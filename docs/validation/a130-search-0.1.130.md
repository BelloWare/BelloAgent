# Sidebar search scopes — 0.1.130

Owner request: default to **Titles & details**, with a temporary **Full chats**
choice. Worktree `wt-a130-search`, branch `dev/a130-search`, build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-search`.

## Decisions

- Search scope belongs to the existing sidebar search controller. It is never
  persisted. Clearing the field resets it, including an already empty field
  after choosing Full chats while focused.
- Both scopes use the existing localized case-insensitive title comparison for
  displayed titles, sub-agent short titles/tasks, project and topic names,
  connection names, and the chat's model override or connection model fallback.
- Titles & details does not query message content, expose snippets, or request
  message reveals. Existing index maintenance continues on its original schedule.
- The pill uses PiKit.Tabs and reserves its vertical slot even while hidden,
  keeping the list's origin stable through focus, typing, clearing and switching.
- An empty search remains active while keyboard focus moves into the pill;
  leaving both controls hides it. PiKit's narrower tab padding and unconditional
  keyboard reachability are opt-in; existing callers retain their defaults.
- Generated journals and isolated test models only. No installed-app launches,
  real preferences/chats, Keychain, paid providers or live capture.

## Validation

Text logs and gallery images are kept under the build root's `evidence` folder.
Final results and exact commands are recorded below.

### Failing-first and regression checks

- Before production changes, `SidebarSearchScopeTests` ran 3 tests and failed
  all 3 (26 assertions): content-only matches/index answers in the default
  search, missing metadata matches, and the absent named pill.
  Log: `evidence/failing-first.log`.
- The initial implementation passed all 9 scope tests and all 9 existing
  `SidebarSearchSidebarTests`. Existing full-content fixtures now explicitly
  choose Full chats; none of their assertions were removed.
- Real-window checks found that editing-began does not report focus on an
  untouched empty field. Visibility now reads the actual field editor.
  Additional Tab checks caught AppKit's pre-layout key loop and an intermediate
  manually linked cycle. The final implementation lets AppKit recalculate the
  loop on scope visibility/geometry changes, and verifies entry, both tabs and
  exit. The AX client verifies the named group and selected states.
  Logs: `keyboard-navigation-failing.log`, `keyboard-key-loop-failing.log`,
  `keyboard-exit-failing.log`, `keyboard-chain-failing.log`, and final
  `keyboard.log`.
- One gallery setup run failed because its generated journal directory did
  not exist. The fixture now creates it (`gallery-fixture-failing.log`);
  the final gallery passes (`gallery.log`).

### Gallery review

All 16 PNGs in `evidence/gallery` were opened and visually inspected at their
native capture sizes. Matrix: `{topics,flat}-{details,full}-{300,200}-{light,dark}.png`.
Both tab labels fit without clipping at 200 points; selected capsules, text,
clear buttons and spacing read correctly in both themes. Titles & details has
no snippets; Full chats shows the active and archived content matches. Existing
narrow row/topic truncation remains intact. The keyboard test separately checks
the unchanged scroll origin through focus, typing, clearing and hiding.

The inherited gallery methods also emitted 100 sub-agent and 92 steering
captures. Every one was viewed in the 16 labeled contact sheets under
`evidence/review-sheets`; `manifest.txt` maps each image to its sheet. This was
an overview check of the changed sidebar chrome in those existing scenes;
the 16 scope images and 4 full-chat search/reveal images received individual
inspection. In total, all 212 generated gallery images were viewed.

### Adversarial self-review

Reviewed query cancellation before/after async index reads, cold/background
requeries, held answers, stale reveal ownership, cache invalidation on metadata
changes, family ancestry, archived groups, empty searches and keyboard escape
from the pill. Scope guards cover both typed and background queries; leaving
Full chats clears held/results state and cancels reveals. Metadata lookup is
cached per sidebar invalidation and shared by rows, topic visibility and
keyboard order. No persistent scope, helper/wire changes or new indexing work.

### Final native results

All final checks pass: **305 passed, 1 skipped, 0 failures** across the affected
run, serial classes, keyboard and galleries (excluding repeated scope runs).
The skip is the existing `PiKitParityTests.testHoverStates`: posting pointer
events requires Accessibility permission for the runner. No permission or real
preference was changed. The AX name/selection and keyboard tests pass.

`affected.log` — 219 passed, 0 skipped, 0 failures:

| Class | Passed |
| --- | ---: |
| ArchiveSwitchTests | 4 |
| PiKitControlTests | 39 |
| ProjectSidebarTests | 8 |
| SidebarAppearanceTests | 6 |
| SidebarBindingActionTests | 3 |
| SidebarDocumentRegressionTests | 10 |
| SidebarDropZoneTests | 6 |
| SidebarFigureGoldenTests | 2 |
| SidebarFlatTopicsTests | 30 |
| SidebarInteractionTests | 9 |
| SidebarListedOrderTests | 5 |
| SidebarMetricsLayoutTests | 10 |
| SidebarMultiSelectionTests | 4 |
| SidebarRecencyTests | 4 |
| SidebarRowDragTests | 4 |
| SidebarRowStatesTogetherTests | 1 |
| SidebarScalePerformanceTests | 4 |
| SidebarSearchIndexTests | 16 |
| SidebarSearchScopeTests | 9 |
| SidebarSearchSidebarTests | 9 |
| SidebarSideClickTests | 4 |
| SubagentDiscoveryTests | 15 |
| SubagentOrganizationTests | 13 |
| TopicSidebarPresentationTests | 4 |

Each serial class ran alone:

| Suite / log | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| SidebarSearchTypingTests | 2 | 0 | 0 |
| SidebarNativeBindingTests | 4 | 0 | 0 |
| SubagentReaderTests | 55 | 0 | 0 |
| PiKitParityTests | 20 | 1 | 0 |
| SidebarSearchKeyboardTests / keyboard.log | 1 | 0 | 0 |
| SidebarSearchGalleryTests / gallery.log | 1 | 0 | 0 |
| UIScreenshotTests / legacy-gallery.log | 3 | 0 | 0 |

The last class includes its inherited sub-agent and steering gallery tests.
The four existing full-chat search/reveal images in
`evidence/legacy-gallery/screenshots` were also opened individually; both themes
retain snippets and the clicked message highlight.

Debug typing measurements: 32,000 generated rows indexed in 6.11 s while typing;
maximum keystroke 29.7 ms, main-thread stall 47.0 ms. With 600 matching chats,
maximum keystroke 46.5 ms and main-thread stall 40.8 ms. Both existing performance
checks pass their original bounds.

### Mutations

- Removed the clear-to-default assignment in `setQuery`: the reset test failed
  with 8 assertions, covering clear button, Escape, delete-all and an already
  empty field. `mutation-reset.log`, exit 65.
- Removed the four Full chats guards before typed/background scheduling and
  before/after the index read: the no-index test failed with 3 assertions,
  including nonzero answered queries after indexing changed. `mutation-no-index.log`,
  exit 65.
- Restored the source byte-for-byte and reran the entire scope class:
  9 passed, 0 failures (`scopes-final.log`, exit 0), then the affected run above.

### Commands

Run from this worktree. Every command uses only the assigned build root; no
named result bundle was requested. Window, focus, parity and gallery runs held
`/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock`, acquired with `mkdir`
and released by an EXIT trap, including failed runs. The focused scope and
mutation tests do not activate a window.

```bash
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-search
xcodegen generate --quiet
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchScopeTests
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchScopeTests -only-testing:PiAppTests/SidebarSearchSidebarTests
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchScopeTests/testClearButtonEscapeAndDeleteAllResetTheScope
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchScopeTests/testDefaultSearchDoesNotAskForContentEvenWhenTheIndexChanges
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchScopeTests

