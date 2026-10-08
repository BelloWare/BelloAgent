#!/bin/bash
set -uo pipefail
source /workspace/shared/build-recovery/env.sh
source /workspace/shared/build-recovery/gpui-env.sh
cd /workspace/shared/agent-topics-integrated/rust
E=/workspace/shared/agent-topics-evidence
cargo clean -p bello-agent-core -p bello-agent-app > "$E/final-package-clean.log" 2>&1
python3 - <<'PY'
import pathlib,json
root=pathlib.Path('/workspace/shared/build-recovery/target/debug/deps')
left=[str(p) for p in root.glob('bello_agent*') if p.is_file() and p.stat().st_mode&0o111]
assert not left,left
pathlib.Path('/workspace/shared/agent-topics-evidence/final-clean-verification.json').write_text(json.dumps({'agent_executables_remaining':left})+'\n')
PY
run() { local name="$1"; shift; "$@" > "$E/$name.log" 2>&1; local r=$?; echo "$r" > "$E/$name.exit"; echo "$name exit $r"; if [ "$r" -ne 0 ]; then tail -90 "$E/$name.log"; exit "$r"; fi; }
run final-core-default cargo test --locked -p bello-agent-core
run final-core-all cargo test --locked -p bello-agent-core --all-features
run final-app-all cargo test --locked -p bello-agent-app --all-features
run final-clippy-default cargo clippy --locked -p bello-agent-core -p bello-agent-app --all-targets -- -D warnings
run final-clippy-all cargo clippy --locked -p bello-agent-core -p bello-agent-app --all-features --all-targets -- -D warnings
run final-fmt cargo fmt --all -- --check
