# Git safety: Pi confirmations — 0.1.127

Branch: `dev/a127-git-safety`. Follow-up to the lead's review of the stock Amend/Reword sheet, 2026-10-15. This record supersedes the earlier safety confirmation captures, not the earlier integration results.

## Change and decisions

- Amend, Reword and committing with Git-check warnings use `PiQuestion.askSheet`, `PiSheetWindow`, `PiKit.Sheet`, custom Pi text and Pi buttons. The Git operation path no longer constructs or presents `NSAlert`. The additive question API leaves existing non-Git question callers alone.
- The compact review shows repository display name (project name, falling back to the repository's basename), a secondary small path truncated in the middle, branch plus a nine-character hash, scope, message and optional sign-off/check details. The full hash and path remain in tooltips and accessibility; full commit messages remain available there too. Visible message/check previews retain their existing 500/1,500-character bounds.
- Singular/plural counts are correct in both commit scopes and in the Checked-files hint. Staged content explicitly leaves unstaged edits in place; Checked files still means whole working-tree content; Reword preserves the commit tree, index and working files. No scope changes during an action.
- The key/value block stacks in narrow panes. Long review content scrolls with the pointer or keyboard, including Page Up/Down and Home/End from a focused footer button; the warning and action buttons stay visible in the footer. Rewrites use the Pi danger button and Pi warning text, with no stock app icon or system destructive styling.
- Escape and Return cancel, including Return while the rewrite action has keyboard focus. Approval still requires the explicit action. A parent close, owner cancellation or asker release cannot leave an orphan sheet or dispatch an accepted answer after its context disappears. Busy askers/windows refuse another question rather than moving or queuing it.
- Conflicts and stale targets remain blocking inline Pi feedback, with no alert or override question. Frozen request, repository, HEAD/branch, scope, draft, sign-off and duplicate-answer protections remain in place. The previously documented external-Git race after native amend's last target check is unchanged.

## Failing-first and mutation evidence

All logs below are under `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/logs/`.

- `pi-confirmation-format-red.log`: the new package test failed nine assertions before the formatting fix: singular file counts and shortened attached/detached target hashes. The full target identity stays unchanged.
- `pi-confirmation-sheet-red.log`: three actual-panel tests failed six assertions because Amend, Reword and warning-Commit entered the `NSAlert` presenter and had no Pi sheet.
- `pi-confirmation-native-followup.log`: the added Checked-files hint test reproduced `1 of 1 files`. Three new presentation assertions also needed correction: AppKit transfers a Return key equivalent into the window's default cell. Tests now inspect that actual Cancel cell; the real Return/Escape tests already passed.
- `pi-confirmation-lifetime-red.log`: three new lifecycle cases failed before the lifetime fix: releasing the asker left its attached sheet behind; parent/owner cancellation during an accepted closing animation still answered true. The other three lifecycle cases passed.
- `pi-confirmation-consent-mutation.log` and `.json`: removing `accepted` from the real Git operation dispatch guard made Cancel rewrite the generated fixture's HEAD. The actual-sheet snapshot test failed. The mutation runner restored the exact source in `finally` and verified its SHA-256; no mutated source is committed.
- `pi-confirmation-keyboard-red.log`: final read-only review identified that programmatic scrolling did not prove keyboard access to long details. The actual window Page Down event, with Cancel focused, failed to move the review. The sheet now routes navigation keys and responder commands to the review body; Page Down/End/Page Up/Home all pass through actual window events.
- Native assertions inspect custom Pi view/button types, short visible/full accessible identity, narrow geometry, scroll reachability, warning visibility, keyboard cancellation and actual repository HEAD/index/worktree bytes. Existing confirmed-Reword coverage also verifies the commit tree, preserved staged/working bytes and one reflog action.

## Validation

Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety`. New Git fixtures use generated temporary repositories, fixture identity, disabled signing, no network/remotes or credential helpers. The isolated native test host is used; the installed app, real preferences and Keychain are not used. No named result bundle is requested; text logs are the evidence.

- Full `bello-views`: `pi-confirmation-package.log`, **269 executed: 266 passed, three opt-in skips, zero failures** (396.7 seconds).
- Focused package safety: `pi-confirmation-format-green.log`, **17 passed**.
- Initial corrected native core: `pi-confirmation-native-final.log`, **24 passed** (six confirmation, twelve operation, six lifecycle cases).
- Expanded affected/gallery run: `pi-confirmation-affected-gallery.log`, **41 passed**, zero failures (106.5 seconds). Includes seven confirmation tests (the additional long/narrow review), six lifecycle tests, seven blocking-alert regressions, three Cancel-default regressions, two Discard regressions, four sheet-cancel regressions, eleven sheet-window regressions, and the gallery.
- Restored core after the consent mutation: `pi-confirmation-restored.log`, **25 passed**. After the additional keyboard fix, `pi-confirmation-keyboard-green.log` passes the same **25 cases**, including actual Page Up/Down/Home/End events and Return with the action focused. Across the affected classes there are **53 distinct passing native cases**, zero remaining failures.
- The one full native parallel lane (four workers): `pi-confirmation-full-parallel.log`, **2,469 executed: 2,432 passed, 37 skipped, zero failures** (523.7 seconds). No isolated reruns were needed. The exact command, extracted per-case results and Xcode summary are saved as `pi-confirmation-full-command.json`, `pi-confirmation-full-cases.json` and `pi-confirmation-full-summary.json`. This run also passes all eleven `PiSheetWindowTests`; it does not establish a cause for the earlier integration run's release-wait timeout.

One initial native rebuild (`pi-confirmation-native-green.log`) hit a Swift 6 diagnostic in unchanged `SidebarInteractionTests.swift:197` about capturing `TopicSessionDragSurfaceView` in a Sendable closure. The identical sidebar sources compiled on retry; they were not edited. This compiler failure is separate from behavioral red tests and passing validation.

## Gallery review

`GitSafetyGalleryTests` runs standalone, with no app model/gateway setup. All **96 captures** were regenerated and viewed: 64 panel images and 32 actual Pi-sheet images. Both light/dark appearances at 1180×780, 920×600, 700×640 and 310×600 are covered. The 700-wide fixtures include multiline messages; Checked amend uses two files. A separate native test reviews a long message in a narrow scrolling sheet and checks that the warning/buttons stay visible.

Gallery folder: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/pi-confirmation-gallery/`.

Scenes: `conflict`, `amend-target`, `amend-checked`, `reword-target`, `preflight-failure`, `stale-target`, `commit-box`, `checked-files`. The four confirmation scenes additionally produce `*-sheet.png`. Every image was viewed through twelve contact sheets; these individual captures were also inspected at full size:

- `amend-target-light-920x600-sheet.png`
- `reword-target-dark-310x600-sheet.png`
- `preflight-failure-light-310x600-sheet.png`

Review found the Pi appearance, pluralization, short targets, secondary middle-truncated paths, warning placement and narrow layouts correct. No confirmation uses a stock icon or stock button. The later keyboard-only changes do not alter this layout.

Read-only production and whole-change review found the lifecycle and keyboard issues documented above; both received failing-first coverage and fixes. The final review found no actionable issues: scrolling stays bounded, modified raw navigation keys are ignored, Return/Escape still cancel, and tests exercise actual window events with button focus and unchanged repository snapshots.
