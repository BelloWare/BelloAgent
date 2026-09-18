# Bello Agent 0.1.4 acceptance

Date: 2026-09-16. Branch: `master`. Released: **0.1.4/build 8**.
Signing, public verification and the actual 0.1.3→0.1.4 update pass. Environment:
macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.

## Reviewed changes

Claude's five follow-up commits through `9304227` were reviewed after its
session finished, with no unmatched tools or child processes. Its report session
grouping, linked-message navigation and compact sidebar remain. Parallel agents
implemented/reviewed onboarding, live activity and unread state; the parent
integrated them, tested actual UI interactions and corrected integration defects.

- New requests use Responses. Saved Messages connections, keys, journals and
  captures remain readable; conversion creates a separate connection explicitly.
- Visible speaker-name labels are gone. Every HTTP attempt has one inline
  accounting owner; it moves from user input to the assistant response. User
  Details still exposes all linked requests. Tool-result rows do not duplicate
  accounting, and compaction retains its own request attribution.
- LiteLLM headers and terminal JSON/SSE evidence preserve routed models,
  cache-write tokens, reasoning tokens and reported reasoning cost. The owner's
  JSON sample yields **38 input + 302 output = 340 total**, including **253
  reasoning tokens**. Reported cost is **$0.0013875**, including **$0.0011385
  reasoning cost**. Neither subset is added again. Null body cost can use final
  JSON response headers; preliminary streaming headers are not final billing.
- Onboarding makes one small selected-model request through the packaged helper,
  with no tools, history, skills or workspace instructions, a bounded output
  budget, cancellation and timeout. It preserves scoped credentials/capture and
  rejects settings changed during the test. No probe chat or journal is created.
- One persistent native status controller handles both mouse buttons. Activity
  precedes Usage and shows model/tool/compaction phases, queues, paused work,
  unread replies and a combined rolling output estimate. It sums fresh exposed
  output only, labels the estimate and excludes opaque reasoning/tool output.
  Usage retains time scopes, reported totals and alias/resolved-model groups.
- Durable unread counters baseline old history, reconcile offline journals,
  survive restart and clear only for the latest completed reply actually visible
  in a foreground chat. Report/background/scrollback are guarded. Explicit Mark
  as Read handles abandoned branches. Quit/install flushing is bounded.
- Review fixes cover report query/navigation races, expired metrics, unknown
  cache counts, preserving native pane state, immediate tool-phase changes,
  painted-frame receipt ordering, Report visibility restoration and sidebar
  session consumption instead of last-request context size.

## Deterministic checks

| Check | Result |
| --- | --- |
| Swift helper full suite | 92 passed, 4.862 seconds |
| Final focused activity suite | 3 passed, 0.091 seconds; includes one additional silent-tool notification regression |
| Optimized helper wire | 23 passed, 3.110 seconds |
| Process/MCP recovery | 2 passed, 2.586 seconds |
| Python release/gateway suite | 52 passed, 17.159 seconds |
| Native app suite | 195 executed: 193 passed, two opt-in tests skipped, zero failures; 12.980 seconds |
| Transcript | 13 passed; TypeScript passed |
| Optimized helper staging | Passed; 1.60 MiB, no shipped Node runtime |
| Native screenshot gallery and onboarding boundary | One passed, 76.585 seconds; 30 light/dark captures; 16 report/gallery checks passed together in 77.915 seconds |

The local gateway validates the real route, credentials, requested alias, tools,
limits, reasoning settings and continuation results before choosing a response.
Probe tests validate the exact fixed prompt and reject unrelated fields/tools.
Both probe bodies are compared to independent HTTP observations; authentication
capture hashing and absence of session files are asserted. The user examples use
synthetic IDs and opaque content, preserving their relevant accounting fields.
The native gallery additionally runs `verifyOnboardingConnection` through the
packaged helper and scoped test vault before any chat exists, verifies cleanup,
and then renders the app. The session report, compact layout, onboarding and
conversation images were inspected. A final presentation correction labels the
probe as a connection check rather than a missing chat. A final gallery review also found cramped pagination at 920-pixel width; grouping and pagination now occupy an adaptive row, verified in the repeated light/dark compact-controls captures. Existing SwiftUI gallery
diagnostics also occur in the previous release's gallery; they are not new
passing evidence for the full performance budget.

## Interactive checks

The final fresh-state CUA fixture passed in **284.612 seconds**. Both Responses
models ran: the owner billing sample and a read-tool round trip plus slow reply.
All **eight bodies from four requests** match independent gateway bytes, with
no missing prior attempts. Totals: **677 tokens and $0.0051375**.

