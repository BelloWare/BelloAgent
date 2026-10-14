# Whole-hunk staging — 0.1.127

Stream 2, `dev/a127-git-hunks`, 2026-10-14. Starting commit: `2472ace6`. Build and evidence root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-git-hunks`.

## Behavior and scope

Ordinary tracked, modified text files offer **Stage hunk** in working-tree diffs and **Unstage hunk** in index diffs. Previous/Next Change and F7/Shift-F7 navigate within the focused diff; Space activates its focused Pi checkbox. Accessibility includes checked state, file, change ordinal and hunk line ranges. Navigation survives layout changes, restarts when the patch changes, and moves focus to the table for a disabled, partly shown hunk. Text selection survives an unrelated index/status refresh when the raw patch is unchanged.

Staging offers **Review Staged Changes**, including after staging the final hunk removes the unstaged row. The offer selects the index diff. Neither staging nor review changes commit scope. Today's **Checked files** default is preserved; the Git safety stream owns the requested single default setting and pending owner decision.

Whole-file operations remain available. Hunk actions explain why they are unavailable for additions/deletions, renames, binary data, mode changes, symlinks, submodules and conflicts. Conservative additional exclusions: custom diff/content/encoding/line-ending attributes, automatic CRLF conversion, sparse/assume-unchanged entries, non-UTF-8 patches, working files/blobs over 4 MiB, patches over 8 MiB or the display parser's 20,000-line limit, and indexes over 64 MiB. Raw CRLF and missing-final-newline content without conversion is supported. The 1,500-row display gate disables a partly displayed hunk until the reader chooses the whole diff.

No new history-rewrite/discard operation, agent tool, permission, capture, vault or data-boundary behavior is introduced. New code is isolated in hunk/patch/transaction files. `GitPanel.swift` has only the binding and final-hunk-offer selection wiring; no controller, sidebar, file-tree, menus or tab-host refactor.

## Safety implementation

- Git produces a complete raw patch from bounded before/after byte snapshots in a private directory outside the repository. External diff, textconv and user/system configuration are disabled there. The display parser never produces mutation input.
- The raw parser validates file headers, mode, hunk coordinates, counts and missing-newline markers. One selected hunk replaces precisely its expected byte range in the captured index blob. There is no fuzzy/context-offset/three-way fallback.
- A write obtains Git's real `index.lock` with exclusive creation, checks the captured index byte identity while holding it, updates a private index, writes and fsyncs the finished lock file, checks cancellation/index identity/lock ownership again, and atomically renames it over the index. Lock cleanup removes only the owned inode. Index permissions and unrelated staged entries are preserved, including split indexes.
- HEAD is checked before/after preparation. Object reads disable replacement objects and lazy fetch. Working files are read through bounded, no-follow descriptors; staging revalidates their reviewed bytes and mode. No working file is written. Content filters are never executed by the hunk path, even if attributes change during a review.
- Duplicate actions are single-flight in the view and cannot consume the same reviewed index twice in the service. Stale actions refuse and refresh; failed/uncertain outcomes are never automatically retried. Navigation invalidates visible actions synchronously; completion notices belong to the captured repository and selection. Recycled controls capture only UUID/scalars, not index/blob snapshots.

## Validation

All new fixtures are generated local temporary repositories with fixture identity, signing disabled, no remotes, no network and no credential helper. Native runs use `scripts/test-macos.sh` and its isolated test host. No installed app launch, xctrace, real preference write or Keychain access. Builds use only the stream's root. Evidence is text logs, with no named result bundles.

| Check | Result | Evidence under `evidence/` |
| --- | --- | --- |
| Raw parser failing-first | 3 tests, 2 expected failures before implementation | `patch-failing-first.log` |
| Native UI regression failing-first | Final-hunk offer, stale visible review, refresh selection and Space regressions reproduced | `native-ui-failing-first-2.log` |
| GitPatchTests + GitIndexTransactionTests | 20 tests passed | `patch-transactions-final.log` |
| Full bello-views package | First full run: 211 tests, 3 skips, 0 failures. Later run under overlapping native gates: 21 assertions failed in 7 existing repository-state/reveal tests. All 7 subsequently passed in filtered/isolated runs; see follow-ups below | `views-full.log`, `views-full-final.log` |
| GitHunkReviewTests | 9 behavioral tests passed (8-test class run plus the added pointer/AX press test) | `native-hunks-final.log`, `native-hunk-pointer-ax-final.log` |
| Standalone GitHunkGalleryTests | 1 test passed, 16 images | `native-gallery.log` |
| Final hunk tests + gallery after binary-message improvement | 9 tests passed (8 behavioral + 1 gallery) | `native-hunks-gallery-final.log` |
| Existing serial GitDiffTableTests, alone | 19 tests passed | `native-diff-table.log` |
| Existing serial GitPanelNarrowParityTests, alone | 8 tests passed | `native-narrow-parity.log` |
| Filtered package follow-up (including final binary fallback) | 23 tests, 15 assertion failures in 3 existing repository-state tests; final binary check and all 10 reveal tests passed | `views-failed-classes-rerun.log` |
| Isolated baseline/current repository-switch comparison | Both passed, 1 test each | `package-baseline-timeout.log`, `package-current-isolated.log` |
| Remaining isolated repository-state cases | 2 tests passed | `package-remaining-isolated.log` |
| One full native parallel lane, 4 workers | 2,374 total: 2,338 passed, 35 skipped, 1 failed; exit 65. All 9 hunk behavioral tests and the gallery passed | `native-parallel.log`, `native-parallel-summary.json` |
| Isolated SessionMarkUnreadTests follow-up | All 11 tests passed | `native-mark-unread-followup.log` |

The later full package run is not a clean full-suite result. The seven failing tests are in unchanged repository-state/reveal code; all passed on follow-up. The representative switch test passed on both the untouched starting commit and this branch. Overlapping native gates were running elsewhere on the shared Mac, but this does not establish the cause of the failures. No production or existing-test changes were made to hide them.

The full native lane's one failure is `SessionMarkUnreadTests.testTheMenusOfferMarkAsUnreadForAReadChatAndMarkAsReadOtherwise`: its bulk menu expected **Mark 2 as Read**, but offered **Mark 1 as Read**. That test and its menu/sidebar implementation are unchanged. All 11 tests in the class passed when run alone; the cause remains unconfirmed. The canonical counts above come from Xcode's result summary; interleaved console lines undercount passing executions. The full lane was run only once.

The 17 transaction tests assert actual index blobs, index entries/trees and working bytes: round-trip one hunk; mixed staging; different line counts/coordinates; CRLF/no final newline; quoted/tab/newline/Unicode/pathspec-like paths; stale index; unrelated staging; changed worktree; existing/replaced lock; real competing Git writer; duplicate actions; publication-time index replacement; cancellation; shared permissions; split index; binary/mode/add/delete/rename/large-diff refusal; symlink/submodule/unmerged refusal; external/textconv/late-clean-filter sentinels; and malicious replacement objects.

Five mutations of the actual production guards were run in a disposable package copy under the build root and all were caught by behavioral assertions. The source copy was restored after each mutation:

| Mutation | Catching test | Log |
| --- | --- | --- |
| Widen selected hunk to whole working file | `testStageAndUnstageOneHunkPreserveOtherHunksAndWorktree` | `mutation-selected-scope.log` |
| Reverse stage/unstage direction | Same round-trip test | `mutation-reverse-direction.log` |
| Remove real index validation | `testConcurrentUnrelatedStagingIsNeverOverwritten` | `mutation-index-validation.log` |
| Remove validation immediately before rename | `testPublicationRevalidatesAfterWritingLockAndLeavesReplacementIndex` | `mutation-publication-validation.log` |
| Permit replacement-object reads | `testReplacementBlobCannotStageUnreviewedContent` | `mutation-replacement-object-guard.log` |

The mutation runner and summary are `mutate-hunks.py` and `evidence/mutations-summary.log` under the build root.

Reproduction: use `swift test --package-path packages/bello-views --scratch-path "$PI_BUILD_ROOT/views" --jobs 2` for the package. For native classes use `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-git-hunks scripts/test-macos.sh -only-testing:PiAppTests/<Class>`; run `GitDiffTableTests` and `GitPanelNarrowParityTests` separately with `-parallel-testing-enabled NO`. Gallery output is enabled with `PI_APP_HUNK_GALLERY` and `TEST_RUNNER_PI_APP_HUNK_GALLERY` set to the same output directory. The single full native run uses four workers and the skip arguments emitted by `python3 scripts/test-lanes.py parallel`; its exact argv is saved in `evidence/native-parallel-command.txt`.

## Gallery and review

Images: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-hunks/gallery/`.
All 16 generated images were visually inspected. The scenes cover 1180×760, 920×600 and a 420×600 detached diff pane, light/dark, unified/split, working and staged hunk controls, partial staging, final-hunk review offer and binary whole-file fallback. Buttons and fallback text fit; narrow split text retains the existing truncation/Wrap behavior.

