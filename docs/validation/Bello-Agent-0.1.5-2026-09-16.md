# Bello Agent 0.1.5 acceptance

Date: 2026-09-16. Branch: `master`. Released: **0.1.5/build 9**.
Source, fixtures, interactive checks, signing, publication and the actual
0.1.4→0.1.5 update pass. Environment: macOS 14.8 arm64,
Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

## Reviewed implementation

Parallel agents implemented capture defaults, session organization and
context/skill inspection. The parent integrated them, added background billing
regressions, reviewed generated UI, exercised native interactions and prepared
distribution. Existing SwiftUI/AppKit composers, React/WKWebView transcript,
self-contained Swift helper, bundle identity and ordinary Keychain are retained.
Node remains build-only. Responses is the active API; historical Messages stays
readable. HTTP-body full-text search remains deferred.

- Request/response bodies default to plaintext retention for 30 days, subject
  to quota. A versioned migration changes the identifiable old default tuple;
  distinguishable capture-off choices and custom retention remain. Legacy
  seven-day retention adopts 30 days once. Subsequent explicit Off/seven-day
  choices remain. Old captures are not rewritten.
- Body pages display directly. Request and response headers remain inspectable
  and copyable. Longer request authentication tokens retain only their last
  four characters behind a mask; short tokens, cookies, response authentication
  and configured-credential echoes are fully masked. Known credential literals
  in request bodies still become labeled hashes, explicitly limiting exactness.
  Actual wire credentials and original noncredential bytes remain unchanged.
- Code blocks and Markdown sections copy their original source, preserving
  Unicode and line endings. Native validation rejects stale messages and invalid
  UTF-16 boundaries. Code copies exclude fences; section copies retain them and
  stop before the next heading at the same or higher level.
- Every project has a collapsible group with persisted disclosure/archive
  choices. Rename, pin, archive and restore preserve history, drafts and active
  work. Organization revisions prevent delayed host/model saves from undoing
  edits. Orphaned historical projects remain visible as unavailable, untrusted
  history groups; they cannot silently start new work.
- Metadata capture invalidates session totals regardless of focus. Coalesced
  queries update all project caches; generation guards reject stale reads and
  pending final billing survives display eviction. Running rows show fresh,
  explicitly estimated output TPS. Consumption and context remain distinct.
- `/side` plus one Return opens a durable child immediately with no model call.
  Closing hides the pane and preserves its draft, context, pending work and
  parent relationship. `/fork` creates an independent journal with the same
  complete active context, provider items, tool results, compaction and branch
  selection, without inheriting queued commands or future identity.
- The circular context control opens immutable paged instructions, tools,
  instruction sources, provider input items and the full prepared request. It
  uses authoritative context and the actual provider builder. Drafts and selected
  skills are included only where applicable; running previews exclude queued
  drafts and incomplete output. This is a preview, not a past HTTP capture or
  exact token count. Later compaction, tools or source changes can change the
  eventual request. Stale configuration/draft results are rejected.
- Per-skill switches affect only Bello Agent. Shared Codex sources/settings are
  unchanged. Disabling removes unsent selections and blocks future/queued use;
  running requests retain their frozen inputs. Re-enabling cannot override
  existing source/project restrictions.
- Native title-bar space no longer overlays content. Double-click toggles the
  available-screen frame and previous size, without intercepting native controls,
  sheets or fullscreen. Conversation-title protocol/model/editing badges are removed.

## Deterministic checks

| Check | Result |
| --- | --- |
| Swift helper full suite | 101 passed, 4.905 seconds |
| Optimized helper wire | 24 passed, 5.160 seconds |
| Process/MCP recovery | 2 passed, 2.576 seconds |
| Python release/gateway | 52 passed, 16.967 seconds |
| Transcript | 21 passed; TypeScript passed |
| Native app including screenshot gallery | 236 executed: 235 passed, one interactive opt-in skip, zero failures; 91.136 seconds |
| Gallery and packaged onboarding boundary | Included above: one passed, 75.587 seconds; 30 light/dark captures |
| Optimized helper staging and app smoke | Passed; helper 1,745,616 bytes (1.66 MiB), no shipped Node runtime |

