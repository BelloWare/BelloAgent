#!/usr/bin/env python3
"""Prepare fresh normal legacy-CLI UI inputs; never seed sessions or authority.
Usage: prepare-gui-fixture.py NEW_ROOT SEALED_BINARY [PORT]
Does not launch a GUI or server. Run only generated launchers after assignment.
"""
import hashlib, json, pathlib, shlex, sys
root = pathlib.Path(sys.argv[1]).resolve()
binary = pathlib.Path(sys.argv[2]).resolve()
port = int(sys.argv[3]) if len(sys.argv) > 3 else 47836
assert 1024 <= port <= 65535
assert binary.is_file()
root.mkdir(parents=False, exist_ok=False)
for name in ('home','project','state','config','data','cache','tmp','evidence'):
    (root/name).mkdir()
profile = {'id':'sidebar-local-fixture','api':'openai-responses','providerId':'litellm',
           'modelId':'local-test-fixture','baseUrl':f'http://127.0.0.1:{port}',
           'contextWindow':32000,'maxOutputTokens':4096}
(root/'profile.json').write_text(json.dumps(profile, indent=2)+'\n')
source = pathlib.Path('/workspace/shared/agent-sidebar-run-state/rust/fixtures/gateway.py')
(root/'gateway.py').write_bytes(source.read_bytes())
(root/'run-gateway.py').write_text('''import os, runpy\nfrom http.server import ThreadingHTTPServer\nfrom pathlib import Path\nroot = Path(__file__).resolve().parent\nnamespace = runpy.run_path(str(root/'gateway.py'))\nThreadingHTTPServer(('127.0.0.1', '''+str(port)+'''), namespace['Handler']).serve_forever()\n''')
launcher = '''#!/usr/bin/env bash
set -euo pipefail
root='''+shlex.quote(str(root))+'''
binary='''+shlex.quote(str(binary))+'''
source /workspace/shared/build-recovery/gui-env.sh
: "${DISPLAY:?Use only the explicitly assigned GUI display}"
for name in $(env | cut -d= -f1 | grep -i proxy || true); do unset "$name"; done
export NO_PROXY='*' no_proxy='*'
export HOME="$root/home" TMPDIR="$root/tmp" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache"
export BELLO_TEST_APPEARANCE=light BELLO_TEST_WINDOW_SIZE=1180x840
unset WAYLAND_DISPLAY
python3 - "$root" "$binary" <<'PYVERIFY'
import hashlib,json,pathlib,sys
root,binary=map(pathlib.Path,sys.argv[1:])
assert hashlib.sha256(binary.read_bytes()).hexdigest()==json.loads((root/'fixture.json').read_text())['binary_sha256']
PYVERIFY
printf '%s' 'sidebar-gui-fixture-only' | "$binary" --project "$root/project" --session "$root/state/session.json" --profile "$root/profile.json" --credential-stdin >> "$root/evidence/app.log" 2>&1
'''
(root/'launch-app.sh').write_text(launcher)
(root/'launch-app.sh').chmod(0o700)
(root/'fixture.json').write_text(json.dumps({'kind':'sidebar-normal-legacy-cli-v1',
    'binary':str(binary),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'gateway_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
    'port':port,'scope':'Normal UI creates all chats; no authority/session/catalog seeding; no saved-connection or native acceptance',
    'outputs':'Text receipts and logs only; no delivered screenshots'},indent=2)+'\n')
print(root)
