#!/usr/bin/env bash
# Explicit assigned-desktop launch only; preparation must not invoke this file.
set -euo pipefail
root=$(realpath "${1:?Supply generated fixture root}")
binary=$(realpath "${2:?Supply sealed synthetic-authority app binary}")
build_env=${3:?Supply existing build environment}
python3 - "$root" "$binary" <<'PY'
import hashlib,json,pathlib,sys
root,binary=map(pathlib.Path,sys.argv[1:])
marker=json.loads((root/'fixture.json').read_text())
assert marker['kind']=='generated-bash-workflow-v1'
sealed=json.loads((root/'evidence/sealed-build.json').read_text())
assert sealed['fixture_id']==marker['id'] and pathlib.Path(sealed['binary'])==binary
assert hashlib.sha256(binary.read_bytes()).hexdigest()==sealed['binary_sha256']
PY
source "$build_env/gui-env.sh"
export HOME="$root/home" TMPDIR="$root/tmp" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache"
export BELLO_TEST_APPEARANCE=light BELLO_TEST_WINDOW_SIZE=1180x840
: "${DISPLAY:?Desktop must be explicitly assigned before launch}"
unset WAYLAND_DISPLAY
"$binary" --synthetic-connections --synthetic-attachment-fixture "$root/profile.json" --project "$root/project" --session "$root/state/session.json" > "$root/evidence/app.log" 2>&1