Prefixes (each has `-light.png` and `-dark.png`): `hunks-wide`, `hunks-920`, `hunks-staged-offer`, `hunks-index`, `hunks-final-offer`, `hunks-binary`, `hunks-narrow-unified`, `hunks-narrow-split`.

Read-only safety/UI reviews found and verified fixes for filter/replacement-object execution risks, byte/lock validation, selection ownership, retained snapshots, final-hunk offers and keyboard focus/navigation. The initial reviewer is clean. Required explicit `gpt-6.1-sol` / `xhigh` whole-change review: **no findings**. Advice: complete the remaining gates and complement direct keyboard-method checks with native event/focus smoke. A pointer hit-test plus real Pi accessibility press test was added; keyboard scope/navigation is asserted through the actual diff key-equivalent method.

## Handoff

The hunk-specific safety gate passes: 20 package checks, 9 native behavioral checks, all five real-guard mutations caught, and a clean read-only review. The 27 existing serial UI checks and all 16 reviewed gallery images pass too. The broader package/native run failures above remain explicit release-validation limitations despite their passing follow-ups.

Ready for the lead to integrate from `dev/a127-git-hunks`. The lead still owns integration/release validation and resolution of the intermittent broader-gate failures; stream 1 owns the single commit-default constant while preserving today's Checked files behavior. This stream does not merge into or push `dev/next`, package a release, or publish a website. Individual-line staging and broader whole-file/safety/history/file-view work remain outside stream 2.
