# Bello Agent 0.1.116 — K and two-decimal money everywhere, the app's own controls, a footer that stays still

Status: publicly released and verified at 2026-09-30 03:48:59 UTC.
Starting main: `ee1596406102247388edfd7a77c3d07482789b24` (0.1.115's verified record).

## Scope

dev/next at `2dc88ba`: 18 commits since 0.1.115 (15 besides merges). The
gated `6ca16a4` added 16 to 0.1.115's candidate `3255a51` (14 changes and 2
merges, `de614cd` from dev/helper and `6398da3` from dev/ui); then `c2833d7`
fixed three test expectations, and `2dc88ba` merged main (the 0.1.115 release)
into dev/next. The owner chose to ship this now, with a fork speed-up following
in 0.1.117.

## Changes

The release notes (`releases/0.1.116.html`) give the user-facing items in full.

- **Changed:** thousands read "K" everywhere, the Usage Report and six other
  places included (`1fd7b19`); money reads with at least two decimals
  everywhere, with the cost charts' axes labelled in dollars (`4018900`); the
  remaining stock spinners, loading bar, switches, checkboxes and date fields
  are the app's own, at the same sizes and with the same keyboard access
  (`557b138`, `6ca16a4`); the large-table window has the app's look
  (`c7c7331`); the footer under the composer stays still while a chat is read,
  with the capture badge keeping its room and a notice taking only free room
  (`b7c86ef`); a side whose chat was deleted opens no side of its own, and Open
  Side and /side say why (`35c76fb`).
- **Fixed:** the sidebar's chevron folds the sides of any chat, not only the
  open one (since 0.1.100; `0e283eb`); a sheet is told what it inherits just
  after SwiftUI's update, not inside it (`4a5e95d`); the helper encodes each
  reply once instead of twice, which took 32% off the helper's CPU for 4,000
  snapshot and history pages (median 8.95 s → 6.13 s over five runs of a
  Release build), with the app receiving the same bytes (`175400a`).

## Under the hood

- **Helper** (`75802c8`, `077dccc`, `1b165f8`):
  - its run states and tool states are enums whose values are the old
    strings;
  - the error codes the app matches are named constants;
  - one shared fixture server replaces copies in 11 test files;
  - one wire client serves the wire scripts.
- **Test reliability:**
  - WorkspaceFollowupTests (in the 0.1.115 gate) and a sheet test waited on
    counts of polls or on too short an allowance, and ran out under the
    parallel lane's load. They now wait on a clock
    (`PiSheetWindowTests.testEveryWorkspaceSheetIsAWindowOfTheAppsOwn` allows
    30 s, `4a5e95d`).
  - The synthetic gateway's teardown could hang for over 20 minutes; it now
    waits on the process's termination handler (`9d4c881`).
- **Codex** (gpt-6.1-sol, reasoning xhigh) planned and reviewed every change.
  Its findings were fixed before each commit.
- **The sides rules** (the owner's decision): only sides of a side whose chat
  was deleted are refused. The helper does not enforce more, since it cannot
  know what the app shows beside what.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `6ca16a4`, 18 min 35 s:
  serial lane 251 executed, 17 skipped, 0 failures; parallel lane 1,560
  passed, 18 skipped, 2 failed; gallery **146 screenshots, 0 failures**, the
  two 23-table-window scenes among them, with a `GALLERY-CAPTURE` line for each
  and no "AttributeGraph: cycle detected" line; helper 521, 4 skipped (the
  opt-in timings); wire 33; concurrent 4; acceptance 2; Python 66.
  `PiSheetWindowTests.testEveryWorkspaceSheetIsAWindowOfTheAppsOwn` passed
  (10.7 s) and
  `WorkspaceFollowupTests.testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject`
  passed. replayd stayed idle (0% CPU); WindowServer averaged 73% of a core
  (peak 125%) with other apps open.
  - The two failures were in `SessionReferenceTests`
    (`testCopyMarkedReferencesUsesSidebarOrderKeepsSelectionAndScopesEachUsage`
    and `testReferenceDistinguishesPartialMissingAndExpiredAccountingFromZero`):
    three expectations still read "$1.5 USD" and "$0 USD", where `4018900`
    makes `gatewayUSD` write "$1.50 USD" and "$0.00 USD", as
    `MoneyFormatGoldenTests` pins. They failed the same way alone (2 of 2
    runs).
- **The fix, `c2833d7`** (test only; Codex-reviewed): the three expectations
  read "$1.50 USD", "$0.00 USD (1/1 requests reported)" and "$0.00 USD (1/3
  requests reported)". With the test bundle rebuilt at `2dc88ba`,
  `SessionReferenceTests` passed 11 of 11 in each of three runs. Per the
  rerun-only-affected-tests rule, the rest of the gate on `6ca16a4` stands.
- `2dc88ba` merges main (`ee15964`) into dev/next, so the merge into main adds
  nothing else: the merged tree equals `2dc88ba`'s. Against the gated
  `6ca16a4`, its `apps/macos` differs only in `SessionReferenceTests.swift`,
  its `packages/swift-host`, `scripts` and `fixtures` are the same, and the
  rest of the difference is 0.1.115's version fields and records.
- **Development evidence** (before the gate): on `6ca16a4`, the wire,
  concurrent and acceptance scripts passed 33, 4 and 2 on a Release helper;
  `SidebarInteractionTests`, `SidebarSideClickTests` and `ProjectSidebarTests`
  (20 tests), `PiSheetWindowTests` (11) and SideTests' new test passed. The
  forks' own runs: 521 helper tests on dev/helper; on dev/ui, the affected
  classes and the gallery with 146 captures, the new table-window scenes
  (23-table-window, light and dark) among them.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.83 of
  the fixture's $5.00 cap (synthetic).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `166c254ea2d534b9aeb8d8673ade2db43e64fd8b`, pushed to GitHub `main`; annotated tag
  `v0.1.116` is pushed and resolves to that commit.
- Website publication: `6d4fa0d7ee7f024c5b315324a6393d26024340b6`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.116, build 120. App notarization
  `002509d7-0a50-40a5-aab9-c908fc01aa3f` and DMG notarization `3f75a03d-a1c5-4585-b1d3-3513c0147adf` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.116.dmg`: **11,508,181 bytes (10.98 MiB)**; SHA-256
  `d2a8337a2642d8427798061a1792d9c515ce739298f5527147b4222812a9ecbb`.
- At 2026-09-30 03:48:59 UTC, the public product page linked to 0.1.116.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No GitHub release page was made: the `gh` CLI is not logged in here. The
  tag and `main` went to GitHub over SSH.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
