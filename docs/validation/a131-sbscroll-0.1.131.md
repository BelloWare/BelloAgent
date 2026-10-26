# SIDEBAR-2: preserve the sidebar's top and visible selection — 0.1.131

Owner, 2026-10-26:

> when the left sidebar just keeps scrolling down, I think whenever there's an update happened, which feels bad because I was at the top, but then whenever a chat got updated, it seems like the chat will be hidden or something like that will be happening. So I need you to also identify that and fix it.

Worktree `wt-a131-sbscroll`, branch `dev/a131-sbscroll`, from `origin/dev/next`
`1ef3a524`. Build root (`$BUILD` below):
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-sbscroll`.
Generated chats/journals, memory vault and the isolated
`com.belloware.PiAppTests.Host` only. No installed app, real preferences/chats,
Keychain, capture or provider requests.

## Cause and scope

`SidebarListDocument.readingAnchor()` always takes the first entry extending
below the clip's top, even when the clip is at zero. After an insertion or
activity reorder above that entry, `layoutEntries` moves the clip down to
keep the old entry in place. Repeating this follows the old entry farther
down and leaves the newly active chats above the viewport.

The same document serves Flat (with or without project chips), grouped
projects/topics, and both sidebar search scopes. A project header at zero
already anchors its own group's activity reorders at zero; inserting an
earlier group exposes the defect in grouped mode too.

Other paths checked:

- `WorkspaceSidebarView.revealOpenChats` unfolds ancestors when the selection
  changes; it does not scroll the clip on activity. Selected rows share the
  same document anchoring as other rows.
- Project chips occupy the search scope's reserved header slot. Choosing a
  chip explicitly scrolls to the top after updating the list; ordinary
  activity does not take that path.
- `entryChangedHeight` and materialization's stale-height correction call
  the same layout/anchor logic. Status and metrics can change row height;
  a brief is shown in a separate hover card, not added to the row's height.
- Pointer/menu/drag holds delay activity ordering; releasing the last hold
  applies the pending order through the same document update.
- `scrollCorrection` rebases kept, newly mounted and exiting views' old
  positions into the new clip coordinates before their animations start.
  That correction must remain for readers below the top.

## Round 1 fix

`ReadingAnchor` distinguishes `.top` from `.entry(id:offset:)`. A clip at or
within **1 point** below its top (`-scroll.contentInsets.top`) takes `.top`;
layout restores that top explicitly, including when the first entry changes
or the list was empty. Farther down, the same first-visible entry and offset
are restored, constrained to the document and its content insets.

The production change stays in the document's anchor capture/restoration.
`scrollCorrection` still rebases the old frames after layout, so kept,
remounted and departing rows start from their old positions on screen.

## Reproduction and focused checks

The new `SidebarScrollPositionTests` ran **before** the production edit.
`logs/red.log`: **7 failed tests, 48 assertions; 3 passed; 1 gallery skipped**.
The original source compiled without test-fixture corrections. Both animated
and nonanimated Flat lists, with and without chips, drifted on each activity
update; the selected row moving to the top was hidden too. Group insertion,
pointer-hold release, search and inset/tolerance regressions also failed.
Height changes and scrolled-down reading/selection already passed.

| Scenario | Before | With fix (`logs/focused.log`) |
| --- | --- | --- |
| Three activity reorders at the top of Flat (each animation/chip variant) | clip 72 → 144 → 216 pt; newest chat hidden | 0 → 0 → 0 pt; newest chat visible |
| Earlier project and topic inserted | clip 122 pt; new group hidden | 0 pt; new group visible |
| New full-text search hit above existing results | clip 92 pt; hit hidden | 0 pt; hit visible |
| Reader scrolled down, activity above the reading row | reading row and visible selection unchanged | unchanged, including animation origins |

`SidebarScrollPositionTests` exercises the real `WorkspaceSidebarView` /
`SidebarListDocument` inside an `NSScrollView` in an offscreen `NSWindow`.
Its boundary cases start 0, 0.5, 1 and 1.5 points below the top, both with zero
inset and a 12-point top inset. The 1.5-point reader keeps the old row/offset.
The metrics-height test goes through the row's `entryChangedHeight` callback.
Search tests use generated journals and the real asynchronous search index.
These regressions never show the application window or touch a real account.

First green run, `logs/focused.log`: **105 passed, 0 failed, 1 opt-in gallery
skipped**. Exact command (from the worktree, with `PI_BUILD_ROOT=$BUILD`):

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarScrollPositionTests \
  -only-testing:PiAppTests/SidebarDocumentRegressionTests \
  -only-testing:PiAppTests/SidebarProjectFilterTests \
  -only-testing:PiAppTests/SidebarFlatTopicsTests \
  -only-testing:PiAppTests/SessionOrderingTests \
  -only-testing:PiAppTests/SidebarOrderHoldViewTests \
  -only-testing:PiAppTests/SidebarMultiSelectionTests \
  -only-testing:PiAppTests/SidebarSearchSidebarTests \
  -only-testing:PiAppTests/SidebarSearchScopeTests
```

