# FOLD-GAP: folded rows take no room (0.1.136)

Workstream `dev/a136-foldgap`, based on `be21bc0bb49923e7cb49335290692937095c423e`
(released 0.1.135 plus the 0.1.136 plan). Implemented 2026-10-28/29 on the
owner's Mac. Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a136-foldgap`.
The lead reviews and merges this branch. No release, tag, or publication is included.

## Cause and design

A folded row without a tree measured one point; its estimate also reserved one
point. A previously opened row's native content likewise reported a minimum of
one point, and the standing-row fallback and motion interpolation imposed that
minimum. Stacking these rows accumulated one blank point per hidden row.
The inherited-context disclosure uses the same row containers and was affected.

Keep every row and its identity, but give folded rows zero height. This is smaller
than removing/skipping rows throughout reconciliation, Find, disclosure ownership,
and retained-row caches. The container owns zero measurement and validation even
when an opened row retained its native tree; individual content classes keep their
existing sizing contracts. Estimates, standing heights, the measuring band's
`rowTops` inputs, and motion endpoints agree. `rowTops` already sums zero correctly.
Opening still restores every row, and closing returns to the exact folded geometry.
When completing an older partial turn makes a document shorter than the viewport,
it starts at `pageTopInset + leadingSpace`, including a document with a newer turn.
Round 2 removes the completion room above the page and its row shift. A reader in
a taller newer turn keeps the existing row anchor. No space is inserted between
a fold line and its answer. The existing 18-point footer hold is unchanged.
The turn planner, running-turn rules, and saved disclosure choices are unchanged.

The document keeps a compact index of rows occupying space, updated only for the
suffix a layout places (and during disclosure motion). Visibility and reading-row
lookups use it. Between structural reconciliation and its queued layout, reading
uses retained nonhidden frames until that index is rebuilt. Layout reconciles
hosts it actually touched instead of reintroducing all retained rows into the
visibility list. This prevents a token from walking a
folded turn merely because its coincident frames lie in the viewport band.

Anchor audit:

- `readingRow`, `captureDocument`, and `firstStartingOnScreen` use the document's
  visible-row lookup, which excludes zero-height and folded rows, including rows
  still moving shut. A next row is found across the entire hidden run.
- `TranscriptPage.firstPlacedRow`'s fallback and `visibleMessageIDs` reject folded
  and zero-height rows. `document.firstVisibleItem` uses the same index.
- Explicit holds, replacement-row lookup, and restoration reject hidden rows;
  a held row that folds is recaptured from the remaining visible content.
- Room-edge detection and trailing-room preservation use the first/last placed
  rows, so a hidden endpoint is not mistaken for an unplaced document. Near the
  loaded window, resizing unread room retains the row anchor through the same
  buffer margin used by `noteReaderInRoom`; only farther away does a logical
  position in unread history replace it.
- The footer's `frame.height > 1` check is specifically for a real summary losing
  its partial-history note. It remains unchanged. Positive minima for widths,
  visible streaming text, and pinned animation content/masks are not row slots;
  they remain unchanged. The interpolation of the actual row frame reaches zero.

History room is estimated from placed height divided by **every message in the
window**, with the existing 24-point floor. Unread history has the same mix of
hidden and visible messages; excluding hidden messages inflated the estimate.
Round 2 restores this formula and removes the drawn-message walk and its counter.
Fold/footer space remains in the numerator; folded rows contribute zero height.
The generated 202-message test has 601 hidden render rows, 198 pt of placed content,
and two visible messages: **24 pt/message**, down from round 1's 99. Window
membership still controls when to resample. Newer-token visibility and reconciliation
counts remain covered; helper projection/delivery code is unchanged.

## Round 1 failing first and mutation

`failing-first.log` built production sources at `be21bc0b` with the new real-window
`TranscriptTurnFoldTests.testFoldedRowsLeaveTheSameAnswerGapAsATurnWithoutWork`.
It failed **1 test / 4 assertions**. Exact hidden-row counts are asserted; all rows
are opened and closed again to test the retained-tree path too.

