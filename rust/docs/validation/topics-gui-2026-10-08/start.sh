#!/bin/bash
set -euo pipefail
r=/workspace/shared/agent-topics-gui
source /workspace/shared/build-recovery/gui-runtime-env.sh
export HOME="$r/home" TMPDIR="$r/tmp" XDG_CONFIG_HOME="$r/config" XDG_DATA_HOME="$r/data" XDG_CACHE_HOME="$r/cache"
export BELLO_TEST_APPEARANCE=light BELLO_TEST_WINDOW_SIZE=1180x840
unset WAYLAND_DISPLAY HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export NO_PROXY=127.0.0.1,::1 no_proxy=127.0.0.1,::1
python3 "$r/trap.py" > "$r/evidence/listener.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
set +e
"$r/bin/bello-agent-topics" --synthetic-connections --synthetic-attachment-fixture "$r/profile.json" --project "$r/project" --session "$r/state/session.json" > "$r/evidence/app.log" 2>&1
code=$?
echo "$code" > "$r/evidence/app.exit"
exit "$code"
