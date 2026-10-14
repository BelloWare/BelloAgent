#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to a scratch directory outside the repository}"
cd "$ROOT"
python3 scripts/build-bundle.py
xcodegen generate
status=0
# No index store: nothing reads it in a test build, and it costs disk and time.
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  "$@" || status=$?
# Keep only the newest result bundle (tens of MB each); the console output is
# the record. PI_KEEP_RESULTS=1 keeps them all.
if [ "${PI_KEEP_RESULTS:-0}" != 1 ]; then
  ls -dt "$PI_BUILD_ROOT"/native-tests/Logs/Test/*.xcresult 2>/dev/null | tail -n +2 | while IFS= read -r bundle; do rm -rf "$bundle"; done || true
fi
exit "$status"
