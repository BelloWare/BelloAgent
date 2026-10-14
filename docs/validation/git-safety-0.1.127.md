# Git safety — 0.1.127, stream 1

Branch: `dev/a127-git-safety`. Worktree: `wt-git-safety`. Validation date: 2026-10-14. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety`. This is the initial stream validation record, not a release gate. The subsequent owner decision, merges and integrated History validation are recorded in [the follow-up](git-safety-integration-0.1.127.md).

## Behavior and decisions

- Unmerged porcelain pairs retain their actual XY status, display a red `!` / “Conflict”, and do not count as staged content. A fresh service conflict check refuses commits before preparing untracked files.
- Unstage in an unborn repository removes only selected, literal index paths with `rm --cached`; working bytes and unrelated staged blobs survive. The fallback first verifies a symbolic branch with no existing ref, so an unreadable established HEAD is not treated as an empty tree.
- Amend and Reword ask a Pi question showing the repository, full reviewed HEAD, branch, message and content scope. Cancel is the Return default, Escape cancels, and duplicate answers cannot dispatch twice. A hidden/moved panel cancels preparation or an unanswered question. An already authorized write may finish.
- Frozen requests retain repository generation, message, amend choice, checked paths, scope and Sign off. Submission checks these again after preflight. Service checks bind rewrites to the reviewed HEAD and branch, including another check after amend preparation. Reword keeps its existing hook, tree-preservation and compare-and-swap behavior.
- At the initial stream commit, Checked files remained today's default; `GitController.defaultCommitScope` controls initialization and reset. Checked files takes whole working-tree content; staged scope takes exactly the index. No fallback or automatic scope switch was added.
- Sign off is optional. Native commits use Git's sign-off behavior; reword adds the configured committer trailer before message hooks. Hooks stay enabled, and a refused operation retains the draft and Sign off choice. Changing tabs preserves the choice; closing the panel resets it.
- Check reads conflicts and selected-scope whitespace on the Git service actor, with cancellation and generation checks. Conflict checks block commits. Whitespace and advisory Git diagnostics are bounded and require confirmation. The whitespace rules remain Git's configured rules. In particular, `safecrlf=warn` remains advisory rather than becoming a fatal application policy.
- A historical diff offers **Open Working File** at line 1 of today's file. Historical line context menus do not offer an inaccurate working-file line jump. Immutable revision tabs are outside this stream.

The commit box and changes list moved into their planned owned files; the operation question is a new file. No hunk, history-filter, file-viewer, sidebar, agent-tool, capture, permission, vault or Keychain implementation changed. XcodeGen registered the new app sources/tests through the existing globs; no project.yml change was needed.

## Failing first and mutations

All new Git tests create temporary repositories with fixture-only identities, signing disabled, no remotes, no credential helper, private hooks and network protocols disabled. Fixture command setup ignores global/system Git config. Native tests ran through the isolated test host, not the installed app. No named result bundles or xctrace launch were used; text logs below are the evidence.

- Baseline package run: 5 tests, 11 assertion failures (`logs/package-failing-first-2.log`). Conflict classification, stale HEAD/branch amend and staging-before-conflict regressions failed. **Unborn unstage already passed on this Mac's Apple Git 2.39.5**; the anticipated baseline failure did not reproduce. The explicit guarded implementation is supported by the preservation test and mutation, not a claimed baseline failure.
- Baseline AppKit run: 2 tests, 6 assertion failures (`logs/app-failing-first.log`). Amend dispatched without a question and changed repository/draft state; Discard gave Return to the destructive action.
- Review found successful `git diff --check` could emit advisory CRLF stderr. The new real-repository regression failed first (`logs/package-warning-failing-first.log`), then passed with the configured conversion, preserved working bytes and visible diagnostic.
- Visual inspection found the narrow first file row clipped. The gallery's new whole-row assertion failed in all eight 310×600 scenes (`logs/gallery-row-failing-first.log`). The list now reserves one full section/file row; scope, Amend and Sign off share a row where their intrinsic widths fit, retaining separate rows in narrow panes. This preserves the five-line draft and useful diff height at 700×640 as well.
- Final lifecycle review found Sign off survived a closed/reopened controller. A hide/show/close/reopen regression failed on both close/reopen assertions (`logs/signoff-close-failing-first.log`); `letGo()` now resets the option.

Six mutation runs changed real production guards, restored the exact source bytes afterward, and produced behavioral failures (`logs/mutations.json`, `logs/mutation-final-request-cancel.json`):

| Mutation | Regression evidence |
| --- | --- |
| Ignore reviewed HEAD/branch equality | Changed HEAD, index and branch-bound reword acceptance |
| Remove the final amend target check | A generated clean filter advances HEAD during preparation; the wrong commit is amended |
| Remove the conflict guard | An untracked checked file enters the index despite unresolved conflicts |
| Remove `--cached` from unborn Unstage | Selected working-tree file is deleted |
| Accept stale repository/choices and remove Cancel defaults | Old repository/changed-scope mutations and draft clearing; rewrite/discard default and real-sheet keyboard checks fail |
| Remove the final repository predicate and pending-question cancellation guard | Two tests produce six failures: stale/hidden answers change repository state and clear drafts. The hidden-answer test joins the dispatched task before checking state |

Logs: `mutation-reviewed-target.log`, `mutation-prepared-target.log`, `mutation-conflict-guard.log`, `mutation-unborn-cached.log`, `mutation-request-and-default-guards.log`, `mutation-final-request-cancel.log` under the build root's `logs/` directory. The final restored-source tests are recorded below.

## Validation results

- Full `bello-views` package suite: **203 tests, 3 skipped, 0 failures** (`logs/package-full.log`). This run includes the 12 safety tests present before the subsequent advisory-CRLF regression.
- The expanded package safety class: **13 tests, 0 failures**, including advisory CRLF conversion (`logs/package-safety-final.log`).
- Earlier focused native regression run: **8 tests, 0 failures**, covering safety, Discard questions and redraws (`logs/app-safety-1.log`). Existing ChangesTab, changelist, commit browsing, audit and rename classes also passed in the expanded run (one opt-in browsing test skipped).
- Restored-source package checks: **31 tests, 0 failures** (13 safety plus 18 commit-scope tests, `logs/package-restored.log`).
- Restored-source native checks: **17 tests, 0 failures** (10 operation safety, 1 gallery, 2 Discard questions, 4 redraw tests, `logs/app-restored.log`).
- Affected serial classes, each alone with parallel testing disabled: **71 tests, 0 failures** (`logs/serial-summary.json` and `logs/serial-<Class>.log`): GitRepositorySwitchTests 17, GitWorkingTreeWatcherTests 16, GitPanelNarrowParityTests 8, ChangesTabFrameTests 7, GitDiffTableTests 19, GitPanelTimingTests 4. The large-repository frame probes reported zero layout cycles; typing/redraw, scroll, clipboard and working-file menu regressions passed.
- The **one full native parallel lane**, with eight workers: **2,375 tests — 2,337 passed, 35 skipped, 3 failed** (`logs/native-full-parallel.log`, `logs/native-full-parallel-summary.json`; command in `logs/full-parallel-command.json`). This was a failed run, not a clean gate. It found two stream regressions: a queued authorized commit was refused when the panel hid, and the new commit box reduced the narrow window's diff to 153 pt instead of the expected 170 pt. Submission now separates repository/choice validity from question visibility. Narrow Changes layout allows the changelist to shrink while retaining one whole section/file row, and the commit choices share a row where their widths fit.
- The third full-lane failure was `PastedAttachmentTests.testCleanupDoesNotHoldRestorationOrMetadataReads`, waiting for “cleanup started”. No attachment implementation changed. The whole attachment class passed on rerun; the parallel-only failure's cause remains unconfirmed. There was no second full lane.
- After the two Git fixes, **37 native tests passed, 0 failures**: operation safety 10, redraw 4, shown/hidden lifecycle 13, panel width 3, gallery 1, pasted attachments 6 (`logs/app-post-lane-fixes.log`). **31 package tests passed, 0 failures** (safety 13 and commit scope 18, `logs/package-post-lane-fixes.log`).
- Final restored-source checks after the sixth mutation, narrow layout refinement and Sign off lifecycle fix: **32 native tests, 0 failures** (operation safety 11, redraw 4, shown/hidden lifecycle 13, panel width 3, gallery 1; `logs/app-final.log`), plus **31 package tests, 0 failures** (safety 13 and commit scope 18; `logs/package-final.log`). Commands and totals are retained in `logs/final-summary.json`.
- Final affected serial layout rechecks, each alone: **15 tests, 0 failures** (GitPanelNarrowParityTests 8 and ChangesTabFrameTests 7; `logs/serial-final-<Class>.log`). The large-repository pane/window probes retained zero layout cycles.

Early expanded native runs exposed test-driver defects: path spelling from Foundation differed from Git's top-level path, non-key test windows did not dispatch ordinary Return through `performKeyEquivalent`, and native buttons legitimately supplied an accessibility title instead of an explicit label. The corrected tests use Git's actual top-level identity, the sheet's default cell, and label-or-title accessibility names. The final stale-repository test also submits an old request directly after switching, independently testing the controller guard behind the question guard. The intermediate failing logs are retained rather than counted as passing validation.

Read-only review found the advisory-stderr handling, hardcoded scope reset and Sign off close/reopen reset. All were fixed; the final whole-change review, including the adaptive choices row and cancellation checks, reported no remaining actionable findings. The reviewer ran no builds and edited no files.

## Gallery and accessibility

Standalone `GitSafetyGalleryTests` builds only generated Git scenes, without the large screenshot-suite gateway setup. The 40 captures cover conflict, amend target, whitespace failure and commit box in light/dark at 1180×780, 920×600, 700×640 and 310×600; eight captures show the real amend sheet. The 700×640 scenes exercise five-line drafts and the combined choices row. The test verifies control bounds, a fully visible first file row, accessible names, checkbox roles/values, conflict semantics and safe default buttons.

Gallery directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/gallery/`.

