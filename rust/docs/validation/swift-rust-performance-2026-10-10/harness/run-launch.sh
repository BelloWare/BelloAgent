#!/bin/zsh
# Interleaved launch/idle comparison: shipped Swift apps vs Rust release builds.
# Owner-approved 2026-10-10: shipped Swift apps may run; their prefs are backed up
# first and restored afterwards. No messages are sent; Rust data is isolated.
set -u
W=$WORK
P=$W/harness/belloperf
RUN=${RUN:-$W/perf/launch-$(date -u +%Y%m%dT%H%M%SZ)}
WARM=${WARM:-8}; COLD=${COLD:-5}; IDLE_WARM=${IDLE_WARM:-20}; IDLE_COLD=${IDLE_COLD:-10}
mkdir -p $RUN/{backup,raw,swift-agent-state,swift-agent-tmp,rust-agent-home,rust-agent-project,rust-box-config}
exec > >(tee -a $RUN/run.log) 2>&1
echo "run=$RUN start=$(date -u +%FT%TZ)"

SWIFT_AGENT="$W/swift-apps/agent/Bello Agent.app/Contents/MacOS/Bello Agent"
SWIFT_BOX="$W/swift-apps/box/Bello Box.app/Contents/MacOS/Bello Box"
RUST_AGENT=$W/target/release/bello-agent
RUST_BOX=$W/target/release/bellobox
for exe in "$SWIFT_AGENT" "$SWIFT_BOX" $RUST_AGENT $RUST_BOX; do shasum -a 256 "$exe"; done | tee $RUN/binaries.sha256
git -C ~/projects/pi-app-rust rev-parse HEAD > $RUN/agent-rust-commit
git -C ~/projects/BelloBox-rust rev-parse HEAD > $RUN/box-rust-commit

# Backups of global Swift app state that launching can change.
defaults export com.belloware.PiApp $RUN/backup/com.belloware.PiApp.plist
defaults export com.ainoob.BelloBox $RUN/backup/com.ainoob.BelloBox.plist
for d in HTTPStorages/com.belloware.PiApp HTTPStorages/com.ainoob.BelloBox Caches/com.belloware.PiApp; do
  [ -e "$HOME/Library/$d" ] && ditto "$HOME/Library/$d" "$RUN/backup/$(echo $d | tr / _)"
done
restore() {
  echo "restoring prefs/caches $(date -u +%FT%TZ)"
  pkill -x "Bello Agent" 2>/dev/null; pkill -x "Bello Box" 2>/dev/null; sleep 1
  for dom in com.belloware.PiApp com.ainoob.BelloBox; do
    defaults delete $dom >/dev/null 2>&1; defaults import $dom $RUN/backup/$dom.plist
    defaults export $dom $RUN/backup/$dom.after-restore.plist
    python3 -I -c "import plistlib,sys; a=plistlib.load(open(sys.argv[1],'rb')); b=plistlib.load(open(sys.argv[2],'rb')); print('restored', sys.argv[3] + ':', 'semantically identical' if a==b else 'DIFFERS')" $RUN/backup/$dom.plist $RUN/backup/$dom.after-restore.plist $dom
  done
  for d in HTTPStorages/com.belloware.PiApp HTTPStorages/com.ainoob.BelloBox Caches/com.belloware.PiApp; do
    b="$RUN/backup/$(echo $d | tr / _)"
    if [ -e "$b" ]; then rm -rf "$HOME/Library/$d"; ditto "$b" "$HOME/Library/$d"; echo "restored $d"; fi
  done
}
trap restore EXIT

ps -Ao pid,pcpu,comm -r | head -8 > $RUN/load-before.txt
launch() { # label exe-and-args... (env via LENV array)
  local label=$1 kind=$2 idx=$3 cold=$4 idle=$5; shift 5
  local coldflag=(); [ $cold = 1 ] && coldflag=(--cold)
  $P launch --label $label --trials 1 --prime 0 --idle $idle "${coldflag[@]}" "${LENV[@]}" --out $RUN/raw/$label-$kind-$idx.json -- "$@" | grep -E 'trial|SUMMARY' | sed -E 's/idleSamples[^]]*\]\]//'
}
sa() { LENV=(--env PI_APP_BENCHMARK_OUTPUT=$RUN/raw/swift-agent-probe-$2-$3.json --env PI_APP_BENCHMARK_STATE_ROOT=$RUN/swift-agent-state --env PI_APP_SCRATCH_ROOT=$RUN/swift-agent-tmp); launch swift-agent $2 $3 $4 $5 "$SWIFT_AGENT"; }
ra() { LENV=(--env HOME=$RUN/rust-agent-home --cwd $RUN/rust-agent-project); launch rust-agent $2 $3 $4 $5 $RUST_AGENT --project $RUN/rust-agent-project; }
SB_PROFILE=$W/harness/no-keychain.sb
sb() { LENV=(); launch swift-box $2 $3 $4 $5 /usr/bin/sandbox-exec -f $SB_PROFILE "$SWIFT_BOX"; }
rbs() { LENV=(--env BELLOBOX_CONFIG_DIR=$RUN/rust-box-config); launch rust-box-sandboxed $2 $3 $4 $5 /usr/bin/sandbox-exec -f $SB_PROFILE $RUST_BOX; }
security_dialog_check() {
  local sa=$(pgrep -x SecurityAgent)
  [ -z "$sa" ] && return 0
  if $W/harness/winlist2 $sa | grep -q 'onscreen=1'; then echo "SECURITY DIALOG VISIBLE after $1; stopping run"; exit 3; fi
}
rb() { LENV=(--env BELLOBOX_CONFIG_DIR=$RUN/rust-box-config); launch rust-box $2 $3 $4 $5 $RUST_BOX; }

echo "== priming (unmeasured first launches)"
for f in sa ra sb rb rbs; do $f x prime 0 0 1; security_dialog_check $f; done
echo "== warm, interleaved x$WARM"
for ((i=1; i<=WARM; i++)); do
  if [ $((i % 2)) = 1 ]; then order=(sa ra sb rb rbs); else order=(ra sa rbs rb sb); fi
  for f in $order; do $f x warm $i 0 $IDLE_WARM; security_dialog_check $f; done
done
echo "== cold (sudo purge before each), interleaved x$COLD"
for ((i=1; i<=COLD; i++)); do
  if [ $((i % 2)) = 1 ]; then order=(sa ra sb rb); else order=(ra sa rb sb); fi
  for f in $order; do $f x cold $i 1 $IDLE_COLD; security_dialog_check $f; done
done
ps -Ao pid,pcpu,comm -r | head -8 > $RUN/load-after.txt
echo "done $(date -u +%FT%TZ)"