The gateway validates routes, credentials, requested models, tools, limits and
continuation results before choosing responses. Side/fork/context tests assert
that inspection and session creation do not send HTTP requests. Both captured
body streams are compared to independent gateway observations; header masking
is checked separately from exact body bytes. Onboarding tests use the packaged
helper and scoped test vault before any chat exists, check selected-model ping
and cleanup, then render the app.

New native regressions cover five accounting races, project disclosure writes,
organization revisions, complete side/fork recovery, global skill policy,
context freshness, native window frames and six clipboard cases. Review fixed
a UTF-16 surrogate split in clipboard validation and a pending-accounting read
invalidated during display eviction. Earlier integration failures (missing
`try`, a shadowed error property and old Project-label expectations) were fixed
before the final passing run. Accounting fixture setup was corrected to include
actual dispatch metadata and initialized configuration, preserving the production
rule that undispatched attempts cannot count as usage.

## Interactive checks

The fresh CUA fixture passes in **670.249 seconds**. Both model aliases ran;
**all 16 retained bodies from eight requests** match independent gateway bytes.
Totals are **1,290 tokens and $0.0101375**, with one observed background billing
session. No prior unmatched attempt remains. The owner's accounting sample
shows 38 input + 302 output = 340 total, 253 reasoning tokens and $0.0013875
total cost including $0.0011385 reasoning cost. Subsets are not added again.

Verified through native UI:

- Exact Swift code copying including an emoji; Markdown section copying retained
  its heading and fenced code but excluded the next section.
- Context ring → prepared request → actual captured request inspector. Body
  content and masked request/response headers appeared without a reveal step.
- Rename to “Release QA”, pin, archive, restore and rearchive; persistent metadata
  assertions pass. Collapsing/expanding one project leaves other groups intact.
- A slow reply finished while another chat was selected. Sidebar cost changed
  from $0.0051375 to $0.0063875 and unread state appeared without focusing it.
- Empty `/side` opened on one Return. Closing retained the child in the sidebar;
  reopening it restored “Unsent side note”. Empty `/fork` opened an independent
  session with inherited complete history and an empty composer.
- A skill switched off, was labeled disabled and could not be selected, with
  explicit Bello-only scope. It was re-enabled for the fixture afterward.
- Status Activity showed a running model at **13.5 estimated output tokens/sec**.
  Usage showed requested/resolved model groups, correct totals and reasoning
  coverage. The panel opened twice, used day/retained scopes, opened Report and
  recovered the main window after it was closed.
- Double-clicking the title bar expanded the window from 1124 pixels to the
  available 1470-pixel width; a second double-click restored the prior frame.
  Window content remained below the reserved title bar.

The live run preceded a final narrow updater/composer correction. A repeated
full native run and gallery include that correction: updater installation now
preserves the edit target and displaced draft; model-to-editor synchronization
suppresses delegate echo, and native focus publication is deferred and rejects
superseded responders. The final gallery has no publishing-during-view-update
warning. Existing layout/AttributeGraph diagnostics remain and are not treated
as performance acceptance. Successful foreground unread clearing is not claimed
from this CUA run; native tests cover visibility, painted-frame ordering and
stale receipts. The fixture invokes the real status-button action; physical
left/right menu-bar clicks remain outside the interactive scope.

## Commands and evidence

Scratch root:
`/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.5`.
`PI_BUILD_ROOT` is its `build` child. Logs and synthetic data stay outside the repo.

```sh
swift test --package-path packages/swift-host
PI_BUILD_ROOT="$SCRATCH/build" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py packages/swift-host/.build/release/pi-native-host
python3 scripts/test-native-acceptance.py packages/swift-host/.build/release/pi-native-host
python3 -m unittest discover -s scripts/tests
scripts/with-runtime.sh npm run typecheck
scripts/with-runtime.sh node --import tsx --test packages/host/test/transcript.test.ts
xcodegen generate
xcodebuild test -project PiApp.xcodeproj -scheme PiApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$SCRATCH/build/native-tests" CODE_SIGNING_ALLOWED=NO
```

The full native run set `PI_APP_UI_SCREENSHOT_ROOT` and its `TEST_RUNNER_`
counterpart to `$SCRATCH/gallery`. Interactive acceptance set its corresponding
UI root to `$SCRATCH/live`, enabled `PI_APP_UI_ACCEPTANCE_PRODUCTIVITY=1`, and
selected `PiAppTests/NativeUIAcceptanceTests`; the operator created `live/finish`
only after completing native interactions. Final assertions wrote
`live/verification.json`.

