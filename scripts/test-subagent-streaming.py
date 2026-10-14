#!/usr/bin/env python3
"""Four real child streams, family capture/accounting and Stop/shutdown latency.

Only generated projects and an ephemeral loopback gateway. Pass the helper to
test; --fixture enables the existing generated-source rollout fixture before
the production switch is changed. All output stays under PI_BUILD_ROOT.
"""
import argparse
import base64
import http.server
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import uuid
from native_host_client import HostPeer

BUILD = Path(os.environ['PI_BUILD_ROOT'])


def run(binary, mode):
    with tempfile.TemporaryDirectory(prefix='subagent-stream-', dir=BUILD) as folder:
        root = Path(folder)
        lock = threading.Lock()
        requests, packets, responses, started = [], [], {}, set()
        rendezvous = threading.Event()
        active = peak = 0

        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def do_POST(self):
                nonlocal active, peak
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                session = self.headers['x-session-id']
                with lock: requests.append((session, body))
                child = session != 'parent'
                if child:
                    with lock:
                        started.add(session); active += 1; peak = max(active, peak)
                        if len(started) == 4: rendezvous.set()
                sent = bytearray()
                try:
                    self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()

                    def event(value):
                        data = ('data: ' + json.dumps(value, separators=(',', ':')) + '\n\n').encode()
                        self.wfile.write(data); self.wfile.flush(); sent.extend(data)

                    results = [item for item in body['input'] if item.get('type') == 'function_call_output']
                    if not child and not results:
                        assert any(tool.get('name') == 'subagent' for tool in body['tools']), body['tools']
                        output = [dict(type='function_call', id='item-' + str(i), call_id='call-' + str(i), name='subagent', arguments=json.dumps(dict(task='Review synthetic area ' + str(i)))) for i in range(4)]
                    else:
                        if child:
                            assert not any(tool.get('name') == 'subagent' for tool in body['tools']), 'Nested delegation advertised'
                            assert rendezvous.wait(10), 'Four children did not overlap'
                        parts = []
                        for i in range(80 if child else 1):
                            delta = f'Fixture line {i}: Unicode boundaries 中文🙂 remain stable.\n'
                            parts.append(delta); event(dict(type='response.output_text.delta', delta=delta))
                            if child: time.sleep(.012)
                        output = [dict(type='message', id='message-' + uuid.uuid4().hex, role='assistant', content=[dict(type='output_text', text=''.join(parts))])]
                    event(dict(type='response.completed', response=dict(id='response-' + uuid.uuid4().hex, model=body['model'], status='completed', output=output, usage=dict(input_tokens=200, output_tokens=80, total_tokens=280, cost=.01))))
                except (BrokenPipeError, ConnectionResetError): pass
                finally:
                    with lock:
                        responses[session] = bytes(sent)
                        if child: active -= 1

        gateway = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        threading.Thread(target=gateway.serve_forever, daemon=True).start()

        def capture(frame):
            with lock: packets.append(frame['packet'])
            return True

        peer = HostPeer(binary, root, capture=capture)
        events = []

        def command(method, params=None, session=None):
            identity = peer.post(method, params, session)
            while True:
                frame = peer.next_frame(15)
                if frame.get('kind') == 'event': events.append(frame)
                if frame.get('commandId') == identity:
                    assert frame['ok'], frame
                    return frame['result']

        def until(predicate):
            deadline = time.monotonic() + 15
            while not predicate():
                assert time.monotonic() < deadline, 'Fixture timed out'
                time.sleep(.015)

        try:
            peer.epoch = peer.hello(10)['hostEpoch']
            command('workspace.open', dict(cwd=str(root), directory=str(root/'sessions'), captureProtocol=1, resources=dict(codexHome=str(root/'codex'), skills=False)))
            profile = dict(id='fixture', providerId='litellm', modelId='fixture-model', api='openai-responses', baseUrl=f'http://127.0.0.1:{gateway.server_port}/v1', contextWindow=100000, maxOutputTokens=4096)
            command('session.open', dict(profile=profile, apiKey='synthetic-loopback-key', toolMode='read-only'), 'parent')
            command('debug.mode', dict(mode='persist'), 'parent')
            began = time.monotonic()
            command('turn.submit', dict(clientTurnId='turn', text='Delegate four independent checks.'), 'parent')
            until(rendezvous.is_set)
            admission_ms = (time.monotonic() - began) * 1000
            # Polling the parent exercises live progress projection while every
            # physical child delivers capture packets over the same transport.
            revisions = set()
            for _ in range(5):
                snapshot = command('session.snapshot', {}, 'parent')
                revisions.add(snapshot.get('subagentsRevision'))
                time.sleep(.025)
            stopped = time.monotonic()
            if mode == 'stop':
                command('turn.stop', {}, 'parent')
                until(lambda: command('session.status', {}, 'parent')['state'] in ['paused', 'error'])
            elif mode == 'complete':
                until(lambda: command('session.status', {}, 'parent')['state'] == 'idle')
                cost = command('session.snapshot', {}, 'parent')['cost']
                assert abs(cost['spentUSD'] - .06) < 1e-9, cost
                assert cost['reportedRequests'] == 6 and cost['unreportedRequests'] == 0, cost
                for child in started:
                    local = command('session.snapshot', {}, child)['cost']
                    assert abs(local['spentUSD'] - .01) < 1e-9, local
            if mode != 'shutdown':
                family = command('subagent.list', {}, 'parent')
                assert family['total'] == 4 and family['active'] == 0, family
            peer.send(dict(v=1, kind='shutdown', hostEpoch=peer.epoch))
            peer.process.wait(timeout=10)
            peer.close(wait=10)
            settled_ms = (time.monotonic() - stopped) * 1000
            assert peak == 4, peak
            assert len(revisions) == 1, 'Token progress changed sidebar discovery revision'
            assert not peer.errors, peer.errors
            rows = [json.loads(line) for line in (root/'sessions/parent.jsonl').read_text().splitlines()]
            results = [row['message'] for row in rows if row.get('message', {}).get('toolName') == 'subagent']
            assert len(results) == 4, results
            assert all(json.loads(row['content'][0]['text'])['status'] == ('completed' if mode == 'complete' else 'interrupted') for row in results)
            begins = [packet['metadata'] for packet in packets if packet['type'] == 'begin']
            ends = [packet['metadata'] for packet in packets if packet['type'] == 'finish']
            children = [value for value in begins if value['sessionId'] != 'parent']
            assert len(children) == 4 and len(begins) == len(ends), (len(begins), len(ends))
            for value in children:
                scope = value['requestScope']
                assert scope['budgetOwnerSessionID'] == 'parent' and scope['sourceSessionID'] == value['sessionId']
                data = b''.join(base64.b64decode(p['bytes']) for p in packets if p['type'] == 'bytes' and p['attemptId'] == value['attemptId'] and p['body'] == 'response')
                assert data, 'A child stream had no captured response bytes'
                if mode == 'complete': assert data == responses[value['sessionId']], 'Concurrent capture lost bytes'
            if mode == 'complete':
                assert len(requests) == 6, requests
                charges = [row['data'] for row in rows if row.get('customType') == 'pi-app.cost.v1']
                # The initial ordinary parent request and every later physical
                # family attempt are each charged exactly once.
                assert len({c['attemptId'] for c in charges}) == 6, charges
                assert abs(sum(c.get('usd', 0) for c in charges) - .06) < 1e-9, charges
            report = dict(mode=mode, concurrent_children=peak, admission_ms=round(admission_ms, 2), settlement_ms=round(settled_ms, 2), captured_attempts=len(ends), capture_packets=len(packets), discovery_revisions_during_stream=len(revisions))
            print(json.dumps(report), flush=True)
            return report
        finally:
            peer.close(); gateway.shutdown(); gateway.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('helper', type=Path)
    parser.add_argument('--fixture', action='store_true')
    options = parser.parse_args()
    binary = options.helper
    if options.fixture:
        spec = importlib.util.spec_from_file_location('subagent_crashes', Path(__file__).with_name('test-subagent-crashes.py'))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        binary = module.fixture_binary()
    reports = [run(binary, mode) for mode in ['complete', 'stop', 'shutdown']]
    (BUILD/'logs/subagent-streaming.json').write_text(json.dumps(reports, indent=2) + '\n')
