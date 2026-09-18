# Bello Agent 0.1.6 acceptance

Date: 2026-09-16. Branch: `master`. Release source:
`30fc4b47bc88fcc9de4daff8087e0b22b2cab2e9`. Version **0.1.6/build 10**.
Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

## Reviewed implementation

Claude completed its foreground and background work before review or release
changes began. Its final transcript ended at 2026-09-16T05:22:24.972Z; the screen
session remained available and no queued work or child test process remained.
Eight existing source commits (`b10ada6` through `b5bd531`) were preserved.
Parallel reviewers checked model/catalog behavior, native session/UI behavior
and the helper/gateway acceptance matrix. Thirteen source commits, including
Claude's eight, were pushed normally from `04354c9` through the release source.

- A configured model catalog is the sole model-list source. Its one-hour cache
  refreshes on access; a failed refresh retains the last successful list and
  exposes the error instead of querying an unrelated gateway list.
- Every request disables LiteLLM fallbacks unless the connection explicitly
  allows them. The request-aware ping fixture checks this field and rejects
  missing/false values in default probes.
- Settings has one Save action, closes only on success, and preserves untouched
  connection records and credentials when only preferences change. Review fixed
  a false edit caused by formatting/injected defaults, which could block active
  or retained Messages connections, and fixed silently discarded edits after a
  URL was cleared. Validation failures leave the form available for correction.
- Settings Test Connection saves first, then targets its own persisted chat in
  No project. Review restored its native composer and enforced tools-disabled
  scratch sessions, guarded side/edit promotion, and fixed a selection race that
  could otherwise submit to another conversation. Onboarding's bounded probe
  remains separate and creates no chat.
- Compaction progress appears above the composer. Its result now comes from
  the latest successful summary in authoritative active context, with a baseline
  when opening existing history. Failed/cancelled compaction cannot reuse an old
  success; fast/background completion is observed independently of scrollback.
- Usage Report shows requested and final models together. Clickable controls
  retain pointer/hover affordances. Archived chats can be explicitly deleted
  while idle; review prevents deleting a child that is still open in a side pane.
- The transcript's previously committed jump-to-latest control, streaming caret
  and resize-follow behavior are retained and included in current tests.

The selected `bello-agent-flat-01-soft.png` is the exact committed master at
`assets/branding/bello-agent-icon.png`, SHA-256
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
Its RGB artwork and pale opaque exterior margin are preserved. All native icon
and inline sizes use deterministic resampling. An attempted alpha derivative
was discarded because it contained a rendered checkerboard; it was not used.
The source prompt/provenance is in `assets/branding/icon-0.1.6-prompt.md`.

Bundle ID, history paths, the ordinary single-item Keychain vault and Sparkle
key remain unchanged. Native SwiftUI/AppKit composers, React/WKWebView transcript
and the self-contained Swift helper remain selected. Node is build-only;
Responses is the active API and historical Messages data stays readable.

## Acceptance

| Check | Result |
| --- | --- |
| Swift helper full suite | 105 passed, 5.179 seconds |
| Optimized helper wire | 24 passed, 5.339 seconds |
| Process/MCP recovery | 2 passed, 2.599 seconds |
| Python release/gateway | 52 passed, 17.046 seconds |
| Transcript | 21 passed, 0.933 seconds; TypeScript passed |
| Native app, gallery enabled | 247 executed: 246 passed, one interactive opt-in skip, zero failures; 91.525 seconds |
| Included gallery and packaged onboarding boundary | One passed, 75.464 seconds; 30 light/dark captures |
| Isolated signed Keychain owner/update acceptance | 51 checks/observations passed |

The native total includes four Settings-save tests and five follow-up tests.
The scratch-chat integration mounts the actual native composer, previews an
empty tool list, sends no HTTP request, transitions to an unavailable project
without a composer, then restores the scratch composer and draft. Additional
tests cover selection-independent submission, side restrictions, child deletion
and authoritative compaction notices. Helper regressions cover successful,
failed, cancelled and abandoned-branch compaction summaries.

The first full native run failed only while a hidden test NSHostingView changed
its root to an unavailable project without a subsequent layout pass. It also
reproduced in isolation. The test now shows and lays out its own window, retains
all original composer/tools/no-traffic assertions, adds the return-to-scratch
check and reports specific wait diagnostics. Its focused five-test rerun passed
in 0.496 seconds, then the full suite above passed. The original failure logs
are preserved. The initial Python ping failures were synthetic request bodies
missing the new required flag; the fixture was corrected without relaxing its
oracle and includes new malformed-request probes.

All 30 gallery views passed; review inspected the new icon, main chat, report
and Settings. The gallery exercises the packaged onboarding helper/scoped vault
before chat creation. These are deterministic loopback fixtures, not deployed
LiteLLM or production credentials. No new full interactive gateway run is claimed:
the eight-request/sixteen-exact-body CUA evidence belongs to the unchanged
0.1.5 record. Current native/helper tests cover the changed behavior.

## Commands and evidence

