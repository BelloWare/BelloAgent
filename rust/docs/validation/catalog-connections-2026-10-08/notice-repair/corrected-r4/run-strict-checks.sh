#!/bin/bash
set -euo pipefail
source /workspace/scratch/8b6fda578834/build-environment/env.sh
export CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR=/workspace/scratch/8b6fda578834/BelloAgent/rust/target
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_INCREMENTAL
logs=/workspace/shared/catalog-native-evidence/notice-repair/corrected-r4
cd /workspace/shared/catalog-native-integrated-stage/rust
cargo clean -p bello-agent-app > "$logs/canonical-package-clean.log" 2>&1
cargo fmt --all -- --check > "$logs/fmt-check.log" 2>&1
cargo clippy --offline --locked --workspace --all-targets -- -D warnings > "$logs/default-clippy.log" 2>&1
cargo clippy --offline --locked --workspace --all-targets --features synthetic-authority -- -D warnings > "$logs/synthetic-clippy.log" 2>&1
cargo clippy --offline --locked -p bello-agent-core --all-features --all-targets -- -D warnings > "$logs/core-all-features-clippy.log" 2>&1
cargo clippy --offline --locked -p bello-agent-app --all-targets --features native-authority -- -D warnings > "$logs/native-clippy.log" 2>&1
cargo clippy --offline --locked -p bello-agent-app --all-targets --features native-authority,synthetic-authority -- -D warnings > "$logs/combined-clippy.log" 2>&1
printf 'all strict checks passed\n' > "$logs/strict-checks-complete.txt"
