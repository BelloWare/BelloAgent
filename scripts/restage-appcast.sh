#!/usr/bin/env bash
# Change the staged download destination without rebuilding or changing the DMG.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to the release scratch directory}"
: "${PI_DOWNLOAD_URL_PREFIX:?Set an owner-selected HTTPS download directory}"
VERSION="${1:?Usage: restage-appcast.sh VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
PYTHONPATH="$ROOT/scripts" python3 -c 'from release_download import validate_prefix; import sys; validate_prefix(sys.argv[1])' "$PI_DOWNLOAD_URL_PREFIX"
RELEASE="$PI_BUILD_ROOT/releases/$VERSION"
WORK="$(mktemp -d "$PI_BUILD_ROOT/restage-feed.XXXXXX")"
mkdir "$WORK/feed"
ditto "$RELEASE/BelloAgent-$VERSION.dmg" "$WORK/feed/BelloAgent-$VERSION.dmg"
cp "$ROOT/releases/$VERSION.html" "$WORK/feed/BelloAgent-$VERSION.html"
"$PI_BUILD_ROOT/native-release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "$PI_DOWNLOAD_URL_PREFIX" --maximum-deltas 0 --embed-release-notes \
  -o "$WORK/bello_agent.appcast.xml" "$WORK/feed"
python3 "$ROOT/scripts/validate-release.py" "$WORK/bello_agent.appcast.xml" \
  "$RELEASE/BelloAgent-$VERSION.dmg" "$RELEASE/Bello Agent.app" --download-url-prefix "$PI_DOWNLOAD_URL_PREFIX"
mv "$WORK/bello_agent.appcast.xml" "$RELEASE/bello_agent.appcast.xml"
cp "$RELEASE/bello_agent.appcast.xml" "$RELEASE/pi_app.appcast.xml"
printf 'Staged appcast destination updated. Installer bytes are unchanged; publication still requires a verified public download.\n'
