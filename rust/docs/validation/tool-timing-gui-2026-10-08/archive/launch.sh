#!/usr/bin/env bash
# Root/operator only: this script launches GUI solely when explicitly executed.
set -euo pipefail
root=$(realpath "${1:?Supply generated fixture root}")
gui_env=${2:?Supply verified existing cloud GUI environment script}
binary=$(python3 - "$root" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
marker=json.loads((root/'fixture.json').read_text())
assert marker['kind']=='generated-a5-concurrency-v1'
sealed=json.loads((root/'evidence/sealed-build.json').read_text())
binary=pathlib.Path(sealed['binary'])
assert sealed['fixture_id']==marker['id']
assert binary.parent==root/'bin' and binary.is_file() and not binary.is_symlink()
assert hashlib.sha256(binary.read_bytes()).hexdigest()==sealed['binary_sha256']
print(binary)
PY
)
# Caller chooses the known cloud GUI environment; no desktop/device discovery.
source "$gui_env"
: "${DISPLAY:?Root must explicitly choose its cloud display}"
export HOME="$root/home" TMPDIR="$root/tmp" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache"
export BELLO_TEST_APPEARANCE=light BELLO_TEST_WINDOW_SIZE=1180x840
unset WAYLAND_DISPLAY
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export NO_PROXY=127.0.0.1,::1 no_proxy=127.0.0.1,::1
exec "$binary" --synthetic-connections --synthetic-attachment-fixture "$root/profile.json" --project "$root/project" --session "$root/state/session.json" > "$root/evidence/app.log" 2>&1
