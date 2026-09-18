#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Pass a complete built Bello Agent.app}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Zhaofeng Wang (43TXHV3TM3)}"
ENTITLEMENTS="$ROOT/apps/macos/PiApp/PiApp.entitlements"
# Fail before changing any nested signatures if an old profile-based build was
# staged. The ordinary login Keychain needs no provisioning profile.
python3 "$ROOT/scripts/release_signing.py" preflight "$APP" --entitlements "$ENTITLEMENTS"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_runtime() { SIGN_IDENTITY="$IDENTITY" python3 "$ROOT/scripts/release_signing.py" sign "$@"; }
sign_runtime "$FRAMEWORK/XPCServices/Downloader.xpc"
sign_runtime "$FRAMEWORK/XPCServices/Installer.xpc"
sign_runtime "$FRAMEWORK/Autoupdate"
sign_runtime "$FRAMEWORK/Updater.app"
SIGN_IDENTITY="$IDENTITY" python3 "$ROOT/scripts/release_signing.py" sign "$FRAMEWORK" --no-runtime
SIGN_IDENTITY="$IDENTITY" python3 "$ROOT/scripts/sign-host.py" "$APP"
sign_runtime "$APP" --entitlements "$ENTITLEMENTS"
python3 "$ROOT/scripts/release_signing.py" validate-app "$APP"
