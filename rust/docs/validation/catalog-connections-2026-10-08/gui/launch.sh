#!/bin/bash
set -euo pipefail
source /workspace/scratch/8b6fda578834/build-environment/gui-env.sh
base=/workspace/shared/catalog-native-evidence/gui
phase="${1:-light}"
qa="$base/$phase"
src=/workspace/shared/catalog-native-integrated-stage
mkdir -p "$qa/home" "$qa/config" "$qa/data" "$qa/project"
export HOME="$qa/home" XDG_CONFIG_HOME="$qa/config" XDG_DATA_HOME="$qa/data" DISPLAY=:0
export BELLO_TEST_APPEARANCE="$phase" BELLO_TEST_WINDOW_SIZE="${2:-1180x812}"
unset WAYLAND_DISPLAY
python3 "$src/rust/fixtures/catalog_workflow_gateway.py" --port 47891 --log "$qa/same-origin.jsonl" --mode-file "$qa/mode" > "$qa/gateway-one.log" 2>&1 &
one=$!
python3 "$src/rust/fixtures/catalog_workflow_gateway.py" --port 47892 --log "$qa/external-origin.jsonl" > "$qa/gateway-two.log" 2>&1 &
two=$!
trap 'kill "$one" "$two" 2>/dev/null || true' EXIT
"$base/bello-agent-catalog-native-integrated" --synthetic-connections --project "$qa/project" --session "$qa/data/session.json" > "$qa/app.log" 2>&1
