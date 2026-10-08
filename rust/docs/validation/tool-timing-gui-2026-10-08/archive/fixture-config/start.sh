#!/usr/bin/env bash
set -euo pipefail
root=/workspace/shared/agent-timing-gui-run
python3 /workspace/shared/a5-gui-fixture/fixture.py serve --root "$root" > "$root/evidence/server-desktop.log" 2>&1 &
server_pid=$!
echo "$server_pid" > "$root/evidence/server-desktop.pid"
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
bash /workspace/shared/a5-gui-fixture/launch.sh "$root" /workspace/shared/build-recovery/gui-runtime-env.sh
