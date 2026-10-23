# OPEN-1: a chat that just finished opens at once — 0.1.131

Workstream `dev/a131-open` (Claude subagent), based on `2ea73777` (`dev/next`).
Worktree `/Users/admin/Library/Caches/BelloSwiftWork/wt-a131-open`; build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-open`, whose `evidence/`
folder holds the text logs named below. All data is generated: chats are
written by the tests against the loopback fixture gateway
(`fixtures/native/ui-gateway.py`) and the packaged helper; workspaces use
isolated state and `MemoryVaultStorage`. No installed app, real chat,
preference, Keychain item, capture or provider call is used; no release, tag or
`main`/`dev/next` write. Every Release timing run and every focus (serial-lane)
run held the shared full-lane lock for that run only (owner line
"a131-open perf" for timing runs), waited for a 1-minute load under 4, and
records the load at its start and end and the highest 1-minute load sampled
during it. Builds started only while no perf or soak run held the lock.

Owner, 2026-10-22: "when I have multiple sessions running, and then one of them
is complete, when I click on it, it actually could take a lot of time for, you
know, for it to be loaded, which is really bad, because it doesn't make sense
to me, because I mean it just finished."

## Cause

A chat in the background is asked for its status, not its rows
(`WorkspaceModel.refresh`: `session.status`, no messages), so a chat the reader
left while its reply was arriving keeps that reply as it was: a streaming row,
its turn still live. Since 0.1.114 (`6a79272e`, found by the soak) opening such
a chat after its run has finished drops those rows (`heldRowsOutlived`), so that
they cannot change under the reader, and the chat opens as a chat opened for the
first time:

1. the page is blank from the click, and the loading cover comes up at 150 ms;
2. everything is read before its first row, in order: which of another chat's
   agents it refers to (`readInheritedSubagents`: a scan of the whole journal,
   since the run changed it), the draft and pending input, the page from the
   helper, and the page's figures (up to 150 ms);
3. every row is then built and placed from scratch under the cover. A chat that
   was running when the reader left it keeps no rows in the pane
   (`TranscriptKeptRows` keeps settled chats only), and the shared geometry
   cache does not take rows with tool calls.

An idle chat the reader comes back to instead shows the rows the pane kept at
once and reads its page behind them. So a chat that had just finished took the
slowest opening there is, which is the owner's "it doesn't make sense". The
other running chats were not the cause: in the probe below the helper's page
read took 8–23 ms and the figures 2–13 ms with three chats streaming, and the
same opening long after every run had ended took as long (154 ms both).

What grows with a real chat is step 2's journal scan and step 3. The scan
(`HistoryReader.subagentRecords`, 64 KiB reads, four `Data.range(of:)` searches
per line) measured 5.6 ms per MiB with `-O` (`evidence/scan-bench.swift`:
57 ms for 10 MiB, 280 ms for 50 MiB), and it ran on every opening after a run
because its cache is keyed by the journal's revision.

## Fix

- **The finished page is read as the run ends** (`catchUpFinishedRows`,
  `WorkspaceSelection.swift`). When the snapshot loop applies a status to a
  chat out of sight whose run has finished with rows it has outlived, the chat's
  page is read as opening it reads it (`readInitialWindow`, `withAccounting`:
  figures and all) and put on its display without presenting it
  (`adoptPage(presenting: false)`, the row half of `adoptInitialHistory`, now
  shared by both). Opened afterwards, its rows are no longer outlived, so it
  opens as a revisit does: its finished rows on the page at once, uncovered, the
  page read behind them, which brings the same rows and changes nothing.
- **What the opening scans is read then too.** After the page, the same read
  scans the journal for the opening (the inherited plans, and the coordination
  of a chat with agents of its own), so the opening finds both cached instead
  of scanning the whole file again. Since round 2 the scan runs off the shared
  `HistoryReader` (`scanPlans`, `scanCoordination`) and only its result is kept
  there, for the journal revision it read.
- **It gives way.** The read lands only while the chat is still out of sight,
  on the same display and presentation, with the same journal, and still idle
  with outlived rows: a chat opened, running again, moved to another journal or
  let go of, or a model shutting down, keeps what it has. One read at a time
  per chat; a failed read leaves the chat to be read as it opens. Chats on
  screen (the selection, its side, a sub-agent tab) already get their rows;
  sub-agents and background requests are not read this way.
- **Opened before the read lands** (a page and its figures, read a moment
  after the run's end), the chat opens as before 0.1.131: rows dropped, read
  behind the cover. Every opening the probe made 0.5 s after a run's end found
  the finished rows already held.
- **A run's end counts as a use of its chat** (owner decision, 2026-10-23;
  round 2 below). Past eight open chats, `releaseUnreadDisplays` lets go of the
  display of the one used longest ago, and a chat that ran a long time out of
  sight was usually that one: once its run had ended, opening any other chat
  let go of it, finished rows and all, and its next opening was a first
  opening. A run that ends while its chat is out of sight now moves the chat to
  the front (`used`, set where the snapshot loop sees the run end), so it keeps
  its display. Memory stays bounded at eight.
- Test seams: `openSteps` (each step of an opening, with its time, as
  `sendSteps` does for a send) and `catchesUpFinishedRows` (off: read as it
  opens, as before, so one build can compare both).

Files: `WorkspaceSelection.swift` (the read, the steps), `WorkspaceRefresh.swift`
(one call after a snapshot of a chat out of sight; round 2: a run's end counts
as use), `WorkspaceHistory.swift` (`adoptPage` split out of
`adoptInitialHistory`, behaviour unchanged; round 2: `followsNavigation`),
`SessionDisplay.swift` (the read in flight), `WorkspaceModel.swift` (seams),
`SubagentDiscovery.swift` and `AgentCoordination.swift` (round 2: the scans as
`nonisolated static` functions, behaviour unchanged), and the generated project
for the two new test files. None of the files the other 0.1.131 workstreams own
is touched.

## Reproduction and timings

`FinishedChatOpeningTests.testWhereOpeningAChatThatJustFinishedSpendsItsTime`
(opt-in, `PI_OPEN_PROBE=1`): the real window (1280 × 820, so the floating
Agents/Diff/Files card is shown), the packaged helper and the fixture gateway.
Five chats, each grown while shown by six rounds of a read tool call over a
30 KB file and a 24 KiB Markdown reply (60 rows held, 949 KiB journal each).
Each round starts a long streamed reply (“A large answer”, about 10 s) in four
chats, each while it is shown, then goes to an idle chat. The first of them is
opened 0.5 s after its run ends while the other three still stream (“just
finished”); another is opened 3 s after every run has ended (“finished long
ago”). Openings go through `openFromSidebar` and are timed from the call,
sampling the page every 2 ms: the chat's first rows on screen, ready, settled
(ready, and no row moving for 0.5 s), whether it opened covered, and any row
that moved once drawn; `openSteps` gives each step's time. Rounds alternate the
read as the run ends off (`catchesUpFinishedRows = false`: as before) and on,
in one Release build (`evidence/release-final-session.log`; 1-minute load 3.09
at its highest).

| Opening (Release, median of 3, range) | First rows | Settled | Covered | Rows moved |
| --- | --- | --- | --- | --- |
| Just finished, 3 others running — before | 154 ms (151–184) | 176 ms | 3 of 3 | 0 |
| Just finished, 3 others running — now | **97 ms** (94–109) | 136 ms | **0 of 3** | 0 |
| Finished long ago, nothing running — before | 154 ms (147–177) | 177 ms | 3 of 3 | 0 |
| Finished long ago, nothing running — now | **96 ms** (95–96) | 140 ms | **0 of 3** | 0 |
| Revisit of an idle chat whose rows were kept | 37–58 ms | 75–171 ms | no | 0 |
| A chat still running (rows held, not kept) | 91 ms | — | no | (streaming) |

Where the time went, round 1 (before): the page blank from the click; the
inherited agents read at 39 ms, draft 40, page 51, figures 64, adopted 65 ms;
the whole page then built and placed under the cover until 186 ms. Round 2
(now): the finished rows are built at once (first rows at 94 ms; the main
thread is building them), and the reads follow behind them and change nothing
(inherited agents at 94 ms, a cache hit; page 131; adopted 134 ms).

An earlier pair of builds, the call that starts the read removed and present,
gave the same picture with one sample each: 186 ms covered against 136 ms
uncovered (`release-before-session.log`, `release-after-session.log`; the
latter's load ended at 4.09, so it was redone as the comparison above).

The probe's chats are small. In a long chat the opening without the fix also
scans the whole journal before its first row (5.6 ms per MiB above) and builds
a longer page under the cover; with the fix both happen out of sight or behind
rows already shown.

First rows still take about 95 ms, against 37–58 ms for a revisit, because the
chat was running when the reader left it: the pane kept none of its rows, so
they are built at the opening (a chat still running costs the same, 91 ms).
Part of that is PERF-1 (a131-layout): beside the floating card each reply's
text is laid out twice.

## Tests

- `ChatOpenPlacementTests.testAChatThatJustFinishedOpensOnItsFinishedRowsAtOnce`
  (new, serial lane; real window, helper and gateway). A long reply is left
  arriving, a second chat is still running, and the first finishes while a third
  is shown. Its finished rows reach it while it is out of sight; from the moment
  it is the selection the finished reply is on the page and nothing covers it;
  the rows it opened on are exactly the page its opening reads (ids, texts and
  states: its saved history); its reply is unread until the page reports it,
  then read; and no row moves once drawn (4 ms samples for 2.5 s).
  **Failing first:** on a Release build with the call that starts the read
  removed (the base behaviour for this flow), 4 failures
  (`release-before-session.log`): the finished reply never reached the chat
  out of sight, it was not on the page at once, the page was covered, and the
  rows held (the reply as left, streaming) were not the page. That build is
  also the mutation check for the call.
- `FinishedRowsCatchUpTests` (new, parallel lane, 6 tests; history reads
  through `historyWindowLoader`, no helper): a finished chat out of sight holds
  its finished page without presenting it and opens on it uncovered (one read
  as the run ends, one as it opens); without that read the same opening is
  covered (the fallback, as before); an opening while the read is in flight
  shows its own page and the late read changes nothing; a chat running again
  keeps its rows; only a finished chat out of sight with outlived rows is read
  (not one running, on screen, or with the seam off); and after the read the
  opening scans none of the journal again (`subagentScannedBytes`).
  **Mutations** (Debug, each with the other five passing): without the
  journal read the opening rescans 207,206 bytes
  (`testTheOpeningFindsItsJournalScannedAlready` fails,
  `debug-mutation-warmup.log`); without the “still outlived” check a running
  chat gets the finished page (`testAChatRunningAgainKeepsItsRows` fails,
  `debug-mutation-running.log`).
- `FinishedChatOpeningTests` (new, serial lane): the probe above; it skips
  unless `PI_OPEN_PROBE=1`.

## Validation

`B=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-open`. Release:
`xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp
-configuration Release -destination 'platform=macOS,arch=arm64'
-derivedDataPath $B/native-release ENABLE_TESTABILITY=YES
CODE_SIGNING_ALLOWED=NO`, then `xcodebuild test-without-building -xctestrun
<its .xctestrun> -parallel-testing-enabled NO -only-testing:PiAppTests/<Class>`
under the lock (`TEST_RUNNER_PI_OPEN_PROBE=1` for the probe). Debug: the same
with `-derivedDataPath $B/native-tests CODE_SIGN_IDENTITY=-
CODE_SIGNING_REQUIRED=NO`, serial classes under the lock.

| Run | Classes | Result |
| --- | --- | --- |
| Release, final | FinishedChatOpeningTests (probe), ChatOpenPlacementTests, FinishedRowsCatchUpTests | 1, 6, 6 passed |
| Release, call removed | ChatOpenPlacementTests (new test); FinishedRowsCatchUpTests | 4 failures (expected); 6 passed |
| Debug, serial lane | ChatLoadStabilityTests 1, ChatOpenPlacementTests 6, FreshPresentationTests 21, HistoryEdgeTests 16, HistoryExtentTests 25, InheritedSubagentReaderTests 8, SessionReadStateTests 16, WorkspaceRefreshLifecycleTests 38, FinishedChatOpeningTests 1 skipped | 132 executed, 0 failures |
| Debug, parallel lane | FinishedRowsCatchUpTests 6, SubagentDiscoveryTests 15, WorkspaceLoadingTests 13 | 34 passed |
| Debug, final code | FinishedRowsCatchUpTests; ChatOpenPlacementTests and FinishedChatOpeningTests (under the lock) | 6 passed; 6 passed, 1 skipped (`debug-final-unit.log`, `debug-final-placement.log`) |

The Debug serial and parallel runs above were on the change before its last
edits (the measurement seam, and the visibility check named
`receivesRows`); the final code was run in Release (first row) and in Debug
(last row). No helper, wire or storage format changed, so the helper, wire,
concurrent and acceptance suites were not run.

## Not changed, for the lead

- **Rows still built at the opening.** A chat that was running when the reader
  left it has no rows kept in the pane, so they are built as it opens (about
  95 ms here). Keeping them would mean keeping live rows out of sight, which
  `TranscriptKeptRows` refuses by design. PERF-1 (a131-layout) removes part of
  the cost beside the floating card.
- **Runs that end in an error, or stopped or paused**, keep the rows the
  reader left: `heldRowsOutlived` covers idle runs, as since 0.1.114, and such a
  chat shows them and then the page in their place. Unchanged.
- **Opened before the read lands**, a moment after the run's end, the chat
  opens as before. Waiting for that read instead of starting another would
  close the gap.
- **First openings** (nothing held) still scan the journal before reading the
  page; the scan could follow the page instead.

## Round 2 — 2026-10-23: a run's end counts as use, and two review findings

Owner decision on the open question of round 1: "Run's end counts as use". A
chat whose run ends while it is out of sight moves to the front of the display
order, as if just opened, so `releaseUnreadDisplays` keeps it among the eight
and its finished rows (the read above) are still there when the reader clicks
it. Memory stays bounded at eight.

- **Change.** `WorkspaceModel.refresh`: when a snapshot of a chat out of sight
  shows its run has ended (busy before the snapshot, not after: idle, failed or
  paused), its display's `used` becomes now. Nothing else reads `used`.
- **Test.** `ChatOpenPlacementTests.testAChatWhoseRunEndsOutOfSightKeepsItsDisplayAmongTheEight`
  (serial lane; real window, helper and gateway): nine chats open, then one
  with a reply and a long one the reader leaves arriving; the nine are opened
  again, so the running chat is the one used longest ago. Once its run has
  ended out of sight it is the chat used last; opening another chat lets go of
  one display and keeps no more than eight, and not this one; opened, it is on
  its finished rows at once, uncovered.
  **Failing first and mutation:** with the new line disabled (a Debug build
  with its condition never true), 4 failures (`debug-use-off.log`): the chat
  is not the one used last, opening another chat lets go of its display, and
  opened it is covered without its finished reply.
- **Validation (Debug, under the lock).** `ChatOpenPlacementTests` 7 passed
  (the new test and the six before), `WorkspaceDisplayMemoryTests` 2 passed
  (`debug-use-on.log`): 9 executed, 0 failures. These are the classes the
  change reaches: nothing else reads `used`, and the release order is only
  changed by a run's end observed out of sight.

Codex review of `afa230a4`, two P2 findings, both confirmed and fixed:

- **The journal scan held up other chats' reads.** The scan read as a run ends
  (`subagentPlans`, `agentCoordination`) ran synchronously on the one
  `HistoryReader` every chat's reads go through, so a chat opened meanwhile
  waited for the whole scan, though its own reads were cached. The scans now
  run off it: `HistoryReader.scanPlans` and `scanCoordination` are the scans
  as they were, `nonisolated static`; the reader's own methods call them as
  before, and `catchUpFinishedRows` runs them in a detached utility task and
  hands the reader only the result (`keepPlans`, `keepCoordination`), kept for
  the revision or file the scan read and only while the journal is still it.
  Nothing waits on the scan, so nothing has to cancel it.
- **A switch between other chats dropped the read.** The read answered to the
  workspace's navigation (`readConversationWindow` checks
  `messageNavigationRevision`, which every change of selection moves), so the
  reader going from one chat to another while it was under way ended it, and
  the chat kept the rows its run had outlived. `readConversationWindow` and
  `readInitialWindow` take `followsNavigation`; the catch-up passes `false`
  and answers to its own chat alone (`current()`: the same display and
  presentation, still idle with outlived rows, still out of sight, the same
  journal). Every other read is unchanged.

Tests, `FinishedRowsCatchUpTests` (both fail first on `afa230a4`'s code,
`debug-review-before.log`: 2 tests, 4 failures):

- `testAChatOpenedWhileTheFinishedJournalIsScannedDoesNotWaitForIt`: a 16 MB
  finished journal; another chat, its reads cached, is opened while the scan
  runs, and its first read happens while the scan is still under way; the
  scan is then kept, and an opening scans nothing again. Before: its first
  read came only after the whole scan.
- `testTheFinishedPageLandsThoughTheReaderMovesOn`: the finished chat's read
  is held while the reader opens another chat; released, the page lands, and
  the chat opens uncovered. Before: the read was dropped, the rows stayed as
  the run left them, and the chat opened covered.
- The two restored fixes are the mutation checks: reverting either one fails
  its test as above.

Validation of the round (Debug; `debug-review-parallel.log`,
`debug-review-serial.log`, the serial classes under the lock):

| Classes | Result |
| --- | --- |
| FinishedRowsCatchUpTests 8, SubagentDeletionTests 19, SubagentDiscoveryTests 15, SubagentDisplayTests 8, SubagentEffortTests 5, SubagentSteeringInspectorTests 6, SubagentSteeringWorkspaceTests 4, WorkspaceDisplayMemoryTests 2, WorkspaceLoadingTests 13 | 80 passed |
| ChatOpenPlacementTests 7, FreshPresentationTests 21, InheritedSubagentReaderTests 8, SubagentReaderTests 60; FinishedChatOpeningTests 1 skipped (opt-in probe) | 96 passed, 1 skipped |

These are the classes that use the scans split above (sub-agent plans,
discovery, deletion, coordination, display, effort, steering) and the opening
and history-reading paths the catch-up goes through. No helper or wire change.

## Round 3 — 2026-10-23: review of `9a681e3a`

Two P2 findings, both confirmed and fixed.

- **A run that came and went during the read left an older page in place.**
  If a short follow-up started and ended while the read was under way (it
  waits up to 150 ms for figures), the chat was idle again with its rows still
  outlived and the same presentation, so the older page was put in place. Its
  rows were finished, so nothing read the chat again, and opened it showed the
  run before and then changed to the newer page. Now the display keeps the
  helper's row revision from every snapshot, also a status
  (`helperDisplayRevision`, from `displayRevision`, which the helper moves only
  when its rows change). The read is bound to the revision at its start: if
  the revision has moved when the page and figures are back, the page is read
  again (up to three times; a run still under way stops the read, and its end
  reads the chat again). The page held keeps the revision it was read at
  (`heldRowsRevision`), and rows read out of sight count as outlived
  (`heldRowsOutlived`) once the helper's rows move past them. So a run the read
  missed reads the chat again, and an opening before that lands opens as
  before, covered, instead of showing the older page. Rows from anywhere else
  (an opening's page, a snapshot's rows) carry no such revision and keep the
  old rule.
- **The overlap test could fail with correct code.** It waited for the page to
  be held, which says nothing about whether the scan was still running, and
  relied on a 16 MB journal taking long enough. A test seam,
  `HistoryReader.planScanStarting`, is called as a whole plan scan begins, on
  the thread that scans. The test holds the scan there, checks that the other
  chat's first read completes, and only then releases it. A small journal
  does.

Tests, `FinishedRowsCatchUpTests` (9 now):

- `testARunThatComesAndGoesDuringTheReadSendsItBackForTheNewerPage` (new):
  the real snapshot loop, with a connected helper whose commands the test
  answers (as `FreshPresentationTests` does). The run ends out of sight
  (revision 5) and the page read is held; a follow-up runs (6) and ends (9);
  released, the chat holds the page after both runs. A later status with a
  newer revision (12) reads the chat again, and opened it is on that page,
  uncovered.
- `testAChatOpenedWhileTheFinishedJournalIsScannedDoesNotWaitForIt` (reworked):
  the scan held at `planScanStarting` until the other chat's first read has
  completed.
- **Mutations** (Debug): without the revision check, the new test fails (the
  older page `[q, r]` is held, `debug-r3-mutation-revision.log`); with the scan
  back on the shared reader, the reworked test fails (the other chat's read
  waits behind the held scan, `debug-r3-mutation-onreader.log`). The other
  eight pass in each.

Validation of the round (Debug, final code; serial classes under the lock):

| Classes | Result |
| --- | --- |
| FinishedRowsCatchUpTests 9, SubagentDiscoveryTests 15, WorkspaceLoadingTests 13 | 37 passed (`debug-r3-parallel.log`) |
| ChatOpenPlacementTests 7, ChatLoadStabilityTests 1, FreshPresentationTests 21, WorkspaceRefreshLifecycleTests 38 | 67 passed (`debug-r3-serial.log`) |

The classes are the ones the round reaches: the catch-up and its seams, the
plan scan, the snapshot loop (the revision is read from every snapshot, and a
snapshot's rows clear the held revision), and the opening, whose fallback now
also covers rows read out of sight that the helper's rows have moved past.

## Round 4 — 2026-10-23: review of `6509c02a`

Two P2 timing races, both confirmed and fixed; the tests hold each race open
with seams, not sleeps.

- **A run that ended during the journal scan was not read.** The read keeps
  its place (`finishedRowsRead`) until the scan after it is done, so a status
  saying that another run had ended, arriving meanwhile, was dropped by the
  read's own guard, and the read ended without looking at the chat again.
  With no later event the chat kept the older page, which an opening then
  discards (round 3's rule) and opens covered. Now an ask that comes while a
  read is under way is noted (`finishedRowsAgain`), and as the read ends the
  chat is looked at again, by the same rules as any status: read again if its
  rows are outlived, else left as it is. Only an ask that came meanwhile does
  this, so a read that fails is retried at most once per status.
- **A run's end taken as seen when the reader had already left.** The snapshot
  loop decided whether a chat was on screen when it asked for the snapshot,
  so a run's end asked for while the chat was shown, and arriving after the
  reader had left it, was not counted as a use (round 2), and no later status
  could count it (the chat was no longer running). Whether the chat is on
  screen is now taken when the answer is applied (`receivesRows`, no longer
  private), for the use and for the read as the run ends.

Tests, `FinishedRowsCatchUpTests` (11 now), on the real snapshot loop with a
helper whose commands the test answers:

- `testARunThatEndsDuringTheScanReadsTheChatAgainOnceItIsDone`: the run ends
  (revision 5), its page is held, and the journal scan after it is held open
  (`planScanStarting`); another run comes (6) and goes (9); released, the
  chat is read again and holds the page after both runs.
- `testARunEndThatArrivesAfterTheReaderLeftCountsAsAUse`: the snapshot is
  asked for while the chat is shown, the reader opens another chat, and the
  answer says the run has ended: the chat is the one used last.
- **Failing first** on `6509c02a`'s code (`debug-r4-before.log`, 2 tests, 4
  failures): the chat kept the older page `[q, r]` (read once, still
  outlived), and the other chat stayed the one used last. Each test fails
  only through its own fix, so that run is also each fix's mutation check.

Validation of the round (Debug, final code): FinishedRowsCatchUpTests 11 and
WorkspaceDisplayMemoryTests 2 passed (`debug-r4-parallel.log`);
ChatOpenPlacementTests 7 and WorkspaceRefreshLifecycleTests 38 passed under the
lock (`debug-r4-serial.log`).

## Round 5 — 2026-10-23: review of `c395ede8`

One P2, confirmed and fixed: **a short run that went unseen was not counted
as a use.** A chat's statuses are coalesced, so a short run can start and end
between two of them: the chat reads idle on both. The catch-up still read its
finished rows (its row revision had moved), but "a run's end counts as use"
required the chat to have been seen running, so the chat kept the recency of
its last opening, and the chats opened next could let it go, rows and all.
Now a chat out of sight also counts as used when a status shows it idle with
its rows moved since the status before (`displayRevision`, the evidence the
catch-up uses): `WorkspaceRefresh.swift`, one condition beside the existing
one. A chat with no earlier revision (its first status) is not counted on
that alone.

- **Test.** `FinishedRowsCatchUpTests.testARunUnseenBetweenTwoStatusesCountsAsAUse`
  (real snapshot loop, answering helper): the run ends (seen, revision 5),
  the reader opens another chat, then a status shows the chat idle at
  revision 9. The chat is the one used last, and its rows are read again.
  **Failing first** on `c395ede8`'s code (`debug-r5-before.log`): the other
  chat stayed the one used last, while the rows were read again, as the
  review describes. The fix is one condition, so that run is also its
  mutation check.
- **Validation (Debug, final code).** FinishedRowsCatchUpTests 12 and
  WorkspaceDisplayMemoryTests 2 passed (`debug-r5-parallel.log`);
  ChatOpenPlacementTests 7 (with the seen run end's test from round 2) and
  WorkspaceRefreshLifecycleTests 38 passed under the lock (`debug-r5-serial.log`).
