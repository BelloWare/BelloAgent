# PERF-2: button drawing on chat switches — 0.1.131

Workstream `dev/a131-buttons`, based on `dev/next` `5b8fe72f`.
Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-buttons`;
text evidence is in `evidence/`, with soak reports and profiles in `ab-*/`.
Only generated fixtures, the isolated `com.belloware.PiAppTests.Host`, an
in-memory vault and the soak's loopback gateway are used. No installed app,
real preferences, real chats, Keychain, capture or paid provider is used.

## Reproduction and cause

`ButtonBase.layout()` unconditionally calls `content.setNeedsDisplay()` after
laying out its layers. The layer already has `needsDisplayOnBoundsChange`;
moving the control or laying it out at the same size does not change its
content, but the explicit invalidation draws its text and symbol images again.
PERF-1's record and the 0.1.129/130 profiles identify about 1,200 main-thread
samples in composer pills and icon drawing per two minutes of chat switching.

`ButtonRedrawTests` counts real content-layer drawing through its existing
drawer closure, without production counters or showing a window. It covers
ten unchanged layouts and moves of pill, icon, composer, menu and tab buttons;
size, label, symbol and selection changes; hover, press, enabled and native
button state changes before layout; appearance and simulated 1x/2x windows.

## Fix

- `ButtonBase.layout()` keeps geometry as before and lets the existing
  `DrawingLayer.needsDisplayOnBoundsChange` invalidate a resized face. A move
  or an unchanged layout keeps the content layer's text and symbol images.
- `refreshFace()` compares hover, press, own/effective enabled state and
  native selection before invalidating content. Subclasses that draw their
  ink from state therefore update even without layout; repeating a state or
  refreshing the same face keeps its pixels. Existing pill/tab selection
  invalidations remain in their setters.
- Appearance and scale invalidation share a guard on the layer's current
  appearance and `contentsScale`, used by layout and AppKit's appearance,
  window and backing-property callbacks.
- `Button` and `IconButton` skip equal-value assignments to drawing inputs
  (style, compactness, symbol, symbol placement, tone and icon size).
  No drawing, shape, font, spacing, color or animation code is changed.

## Validation

**Failing first** (`evidence/failing-first.log`): production sources still
`5b8fe72f`; `ButtonRedrawTests` **7 executed, 7 failed, 34 assertions**.
Button, IconButton, ComposerPillButton, MenuButton and Tab each drew **11**
times for the initial draw followed by ten unchanged layouts/moves. The
state test also exposed that content using hover/press/enabled/native button
selection was not invalidated until layout. Appearance, scale, size and
content tests rejected the extra draw on the following unchanged layout.

Exact command (with the exported build root):

```sh
scripts/test-macos.sh -configuration Release ENABLE_TESTABILITY=YES -jobs 4 \
  -parallel-testing-enabled NO -only-testing:PiAppTests/ButtonRedrawTests
```

**Fixed** (`evidence/fixed-new.log`) and **restored after mutations**
(`evidence/restored-new.log`): **7/7 passed** in each run. The content-change
case also checks style, compactness, symbol placement and icon size, including
setting each input to the same value again.

Debug command for these and each mutation (no windows shown):

```sh
scripts/test-macos.sh -jobs 4 -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ButtonRedrawTests
```

**Mutation checks** (`evidence/mutation-*.log`,
`evidence/mutations-summary.txt`); fixed source restored after every run:

| Broken | Result |
| --- | --- |
| Restore unconditional content invalidation in layout | 7 executed, 7 failed, 31 assertions; unchanged layouts draw again |
| Disable bounds-change invalidation, state invalidation and the environment update (retain the initial draw) | 7 executed, 4 failed, 35 assertions; size, state, appearance and scale tests each fail |
| Remove equal-value guards from Button/IconButton setters | 7 executed, 1 failed, 9 assertions; repeated content assignments redraw |

**Release redraw check** (`evidence/release-fixed-new.log`), using the same
Release command as failing first: **7/7 passed**.

**Unchanged parity, behavior and galleries**, Release, serial under the lane
lock (`evidence/affected-serial.log`): **81 executed, 1 skipped, 0 failed**.

| Class | Executed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| PiKitControlTests | 39 | 0 | 0 |
| PiKitParityTests | 21 | 1 | 0 |
| ShellParityTests | 15 | 0 | 0 |
| CapsuleRenderingTests | 1 | 0 | 0 |
| SessionCardSwitchTests | 3 | 0 | 0 |
| CapsuleGalleryTests | 1 | 0 | 0 |
| SessionPanelGalleryTests | 1 | 0 | 0 |

`PiKitParityTests.testHoverStates` retained its existing skip because posting
pointer events needs Accessibility permission for this test runner. The
programmatic hover/press/enable tests passed. No existing test or parity
threshold was edited.

```sh
env TEST_RUNNER_PI_CAPSULE_GALLERY="$PI_BUILD_ROOT/gallery-capsule" \
    TEST_RUNNER_PI_SESSION_PANEL_GALLERY="$PI_BUILD_ROOT/gallery-session-panel" \
  scripts/test-macos.sh -configuration Release ENABLE_TESTABILITY=YES -jobs 4 \
    -parallel-testing-enabled NO \
    -only-testing:PiAppTests/PiKitControlTests \
    -only-testing:PiAppTests/PiKitParityTests \
    -only-testing:PiAppTests/ShellParityTests \
    -only-testing:PiAppTests/CapsuleRenderingTests \
    -only-testing:PiAppTests/SessionCardSwitchTests \
    -only-testing:PiAppTests/CapsuleGalleryTests \
    -only-testing:PiAppTests/SessionPanelGalleryTests
