# Bello Agent 0.1.119 — the approved UI/UX handoff

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.119, build 123. Public verification completed at **2026-10-02 22:58:55 UTC**. Tagged source: **`310b222c`**, `v0.1.119`. Website: **`5345b79`**. Previous public release: 0.1.118/build 122. The owner asked for this release on 2026-10-02 ("work on it, and release a new version when all done") and on 2026-10-03 deferred the manual VoiceOver and real-gateway checks again; neither is claimed to have run.

## Scope

Every item of the [approved UI/UX handoff](../reviews/BelloAgent-approved-UI-UX-handoff-2026-10-02.md). The planned refactors are not included; another agent takes them up separately.

- **D1** Commit Checked Files and Commit Staged Changes as explicit scopes; Reword Last Commit through `commit-tree` with a compare-and-swap ref update, leaving the index and worktree untouched.
- **D2** Editing a queued message holds every pending input in that chat: atomic, durable acquire, save, cancel and remove with an edit identity and remembered outcome; restart reconciliation with Resume Edit / Cancel Edit.
- **D3** Settings Save All; Cancel discards; dirty close, Escape, ⌘W and quit ask Save All / Discard Changes / Keep Editing; guarded Reload; honest partial saves.
- **D4** Bounded, scrolling, collapsible queue panel with steering and follow-up headings, truthful timing and a read-only detail with the captured model and effort.
- **D5** Several terminals per project; restart and close of a live shell ask first, Cancel default.
- **D6** Find and Go to Line survive a live reload.
- **D7** "Remove All MCP Servers…" with an honest confirmation and partial-result report.
- **D8** Git Blame of the displayed text, with Show Change opening the commit-versus-first-parent diff at the line in Changes → History, and Back.
- **A1** Contextual accessibility in the shared Pi controls and the new controls, asserted through the accessibility client interface.
- **A2** Image-only messages on every submission path for models that take images; images validated at submission.
- **Owner-accepted limit:** at 920×600 with a terminal, a tall draft and a running reply, the transcript gets about 50–75 pt and the window grows to about 670 pt.

Release notes: `releases/0.1.119.html`.

## Validation

Toolchain: macOS 14.8 (a VM) on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1. Each workstream planned and reviewed every change with Codex (gpt-6.1-sol, xhigh, read-only) to no findings and mutation-checked its new tests; their reports list the criteria not fully covered (real VoiceOver use, synthesized drags, a held late image read, terminal start failure, real providers).

- Wire scripts on a fresh Release helper before the gate: 34, 4 and 2 passed.
- **First gate** at `51328091`: serial 376 executed, 21 skipped, 0 failures; parallel 1,750 passed, **1 failed**, 18 skipped; helper cost 5; gallery 192; helper 611 (6 skipped); views 164 (3 skipped); wire 34, concurrent 4, acceptance 2, Python 72.
  - The failure, `PiSheetWindowTests.testEveryWorkspaceSheetIsAWindowOfTheAppsOwn`, was a **real D3 regression**: loading the vault set Settings' `busy`, and closing, Cancel, Escape and quit refused while busy ("Wait for the save to finish."). A slow load in the parallel lane swallowed Escape. Fixed in `163a292f` with a separate `saving` flag for vault writes; two native tests hold a reload with a vault read gate and fail without the fix. SettingsCloseNativeTests 11 (1 opt-in skipped), SettingsUnsavedTests 23 and five related parallel classes (51 tests) passed; Codex had one finding (two fixtures faking a save), fixed, then none.
- **Second gate** at `163a292f`, 21 min 20 s: serial **378 executed, 21 skipped, 0 failures**; parallel **1,749 passed, 1 failed, 18 skipped**; helper cost 5; gallery **192 screenshots**; helper **611, 6 skipped, 0 failures**; views **164, 3 skipped**; wire 34, concurrent 4, acceptance 2, Python 72. PiSheetWindowTests passed.
  - The failure, `SendImmediacyTests.testAtTheFootOfALongChatTheHelpersRowTakesOverInPlace` (unchanged since 0.1.87), asserted state after six 8 ms polls. It passed in the first gate and 3/3 alone. `2b847707` keeps the six samples and then waits on the shared wall-clock bound for the asserted state, every pass still checked for steadiness; test only. SendImmediacyTests 14/14 three times, and the test 3/3 with all cores busy. Codex: no findings.
- **Gallery review** (second gate's run and the first, light and dark): commit scope and amend (10d, 10e), blame and Show Change (24c, 24d), find through reload (24c), the queue running and held for an edit (13, 13c), Settings dirty and the close question (26, 26a), terminals (26b–d), MCP removal (26e). No 0.1.119 defect found. Seen and not changed: in a narrow chat pane beside a file tab (920 pt window) the footer's capture badge overlaps the end of the cost line; the footer is unchanged since 0.1.118 apart from an accessibility modifier.
- **Hour soak**, Release build of `2b847707` (product code of `163a292f`), seed **1790977596393**, load 2.5 → 2.4 at start, no other builds; replayd idle: **passed**. 3,604 s, 181 launches (sidebar median 301 ms, max 398 ms), **0 stalls over 250 ms**, 0 row jumps, 0 slow launches. Main-thread answers over 100/150/200 ms: 464/5/1; longest **207 ms** (43 ms margin; 0.1.118's final soak had 245 ms). Footprint grew 4.06 MB per launch with 181 windows alive, the test runner's documented window retention.
- Not run: the owner's VoiceOver pass and real-gateway compaction (deferred by the owner); install and update rehearsals (standing owner policy).

## Publication

Packaged from **`310b222c`**, the release commit: `main` merged with `dev/next` at `5f36c097` (`--no-ff`) plus the version bump to 0.1.119/build 123 and the RELEASE_MESSAGE. Its `apps/` and `packages/` trees equal the gated and soaked source apart from those settings. `scripts/release.sh` ran on 2026-10-03: Release build, stripped binaries with retained dSYMs, Developer ID signing, packaged-helper offline smoke, app and DMG notarization and stapling, Gatekeeper validation, signed appcast and Ed25519 verification.

- App notarization: **`d781474e-c1c2-4465-8264-93c5a4c987ab`**, Accepted.
- DMG notarization: **`9557c71f-f85b-432d-9b7f-c25ab78094a8`**, Accepted.
- Installer: **12,710,550 bytes (12.12 MiB)**, below the 20 MiB target.
- SHA-256: **`0315a304b588ecf216d67f3028c7a34cb36e7efab96fe560d017ff785119f4eb`**.
- `validate-release.py --previous-build 122` passed; both local feeds byte-identical.

Source was pushed atomically to `main` and `dev/next` at `310b222c`. `publish-release.sh 0.1.119` committed and pushed website `5345b79`. `verify-published.py` passed at 2026-10-02 22:58:55 UTC, about 4 minutes after the push: identical canonical and legacy feeds, public DMG SHA-256 match and Ed25519 signature. Install and update rehearsals were skipped under the standing owner policy.
