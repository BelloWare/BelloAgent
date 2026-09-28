# Bello Agent 0.1.110 — a closed side stays closed after relaunch

Status: candidate; publication pending.
Starting main: `30dfb1aea578cc0723682cd3492c6ca7ade93898` (0.1.109's verified record).

## Changes

The owner reported that a side they had closed came back after quitting and
relaunching.

1. **A side closed while launch is still reading stays closed** (`5194f19`,
   `01f624d`). Until launch had reopened the chat left open, a side pane opened
   or closed was not recorded (`sidesChanged` returned early), and launch then
   wrote back the sides it had read. The first page of a large chat can take
   seconds while its small side pane is already on screen, so a side closed in
   that time came back at every launch. The panes are now tracked from the
   moment the chats are listed, and only the write waits for launch.
   `restore()` adopts the saved record in the same turn as the rows, so a chat
   opened from the first painted row also brings its side back.
2. **Quitting before launch ends keeps what was opened and closed**
   (`0e399f6`). Nothing was written until launch had reopened its chat, so a
   quit or update that came first left the record as the last session did: the
   chat opened meanwhile was forgotten and a side closed meanwhile came back.
   `flushSelection` now writes the chat on screen and the panes as they are
   when launch has not yet; a launch that has opened nothing leaves the record
   alone, and `selectionMemoryStopped`, set in `stopRememberingSelection`,
   keeps a launch that finishes after shutdown from writing again.

After updating, a side that has been coming back reopens once more, because the
saved record still names it; closing it once then sticks. The release notes say
so.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `8fb1ab7`, dev/next's tip:
  serial lane 213 executed, 7 skipped, 0 failures; parallel lane 1,457 passed,
  17 skipped, 0 failures (the five new tests among them); gallery **128
  screenshots, 0 failures**; helper 480, 2 skipped (the opt-in timings); wire
  32; concurrent 4; acceptance 2; Python 66; all passed in 12 min 25 s.
- `8fb1ab7` merges main (`30dfb1a`) into dev/next, so the merge into main adds
  nothing else: the merged tree equals the gated tree. Against main it changes
  six app files; `packages/swift-host`, `scripts` and `fixtures` are unchanged
  since the gated 0.1.109.
- **Development evidence** (Debug, before the gate): on `8fb1ab7`,
  `LaunchSelectionTests` 18 of 18, `SideRelaunchTests` 3 of 3 and `SideTests`
  8 of 8; on `0e399f6`, the quit and update paths (`HardeningTests`,
  `LifecycleHelperTests`, `WindowLifecycleTests`, `BlockingAlertTests`,
  `ReleaseConfigurationTests`) 31 of 31, since the flush now writes during
  launch.
- `LaunchSelectionTests.testASideClosedWhileLaunchIsStillReadingStaysClosed` and
  `testQuittingWhileLaunchIsStillReadingKeepsTheSideClosed`: a side closed
  while launch is held stays closed, also when the app quits before launch
  ends. Each failed before its fix.
- `SideRelaunchTests` (3, new): the owner's steps with the packaged helper and
  the synthetic gateway, then a relaunch. A side sent from and closed, one
  closed while its reply streams, and one opened with `/side <question>` and
  closed each stay closed. It runs in the parallel lane, about 9 s.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
