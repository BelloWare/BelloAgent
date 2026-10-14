#!/usr/bin/env python3
"""Compatibility against explicitly supplied pre-v2 and optional v2 helpers.

Only generated journals are opened. --current-helper first creates a real v3
family through the enabled bundled helper and an ephemeral loopback gateway.
"""
import hashlib
import argparse
import http.server
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

from native_host_client import HostPeer


def command(peer, method, params=None, session=None):
    identity = peer.post(method, params, session)
    while True:
        frame = peer.next_frame(20)
        if frame.get('commandId') == identity: return frame


def check_enabled_family(current, older):
    with tempfile.TemporaryDirectory(prefix='enabled-downgrade-', dir=os.environ['PI_BUILD_ROOT']) as directory:
        root = Path(directory); sessions = root/'sessions'; sessions.mkdir()
        requests = []
        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                identity = self.headers['x-session-id']; requests.append(identity)
                if identity == 'parent' and requests.count(identity) == 1:
                    assert 'subagent_start' in [tool.get('name') for tool in body['tools']]
                    output = [dict(type='function_call', id='start', call_id='start', name='subagent_start', arguments=json.dumps(dict(task='Synthetic child', mode='wait')))]
                else:
                    output = [dict(type='message', id='answer', role='assistant', content=[dict(type='output_text', text='Synthetic answer')])]
                response = dict(id='response', model=body['model'], status='completed', output=output, usage=dict(input_tokens=10, output_tokens=2, total_tokens=12, cost=.01))
                payload = ('data: '+json.dumps(dict(type='response.completed', response=response))+'\n\n').encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(payload)))
                self.end_headers(); self.wfile.write(payload)
        gateway = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        thread = threading.Thread(target=gateway.serve_forever, daemon=True); thread.start()
        profile = dict(id='fixture', providerId='litellm', modelId='fixture-model', api='openai-responses',
                       baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1', contextWindow=100000, maxOutputTokens=4096)
        def opened(binary):
            peer = HostPeer(binary, root); ready = peer.hello(10); peer.epoch = ready['hostEpoch']
            assert command(peer, 'workspace.open', dict(cwd=str(root), directory=str(sessions), resources=dict(codexHome=str(root/'codex'), skills=False)))['ok']
            return peer, ready
        def settled(peer):
            deadline = time.monotonic()+30
            while True:
                state = command(peer, 'session.status', session='parent')['result']['state']
                if state == 'idle': return
                assert state != 'error' and time.monotonic() < deadline, state
                time.sleep(.01)
        peer = None
        try:
            peer, ready = opened(current)
            assert 'subagents-steering-v3' in ready['capabilities'], ready
            assert command(peer, 'session.open', dict(profile=profile, apiKey='synthetic', toolMode='read-only'), 'parent')['ok']
            assert command(peer, 'turn.submit', dict(text='Delegate the generated check', clientTurnId='task'), 'parent')['ok']
            settled(peer)
            family = command(peer, 'subagent.list', session='parent')['result']
            assert family['total'] == 1 and family['children'][0]['status'] == 'completed', family
            # Checkpoints are created at nonempty context boundaries, not at
            # every close. Editing a second turn retains the family context.
            assert command(peer, 'turn.submit', dict(clientTurnId='checkpoint', text='One more generated task'), 'parent')['ok']
            settled(peer)
            assert command(peer, 'turn.edit', dict(messageId='checkpoint', clientTurnId='edited', text='Revised generated task'), 'parent')['ok']
            settled(peer)
            assert command(peer, 'session.close', session='parent')['ok']
            peer.close(); peer = None
            journals = {path: path.read_bytes() for path in sessions.glob('*.jsonl')}
            assert len(journals) == 2 and all(b'pi-app.native.v3' in data for data in journals.values())
            checkpoints = {path: path.read_bytes() for path in sessions.glob('*.meta')}
            assert sessions/'parent.jsonl.meta' in checkpoints, 'Parent edit did not retain its checkpoint'
            for binary in older:
                for with_checkpoint in (True, False):
                    for path, data in checkpoints.items():
                        if with_checkpoint: path.write_bytes(data)
                        else: path.unlink(missing_ok=True)
                    peer, _ = opened(binary)
                    for path, data in journals.items():
                        response = command(peer, 'session.open', dict(profile=profile, apiKey='synthetic', path=str(path)), path.stem)
                        assert not response['ok'] and response['result']['code'] == 'legacy_session', response
                        assert path.read_bytes() == data, 'Downgrade modified a promoted journal'
                    peer.close(); peer = None
                    print(f'PASS enabled family: {binary} refuses parent/child, parent checkpoint={with_checkpoint}, unchanged bytes', flush=True)
            assert len(requests) == 5, requests
            print(f'PASS enabled bundled helper: v3 capability, actual parent/child promotion, {len(requests)} loopback requests', flush=True)
        finally:
            if peer: peer.close()
            gateway.shutdown(); gateway.server_close(); thread.join()


def check(binary, promoted_only=False):
    with tempfile.TemporaryDirectory(prefix='subagent-downgrade-', dir=os.environ['PI_BUILD_ROOT']) as directory:
        root = Path(directory)
        sessions = root / 'sessions'
        sessions.mkdir()
        profile = dict(id='fixture', providerId='litellm', modelId='fixture-model', api='openai-responses',
                       baseUrl='http://127.0.0.1:12345/v1', contextWindow=100000, maxOutputTokens=4096)
        binding = dict(api=profile['api'], model=profile['modelId'], provider='litellm',
                       endpointSHA256=hashlib.sha256(b'http://127.0.0.1:12345/v1/responses').hexdigest())
        link = dict(version=1, delegationID='delegation', childSessionID='child', budgetOwnerSessionID='parent',
                    call=dict(parentSessionID='parent', assistantMessageID='reply', toolCallID='call'),
                    parentTurnID='turn', parentExecutionID='execution', depth=1)
        origin = dict(link=link, description='Task', model=dict(model='fixture-model'), tools=[], readOnly=True, resourceRevision='fixture')

        def journal(session, marker, records):
            rows = [dict(type='session', version=3, id=session, cwd=str(root), timestamp='2026-10-14T00:00:00Z')]
            previous = None
            for identity, fields in [('marker', dict(type='custom', customType=marker, data=dict(binding=binding, version=2))), *records]:
                rows.append(dict(fields, id=identity, parentId=previous, timestamp='2026-10-14T00:00:00Z'))
                previous = identity
            path = sessions / (session + '.jsonl')
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return path

        parent = journal('parent', 'pi-app.native.v1', [
            ('reply', dict(type='message', message=dict(role='assistant', content=[dict(type='toolCall', id='call', name='subagent', arguments=dict(task='Task'))]))),
            ('plan', dict(type='custom', customType='pi-app.subagent-call.v1', data=dict(origin=origin, task='Task', resultMessageID='result')))
        ])
        child = journal('child', 'pi-app.native.v2', [('origin', dict(type='custom', customType='pi-app.subagent-origin.v1', data=origin))])
        child_bytes = child.read_bytes()
        peer = HostPeer(binary, root)
        peer.epoch = peer.hello(10)['hostEpoch']

        def command(method, params=None, session=None):
            identity = peer.post(method, params, session)
            while True:
                frame = peer.next_frame(10)
                if frame.get('commandId') == identity:
                    return frame

        try:
            assert command('workspace.open', dict(cwd=str(root), directory=str(sessions), resources=dict(codexHome=str(root/'codex'))))['ok']
            for session in ('promoted-parent','promoted-child'):
                promoted_link = dict(link,childSessionID='promoted-child',budgetOwnerSessionID='promoted-parent',
                                     call=dict(link['call'],parentSessionID='promoted-parent'))
                promoted_origin = dict(origin,link=promoted_link)
                path = journal(session,'pi-app.native.v3',[] if session.endswith('parent') else [('origin',dict(type='custom',customType='pi-app.subagent-origin.v1',data=promoted_origin))])
                before = path.read_bytes()
                refused = command('session.open',dict(profile=profile,apiKey='fixture',path=str(path)),session)
                assert not refused['ok'] and refused['result']['code'] == 'legacy_session', refused
                assert path.read_bytes() == before, 'Older helper changed a promoted journal'
            print(f'PASS: {binary} refuses promoted parent and child without changing bytes')
            if promoted_only: return
            opened = command('session.open', dict(profile=profile, apiKey='fixture', path=str(parent)), 'parent')
            assert opened['ok'], opened
            rows = [json.loads(line) for line in parent.read_text().splitlines()]
            results = [row for row in rows if row.get('message', {}).get('role') == 'toolResult']
            assert len(results) == 1 and results[0]['message']['isError']
            assert command('debug.list', session='parent')['result']['attempts'] == []
            refused = command('session.open', dict(profile=profile, apiKey='fixture', path=str(child)), 'child')
            assert not refused['ok'] and refused['result']['code'] == 'legacy_session', refused
            assert child.read_bytes() == child_bytes
            # The old reader does not inspect data.version: only a distinct marker excludes it.
            version_only = journal('version-only', 'pi-app.native.v1', [])
            accepted = command('session.open', dict(profile=profile, apiKey='fixture', path=str(version_only)), 'version-only')
            assert accepted['ok'], accepted
            print('PASS: v1 parent, interrupted result without replay, v2 child refusal, unchanged child, marker-type gate')
        finally:
            peer.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pre_v2_helper',type=Path)
    parser.add_argument('--v2-helper',type=Path)
    parser.add_argument('--current-helper',type=Path, help='Enabled bundled helper; validate actual promotion with both older generations')
    args = parser.parse_args()
    check(args.pre_v2_helper.resolve())
    if args.v2_helper: check(args.v2_helper.resolve(),promoted_only=True)
    if args.current_helper:
        check_enabled_family(args.current_helper.resolve(), [args.pre_v2_helper.resolve()] + ([args.v2_helper.resolve()] if args.v2_helper else []))