```

Galleries regenerated **26 images**: four capsule sheets (light/dark, 1x/2x)
and 22 session-panel scenes. Inspected the capsule sheets and representative
light/dark full and narrow views, including Agents, Diff and Files. Button
labels, icons, capsule outlines, chosen tabs, composer pills and the narrow
family pill remain correctly drawn. Only the changed code and its covering
classes were tested; no full native, helper or wire suites were run.

The first Release test build stopped before tests: `GitView` was not compiled
for `@testable` imports (`evidence/release-testability-build.log`). Rebuilt with
the documented `ENABLE_TESTABILITY=YES`; this compilation failure is not the
failing-first result.
The new test counter also needed an explicit `@MainActor` annotation on its
nested helper (`evidence/failing-first-build-actor.log`); fixed before the
failing-first run executed.

## Release chat-switch A/B

The supplied `r131/ab-soak.sh` is copied into this build root, with output and
host-isolation-check paths redirected to this worktree; its profile selects
this build root's test host by executable path. It records load at start/end
and every ten seconds. The lock owner is `a131-buttons soak <name> <date>`.
`ab-analyze.py` is an unchanged copy of the supplied analyzer. This workstream
runs no other builds, tests or captures beside a soak.

Release build/run commands (with the exported build root):

```sh
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO -jobs 4
zsh "$PI_BUILD_ROOT/ab-soak.sh" base "$PI_BUILD_ROOT/native-tests" 900
zsh "$PI_BUILD_ROOT/ab-soak.sh" new "$PI_BUILD_ROOT/native-tests" 900
python3 "$PI_BUILD_ROOT/ab-analyze.py" 900 "$PI_BUILD_ROOT/ab-base" \
  "$PI_BUILD_ROOT/ab-new" 'ButtonBase|ComposerPillButton|IconButton|Tabs'