The red run uses the same command with only
`-only-testing:PiAppTests/SidebarScrollPositionTests`.

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| SidebarScrollPositionTests | 10 | 0 | 1 |
| SidebarDocumentRegressionTests | 10 | 0 | 0 |
| SidebarProjectFilterTests | 21 | 0 | 0 |
| SidebarFlatTopicsTests | 30 | 0 | 0 |
| SessionOrderingTests | 5 | 0 | 0 |
| SidebarOrderHoldViewTests | 3 | 0 | 0 |
| SidebarMultiSelectionTests | 4 | 0 | 0 |
| SidebarSearchSidebarTests | 10 | 0 | 0 |
| SidebarSearchScopeTests | 12 | 0 | 0 |

The first build waited through IMG-1's `perf` lock, then STREAM-1's `perf`
lock (13:42–13:50 local). It began at 13:50 after the quiet window ended.
Every later heavy run checks the lock again; gallery/focus runs take it.

## Mutation, restoration and gallery

`logs/mutation.log`: remove only the early `.top` return from
`readingAnchor()`, then run `SidebarScrollPositionTests` with the red command.
**7 tests fail with the same 48 assertions; 3 pass; the gallery skips.**
The original 72 → 144 → 216 pt drift returns. Restore the fixed source in a
`finally` block and compare it byte for byte with the saved fixed file (`cmp`
also passed). The rebuilt, restored source passes all **11** tests with its
gallery enabled (`logs/restored-gallery.log`); no skips.

Each following command ran alone under the shared full-lane lock, releasing
it after the run, with `PI_BUILD_ROOT=$BUILD`:

```sh
TEST_RUNNER_PI_APP_SIDEBAR_SCROLL_GALLERY="$BUILD/gallery-scroll" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarScrollPositionTests
TEST_RUNNER_PI_APP_PROJECT_FILTER_GALLERY="$BUILD/gallery-filter" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarProjectFilterGalleryTests
TEST_RUNNER_PI_APP_SIDEBAR_SHOT_ROOT="$BUILD/gallery-sidebar" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarAppearanceTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarListedOrderTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarDropZoneTests
```

| Class | Passed | Failed / skipped | Log |
| --- | ---: | ---: | --- |
| SidebarScrollPositionTests (restored, gallery enabled) | 11 | 0 / 0 | restored-gallery.log |
| SidebarProjectFilterGalleryTests | 1 | 0 / 0 | gallery-filter.log |
| SidebarAppearanceTests | 6 | 0 / 0 | appearance.log |
| SidebarListedOrderTests | 5 | 0 / 0 | listed-order.log |
| SidebarDropZoneTests | 6 | 0 / 0 | drop-zone.log |

Across the final source, **124 distinct test methods in 13 classes passed**.
The one opt-in skip in the first focused run was subsequently run and passed.
No unrelated test failures. No full native/helper/wire suite or performance
run: this changes sidebar positioning, and the numbers above are geometry,
not timing claims.

All **38 PNGs** were regenerated and visually inspected, using contact sheets
in `$BUILD/review`:

- `gallery-scroll/updated-{flat,chips,groups}-{200,300}-{light,dark}.png`
  (12): the selected updated chat is the first chat and fully visible at the
  top in every mode, width and appearance. Group headers remain visible.
- `gallery-filter/project-filter-*.png` (14): All, chosen project, overflow
  choice and search. The pinned first chat stays visible in All; the chip
  row and search scope fit both widths.
- `gallery-sidebar/sidebar-*.png` (12): narrow/wide light/dark grouped
  lists, metrics at six widths, and narrow/wide headers. Selection, unread
  and running states fit; no row content overflows the sidebar.

Gallery, focus and pasteboard classes each held the full-lane lock. Only the
isolated test host's windows were shown by the existing appearance/order
tests. No test-host clone directories were created (`-parallel-testing-enabled
NO` throughout).

