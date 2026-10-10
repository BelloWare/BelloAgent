#!/bin/zsh
# Idle diagnosis for the Rust apps: render callbacks per second (BELLO_PERF_LOG),
# wakeups, and a physical-footprint breakdown. Isolated data only.
set -u
W=$WORK
OUT=${OUT:-$W/perf/idle-diagnose-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p $OUT/agent-home $OUT/agent-project $OUT/box-config
run_one() { # label ... command
  local label=$1; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 8   # past launch and first paint
  : > $OUT/$label-perf.jsonl.mark
  local lines0=$(wc -l < $OUT/$label-perf.jsonl 2>/dev/null || echo 0)
  local t0=$(date +%s)
  top -l 2 -s 10 -pid $pid -stats pid,cpu,idlew,power,mem > $OUT/$label-top.txt 2>&1
  local lines1=$(wc -l < $OUT/$label-perf.jsonl 2>/dev/null || echo 0)
  local t1=$(date +%s)
  footprint $pid > $OUT/$label-footprint.txt 2>&1
  echo "$label: perf-log lines during ~$((t1 - t0))s idle: $((lines1 - lines0))"
  kill -TERM $pid; sleep 2; kill -9 $pid 2>/dev/null
}
run_one rust-agent env HOME=$OUT/agent-home BELLO_PERF_LOG=$OUT/rust-agent-perf.jsonl $W/target/release/bello-agent --project $OUT/agent-project
run_one rust-box env BELLOBOX_CONFIG_DIR=$OUT/box-config BELLO_PERF_LOG=$OUT/rust-box-perf.jsonl $W/target/release/bellobox
echo "out=$OUT"
