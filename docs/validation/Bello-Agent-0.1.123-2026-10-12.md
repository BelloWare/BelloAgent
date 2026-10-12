# Bello Agent 0.1.123 — the whole chat in the scroll bar, faster find, replies kept through a crash

Status: **packaged, publication pending.** Marketing version 0.1.123, build 127. Previous public release: 0.1.122/build 126.

## Owner request

On 2026-10-11 the owner stopped the Rust port and asked to bring into the shipping Swift app what the port had found ("work on all of them"), and added a top-priority feature: scrolling a long chat "keeps loading" bounded areas and should be smooth all the way through. The owner pre-approved releasing both Bello Agent and Bello Box once the fixes and the scrolling were done, and will test scrolling by hand.

## Scope

- **Whole-chat scrolling** (`dev/smooth-scroll`, `dev/scroll-fix`, `dev/scroll-fix2`): history pages carry their position and the chat's total; the document keeps room above and below the loaded rows sized by unloaded rows × this chat's measured row height (`Transcript/TranscriptExtent.swift`, capped at 8 M points); edge pages fill their room without moving what is on screen; landing in unreached room reads the page at that row by position from the journal or the helper (newest request wins, failures retry, a changed or missing journal offers Reload). Record: `docs/perf/smooth-scrolling-0.1.123.md`.
- **Find**: pure-ASCII records that cannot hold an ASCII query are skipped by a byte scan (results unchanged, `ContentSearchTests`); records decode in parallel within 16 MiB.
- **Reply kept through a helper crash** (`dev/streaming`, `dev/stream-fix`): deltas batched every 100 ms or 16 KiB into `<journal>.stream` (`PartialReplyLog.swift`); a run cut off by the helper dying reopens with the reply as an interrupted row, as a Stop leaves it; nothing is resent. A log the journal refuses, or that cannot be set aside, is kept.
- **Chat records** (`dev/chat-records-mcp`): rows without newer keys (`toolMode`, `imported`, and the topic/read-state equivalents) decode with defaults instead of being skipped.
- **MCP**: the outcome marker is cleared only after the batch's result rows are appended and synced.
- **Terminal** (`dev/terminal-fixes`, `dev/launch-perf`): Quit ends hang-up-ignoring shells (SIGHUP, ≤ 50 ms, SIGKILL); held keys repeat; focus-out reported; only keys pressed in the terminal repeat; New stays clear of the badge in a narrow pane; ⌃` waits behind sheets and pickers.
- **Folded sides stay folded** (owner, 2026-10-12, `dev/side-fold`): starting a new side from a chat whose sides are folded in the sidebar leaves them folded (`openSide` sets `quietSidebarReveal` as a sidebar click does); other navigation still unfolds. `SidesPanelTests.testANewSideLeavesItsChatsFoldedSideListFolded` failed first and was mutation-checked; Codex no findings; side and sidebar classes (30 parallel, `SidebarInteractionTests` alone) pass on the merged tree.
- **Launch**: the menu-bar item is made after the launch window and its panel on first open. Record: `docs/perf/launch-0.1.123.md`.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- Full gate (`verify-release.sh`) on `7a60c8a7`, run alone, 45 min 58 s: native serial lane 652 (30 skipped), parallel lane 2,030 passed with 3 failures (35 skipped), helper 627 (6 skipped), helper streaming cost 5, gallery 206 screenshots, wire 34, concurrent 4, acceptance 3, Python 72. Of the three failures, `TranscriptRowUpdateTests` and `StreamingDeliveryCostTests.testRefreshRoundTripOccupancy` repeated alone (2 of 2): a regression from the scrolling work's position-recovery read, fixed on `dev/scroll-fix`; both classes then passed. `SessionMarkUnreadTests` passed 2 of 2 alone (the known Mark as Unread flake).
- After the fixes: the failed classes, paging/streaming/search/reveal classes (71 then 56 tests) and the serial `LongChatScrollTests`, `StreamedReplyEndTests`, `HistoryEdgeTimingTests` each alone passed on `bc8b3d3e` and again on `af1ca062`; helper suite 630 (6 skipped) on `bdabaad5`. `StreamedReplyEndTests.testRowsThatLeaveTheWindowAsAChatGrowsCanBeScrolledBackTo` failed once in five runs (passed in the gate and in both whole-class reruns): recorded as flaky.
- Scrolling, Release, synthetic chats: knob held at the top 14.2 s → immediate (400 turns), not reached in 60 s → immediate (2,000 turns); knob dragged to the middle of 400 turns shows turn ~193 (was 390); rows on screen 0–48 ms after the hand stops; scroller size changes over 5% while scrolling up 34 → 0; frame times unchanged; 0 jumps including wheel flings. Find, typed → marked: 400 turns 1,171 → ~450 ms; 2,000 turns 5,082 → 1,337 ms.
- Streaming durability: an acceptance test SIGKILLs the real helper mid-reply and reopens (failed before, passes after). Helper CPU while streaming 8.6% → 8.9% of a core.
- Launch, Release, warm n=15: first window 264 → 235 ms; settled 573 → 555 ms (within noise); cold 1,078 → 1,038 ms.
- Codex (gpt-6.1-sol, xhigh, read-only): every workstream reviewed by its agent and fixed to no real findings; the lead re-reviewed the scrolling branch five more times (all findings fixed test-first). The whole-release review from `v0.1.122` found two failure paths (a reply log that could not be set aside; a cut-short or missing journal retried forever), both fixed test-first and re-reviewed; the last re-review of the Reload counter found two ordering issues, fixed with tests.
- **Hour soak**, Release build of `bc8b3d3e`, seed **1790822043708**, no other builds: **passed**. 3,602 s, 178 launches (sidebar median 247 ms, max 295 ms), **0 stalls over 250 ms**, 0 row jumps, 0 slow or missing launches. Main-thread answers over 100/150/200 ms: 8/1/0; longest **176 ms** (0.1.122: 28/2/1, longest 203 ms). Footprint 99 → 733 MB, 3.58 MB per launch (0.1.122: 5.31) with the test runner's documented window retention.
- Known: during a fast scroller drag the reader sees blank room until the hand stops; the knob can drift slightly as measured heights replace the estimate; a failed recovery read on an idle chat retries on its next update; streaming CPU (~37% app) unchanged, a 30/s update cap is left for the owner to decide.
- Not done: the owner's hand test of scrolling, VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.
- During launch measurement an agent's `xctrace --launch` started the installed 0.1.122 app twice: it read the real Keychain vault (read only) and wrote the real `com.belloware.PiApp` preferences (window frame); synthetic chats only, no request sent. Reported to the owner; launch measurement now goes only through `scripts/perf-launch.sh`.

## Publication

Pending.