## Round 2: owner decision — keep selected chat visible

The Astra and lead reviews of `5dc43d45` found no regressions. Round 1 kept
the existing reading-position policy and offered three choices: keep that
policy, minimally follow a previously visible selection, or always follow
selection. On **2026-10-26**, the owner chose **"Keep selected chat visible"**:

- Below the top, remember the primary selection only if its row intersects
  the old viewport, even partly. Bulk marks are not primary selection.
- Restore the normal reading anchor first. If that same selected row has
  become completely hidden above or below the viewport, scroll only to the
  nearer edge. Rows taller than the viewport use the edge requiring the
  smaller correction. A selection still partly showing causes no correction.
- A selection already off screen is not followed. A primary-selection change
  does not follow the old selection. A removed reading row does not prevent
  a surviving visible selection from being kept.
- The top still wins, and an activity reorder held by the pointer does not
  move anything until the hold ends.

The entry reading anchor now also carries the previously visible selected
entry ID. Its restoration verifies the row is still selected before applying
the edge correction. Both chat and side entry selection states are supported;
the existing focused-chat state identifies the primary row. The final scroll
is applied before `update` computes `scrollCorrection`, preserving kept,
remounted and departing animation origins. Direct height relayouts share the
same anchor capture/restoration.

### Failing first and mutation

`logs/r2-red.log`, production still at `5dc43d45`: **18 tests executed,
6 failed / 58 assertions, 11 passed, 1 gallery skipped**. The seven new tests
cover a selection moving above and below, previously offscreen selection,
partly visible selection, bulk marks, pointer hold/top precedence, and
remounted/departing animations. All reorder cases exercise animated and
nonanimated updates; the above/below cases cover Flat with chips and grouped
lists. The offscreen guard already passes before the change.

| Scenario | Round 1 clip origin | Round 2 clip origin / required edge |
| --- | ---: | ---: |
| Visible selection moves above, Flat | 945 pt (selection hidden at 0) | 0 pt |
| Visible selection moves above, grouped | 729 pt (selection hidden at 31) | 31 pt |
| Visible selection moves below, Flat | 873 pt (selection ends at 2877) | 2609 pt, row bottom at viewport bottom |
| Visible selection moves below, grouped | 676 pt (selection ends at 2148) | 1880 pt, row bottom at viewport bottom |

`logs/r2-focused.log`: **112 passed, 0 failed, 1 opt-in skip**, the same
nine-class command as round 1; `SidebarScrollPositionTests` now has 18 tests.
Additional guards then cover changing the primary selection and deleting the
reading row, plus a new selection-following gallery.

