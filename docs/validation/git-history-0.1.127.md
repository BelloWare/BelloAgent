# Git history — 0.1.127

Stream 3, `dev/a127-git-history`. Validation uses only generated local repositories and the isolated native test host. Build products, text logs and gallery images live under `/Users/admin/Library/Caches/BelloSwiftWork/build-git-history`.

## Implementation and integration

The new history service separates literal message/author/path filtering from exact object-hash navigation. Queries freeze branch tips into immutable commit IDs; cursors name that snapshot and count actual log results. Inclusive date filters and row dates use committed dates in UTC. A renamed file's next page walks an ID-only prefix before fetching that page's metadata, avoiding Git's `--follow --skip` rename loss. Metadata is read in batches of 50 even when preserving thousands of loaded rows.

`GitHistoryState` owns cancellation and publication identities. A retired refresh/page cannot publish results, errors or loading flags. `GitHistoryBrowser` supplies searchable refs, date and hash popovers, removable filters, virtual rows and keyboard/accessible selection. Detail reads continue through the existing controller and its large-diff gate and blame pin.

The plan assigns `GitController.swift`, `GitService.swift` and `GitPanel.swift` to stream 1. Those files are unchanged here. The concrete activation handoff is [`git-history-wiring-0.1.127.patch`](git-history-wiring-0.1.127.patch): controller delegation, view construction, exact-hash pinning and committed-date metadata for legacy blame/detail callers. Stream 1 must apply/adapt it and validate the integrated panel before shipping. Standalone native tests and gallery exercise the new modules through the same callback interface.

No Git writes, agent-tool changes, commit-default change, comparison UI or new patch cache are introduced. Existing 24-commit detail caching remains with the controller. Ref listing and all-branch snapshots are capped at 2,000 refs/tips with a visible error. GitService's existing subprocess/output bounds remain in effect; extreme ID walks or an individually oversized metadata page report an error rather than silently returning partial history.

## Evidence

Passing runs (text logs in `logs/` under the build root):

| Check | Result | Log |
| --- | --- | --- |
| Full `bello-views` package | 206 executed, 3 skipped, zero failures | `history-views-full.log` |
| `GitHistoryFilterTests` | 13 passed | `history-native-final.log` |
| Standalone `GitHistoryGalleryTests` | 1 passed; 16 captures | `history-gallery.log` |
| Serial `GitRepositorySwitchTests`, alone | 17 passed | `history-repository-switch.log` |
| Serial `GitWorkingTreeWatcherTests`, alone | 16 passed | `history-watcher.log` |
| Final native parallel lane, four workers, one run | 2,377 total: 2,342 passed, 35 skipped, zero failures | `history-native-parallel.log`, `history-native-parallel-summary.json` |
| Handoff package copy, `GitHistoryQueryTests` | 15 passed | `history-wiring-package.log` |
| Handoff package copy, `GitHistoryWiringTests` | 2 passed: close/reopen reset; exact hash pin and 40-file diff gate | `history-wiring-controller.log` |

The handoff's package/controller changes were applied only to `build-git-history/integration-preview`, compiled and tested there. Its AppKit panel wiring still requires stream 1's integrated build. `git apply --check` passes against this branch. Read-only review continued through fixes for cancellation, object/ref ambiguity, large preserving reads, repository ownership, paging selection/focus, close cleanup, ref arrival and error-row geometry. Final whole-change source review found no further actionable issues.

Failing-first evidence in `logs/`:

- `history-red.log`: old message search treated punctuation as regex and displayed author dates.
- `history-backend.log`: hash search bypassed author filtering; paged file history lost rename ancestry with Git's `--skip`.
- `history-large-red.log`: a 4,000-row preserving read exceeded the existing argument guard; `history-large-green.log` passes after bounded metadata batches.
- `history-native-red.log`: pending-page selection, ref-picker field-editor keys and accessible focus failed before their fixes. Early fixture runs also exposed `/var` versus `/private/var` path aliases and a controller refresh that could be superseded; fixtures now wait for the published repository snapshot and use Git's resolved root for history reads.
- `history-reset-red.log` → `history-reset-green.log`: closing releases metadata and retires a read already past IO.
- `history-native-review-red.log`: asynchronously arriving refs reset a keyboard choice; fixed by preserving the scope key.
- `history-native-focus-red.log`: 11/12 passed; the remaining test proved a completed page stole the filter field's focus. The final class run passes with the visible-list focus guard.
- `history-native-status-red.log`: a wrapping error overlapped its retry button at both 260 and 300 points; the final class run passes with separate regions and invalidated cached row height.

Three real production mutations were each rejected, then restored: removing the stale-query publication identity (`history-mutation-identity.log`); preventing cursor advancement (`history-mutation-cursor-offset.log`); accepting a cursor owned by another snapshot (`history-mutation-cursor-owner.log`). Each selected test failed behaviorally, not at compile time. The complete package run above passed after restoration.