The native Details sheet showed the user's request link, resolved
`gpt-5.4-mini`, exact cost, and reasoning portion. Tool-round accounting showed
42 and 50 tokens once each; the corrected sidebar showed **92 consumed session
tokens**, while the composer separately retained its 50-token context estimate.
The menu showed **13.5 estimated output tokens/second** during a live request,
scoped cost/usage and both requested/resolved model groups. It opened twice,
used day/retained scopes, opened Report and recovered after the main window
closed. Report linked-message navigation worked.

The earlier run passed in 316.946 seconds with seven requests, 14 exact bodies,
1,016 tokens and $0.0088875. It additionally showed one running model and one
pending follow-up together. That run preceded the sidebar/receipt refinements;
the final run and deterministic regressions establish those final source changes.

Unread output remained correctly marked while Report was visible. During the
final foreground-clear check, macOS SecurityAgent owned foreground focus and
the chat window was inactive. The computer-use tool refused SecurityAgent
access. The app correctly retained the unread marker; **successful foreground
clearing was not claimed from that CUA run**. Native tests cover visibility,
painted-frame ordering, stale receipts, restart and explicit marking separately.
The fixture invokes the actual status-button action; physical left/right menu
bar clicks remain outside CUA coverage. Both event masks have native tests.

## Distribution and limits

Release source is `16b5152273b50b0daf796c0134414cd309fbb04a` (application
changes through `4d4a0f0`); website publication is
`75c40908be00ad9f102e475eb18e9731f824c258`. Both were committed and pushed normally.
The same Clipboard Developer ID identity (`43TXHV3TM3`) signed all nested code
with hardened runtime and secure timestamps; deep strict validation passes.
The packaged Swift helper smoke passed with no bundled Node runtime.

- App notarization accepted: `ae9b6d96-7f36-450b-ab5f-2658e93422f9`.
- DMG notarization accepted: `e952b77c-77e2-4441-b66c-2ea732ffbd3e`.
- Both tickets stapled and validated; app Gatekeeper acceptance passed.
- Installer: **5,044,519 bytes (4.81 MiB)**.
- SHA-256: `feec253f6ce52a6e9c00a38cf77708d4b38374969daf96d1ed3756724eeac9ca`.
- The appcast Ed25519 signature verifies for these exact bytes.
- The isolated signed Keychain suite was repeated: **51 checks/observations
  passed**, including changed-executable continuity and concurrent writes.
  Synthetic items were removed; no production-vault or signing-key policy changed.

At **10:39:55 SGT**, both public update feeds matched the local appcast exactly;
the downloaded DMG matched the SHA-256 above and passed Sparkle Ed25519
verification. The product page, legacy redirect, homepage, sitemap and icon
matched website commit `75c4090` byte-for-byte. Public locations:
[Bello Agent page](https://belloware.com/bello-agent.html) and
[0.1.4 installer](https://belloware.com/assets/BelloAgent-0.1.4.dmg).
The same final signed installer was copied to the session outbox.

Actual CUA update acceptance started in the existing 0.1.3/build 7 installation.
Check for Updates offered 0.1.4; Install Update downloaded it, then Install and
Relaunch installed **0.1.4/build 8** at the existing
`clipboard-release/update/PiApp.app` path. All **75 files and symlinks** match
the signed release exactly. Deep strict codesign, stapler and Gatekeeper checks
pass. Five historical chats and their transcript remain visible; the updated
transcript omits speaker names. Settings → Reload Vault succeeds at unchanged
revision 0 (empty configuration), with no saved configuration/credential changes
or real gateway request. Production ⇧⌘R opens Report and Esc restores the
same transcript/WKWebView. This does not replace the foreground-unread limitation
recorded above.

These are request-aware loopback fixtures, not a deployed LiteLLM service. No
real gateway or production credentials were used. The previous real-language
IME, chart dragging and complete Release performance-budget limits remain;
see the [0.1.3 evidence](Bello-Agent-0.1.3-2026-09-16.md). HTTP-body full-text
search remains deferred. Existing ordinary-Keychain access policy is unchanged.

Scratch root: `/Users/admin/.cdkjj-remote/sessions/ses_VDD71kc06BCA4Vig/tmp/bello-agent-0.1.4`.
Logs: `core-final.log`, `activity-tests.log`, `onboarding-tests.log`,
`wire-final.log`, `process-final.log`, `python-verified.log`,
`native-release-ready.log`, `live.log`, `live/verification.json`,
`live-final.log`, `live-final/verification.json`, `gallery.log`, `gallery-final.log`, `report-final.log`, `keychain-final.log`, `release-0.1.4.log`, `publish-0.1.4.log`, `public-verification.log`,
`public-verification/website-verification.json` and
`installed-update-verification.json`.
