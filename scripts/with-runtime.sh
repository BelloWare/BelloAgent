#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT and run scripts/setup-runtime.py first}"
RUNTIME="$(python3 - "$ROOT/scripts/runtime-lock.json" "$PI_BUILD_ROOT" <<'PY'
import json, pathlib, sys
lock = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(pathlib.Path(sys.argv[2]) / 'runtime' / f"node-v{lock['node']}-{lock['platform']}" / 'bin')
PY
)"
test -x "$RUNTIME/node"
export PATH="$RUNTIME:$PATH"
export TMPDIR="$PI_BUILD_ROOT"
export npm_config_cache="$PI_BUILD_ROOT/npm-cache"
exec "$@"
