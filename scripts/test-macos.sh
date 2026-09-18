#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to a scratch directory outside the repository}"
cd "$ROOT"
python3 scripts/build-bundle.py
xcodegen generate
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  "$@"
