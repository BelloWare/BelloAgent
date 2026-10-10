#!/bin/zsh
# Native follow check for the Rust Agent transcript (loopback gateway, seeded
# 800-message chat, fake key; nothing leaves the Mac). Usage: follow-check.sh OUT
# Captures: open placement, following while a reply streams, holding after the
# reader scrolls up, and following again after they scroll back to the end.
set -u
W=/Users/admin/Library/Caches/BelloRustWork/claude-2026-10-10
V=${1:?output folder}
P=$W/harness/belloperf
rm -rf $V; mkdir -p $V/home $V/project $V/session
cp $W/fixtures/longchat-400/rust-session/session.json $V/session/
BENCH_LOG=$V/gateway.jsonl BENCH_PORT=47900 nohup python3 -I $W/harness/benchgw.py > $V/gateway.out 2>&1 &
GW=$!
sleep 1
(cd $V/project && HOME=$V/home $W/harness/rust-agent-run.sh $W/target/release/bello-agent --project $V/project \
  --session $V/session/session.json --profile $W/fixtures/bench/rust-profile.json --credential-stdin \
  > $V/stdout.log 2> $V/stderr.log &)
sleep 5
PID=$(pgrep -n -f "$W/target/release/bello-agent --project $V/project")
WIN=$($P windows $PID | sed -n 's/^window id=\([0-9]*\).*bounds=(\([0-9.]*\), \([0-9.]*\),.*/\1 \2 \3/p' | head -1)
read ID X Y <<< "$WIN"
echo "pid=$PID gateway=$GW window=$ID origin=$X,$Y"
# Transcript region in screen points (sidebar is 300 pt wide, composer below 740).
RX=$((${X%.*} + 400)); RY=$((${Y%.*} + 150))
shot() { $P capture $ID $V/$1.png > /dev/null; echo "captured $1"; }
wheel() { $P input --pid $PID --kind wheel --region $RX,$RY,700,400 --count 1 --wheel-px $1 --timeout-ms 400 --label wheel > /dev/null; }
shot 01-opened
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" > /dev/null
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "Stream the follow check"' -e 'tell application "System Events" to key code 36'
sleep 4; shot 02-streaming-4s
sleep 4; shot 03-streaming-8s
for i in 1 2 3 4 5; do wheel 600; done
sleep 0.5; shot 04-scrolled-up
sleep 5; shot 05-held-5s-later
for i in 1 2 3 4; do wheel -6000; done
sleep 0.5; shot 06-back-at-end
sleep 5; shot 07-following-5s-later
echo "pid=$PID gateway=$GW"
