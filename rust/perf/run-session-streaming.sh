#!/usr/bin/env bash
# Builds only a standalone example; does not patch the measured core.
set -euo pipefail
cd "$(dirname "$0")/../.."
source /workspace/shared/rust-toolchain/env.sh
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/workspace/shared/rust-toolchain/release-target}"
export BENCH_CLK_TCK="$(getconf CLK_TCK)"
export NO_PROXY=127.0.0.1,localhost
export no_proxy="$NO_PROXY"
output="${1:-rust/perf/raw/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$output"
output="$(realpath "$output")"
sources=(rust/Cargo.toml rust/Cargo.lock rust/crates/bello-agent-core/Cargo.toml
  rust/crates/bello-agent-core/src/*.rs
  rust/crates/bello-agent-core/examples/session_streaming_bench.rs
  packages/swift-host/Sources/PiAgentCore/SessionStreaming.swift
  packages/swift-host/Sources/PiAgentCore/SessionStreamingRow.swift
  packages/swift-host/Sources/PiAgentCore/SessionJournal.swift)
sha256sum "${sources[@]}" > "$output/source-before.sha256"
{
  date -u +%FT%TZ
  git rev-parse HEAD
  rustc -Vv
  cargo -V
  uname -a
  cat /etc/os-release
  printf '\nBuild profile / limits\n'
  sed -n '/\[profile.release\]/,$p' rust/Cargo.toml
  printf 'CARGO_TARGET_DIR=%s\nCARGO_BUILD_JOBS=%s\nBENCH_CLK_TCK=%s\n' "$CARGO_TARGET_DIR" "$CARGO_BUILD_JOBS" "$BENCH_CLK_TCK"
  printf 'Filesystem types (container backing hardware unspecified)\n'
  df -T "$output" /tmp
  printf 'Available CPUs and memory limit\n'
  getconf _NPROCESSORS_ONLN
  cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max 2>/dev/null || true
} > "$output/environment.txt"
cargo build --manifest-path rust/Cargo.toml --locked --offline --release -p bello-agent-core --example session_streaming_bench 2>&1 | tee "$output/build.log"
sha256sum "${sources[@]}" > "$output/source-pre-run.sha256"
cmp "$output/source-before.sha256" "$output/source-pre-run.sha256"
binary="$CARGO_TARGET_DIR/release/examples/session_streaming_bench"
sha256sum "$binary" > "$output/binary.sha256"
python3 rust/perf/run-session-streaming.py "$binary" "$output"
sha256sum "${sources[@]}" > "$output/source-after.sha256"
cmp "$output/source-pre-run.sha256" "$output/source-after.sha256"
printf 'Completed, measured source unchanged: %s\n' "$output"
