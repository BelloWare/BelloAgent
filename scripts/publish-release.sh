#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PI_BUILD_ROOT:?Set PI_BUILD_ROOT to the scratch directory used for the release}"
VERSION="${1:?Usage: publish-release.sh VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
SITE="${BELLOWARE_SITE_ROOT:-$ROOT/../belloware.com}"
RELEASE="$PI_BUILD_ROOT/releases/$VERSION"
DMG_NAME="BelloAgent-$VERSION.dmg"
FEED_NAME="bello_agent.appcast.xml"
LEGACY_FEED_NAME="pi_app.appcast.xml"
DOWNLOAD_PREFIX="${PI_DOWNLOAD_URL_PREFIX:-https://belloware.com/assets/}"

# Publish only committed source: no uncommitted or untracked file may differ
# from the released commit. The standing workflow pushes source before
# publication and pushes the final validation record and tag afterward.
# This script publishes the website repository, which must be in sync since
# pushing it is how the site deploys. See AGENTS.md and docs/Release.md.
test -z "$(git -C "$ROOT" status --porcelain)"
git -C "$ROOT" rev-parse --verify --quiet HEAD >/dev/null
SITE_UPSTREAM="$(git -C "$SITE" rev-parse --abbrev-ref '@{upstream}')"
# Keep a publication commit free of unrelated work. Do not reset or stash it.
test -z "$(git -C "$SITE" status --porcelain)"
git -C "$SITE" fetch
test "$(git -C "$SITE" rev-parse HEAD)" = "$(git -C "$SITE" rev-parse "$SITE_UPSTREAM")"
test ! -e "$SITE/assets/$DMG_NAME"
PREVIOUS="$(python3 - "$SITE/assets/$FEED_NAME" "$SITE/assets/$LEGACY_FEED_NAME" <<'PY'
from pathlib import Path
import sys, xml.etree.ElementTree as ET
builds = [0]
for name in sys.argv[1:]:
    path = Path(name)
    if path.is_symlink():
        raise SystemExit('Website update feeds must not be symbolic links')
    if path.exists():
        versions = ET.parse(path).findall('./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
        if not versions:
            raise SystemExit('Existing update feed has no build number')
        builds.extend(int(version.text) for version in versions)
print(max(builds))
PY
)"
python3 "$ROOT/scripts/validate-release.py" "$RELEASE/$FEED_NAME" \
  "$RELEASE/$DMG_NAME" "$RELEASE/Bello Agent.app" --previous-build "$PREVIOUS" --download-url-prefix "$DOWNLOAD_PREFIX"
# Validate product/discovery inputs and the native size target before copying
# any installer or feed into the website working tree.
python3 "$ROOT/scripts/stage-release-site.py" "$RELEASE" "$SITE" --download-url-prefix "$DOWNLOAD_PREFIX" --check-only
if [[ "$DOWNLOAD_PREFIX" == "https://belloware.com/assets/" ]]; then
python3 - "$RELEASE/$DMG_NAME" <<'PY'
from pathlib import Path
import sys
if Path(sys.argv[1]).stat().st_size > 25 * 1024 * 1024:
    raise SystemExit('Installer exceeds Cloudflare static assets\' 25 MiB limit. Upload it to an approved large-binary host and configure/verify that enclosure URL before publishing the appcast. No website files were changed.')
PY
ditto "$RELEASE/$DMG_NAME" "$SITE/assets/$DMG_NAME"
else
  # The owner-selected binary must already be publicly downloadable, complete,
  # and signature-valid before the website can advertise it.
  VERIFY="$(mktemp -d "$PI_BUILD_ROOT/verify-download.XXXXXX")"
  python3 "$ROOT/scripts/verify-published.py" "$RELEASE" "$VERIFY" \
    --archive-only --download-url-prefix "$DOWNLOAD_PREFIX"
fi
python3 "$ROOT/scripts/stage-release-site.py" "$RELEASE" "$SITE" --download-url-prefix "$DOWNLOAD_PREFIX"
git -C "$SITE" add -- "assets/$FEED_NAME" "assets/$LEGACY_FEED_NAME"
git -C "$SITE" add -- bello-agent.html pi-app.html index.html sitemap.xml assets/bello_agent_icon.png
if [[ "$DOWNLOAD_PREFIX" == "https://belloware.com/assets/" ]]; then git -C "$SITE" add -- "assets/$DMG_NAME"; fi
git -C "$SITE" diff --cached --check
git -C "$SITE" commit -m "Publish Bello Agent $VERSION update"
git -C "$SITE" push
printf 'Publication committed and pushed. Verify the live feed and archive with scripts/verify-published.py.\n'
