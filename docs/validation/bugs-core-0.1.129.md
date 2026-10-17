# Core bug fixes, 0.1.129

Branch `dev/a129-bugs-core` (from `dev/next` a2691e9c). Seven findings from the external
review of 2026-10-16 (reviewed commit 9d4123f6): BUG-002, 003, 004, 005, 009, 010, 011.
All seven reproduced on this branch with a failing-first test; none was disputed. Each fix
was then broken on purpose (mutation) and its test failed again.

## Findings, fixes and evidence

| Bug | Fix | Failing first | Mutation |
| --- | --- | --- | --- |
| BUG-002 HTTP MCP ping during `tools/call` | `HTTPMCP` answers a server `ping` on a response SSE stream with an empty result in a new POST (session id and negotiated version headers), then keeps reading the call's stream. Other server requests still throw `mcp_capability` (none advertised; unchanged). More than 64 pings in one exchange is `mcp_server_flood`, mirroring stdio's 64/s guard. A ping answer that cannot be sent is not an error of the call; the exchange deadline still bounds it. | `HTTPMCPPingTests`: `mcp_capability`, call outcome unknown | Answer POST removed: 2 failures (server logs "pinged unanswered") |
| BUG-003 promoted steering does not wake a waiting parent | `steerQueued` and direct steering share `steeringAdmitted()`: publish `steering.queued`, then wake the coordinator. Rollback on persistence failure unchanged. The change is local to `SessionQueue.swift` (two call sites and one private helper). | `AgentSteeringPromotionTests`: promotion test gets no parent request in 5 s with the child held; the direct-steer control passes | `steerQueued` back to the bare event: promotion test fails |
| BUG-004 completion webhook from stale rows | The tracker keeps the finished task's identity (`rootID`, `lastSourceID`) from the helper's task fence, captured when the outcome is returned and carried into the async preparation. Preparation reads the chat's history (not `display.messages`) when the chat has a journal, re-reads around `lastSourceID` if the latest page lacks the task, and bounds the exchange to that task's rows. Chats not yet saved still use the rows on screen. The 0.1.128 family-completion fence (`familyWaiting`, inbox, completion revision) is untouched. | `WebhookExchangeTests`: switched away mid-stream (reply ""), older page resident (old request/reply), next turn already started (reply ""); exchange and tracker unit tests | Display-first preparation: 3 scenario failures. Exchange ignoring the task: next-turn scenario plus unit failures |
| BUG-005 terminal special keys bypass IME composition | While marked text exists, every non-Command key goes to `interpretKeys`/`interpretKeyEvents` first; a key the input method does not take returns as `doCommand(by:)`. No composition: unchanged terminal encoding. | `TerminalPanelSerialTests.testComposingKeysGoToTheInputMethodFirst`: arrows, Backspace, Escape and Control-H sent as terminal bytes, Return sent CR instead of committing | Early branch disabled: 5 failures |
| BUG-009 covered side loses its unread-failure mark | `markRunFailed` suppresses the mark only when `transcriptShows(id)` and the app is active (`applicationIsActive`, the existing seam over `NSApp.isActive`). | `SubagentReaderTests.testASideCoveredByATabKeepsItsFailureMark` (failed first on the visible case too, since the old guard read `NSApp.isActive` directly) | Old mounted-side condition with the seam: covered side has no mark |
| BUG-010 NUL truncates search | `ChatSearchHit.collapsed` treats U+0000 as a separator, so indexed text, queries and excerpts agree; the excerpt's whitespace regex also accepts NUL. All binds and reads in the index are length-aware. `schemaVersion` 2 rebuilds indexes written by 0.1.128 and earlier. | `SidebarSearchIndexTests.testTextAfterAnEmbeddedNULIsSearchable`: user and tool-output text after NUL not found; a query with NUL errored | Normalization removed (length-aware binds kept): still not found, as the review's trigram table predicts. `schemaVersion` back to 1: the rebuilt-index half fails |
| BUG-011 `Application/JSON` treated as SSE | `ProviderClient.isJSONMediaType`: the media type before parameters, trimmed, lowercased, exactly `application/json`. Used by the provider and by `GatewayTelemetry` (one rule). | `ProviderMediaTypeTests`: `incomplete_stream` for a complete JSON body under `Application/JSON` | `lowercased()` removed: 5 failures |

