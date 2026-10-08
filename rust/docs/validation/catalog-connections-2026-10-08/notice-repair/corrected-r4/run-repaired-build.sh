#!/bin/bash
set -euo pipefail
source /workspace/scratch/8b6fda578834/build-environment/env.sh
export CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR=/workspace/scratch/8b6fda578834/BelloAgent/rust/target
logs=/workspace/shared/catalog-native-evidence
python3 "$logs/notice-repair/corrected-r4/source-provenance-r4.py" before > "$logs/gui-r4/build-source-check.log"
cd /workspace/shared/catalog-native-integrated-stage/rust
cargo clean -p bello-agent-core -p bello-agent-app > "$logs/gui-r4/build-package-clean.log" 2>&1
cargo build --offline --locked -p bello-agent-app --features native-authority,synthetic-authority --config profile.dev.package.gpui.codegen-units=256 > "$logs/gui-r4/build.log" 2>&1
cp "$CARGO_TARGET_DIR/debug/bello-agent" "$logs/gui-r4/bello-agent-catalog-native-integrated"
python3 "$logs/notice-repair/corrected-r4/source-provenance-r4.py" after >> "$logs/gui-r4/build-source-check.log"
sha256sum "$logs/gui-r4/bello-agent-catalog-native-integrated" > "$logs/gui-r4/binary.sha256"