| Hidden rows | Baseline row gap | Fixed row gap |
| ---: | ---: | ---: |
| 0 (no-work control) | 0 pt | 0 pt |
| 10 | 10 pt | 0 pt |
| 200 | 200 pt | 0 pt |

The row gap is the answer row's top minus the preceding fold/header row's bottom.
The fold's own padding and the answer's text inset are measured separately below.

`mutation.py` changed only the folded measurement from zero back to one. The same
regression again reported **1 failed test / 4 assertions**, with 10/200 pt gaps
(`mutation-one-point.log`). It restored the source in `finally`; final tests rebuilt
restored products. The animation tests now also require an exact zero endpoint.

Additional regressions exercise 200 inherited messages, exclusion from visible
message IDs, the next visible reading row, opening and closing inherited context,
history sampling, and newer-token work. Initial fixture-development runs are kept:
`fixed-TranscriptTurnFoldTests.log` and `fixed2-TranscriptTurnFoldTests.log` had
incorrect fixture setup (status notices are not tool replies, inherited markers
need a managed Codex child, and history positions must be installed before binding).
`focused-sampling.log` then exposed the real all-row visibility-list reset; fixing
that changed ten-token visibility visits from 6,070 to 60.
`baseline-extra.log` executed zero tests because the added method was not in that
already-built test bundle; it is not validation evidence.

The first broader run caught the short newer answer moving **630.076 → 513 pt**
when the document became shorter than the viewport. The completion-space repair
keeps it at **630.076 → 630.076 pt**. The following tall answer and the opened fold
remain at **−604 → −604 pt**; the reader inside the newer tall answer remains at
**−120.076 → −120 pt**. The intentionally short first turn still folds upward from
its old work into the normal top-inset layout. A paging-anchor failure found in
that run moved a near-window row by 960 pt. The reader's viewport had just left
the loaded rows, but was still inside the paging buffer; room resizing discarded
the row anchor before the approaching page landed. Keeping it through that buffer
and honoring retained frames before indexing fixes the existing whole-chat paging
case. `repair-LongTurnPagingTests.log` and both `diagnostic-paging*.log` retain the
failed attempts; `verified-LongTurnPagingTests.log` passes all nine cases. Temporary
trace prints were removed before the verified build. An intermediate gallery-only
assertion mistook the native text surface's top for ink: the surface is 8 pt below
the divider, while the first drawn glyph starts 12 pt below it; the final check and
pixel measurement distinguish these. The round-1 completion-space repair and
visible-message history sample are superseded by the round-2 review below.

## Round 1 commands and isolated suites