python3 "$PI_BUILD_ROOT/profile-cost.py" "$PI_BUILD_ROOT/ab-base" "$PI_BUILD_ROOT/ab-new"
```

Before: `5b8fe72f`, with only the new test file added; production sources
unchanged. After: the button fix in this worktree. Source/product hashes are
in `evidence/base-product.txt` and `evidence/new-product.txt`. Analysis is in
`evidence/ab-report.txt` and `evidence/ab-profile-cost.txt`.

Both runs used 900 s, seed **1790822043708**, chat switching enabled,
every answer over 50 ms recorded and a **120 s, 1 ms `sample`**. Each completed
906 s, **44 launches, 1,099 selections and 220 rapid switches**.

| Measurement | Before | After |
| --- | ---: | ---: |
| 1-minute load: start / max / end, including teardown | 1.91 / 3.86 / 3.49 | 1.98 / 3.52 / 3.36 |
| Main-thread samples: busy / total | 22,109 / 84,918 | 20,678 / 86,220 |
| Busy sample time, nominal 1 ms | 22.109 s | 20.678 s (−6.5%) |
| Busy fraction × 120 s, estimated time in the profile window | 31.243 s | 28.779 s (−7.9%) |
| All button content drawing samples | 1,766 | 523 (−70.4%) |
| Composer pills + icon button drawing | 1,212 | 131 (−89.2%) |
| — composer pills | 483 | 27 |
| — PiKit icon buttons | 729 | 104 |
| Composer send/stop drawing | 225 | 61 |
| Before 755 s: answers over 50 / 75 / 100 / 150 ms | 543 / 68 / 5 / 0 | 562 / 37 / 4 / 0 |
| Select, chats 1–5: n; median / p90 / max | 274; 60 / 72 / 79 ms | 280; 60 / 70 / 79 ms |
| Select, largest chat 6 | 91; 74 / 80 / 83 ms | 91; 72 / 78 / 82 ms |
| Two chats within 50 ms, chats 1–5 | 75; 60 / 68 / 77 ms | 73; 60 / 71 / 77 ms |
| Two chats within 50 ms, including chat 6 | 30; 68 / 80 / 84 ms | 31; 68 / 74 / 81 ms |
| Launch answers | 32; 63 / 77 / 84 ms | 39; 61 / 75 / 77 ms |
| Quit answers | 27; 59 / 63 / 66 ms | 33; 64 / 69 / 72 ms |
| Whole run: answers over 50 / 100 / 150 / 200 ms | 682 / 7 / 1 / 0 | 707 / 6 / 0 / 0 |
| Whole run: longest answer | 187 ms | 147 ms |
| Sidebar listed after launch: median / max | 259 / 497 ms | 260 / 349 ms |
| Idle row jumps / slow launches / never-listed launches / quit failures | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| Footprint: first / last / peak | 107 / 270 / 270 MB | 107 / 274 / 274 MB |
| Footprint growth per launch | 3.79 MB | 3.88 MB |

Answer quantiles are **only answers over 50 ms**, as the supplied analyzer
reports them, before 755 s to leave out profiling. Ordinary opening's median
remains 60 ms; its p90 improves by 2 ms, as does the largest chat's. The
50 ms answer count increases, while the count over 75 ms falls. The clear
reduction is in button drawing and main-thread busy work; this single pair
supports that conclusion without a broad latency claim.

Profile counts are inclusive main-thread subtrees, counting a matching
ancestor only once. Button drawing is the content drawer closure in
`ButtonBase.init(frame:)`; composer/icon drawing is their `drawContent(in:)`
subtrees. Main-thread busy excludes `__CFRunLoopServiceMachPort` waits.
The nominal 1 ms time matches the earlier record's sample-count convention;
the busy fraction scaled to 120 s also accounts for the different total
number of samples collected in each window.

The first baseline attempt (`ab-base-discard1/`,
`evidence/ab-base-discard1-run.log`) started at load 2.79 but reached **4.62**.
It was interrupted before profiling, its logs retained and its own processes
stopped; no other workstream process or lock was removed. The runner's quiet
start threshold was tightened from below 3 to below 2 for both kept runs.

The 50 ms threshold is both the recording and assertion threshold in
`SoakTests`: a completed measurement with any such answer deliberately fails
that assertion. Each run executed 1 test with 1 expected threshold assertion failure. Row
jumps, slow launches and quit failures all passed in both runs; these are
measurement runs with the lowered threshold.

## Secondary findings

Left listed for separate work:

- `apps/macos/PiApp/DesignKit/PiKitControls.swift:287`, `Tabs.intrinsicContentSize`: every query measures its
  tab labels again, and layout queries each button again. A size cache must
  cover title/order, backing scale and child invalidations; it is independent
  of the content-layer fix.
- `apps/macos/PiApp/Transcript/NativeTranscriptView.swift:104` and
  `NativeTranscriptScrollView.swift:128`, legacy transcript scrollers: a scroller appearing after the first layout
  narrows the column by 15 pt and measures every row again at the new width
  (PERF-1's reproduction). Changing gutter reservation affects transcript
  layout and overlaps the scroll workstream.
- `apps/macos/PiApp/Transcript/TranscriptNativeTimelineParts.swift:130`,
  reasoning still arriving in an opened work row: its caret can lay out the
  text at 840 pt before measurement. Passing the row's final width into this
  surface needs its own streaming/row sizing regression; it is outside the
  button drawing path.

Remaining drawing in the profile includes `PiKit.StatPill.drawContent`
(224 → 206 samples) and `SidebarLinkButton.drawContent` (74 → 83).
`apps/macos/PiApp/DesignKit/PiKitOverlays.swift:68` (`StatPill.update`) and
`apps/macos/PiApp/Workspaces/SidebarEntryViews.swift:432` (`SidebarLinkButton.title`) explicitly
request content drawing on model/title updates. Guards for unchanged inputs
at those call sites are separate follow-ups; the sidebar is another
workstream's file. They were left unchanged here.
