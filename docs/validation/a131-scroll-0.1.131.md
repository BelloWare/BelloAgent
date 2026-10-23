# SCROLL-1: a turn reads the same however much of the chat is loaded (0.1.131)

Workstream `dev/a131-scroll`, base `dev/next` `a9f34673`. Generated fixtures and loopback only (no installed app, real chats, preferences, Keychain or provider). Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-scroll`; logs named below are in it.

The owner (2026-10-22): opening a long session showed a turn as "42 calls" when all of it was loaded, but as every call in detail when not, and the same turn changed as more loaded; scrolling felt like loading "too few elements at once"; "you can load maybe 1000 rows".

## Reproduction (dev/next, Debug)

Fixture `ToolHeavyJournal` (`apps/macos/PiAppTests/LongTurnPagingTests.swift`): 30 turns of 40–60 tool calls each (a call row and a result row per call, narration on every fifth call), an answer and the task's receipt, as the helper writes them: 2,880 rows. Opened through the app's journal reader in the real pane, compact transcript (the default). `LongTurnPagingTests` on dev/next: 2 tests, 11 failures (`run-repro-1.log`):

| | dev/next |
|---|---|
| (a) window on opening | 60 rows, first `r29_24`: inside turn 29. Turn 29 drew **97 rows**, no fold line |
| (b) the same turn once its question was read in | fold line **"54 tool calls · 11 messages"**, 3 rows drawn, 175 folded away: 94 rows went from drawn to folded |
| (c) gesture from the newest message to the first (120 pt/frame) | 2 windows, 1 starting inside a turn, 1 turn reshaped; **2 jumps** (the question row moved 3,497 pt in one frame as the turn folded under the reader); **1,322 of 1,330 frames blank** (the reader was left in the room kept for unread rows); max frame 221 ms |

## Cause

1. **Pages cut turns.** A history page was three display turns or 60 rows, whichever came first, within 256 KiB (`HistoryWindowPolicy.range`), for both the helper's `session.history` and the desktop journal reader. A coding agent's turn of 40–60 calls is 80–120 rows, so every page boundary fell inside a turn: the window always began mid-turn.
2. **A turn folds only when its question is on the page.** The compact transcript folds a finished turn's work behind "N tool calls" only if the turn's first row is on the page (`TranscriptTurnFold`: a window that begins mid-turn "cannot know what it would be hiding"). So the window's first turn showed every call, and when the page with its question landed, the same turn folded and ~100 rows collapsed under the reader.
3. **The room was sized from the detailed rows.** The scroller keeps room for unread rows at the average height of the rows laid out. Measured over the detailed partial turn (~55 pt a row), it was many times the folded turns' height, so after the collapse the reader stood in room far above any row, where position reads land only when the gesture stops.
4. Smaller contributors, all fixed: the resident window let go of rows one at a time, so it too could start or end inside a turn; the readers counted an agent's delivery (a user row inside a turn) as a turn start, where the fold does not; a call and its result could sit on different pages.
5. Once pages hold whole turns, most rows of a page are folded away, and a folded row was estimated at its open height and built and mounted (to measure one point). A page of whole folded turns stood many screens taller than it drew, and scrolling past folded turns built every hidden row (Debug: 50 s for the gesture, p50 161 ms a frame, 76 jumps, before this was fixed too).

## What changed

- **Pages hold whole display turns** (`HistoryWindowPolicy.page`, `PageFill`, `PageLimits`), shared by the helper and the journal reader: as many whole turns as fit in **250 rows and 1 MiB** (was three turns or 60 rows in 256 KiB); one turn longer than that is still read whole, up to the resident window (750 rows, 6 MB); only a turn longer still is cut (and, never held whole by any window, always shows call by call, as every turn did before). A page read around a row (find, reveal, a scroller dragged into unread rows) starts at that row's question; when that turn's rows before the row are past its byte budget, the page starts at the row so it still holds it. A turn starts at a message of the reader's, never at an agent's delivery, exactly as the fold counts turns. The live snapshot is unchanged (three turns, 60 rows, 256 KiB). The size was chosen by measurement (below): the owner's 1,000 rows made every streamed token of a long chat five to seven times as expensive as on dev/next.
- **Pages say whether they end where a turn does** (`endsTurn`, helper result key and journal page), and the window keeps that for its newer edge: the window's last turn then folds as it will once the next turn is read. A journal read through its metadata file's checkpoint does not start a page at the checkpoint's first row unless a turn starts there (it reads the whole journal for the turn's start).
- **The resident window holds whole turns** (`TranscriptPaging`): it lets go of whole turns, keeps the turns of the rows on screen whole, and only cuts a turn that alone is past its caps. Resident caps 750 rows / 6 MB (were 500 / 4 MB): three pages.
- **A position read lands on the row the reader dragged to** (`TranscriptReveal.drawablePage(at:)`), since the page now starts at that row's turn.
- **Folded rows cost nothing until opened** (`TranscriptRowContainer`, `TranscriptNativeDocument`): estimated at the one point they measure, never built, measured through a tree or mounted while their turn's fold is closed.
- **The request log is asked about the whole window** (`PayloadArchive.gatewayAccounting`): its bound on the rows one read names was 500, the old window, and `TranscriptPage.accountingPage` hands it up to the resident window. Left at 500, every chat whose window held more than 500 rows lost every reply's cost and usage line and showed "Retained cost/cache metrics unavailable" (`LiveAccountingTests` fails on this branch's first commit, `4c8ca16c`: 9 failures, `cls-acct-LiveAccountingTests.log`). The bound is now `HistoryWindowPolicy.residentRows`. SQLite here allows 500,000 bound values (a 750-row read uses 3,756) and a multi-row `VALUES` list is not held to the compound-select limit (checked with a 3,000-row list).
- Test seams: `TranscriptPaging.pageLimits` (app) and `AgentSession.limitHistoryPages` (helper), beside the existing `residentCaps`. The tests of paging mechanics written for three-turn pages run at that size through `usePlanPages(rows:)`; the new tests run at the standard limits. Opt-in probe knobs: `PI_TURN_PROBE_PAGE_ROWS`, `PI_TURN_PROBE_RESIDENT_ROWS`, `PI_LONG_PAGE_ROWS`, `PI_LONG_RESIDENT_ROWS` (page and window sizes), `PI_DELTA_ROWS` (`StreamingDeliveryCostTests`' window).

## Measurements (Release build-for-testing)

Every run held the shared full-lane lock and started and ended with a one-minute load at or under 4 (`perf/load.txt`, `perf/sweep.txt`, `perf/window.txt`, `perf/final.txt`); other workstreams build on this machine too, so one run varies by roughly ±15%. Baseline: `dev/next` `a9f34673` built the same way with only this branch's probe tests added (a temporary worktree, since removed). Probes: `LongTurnPagingProbeTests` (`PI_TURN_PROBE=1`; `PI_TURN_PROBE_TURNS=120` for the long one), `LongChatScrollProbeTests/testProbeGestureUpAndDown` (`PI_LONG_PROBE=1 PI_LONG_TURNS=400`). Gestures run from the newest message to the first and back at 120 pt a frame.

### Choosing the size: what a page and a window cost

The sweep (one run each; `perf/sweep-*.log`, `perf/turn*-after-1.log`, `perf/long-after-1.log`, `perf/window-long-p1000-1.log`, `perf/final-*.log`). Tool-heavy chat, 30 turns, 2,880 rows:

| page / window (rows) | dev/next 60 / 500 | **250 / 750** | 500 / 1,500 | 1,000 / 2,000 | 1,000 / 3,000 |
|---|---|---|---|---|---|
| First rows on screen | 402, 397 ms | **320, 323 ms** | 393 ms | 495 ms | 527, 530 ms |
| A page landing on the main thread, mean | 98 ms | **55 ms** | 116 ms | 155 ms | 207, 196 ms |
| Up: page loads; frames over 50 ms | 48; 215 of 359 | **19; 19 of 164** | 6; 10 of 256 | 3; 22 of 408 | 2; 33 of 409 |
| Down: page loads; blank frames | 40; 39 | **17; 13** | 3; 3 | 1; 1 | 0; 0 |
| Footprint after both gestures | +105, +95 MB | **+29, +21 MB** | +34 MB | +48 MB | +88, +97 MB |

Normal chat, 400 turns of 5 rows (2,000 rows):

| page / window | dev/next | **250 / 750** | 500 / 1,500 | 1,000 / 3,000 |
|---|---|---|---|---|
| Up: page loads; frames over 50 ms (of 8,030) | 70; 65 | **7; 34** | 3; 57 | 1; 121, 130 |
| Down: page loads; blank frames; p99 | 54; 98; 46.0 ms | **5; 5; 32.1 ms** | 1; 1; 31.6 ms | 0; 0; 24.1, 23.9 ms |

**What a streamed token costs grows with the window.** `TranscriptFrameBudgetTests.testWhereAStreamingDeltaSpendsItsTime` with `PI_PERF_ROWS` (the real path from the display to the drawn document, one presentation per token) and `StreamingDeliveryCostTests` with `PI_DELTA_ROWS` (`perf/window-*.log`, `perf/final-stream-*.log`, `perf/final-delta-*.log`):

| rows the window holds | 60 | 250 | 300 | 500 | 750 | 1,000 | 3,000 |
|---|---|---|---|---|---|---|---|
| A token, real path: mean (worst) | 3.0 ms | 7.0 (7.6) | 8.2 (14.2) | 12.2 | 17.5 (24.3) | 22.0 (31.6) | 61.0 (94.9) |
| Row update: apply + merge + regroup | 0.33 ms | 1.37 | 1.74 | 2.90 | 4.47 | 6.13 | 19.1 |
| Refresh round trip, reply to published (median) | 0.65 ms | 1.62 | 1.83 | 2.94 | 4.56 | 5.93 | 18.3 |

About 0.02 ms a row a token. A sample of the 3,000-row case (`perf/profile-stream.sample.txt`) shows why: for every token `TranscriptNativeDocument.update` visits every row (`TranscriptRowContainer.update(item:)`, the `messageRows` index), `SessionDisplay.presentedMessages` maps every row and `TranscriptActivity.patch` compares every row. None of that is new here, but it makes the window's size the price of every token of a reply; production presents at most 30 times a second, so at 3,000 rows a reply alone would take the main thread whole. On dev/next a chat just opened streamed into its 60-row page, at most 500 rows.

Also measured: the request log's read of a whole window (`LiveAccountingTests`, three requests in the archive) 15.7 ms at 750 rows and 59.5 ms at 3,000; a helper page decoded on the main thread (`TranscriptMessage.page`) 5.6 ms for 250 tool-heavy rows, 22.5 ms for 1,000; profiled, a 1,000-row journal page reads in about 150 ms off the main thread, 60% of it decoding JSON, 15% the offset index and 15% weighing each row.

**Chosen: pages of 250 rows (1 MiB) in a window of 750 rows (6 MB).** Against dev/next it reads a tool-heavy chat back in 19 loads instead of 48 and a normal chat in 7 instead of 70, opens faster, lands each page in about half the time, never starts a window inside a turn, and keeps a reply's tokens at 7 ms in a chat just opened (dev/next 3 ms) and 17.5 ms with a full window (dev/next 12.2 ms at its 500). The owner's 1,000 rows would have read the same chat back in two loads, but streamed a reply in a chat just opened at 22 ms a token and, with a full window, at 61 ms; it waits on making a token's cost independent of the window. The owner confirmed the choice on 2026-10-23: "250 now, 1,000 later" (Open items, 1).

### dev/next against this branch

Tool-heavy chat, 30 turns (two runs each; `perf/turn1-base-1.log`, `perf/turn2-base-1.log`, `perf/final-turn1-1.log`, `perf/final-turn2-1.log`):

| | dev/next | this branch |
|---|---|---|
| First rows on screen (journal read) | 402 / 397 ms (232 / 227) | 320 / 323 ms (256 / 259) |
| Window on opening | 60 rows, inside turn 29 | 206 rows, turns 28–29 whole |
| A page: read off the main thread; landing on it, mean / max | 12 ms; 98 / 295 and 98 / 217 ms | 28 ms; 55 / 67 and 55 / 66 ms |
| Up: time; frame p50 / p95 / p99 / max | 39.4 / 37.8 s; 58 / 348 / 512 / 702 and 65 / 356 / 453 / 516 ms | 4.1 / 4.1 s; 17.7 / 69 / 90 / 187 and 17.7 / 69 / 94 / 179 ms |
| Up: loads; jumps; rows lost; blank frames | 48 / 47; 5 / 10; 0 / 1; 1 / 6 | 19 / 19; 0 / 0; 0 / 0; 0 / 0 |
| Down: time; p95; loads; blank frames; jumps | 30.4 / 30.2 s; 439 / 435 ms; 40 / 40; 39 / 38; 2 / 2 | 3.0 / 3.0 s; 61 / 60 ms; 17 / 17; 13 / 15; 0 / 0 |
| Windows starting inside a turn | 84 of 87, 86 of 88 | 0 of 35, 0 of 35 |
| Footprint after both gestures | +105 / +95 MB | +29 / +21 MB |

Tool-heavy chat, 120 turns, about 11,500 rows (one run each; `perf/huge-base-1.log`, `perf/final-huge-1.log`):

| | dev/next | this branch |
|---|---|---|
| First rows on screen | 1,046 ms | 956 ms |
| Up: time; p95 / max; loads; jumps; lost | 176 s; 404 / 590 ms; 191; 34; 1 | 14.8 s; 85 / 176 ms; 91; 0; 0 |
| Down: time; p95 / max; loads; blank frames | 148 s; 450 / 891 ms; 184; 192 | 12.2 s; 62 / 71 ms; 91; 58 |
| Windows starting inside a turn | 368 of 376 | 0 of 175 |
| Footprint after both gestures | +90.7 MB | +14.2 MB |

Normal chat, 400 turns of 5 rows (`perf/long-base-1.log`, `perf/final-long-1.log`):

| | dev/next | this branch |
|---|---|---|
| Up: frame p50 / p95 / p99 / max; over 50 ms; loads | 16.7 / 28.2 / 47.0 / 123 ms; 65; 70 | 16.7 / 27.0 / 39.9 / 134 ms; 34; 7 |
| Down: p95 / p99 / max; over 50 ms; loads; blank frames | 25.1 / 46.0 / 146 ms; 67; 54; 98 | 22.6 / 32.1 / 106 ms; 24; 5; 5 |

Budget and scroll groups, unchanged within noise (`perf/budget-base-1.log`, `perf/final-budget-1.log`, `perf/scroll-base-1.log`, `perf/final-scroll-1.log`): a token into 300 rows 8.2 → 8.2 ms; folding / unfolding a 60-tool turn 8.3 / 4.3 → 8.2 / 4.2 ms; 300 rows open, first paint 38 → 37 ms; switching to a 300-row chat, cold 34 → 31 ms, back 23 → 23 ms; scrolling 400 rows 0.18 ms mean, worst 14.8 → 9.0 ms; 300 rich rows p95 6.15 → 4.52 ms; an 88 KB answer p95 0.250 → 0.241 ms.

## Tests

Commands (`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-scroll`, from the worktree):

```
python3 scripts/build-bundle.py
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $PI_BUILD_ROOT/native-tests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO
xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath $PI_BUILD_ROOT/native-tests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -parallel-testing-enabled NO \
  -only-testing:PiAppTests/<Class>          # serial-lane classes one per run; the parallel-lane classes in one run
