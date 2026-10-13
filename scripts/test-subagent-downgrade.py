#!/usr/bin/env python3
"""Read/write compatibility against an explicitly supplied pre-v2 helper.

Only generated journals are opened. No turn is submitted and no gateway runs.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

from native_host_client import HostPeer


def check(binary):
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
    check(Path(sys.argv[1]).resolve())
