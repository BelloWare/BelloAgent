# DRAW-1: transcript text drawing — 0.1.131

Workstream `dev/a131-blanktext`, based on `47a80fc1`. Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-blanktext` (`$B` below);
text logs are in `$B/evidence`. macOS 14.8 (23J21), arm64, Xcode 16.1 (16B40).

Generated fixtures and the isolated `com.belloware.PiAppTests.Host` only. No
installed app, real chats/preferences, credentials, Keychain, live capture or
provider calls. All window captures contain the test process's own windows.
Focus-dependent checks and galleries hold the shared full-lane lock, released
also after expected failures. Builds wait while a perf/soak owner holds it.
Only this workstream's branch is committed/pushed; no release or upstream merge.

## Reproduction and cause

Built **both** pre-PERF-1 `ee41c072` (a temporary detached worktree, with only
the new test and generated project added) and starting revision `47a80fc1`,
serially into the same build root. Ran the identical pixel regression and
`UIScreenshotTests/testRenderSubagentGallery` on each. The latter is the test
in `SubagentGalleryTests.swift`: there is no test class named
`SubagentGalleryTests`, and selecting that name would execute zero tests.

| Product | Tests | Result | Sub-agent gallery |
| --- | --- | --- | --- |
| `ee41c072` | 2 | 2 passed | 100 PNGs, task and reply present |
| `47a80fc1` | 2 | pixel test failed (6 assertions); gallery test passed | 100 PNGs, blank prose captured |
| Current product, only PERF-1's display guard disabled | 1 | passed | 6 focused captures, prose present |

Logs: `before.log`, `current.log`, `trace.log`, `guard-off.log`. Captures:
`gallery-before`, `gallery-current`, and corresponding `*-focused` folders;
`gallery-trace` and `gallery-guard-off`. The pixel regression found **zero**
text-colored pixels in both prose areas at **700, 920 and 1240 points in dark
mode**, deterministically on both unfixed runs. Light mode passed. Pre-PERF-1
and the guard-disabled control draw 8,780–8,788 task pixels and 20,325–20,344
reply pixels in dark mode. The reported 920-point exception did not occur here.

**Exact cause:** a cached height does not imply that glyphs remain laid out.
When revisiting a measured width, `measure(width:)` returns its cached size;
placing the text container at that width invalidates its old layout. PERF-1's
`setNeedsDisplay(_:avoidAdditionalLayout:)` suppresses eager layout while a
text view is joining/being placed. AppKit can then reach `draw(_:)` in its
avoid-layout display mode with no laid-out glyphs. Contrary to the old comment,
`super.draw` does **not** necessarily lay them out. The visible-glyph lookup
that already followed `super.draw` lays them out, but too late: no later redraw
is requested, leaving a correctly sized, blank row.

Temporary tracing of `MarkdownTextView.draw` and
`MarkdownTextLayoutManager.drawGlyphs` established this, without querying a
layout-producing API before the failing draw (`trace.log`, lines 74–81):

```text
The tokenizer: before super, first unlaid glyph = 0
The tokenizer: after super, first unlaid glyph = 0
Task:          before super, first unlaid glyph = 0
Task:          after super, first unlaid glyph = 0
(no drawGlyphs call for either)
after the existing post-draw lookup: first unlaid = 210 / 94; ink = 0 / 0
```

Disabling only the guard lets `super.draw` lay out and draw glyph ranges
`{0, 210}` / `{0, 94}` and the same test passes (`guard-off.log`). All temporary
tracing and the control switch were removed from the final source.

## Change

Move the **existing** visible-glyph/character-range lookup before `super.draw`.
Resolve file links afterward as before. Keep PERF-1's join guard, row-width
preparation, measurement cache and layout counters unchanged. There is no new
whole-container layout or second glyph-range lookup; the existing visible work
happens in time to draw. This covers both delegated tasks and ordinary replies,
including cached-width and appearance changes.

`NativeMarkdownDrawingTests.testPausedSubagentTextIsDrawnAtEveryWidthAndAppearance`
uses the real paused-child scene, visiting parent states between child views,
then checks actual window-server pixels inside both text views. It asserts
both views are visible and each has over 100 text-colored pixels. It runs by
default, uses normal transcript mode explicitly, closes its generated workspace,
and removes temporary screenshots unless an evidence destination was supplied.
Stored text, row height, and a layout queried after drawing cannot make it pass.

## Focused validation and mutation

`affected.log`: **27 executed, 3 skipped, 0 failed** (24 passed):

| Class | Executed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `NativeMarkdownDrawingTests` | 1 | 0 | 0 |
| `NativeMarkdownSizingTests` | 6 | 0 | 0 |
| `SessionCardSwitchTests` | 3 | 0 | 0 |
| `MarkdownTextSurfaceTests` | 9 | 3 | 0 |
| `NativeMarkdownSurfaceStreamingTests` | 4 | 0 | 0 |
| `NativeMarkdownViewportTests` | 4 | 0 | 0 |

The three skips are the existing opt-in Markdown snapshot/benchmark tests.
The PERF-1 assertions are unchanged: **0** full layouts on joining; **1** at
the measured width; **1 per newly mounted reply** at its column width when
opening/switching chats, borrowing cached heights, and rebuilding released rows.
No Release timing claim is made; the retained layout counts are the performance
contract tested here. No helper tests or full native lanes were run.

**Mutation:** restore the original draw order (lookup after `super.draw`),
rebuild and run the pixel regression alone. `mutation.log`: **1 executed,
1 failed, 6 assertions**, all dark task/reply captures again have **0** ink
pixels. Restored the fix and rebuilt it for the final gallery/pixel run.
With the fix, dark task pixels are **8,780–8,788** and reply pixels
**20,325–20,344**, exactly the pre-PERF-1 counts at the corresponding widths.
Light counts also match the baseline (6,688–6,741 task; 15,320–15,385 reply).

## Complete gallery comparison

`gallery.log`: **5 executed, 0 skipped, 0 failed**, under the shared lock:

- `NativeMarkdownDrawingTests`: 1/1 (restored fix, all six captures pass).
- `SessionPanelGalleryTests`: 1/1, 22 captures.
- Complete `UIScreenshotTests`: 3/3 — main gallery 238 captures, sub-agent
  gallery 100, steering gallery 92. No gallery scene-filter variables were set.

The final output contains 430 release-gallery window captures plus the
`retry-budget.png` source asset. Every one of the 423 supplied baseline PNGs
was pixel-compared: **415 same-size differences, 1 one-point capture-height
variance, 7 exact matches, 0 missing**. Eight new SIDEBAR-1 filter/overflow
scenes account for the additional files.

I inspected all 430 gallery captures and all 22 session-panel captures, plus
paired outliers and every region flagged by the text-pixel diagnostic. The
complete per-image list, raw changed pixel counts and reasons are in the
[gallery comparison](a131-blanktext-gallery-0.1.131.md). Expected differences
include generated fixture paths/IDs/ports and their wrapping, runtime metrics
and dates, native raster/caret/spinner phases, and the approved sidebar chips.
No additional blank/missing rendered text was found. The exact source of the
one-point native screen-clamping/capture-height variation was not investigated
beyond confirming that all report content remains visible; it is documented
per-image and does not change this fix.

## Draw-time reading callbacks

`reading-callbacks.log`: **13 executed, 0 skipped, 0 failed** —
`StableReadingTests` 6/6 and `MarkdownSourceReconciliationTests` 7/7. These are
the two suites that install the existing `didDrawPreparedContent` callback
whose glyph preparation now happens before drawing. The run held the lane
lock, after waiting for the other workstream's soak to finish.

Final focused totals: **40 executed, 3 optional skips, 0 failures** (37 passed),
plus the **5/5** restored pixel/gallery run above. Expected failing-first and
mutation results are recorded separately. No unrelated test failed. The
temporary pre-PERF-1 checkout and old automatic result bundles were removed;
no clone directories remain. The final source matches the file used for the
passing affected tests, gallery, and reading callbacks; existing PERF-1 tests
are unchanged. `xcodegen generate --quiet` and `git diff --check` pass.

## Commands

All builds/tests use this workstream's `PI_BUILD_ROOT`. The temporary pre-PERF-1
checkout was `/Users/admin/Library/Caches/BelloSwiftWork/wt-a131-blanktext-before`.
The initial baseline attempt had a compile-only diagnostic spelling error
(`firstUnlaidGlyphIndex` needs `()`); it executed no tests. `before-compile.log`
records that error, corrected before collecting the results above.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-blanktext
B=$PI_BUILD_ROOT
# From the pre-PERF-1 checkout, after copying in the identical new test:
TEST_RUNNER_PI_MARKDOWN_DRAWING_GALLERY="$B/gallery-before-focused" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$B/gallery-before" \
  scripts/test-macos.sh -jobs 4 -parallel-testing-enabled NO \
  -only-testing:PiAppTests/NativeMarkdownDrawingTests \
  -only-testing:PiAppTests/UIScreenshotTests/testRenderSubagentGallery

# Current checkout. Build separately; each window run takes the lane lock.
python3 scripts/build-bundle.py
xcodegen generate --quiet
X=(-project PiApp.xcodeproj -scheme PiApp \
   -destination 'platform=macOS,arch=arm64' -derivedDataPath "$B/native-tests" \
   CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)
xcodebuild build-for-testing "${X[@]}" -jobs 4 COMPILER_INDEX_STORE_ENABLE=NO
TEST_RUNNER_PI_MARKDOWN_DRAWING_GALLERY="$B/gallery-current-focused" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$B/gallery-current" \
  xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/NativeMarkdownDrawingTests \
  -only-testing:PiAppTests/UIScreenshotTests/testRenderSubagentGallery

# The temporary tracing/control build used the same build-for-testing command.
# Each of these selected only NativeMarkdownDrawingTests:
# TEST_RUNNER_PI_DRAW_TRACE=1                                  -> trace.log
# TEST_RUNNER_PI_DRAW_TRACE=1 TEST_RUNNER_PI_DRAW_JOIN_GUARD_OFF=1 -> guard-off.log
```

```sh
# Fixed affected classes, after build-for-testing; lock held for this run.
TEST_RUNNER_PI_MARKDOWN_DRAWING_GALLERY="$B/gallery-fixed-focused" \
  xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/NativeMarkdownDrawingTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/SessionCardSwitchTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests

# Mutation: restore the old draw order, rebuild, then under the lock:
TEST_RUNNER_PI_MARKDOWN_DRAWING_GALLERY="$B/gallery-mutation" \
  xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/NativeMarkdownDrawingTests
# Restore the fixed file and rebuild before the final run.

# Complete requested galleries and restored pixel regression, under the lock:
TEST_RUNNER_PI_MARKDOWN_DRAWING_GALLERY="$B/gallery-final-focused" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$B/gallery-fixed" \
TEST_RUNNER_PI_SESSION_PANEL_GALLERY="$B/gallery-session-panel" \
  xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/NativeMarkdownDrawingTests \
  -only-testing:PiAppTests/UIScreenshotTests \
  -only-testing:PiAppTests/SessionPanelGalleryTests

# Draw-time reading callbacks, queued behind the gallery under the same lock:
xcodebuild test-without-building "${X[@]}" -parallel-testing-enabled NO \
  -only-testing:PiAppTests/StableReadingTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests
```
