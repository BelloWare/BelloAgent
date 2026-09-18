# Bello Agent 0.1.8 acceptance

Date: 2026-09-16. Branch: `master`. Release source:
`3880709162722ba5d7e4bd3d1715aa396f2bef85`. Version **0.1.8/build 12**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
**Public release verified at 2026-09-16 07:09:31 UTC.**

## Reviewed change

`50818b3` replaces the native strip that covered conversation controls with a
custom 36-point row above the chat/report layout. The SwiftUI WindowGroup uses
`hiddenTitleBar`, matching AppKit's full-size content style. Native close,
minimize and full-screen buttons remain; empty header space supports dragging
and available-screen double-click zoom/restore. Controls and sheets are excluded
from the zoom gesture. Resizing and report navigation preserve focus, drafts
and mounted transcript/composer instances. Zoom is nonanimated.

The release retains the selected flat icon, bundle ID, history paths, ordinary
single-item Keychain vault and Sparkle key. No provider, helper, transcript,
credential or accounting implementation changed.

## Focused acceptance

| Native suite | Passing evidence |
| --- | --- |
| WindowPresentation | 5 passed, 1.091 seconds; `native-final.log` |
| ReportNavigation | 3 passed, 4.318 seconds; `native-final.log` |
| WindowPresentation, optional capture readiness rerun | Same 5 passed, 2.756 seconds; `native-previews.log` |

All **eight unique focused native tests pass**: WindowPresentation 5 and
ReportNavigation 3 in `native-final.log` (5.409 seconds). WindowPresentation's
five tests passed again in `native-previews.log` (2.756 seconds) after changing
only optional screenshot readiness. This repeat is not five additional tests.
The checks exercise the actual SwiftUI WindowGroup after layout/resize, reserved
header geometry, native-control exclusions, zoom/restore, composer focus/drafts
and retained chat/report surfaces. Three synthetic JPEGs were inspected: light
chat, compact dark chat and light report. The top row no longer covers content.

The first build rejected a test-only write to the SDK's read-only Reduce Motion
environment value. Removing that fixture injection fixed compilation without
changing system preferences; no test assertion failed. Initial screenshots were
captured before WebKit paint/report transition completion; optional capture now
waits for fixture text, two animation frames and a bounded 350 ms settle. The
ordinary test path has no added capture delay.

Unchanged 0.1.7 picker/defaults/reporting acceptance (81 tests), and 0.1.6 helper,
wire, process, Python, transcript and broader UI evidence are reused from their
versioned records. No full native/gallery, provider, interactive gateway or new
performance acceptance was run. Install/update and signed owner/update
rehearsals were skipped by owner instruction.

The synthetic light chat, compact dark chat and light report captures are
`chat-light.jpg`, `chat-compact-dark.jpg` and `report-light.jpg`. They capture
only the fixture window, not unrelated applications. Fixtures use MemoryVault
and isolated state; no production credentials or deployed gateway are used.
These screenshots establish header layout, not a full interactive acceptance
run or a new drag/full-screen-control gesture rehearsal.

## Signing and public distribution

- Source: `3880709162722ba5d7e4bd3d1715aa396f2bef85`.
- Website: `956a86317892a47b5ced402eb8a30aad5e086552`.
- Product: [belloware.com/bello-agent.html](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.8.dmg](https://belloware.com/assets/BelloAgent-0.1.8.dmg).
- Size: **6,691,444 bytes (6.38 MiB)**.
- SHA-256: `dca53c6d618c6bb56e8d499d1e8c748327182d617792129fe46b031f991c070b`.
- App notarization: `c6b2e002-0ca5-4e25-9c22-53c07871ce55 (accepted)`.
- DMG notarization: `3f80d1fb-3018-4515-b341-479141457a2a (accepted)`.

App/DMG signing and notarization, local smoke checks, public pages/icon, identical
update feeds and downloaded archive SHA-256/Ed25519 verification pass.
Initial public checks still received the 0.1.7 feed during deployment propagation.
Final verification at **2026-09-16 07:09:31 UTC** confirmed both canonical/legacy feeds
match the intended 0.1.8 feed and the downloaded DMG matches the expected size,
SHA-256 and Ed25519 signature. The product page advertises 0.1.8 and its exact
DMG link; legacy redirect, homepage discovery and sitemap pass. Public icon
bytes match SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
The website commit is confirmed at its remote.

These are artifact/publication checks, not an installation or update rehearsal.
Historical actual-update evidence remains in the [0.1.6 record](Bello-Agent-0.1.6-2026-09-16.md).
Updater functionality remains enabled.

## Commands and evidence

Per-run scratch/logs:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/window-chrome-followup`.
Stable incremental `PI_BUILD_ROOT`:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6/build`.
Its older directory name denotes the reused cache, not the release version.
`PI_APP_SCRATCH_ROOT` isolates state. The full gallery/interactive opt-ins were
disabled; `PI_APP_CHROME_CAPTURE_ROOT` enables only the three focused JPEGs.

```sh
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WindowPresentationTests \
  -only-testing:PiAppTests/ReportNavigationTests CODE_SIGNING_ALLOWED=NO
```

The capture-only rerun selected `WindowPresentationTests` alone. Original compile
output is retained in `native-focused.log`; passed runs are `native-final.log`
and `native-previews.log`. Release/publication follows `scripts/release.sh`,
`scripts/publish-release.sh` and `scripts/verify-published.py`. Detailed release
log root: `PI_BUILD_ROOT/release.XSSFYQ`. No raw logs or synthetic state are published.

Existing limitations remain: local fixtures do not establish deployed LiteLLM
compatibility; physical status-item clicks, chart dragging, foreground unread
clearing through CUA, real-language IME and the full Release performance budget
are not newly verified. Ordinary Keychain's same-user write/delete limits and
deferred HTTP-body full-text search remain unchanged.
