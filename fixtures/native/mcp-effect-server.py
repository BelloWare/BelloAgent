#!/usr/bin/env python3
"""Synthetic MCP effects fixture: persist one effect, then disconnect once.

Only writes effects.jsonl and disconnected-once inside the test-supplied directory.
It has no network access or credentials. A lost response must never cause a retry.
"""
import json
import os
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    if method == 'initialize':
        result = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'effects-fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'record', 'description': 'Record a synthetic effect', 'annotations': {'readOnlyHint': True}, 'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}}]}
    elif method == 'tools/call':
        with (state / 'effects.jsonl').open('a') as output:
            output.write(json.dumps(request['params']['arguments']) + '\n')
            output.flush()
            os.fsync(output.fileno())
        marker = state / 'disconnected-once'
        if not marker.exists():
            marker.write_text('Fixture disconnected after recording its effect.\n')
            os._exit(17)
        result = {'content': [{'type': 'text', 'text': 'effect retained'}], 'isError': False}
    else:
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'Unsupported fixture method'}}), flush=True)
        continue
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
