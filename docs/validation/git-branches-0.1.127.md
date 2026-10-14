# Branches and stash — 0.1.127

Stream 5, `dev/a127-git-branches`, 2026-10-14–15. Starting commit: `2da7acbf` (includes stream 2's hunk staging). Build, text logs and gallery root: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-branches`.

## Behavior and integration

The existing branch pill opens a searchable popup with Recent, Local and per-remote groups, current-branch indication, keyboard arrows/Return/Escape and accessibility labels. Local actions include checkout, create from the reviewed commit, rename, delete, compare and Show in History. Remote checkout creates a new tracking branch; remote deletion is not offered. A newly initialized repository can list and check out fetched remote branches before its first commit.

Compare is read-only, paged in both directions at immutable commit IDs and reuses `GitCommitRowContent`. Show in History calls `GitController.onShowBranchHistory(reference, repositoryIdentity)` when installed. Stream 3 should adapt this callback to its history query and visible branch filter. The standalone fallback already filters the existing History browser by the full reference and provides a removable filter chip.

The existing Stash menu opens a list with message, branch and age, changed-file metadata followed by one lazy read-only diff. Saved index changes and untracked files are represented separately. Apply and Pop restore the saved index as well as working files. Pop removes only the reviewed reflog entry after successful application. Conflicts report Git's diagnostics and retain the stash. New Stash supports message, include-untracked and keep-index options; Drop asks through PiQuestion.

Code lives in new branch/stash service and presentation files. Shared edits are limited to controller write admission/result/history hooks, Git runner stdin and explicit-reference history support, toolbar hooks and the removable legacy history chip. No sidebar or file-tree files are changed by this stream. This stream does not select or override the commit default; git-safety owns it and the owner's Staged changes decision. Agent tools, permission/capture/vault/data boundaries and pi 0.85.1 semantics are unchanged.

## Safety decisions

- Checkout uses native non-force `git switch` with ignored-file protection. A refusal displays Git's reason and offers an explicit Stash and Checkout action. Recovery checks the reviewed repository, HEAD, target tip and dirty-state fingerprint before stashing. Ignored files are not included in the recovery stash; an ignored-file collision continues to refuse checkout rather than overwrite those bytes.
- Delete asks once for any local branch, and again for an unmerged branch, naming its reviewed base, commit count and up to eight commit IDs/subjects. Both questions default Return to Cancel; Escape cancels. Current branches and branches checked out in registered worktrees are refused.
- Deletion verifies the reviewed HEAD, all registered worktree HEADs and target tip in the same native ref transaction. A newly switched worktree cannot turn the target into a current branch during that transaction. A new worktree registered after topology enumeration is outside this captured set: Git exposes no transaction locking the worktree registry itself. Concurrent repository mutation is not claimed to be globally serialized with external Git processes.
- Following successful ref deletion, configuration cleanup reacquires the target files-ref lock, checks that the branch has not been recreated, then uses native Git to remove its local configuration section. Lock/storage/missing-parent failures report that the branch was deleted but its configuration was retained; deletion is never blindly retried. Inherited/global configuration is not removed.
- Stash removal holds Git's stash ref and reflog locks while verifying the entire reviewed raw reflog fingerprint, selector and commit ID. It preserves unrelated raw log bytes (including non-UTF-8 identities/messages), saved index content and existing file permissions. Cleanup does not unlink another writer's subsequently acquired lock. Ref/log publication is two-file publication under writer locks, not a claim of crash-atomic storage.
- Removal intentionally refuses packed `refs/stash`, non-files ref storage, symlinked store paths and reflogs over 4 MiB. Apply/Pop may apply successfully but retain the stash if guarded removal cannot complete; the result says so. There is no automatic retry of an uncertain apply/pop. Ref-storage limitations direct the user to the terminal.
- Branch/stash reads disable replacement objects and lazy fetch; diff previews disable external diff/textconv. Parsing happens on the service actor, not in view body/layout. Superseded reads are cancelled and retired; only the selected stash/file preview is retained. Comparison pages are fetched explicitly.
- Presentation callbacks carry repository identity and a lifetime token. Repository changes/closing retire questions and reads; an old sheet completion cannot close a newly opened popup. All writes use the controller's shared busy admission.

## Validation

Generated temporary repositories only, with fixture identity, signing disabled, empty hooks and no credential helper. The remote tests use a local bare repository and local file transport, never a network remote. Native tests use the isolated test host through `scripts/test-macos.sh`; no installed-app launch, xctrace, real preferences or Keychain. Only this stream's build root is used; no named result bundles.

| Check | Result | Log under `logs/` |
| --- | --- | --- |
| Legacy ignored-file checkout, failing-first | 1 test, 3 expected failures before the protection | `checkout-red.log` |
| Review regressions, failing-first | HEAD changed during lock collection, deleted branch config inheritance, shared stash modes and unborn remote checkout: all four failed | `review-red.log` |
| Final focused package checks | 30 tests passed (16 branch + 14 stash), including History hash filtering and untracked-parent replacement protection | `package-final-focused.log` |
| Exact branch config cleanup follow-up | 3 tests passed (one new dotted-name case plus two strengthened existing cases); 31 distinct new package tests pass across the final focused runs | `config-final.log` |
| First complete views package | 235 tests, 3 skips, 0 failures | `package-all.log` |
| Complete views package after safety fixes | 239 tests, 3 skips, 0 failures; followed by the focused message/filter/third-parent checks above | `package-all-final.log` |
| Native behavior and standalone gallery | 9 interaction tests + 1 gallery passed | `native-gallery.log` |
| Affected native classes, including the new classes | 44 tests, 1 skip, 0 failures | `native-affected.log` |
| Final standalone gallery | 1 test passed, 42 images | `gallery-final.log` |
| Serial repository-switch and narrow-layout classes, each alone | 17 + 8 tests passed, 0 failures | `native-repository-switch.log`, `native-narrow-parity.log` |
| One full native parallel lane, four workers | 2,384 total: 2,349 passed, 35 skipped, 0 failures; exit 0 | `native-parallel.log`, `native-parallel-summary.json` |

Package assertions check actual refs, index blobs/entries, working-file bytes, upstream configuration, stash reflog identity and file modes. Coverage includes dirty/stale checkout, ignored files, remote tracking and unborn HEAD, unmerged/current/linked-worktree deletion, review races, rename collisions, bidirectional comparison, include-untracked/keep-index, saved-index-only data, apply/pop conflicts, stale selectors, duplicate stash object IDs, raw non-UTF-8 logs, concurrent/replaced locks and packed-ref refusal. Final review's configless/dotted-name success messages, explicit-branch hash filter and third-parent replacement defects were reproduced before repair in `config-message-red.log`, `config-prefix-red.log`, `history-filter-red.log` and `third-parent-red.log`. The popup surface assertion also failed before its explicit Pi background (`gallery-surface-red.log`).

The 44-case affected native run contains `GitBranchesInteractionTests`, `GitBranchesGalleryTests`, `GitCommitBrowsingTests`, `GitDiscardQuestionTests`, `GitHunkReviewTests`, `GitPanelAuditTests`, `GitPanelLayoutTests`, `GitPanelRedrawTests` and `GitPanelWidthTests`. Its skipped commit-browsing benchmark is pre-existing. The complete package result precedes the last small message/filter/third-parent corrections; the final focused runs cover those corrections rather than claiming another complete-suite run.

The existing serial repository-switch form helper was adapted to open the actual branch popup/New Branch button and New Stash menu instead of the replaced menu/form. Its stale-callback, repository identity and worktree assertions remain intact. After that adaptation, the existing repository-change explanation test failed four assertions (`native-form-notice-red.log`): the new forms closed safely but omitted the toolbar explanation. The full class additionally reproduced same-repository folder switches dismissing forms (`native-form-lifetime-red.log`, ten assertions in two tests). The coordinator now waits for a confirmed identity change or presentation retirement; writes stay blocked during unresolved folder reads. A minimal toolbar hook preserves the existing closure explanation. The initial obsolete-helper failures are retained in `native-repository-switch-legacy-helper.log`.

The single final native parallel run passed on macOS 14.8/arm64 in 544.2 seconds of testing. Counts above come from `xcresulttool get test-results summary`, saved as text JSON; `native-parallel-command.txt` records the four-worker invocation and all 104 serial-class exclusions. All ten new native cases passed in this lane, with no new skips. Source changes were complete before the run; only this validation record was finalized afterward.

Six mutations of actual production guards were caught by behavioral assertions (each test process exited 1). The mutation runner restored each source in `finally`; no mutation remains in the branch. Runner: `mutate.py` under the build root; summary: `logs/mutations.json`.

| Removed protection | Catching test | Log |
| --- | --- | --- |
| Unmerged delete guard | `testUnmergedDeletionRequiresExplicitSecondConsent` | `mutation-unmerged-delete.log` |
| Dirty checkout recovery guard | `testDirtyCheckoutGuardRejectsEditsMadeAfterTheRecoveryOffer` | `mutation-dirty-checkout.log` |
| Restore saved index on Pop | `testPopRestoresIndexOnlyBytesBeforeDropping` | `mutation-saved-index.log` |
| Stash lock ownership cleanup | `testDropDoesNotRemoveLocksAcquiredAfterPublication` | `mutation-lock-ownership.log` |
| Replacement-object protection | `testPopAppliesTheSameObjectAsPreviewDespiteReplacementRefs` | `mutation-replacement-object.log` |
| Linked-worktree HEAD transaction guards | `testLinkedWorktreeSwitchAtPublicationCannotDeleteItsNewCurrentBranch` | `mutation-linked-head.log` |

Reproduce package checks with `swift test --package-path packages/bello-views --scratch-path "$PI_BUILD_ROOT/views" --jobs 2`. Native checks use `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-git-branches scripts/test-macos.sh -only-testing:PiAppTests/<Class>`; serial classes run alone. Gallery output uses `PI_APP_BRANCHES_GALLERY` and `TEST_RUNNER_PI_APP_BRANCHES_GALLERY` set to the same directory. The final parallel lane uses the skip arguments from `python3 scripts/test-lanes.py parallel` and four workers.

## Gallery, review and remaining work

All 42 final PNGs in `gallery/` were inspected, including full-size narrow views and the seven `gallery-review/` contact sheets. The gallery covers branches, remote search, comparison, stash preview, New Stash and delete/drop confirmations, each in light/dark at 1180×760, 920×600 and 420×600 host sizes. Branch popup width is capped at 420 points; form and native question sizes remain their intrinsic size. Long branch names fit the fixture; narrow compare stacks its two directions; stash actions remain visible below the read-only diff. The narrow diff subtitle truncates as in the shared component. Native PiQuestion captures are rendered with their effective appearance and an opaque window-color backdrop because subview caching omits the native backdrop; no screenshot permission or real-app capture is used.

Read-only design, safety and UI review iterations found and verified the lock/identity/saved-index/replacement/race/configuration repairs recorded above. The required final whole-change **gpt-6.1-sol / xhigh** review reports **no remaining introduced findings**. A subsequent bounded review also verified the serial-test helper and confirmed-identity form-lifetime repair, without weakening any existing assertions. Advice: preserve the full-reference/repository History callback during integration, finalize this evidence, and complete combined release validation. Physical VoiceOver operation is not claimed; keyboard and accessibility labels are checked by native tests.

Stream 3's new History adapter, lead integration and release validation remain with the lead. This branch is pushed only to `dev/a127-git-branches`; it does not merge into or push `dev/next`, package a release or publish the website.

## Lead gallery polish — 2026-10-15

The current branch now uses a separate leading check column, reserved on every row, with `Current` in the accessibility value. Names contain no status glyph. Remote rows use `cloud`. Section headings use Quick Open's uppercase micro type, tertiary ink and 0.4-point tracking, with eight points above the first heading and fourteen above subsequent sections.

Local rows show a secondary upstream name and ahead/behind counts on the right. The existing single `for-each-ref` read includes `%(upstream:short)` and `%(upstream:track)`; the service actor parses them into the same immutable catalog as the branch list. No per-branch commands or reads during filtering, keyboard movement or layout were introduced. Full upstream refs remain available to callers. No upstream, in-sync, divergent, missing-upstream and unfamiliar statuses stay distinct; unknown counts are never presented as zero. Narrow rows reserve counts and prioritize the branch name over upstream text. Commit-default code was untouched.

Failing-first evidence: `logs/polish-tracking-red.log` (one case, ten expected missing-metadata failures) and `logs/polish-ui-red.log` (one case, three expected current-value/name/icon failures). After the changes, `logs/polish-package.log` passes all 33 branch/stash package cases (19 + 14); `logs/polish-native-gallery.log` passes all eleven native cases (ten interaction + one gallery). The native additions check current-mark alignment, accessibility reuse, section spacing/style, visible counts at 280-point popup width and catalog retention across filtering and keyboard movement.

All 42 regenerated PNGs in `gallery-polish/` were viewed through seven `gallery-polish-review/` contact sheets, with original-size light/dark narrow branch and search images also inspected. The divergent fixture shows `origin/topic ↑2 ↓1`; the in-sync row keeps only the upstream name. Branch/search, stash preview, New Stash, comparison and both confirmations remain readable at wide, 920×600 and narrow host sizes. Read-only gpt-6.1-sol/xhigh review of the polish reports no introduced findings.

## Upstream integration — 2026-10-15

Fetched `origin` and merged `origin/dev/next` at `efe431a345fe68fba24cd8381940a9fb835d68fc` into this workstream, after polish commit `2339dbb4`. Git merged the release notes and project registrations without textual conflicts; both parents' registrations remain present. The incoming file folders, global Flat sidebar and file-review continuity are preserved alongside the already merged hunk staging. This integration does not choose or override the commit default.

Combined review caught a branch-filter lifetime issue when File Review opens History in another repository. A confirmed repository change now retires only the branch reference after publishing the new snapshot; same-repository subfolders retain it, and text/author/path/all-branches filters stay intact. Choosing Show in History while a different repository's status is still pending reports that the repository was loading and asks the reader to try again. The callback and fallback both wait for a matching published snapshot, and a successful retry clears that notice. This keeps the shared hook small for the History stream's adapter.

Both regressions failed before their repairs: `logs/polish-integration-red.log` has five expected assertions for absent and same-named destination branches, including Git's bad-revision error and the missing destination commit. `logs/polish-early-history-red.log` has three expected assertions for premature filter/callback admission. The final tests assert actual destination commit IDs, preserved generic filters and unchanged index/worktree snapshots, including a held status read and successful retry.

| Integration check | Result | Log under `logs/` |
| --- | --- | --- |
| Complete merged views package, before the two controller integration repairs | 265 total, 3 skipped, 0 failures | `polish-merged-package-all.log` |
| Controller package regressions after the publication reset | 40 passed, 0 failures (`GitRepositoryStateTests`, `GitRevealTests`, `GitCommitScopeTests`) | `polish-merged-controller-package.log` |
| Affected native branch, File Review and commit browsing classes after the publication reset | 35 total, 34 passed, 1 pre-existing benchmark skip, 0 failures | `polish-merged-native-affected.log`, `polish-merged-native-affected-summary.json` |
| Final branch interactions, including the delayed-status admission repair | 12 passed, 0 failures | `polish-merged-native-branches.log` |
| Serial repository-switch class, alone | 17 passed, 0 failures | `polish-merged-native-repository-switch.log` |
| One final merged-tree full native parallel lane, four workers | 2,431 total: 2,395 passed, 36 skipped, 0 failures; exit 0 | `polish-merged-native-parallel.log`, `polish-merged-native-parallel-summary.json` |

The final full-lane counts come from `xcresulttool get test-results summary`; testing took 478.4 seconds on macOS 14.8/arm64. Its command and timing/exit record are `logs/polish-merged-native-parallel-command.txt` and `logs/polish-merged-native-parallel-run.json`, with all 105 serial classes excluded. All twelve branch interaction cases and the standalone gallery passed. The 36 skips are existing optional probes/captures/benchmarks, including the incoming File Review gallery, whose separate capture environment was not enabled. No new branch/stash test is skipped. Only this validation record changed after the run.

The required final read-only gpt-6.1-sol/xhigh whole-change review is clean after both integration repairs. It confirms preserved project registrations, callback composition and commit-default ownership. The existing six safety-guard mutation results above still apply; this polish and integration do not change those guards.

The merged-tree full lane regenerated all 42 PNGs in `gallery-merged/`. All seven `gallery-merged-review/` contact sheets were inspected, plus original-size narrow branch and stash-preview images. The branch/search, compare, stash-preview, New Stash and delete/drop confirmation scenes remain consistent in both appearances and all three host sizes. No additional visual correction was needed after integration.