swift build --package-path packages/swift-host --scratch-path $PI_BUILD_ROOT/swift-verify --build-tests
swift test --package-path packages/swift-host --scratch-path $PI_BUILD_ROOT/swift-verify --skip-build --filter 'PiAgentCoreTests\.(<Class>|…)'
python3 scripts/test-native-host.py $PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host \
  NativeIntegration.test_a_result_beyond_the_frame_limit_is_read_back_whole_through_a_display_transfer
# Release: build-for-testing -configuration Release -derivedDataPath $PI_BUILD_ROOT/release-after ENABLE_TESTABILITY=YES
# CODE_SIGNING_ALLOWED=NO, then test-without-building -xctestrun <its .xctestrun> with the TEST_RUNNER_PI_* probe variables.
```

**Failing first.** On `dev/next` `a9f34673`: `LongTurnPagingTests` 2 tests, 11 failures (`run-repro-1.log`, the reproduction above). On this branch's first commit `4c8ca16c`: `LiveAccountingTests` 10 tests, 9 failures (`cls-acct-LiveAccountingTests.log`), all in `testFullNativePageKeepsAccountingPastTheOldHundredRowLimit`.

**Final code, Debug** (`final3.txt`, `cls-final3-<Class>.log`, `final3-parallel.log`). Serial-lane classes, one run each, all passing: `LongTurnPagingTests` 3, `HistoryTurnPagingTests` 2, `TranscriptPagingTests` 9, `HistoryExtentTests` 26, `TranscriptRevealTests` 12, `FreshPresentationTests` 21, `HistoryEdgeTests` 16, `TranscriptFindTests` 11, `WorkspaceRefreshLifecycleTests` 38, `StreamedReplyEndTests` 5 (1 skipped), `SubagentReaderTests` 60, `TranscriptTurnFoldTests` 24, `NativeTranscriptDocumentTests` 10, `NativeTranscriptScrollTests` 5, `TranscriptFrameBudgetTests` 6, `ChatOpenPlacementTests` 5, `HistoryEdgeTimingTests` 2, `HistoryEditTests` 3, `InheritedSubagentReaderTests` 8, `LongChatScrollTests` 6, `TranscriptWirePageTests` 4: **276 tests, 1 skipped, 0 failures**. Parallel-lane classes in one run (`CompactTurnReportTests`, `ConversationSearchPagingTests`, `ForkCloneReaderTests`, `HardeningTests`, `HistoryIndexFilesTests`, `HistoryReaderCheckpointTests`, `HistoryReaderOpenPerformanceTests`, `HistoryReaderStateTailTests`, `LaunchSelectionTests`, `LiveAccountingTests`, `LongJournalHistoryTests`, `NativeDeferredViewTests`, `NativeTranscriptSafetyTests`, `NativeTranscriptTests`, `ReportMessageNavigationTests`, `SideTests`, `StreamingDeliveryCostTests`, `SubagentDisplayTests`, `SubagentTranscriptTests`, `TranscriptActivityTests`, `TranscriptDisclosureTests`, `TranscriptGeometryCacheTests`, `TranscriptHeightSamplingTests`, `TranscriptKeptRowsTests`, `TranscriptNativeEverywhereTests`, `TranscriptNativePaneBehaviourTests`, `TranscriptNativeTurnBehaviourTests`, `TranscriptNativeTurnParityTests`, `TranscriptRowChangeTests`, `TranscriptRowUpdateTests`, `TranscriptStreamingScrollTests`, `TranscriptStreamingStressTests`, `WorkspaceConcurrencyTests`, `WorkspaceDisplayMemoryTests`, `WorkspaceLoadingTests`, `WorkspaceRaceTests`, `WorkspaceTests`): **37 classes, 353 tests, 3 skipped, 0 failures**.

**Helper.** The classes that read history pages (`HistoryWindowTests`, `FullDisplayTests`, `MessageVersionTests`, `HistoryFillTests`, `IncompleteRetryTests`, `HistoryReadCancellationTests`, `OlderRowsTests`, `QueueEditHoldTests`, `JournalCheckpointTests`, `ForkPerformanceTests`, `ContinueRunTests`, `TaskPresentationTests`, `SessionOpenPerformanceTests`, `HostDispatchTests`, `ForkReplayHandoffTests`, `ForkCloneTests`, `ToolRecordingFailureTests`, `ToolOutcomeTests`, `ToolLineTests`, `TimelineDurabilityTests`, `SubagentPermissionTests`, `SessionSettlementTests`, `RetryTests`, `PartialReplyLogTests`, `ForkAtReplyTests`, `DisplayObservationTests`, `ConversationReadTests`, `AcceptanceTests`): 237 tests, 7 skipped, 1 failure (`helper-final2.log`): `FullDisplayTests.testLargeHistoryRowIsCompleteAndEveryPageRemainsReachable`, whose answer "longer than a page" was sized for 4 MiB pages and is past the whole 6 MB window at 1 MiB pages. Sized from `pageBytes` now (test only); `FullDisplayTests` and `HistoryWindowTests` again: 13 tests, 0 failures (`helper-fd2.log`). (The full helper suite ran once at the first commit's limits: 1,187 tests, 8 skipped, 1 failure in this same test, since rewritten: `helper-full-1.log`.)

**Wire.** `session.history` gained the `endsTurn` key; the one wire test that reads it: OK with the final helper (`wire-history-p250.log`). Concurrent and acceptance wire suites do not read history pages.

**Mutations** (each applied alone or with one caught by other tests, Debug rebuilt, named classes run, originals restored; rounds A–G at the first commit's 1,000 / 3,000 limits, P1–P4 again at 250 / 750; `mutA.txt`…`mutF.txt`, `helper-mutE.log`…`helper-mutG.log`, `mutations-p250.txt`):

| Mutation | Caught by |
|---|---|
| M1 pages not aligned to turn starts | `LongTurnPagingTests` (window opens inside turn 27, 10 of 11 windows mid-turn, a turn reshapes, a jump), `HistoryTurnPagingTests` (16), helper `HistoryWindowTests` (3,338) |
| M2 an agent's delivery starts a turn | `TranscriptPagingTests` (2), `HistoryTurnPagingTests` (18), helper `HistoryWindowTests` (5) |
| M3 the window lets go of rows one at a time | `TranscriptPagingTests` (5) |
| M4 a full page keeps every row it read | helper `HistoryWindowTests.testAPageFilledWithinItsBytesKeepsWholeTurns` |
| M5 the window's newer edge ignores `endsTurn` | `LongTurnPagingTests` (18: the window's last turn loses its fold) |
| M6 a folded row estimated at its open height | `LongTurnPagingTests` (9 jumps; 65 at the first limits) |
| M7 folded rows built and mounted | `LongTurnPagingTests` (1,074 trees built; 1,408 at the first limits) |
| M8 a read around a row never restarts at the row (app; helper) | `TranscriptRevealTests`; helper `HistoryWindowTests` |
| M9 a checkpoint index's first row taken for the chat's start | `HistoryTurnPagingTests` |
| M10 a position read lands on the page's first row | `HistoryExtentTests` |
| M11 the request log's bound back at 500 rows | `LiveAccountingTests` (7: "metrics unavailable", no figures) |

After the last round no mutation marker is left and every mutated file is byte-identical to its saved original; the Debug build was rebuilt from them (`build-restored.log`).

## Review round 2 (Codex Astra, on `9185743c`)

Three findings, each fixed with a test that failed first (`r2fail` logs: the tests below on the unfixed code; `r2fix` logs and `r2-wide2.txt`: after):

1. **The journal reader weighed rows before their results filled the call cards** (`HistoryReader.decodePage`). A saved turn of a hundred 32 KiB tool results was admitted at 3.3 MB, and `resolvingToolResults` then copied each output into its call's card, keeping the result row: 6.7 MB as the window weighs it, past its 6 MB. Installed whole and folded, the turn lost its question at the next update and unfolded. Rows are now weighed as encoded or as the window holds them, whichever is more, plus each result's output once more for its call's card; a turn too heavy for the window then reads as the cut turn it is. Test: `HistoryTurnPagingTests.testAPageOfLongToolResultsFitsTheWindowItOpens` (unfixed: the page held 6,712,023 bytes and the next window let go of its first rows).
2. **A read into a turn longer than the window added nothing** (`TranscriptPaging.window(_:keeping:keepingEarlier:)`). With a 1,500-row turn open at its last 750 rows and rows 750–759 on screen, the turn's earlier rows were more than the window had, so the window kept only the ten rows on screen, the read added none and `loadHistoryPage` refused it; the newer direction stalled the same way. A turn the window can never hold whole now gives the rows of it nearest the kept ones that there is room for (a turn that fits on its own still comes whole or waits), and the window's earlier edge names that turn's question (`TranscriptPaging.partialTurnInput(of:in:fallback:)`, used by `loadHistoryPage`). Tests: `TranscriptPagingTests.testATurnTooLongForTheWindowGivesTheRowsThereIsRoomFor` (unfixed: 10 rows kept in both directions) and `HistoryTurnPagingTests.testAReadIntoATurnLongerThanTheWindowAddsTheRowsThereIsRoomFor` (the real reads, both directions; unfixed: both refused).
3. **A page around a row exactly a page's reach from its question missed the row** (`HistoryWindowPolicy.page`). `page(count: 1500, around: 750, startsTurn: { $0 == 0 })` returned `0..<750`; both readers then left out the row find, reveal or a position read asked for. The page now starts at the question only while the page from there still reaches the row, else at the row. Tests: helper `HistoryWindowTests.testAPageAroundARowAsFarFromItsQuestionAsAPageReachesHoldsTheRow` (unfixed: 6 failures) and `HistoryTurnPagingTests.testAPageAroundARowAsFarFromItsQuestionAsAPageReachesHoldsIt` (the journal reader's around and position reads).

After the fixes (Debug, pinned helper rebuilt): serial-lane `HistoryTurnPagingTests` 5, `TranscriptPagingTests` 10, `LongTurnPagingTests` 3, `HistoryExtentTests` 26, `HistoryEdgeTests` 16, `HistoryEdgeTimingTests` 2, `FreshPresentationTests` 21, `TranscriptRevealTests` 12, `TranscriptFindTests` 11, `LongChatScrollTests` 6, `WorkspaceRefreshLifecycleTests` 38, `StreamedReplyEndTests` 5 (1 skipped), `SubagentReaderTests` 60: 215 tests, 0 failures; parallel-lane `WorkspaceLoadingTests`, `HardeningTests`, `NativeTranscriptTests`, `LongJournalHistoryTests`, `HistoryReaderCheckpointTests`, `HistoryIndexFilesTests`, `ConversationSearchPagingTests`, `HistoryReaderStateTailTests`, `HistoryReaderOpenPerformanceTests`, `ForkCloneReaderTests`: 52 tests (2 skipped), 0 failures (`r2-wide2.txt`, `r2-parallel.log`); helper `HistoryWindowTests` and `FullDisplayTests`: 14 tests, 0 failures (`helper-r2fix.log`). A first try weighed journal rows by the window's measure alone; `FreshPresentationTests.testOversizedTurnSegmentsKeepInputReferenceAndFullContentAccess` caught its page then passing one envelope as encoded (274,899 of 262,144 bytes, `r2-wide.txt`), hence the larger of the two.

## Review round 3 (Codex Astra, on `7dc15370`)

Two regressions of whole-turn paging, each fixed with a test that failed first (`cls-r3fail-*.log`; after: `r3.txt`):

1. **A saved place inside a finished turn's work reopened folded away** (`TranscriptPage.receive`). A cold reopen reads the page around the saved row (`readInitialWindow`), which now starts at the turn's question, so `TranscriptTurnFold` folded the turn over the row; a restored place, unlike a reveal, never called `unfoldTurn`, and the page placed the reader on the hidden row's one-point frame. Restoring a place now opens the fold that hides its row before the rows are drawn (the reveal's own `openFold`); a place no fold hides opens nothing. Test: `LongTurnPagingTests.testAPlaceSavedInsideAFinishedTurnReopensWithThatTurnOpen`: a 30-turn tool-heavy journal, the place saved in the store at a call in turn 5, a cold `select` (unfixed: the row folded away, no fold open; fixed: turn 5's fold alone opens).
2. **The fold commands planned a window's last turn as unfinished** (`WorkspaceModel.commandItems`). The transcript folds the last turn of a window that ends where a turn does (`endsTurn`), but the keyboard and menu planner still required no newer rows, so Unfold Every Turn and Unfold This Turn left that turn folded. Both now read `ConversationPageBoundary.lastTurnFinished`. Test: `TranscriptTurnFoldTests.testTheFoldCommandsReachTheLastTurnOfAWindowThatEndsWhereATurnDoes` (unfixed: the commands planned `["u1"]` against the page's `["u1", "u2"]` and left `u2` folded).

After the fixes (Debug), one class per run: `TranscriptTurnFoldTests` 25, `LongTurnPagingTests` 4, `SmoothPaneAndKeyboardTests` 4, `ResponseChronologyTests` 14, `LaunchSelectionTests` 21, `NativeTranscriptDocumentTests` 10, `NativeTranscriptSafetyTests` 5, `NativeTranscriptTests` 5, `HistoryEdgeTests` 16, `ChatOpenPlacementTests` 5, `TranscriptRevealTests` 12, `TranscriptFindTests` 11, `HistoryExtentTests` 26, `InheritedSubagentReaderTests` 8, `SubagentReaderTests` 60: 226 tests, 0 failures.

## Review round 4 (Codex Astra, on `6b55e60b`)

**The helper paged a chat reopened from its metadata file as though its loaded rows began the chat** (`AgentSession.historyWindow`). Those rows begin after the last compaction, which can split a turn, so the first of them can be inside a turn whose question was not loaded. With `firstIsStart` left at true, the newest page took that loaded tail from the "chat's first row", call by call, and reading earlier then completed the turn and folded it: the grouping change SCROLL-1 removes (the journal reader already started at the first question among its loaded rows). The helper now passes `firstIsStart: shown.base == 0`, and a page whose first turn began before the loaded rows loads where the older rows are and is read again, as `HistoryReader.read` re-indexes the whole journal. Test: helper `HistoryWindowTests.testAReopenedChatsPagesStartAtAQuestionWhenItsLoadedRowsBeginInsideATurn`, a chat whose manual compaction cut its last turn at that turn's answer, reopened from its metadata file. Unfixed, the newest page started at the answer instead of the next question, and the page before ended inside the split turn (`helper-r4dbg.log`). Fixed, the newest page starts at the first loaded question and the page before holds the split turn whole, from its question to the newest page's start (`helper-r4fix-one.log`).

After the fix: helper `HistoryWindowTests`, `FullDisplayTests`, `OlderRowsTests`, `JournalCheckpointTests`, `HistoryFillTests`, `HistoryReadCancellationTests`, `ForkCloneTests`, `SessionOpenPerformanceTests`, `ConversationReadTests`, `CommandReceiptsTests`, `DurableReplayTests`, `MessageVersionTests`, `TimelineDurabilityTests`: 13 classes, 104 tests (6 skipped), 0 failures (`helper-r4.log`); the history-paging wire test with the rebuilt release helper: OK (`wire-history-r4.log`).

## Unrelated failures

- `TranscriptDisclosureTests.testACardAndReasoningMoveOnTheSameCurve` failed on this machine, run on its own, with the same 8 assertion failures on pure `dev/next` `a9f34673` (all of this branch's changes stashed, Debug rebuilt: `cls-base-TranscriptDisclosureTests.log`) as on this branch (`cls-b-TranscriptDisclosureTests.log`); it passed in the final parallel-lane run and in the 0.1.130 gate (`build-lead/verify-logs/suite-serial.log`). Not investigated further.
- `StreamingDeliveryCostTests.testPerDeltaStageCostsWithRowUpdates` holds a Release build to 1 ms a token for applying, merging and regrouping a row update in its default 300-row window; on this machine it measures 1.74 ms (`perf/window-delta-300-1.log`), the regroup (`TranscriptActivity.patch`) 1.38 ms of it. None of the code it times is changed by this branch; the Debug gate holds it to no absolute number (`releaseBudget`).

## Open items

1. **The page size: decided.** The owner, 2026-10-23: "250 now, 1,000 later". 0.1.131 ships 250-row pages in a 750-row window (a below). Once this branch is merged, a follow-up makes a streamed update cost only what changed (b) and then raises pages to 1,000 rows; it is not part of this branch. The options as measured:
   - (a) Keep 250 / 750: 19 loads to read the tool-heavy chat back, 7 for the normal one; a token costs 7 ms in a chat just opened (dev/next 3 ms) and up to 17.5 ms with a full window (dev/next 12.2 ms).
   - (b) First make a streamed token cost what changed rather than the whole window (`TranscriptNativeDocument.update`, `SessionDisplay.presentedMessages` and `TranscriptActivity.patch` each walk every row per token), then raise pages to the owner's 1,000 rows: 2 loads for the same chat. A performance project of its own, in the streaming path.
   - (c) 1,000 / 3,000 now: 2 loads, but 22 ms a token in a chat just opened and up to 61 ms with a full window.
   - (d) 500 / 1,500: 6 loads; about 12 ms a token just opened, up to about 31 ms.
2. **Turns longer than the window** (more than 750 rows, about 375 tool calls) are cut and always show call by call, as every turn did before. Options: keep (chosen); a larger window (each 250 rows adds about 5 ms to a token with a full window); fold a turn the window cannot hold as "at least N tool calls".
3. **The live snapshot** (three turns, 60 rows, unchanged) still starts inside a tool-heavy turn when it is all a window holds (a new chat, a branch adopted fresh); the next read makes that turn whole and it folds then. Every history read, the one that opens a chat among them, is whole turns.
4. **Landing a page** takes about 55 ms of the main thread (250 tool-heavy rows), so a fast gesture through a tool-heavy chat has one 55–70 ms frame at each load: the up gesture's p95 of 69 ms is those frames. Most of it is building a row container for each row, folded or not.
5. **The read-back probe** (`testProbeOpeningAndReadingBack`) asks for earlier pages with the reader at the bottom; once the window is full each read is let go of again (dev/next did the same at 500 rows), so its count of pages is its ceiling of 200, not a measure. The gestures, which read where the reader is, are the measure.
6. **Version views** read an earlier version up to the resident window: 750 rows, was 500 (`WorkspaceVersions`).
7. **Memory:** up to eight kept displays of 6 MB of rows each (was 4 MB).
8. **The journal reader weighs a row** by encoding its display message (`JSONEncoder`, 15% of a page's read); the helper weighs the wire row. The same budgets, measured slightly differently.
9. **Merging:** `dev/a131-open` also changes `WorkspaceHistory.swift` and `WorkspaceRefresh.swift`.
