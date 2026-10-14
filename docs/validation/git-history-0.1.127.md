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
