#!/usr/bin/env bash
# Launch to a settled window, over synthetic data only (docs/perf/launch-0.1.123.md).
#
#   scripts/perf-launch.sh <fixture> <out> <label>=<app> [<label>=<app> ...]
#
# <fixture>  a folder from LaunchFixtureWriter (PI_APP_LAUNCH_FIXTURE),
#            "settled" in place by one launch and quit of the app first, so
#            the request archive and search index exist as on a reader's Mac.
# <app>      a Release build made with
#            SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PI_LAUNCH_FIXTURE':
#            it reads the fixture's vault.json and never the Keychain. Each app
#            is copied and given the bundle id com.belloware.PiApp.launchperf,
#            so its preferences never touch the reader's com.belloware.PiApp.
# BELLOPERF  the belloperf harness binary (Rust port's validation harness,
#            rust/docs/validation/swift-rust-performance-2026-10-10/harness).
# WARM, COLD trials per app (default 8 and 5); cold runs `sudo -n purge` first.
#
# Every trial starts from a fresh copy of the fixture's state, with all home
# roots and scratch storage pointing into it; trials alternate between apps.
# Results: <out>/raw/<label>-<warm|cold>-<n>.json; summarize with the
# harness's analyze-launch.py <out>.
set -euo pipefail
FIXTURE=$(cd "$1" && pwd) OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift 2
# The fixture's records name its journals and projects by absolute path, and
# its search index keys each journal by path and file identity: a copied
# journal would be indexed again in full at every launch. So each trial gets
# its own copy of the state, and reads the fixture's own journals, which a
# launch only reads (checked below). A fixture that moved is rebased once with
# rebase-launch-fixture.py and settled again by one launch.
[ "$(cat "$FIXTURE/fixture-root")" = "$FIXTURE" ] || { echo "$FIXTURE moved from $(cat "$FIXTURE/fixture-root"): rebase and settle it first" >&2; exit 1; }
journals() { find "$FIXTURE/home" -name '*.jsonl' -exec stat -f '%N %m %z' {} + | sort; }
before_journals=$(journals)
: "${BELLOPERF:?Set BELLOPERF to the belloperf binary}"
WARM=${WARM:-8} COLD=${COLD:-5} IDLE=${IDLE:-2}
DOMAIN=com.belloware.PiApp.launchperf
mkdir -p "$OUT/raw" "$OUT/apps"
FIXTURE_PREFS="$FIXTURE/home/Library/Preferences/$DOMAIN.plist"
before_preferences=$(stat -f %m "$FIXTURE_PREFS" 2>/dev/null || echo none)
labels=() exes=()
for spec in "$@"; do
  label=${spec%%=*} app=${spec#*=}
  rm -rf "$OUT/apps/$label"; mkdir -p "$OUT/apps/$label"
  ditto "$app" "$OUT/apps/$label/LaunchProbe-$label.app"
  plist="$OUT/apps/$label/LaunchProbe-$label.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" -c "Set :CFBundleName LaunchProbe-$label" "$plist"
  labels+=("$label"); exes+=("$OUT/apps/$label/LaunchProbe-$label.app/Contents/MacOS/Bello Agent")
done
trial() { # label exe kind index
  local run="$OUT/run"
  rm -rf "$run"; ditto "$FIXTURE" "$run"
  mkdir -p "$run/home/.codex" "$run/tmp"
  rm -f "$run/home/Library/Preferences/$DOMAIN.plist"
  local cold=(); [ "$3" = cold ] && cold=(--cold)
  env -u PI_APP_BENCHMARK_STATE_ROOT -u PI_APP_BENCHMARK_OUTPUT -u BELLO_CONTEXT_DIAGNOSTICS \
    HOME="$run/home" CFFIXED_USER_HOME="$run/home" CODEX_HOME="$run/home/.codex" \
    TMPDIR="$run/tmp" PI_APP_SCRATCH_ROOT="$run/tmp" \
    "$BELLOPERF" launch --label "$1" --trials 1 --prime 0 --idle "$IDLE" ${cold[@]+"${cold[@]}"} \
    --env HOME="$run/home" --env CFFIXED_USER_HOME="$run/home" --env CODEX_HOME="$run/home/.codex" \
    --env TMPDIR="$run/tmp" --env PI_APP_SCRATCH_ROOT="$run/tmp" --env PI_APP_LAUNCH_FIXTURE_VAULT="$run/vault.json" \
    --out "$OUT/raw/$1-$3-$4.json" -- "$2" | grep -E '^'"$1"' trial' | grep -oE '"(windowMs|settledMs)": [0-9.]+' | tr '\n' ' '
  echo " load $(sysctl -n vm.loadavg)"
}
echo "priming"; for i in "${!labels[@]}"; do trial "${labels[$i]}" "${exes[$i]}" prime 0 >/dev/null; done
for kind in warm cold; do
  count=$WARM; [ $kind = cold ] && count=$COLD
  for ((n = 1; n <= count; n++)); do
    order=("${!labels[@]}"); [ $((n % 2)) = 0 ] && order=($(printf '%s\n' "${!labels[@]}" | sort -rn))
    for i in "${order[@]}"; do printf '%s %s %d: ' "${labels[$i]}" $kind $n; trial "${labels[$i]}" "${exes[$i]}" $kind $n; done
  done
done
rm -rf "$OUT/run" "$OUT/raw/"*-prime-*.json
[ "$(journals)" = "$before_journals" ] || echo "WARNING: a fixture journal changed during the run" >&2
[ "$(stat -f %m "$FIXTURE_PREFS" 2>/dev/null || echo none)" = "$before_preferences" ] || echo "WARNING: fixture preferences changed during the run" >&2
