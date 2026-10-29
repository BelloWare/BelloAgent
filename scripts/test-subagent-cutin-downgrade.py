#!/usr/bin/env python3
"""Real 0.1.135 writer fence, using generated loopback journals only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
from native_host_client import HostPeer

BUILD = Path(os.environ['PI_BUILD_ROOT'])

def command(peer, method, params=None, session=None):
    key = peer.post(method,params,session)
    while True:
        frame = peer.next_frame(20)
        if frame.get('commandId') == key: return frame

def check(current, older):
    spec = importlib.util.spec_from_file_location('cutin',Path(__file__).with_name('test-subagent-cutin.py'))
    fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
    with tempfile.TemporaryDirectory(prefix='cutin-downgrade-',dir=BUILD) as folder:
        root = Path(folder)
        previous = os.environ.get('PI_CUTIN_KEEP'); os.environ['PI_CUTIN_KEEP'] = str(root)
        try:
            for mode in ['reasoning','portable']: fixture.run(current,mode)
        finally:
            if previous is None: os.environ.pop('PI_CUTIN_KEEP',None)
            else: os.environ['PI_CUTIN_KEEP'] = previous
        for variant in ['checkpoint','cold','v4-uncut','fence-mutation']:
            source = root/('portable' if variant == 'v4-uncut' else 'reasoning')
            target = root/variant; shutil.copytree(source,target)
            if variant in ['cold','fence-mutation']:
                for path in (target/'sessions').glob('*.meta'): path.unlink()
            if variant == 'fence-mutation':
                for path in (target/'sessions').glob('*.jsonl'):
                    path.write_bytes(path.read_bytes().replace(b'pi-app.native.v5',b'pi-app.native.v4'))
            journals = {p:p.read_bytes() for p in (target/'sessions').glob('*.jsonl')}
            peer = HostPeer(older,target); peer.epoch = peer.hello(10)['hostEpoch']
            try:
                assert command(peer,'workspace.open',dict(cwd=str(target),directory=str(target/'sessions'),resources=dict(codexHome=str(target/'codex'),skills=False)))['ok']
                profile = json.loads((target/'profile.json').read_text())
                for path,data in sorted(journals.items(),key=lambda pair:pair[0].stem != 'parent'):
                    response = command(peer,'session.open',dict(profile=profile,apiKey='generated-loopback-only',path=str(path)),path.stem)
                    if variant in ['checkpoint','cold']:
                        assert not response['ok'] and response['result']['code'] == 'legacy_session',response
                        assert path.read_bytes() == data,'Old writer changed a v5 journal'
                    elif path.stem == 'parent': assert response['ok'],response
                print(f'PASS 0.1.135 {variant}: '+('parent and child refused; identical bytes' if variant in ['checkpoint','cold'] else 'v4 parent opens'),flush=True)
            finally:
                peer.send(dict(v=1,kind='shutdown',hostEpoch=peer.epoch)); peer.process.wait(timeout=15); peer.close()
        print('PASS writer-fence mutation killed: removing v5 permits the old writer',flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('current'); parser.add_argument('older')
    args = parser.parse_args()
    print('0.1.135 helper SHA256 '+hashlib.sha256(Path(args.older).read_bytes()).hexdigest(),flush=True)
    check(args.current,args.older)
