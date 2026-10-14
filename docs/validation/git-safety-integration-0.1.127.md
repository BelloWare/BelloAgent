# Git safety and History integration — 0.1.127

Branch: `dev/a127-git-safety`. Worktree: `wt-git-safety`. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety`. This follow-up implements the owner's staged-default decision and the lead's integration request; it is not a release gate.

## Changes and decisions

- Merged `origin/dev/next` (`d8aacff1`, including hunk staging merge `2da7acbf`) in `188a8c1a`, then merged History delivery `75af32af` in `b41d33e4`. Kept both release records and regenerated the Xcode project at each conflict. Hunk review wiring and the flat sidebar remain intact; no sidebar or folder-tree source was edited.
- `GitController.defaultCommitScope` is now `.stagedChanges`. Staged changes is the first scope tab, the commit button names that scope, and the empty-index hint offers staging files/hunks or explicitly choosing Checked files. Commit never changes scope or falls back to checked files. Checked files still commits whole working-tree content.
- There is **no persisted commit-scope preference** in the existing controller or per-repository storage. Nothing saved is overwritten. An explicit choice in an open controller survives refreshes, stage actions, and hide/show. A new or closed/reopened controller uses the new staged default, including the first launch after updating. No new preference storage was introduced.
- Check can read conflicts with an empty staged scope. This permits a read-only preflight request; commit actions still require content, and submission repeats the service guards.
- Adapted `git-history-wiring-0.1.127.patch` to the safety controller and hunk-aware panel. The actual History panel uses the shared history state: literal message/author filters, searchable refs, committed-date filters in UTC, removable chips, immutable-tip paging and keyboard navigation. Exact hash navigation and blame stay pinned outside filters. Exact-hash selection retires older pending blame navigation even when the chosen hash is unchanged. Detail dates now explicitly say committed/local time.
- A visibility transition refreshes panel inputs even when the repository's quiet refresh has no changed values. This prevents History controls and rows retaining their hidden state on re-show. The browser retains same-repository rows while hidden so its scroll document does not collapse; repository/suspension action guards remain in force.
- Blame line positioning waits until AppKit has laid out the diff rows at the current width. The integrated gallery caught cached targets being selected below the visible area at 310 points because the early reveal clamped against the old document height. Superseding states retire pending reveals, and a completed reveal does not override subsequent manual scrolling. The shared diff-table change is confined to this layout handoff.
- `ChangesTab.cameFrom(_:source:)` defaults to `.blame`. Direct file-history callers use `.file`, changing the return-bar note to “Opened from the file”; existing blame callers retain “Opened from its blame”. Both retain the same file tab.

## Stream 4 handoff

The file-continuity branch was not merged into this branch. In its direct Show File History path, replace the existing call with:

```swift
changes.cameFrom(tab, source: .file)
```

Blame navigation keeps `changes.cameFrom(tab)`. The new API and both labels are covered in `GitIntegratedHistoryTests` and the integrated gallery.

## Evidence

All added repositories are generated temporary fixtures, with fixture identities and signing disabled. No test contacts a remote, credential helper, real preference store or Keychain; the native script uses its isolated test host. No installed app launch, xctrace launch, named result bundle or force push was used. Logs live under the build root's `logs/` directory.

Failing first:

- `staged-default-red.log`: 3 new scope tests failed with 9 assertions against Checked files as the default, including actual committed/index/worktree bytes.
- `history-integration-red-2.log`: 2 native tests failed because the live panel still hosted the old list and direct file history still used the blame label.
- `history-same-hash-red.log`: 1 test, 3 assertions failed when an older blame reveal replaced a newer same-hash choice.
- `staged-conflict-check-red.log`: the empty-index conflict Check test failed; the two initial integrated History/label tests passed.
- `followup-hide-red-preflight-mutation.log`: the new actual-panel hide/show test failed before the visibility fix. The unchanged repository had finished reading, but the controls and rows never returned.
- `followup-scroll-red.log`: the 60-commit actual-panel regression failed before the row-retention fix: hiding/showing reset the scroll offset from `(0, 2437)` to `(0, 0)`.
- `followup-history-gallery-viewport.log`: the gallery's new actual-viewport assertion failed twice, at 310×600 in light and dark. The blamed line was selected but below the visible area. Both fresh-view focused variants passed, so the gallery sequence is the regression that exposed the layout ordering.

Mutation evidence:

- `followup-package-mutation.log`: reverted the actual default constant and removed the explicit navigation-generation advance. All 3 selected tests failed, with 11 assertions showing committed/index/worktree differences and stale reveal takeover. Exact source bytes were restored afterward.
- `followup-hide-red-preflight-mutation.log` also removes the real empty-index preflight exception; Check again fails to report the fixture's conflict. Both selected tests fail, with 2 assertions. The preflight guard was restored, and the visibility regression was then fixed.
- `followup-viewport-gallery-mutation.log`: put the actual reveal back before layout. The viewport assertion failed twice again (310×600, both themes); the source bytes were restored. The simpler warmed-target native case passed under this mutation (`followup-viewport-mutation.log`); the gallery's multi-size sequence is the effective regression.

Validation:

- `followup-package.log`: complete `bello-views` suite, **245 tests, 3 skipped, 0 failures**.
- `followup-package-restored.log`: restored-source safety, scope and History-wiring checks, **37 tests, 0 failures**.
- `followup-package-reveal.log`: final-source diff parser/prefix, reveal and History-wiring checks, **19 tests, 0 failures**.
- `followup-native-2.log`: 95 affected tests, 1 skipped, 2 test cases failed (5 assertions). Both failures were existing Checked-files-default assumptions: accessibility tab order/selection and the first-keystroke hint-height test. Those tests now exercise the new default and the explicit Checked files choice respectively. The five live History tests, 12 operation-safety tests, 9 hunk-review tests and 13 History-filter tests passed in this run.
- `followup-native-final.log`: **43 of 44 tests passed**. Accessibility and redraw expectations now pass; the first hide/show regression passes, as do all operation safety, shown-state, hunk-gallery and safety-gallery checks. The sole failed case was the newly written History gallery using the temporary directory's path alias instead of the controller's Git-resolved root for blame navigation (6 scene assertions). The gallery now passes the resolved identity, as the live navigation test already did.

- `followup-history-final.log`: **21 tests, 0 failures** (7 integrated History tests, 13 History-filter tests and the integrated gallery). Same-hash navigation, filters/chips, paging, pinned blame, both source labels, hide/show readiness and preserved scrolling are covered.
- `followup-viewport-green.log`: **9 tests, 0 failures** (8 integrated History tests and the gallery with actual viewport assertions). Broader blame checks then exposed a missing retry after the scrollbar changed width: `followup-viewport-final.log` fails two existing FileBlame tests. The final handoff coalesces a next-turn subtree layout, retires superseded requests, and leaves zero-size panes dormant until layout resumes.
- `followup-reveal-final.log`: **19 tests, 0 failures** (all 10 FileBlame tests, all 8 integrated History tests and the gallery). Targets beyond the parser limit, navigation back to the file, pinned line visibility, selection across layouts, cancellation and manual scrolling pass with the final deferred handoff.
- `followup-gallery-settled.log`: final integrated gallery, **1 test, 0 failures**, including line visibility and both wrapped navigation buttons. An immediate capture assertion previously caught the row during AppKit's height animation (`followup-heading-geometry.log`: final row rect 255 points, live row/heading still 224). The gallery now waits for the actual row view to reach the final height before capture; this required no additional production change.
- `followup-serial-GitPanelNarrowParityTests.log`: **8 tests, 0 failures**. The new browser's filter/list geometry has explicit containment and nonoverlap checks; unchanged toolbar/header/tab allocation still compares against the frozen reference.
- `followup-serial-ChangesTabFrameTests.log`: **7 tests, 0 failures**.
- `followup-serial-GitRepositorySwitchTests.log`: **17 tests, 0 failures**.
- `followup-serial-GitWorkingTreeWatcherTests.log`: **16 tests, 0 failures**. The four serial classes total **48 tests**, each run alone with parallel testing disabled.
- `followup-serial-GitDiffTableTests.log`: **19 tests, 0 failures**, also run alone, covering wrapped geometry, resize anchoring, selection/copy, keyboard scrolling and file navigation.
- `followup-latest-test-results.json` collects the latest result for each affected native test across these runs: **168 unique tests — 167 passed, 1 opt-in benchmark skipped, 0 remaining failures**. This is an aggregate of affected checks and reruns, not a single full native lane.

## Galleries inspected

All images are under `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/followup-gallery/`:

| Folder | Captures | Scenes and sizes |
| --- | ---: | --- |
| `safety/` | 48 | Conflict, staged amend, whitespace warning, staged Sign off and explicit Checked files; 1180×780, 920×600, 700×640, 310×600; light/dark; 8 actual Pi question sheets |
| `hunks/` | 16 | Working hunks, staged review offer, staged index, final hunk, binary fallback, narrow unified/split; light/dark |
| `history/` | 36 | Filtered, empty, loading, long ref, pinned blame and direct file history; 1240×800, 920×600, 310×600; light/dark |

All 100 captures were visually inspected through scene contact sheets, including full-size narrow blame inspection. Scope selection/button text, full conflict rows, Check feedback, Cancel-default sheets, filter chips, committed-date labels, ref truncation, both source labels and hunk actions are visible. The History gallery uses the controller's resolved repository identity and navigates after applying the captured window size; its blamed line must be inside the viewport.

Final read-only review found no remaining actionable safety issue after the same-hash, hide/show and post-layout reveal fixes.

## Limits

The native amend operation still has the previously documented external-Git race after its final reviewed-target check. This integration does not claim atomic history rewriting. The initial stream's one full native parallel lane and its failures remain recorded in `git-safety-0.1.127.md`; this follow-up runs affected classes and galleries, not another full-release gate. No agent-tool semantics, permission, capture, tool, vault or data boundaries changed.