SSE coverage is kept: the media-type test also sends `text/event-stream` and
`Text/Event-Stream; charset=utf-8` streams through the same provider.

## Decisions

- BUG-002 scope: only `ping` is answered. Answering other unadvertised server requests with
  `-32601` (as stdio does) would also avoid aborting a call, but changes an existing,
  deliberate error; left as is.
- BUG-004: the webhook preview (no status) also reads the history first now, so a preview of a
  chat with an older page up shows its latest exchange, the same one a send would use.
- BUG-009: visibility is `transcriptShows` plus app activity, as for read marks. Whether the
  main window is minimized is not considered (unchanged from before).

## Full gate

`PI_BUILD_ROOT=…/build-bugs-core scripts/verify-release.sh` under the full-lane lock, at 14f51323
(2026-10-17, 56 min 40 s):

| Suite | Result |
| --- | --- |
| Native serial lane | 888 tests, 42 skipped, 1 failed (below) |
| Native parallel lane | 2,632 passed, 0 failed, 38 skipped |
| Helper cost (StreamingCostTests) | 5, 0 failures |
| Helper suite | 966, 7 skipped, 0 failures |
| Gallery | 3, 0 failures; 230 screenshots |
| Wire / concurrent / acceptance | 36 / 4 / 3 ran, all passed |
| Script tests | 86 ran, all passed |

The one failure: `SettingsFullDocumentGeometryTests.testCompleteConnectionGroupsMatchAfterTheFrozenLazyPageIsRealized`,
every Settings connection group 1 pt shorter (783 vs 784). This is the already-recorded unexplained 1 pt
Settings geometry miss (NEXT-RELEASE 0.1.129, "Still unexplained"); no Settings code is touched here. The
unchanged class passed 3/3 alone right after the gate.

Focused runs for the changed areas, all passing after the fixes: TerminalPanelSerialTests +
TerminalPanelAuditTests 25; SubagentReaderTests + SessionReadStateTests 71; SidebarSearchIndexTests 16;
WebhookExchangeTests + WebhookTests 20; helper MCP 31, AgentSteering*/QueueEditing 49, provider/telemetry 50.

No UI drawing changed, so no gallery scenes were regenerated beyond the gate's own run.


## Review round 1 (Codex, 200920f9): two P2s fixed

