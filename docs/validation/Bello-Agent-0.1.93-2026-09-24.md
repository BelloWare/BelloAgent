# Bello Agent 0.1.93 validation

Date: 2026-09-24. Version 0.1.93, build 97, arm64 macOS 14+.

## Changes

- **Earlier versions of an edited message.**
  - Editing a message keeps what it replaced. The edited message shows a `‹ 2 / 2 ›` switcher, also reachable with ⌥← and ⌥→.
  - An earlier version shows read-only, with its replies, under an "Earlier version" banner. "Back to latest" returns, as does sending.
  - Its requests open in the Session Inspector, which lists an edited turn's earlier versions under it.
  - Chats edited before 0.1.93 get the switcher without anything being rewritten.
  - On the wire, rows carry `versions {index, count, ids}`, with `session.versions` and `session.version.page` to read them.
- **Fork from any reply.**
  - "Fork from here" is on every finished reply: on hover, in its menu, in earlier versions, and on the Inspector's request page.
  - A fork is a new chat that holds exactly the conversation up to that reply, even one a later compaction had summarized.
  - `session.fork` takes `atMessageId`. A reply whose tools are still running is refused with `fork_tools_running`.
- **Compaction requests named in the Session Inspector.**
  - A compaction's summary requests sit under one "Compaction · N requests" row. Each is named "earlier history", "start of this turn" (pi's split-turn prefix summary) or "part N of M" (a chained chunk).
  - The kind is read from the request's body when a page of that compaction opens; the navigator never reads bodies.
  - A summary request's Conversation tab shows its instruction first.
- **A chat keeps following after a very long reply.**
  - A reply longer than the helper's page (about 250 KiB) left no room for itself once rows followed it. The next page then shared no row with the chat, which stopped following behind Load newer, so the next question and its answer never showed.
  - The snapshot now names the row its page starts right after (`historyFollows`), and a chat whose last row is that one joins the page on.
- **A new shell gets the keyboard.** After switching projects or pressing Restart, the terminal's new shell now takes the keyboard reliably (see Evidence).
- **Tests.**
  - The Git watcher leak test counted every open file-watch stream in the process. A panel from the previous test, still closing under the parallel lane's load, could fail it. It now counts its own repository's streams, and reproduces that mechanism deterministically.
  - The opt-in live compaction test, `scripts/live-compaction-e2e.py`, and its fixture gateway join the repository.

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on `c464708`, the candidate before its terminal fix:
  - serial lane: 140 tests, 7 skipped, 0 failures;
  - parallel lane: 1,421 passed, 13 skipped, 1 failed. The failure, `TerminalPanelAuditTests.testSwitchingProjectsMovesTheTerminalAndTheKeyboardWithIt`, exposed a real race, fixed in this release (next bullet);
  - gallery: 100 screenshots;
  - helper: 424 tests;
  - scripts: wire 31, concurrent 3, acceptance 2, Python 65;
  - 9 min 38 s.
- **Terminal fix:**
  - The panel asked for the keyboard once, right after swapping sessions. That can come before SwiftUI puts the new view in the window, and after Restart it always did. A shell asked before its view is in a window now takes the keyboard when the view arrives.
  - The new `TerminalPanelAuditTests.testAShellAskedForTheKeyboardBeforeItIsShownTakesItWhenShown` fails before the fix.
  - Afterwards, every terminal class (`SmoothShellTests`, `TerminalCaptureTests`, `TerminalEmulatorTests`, `TerminalPanelAuditTests`, `TerminalPanelSerialTests`) passed: 37 tests, 1 skipped.
  - The switching test and the new test also ran 8 iterations each under 12 CPU-busy processes: 16 passed.
- **Earlier full gate on the branch before the paging and terminal fixes:** 0 failures (serial 140, parallel 1,420 passed, gallery 100, helper 423, wire 31, concurrent 3, acceptance 2, Python 65).
- **New tests:**
  - helper: `MessageVersionTests`, `ForkAtReplyTests`, `FullDisplayTests.testAPageWithNoRoomForTheReplyBeforeItNamesThatReply`;
  - app: `MessageVersionTranscriptTests`, `ForkFromReplyTests`, `InspectorSummaryRequestTests`, `TranscriptPagingTests.testALivePageThatStartsRightAfterTheLastShownRowJoinsIt`, and `HistoryEdgeTests.testTheRowsAfterAReplyLongerThanAPageStillArrive`, which fails on 0.1.92 (the answer never reaches the chat);
  - gallery scenes 19 (versions and forks) and 20 (a split-turn compaction in the Inspector).
- **Git watcher fix:** 5 parallel-lane iterations of the class (8 workers) under 12 CPU-busy processes: 65 passed, 0 failed.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed.

## Release provenance

- **Source:** tag `v0.1.93`, one release commit on GitHub. The DMG was built from the local candidate `082e94f`, with native tree `45383e4db532b9705a186fe4297a0e856b4142aa` and helper tree `f9c2d6c30eab338d24acdfd80e2f777a8e7023b4`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `06005aca8c9e20a156ae74707924aed6307a9256`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `a830b6a7-e1d6-4bd0-b563-6ad4470886a6`; DMG `2b56ff59-bc90-4cd1-8436-ace04772a69f`.
- **Public verification** at **2026-09-24 03:57:13 UTC**: the product page advertises 0.1.93, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,722,736 bytes (10.23 MiB)**; SHA-256 `c205aff7e7a12ee09f133673b7698c29c0fd6b6e6b17c443049dbfe844f53b6a`.
- **Download:** [Bello Agent 0.1.93](https://belloware.com/assets/BelloAgent-0.1.93.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
