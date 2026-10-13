# Bello Agent 0.1.125 — Resume a paused chat, update without stopping work, a quieter sidebar

Status: **packaged; publication pending** — marketing version 0.1.125, build 129. Previous public release: 0.1.124/build 128.

## Owner request

On 2026-10-13, after 0.1.124, the owner asked:
- "when I pause, support resume, and allow me to check update and when restart, pause ongoing sessions, and allow me to resume once restarted";
- "no need to show 'working' on left bar for a given session";
- for the "Selected skill is unavailable or changed" send failure to be fixed.

Owner decisions:
- the queue's Resume continues the run and then sends follow-ups;
- Check for Updates pauses nothing, and running chats are paused only to install ("Check first, pause only to install");
- Quit does not ask about follow-ups paused behind a stopped run.

The owner asked for these to ship as a new version ("just have the rest released in a new version").

## Scope

- **Resume runs** (`dev/resume-runs`). A stopped run, or one cut off by Quit or an update, ends with a Paused card and a Resume button. Resume is also in Conversation ▸ Resume.
  - One `run.continue` action resumes the run.
  - A cut-off tool call is never re-run on its own: the model is told how it ended.
  - The queue's Resume continues the run, then sends the queued follow-ups.
- **Update while running.** Check for Updates runs while chats are running and pauses nothing. Choosing Install asks to pause the running chats, and each one shows Resume after the update.
  - Sparkle's "up to date" and error alerts are now window sheets (`Application/UpdateUserDriver.swift`), so they no longer block streaming.
  - Update results wait for a window and are never dropped.
- **Quit** no longer asks to stop work when the only work left is follow-ups paused behind a stopped run.
- **Skill refresh** (`dev/skill-refresh`). If a picked skill has changed, the app refreshes it and shows a notice; the next Send uses the new version.
  - A removed skill is taken out of the message with a note.
  - A queued follow-up whose skill changed waits with Resume.
- **Sidebar** (`dev/sidebar-working`). A running chat's row no longer says "Working"; the spinner shows it. Waiting, Compacting, Paused and the other states still show.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- **Codex review loop.** Each branch was reviewed read-only by Codex (gpt-6-astra, max) until clean. Every finding was fixed test-first. A final whole-release review from `v0.1.124` to `ba901762` found no actionable regressions.
- **Full gate** (`verify-release.sh`) on `ba901762`:
  - native serial lane 671 (30 skipped), 0 failures;
  - gallery 218 screenshots, 0 failures;
  - helper 670 (6 skipped);
  - helper streaming cost 5.
  - The parallel lane had 2,151 passed, 3 failed (34 skipped):
    - `CostLimitTests.testSendingAtTheLimitShowsTheNoticeAndADisabledDefaultNeverStops` and `SessionMarkUnreadTests.testTheMenusOfferMarkAsUnreadForAReadChatAndMarkAsReadOtherwise` passed when rerun alone (load flakes, unrelated code).
    - `WorkspaceFollowupTests.testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject` also fails alone. It is pre-existing: it fails the same way on the 0.1.124 tree. The scratch chat's helper takes over 5 s in `HostService.shutdown` and is then killed. Under investigation on `dev/helper-shutdown` (see Known).
- **Hour soak.** Release build of `ba901762`, seed **1790822043708**, no other builds running:
  - 3,603 s, 178 launches (sidebar median 244 ms, max 285 ms), 0 slow or missing launches, 0 row jumps.
  - **0 stalls over 250 ms** (0.1.124: 1, a window-server artifact).
  - Main-thread answers over 100/150/200 ms: 4/0/0, longest 125 ms (0.1.124: 6/1/1).
  - Footprint 99 → 745 MB, 3.65 MB per launch (0.1.124: 3.61).
  - The 60 s draw soak passed.
- **Known:**
  - Scratch-chat helper shutdown takes more than 5 s and is then force-ended. The user-visible effect is limited to a slower close of a scratch chat's helper; the test above times out on it.
  - Git (rare, carried from 0.1.124): during a repository switch, a commit message typed while the new repository loads can be cleared, and Amend can prefill the previous repository's HEAD message.
  - The side-chat panel still labels running sides "Working" (only the sidebar was in scope).
- **Not done:** VoiceOver and real-gateway checks; install/update rehearsals skipped under standing policy.