Every command ran in the assigned worktree with:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-foldgap
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptTurnFoldTests/testFoldedRowsLeaveTheSameAnswerGapAsATurnWithoutWork
```

That first command staged the helper and generated the project. Subsequent builds
used the same DerivedData, never a second build root:

```sh
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -parallel-testing-enabled NO -only-testing:PiAppTests/<Class-or-Class/method>
# After building: the same command with test-without-building instead of test.
```

`run.py`, `verified-checks.py`, and `mutation.py` under the build root preserve exact
invocations. Every log begins with the expanded command, load average, and process
CPU snapshot, and ends with the exit status. Each class runs alone. Every run
acquires the shared lock and releases it in `finally`; no full lanes ran. All
checks use the isolated test host, generated data, and loopback services. Debug
products were used for behavior and operation-count assertions; no new Release
speed claim is made. No tests or code in the concurrent P3 workstream were changed.

Final rebuild and serial class commands:

```sh
python3 "$PI_BUILD_ROOT/mutation.py"
python3 "$PI_BUILD_ROOT/verified-checks.py"
```

The final run has **277 executions: 275 passed, 2 opt-in skips, 0 failures**.
Logs are `verified-<Class>.log` under the build root. The first class rebuilt the
restored sources; each remaining class used `test-without-building` against those
same products. Both disclosure-motion variants, running turns, opened folds,
Find/reveal/latest, and all `completeCutTurn` cases passed.

| Class (run alone) | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| TranscriptTurnFoldTests | 29 | 0 | 0 |
| LongTurnPagingTests | 9 | 0 | 0 |
| HistoryTurnPagingTests | 6 | 0 | 0 |
| InheritedSubagentReaderTests | 8 | 0 | 0 |
| StreamedReplyEndTests | 8 | 1 | 0 |
| FreshPresentationTests | 21 | 0 | 0 |
| HistoryExtentTests | 26 | 0 | 0 |
| TranscriptOpeningFillTests | 11 | 1 | 0 |
| TranscriptRevealTests | 12 | 0 | 0 |
| TranscriptFindTests | 12 | 0 | 0 |
| NativeTranscriptDocumentTests | 10 | 0 | 0 |
| NativeTranscriptScrollTests | 5 | 0 | 0 |
| NativeTranscriptSafetyTests | 5 | 0 | 0 |
| TranscriptStreamingScrollTests | 3 | 0 | 0 |
| TranscriptKeptRowsTests | 10 | 0 | 0 |
| TranscriptWidthChangeTests | 6 | 0 | 0 |
| TranscriptGeometryCacheTests | 7 | 0 | 0 |
| TranscriptFrameBudgetTests | 6 | 0 | 0 |
| TranscriptPageStressTests | 24 | 0 | 0 |
| TranscriptHeightSamplingTests | 1 | 0 | 0 |
| TranscriptIncrementalTests | 12 | 0 | 0 |
| TranscriptVisibilityTests | 3 | 0 | 0 |
| TranscriptRowChangeTests | 4 | 0 | 0 |
| TranscriptRowUpdateTests | 5 | 0 | 0 |
| TranscriptUpdateIsolationTests | 8 | 0 | 0 |
| StableReadingTests | 6 | 0 | 0 |
| NativeMarkdownViewportTests | 4 | 0 | 0 |
| MarkdownSourceReconciliationTests | 7 | 0 | 0 |
| LongChatScrollTests | 6 | 0 | 0 |
| SubagentCodexGalleryTests | 1 | 0 | 0 |

The two existing opt-in skips are
`StreamedReplyEndTests.testAStreamedReplyEndsWholeOnScreenUnderInterference`
(`PI_STREAM_STRESS_SECONDS` unset) and
`TranscriptOpeningFillTests.testOpeningFillGallery` (`PI_OPENING_GALLERY` unset).
The requested turn-fold and inherited galleries ran with their variables set.

## Round 1 gallery and geometry

Baseline and final `LongTurnPagingTests` used:

```sh
TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/gallery-before" \
  python3 "$PI_BUILD_ROOT/run.py" run baseline-turnfold-gallery \
  LongTurnPagingTests/testFinishedTurnFillKeepsTheFollowingReaderAtTheEnd
TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/gallery-after" \
  python3 "$PI_BUILD_ROOT/run.py" run verified-LongTurnPagingTests LongTurnPagingTests
TEST_RUNNER_PI_APP_CODEX_AGENTS_GALLERY="$PI_BUILD_ROOT/gallery-inherited" \
  python3 "$PI_BUILD_ROOT/run.py" run verified-SubagentCodexGalleryTests SubagentCodexGalleryTests
```

All four before and all four after turn-fold captures were opened and inspected:
900 pt light/dark and 520 pt narrow light/dark. The question, one fold line, answer,
and footer are intact, with no clipping or overlap and no blank band. The generated
fixture's project-unavailable notice is expected. `TranscriptTurnFoldTests` has no
separate gallery scenes.

| Geometry (all four scenes) | Before | After |
| --- | ---: | ---: |
| Folded rows | 193 | 193 |
| Fold row bottom → answer row top | 193 pt | 0 pt |
| Drawn divider bottom → prose surface | 201 pt | 8 pt |
| Drawn divider bottom → first answer ink | 205 pt | 12 pt |

The wide first row starts at 12 pt; its fold row ends at 134 pt and answer row
starts at 134 pt (before: 327 pt). Narrow: fold/answer both 158 pt (before: 351 pt).
The document logs the row and surface coordinates. `readpng.swift` / `pixel-gaps.log`
measure the 2× PNGs: wide divider bottom 252 px, answer ink 662 → 276 px; narrow
300 px, ink 710 → 324 px. Light and dark agree exactly. Command:

```sh
swift -module-cache-path "$PI_BUILD_ROOT/swift-cache" \
  "$PI_BUILD_ROOT/readpng.swift" > "$PI_BUILD_ROOT/pixel-gaps.log"