`logs/r2-mutation.log`: remove only the selection edge-correction block (keep
round 1's top rule). **21 executed, 7 failed / 61 assertions, 12 passed,
2 galleries skipped**. The same six failures recur and the removed-reading-row
case fails too. The original fixed source is restored in `finally` and checked
byte for byte against `$BUILD/SidebarListDocument.r2-fixed.swift`.

### Restored checks and gallery before the merge

The restored source passes all **21** scroll-position tests with both galleries
enabled (`logs/r2-restored-gallery.log`). The other four serial/gallery classes
run individually again, under the shared lock. Combined with the focused run,
**134 distinct tests in 13 classes pass**, with no failures or remaining skips:

| Class | Passed | Log under `$BUILD/logs` |
| --- | ---: | --- |
| SidebarScrollPositionTests | 21 | r2-restored-gallery.log |
| SidebarDocumentRegressionTests | 10 | r2-focused.log |
| SidebarProjectFilterTests | 21 | r2-focused.log |
| SidebarFlatTopicsTests | 30 | r2-focused.log |
| SessionOrderingTests | 5 | r2-focused.log |
| SidebarOrderHoldViewTests | 3 | r2-focused.log |
| SidebarMultiSelectionTests | 4 | r2-focused.log |
| SidebarSearchSidebarTests | 10 | r2-focused.log |
| SidebarSearchScopeTests | 12 | r2-focused.log |
| SidebarProjectFilterGalleryTests | 1 | r2-gallery-filter.log |
| SidebarAppearanceTests | 6 | r2-appearance.log |
| SidebarListedOrderTests | 5 | r2-listed-order.log |
| SidebarDropZoneTests | 6 | r2-drop-zone.log |

Commands are the same nine-class and five individual commands recorded for
round 1, with gallery destinations `$BUILD/r2-gallery-scroll`,
`$BUILD/r2-gallery-filter` and `$BUILD/r2-gallery-sidebar`. Red and mutation
each run only `SidebarScrollPositionTests`, with no gallery environment variable.
All use `-parallel-testing-enabled NO` and the assigned build root; every heavy
run checks for a perf/soak quiet window, and each gallery/focus run holds the
full-lane lock. There are no unrelated test failures.

All **62 PNGs** were regenerated and visually inspected in light/dark and
200/300-point sidebar widths, using five contact sheets in `$BUILD/r2-review`
and the full-size bottom-edge/chips/light scene:

- `r2-gallery-scroll`: the previous 12 top/activity scenes, plus 24
  `selected-{top,bottom}-{flat,chips,groups}-{200,300}-{light,dark}.png` scenes.
  The selected chat is fully visible at the correct edge; chips and search
  controls remain intact. A grouped reader following a selection upward stops
  at the chat's top (31 pt), while the at-top scene keeps its group header too.
- `r2-gallery-filter`: 14 project-filter scenes, unchanged layout and selection.
- `r2-gallery-sidebar`: 12 appearance/header/metrics scenes, no overflow or
  state-marker regressions.

The owner's decision is implemented; no product choice remains unresolved.

### Merge and final validation

Round 2 implementation: **`b379855d`**. After its pre-merge checks,
`git fetch origin dev/next` found **`be81ac4f`**, which contains the requested
`c03168e0` plus STREAM-1's bounded speculative opening retries. Merged that
tip into `dev/a131-sbscroll` as **`1961c8e7`**, without rewriting either
history. The merge changed neither `SidebarListDocument.swift` nor
`SidebarScrollPositionTests.swift`. Removed the duplicate pending SIDEBAR-2
release entry and retained the checked entry and owner decision. Regenerating
the project with `xcodegen generate --quiet` made no further changes.

On `1961c8e7`, the same nine-class focused command passes **114 tests**, with
the two opt-in galleries skipped (`logs/r2-merged-focused.log`: 116 executed,
zero failures). The following individual commands then pass every gallery
and serial class, each under the shared full-lane lock:

```sh
TEST_RUNNER_PI_APP_SIDEBAR_SCROLL_GALLERY="$BUILD/r2-merged-gallery-scroll" \
  PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarScrollPositionTests
TEST_RUNNER_PI_APP_PROJECT_FILTER_GALLERY="$BUILD/r2-merged-gallery-filter" \
  PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarProjectFilterGalleryTests
TEST_RUNNER_PI_APP_SIDEBAR_SHOT_ROOT="$BUILD/r2-merged-gallery-sidebar" \
  PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarAppearanceTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarListedOrderTests
PI_BUILD_ROOT="$BUILD" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SidebarDropZoneTests
```

| Class on the merged tree | Passed | Log under `$BUILD/logs` |
| --- | ---: | --- |
| SidebarScrollPositionTests | 21 | r2-merged-restored-gallery.log |
| SidebarDocumentRegressionTests | 10 | r2-merged-focused.log |
| SidebarProjectFilterTests | 21 | r2-merged-focused.log |
| SidebarFlatTopicsTests | 30 | r2-merged-focused.log |
| SessionOrderingTests | 5 | r2-merged-focused.log |
| SidebarOrderHoldViewTests | 3 | r2-merged-focused.log |
| SidebarMultiSelectionTests | 4 | r2-merged-focused.log |
| SidebarSearchSidebarTests | 10 | r2-merged-focused.log |
| SidebarSearchScopeTests | 12 | r2-merged-focused.log |
| SidebarProjectFilterGalleryTests | 1 | r2-merged-gallery-filter.log |
| SidebarAppearanceTests | 6 | r2-merged-appearance.log |
| SidebarListedOrderTests | 5 | r2-merged-listed-order.log |
| SidebarDropZoneTests | 6 | r2-merged-drop-zone.log |

**134 distinct methods in 13 classes pass again**, zero failures and no
remaining skips. The final restored runs also retain the round-1 zero-drift
behavior and the round-2 edge positions in the table above. No broader native,
helper or performance suites were run.

The merged gallery runs regenerate all **62 PNGs**. Comparing dimensions and
decoded RGBA pixels against the inspected pre-merge captures finds **zero
differences**: scroll 36/36, filter 14/14, sidebar 12/12
(`logs/r2-merged-pixels.log`). The light/dark/narrow inspection therefore holds
for the merged tree too. All lock ownership is released after each run; no
test-host clones were created. The final validation-record commit changes
documentation only.