Names: `{conflict,amend-target,preflight-failure,commit-box}-{light,dark}-{1180x780,920x600,700x640,310x600}.png`, plus `amend-target-{light,dark}-{1180x780,920x600,700x640,310x600}-sheet.png`. All 40 final scenes were visually inspected through five contact sheets, retained beside them. Sheet capture composites the cache over the sheet appearance's window color because AppKit vibrancy otherwise captures transparent pixels. Keyboard coverage exercises Escape and the Return default on actual sheets. A physical VoiceOver listening pass was not performed.

## Limits and handoff

Native `git commit --amend` is **not atomic with respect to external Git** after its final check. This change narrows and detects stale intent; it does not introduce a strict amend transaction. A clean filter/hook or external writer can also change state during preparation. A stale target detected after staging a new checked file leaves that prepared index entry in place; it never rolls an index back over another writer. The regression explicitly verifies the newer HEAD/tree and working bytes survive.

Preflight is advisory about a moment in time. Submission repeats it, and Git still enforces the real commit and hook result. No display diff is parsed in a view body or layout, and preflight retains only bounded diagnostics. Whitespace checking of unborn/untracked files uses per-file Git checks; this is not a new diff cache.

The owner can flip the single default-scope constant after deciding Checked files versus Staged changes. Integration into `dev/next`, other streams, hunk-staging safety and release packaging remain the lead's work. This branch must be pushed on its own, with no merge or push to `dev/next`.
