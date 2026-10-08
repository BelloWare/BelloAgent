#!/usr/bin/env bash
printf '%s\n' "${1:-unrecorded}" > /workspace/shared/agent-timing-gui-run/evidence/first-exit.txt
bash /workspace/shared/agent-timing-gui-run/start.sh
