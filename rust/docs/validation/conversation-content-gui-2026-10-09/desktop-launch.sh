#!/bin/bash
r=/workspace/shared/conversation-content-r2-gui
python3 "$r/gateway.py" > "$r/evidence/gateway.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
sleep 0.3
bash "$r/launch.sh" /workspace/shared/conversation-content-r2-evidence/bin/bello-agent-search-copy-r2 1ccee19cbadf3dc6d42e4fcea96775454c17ebab347e1586c5ada84575820740
code=$?
echo "$code" > "$r/evidence/app.exit"
exit "$code"
