#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to a scratch directory outside the repository}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Zhaofeng Wang (43TXHV3TM3)}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-$ROOT/../BelloWallProfiles/AuthKey_SSYSS59Z5W.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-SSYSS59Z5W}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-ed7b7d3d-c846-4e12-a37d-f216553dc5bb}"
DOWNLOAD_PREFIX="${PI_DOWNLOAD_URL_PREFIX:-https://belloware.com/assets/}"
PYTHONPATH="$ROOT/scripts" python3 -c 'from release_download import validate_prefix; import sys; validate_prefix(sys.argv[1])' "$DOWNLOAD_PREFIX"
test -f "$NOTARY_KEY_PATH"
test "$(xcodebuild -version | head -1)" = "Xcode 16.1"
mkdir -p "$PI_BUILD_ROOT"
WORK="$(mktemp -d "$PI_BUILD_ROOT/release.XXXXXX")"
cd "$ROOT"
python3 scripts/build-bundle.py
xcodegen generate
xcodebuild build -project PiApp.xcodeproj -scheme PiApp -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/native-release" \
  CODE_SIGNING_ALLOWED=NO >"$WORK/build.log" 2>&1
APP="$WORK/Bello Agent.app"
ditto "$PI_BUILD_ROOT/native-release/Build/Products/Release/Bello Agent.app" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
OUT="$PI_BUILD_ROOT/releases/$VERSION"
if [[ -e "$OUT" ]]; then
  echo "Release directory already exists: $OUT; choose a new version or scratch root." >&2
  exit 1
fi
mkdir -p "$OUT"
SPARKLE="$PI_BUILD_ROOT/native-release/SourcePackages/artifacts/sparkle/Sparkle"
test -x "$SPARKLE/bin/generate_appcast"
# Ship stripped binaries, before signing so the signature covers the stripped
# files. Their dSYMs stay beside the artifacts for crash symbolication.
ditto "$PI_BUILD_ROOT/native-release/Build/Products/Release/Bello Agent.app.dSYM" "$OUT/Bello Agent.app.dSYM"
ditto "$PI_BUILD_ROOT/pi-native-host.dSYM" "$OUT/pi-native-host.dSYM"
xcrun strip "$APP/Contents/MacOS/Bello Agent"
xcrun strip "$APP/Contents/Helpers/pi-native-host"
SIGN_IDENTITY="$IDENTITY" bash "$ROOT/scripts/sign-app.sh" "$APP"
python3 "$ROOT/scripts/smoke-native-bundle.py" "$APP" >"$WORK/host-proof.json"

# Notarize/staple the application too, so Finder extraction retains its ticket.
ditto -c -k --keepParent "$APP" "$WORK/BelloAgent.zip"
xcrun notarytool submit "$WORK/BelloAgent.zip" --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait >"$WORK/notary-app.log" 2>&1
cat "$WORK/notary-app.log"
xcrun stapler staple "$APP"
spctl -a -t exec -v "$APP"

mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Bello Agent.app"
ln -s /Applications "$WORK/dmg/Applications"
DMG="$OUT/BelloAgent-$VERSION.dmg"
hdiutil create -srcfolder "$WORK/dmg" -volname "Bello Agent $VERSION" -fs APFS -format ULFO "$DMG"
SIGN_IDENTITY="$IDENTITY" python3 "$ROOT/scripts/release_signing.py" sign "$DMG" --no-runtime
xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait >"$WORK/notary-dmg.log" 2>&1
cat "$WORK/notary-dmg.log"
xcrun stapler staple "$DMG"

# Only a fresh, single-release directory reaches generate_appcast. Never export keys.
mkdir "$WORK/feed"
ditto "$DMG" "$WORK/feed/$(basename "$DMG")"
cp "$ROOT/releases/$VERSION.html" "$WORK/feed/BelloAgent-$VERSION.html"
"$SPARKLE/bin/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-deltas 0 --embed-release-notes -o "$OUT/bello_agent.appcast.xml" "$WORK/feed"
python3 "$ROOT/scripts/validate-release.py" "$OUT/bello_agent.appcast.xml" "$DMG" "$APP" --download-url-prefix "$DOWNLOAD_PREFIX"
cp "$OUT/bello_agent.appcast.xml" "$OUT/pi_app.appcast.xml"
ditto "$APP" "$OUT/Bello Agent.app"
shasum -a 256 "$DMG" >"$OUT/SHA256SUMS"
printf 'Validated release: %s (%s)\nArtifacts: %s\nLogs: %s\n' "$VERSION" "$BUILD" "$OUT" "$WORK"
