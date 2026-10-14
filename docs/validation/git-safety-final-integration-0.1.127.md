# Git safety final integration — 0.1.127

Stream 1, `dev/a127-git-safety`, 2026-10-15. This records the final integration request after `bce97383`; the earlier [integration record](git-safety-integration-0.1.127.md) remains historical evidence.

## Integrated changes

- `258a64a3` merges History review commit `5846c7e6`. Rename-aware end-date filtering, matching-commit paging and quiet automatic refreshes retain the live controller/panel wiring. Both validation appendices were retained when resolving the documentation conflict.
- `2b8d0237` merges `origin/dev/next` at `efe431a3`, including file folders (`1aab3ddf`) and file continuity. Both release entries were retained; the generated Xcode project was regenerated with `xcodegen`.
- The actual file-tab Show File History action now calls `changes.cameFrom(tab, source: .file)`. Its return bar says “Opened from the file”; blame retains “Opened from its blame”. The existing return tab, logical reading position, selection and repository boundaries remain intact.
- Read-only review identified a remaining same-row navigation race: Return on an already-selected History row did not invalidate an older pending blame reveal. `chooseHistoryCommit` now advances the navigation generations for every explicit row choice, clears the pin/reveal and keeps the ordinary selection subject to list filters. Both row implementations use it. Exact-hash and blame navigation remain pinned.
- The staged commit default, hunk staging and flat sidebar behavior are preserved. No persisted commit-scope preference existed to migrate; the earlier default decision is unchanged by these merges.

## Failing-first and integration coverage

Logs live under `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/logs/`.

- `final-file-history-label-red.log`: the existing real tab-menu/Back test failed its new rendered-label assertion before the one-line fix: one test, one expected assertion failure. It also verifies repository tree, index blob and working bytes remain unchanged.
- `final-history-row-red.log`: three selected tests; the file-menu label and integrated automatic-refresh geometry passed, while the actual browser Return regression failed four assertions. The older blame incorrectly won and remained pinned after filtering.
- `final-row-guard-mutation.log`: removing the new row-choice generation increments from the real controller reproduced all four behavioral failures. The mutation runner restored the exact source in `finally`; all ten cases of the restored class passed before the full lane.
- The new controller-level geometry test holds an automatic History refresh before publication and checks unchanged document height, scroll position, loading state and repository bytes. It verifies that the imported state fix remains effective through the real panel/controller.
- `GitIntegratedHistoryTests` now has ten cases, also covering filter chips, live paging, exact-hash pins, pinned blame line visibility and hide/show continuity. `FileReviewStateTests` has twenty cases after the merged nested-repository regressions.

## Validation results

All work uses the stream's own build root. New/affected Git and file fixtures are generated in temporary directories, with fixture identity, signing disabled, no real remotes or credential helpers. The installed app, real preferences and Keychain were not used. The native test host remains isolated; broader existing tests include their own loopback fixtures. No named result bundle was requested; text logs and extracted JSON summaries are the evidence.

- Full `bello-views`, `final-package.log`: **268 executed, 265 passed, three opt-in skips, zero failures**, 421.1 seconds. This includes all seventeen History query regressions, file reading-position and folder tests. The run began before the final additive row-choice API; final-source controller regression results are recorded below.
- Affected parallel native run, `final-affected-parallel.log`: **207 executed, 205 passed, two opt-in skips, zero failures**, four workers. Covers Git, History, file history/continuity, file tabs, chat/reply links, TabHost/TabPane and accessibility. The two skips are the commit-browsing benchmark and opt-in diff capture.

Each serial class ran alone with `-parallel-testing-enabled NO`; logs are `final-serial-<Class>.log`. All **180 passed**, zero failures. Together with the parallel group, **387 affected native tests executed: 385 passed, two skipped, zero failures**. Per-test results are in `final-affected-summary.json`.

| Serial class | Passed |
| --- | ---: |
| ChangesTabFrameTests | 7 |
| FileFindTabTests | 16 |
| FileFolderTests | 19 |
| FileSyntaxTests | 11 |
| FileTextViewTests | 45 |
| GitDiffTableTests | 19 |
| GitHistoryGalleryTests | 1 |
| GitPanelNarrowParityTests | 8 |
| GitPanelTimingTests | 4 |
| GitRepositorySwitchTests | 17 |
| GitWorkingTreeWatcherTests | 16 |
| QuickOpenTests | 17 |

Final-source controller checks: `final-package-controller.log` passes **13 package History-wiring/reveal tests** after the row-choice API change. `final-history-restored.log` passes **all ten integrated History native tests** after restoring the exact mutated source. Neither run has failures or skips.

The **one full native parallel lane** used four workers and exclusions from `scripts/test-lanes.py parallel`: **2,456 executed, 2,418 passed, 37 skipped, one failed**, 548.3 seconds. `final-full-parallel.log` is the text record; `final-full-parallel-command.json`, `final-full-parallel-summary.json`, `final-full-parallel-tests.json` and `final-full-parallel-log-results.json` preserve the command, result and per-test details. All affected parallel cases passed or skipped as expected in that lane (**203 passed, four opt-in skips**; the two galleries were already captured in the affected run).

The only failure was `PiSheetWindowTests.testEveryWorkspaceSheetIsAWindowOfTheAppsOwn`: “Never every closed sheet's views to be let go of”, the final view-release wait after closing the workspace sheets. It took 39.1 seconds. No Git, History or file-review test failed.

The entire unchanged `PiSheetWindowTests` class was rerun alone with parallel testing disabled: **11 passed, zero failures or skips**, 22.8 seconds of test time (`final-isolated-PiSheetWindowTests.log` and its extracted summary). The failing case passed on that rerun. The timeout remains an unconfirmed full-lane view-release issue; no unrelated sheet implementation or timing threshold was changed.

The full lane was not repeated. Its failed gate remains recorded separately from the isolated rerun; a passing isolated rerun does not establish the timeout's cause.

## Gallery

Captures are under `/Users/admin/Library/Caches/BelloSwiftWork/build-git-safety/final-integration-gallery/`:

- `history/`: 36 actual Changes-tab captures — filtered, empty, loading, long reference, pinned blame and direct file history, each in light/dark at 1240×800, 920×600 and 310×600.
- `file-review/`: 24 captures — restored reader, durable recents, actual tab-menu History and Back, each in light/dark at 1240×800, 920×600 and 420×600. The gallery invokes the menu action and asserts the rendered source label.
- `history-module/`: 16 standalone History browser/detail captures — filtered, empty, loading and long reference in light/dark at 1240×800 and 920×600.

All **76 captures** were opened and inspected through scene contact sheets, with the 920×600 pinned-blame scene also inspected at full size. Filters/chips, long refs, loading/empty states, the pinned line, distinct source labels and the restored reader selection remain visible and readable at their tested sizes. The standalone gallery includes native window chrome; the integrated galleries capture only their fixture view trees.

## Review and remaining scope

The read-only integration review found the same-row race above; its follow-up review found no remaining actionable issue. It also checked rename/date pagination, immutable page ownership, quiet-refresh cancellation and direct-file source semantics. Automated keyboard/accessibility checks are not a manual VoiceOver session. Release packaging and merging into `dev/next` remain with the lead; this stream pushes only its own branch.
