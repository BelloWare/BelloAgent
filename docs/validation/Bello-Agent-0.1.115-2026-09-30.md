# Bello Agent 0.1.115 — a sides panel, newer rows that load by themselves, a reply that no longer stops halfway

Status: candidate; publication pending.
Starting main: `362d7ff68f3fe5a28bb1253194c61cb79aeaf24d` (0.1.114's verified record).

## Scope

dev/next at `3255a51`: 118 commits since 0.1.114 (91 besides merges). It now
includes the side work held out of 0.1.114 (`874315c`, `f6f9863`); the
side-switcher mock-ups `874315c` added (`SidePaneHeaderSlot.swift`,
`SideSwitcherMockups.swift`) are gone by `e30876a`, so none of them ships. The
owner asked for this release.

## Changes

The release notes (`releases/0.1.115.html`) give the user-facing items in full.

- **New:** a sides panel at the window's right edge, hidden until the pointer
  rests there, listing the open chat's sides with their status and last
  activity, "+ New side", and a pin that keeps it as a column; and newer rows
  that load by themselves at the bottom of an older window, with the "Load
  newer messages" button gone.
- **Fixed:** a reply that stopped growing on screen in a long chat after the
  reader scrolled up or selected text further up (since 0.1.80); rows that
  left the top of a long chat and could not be scrolled back to; a short page
  that pushed out the newest rows; a held window that did not shrink again;
  newer rows read after a quick scroll ("The selected text is at the display
  boundary"); a long chat's rows jumping while its context pill changed words
  (the pill now keeps one room per showing); New side from a pinned sides
  panel opening out of sight; the sidebar unfolding itself when a side is
  clicked; the cursor going to the chat instead of the side; costs and token
  counts rounded differently in different places (now decimal half-up
  everywhere); Rename's title suggestions sent as a utility request; a fork
  holding up other chats (586 ms → 5 ms); a side's opening syncing once per
  message (65 syncs for 60 messages → 2); the menu bar and activity graph
  disagreeing on an interrupted chat; the Usage Report falling back silently
  on a misspelt view choice.
- **A correction** (as published in the notes): The 0.1.113 and 0.1.114 notes
  said closed sheets were kept, with their views, and the MB each close saved.
  Checked in the real app, closed sheets, windows and popovers are freed. What
  was measured came from the test runner itself, which keeps autoreleased
  objects until a test returns. The code those releases added is harmless and
  stays.

## Under the hood

- **A codebase review of four areas:** the model and storage, the transcript
  and composer, the helper and scripts, and the Inspector, Dashboard, Git,
  Design and tests. It was followed by behaviour-preserving refactors:
  - run state and the report's state are typed;
  - the chat record's merge rules are explicit and tested;
  - the refresh, send, select and history reads are split into named phases;
  - the 2,106-line transcript view is split by moves only;
  - one action forwarder, with the transcript's dead guards working again;
  - the helper's dispatch, run loop and fork paths are split, with a
    replay-parity test;
  - a shared test gateway fixture, one wait helper and one model teardown.
- **Test reliability:**
  - three tests used the real Keychain;
  - 29 test files deleted open databases;
  - several flaky tests were fixed at the cause (address reuse, autorelease
    pools, wall-clock waits).
- **An independent review:** Codex (gpt-6.1-sol, reasoning xhigh) reviewed the
  whole release against 0.1.114. It found one defect (New side behind another
  page, fixed in `44f50a1`). It also reviewed each fix made since, and three of
  its findings shaped the context pill fix.
- **An hour-long soak** of a Release build: 177 relaunches, about 4,000
  selections, switches and sends over six synthetic chats.
  - It found the rows jump above (29 times, all on the two busiest chats after
    53 minutes). A first fix covered chats whose figure was known. A second
    hour with the same seed still had 20 jumps, on chats with no figure yet, so
    the pill now keeps one room per showing.
  - Its 16 pauses over 250 ms were all in system code: window-server routing
    for tooltips, Core Animation commits, the font cache lock. That is under 1
    per 200 s, fewer than shorter runs showed before this release.
  - Its memory grew 2.2 MB per relaunch inside one test process. A new report
    line shows closed models are let go a few relaunches later, not kept. The
    windows that stay alive are the test runner's own; the app has one.
  - A third hour with the same seed, on the final build (`e30876a`):
    - 179 relaunches and 0 jumps;
    - the sidebar listed its chats in a median of 285 ms (max 434 ms);
    - 0 of SwiftUI's "Publishing changes from within view updates" warnings,
      which the first hour logged 35 times;
    - 20 pauses over 250 ms, all SwiftUI drawing a newly opened chat's text
      while waiting on CoreGraphics' font cache (the same kind and rate as the
      two earlier hours; a round-2 performance item), so the soak's pause
      check still fails;
    - closed models let go within seven relaunches.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `e30876a`, 19 min 2 s:
  serial lane 251 executed, 17 skipped, 0 failures (`SmoothShellTests` 5 of 5
  among them); parallel lane 1,554 passed, 18 skipped, 1 failed; gallery **144
  screenshots, 0 failures**, with a `GALLERY-CAPTURE` line for each and no
  "AttributeGraph: cycle detected" line; helper 511, 4 skipped (the opt-in
  timings); wire 32; concurrent 4; acceptance 2; Python 66. replayd stayed
  idle (0% CPU) throughout.
  - The one failure,
    `WorkspaceFollowupTests.testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject`,
    failed after 8.7 s under the parallel lane's load. Its class's private
    wait counted 100 polls of 20 ms, about 2 s. It passed 3 of 3 alone and
    its class 6 of 6 on `e30876a`, and the serial lane's pane and composer
    timing budgets all passed.
- **The fix, `3255a51`** (test only; Codex-reviewed with no findings): the
  class's wait delegates to the suite's shared wall-clock `eventually`
  (`TestSeams.swift`, 10 s). With the test bundle rebuilt at `3255a51`,
  `WorkspaceFollowupTests` passed 6 of 6 in each of three runs. Per the
  rerun-only-affected-tests rule, the rest of the gate on `e30876a` stands:
  `3255a51` differs from it only in `WorkspaceFollowupTests.swift`.
- `3255a51` contains main (`362d7ff`), so the merge into main adds nothing
  else: the merged tree equals `3255a51`'s.
- **Development evidence** (before the gate): the wire, concurrent and
  acceptance scripts passed 32, 4 and 2 on a Release helper, and no helper or
  script code has changed since `391a96f`; the affected app classes passed, 87
  in the parallel lane and 57 in the serial lane; the gallery passed on
  `c4adfc5`, after which only test-harness files changed. In the developer's
  earlier full gate, `SmoothShellTests` failed once in the serial lane under
  load and passed 3 of 3 alone.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