```

The inherited-context gallery regenerated successfully. All eight relevant PNGs
were opened and inspected: `inherited-{fold,expanded}-{light,dark}-{920,640}.png`.
Folded context puts the local handoff card directly after the disclosure's normal
padding; no hidden-row band remains. Expanded context shows all six seed messages
and scrolls down to the handoff. Light/dark are legible and narrow wrapping fits;
the narrow disclosure label uses its existing ellipsis. The separate 200-message
regression checks exact zero hidden heights and open/close geometry, so this
six-message visual fixture does not limit the row-count coverage.

## Round 1 machine comparison and remaining work

`LongChatScrollTests` ran once on the unchanged `be21bc0b` products and once on the
fixed products, using the same build root and arguments, each alone under the
shared lock:

```sh
# Before production edits, against the failing-first build of be21bc0b:
python3 "$PI_BUILD_ROOT/run.py" run baseline-LongChatScrollTests LongChatScrollTests
# Fixed products, also included once in verified-checks.py:
python3 "$PI_BUILD_ROOT/run.py" run verified-LongChatScrollTests LongChatScrollTests
```

Both passed **6/6**, baseline in 81.718 s and fixed in 79.928 s. These are Debug
test durations, not speed comparisons. The process snapshots record `replayd`
at 78.0% before the baseline suite and 80.1% before the fixed suite (91.4% at the
initial build). There was no shared failure signature to classify as machine
interference. No LongChatScrollTests threshold or test was changed.

The two opt-in checks above were not run. Lead review subsequently requested
the corrections recorded below; the merged release gate remains with the lead.

## Round 2: lead review of 0744a8d1 (2026-10-29)

### F1 — all-message history average

Restored `max(24, placedHeight / snapshot.messages.count)`. The denominator must
describe the unread timeline, including hidden messages, rather than just messages
with drawn rows. Removed the drawn-message walk and `historySampleRowVisitCount`.
The renamed folded-window regression retains its newer-token visibility and
reconciliation checks and pins the all-message average and 24-point floor.

On unchanged round-1 production code, `round2-failing-F1.log` fails **1 test / 2
assertions**: 198 pt across 202 messages sampled 99 instead of 24 pt/message.
`round2-fixed-F1.log` passes **1/1**, with 24 pt/message. The 500 unread messages
in this fixture therefore reserve 12,000 rather than 49,500 pt. The floor remains
an estimate; this folded window's actual placed average is about 0.98 pt/message.

### F2 — short documents start at the top

Removed `completedNewerTail`, `completionTopSpace`, their capture/reset logic,
the addition to `roomHeights`, and the row-shifting loop in `finishPass`.
`testFinishedTurnFillLaysOutAShortNewerTurnFromTheTop` replaces the short-tail hold
expectation. Both short completion fixtures now require a document shorter than
the viewport, zero leading room, and the first row at `pageTopInset + leadingSpace`.
The tall newer-reader assertions and 18-point footer hold are unchanged.

`round2-failing-F2.log` fails on round 1: **1 test / 2 assertions**, with 116.076 pt
of held leading room and an 804.076-pt document at an 804-pt viewport. The fixed
test passes **1/1** (`round2-fixed-F2.log`): the short answer moves **629 → 513 pt**
as its earlier work folds, and the document takes its ordinary top-aligned layout.
No top room remains until the next send.

### F3 — retain the paging margin, with a separate regression

F1/F2 were applied and the room-resize condition was restored to
`clip.bounds.maxY <= top + leadingSpace` before rerunning the exact earlier failure,
`testScrollingUpThroughToolHeavyTurnsNeverReshapesATurn`. It still fails:
`round2-F3-without-margin.log`, **1 test / 1 assertion**; `u27` moves **−1,319.8 pt**
at frame 11. The inflated F1 sample was therefore not the only cause.

The new `testRoomResizeKeepsTheRowAnchorJustAboveTheLoadedWindow` isolates the
boundary with an actual tool-heavy pane. It verifies the restored **24 pt/message**
sample, parks the viewport wholly above the first drawn row but within half the
paging margin, and disables the edge-read callback to isolate a resize to 36 pt/message.
It asserts the resize happened, the row stayed at the same screen position, and
no unrelated position read began. Without the margin, the row moves **851.5 →
1,277.5 pt** and a position read starts at message 2,638: `round2-failing-F3.log`,
**1 test / 2 assertions**. With the margin, it stays **851.5 → 851.5 pt** and no
position read starts. That test and the whole-chat case pass **2/2** in
`round2-fixed-F3.log`; the latter records **zero jumps, lost rows, or read errors**.

Keep the margin: `noteReaderInRoom` already uses it to distinguish approaching
edge paging from a distant position in unread history. Room resizing must make
the same distinction rather than discard the row anchor inside that buffer.
Farther into unread room, the existing logical-position behavior is unchanged.

### Round 2 commands and mutations

All runs reuse the assigned build root and its existing `native-tests` products.
No helper or project-file changes were needed. Each class runs alone, with
parallel testing disabled and the shared focus lock held for that invocation.
LongChatScroll runs mark the lock `perf` and sample the one-minute load every
five seconds, as well as recording load and process state at the start and load
at the end. No installed app, real user data, or live capture is used.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-foldgap
# run.py and round2-run.py expand build/run into this command:
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -parallel-testing-enabled NO -only-testing:PiAppTests/<Class-or-Class/method>
# run uses test-without-building in place of test; exact selectors are logged.

python3 "$PI_BUILD_ROOT/run.py" build round2-failing-F1 \
  TranscriptTurnFoldTests/testFoldedMessagesCountInHistoryAverageWithoutVisitsFromANewerToken
python3 "$PI_BUILD_ROOT/run.py" run round2-failing-F2 \
  LongTurnPagingTests/testFinishedTurnFillLaysOutAShortNewerTurnFromTheTop
# After F1/F2, with the room-resize margin removed:
python3 "$PI_BUILD_ROOT/run.py" build round2-fixed-F1 \
  TranscriptTurnFoldTests/testFoldedMessagesCountInHistoryAverageWithoutVisitsFromANewerToken
python3 "$PI_BUILD_ROOT/run.py" run round2-fixed-F2 \
  LongTurnPagingTests/testFinishedTurnFillLaysOutAShortNewerTurnFromTheTop
python3 "$PI_BUILD_ROOT/run.py" run round2-F3-without-margin \
  LongTurnPagingTests/testScrollingUpThroughToolHeavyTurnsNeverReshapesATurn
python3 "$PI_BUILD_ROOT/round2-run.py" build round2-failing-F3 \
  LongTurnPagingTests/testRoomResizeKeepsTheRowAnchorJustAboveTheLoadedWindow
# Restore the margin:
python3 "$PI_BUILD_ROOT/round2-run.py" build round2-fixed-F3 \
  LongTurnPagingTests/testRoomResizeKeepsTheRowAnchorJustAboveTheLoadedWindow \
  LongTurnPagingTests/testScrollingUpThroughToolHeavyTurnsNeverReshapesATurn
python3 "$PI_BUILD_ROOT/round2-mutations.py"
python3 "$PI_BUILD_ROOT/round2-checks.py"
# The first LongChat run passed, but its load exceeded 4; repeat after settling:
python3 "$PI_BUILD_ROOT/round2-quiet-checks.py" > "$PI_BUILD_ROOT/round2-quiet-checks.log" 2>&1
```