scripts/test-macos.sh \
  -only-testing:PiAppTests/ArchiveSwitchTests \
  -only-testing:PiAppTests/PiKitControlTests \
  -only-testing:PiAppTests/ProjectSidebarTests \
  -only-testing:PiAppTests/SidebarAppearanceTests \
  -only-testing:PiAppTests/SidebarBindingActionTests \
  -only-testing:PiAppTests/SidebarDocumentRegressionTests \
  -only-testing:PiAppTests/SidebarDropZoneTests \
  -only-testing:PiAppTests/SidebarFigureGoldenTests \
  -only-testing:PiAppTests/SidebarFlatTopicsTests \
  -only-testing:PiAppTests/SidebarInteractionTests \
  -only-testing:PiAppTests/SidebarListedOrderTests \
  -only-testing:PiAppTests/SidebarMetricsLayoutTests \
  -only-testing:PiAppTests/SidebarMultiSelectionTests \
  -only-testing:PiAppTests/SidebarRecencyTests \
  -only-testing:PiAppTests/SidebarRowDragTests \
  -only-testing:PiAppTests/SidebarRowStatesTogetherTests \
  -only-testing:PiAppTests/SidebarScalePerformanceTests \
  -only-testing:PiAppTests/SidebarSearchIndexTests \
  -only-testing:PiAppTests/SidebarSearchScopeTests \
  -only-testing:PiAppTests/SidebarSearchSidebarTests \
  -only-testing:PiAppTests/SidebarSideClickTests \
  -only-testing:PiAppTests/SubagentDiscoveryTests \
  -only-testing:PiAppTests/SubagentOrganizationTests \
  -only-testing:PiAppTests/TopicSidebarPresentationTests

for cls in SidebarSearchTypingTests SidebarNativeBindingTests SubagentReaderTests PiKitParityTests; do
  scripts/test-macos.sh -only-testing:PiAppTests/$cls
done
scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchKeyboardTests
TEST_RUNNER_PI_APP_SEARCH_SCOPE_GALLERY="$PI_BUILD_ROOT/evidence/gallery" \
  scripts/test-macos.sh -only-testing:PiAppTests/SidebarSearchGalleryTests
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/evidence/legacy-gallery" \
TEST_RUNNER_PI_APP_UI_GALLERY_SEARCH_ONLY=1 \
  scripts/test-macos.sh -only-testing:PiAppTests/UIScreenshotTests
```

No helper source or wire behavior changed, so helper/wire/concurrent/acceptance
suites were not required for this app-only feature. The lead runs the merged
release gate. No unresolved feature issue or owner decision remains.
