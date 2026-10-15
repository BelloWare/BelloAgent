# Branches and stash — 0.1.127

Stream 5, `dev/a127-git-branches`, 2026-10-14–15. Starting commit: `2da7acbf` (includes stream 2's hunk staging). Build, text logs and gallery root: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-branches`.

## Behavior and integration

The existing branch pill opens a searchable popup with Recent, Local and per-remote groups, current-branch indication, keyboard arrows/Return/Escape and accessibility labels. Local actions include checkout, create from the reviewed commit, rename, delete, compare and Show in History. Remote checkout creates a new tracking branch; remote deletion is not offered. A newly initialized repository can list and check out fetched remote branches before its first commit.

Compare is read-only, paged in both directions at immutable commit IDs and reuses the live History browser’s `GitHistoryRowContent`, including committed dates in UTC. Show in History sets `historyOptions.reference` and opens that browser with a removable full-ref chip. It clears previous search/date/path constraints to show the whole branch and retires older blame navigation. Successful rename retargets a matching filter to the normalized new full ref; successful delete clears it, both before the write refresh. Text/author/path/all-branches/date filters survive these writes. Failures, cancelled confirmations and a subsequently changed ref filter leave the selection intact.

The existing Stash menu opens a list with message, branch and age, changed-file metadata followed by one lazy read-only diff. Saved index changes and untracked files are represented separately. Apply and Pop restore the saved index as well as working files. After successful application, Pop rechecks the reviewed selector and object ID before asking Git to remove that entry. Conflicts report Git's diagnostics and retain the stash. New Stash supports message, include-untracked and keep-index options; Drop asks through PiQuestion.

Code lives in new branch/stash service and presentation files. Shared edits cover controller write admission/result/history hooks, Git runner stdin and explicit-reference history support, toolbar hooks, and removal of the unused legacy History UI. The new browser has the sole branch/ref state; `GitLogFilter.reference`, the provisional callback and the old chip are removed. The stateless legacy `log` reader retains an explicit reference argument and committed-date `%cI` handling. No sidebar or file-tree files are changed by this stream. This stream does not select or override the commit default; git-safety owns it and the owner's Staged changes decision. This stream leaves agent tools and permission/capture/vault/data boundaries unchanged. The final merge preserves the separately owner-approved incomplete-retry deviation from pi 0.85.1.

## Safety decisions

- Checkout uses native non-force `git switch` with ignored-file protection. A refusal displays Git's reason and offers an explicit Stash and Checkout action. Recovery checks the reviewed repository, HEAD, target tip and dirty-state fingerprint before stashing. Ignored files are not included in the recovery stash; an ignored-file collision continues to refuse checkout rather than overwrite those bytes.
- Delete asks once for any local branch, and again for an unmerged branch, naming its reviewed base, commit count and up to eight commit IDs/subjects. Both questions default Return to Cancel; Escape cancels. Current branches and branches checked out in registered worktrees are refused.
- Branch deletion rechecks the reviewed target tip and HEAD, then invokes native `git branch -d -- <name>`. Only the explicitly confirmed unmerged case uses `-D`; a `-d` refusal is never retried with `-D`. Git retains its checked-out/rebase/bisect reservations across primary and linked worktrees and owns branch configuration cleanup. There is no custom `update-ref` deletion or configuration-lock implementation.
- Stash deletion compares the reviewed raw reflog fingerprint, then immediately resolves the reviewed `stash@{n}` and checks its OID before native `git stash drop -- stash@{n}`. A stale selection is refused and the UI refreshes. The fingerprint additionally rejects changed lists whose selected OID still matches. Git owns loose/packed ref updates, reflog rewriting, repository permissions and lock cleanup; there is no custom unlink or ref/reflog publication.
- These identity checks precede the native commands and do not atomically serialize approval with external Git writers. A concurrent writer in the check-to-command window remains outside the guarantee. Each controller admits one write at a time; other controllers and external writers are not globally serialized with approval. There is no force checkout, force push or automatic retry of a destructive refusal.
- Read-only stash fingerprinting supports files ref storage and bounded regular reflogs up to 4 MiB. Native removal supports loose, packed-only and loose-plus-packed stash refs. Apply/Pop may apply successfully but retain the stash if guarded removal cannot complete; the result says so. Conflicts never attempt removal. Unsupported metadata storage directs the user to the terminal.
- Branch/stash reads disable replacement objects and lazy fetch; diff previews disable external diff/textconv. Parsing happens on the service actor, not in view body/layout. Superseded reads are cancelled and retired; only the selected stash/file preview is retained. Comparison pages are fetched explicitly.
- Presentation callbacks carry repository identity and a lifetime token. Repository changes/closing retire questions and reads; an old sheet completion cannot close a newly opened popup. All writes use the controller's shared busy admission.

## Validation

Generated temporary repositories only, with fixture identity, signing disabled, empty hooks and no credential helper. The remote tests use a local bare repository and local file transport, never a network remote. Native tests use the isolated test host through `scripts/test-macos.sh`; no installed-app launch, xctrace, real preferences or Keychain. Only this stream's build root is used; no named result bundles.

The following table records the original implementation. The later polish/integration and native-deletion correction sections contain the current-tree validation.

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

Package assertions check actual refs, index blobs/entries, working-file bytes, upstream configuration, stash reflog identity and file modes. Coverage includes dirty/stale checkout, ignored files, remote tracking and unborn HEAD, unmerged/current/linked-worktree deletion, review races, rename collisions, bidirectional comparison, include-untracked/keep-index, saved-index-only data, apply/pop conflicts, stale selectors, duplicate stash object IDs, raw non-UTF-8 logs, concurrent/replaced locks and native packed-ref deletion (the original packed-ref refusal is superseded by the correction below). Final review's configless/dotted-name success messages, explicit-branch hash filter and third-parent replacement defects were reproduced before repair in `config-message-red.log`, `config-prefix-red.log`, `history-filter-red.log` and `third-parent-red.log`. The popup surface assertion also failed before its explicit Pi background (`gallery-surface-red.log`).

The 44-case affected native run contains `GitBranchesInteractionTests`, `GitBranchesGalleryTests`, `GitCommitBrowsingTests`, `GitDiscardQuestionTests`, `GitHunkReviewTests`, `GitPanelAuditTests`, `GitPanelLayoutTests`, `GitPanelRedrawTests` and `GitPanelWidthTests`. Its skipped commit-browsing benchmark is pre-existing. The complete package result precedes the last small message/filter/third-parent corrections; the final focused runs cover those corrections rather than claiming another complete-suite run.

The existing serial repository-switch form helper was adapted to open the actual branch popup/New Branch button and New Stash menu instead of the replaced menu/form. Its stale-callback, repository identity and worktree assertions remain intact. After that adaptation, the existing repository-change explanation test failed four assertions (`native-form-notice-red.log`): the new forms closed safely but omitted the toolbar explanation. The full class additionally reproduced same-repository folder switches dismissing forms (`native-form-lifetime-red.log`, ten assertions in two tests). The coordinator now waits for a confirmed identity change or presentation retirement; writes stay blocked during unresolved folder reads. A minimal toolbar hook preserves the existing closure explanation. The initial obsolete-helper failures are retained in `native-repository-switch-legacy-helper.log`.

The single final native parallel run passed on macOS 14.8/arm64 in 544.2 seconds of testing. Counts above come from `xcresulttool get test-results summary`, saved as text JSON; `native-parallel-command.txt` records the four-worker invocation and all 104 serial-class exclusions. All ten new native cases passed in this lane, with no new skips. Source changes were complete before the run; only this validation record was finalized afterward.

At the original implementation, six mutations of production guards were caught by behavioral assertions (each test process exited 1). The mutation runner restored each source in `finally`; no mutation remains in the branch. Runner: `mutate.py` under the build root; summary: `logs/mutations.json`. The lock/transaction implementation and its mutation claims below are historical; native-deletion mutation results in the later correction section supersede them.

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

The final integration below completes the new History browser adapter. Lead merge into `dev/next` and release validation remain with the lead. This branch is pushed only to `dev/a127-git-branches`; it does not merge into or push `dev/next`, package a release or publish the website.

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

The required final read-only gpt-6.1-sol/xhigh whole-change review is clean after both integration repairs. It confirms preserved project registrations, callback composition and commit-default ownership. At that merge point, the six safety-guard mutation results above still applied; the polish and integration had not changed those guards. The native-deletion corrections below supersede the former ref/lock implementation and its mutation evidence.

The merged-tree full lane regenerated all 42 PNGs in `gallery-merged/`. All seven `gallery-merged-review/` contact sheets were inspected, plus original-size narrow branch and stash-preview images. The branch/search, compare, stash-preview, New Stash and delete/drop confirmation scenes remain consistent in both appearances and all three host sizes. No additional visual correction was needed after integration.

## Native deletion and rename review corrections (2026-10-15)

The follow-up read-only review found three defects in the previous implementation: manual branch ref deletion bypassed Git's rebase/bisect reservations in detached worktrees; loose-only final stash deletion did not coordinate with packing; and rename left the active History filter on the old branch name. The lead requested native `branch -d`/explicitly confirmed `-D` and `stash drop` after a fresh selector/OID check. Those commands now own deletion; the custom configuration writer and stash ref/reflog writer are removed. Confirmation UI and commit-default ownership are unchanged.

Failing-first evidence is `logs/native-delete-red.log` (3 tests, 10 assertions failed) and `logs/rename-history-red.log` (1 test, 3 assertions failed). Rebase and bisect fixtures exercise both the primary and a linked worktree, preserve reservation files/index/worktree bytes, and verify that Git itself refuses deletion. Packed-stash fixtures cover both packed-only and loose-plus-packed refs, confirm `refs/stash` is absent afterward, and preserve repository bytes and the saved stash object. The rename test uses the real form with a whitespace-padded name, checks actual History commits and the visible chip, and preserves all other filters.

Additional boundary checks move a stash selector after the fingerprint read, change the list while the selected OID stays the same, verify stale confirmed Drop refreshes the visible list, preserve History after failed rename, and change the History filter during an admitted rename. Git's explicit shared-repository mode `0660` is honored; this does not claim preservation of arbitrary manually assigned modes independent of Git configuration.

| Check | Result | Log under `logs/` |
| --- | --- | --- |
| First green affected package classes | 38 passed (21 branch + 17 stash), zero failures | `native-delete-green-package.log` |
| First green native branch interactions | 16 passed, zero failures | `native-delete-green-native.log` |

Eight focused mutations were rejected by behavioral assertions against real fixture state. `mutate-native-deletion.py` restores each source in `finally`; the text summary is `logs/review-mutations.json`. Package mutations exit 1 and native mutations exit 65 from expected XCTest failures, with no compile failures.

| Mutation | Result | Log under `logs/` |
| --- | --- | --- |
| Replace native branch deletion with unsafe ref deletion | Both reservation tests fail; 8 assertions catch deleted primary/linked rebase/bisect refs | `review-mutation-native-branch-protection.log` |
| Replace native stash deletion with loose-only removal | Packed-only and loose-plus-packed cases each retain `refs/stash`; 2 assertions fail | `review-mutation-native-packed-stash.log` |
| Remove the final stash-selector OID comparison | Wrong entry is dropped after the selector moves; 3 assertions fail | `review-mutation-stash-final-oid.log` |
| Remove the reviewed-list fingerprint check | A changed list with the same selected OID is incorrectly accepted; 2 assertion failures plus the expected missing-log read error | `review-mutation-stash-fingerprint.log` |
| Omit successful rename's filter retarget | Old filter/chip and bad-revision notice return; 3 assertions fail | `review-mutation-rename-retarget.log` |
| Require resolved folder identity when retargeting a completed rename | The hidden same-repository folder-switch regression retains the old ref and reports bad revision; 3 assertions fail | `review-mutation-rename-folder-identity.log` |
| Retarget without checking the still-active filter | The user's new History selection and displayed commits are overwritten; 2 assertions fail | `review-mutation-rename-matching-filter.log` |
| Skip the second unmerged-delete question | The destructive write proceeds after only one question; count and required-question assertions fail | `review-mutation-unmerged-second-question.log` |

The unmerged mutation exercises the actual second-question gate. Removing only the service's explicit-consent guard would still be protected by native `-d`, so the test does not claim that a masked mutation failed. The unchanged dirty-checkout guard's original mutation evidence remains valid. The native-command and consent mutations above supersede the historical hand-written ref/lock checks.

The final read-only gpt-6.1-sol/xhigh code double-check is clean after the folder-navigation correction below; no remaining introduced findings. Its advice is to finish serial/full native validation and record the mutation results before committing.

The final double-check also identified a post-rename navigation edge. Write-admission readiness was too strict for updating retained History metadata while the panel hid during navigation to another folder in the same repository. `rename-subfolder-red.log` reproduces three failures with actual old-ref/bad-revision results. Retargeting now requires the captured repository identity and retained snapshot, an open controller, and the matching old filter; admission itself still requires a resolved active repository. Reopening the same repository retains the normalized renamed ref, while normal publication of a different repository clears it. The initial held-status probe (`rename-subfolder-initial-probe.log`) did not reproduce the issue because folder identification precedes that hook; the final test uses explicit hide/navigation/reopen state without sleeps or new test seams.

| Final regression check | Result | Log under `logs/` |
| --- | --- | --- |
| Complete views package, before the final folder-lifetime guard correction | 270 total, 267 passed, 3 existing skips, zero failures | `review-fixes-package-all.log` |
| Native branch interactions after that correction | 17 passed, zero failures | `review-fixes-native-branches.log` |
| Controller package checks after that correction | 40 passed, zero failures (`GitRepositoryStateTests`, `GitRevealTests`, `GitCommitScopeTests`) | `review-fixes-controller-package.log` |
| Serial repository-switch class, alone | 17 passed, zero failures | `review-fixes-native-repository-switch.log` |
| One final full native parallel lane, four workers | 2,436 total: 2,400 passed, 36 existing skips, zero failures; exit 0 | `review-fixes-native-parallel.log`, `review-fixes-native-parallel-summary.json` |


The final native lane regenerated all 42 PNGs in `gallery-review-fixes/`. All seven `gallery-review-fixes-contact/` contact sheets were inspected, plus original-size narrow branch and stash-preview captures. The separate current check column, remote cloud icon, section spacing and tracking metadata remain clear in both appearances. Compare stacks in narrow panes; stash actions and New Stash options remain visible; delete/drop questions preserve their cancellation behavior. No additional visual change was needed for these service/filter corrections.

The final full native lane took 480.1 seconds of testing on macOS 14.8/arm64. Its invocation and timing/exit record are `logs/review-fixes-native-parallel-command.txt` and `logs/review-fixes-native-parallel-run.json`; all 105 serial classes were excluded. All 17 branch interaction cases and the standalone gallery passed in the restored-source run. The 36 optional capture/probe/benchmark skips are unchanged; no branch/stash case is skipped. The Swift source/test hashes in `logs/review-fixes-source-hashes.json` still match the start of the run. Only documentation was finalized afterward. These native-deletion corrections were complete at `8a63e85c`; the subsequent new-browser integration is recorded below.


## Final integration with the live History browser (2026-10-15)

Fetched `origin` and merged `origin/dev/next` at `0e552844f8282259c022f5886cb99bb82a93ea6c`. The merge retains git-safety’s Pi confirmations and unchanged `defaultCommitScope = .stagedChanges`, stream 3’s History modules, file folders/continuity, the flat sidebar, hunk staging and the incoming incomplete-retry helper change. All release items were retained. The project conflict used this branch’s project followed by `xcodegen generate`; the generated project includes the combined source/test registrations and removes the retired chip file.

The branch action now drives the same `historyOptions.reference` used by the live browser’s Refs selector and removable chips. Rename and confirmed delete update only a still-matching ref in the captured repository’s retained snapshot before refreshing. Hidden same-repository folder navigation retains the update; a confirmed repository change clears the ref. The obsolete `GitLogFilter.reference`, uninstalled adapter callback and unused legacy History list/chip/rows are removed. Compare shares the new History row content and accessibility text. The legacy service read still accepts an explicit reference argument, preserving branch-constrained hash lookup and committed dates without a parallel browser state.

Failing-first evidence: `logs/final-integration-history-red.log` records three tests and fourteen expected assertion failures for Show, rename and delete through the live browser. `logs/final-integration-navigation-red.log` records two tests and eight expected assertion failures for pending blame overriding Show and comparison retaining the old row content. The new navigation test begins without any selected commit, so assigning `nil` alone cannot mask the missing navigation guard. All twenty branch interaction tests then passed in `logs/final-integration-history-green.log`.

The read-only gpt-6.1-sol/xhigh whole-change code review is clean. It verified the sole ref-filter path, retained-snapshot guards, explicit navigation retirement, native Git deletion, unchanged staged default and generated registrations. The affected native follow-up in `logs/final-integration-native-affected.log` passed 132 of 133 cases, with one existing commit-browsing benchmark skip and no failures. It includes Git safety/confirmations, History filters/integration, hunk review, panel layout/redraw/lifecycle, rename/tool behavior and file blame/review state, in addition to the separate twenty branch interaction cases above.

Six mutations of the actual controller behavior were caught, with eight focused test executions and twenty-seven expected assertion failures. `mutate-final-history.py` restores the controller in `finally`; all 940 saved Swift source/test hashes matched afterward. The summary is `logs/final-integration-mutations.json`; individual logs use the prefix `final-integration-mutation-`.

| Mutation | Behavioral result | Log suffix |
| --- | --- | --- |
| Omit Show’s ref filter | Wrong query/commits and absent removable chip; 4 failures | `branch-filter.log` |
| Omit successful branch-write retarget/clear | Rename and delete leave stale query/chip/error state; 10 failures | `branch-write-retarget.log` |
| Remove the still-matching-ref guard | Rename and delete overwrite a newer selected ref; 4 failures | `matching-reference.log` |
| Omit explicit navigation retirement | Older blame reselects its commit and reveal after Show; 3 failures | `new-navigation.log` |
| Keep the previous repository’s reference | Absent and same-named destination branches retain the wrong filter/results; 4 failures | `repository-reference.log` |
| Require resolved write-admission identity for metadata retarget | Hidden same-repository folder navigation keeps the old ref; 2 failures | `hidden-folder-retarget.log` |

| Final integration check | Result | Log under `logs/` |
| --- | --- | --- |
| Branch interactions through the live browser | 20 passed, zero failures | `final-integration-history-green.log` |
| Other affected native Git, History and file-review classes | 133 total, 132 passed, 1 existing benchmark skip, zero failures | `final-integration-native-affected.log` |
| Serial repository-switch class, alone | 17 passed, zero failures | `final-integration-repository-switch.log` |
| Serial narrow-panel parity class, alone | 8 passed, zero failures | `final-integration-narrow-parity.log` |
| Serial standalone History gallery, alone | 1 passed, 16 PNGs | `final-integration-history-gallery.log` |
| Complete bello-views package | 307 total, 304 passed, 3 existing skips, zero failures | `final-integration-package-all.log` |
| Branch/stash/compare/History gallery after fixture correction | 1 passed, 48 PNGs | `final-integration-gallery-green.log` |
| One final full native parallel lane, four workers | 2,491 total: 2,455 passed, 36 existing skips, zero failures; exit 0 | `final-integration-native-parallel.log`, `final-integration-native-parallel-summary.json` |

The package suite includes all 21 branch, 17 stash, 18 commit-scope, 17 History-query and 3 History-wiring tests. Serial classes ran individually. The controller mutation runner completed before these restored-source checks. The complete package took 451.4 seconds; only the gallery fixture lifecycle adjustment below changed Swift source afterward. All production and behavioral-test sources were identical between the package/affected runs and the final native lane.

Adding a live History panel to the branch gallery exposed a fixture lifecycle error: removing the panel correctly suspends its controller, so the next standalone popup fixture could time out waiting for a branch catalog. The initial gallery probe (`final-integration-gallery-probe.log`) failed there, while its integrated History gallery passed and produced 36 PNGs. The fixture now waits for that suspension callback, resumes the standalone fixture and awaits readiness. The standalone branch gallery then passed in 37.2 seconds. The read-only gpt-6.1-sol/xhigh follow-up verified that this bounded fixture change preserves production behavior and assertions.

Before the full native lane, all 100 generated images were inspected through 18 contact sheets, plus original-size narrow branch-History, stash and long-ref captures. They cover 48 branch/search/compare/branch-History/stash/New Stash/confirmation images in `gallery-final-integration/`, 36 integrated History images in `gallery-final-history/` and 16 standalone History images in `gallery-final-history-standalone/`. Each directory is under the stream build root; corresponding contact directories append `-contact`. Light/dark, wide, 920×600 and narrow views preserve readable branch tracking, removable ref chips, read-only comparison/diffs and visible stash actions. Integrated History additionally covers empty/loading results, file filters and pinned blame outside the filter. No production visual correction was required.

`logs/final-integration-final-source-hashes.json` records all 940 Swift source/test hashes immediately before the full lane. Compared with the earlier mutation/package manifest, only `GitBranchesGalleryTests.swift` differs, for the lifecycle correction described above.

The one final native parallel lane passed on macOS 14.8/arm64 with four workers and all 106 serial classes excluded. Counts come from `xcresulttool get test-results summary`; the invocation and timing/exit evidence are `logs/final-integration-native-parallel-command.txt` and `logs/final-integration-native-parallel-run.json`. Xcode's test observer reports 584.6 seconds. All twenty branch interaction cases, the History integration/filter classes and the regenerated galleries passed. The 36 skips are existing optional probes/captures/benchmarks and the test host’s absent Conversation-menu check; no branch/stash case is skipped. There were no failures to rerun alone.

The lane’s branch and integrated History gallery classes passed in 37.3 and 19.0 seconds, regenerating all 48 and 36 images respectively. All fourteen refreshed contact sheets and original-size narrow branch-History, stash, compare and long-ref captures were inspected again, along with a 920×600 filtered History capture. No visual correction was needed. The sixteen standalone History images remain from the isolated serial gallery run; `logs/final-integration-gallery-hashes.json` records the final 100 inspected PNGs.

All 940 final Swift source/test hashes and all 100 inspected gallery hashes still matched after the full lane. Only documentation was finalized afterward. The final read-only documentation check found consistent evidence and no source follow-up; two stale Retry/Flat release-note status tails were corrected to reflect their already-merged upstream state, preserving every release item and its follow-up. This stream's implementation and integration are complete. Lead merge into `dev/next` and combined release validation remain with the lead.