`round2-mutations.py` breaks each fix independently, rebuilding for its one
regression. It restores the source after each test and in `finally`. All three
mutations were caught by assertions, with **1 failed test / 2 assertions each**:

| Mutation | Result | Log |
| --- | --- | --- |
| F1: restore the visible-message denominator | 99 instead of 24 pt/message | `round2-mutation-F1.log` |
| F2: restore the newer-tail top hold | Leading room returns; short document no longer fits | `round2-mutation-F2.log` |
| F3: remove only the room-resize margin | 426-pt row shift and unwanted position read | `round2-mutation-F3.log` |

The first final suite rebuilds restored sources before the remaining isolated
class runs use those same products. Text logs are the evidence; no named result
bundles or extra DerivedData copies were created.

### Round 2 gallery and geometry

The final LongTurnPagingTests invocation set
`TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/gallery-round2"`. All four fresh
captures were opened and inspected: 900-pt light/dark and 520-pt narrow light/dark.
The question begins at the normal top inset, the sixty-call disclosure is closed,
the answer follows without a hidden-row band, and the completed footer fits. No
clipping or overlap; both appearances are legible and narrow text wraps correctly.
The generated fixture's project-unavailable notice is expected.

All four scenes retain **193 hidden rows, 0-pt row gap, 8-pt divider-to-prose-surface
gap, and 12-pt divider-to-first-ink gap**. The first row is at 12 pt; wide fold/answer
edges coincide at 134 pt, narrow at 158 pt. Pixel measurements against the retained
baseline remain **205 → 12 pt**, in both appearances and widths:

```sh
swift -module-cache-path "$PI_BUILD_ROOT/swift-cache" \
  "$PI_BUILD_ROOT/round2-readpng.swift" > "$PI_BUILD_ROOT/round2-pixel-gaps.log"
```

Final completion checks (`round2-verified-LongTurnPagingTests.log`): tall newer
reader **−120 → −120 pt**; following reader **−603.983 → −604 pt**; opened fold
**−603.983 → −603.75 pt**. Short newer answer **630 → 513 pt**, with zero held top
room; short first-turn answer **487.867 → 134 pt**. The 18-point footer hold and
its release on the next question pass unchanged. The final folded-window check
records **24 pt/message, 10 row reconciliations and 60 visibility visits for ten
newer tokens**, with 601 hidden rows.

### Round 2 isolated suite counts and quiet reruns

The final set is **189 executions: 188 passed, 1 opt-in skip, 0 failures**, including
two quiet LongChat runs. Logs are `round2-verified-<Class>.log`, except the accepted
LongChat logs, `round2-quiet-LongChatScrollTests-{1,2}.log`. The additional
TranscriptHeightSamplingTests class covers the changed history sampling function.

| Class (each run alone) | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| TranscriptTurnFoldTests | 29 | 0 | 0 |
| LongTurnPagingTests | 10 | 0 | 0 |
| HistoryTurnPagingTests | 6 | 0 | 0 |
| InheritedSubagentReaderTests | 8 | 0 | 0 |
| HistoryExtentTests | 26 | 0 | 0 |
| FreshPresentationTests | 21 | 0 | 0 |
| TranscriptOpeningFillTests | 11 | 1 | 0 |
| TranscriptRevealTests | 12 | 0 | 0 |
| NativeTranscriptDocumentTests | 10 | 0 | 0 |
| NativeTranscriptScrollTests | 5 | 0 | 0 |
| TranscriptStreamingScrollTests | 3 | 0 | 0 |
| TranscriptKeptRowsTests | 10 | 0 | 0 |
| TranscriptPageStressTests | 24 | 0 | 0 |
| TranscriptHeightSamplingTests | 1 | 0 | 0 |
| LongChatScrollTests, quiet run 1 | 6 | 0 | 0 |
| LongChatScrollTests, quiet run 2 | 6 | 0 | 0 |

The skip is `TranscriptOpeningFillTests.testOpeningFillGallery`, whose existing
`PI_OPENING_GALLERY` opt-in was unset. The requested turn-fold gallery was enabled
and all four captures inspected.

The initial LongChat run also passed **6/6** (`round2-verified-LongChatScrollTests.log`,
79.469 s), but its sampled one-minute load peaked at **4.52**. The validation driver
stopped on that machine-condition check, not a test failure. That log is preserved
as an additional run and is not counted as one of the required two quiet runs.
`round2-quiet-checks.py` waited for a start load at or below 2.5 and repeated the
same suite twice, each under the shared `perf` lock: **6/6 in 79.423 s**, peak
sampled load **2.74**, and **6/6 in 79.540 s**, peak **2.98**. These are Debug
behavior checks, not Release speed comparisons. LongChat test code and thresholds
are unchanged. `replayd` was at **0.0%** in each run's starting process snapshot.

No assigned F1–F3 issue remains unresolved. Lead review and the merged release
gate remain with the lead. This branch does not release, tag, or publish.