Fixtures disable signing, hooks, credential helpers and fsmonitor. No remote is configured and no network operation is used. Repository invariants compare the HEAD tree, index bytes/index blobs and worktree bytes across reads.

Focused native runs use `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-git-history scripts/test-macos.sh -only-testing:PiAppTests/<Class>`. Serial classes run alone. The final native parallel lane uses the selectors from `python3 scripts/test-lanes.py parallel` with `-parallel-testing-enabled YES -parallel-testing-worker-count 4`; four workers limit contention on the shared machine. No named result bundle is requested. Package runs use the same stream's own SwiftPM scratch paths.

The final native lane completed in 602 seconds. Its counts come from the default Xcode result's summary exported as JSON; the text log also reports `TEST SUCCEEDED`. It includes the 13 new history UI tests and existing blame, rename, panel visibility, layout and redraw regressions. No second full native lane was run. Staged whitespace checks and the activation patch's application check both pass.

## Gallery

Standalone `GitHistoryGalleryTests` captures filtered, empty, loading and long-ref states in light/dark at 1240×800 and 920×600 (16 images). It does not inherit the chat screenshot fixture or start a gateway. The narrow history pane is 300 points. Every image was opened and visually inspected: chip removal remains reachable, refs truncate inside their rows, header content clears traffic lights and empty/loading text is unobstructed.

Images: `/Users/admin/Library/Caches/BelloSwiftWork/build-git-history/gallery/{filtered,empty,loading,long-ref}-{light,dark}-{1240x800,920x600}.png`; `manifest.txt` lists all 16. These scenes host the new browser beside the existing detail view; the detail date-label change in the handoff patch is not represented in these captures.

## Remaining integration work

- Stream 1 applies/adapts the handoff patch to its controller/panel changes; preserves file-history entry points and pinned blame navigation; repeats relevant controller/panel regressions on the merged implementation.
- Branch comparisons remain the next increment, per the agreed plan.

## Review follow-up after 75af32af

The owner requested two test-first corrections while stream 1 integrates the original commit. Changes stay in the history service/state and their tests; the controller, panel, handoff patch and shared release records are untouched.

- A Through date preceding a rename no longer hides the file's old path. Filtered file queries walk expanding prefixes containing only object IDs and committed timestamps, follow every rename in those prefixes, and then apply both date bounds. Review also found and fixtures confirmed that message/author predicates could hide the rename; these now run afterward in Git `--no-walk` batches of 1,000 IDs, preserving literal message-body and author-email matching. Predicate results are reused only within the current read, bounded by its existing output cap, so prefix expansion does not repeatedly inspect old IDs. Cursor offsets count matching commits. Rich metadata still loads only for the matching page in batches of 50; existing cancellation and subprocess/output bounds remain. The generated regression covers two later renames, excluded commits between matches, both date boundaries, multiple pages, combined filters with and without dates, and unchanged HEAD tree/index/worktree bytes. Existing long-subject and 4,000-row regressions now also exercise predicate batching.
- Automatic same-query, same-repository refreshes retain the visible reading until replacement data arrives. The private task blocks paging while the old cursor remains visible. The generated native regression holds a refresh at publication with the exhausted tail visible: the original implementation grew the document from 598 to 666 points and showed a loading row. The fixed implementation preserves geometry and scroll position. A package regression covers the non-exhausted cursor, blocked concurrent paging and resumed paging after refresh.

Failing-first evidence: `history-review-package-red.log` (both new package regressions fail) and `history-review-native-red.log` (the new native regression fails three assertions). Initial fixes pass those same two package cases and one native case in `history-review-package-green.log` and `history-review-native-green.log`.

The message/author combinations fail in `history-review-predicates-red.log` and `history-review-predicates-red-2.log`. Expanded coverage passes in `history-review-predicates-green-3.log`. Intermediate runs named `history-review-predicates-green.log` and `history-review-predicates-green-2.log` failed on a fixture expectation: its excluded commit's label contained “matches” and correctly matched a literal “Match” query without date bounds. The fixture now uses an unrelated label; production matching was retained.

Final production mutations were rejected behaviorally, with no compile failures, and restored in `finally`: applying predicates before following renames (seven assertion failures, `history-review-mutation-filters.log`); publishing loading during an automatic refresh (three, `history-review-mutation-quiet.log`); allowing paging while the private refresh task exists (two, `history-review-mutation-busy.log`). An earlier date-only mutation also failed (`history-review-mutation-dates.log`).

Final affected runs after the predicate batching optimization: `GitHistoryQueryTests` **17 passed**, zero failures (`history-review-package-optimized.log`, 75.5 s), and native `GitHistoryFilterTests` **14 passed**, zero failures (`history-review-native-optimized.log`). Both classes also passed before that optimization (`history-review-package-final.log`, `history-review-native-final.log`). The final read-only review found no remaining actionable correctness, performance, cancellation or lifecycle findings. Whitespace checks pass.

The broader package/native/gallery evidence above belongs to 75af32af. This follow-up reruns only the affected history tests, as requested.
