#!/bin/bash
set -euo pipefail
source /workspace/scratch/8b6fda578834/build-environment/env.sh
export CARGO_BUILD_JOBS=1 CARGO_TARGET_DIR=/workspace/scratch/8b6fda578834/BelloAgent/rust/target
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_INCREMENTAL
base=/workspace/shared/catalog-native-evidence/notice-repair/corrected-r4
harness=/workspace/shared/catalog-native-app-focused
python3 /workspace/shared/catalog-native-evidence/create-app-focused.py > "$base/harness-preparation.log"
cp "$harness/focused-provenance.json" "$base/restored-harness-provenance.json"
file="$harness/rust/crates/bello-agent-app/src/connection_settings_controller.rs"
cp "$file" "$base/controller-restored.rs"
trap 'cp "$base/controller-restored.rs" "$file"' EXIT
mutate() {
 python3 - "$file" "$base/controller-restored.rs" "$1" "$base" <<'PY'
from pathlib import Path
import sys,hashlib,json
p,original,mode,out=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4]);base=original.read_bytes();assert p.read_bytes()==base
t=base.decode()
if mode=='discard-clear':
 old='.is_some_and(|owner| discarded.is_none_or(|discarded| discarded == owner))';new='.is_some_and(|owner| false && discarded.is_none_or(|discarded| discarded == owner))'
else:
 old='    fn notice(&mut self, text: impl Into<String>, error: bool) {\n        self.draft_notice_owner = None;';new='    fn notice(&mut self, text: impl Into<String>, error: bool) {'
assert t.count(old)==1;t=t.replace(old,new);p.write_text(t)
(out/(mode+'-mutation.json')).write_text(json.dumps({'file':str(p),'before_sha256':hashlib.sha256(base).hexdigest(),'after_sha256':hashlib.sha256(t.encode()).hexdigest(),'old':old,'new':new},indent=2)+'\n')
PY
}
run_test() {
 cargo test --manifest-path "$harness/rust/Cargo.toml" --offline --locked -p bello-agent-app --features native-authority,synthetic-authority --config profile.test.package.gpui.codegen-units=256 "$@" -- --test-threads=1
}
cargo clean --manifest-path "$harness/rust/Cargo.toml" -p bello-agent-app > "$base/bounded-package-clean.log" 2>&1
mutate discard-clear
set +e
run_test discard_reopen > "$base/negative-discard-clear.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$base/negative-discard-clear-status.txt"
[[ "$status" == 101 ]]
grep -q 'catalog_discard_reopen_removes_selected_metadata_and_success_notice .*FAILED' "$base/negative-discard-clear.log"
cp "$base/controller-restored.rs" "$file"
mutate notice-owner-reset
set +e
run_test discard_reopen > "$base/negative-notice-owner-reset.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$base/negative-notice-owner-reset-status.txt"
[[ "$status" == 101 ]]
grep -q 'save_errors_survive_discard_reopen_and_uncertainty_still_blocks_admission .*FAILED' "$base/negative-notice-owner-reset.log"
grep -q 'non_error_recovery_notice_survives_discard_reopen .*FAILED' "$base/negative-notice-owner-reset.log"
cp "$base/controller-restored.rs" "$file"
run_test > "$base/focused-app-combined-restored.log" 2>&1
cargo test --manifest-path "$harness/rust/Cargo.toml" --offline --locked -p bello-agent-app --features native-authority --config profile.test.package.gpui.codegen-units=256 -- --test-threads=1 > "$base/focused-app-native-restored.log" 2>&1
cmp "$file" "$base/controller-restored.rs"
printf 'all restored focused checks passed\n' > "$base/regressions-complete.txt"
