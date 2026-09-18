# Bello Agent 0.1.7 acceptance

Date: 2026-09-16. Branch: `master`. Release source:
`bd6a5559fa5d52a647f997d9084cf9fbd7001c18`. Version **0.1.7/build 11**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 06:36:37 UTC.**

## Reviewed changes

- `8ba5f2c`: the visible session picker loads its saved connection's catalog
  without requiring hover, including keyboard access. Saved profile changes
  reload the appropriate catalog; other connections are not prefetched. The
  configured catalog remains the sole source, with anonymous external fetches,
  shared cache/in-flight behavior and no gateway fallback. Models after the
  first 80 remain selectable in bounded menu pages; manual aliases remain.
- `6539aa4`: new chats remember the last deliberately selected model, reasoning
  effort and catalog limits per connection across projects and restarts.
  Explicit profile defaults remain distinct from model-default effort. Chat
  and defaults commit atomically, pending picker saves finish before New Chat,
  and failed persistence preserves the prior choices. Existing chats and shared
  connection defaults stay unchanged; sides and forks still inherit their
  parent. Review also guarded against applying a completed save to a replacement
  side pane.
- Claude's `0b3c255` retains every conflicting gateway model name and exposes
  the names through request details. Its final turn ended at
  `2026-09-16T06:23:50.945Z`, with no remaining child work. Independent review
  found no blockers; Dashboard and MenuBarMetrics regressions pass. No additional
  interactive reveal-gesture check is claimed.
- `888e05b` and `bd6a555` prepare the 0.1.7/build 11 release. The selected flat
  icon, bundle ID, history paths, ordinary single-item Keychain vault and Sparkle
  key remain unchanged. SwiftUI/AppKit composers, React/WKWebView transcript and
  the self-contained Swift helper remain selected; Node is build-only.

## Focused acceptance

| Native suite | Final passing evidence |
| --- | --- |
| GatewayModelDiscovery | 9 passed, 1.051 seconds |
| ModelCatalogEndpoint | 12 passed, 1.112 seconds |
| ProjectSidebar | 6 passed, 0.179 seconds |
| Workspace | 14 passed, 0.341 seconds |
| ModelSwitch | 11 passed, 0.468 seconds |
| Dashboard | 14 passed, 1.088 seconds |
| MenuBarMetrics | 15 passed, 0.524 seconds |

These are **81 unique passing tests**. The first four suites passed in
`native-focused.log`; the last three passed in `native-final.log`. The initial
ModelSwitch restart test had five failed assertions because the simulated prior
app instance retained the request archive lock. The fixture now closes that
archive before restart. All original assertions remain and pass; the initial
failure log is retained.

The picker regression mounts the native control without a hover, serves 130
catalog models from a loopback endpoint, changes the saved catalog and checks
that other connections and gateway discovery remain untouched. Defaults tests
cover restart/projects, connection isolation, explicit default/reset choices,
upgrade fallback, pending-write ordering and transactional rollback. Fixtures
use synthetic state and local gateways, without production credentials.

Unchanged helper, optimized wire, process/MCP and transcript evidence is reused
from [0.1.6](Bello-Agent-0.1.6-2026-09-16.md): 105 helper, 24 wire, two process,
52 Python and 21 transcript tests passed there, along with TypeScript checks.
Its broader native/gallery and signed Keychain results remain historical,
not new 0.1.7 runs. No full native suite, gallery or full interactive gateway
run was repeated. Under the owner's current policy, **fresh-install, actual
Sparkle update/relaunch and signed owner/update rehearsals were skipped**.

## Signing and public distribution

- Source: `bd6a5559fa5d52a647f997d9084cf9fbd7001c18`.
- Website: `90ffc8fd821aa17789c85f2cf49cdf50d06518b3`, pushed to the website's
  `main` branch and confirmed at its remote.
- Product: [belloware.com/bello-agent.html](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.7.dmg](https://belloware.com/assets/BelloAgent-0.1.7.dmg),
  **6,688,314 bytes (6.38 MiB)**, below the 20 MiB distribution target.
- SHA-256: `00e284caa89b62eec2d1e6246f029e0ceeef20dc1982610bc918f8151e0a3c96`.
- App notarization: `2a52c7ca-494c-4233-8557-f9230c6ac4f0`, accepted.
- DMG notarization: `5a455e49-e298-4040-8d65-91132addd055`, accepted.

The app and DMG pass signing/notarization and local artifact/feed validation;
the local release smoke check passes. Both public update feeds are byte-identical
to the intended local feed. The downloaded DMG matches its expected size, SHA-256
and Ed25519 signature. The public product page advertises 0.1.7 and its correct
download; homepage discovery, legacy page redirect and exact icon bytes also
pass. An initial public check still saw the previous feed while deployment was
propagating; final public verification completed successfully at 06:36:37 UTC.

These are artifact/publication checks, not an installation or update rehearsal.
The actual 0.1.5→0.1.6 installation and state-preservation evidence remains
historical in the 0.1.6 record. Updater functionality remains enabled.

## Commands and evidence

Per-run scratch/logs:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/model-picker-followup`.
The stable incremental `PI_BUILD_ROOT` remains
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`;
its older directory name is a cache location, not the release version.
Native tests reused `PI_BUILD_ROOT/native-tests`, with isolated fixtures and
gallery/interactive opt-ins disabled. The two suite selections were:

```sh
# From repository root, with the stable PI_BUILD_ROOT and isolated test environment.
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ModelSwitchTests \
  -only-testing:PiAppTests/ModelCatalogEndpointTests \
  -only-testing:PiAppTests/GatewayModelDiscoveryTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ProjectSidebarTests CODE_SIGNING_ALLOWED=NO

xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ModelSwitchTests \
  -only-testing:PiAppTests/DashboardTests \
  -only-testing:PiAppTests/MenuBarMetricsTests CODE_SIGNING_ALLOWED=NO
```

Release/publication used `scripts/release.sh`, `scripts/publish-release.sh` and
`scripts/verify-published.py`, following Clipboard's profile-free Developer ID
flow. Logs are `native-focused.log`, `native-final.log`, `release.log`,
`publish.log` and `public-verification.log`; page/icon results are in
`public-verification/pages-verification.txt`. Detailed release logs remain under
`PI_BUILD_ROOT/release.2dTxZv`. No raw logs or synthetic state are published.

Existing limits remain: local fixtures are not deployed LiteLLM acceptance;
physical status-item clicks, chart dragging, foreground unread clearing through
CUA, real-language IME and the full Release performance budget are not newly
verified. Ordinary Keychain's same-user write/delete limits and deferred
HTTP-body full-text search remain unchanged.
