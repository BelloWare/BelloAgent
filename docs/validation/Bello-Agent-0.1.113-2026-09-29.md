# Bello Agent 0.1.113 — closed sheets let go, saved context readings, old journals slimmed

Status: candidate; publication pending.
Starting main: `950ad68740e84384bea19c1164659afd9de9ab63` (0.1.112's verified record).

## Changes

The owner approved a performance and consistency batch.

1. **Closed sheets let go of their views** (`a3220c3`). SwiftUI (macOS 14)
   keeps the window of every sheet it presented after the sheet is dismissed:
   hidden, with the sheet's views still in it and still observing the model, so
   every model change redrew each sheet ever closed. After the Settings sheet
   was opened and closed ten times, a hundred model changes cost 4.9 s instead
   of 1.0 s (Debug), and the cost grew with every sheet opened in a launch.
   - `DismissedSheets` (`Application/DismissedSheets.swift`, started from
     `applicationDidFinishLaunching`) empties SwiftUI's own sheet windows once
     the sheet has ended and is off screen.
   - The ⌘, Settings window, which SwiftUI reuses, takes its form down while
     closed; its edits wait in `SettingsWindowContent`, so unsaved changes are
     there when it reopens.
   - The short lazy lists (the Projects list, choice pickers, a page of
     instruction sources) are plain stacks; the lists that can be long keep
     their lazy stacks.
   - The gallery's "AttributeGraph: cycle detected" reports fell from 2,948 to
     122, most of them having come from closed sheets laid out again on each
     appearance change. The gallery writes a `GALLERY-CAPTURE` line per
     screenshot to standard error, so a report can be traced to its screen.
2. **A chat shows its saved context reading** (`466cbba`). Showing a chat
   started its project's helper about 0.2 s later only so the context pill
   could count the next request; until then the pill read "Calculating
   context…", and an idle helper that went away took the figures with it. The
   pill's reading is now saved whenever the helper's preview counts an idle
   chat with an empty composer, with the chat's binding, the configuration
   revision and the journal's stamp. It is read with the chat list and shown
   from the first frame, with no helper opened for it, while it still stands,
   the composer is empty and no helper is open for the chat. Typing, a chat
   never counted, and a changed model, window, settings or journal count again
   as before; the helper's own figures, once published, come first; a deleted
   chat's reading goes with it.
3. **An unchanged chat is not read again** (`0ba7aac`, `596f92b`, `06c9251`).
   Going back to a chat shown earlier in the launch read its journal again.
   Its rows are now shown again without a read only when a fresh read of the
   unchanged journal (the same file, size and change times) would return them:
   the newest page, still as read in, with the reader at the bottom or on one
   of its rows. Anything else is read as before. A chat's usage is read once
   when it opens: the read before its rows are shown also sets its totals, and
   the refresh after the chat is ready reads only the totals and the timing.
4. **Journals written before 0.1.111 are slimmed once** (`cebafb3`). The
   helper's new `journal.slim` command writes a journal again without the
   run-state records a later one supersedes, keeping the one the chat's run
   state comes from with its receipts whole, and re-links the chain with no id
   changed. It replays the old and new journals in full and compares rows,
   model context, versions, spend, receipts, queue, run state, task records,
   request links and compaction state; only when they are the same does it put
   the new journal in place, with the original in the Trash and the metadata
   file written again. The journal's lock is held throughout, the helper
   refuses a chat it has open, and any failure leaves the journal as it was
   with nothing in the Trash. The app asks once per chat, about 20 s after
   launch while nothing is going on, for native chats of 2 MiB or more that are
   neither open nor on screen, and keeps the answer (`journal-slim`). A
   1,000-turn synthetic chat in the old format went from 71.0 MB to 13.6 MB
   (5,999 of 6,000 run-state records removed), its full open from about 500 ms
   to 400 ms (Release); slimming it took 2.8 s. `docs/Journal-Command-Receipts.md`
   describes it.
5. **The launch archive order is unchanged.** Measured: the owner's request
   log is about 260 KB, so its open and sweep cost milliseconds.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `06c9251`, dev/next's tip:
  serial lane 217 executed, 7 skipped, 0 failures; parallel lane 1,462 passed,
  17 skipped, 0 failures; gallery **128 screenshots, 0 failures**, with 122
  "AttributeGraph: cycle detected" lines (2,948 in 0.1.112's gate); helper 495,
  3 skipped (the opt-in timings); wire 32; concurrent 4; acceptance 2; Python
  66; all passed in 14 min 20 s. The two tests that failed in the development
  run passed: `AppShellTimingTests.testLaunchToFirstSidebarPaintWithFourHundredChats`
  in the serial lane (0.38 s) and
  `NativeMarkdownSurfaceStreamingTests.testATokenOnAnOpenListCostsTheSameAtOneAndEightKilobytes`
  in the parallel lane.
- `06c9251` contains main (`950ad68`), so the merge into main adds nothing
  else: the merged tree equals the gated tree.
- **Development evidence** (before the gate): on the merge `2467c8b`, the
  helper suite ran 495 tests, 3 skipped, 0 failures, and the wire, concurrent
  and acceptance scripts passed 32, 4 and 2 on a Release helper. The full app
  run on `2467c8b`:
  - serial lane 217 with 1 failure,
    `AppShellTimingTests.testLaunchToFirstSidebarPaintWithFourHundredChats`
    (no sidebar row within 30 s). It passed alone (117 ms), and the whole
    serial lane, rerun alone on the final code, passed 217, 7 skipped, 0
    failures (launch paint 95 ms);
  - parallel lane 1,460 passed, 2 failed:
    `HardeningTests.testAnOlderReadingPositionSurvivesSwitchingAwayAndRelaunching`,
    a real bug in the revisit skip, fixed by `06c9251` (then `HardeningTests`
    12 of 12, `WorkspaceLoadingTests` 12 of 12, `LaunchSelectionTests` 19 of
    19); and
    `NativeMarkdownSurfaceStreamingTests.testATokenOnAnOpenListCostsTheSameAtOneAndEightKilobytes`,
    a cost comparison under 8-clone load that passes alone and that this batch
    does not touch;
  - gallery 128 screenshots.
- `LayoutCycleTests` (3, serial lane): no cycles from the window, the Rename
  and Projects sheets, or an appearance change after sheets were closed; closed
  sheets hold no views, and a model change costs what it did before any sheet
  was opened; the Settings window's form is gone while it is closed and back
  when it reopens.
- `ContextReadingTests` (3, packaged helper and synthetic gateway): after a
  relaunch a counted chat shows the same figures from its first frame, never
  calculates and starts no helper, and when a helper exits the figures stay;
  typing still counts the draft; a changed model or journal counts again. They
  fail with the saved reading turned off. `AutomaticContextTests`' eviction
  test expects the saved reading, not a second count.
- `LaunchSelectionTests.testGoingBackToAnUnchangedChatDoesNotReadItAgain`
  counts the pages read; it fails when the check is turned off.
- `JournalSlimmingTests` (8, helper, with journals from real sessions): old
  whole-list journals slim and open as before; journals with receipt changes
  keep their receipts; a fork and a kept side slim too; a journal a session has
  open, a copy that does not replay the same and a discard that fails each
  leave the journal alone; small and imported journals are left alone; the
  helper slims only its own journals that no chat has open.
  `JournalSlimmingTriggerTests`: the app asks about large closed native chats
  once and leaves the rest. `SessionOpenPerformanceTests.testSlimmingAKeptJournal`
  is opt-in.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
