#!/usr/bin/env bash
# Runs the transcript performance measurements against one Release
# build-for-testing, through its .xctestrun so the sources may move on.
# Usage: run-perf.sh <derived-data> <out-dir> [rounds] [soak-seconds] [max-load]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD=$1 OUT=$2 ROUNDS=${3:-3} SOAK=${4:-122} MAXLOAD=${5:-4}
[[ "$DD" = /* ]] || DD="$PWD/$DD"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
mkdir -p "$OUT" || exit 1
cd "$OUT" || exit 1
STATUS=0
RUN=$(ls "$DD"/Build/Products/*.xctestrun | head -1)
# Old build-for-testing products hosted tests in the shipping app. Never
# execute those, even when the source checkout has since gained isolation.
python3 "$ROOT/scripts/check-test-host.py" "$RUN" || exit 1
X=(-xctestrun "$RUN" -destination 'platform=macOS,arch=arm64')
quiet() { # waits until the one-minute load is below MAXLOAD
  while :; do l=$(sysctl -n vm.loadavg | awk '{print $2}'); awk -v l="$l" -v m="$MAXLOAD" 'BEGIN{exit !(l<m)}' && return; sleep 20; done
}
run() { # name, env..., -- tests...
  local name=$1; shift
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  local only=(); for t in "$@"; do only+=("-only-testing:PiAppTests/$t"); done
  for r in $(seq 1 "$ROUNDS"); do
    local log="$OUT/$name-$r.log"
    quiet
    echo "== $name round $r, load $(sysctl -n vm.loadavg)" | tee -a "$OUT/load.txt"
    env "${envs[@]}" xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO "${only[@]}" > "$log" 2>&1
    local status=$?
    if [ "$STATUS" -eq 0 ] && [ "$status" -ne 0 ]; then STATUS=$status; fi
    echo "   exit $status $(grep -E 'Executed [0-9]+ tests' "$log" | tail -1)" | tee -a "$OUT/load.txt"
  done
}
[ -z "${ONLY:-}" ] || [ "$ONLY" = probe ] && run probe TEST_RUNNER_PI_REDRAW_PROBE=1 PI_REDRAW_PROBE=1 -- \
  RedrawCostProbeTests/testWhatAChatSwitchCosts RedrawCostProbeTests/testWhatTypingCosts \
  RedrawCostProbeTests/testWhatAStreamedReplyCosts RedrawCostProbeTests/testWhatAFirstOpenCosts
[ -z "${ONLY:-}" ] || [ "$ONLY" = budget ] && run budget X=1 -- \
  TranscriptFrameBudgetTests/testWhereOpeningALongChatSpendsItsTime TranscriptFrameBudgetTests/testWhereAStreamingDeltaSpendsItsTime \
  TranscriptSwitchBudgetTests/testSwitchingBetweenTwoLongChats TranscriptScrollBudgetTests/testScrollingATwoThousandRowPageKeepsUpWithTheDisplay \
  TranscriptFrameBudgetTests/testWhereFoldingSixtyToolCallsSpendsItsTime
[ -z "${ONLY:-}" ] || [ "$ONLY" = scroll ] && run scroll X=1 -- NativeTranscriptScrollingPerformanceTests
[ -z "${ONLY:-}" ] || [ "$ONLY" = baseline ] && run baseline X=1 -- PerformanceBaselineTests/testOpeningALongChatAndStreamingDeltaBaselines PerformanceBaselineTests/testEditingAnEarlyMessageInALongChatBaseline
if [ "$SOAK" -gt 0 ] && { [ -z "${ONLY:-}" ] || [ "$ONLY" = soak ]; }; then
  run soak TEST_RUNNER_PI_SOAK_SECONDS=$SOAK TEST_RUNNER_PI_SOAK_SWITCHES=1 TEST_RUNNER_PI_SOAK_SEED=1790822043708 -- SoakTests
  ROUNDS=1 run soakdraw TEST_RUNNER_PI_SOAK_SECONDS=60 TEST_RUNNER_PI_SOAK_SWITCHES=1 TEST_RUNNER_PI_SOAK_DRAW_REPORT=1 TEST_RUNNER_PI_SOAK_SEED=1790822043708 -- SoakTests
fi
grep -hE "^(PERF|REDRAW|SWITCH|TYPING|KEPT|SCROLL PERF|SCROLL PERCENTILES|SOAK|DRAW)" "$OUT"/*.log > "$OUT/lines.txt" || true
echo done
exit "$STATUS"
