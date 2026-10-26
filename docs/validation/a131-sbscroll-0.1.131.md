# SIDEBAR-2: keep the top of the sidebar at the top — 0.1.131

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

## Fix

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

## Needs owner decision: selection that moves while reading farther down

Conservative choice: keep the existing first-visible-row/offset behavior
below the top. An unrelated update above it keeps the reader and a visible
selected row in place. Do not add separate selection tracking when the
selected chat itself moves elsewhere; the reading anchor can itself be the
selected row, in which case it stays anchored as before. At the top, showing
new activity takes precedence over following an older selection.

Options:

1. Keep the reading position (chosen, existing behavior).
2. Scroll just enough to retain a previously visible selected row when it
   moves outside the viewport.
3. Always follow the selected chat when its activity changes its position.

This work does not introduce a selection-following policy.