| Finding | Fix | Failing first | Mutation |
| --- | --- | --- | --- |
| Webhook: a task longer than one history page (60 rows / 256 KiB) lost its request; the `around:` fallback started at the last row | `completedExchange` reads the latest page (or the page ending at the task's last row when a later turn pushed it off), then older pages until the bounded rows reach the task's request. `holds` is replaced by `bounded`/`reachesRequest`. | `WebhookExchangeTests.testATaskLongerThanAPageIsReadWhole` (130-row task, with and without 90 later rows): empty request, reply only "Step 129" | Backward loop disabled: 4 failures |
| Terminal: a key the input method declines while composing (`moveLeft:`, `deleteForward:`, …) was dropped | The composing key is kept while the input method has it; `doCommand(by:)` sends its terminal sequence through the same encoder as uncomposed keys (`sendTerminalKey`). | `TerminalPanelSerialTests.testAKeyTheInputMethodDeclinesStillReachesTheProgram`: arrows, forward delete, Home and Shift-Left sent nothing after the commit | Fallback removed: 6 failures |

Reruns: TerminalPanelSerialTests + TerminalPanelAuditTests 26/26; WebhookExchangeTests + WebhookTests 21/21.

## SettingsFullDocumentGeometryTests: the 1 pt miss

What the evidence shows:
- The product page is constant. The native Settings page's Connection group was 783 pt in every run
  examined: the failing gate, the failing neighbour run, and every passing run (more than 170).
- The varying side is the frozen 0.1.119 SwiftUI oracle. Its Connection group is 784 in the gate
  (lazy and eager hosting views alike) and 782 in one neighbour run (lazy only; the eager view in
  the same process was 783). One hosting view keeps its value through every phase of the test.
- Frequency: 1 in 52 runs of the class after its serial-lane neighbours
  (SessionStatisticsParityTests, SessionUsageWindowFrameTests, SettingsCloseNativeTests);
  0 in 100 iterations alone; 0 in 40 iterations under ten busy CPU loops; 0 in 640 fresh oracle
  views built in one process (including after the neighbours, before or after window attachment,
  at display scale 1 or 2, with the catalog loading, after warming fonts, dark app appearance,
  every text field focused in turn).
- No model, controller or catalog publication happens while the oracle lays out (instrumented).

Cause: the frozen SwiftUI 0.1.119 reference page (the test's oracle), not the product. The product
page was 783 pt in every one of 170+ runs; the oracle sometimes lays out its Connection group a point
taller or shorter, and keeps that value for the life of its hosting view. Which row inside the oracle
moves is not identified. The comparison now prints a per-row dump when the pages disagree, so the next
sighting will show it.

Decision (coordinator, 2026-10-17): re-measure the oracle when it disagrees; the native page stays
strictly compared. The test now:
- compares the native page with the oracle exactly as before: strict against the realized lazy stack,
  1.01 pt on the supplemental eager copy, plus document height and thumb;
- when they disagree, prints `SETTINGS-CONNECTION-ROWS` for all three pages and an `ORACLE-REMEASURED`
  line naming each difference, then builds a fresh oracle (lazy and eager), up to two more times;
- passes only if a fresh oracle matches the native page on every check, and logs `ORACLE-REMEASURED …
  matched` when one does;
- fails with every disagreement from all three oracles when none matches.

`testAnOracleThatDisagreesIsMeasuredAgain` proves the path. A first oracle forced a point taller
(Connection height, later positions, document height) is re-measured, and the second one matches. An
oracle forced off every time fails, listing all three attempts. Mutations:
- one attempt only: 3 failures;
- loosening the strict oracle checks to 1.01: 1 failure.

The class passed 3/3 after the change.

## Review round 2 (Codex, 4a59e6d3): two P2s fixed

- Webhook, branch replaced during preparation: when an edit or resend has replaced the finished
  task's branch, its last row is in no history the chat can reach. Preparation no longer falls back
  to the replacement branch's latest page. It uses the rows on screen only when they hold the task.
  Otherwise the request and reply go out empty (conservative: the webhook still reports that the
  chat finished, and never with another branch's exchange). `WebhookContext.bounded` also returns
  no rows when the rows hold none of the task's.
  - Test: `testAReplacedBranchNeverLendsItsRowsToTheExchange`. Before the fix it sent "Replacement
    request/reply" (4 failures).
  - Mutations: the old fallback, and the `bounded` guard removed, gave 6 failures between this test
    and the unit test.
- Settings retry test made deterministic: `compare` takes the oracle measurement as a closure. The
  retry test feeds measurements derived from the native page (exact, or a point taller or shorter
  in Connection with later groups and the document moved accordingly) instead of real SwiftUI
  oracles. It covers matching at once, on the second attempt, on the third, and never (+1 and −1).
  - Mutation (one attempt): 8 failures.
- Reruns: WebhookExchangeTests + WebhookTests 22/22; SettingsFullDocumentGeometryTests 2/2.

## Final gate (add1ae60)

`verify-release.sh` under the full-lane lock, 54 min 24 s, all passed:

| Suite | Result |
| --- | --- |
| Native serial lane | 890 tests, 42 skipped, 0 failures |
| Native parallel lane | 2,634 passed, 0 failed, 38 skipped |
| Helper cost | 5 passed |
| Helper suite | 966 tests, 7 skipped, 0 failures |
| Gallery | 3 passed, 230 screenshots |
| Wire / concurrent / acceptance | 36 / 4 / 3, all passed |
| Python | 86 passed |

The real Settings comparison matched on its first oracle: no `ORACLE-REMEASURED` line came from
it. The 16 such lines in the log are the deterministic retry test's.
