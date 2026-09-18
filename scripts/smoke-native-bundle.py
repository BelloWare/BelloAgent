#!/usr/bin/env python3
"""Offline packaged-helper handshake/protocol smoke. No model calls or credentials."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import uuid

app = Path(sys.argv[1]).resolve()
helper = app / 'Contents/Helpers/pi-native-host'
manifest = json.loads((app / 'Contents/Resources/Host/bundle-manifest.json').read_text())
assert manifest['engine'] == 'swift' and manifest['bundledNode'] is False
catalog = app / 'Contents/Resources/bello-agent.models.json'
catalog_source = Path(__file__).resolve().parent.parent / 'catalogs/bello-agent.models.json'
assert catalog.read_bytes() == catalog_source.read_bytes(), 'Packaged model catalog differs from the reviewed source'
catalog_models = json.loads(catalog.read_text())['models']
subprocess.run(['lipo', str(helper), '-verify_arch', 'arm64'], check=True)
assert not (app / 'Contents/Helpers/node').exists()
assert not list((app / 'Contents/Resources/Host').rglob('node_modules'))
with tempfile.TemporaryDirectory(prefix='pi-native-smoke-') as scratch:
    process = subprocess.Popen([str(helper)], cwd=scratch, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    frames = queue.Queue()
    def read_frames():
        try:
            for line in process.stdout:
                frames.put(json.loads(line))
        except Exception as error:
            frames.put(error)
    threading.Thread(target=read_frames, daemon=True).start()
    def send(value):
        process.stdin.write(json.dumps(value).encode() + b'\n'); process.stdin.flush()
    def next_frame():
        value = frames.get(timeout=10)
        if isinstance(value, Exception):
            raise value
        return value
    try:
        send({'v': 1, 'kind': 'hello', 'major': 1, 'minor': 1})
        ready = next_frame()
        assert ready['kind'] == 'ready' and ready['engine'] == 'swift'
        assert 'responses' in ready['capabilities'] and 'messages' not in ready['capabilities'], ready
        epoch = ready['hostEpoch']
        for method, params in [('runtime.info', {}), ('workspace.open', {'cwd': scratch, 'directory': str(Path(scratch) / 'sessions')}), ('mcp.list', {})]:
            identity = str(uuid.uuid4())
            send({'v': 1, 'kind': 'command', 'hostEpoch': epoch, 'commandId': identity, 'method': method, 'params': params})
            while True:
                reply = next_frame()
                if reply.get('commandId') == identity:
                    assert reply['ok'], reply
                    break
        process.stdin.close(); process.wait(timeout=10)
        assert process.returncode == 0
        print(json.dumps({'engine': 'swift', 'engineVersion': ready['engineVersion'], 'bundledNode': False,
                          'offlineSmoke': 'passed', 'bundledCatalogModels': len(catalog_models),
                          'helperBytes': helper.stat().st_size, 'capabilities': ready['capabilities']}, indent=2))
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
        process.stdout.close(); process.stderr.close()