Scratch root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.6`.
`PI_BUILD_ROOT` is its `build` child; no raw logs or synthetic state are published.

```sh
swift test --package-path packages/swift-host --scratch-path "$SCRATCH/host-swift-build"
swift build -c release --package-path packages/swift-host --scratch-path "$SCRATCH/host-swift-build"
python3 scripts/test-native-host.py "$SCRATCH/host-swift-build/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$SCRATCH/host-swift-build/release/pi-native-host"
python3 -m unittest discover -s scripts/tests
scripts/with-runtime.sh npm run typecheck
scripts/with-runtime.sh node --import tsx --test packages/host/test/transcript.test.ts
python3 scripts/build-bundle.py
python3 scripts/test-keychain-identity.py "$SCRATCH/keychain"
xcodegen generate
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$SCRATCH/build/native-tests" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The final native run used `PI_APP_SCRATCH_ROOT`/`TEST_RUNNER_PI_APP_SCRATCH_ROOT`
at `native-scratch-final` and both screenshot-root variables at `gallery-final`.
Logs: `host-swift-core-final.log`, `host-swift-release-build-final.log`,
`host-native-host-final.log`, `host-native-acceptance-final.log`,
`host-python-unittest-fixed.log`, `host-python-gateway-focused.log`,
`typecheck.log`, `transcript-tests.log`, `stage.log`, `keychain.log`,
`native-gallery.log`, `native-followup-reproduce.log`, `native-followup-fixed.log`
and `native-final.log`. Source manifest and hash scope are in
`host-source-manifest.json` and `host-acceptance-report.md`. Keychain report:
`keychain/keychain-29109f9c-afef-4dde-ad52-c470982d97d9/report.json`.

## Distribution

Source `30fc4b47bc88fcc9de4daff8087e0b22b2cab2e9` and website
`d92957c43e41c160df40b14a93dab007c647716a` were pushed normally. Documentation
commits after that source do not change the released app. The website uses the
exact selected master for `assets/bello_agent_icon.png`.

Clipboard's profile-free Developer ID identity (`43TXHV3TM3`) signs nested code
with hardened runtime and secure timestamps. The signed helper smoke passed
without Node; its signed helper is 1,764,256 bytes.

- App notarization accepted: `9018c056-ebab-4367-8a13-4e988df7e55e`.
- DMG notarization accepted: `a47c72a1-36e8-4bc4-9eb8-386f548cf75e`.
- Tickets stapled and validated; deep strict codesign and Gatekeeper pass.
- Installer: **6,656,677 bytes (6.35 MiB)**, below the 20 MiB target.
- SHA-256: `3ede78cb91a98199d4f7e4c1f78196d9bdd4a7d42346d3782a39b7a487684f62`.
- Sparkle Ed25519 signature verifies against these exact bytes.

The fourth normal public verification passed after the first three reads still
served the old feed. Both canonical and legacy feeds match the local appcast;
the downloaded DMG matches SHA-256 and Ed25519. At **13:56:19 SGT**, the product
page, legacy redirect, homepage, sitemap and selected icon all matched the
website commit byte-for-byte. Public locations:
[Bello Agent page](https://belloware.com/bello-agent.html) and
[0.1.6 installer](https://belloware.com/assets/BelloAgent-0.1.6.dmg).
The identical final signed DMG is also in the session outbox.

Actual CUA acceptance started from the existing signed 0.1.5/build 9 app.
Check for Updates visibly offered 0.1.6; Install Update downloaded it; Install
and Relaunch installed **0.1.6/build 10** at the unchanged
`clipboard-release/update/PiApp.app` path. All **75 files and symlinks** match
its signed release exactly. Deep strict codesign, stapler and Gatekeeper pass.
The app relaunched with the selected icon, retained transcript and all five
historical chats visible.

All five journal files are byte-identical. The eleven chat/draft/workspace
records retain their values: ten are byte-identical; the install flush re-encoded
one empty draft with a different JSON object key order. Re-encoding the current
values in that prior order reproduced the exact pre-update SHA-256, establishing
that no draft value changed. The initial byte-only comparison and the resolved
comparison are both retained as evidence.

The existing test installation has an empty vault. Settings → Reload Vault
succeeded at unchanged revision 0, then Cancel closed the sheet without saving
configuration or sending a gateway request. The missing project's history
remained read-only; the update did not recreate trust or connections. No
production vault or signing policy was changed. The separate isolated signed
Keychain suite above was repeated for this release.

Commands: `PI_BUILD_ROOT=... scripts/release.sh`,
`python3 scripts/validate-release.py <feed> <dmg> <app> --previous-build 9`,
`PI_BUILD_ROOT=... scripts/publish-release.sh 0.1.6` and
`python3 scripts/verify-published.py <release-directory> <verification-directory>`.
Additional evidence: `release.log`, `build/release.4XD3SL/build.log`,
`build/release.4XD3SL/notary-app.log`, `build/release.4XD3SL/notary-dmg.log`,
`publish.log`, `release-identity.json`, `public-verification-01.log` through
`public-verification-04.log`, `public-verification/website-verification.json`,
`installed-state-before.json`, `installed-update-initial-verification.json`,
`installed-update-verification.json`, `installed-codesign.log`,
`installed-stapler.log` and `installed-gatekeeper.log`.


## Limits

Ordinary Keychain's raw same-user write/delete limitation remains explicit.
The full isolated signed suite used synthetic items and did not alter production
vault data, signing-key ACLs or persistent signing policy. HTTP-body full-text
search remains deferred. Request auth headers stay masked, known body credential
literals stay hashed and ordinary request/response capture remains plaintext
with the existing 30-day default.

Pre-existing layout/AttributeGraph, WebKit process teardown and closed temporary
SQLite diagnostics appear in the gallery; the final suite has no failures.
These are not claimed as full performance acceptance. Physical status-item
clicks, chart dragging, real-language IME, deployed LiteLLM and the complete
Release performance budget remain unverified. The older foreground unread CUA
limitation remains; native tests cover its visibility and stale-receipt guards.
