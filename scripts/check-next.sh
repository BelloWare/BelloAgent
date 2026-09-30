#!/usr/bin/env bash
# Check dev/next, for the machine that can run code.
#
# The next release is developed on one branch, dev/next (see NEXT-RELEASE.md).
# An agent that writes code but cannot run it pushes there; this script, run on
# the owner's Mac, brings a dedicated worktree up to date with it and builds and
# tests it. The worktree and build products live under ~/Library/Caches, not
# /private/tmp, so they survive a restart and never touch the main checkout.
#
#   scripts/check-next.sh             pull, build the helper bundle, the app and its tests
#   scripts/check-next.sh test A B    the same, then run test classes A and B
#                                      (serial-lane classes: run them one per call)
#   scripts/check-next.sh helper      the same, then the helper suite and the wire scripts
#   scripts/check-next.sh gate        the same, then the whole release gate
#                                      (scripts/verify-release.sh; run it alone)
#   PI_NEXT_REF=dev/next scripts/check-next.sh ...
#                                    check local committed work without fetching
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
HOME_DIR="$HOME/Library/Caches/BelloAgentNext"
WT="$HOME_DIR/worktree"
export PI_BUILD_ROOT="$HOME_DIR/build"
LOGS="$HOME_DIR/logs"
mkdir -p "$PI_BUILD_ROOT" "$LOGS"

CHECK_REF=${PI_NEXT_REF:-origin/dev/next}
if [ -z "${PI_NEXT_REF:-}" ]; then
  git -C "$REPO" fetch -q origin || { echo "fetch failed"; exit 1; }
fi
# Resolve once: all builds and tests in this call check the same commit,
# even if development advances the local branch while the check runs.
CHECK_COMMIT=$(git -C "$REPO" rev-parse --verify --end-of-options "$CHECK_REF^{commit}") || { echo "Unknown check ref: $CHECK_REF"; exit 1; }
if [ ! -d "$WT/.git" ] && [ ! -f "$WT/.git" ]; then
  git -C "$REPO" worktree prune
  git -C "$REPO" worktree add -q --detach "$WT" "$CHECK_COMMIT" || exit 1
fi
cd "$WT" || exit 1
if [ -n "$(git status --porcelain)" ]; then
  echo "The check worktree has local changes; not touching them:"; git status --short; exit 1
fi
git checkout -q --detach "$CHECK_COMMIT" || exit 1
echo "$CHECK_REF at $(git log --oneline -1)"

python3 scripts/build-bundle.py > "$LOGS/bundle.log" 2>&1 || { echo "BUNDLE FAILED ($LOGS/bundle.log)"; tail -20 "$LOGS/bundle.log"; exit 1; }
xcodegen generate --quiet > "$LOGS/xcodegen.log" 2>&1 || { echo "XCODEGEN FAILED"; exit 1; }
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -quiet > "$LOGS/build.log" 2>&1
if [ $? -ne 0 ]; then echo "BUILD FAILED ($LOGS/build.log)"; grep -E "error:" "$LOGS/build.log" | sort -u | head -30; exit 1; fi
echo "build OK"

mode=${1:-build}; shift || true
case "$mode" in
  build) ;;
  test)
    args=(); for t in "$@"; do args+=("-only-testing:PiAppTests/$t"); done
    xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$PI_BUILD_ROOT/native" CODE_SIGNING_ALLOWED=NO "${args[@]}" > "$LOGS/test.log" 2>&1
    status=$?
    grep -E "Test Case .*failed|error: -\[" "$LOGS/test.log" | head -30
    grep -E "Executed [0-9]+ tests" "$LOGS/test.log" | tail -1
    exit $status ;;
  helper)
    swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" > "$LOGS/helper.log" 2>&1; h=$?
    grep -E "error:|Executed [0-9]+ tests" "$LOGS/helper.log" | tail -3
    swift test --package-path packages/bello-views --scratch-path "$PI_BUILD_ROOT/bello-views" > "$LOGS/views.log" 2>&1; v=$?
    grep -E "error:|Executed [0-9]+ tests" "$LOGS/views.log" | tail -2
    HOST="$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"; w=0
    for script in test-native-host.py test-concurrent-native-host.py test-native-acceptance.py; do
      python3 "scripts/$script" "$HOST" > "$LOGS/$script.log" 2>&1 || w=1
      echo "$script: $(grep -E '^(Ran|OK|FAILED)' "$LOGS/$script.log" | tr '\n' ' ')"
    done
    exit $(( h || v || w )) ;;
  gate) bash scripts/verify-release.sh ;;
  *) echo "unknown mode: $mode"; exit 2 ;;
esac