Logs: `python-tests.log`, `typecheck.log`, `transcript-tests.log`, `stage.log`,
`core-final.log`, `wire-final.log`, `process-final.log`, `native-gallery.log`,
`native-final-polish.log`, `live.log`, `live/verification.json`. The 30 gallery images are scratch evidence;
they contain only synthetic loopback conversations.

## Distribution and limits

Release source is `34603906e6a38ab02244ee799deb6b65cc467d0c`; website
publication is `51d81cf49af8756215b04993a2c4f9fc1252dcfc`. Seven reviewable source,
UI and preparation commits were pushed normally before publication. Later
release-record documentation does not change the released application.

Clipboard's profile-free Developer ID identity (`43TXHV3TM3`) signs all nested
code with hardened runtime and secure timestamps. The signed helper smoke
passes without Node and measures 1,763,888 bytes including its signature.

- App notarization accepted: `ac3b9b62-8bf2-474e-8b14-65893c382302`.
- DMG notarization accepted: `aab41357-c6e4-4b2c-aa9b-ad71a56ef60f`.
- Tickets stapled and validated; deep strict codesign and Gatekeeper pass.
- Installer: **5,283,041 bytes (5.04 MiB)**.
- SHA-256: `56fbe30cae225525104bd84938548c8a951e67f750ce28a384762338a3b42934`.
- Sparkle Ed25519 signature verifies against these exact bytes.

At **12:00:28 SGT**, deployment verification began its successful seventh
attempt after earlier reads still served 0.1.4. Both public feeds match the local
appcast; the downloaded DMG matches the hash above and verifies its signature.
The product page, legacy redirect, homepage, sitemap and icon all match website
commit `51d81cf` byte-for-byte. Public locations:
[Bello Agent page](https://belloware.com/bello-agent.html) and
[0.1.5 installer](https://belloware.com/assets/BelloAgent-0.1.5.dmg).
The final signed DMG is also in the session outbox.

Actual CUA acceptance started from the existing signed 0.1.4/build 8 app.
Check for Updates offered 0.1.5; Install Update downloaded it; Install and
Relaunch installed **0.1.5/build 9** at the existing
`clipboard-release/update/PiApp.app` path. All **75 files and symlinks** match
the signed release exactly. Deep strict codesign, stapler and Gatekeeper pass.
All five historical chats remain in a retained-project group, with the prior
transcript and new copy/context controls visible. Because this test installation
has an empty vault, the missing project's history remains read-only; the update
does not silently recreate trust or profiles. Settings → Reload Vault succeeds
at unchanged revision 0 with no connection test or saved configuration changes.
The production vault/signing policy was not modified. The full isolated signed
Keychain suite was not repeated; its prior 51-check evidence and unchanged
ordinary-Keychain limitations remain in the
[0.1.4 record](Bello-Agent-0.1.4-2026-09-16.md).

Release commands were `PI_BUILD_ROOT=... scripts/release.sh`,
`PI_BUILD_ROOT=... scripts/publish-release.sh 0.1.5` and
`python3 scripts/verify-published.py <release-directory> <verification-directory>`.
Additional logs: `release.log`, `build/release.uAIBWA/build.log`,
`build/release.uAIBWA/notary-app.log`, `build/release.uAIBWA/notary-dmg.log`,
`publish.log`, `public-verification.log`,
`public-verification/website-verification.json` and
`installed-update-verification.json`.

The final gallery retains pre-existing layout/AttributeGraph diagnostics. Its
SQLite NULL-handle warning also occurs in the earlier passing gallery; closed
temporary test stores throw safely, and production has no mid-session metadata
store close call. No new runtime data-loss/crash was identified in the review.
These diagnostics are not counted as full performance-budget acceptance.

These tests use request-aware loopback fixtures, not deployed LiteLLM or
production credentials. Physical status-item clicks, chart dragging, real IME
and the complete Release performance budget remain unverified. Earlier Debug
target misses remain in the 0.1.3 record. Ordinary Keychain's same-user raw
write/delete limitation is unchanged. HTTP-body full-text search is deferred.
