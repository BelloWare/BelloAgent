#!/usr/bin/env bash
# The release gate in one command: the helper bundle, the Debug build, the
# whole native suite, then the screenshot gallery alongside the helper, wire
# and script tests.
#
# The suite runs alone because its frame and latency budgets measure wall
# time. The gallery and the helper checks assert no timings and their
# gateways bind ephemeral ports, so they share the machine, which hides the
# helper checks' three minutes behind the gallery. A failing check does not
# stop the later ones, so one pass reports every failure; the exit status is
# non-zero if anything failed. Run it alone: nothing else should build or
# test on the machine while the suite measures.
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to a scratch directory outside the repository}"
cd "$ROOT"
DD="$PI_BUILD_ROOT/native-verify"
SWIFT_TESTS="$PI_BUILD_ROOT/swift-verify"
HOST="$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host"
LOGS="$PI_BUILD_ROOT/verify-logs"
# The host rejects sessions under /private/tmp, so the gallery takes the
# /tmp spelling of the same folder.
GALLERY="$PI_BUILD_ROOT/verify-gallery"
case "$GALLERY" in /private/tmp/*) GALLERY="${GALLERY#/private}" ;; esac
XCODE=(-project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64'
       -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO)
rm -rf "$LOGS" "$GALLERY"; mkdir -p "$LOGS" "$GALLERY"
failed=""
began=$SECONDS

stamp() { printf '%s %-10s %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
check() { # check NAME COMMAND...: output goes to $LOGS/NAME.log
  local name=$1; shift
  "$@" > "$LOGS/$name.log" 2>&1 || { failed="$failed $name"; return 1; }
}
summary() { grep -hE "Executed [0-9]+ tests?|^Ran [0-9]+ tests" "$LOGS/$1.log" 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]+//'; }
failures() { grep -hE "Test Case '.*' failed" "$LOGS/$1.log" 2>/dev/null |
  sed -E "s/.*\[[A-Za-z]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\].*/           failed \1.\2/" | sort -u; }

# A stale project silently leaves new test files out of the run.
xcodegen generate --quiet > "$LOGS/xcodegen.log" 2>&1 || { stamp project "xcodegen failed, see $LOGS/xcodegen.log"; exit 1; }
if ! git diff --quiet -- PiApp.xcodeproj; then
  stamp project "PiApp.xcodeproj did not match project.yml; commit the regenerated project and rerun"; exit 1
fi

stamp build "helper bundle"
check bundle python3 scripts/build-bundle.py || { stamp build "FAILED, see $LOGS/bundle.log"; exit 1; }
stamp build "app and tests (Debug)"
if ! check build xcodebuild build-for-testing "${XCODE[@]}" COMPILER_INDEX_STORE_ENABLE=NO; then
  grep -E "error:" "$LOGS/build.log" | sort -u | head -20
  stamp build "FAILED, see $LOGS/build.log"; exit 1
fi
stamp build "helper tests"
check helper-build swift build --package-path packages/swift-host --scratch-path "$SWIFT_TESTS" --build-tests

stamp suite "whole native suite, alone"
check suite xcodebuild test-without-building "${XCODE[@]}"
stamp suite "$(summary suite)"; failures suite
rm -rf "$DD"/Logs/Test/*.xcresult

stamp gallery "gallery, with the helper checks alongside"
PI_APP_UI_SCREENSHOT_ROOT="$GALLERY" TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$GALLERY" \
  xcodebuild test-without-building "${XCODE[@]}" -only-testing:PiAppTests/UIScreenshotTests > "$LOGS/gallery.log" 2>&1 &
gallery=$!
case " $failed " in
  *" helper-build "*) ;;
  *) check helper swift test --package-path packages/swift-host --scratch-path "$SWIFT_TESTS" --skip-build ;;
esac
check wire python3 scripts/test-native-host.py "$HOST"
check concurrent python3 scripts/test-concurrent-native-host.py "$HOST"
check acceptance python3 scripts/test-native-acceptance.py "$HOST"
check python python3 -m unittest discover -s scripts/tests
wait $gallery || failed="$failed gallery"
rm -rf "$DD"/Logs/Test/*.xcresult
stamp gallery "$(summary gallery); $(ls "$GALLERY/screenshots" 2>/dev/null | wc -l | tr -d ' ') screenshots in $GALLERY/screenshots"
failures gallery
for name in helper wire concurrent acceptance python; do
  [ -f "$LOGS/$name.log" ] && stamp "$name" "$(summary $name)"
done
failures helper

elapsed=$((SECONDS - began))
took="$((elapsed / 60)) min $((elapsed % 60)) s"
if [ -z "$failed" ]; then
  stamp done "all passed in $took; logs in $LOGS"
else
  stamp done "FAILED:$failed ($took); logs in $LOGS"
  exit 1
fi
