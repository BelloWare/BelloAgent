#!/bin/zsh
# Profile the Rust Agent while a 96K-character reply streams on screen (loopback
# gateway, seeded 800-message chat, fake key). Usage: stream-profile.sh OUT [BIN]
# Writes per-second CPU/footprint (cpu.json) and a full call-tree `sample`
# taken 30 s into the stream (call-tree.txt).
set -u
W=/Users/admin/Library/Caches/BelloRustWork/claude-2026-10-10
V=${1:?output folder}
BIN=${2:-$W/target/release/bello-agent}
P=$W/harness/belloperf
rm -rf $V; mkdir -p $V/home $V/project $V/session
cp $W/fixtures/longchat-400/rust-session/session.json $V/session/
BENCH_LOG=$V/gateway.jsonl BENCH_PORT=47900 nohup python3 -I $W/harness/benchgw.py > $V/gateway.out 2>&1 &
GW=$!
sleep 1
(cd $V/project && HOME=$V/home $W/harness/rust-agent-run.sh $BIN --project $V/project \
  --session $V/session/session.json --profile $W/fixtures/bench/rust-profile.json --credential-stdin \
  > $V/stdout.log 2> $V/stderr.log &)
sleep 5
PID=$(pgrep -n -f "$BIN --project $V/project")
ID=$($P windows $PID | sed -n 's/^window id=\([0-9]*\).*/\1/p' | head -1)
echo "pid=$PID gateway=$GW window=$ID"
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" > /dev/null
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "Stream the profile check"' -e 'tell application "System Events" to key code 36'
$P sample --pid $PID --seconds 62 --out $V/cpu.json --label stream > $V/cpu.out &
SAMPLER=$!
sleep 30
sample $PID 8 -file $V/call-tree.txt > /dev/null 2>&1
$P capture $ID $V/at-38s.png > /dev/null
wait $SAMPLER
cat $V/cpu.out
kill $PID $GW 2>/dev/null
echo "stopped pid=$PID gateway=$GW"
