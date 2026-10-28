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
scrolling can no longer hold the newer turn at its old screen position. The
completion pass retains only that missing room above the page, and only for a
reader following the end or already inside the newer turn. The space belongs to
that tail, is released on a new tail/presentation, and is not recomputed per token.
A short first turn still starts at the ordinary top inset; no space is inserted
between a fold line and its answer. The existing 18-point footer hold is unchanged.
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

History room is estimated from unique source messages with at least one visible
row. A response with hidden reasoning and visible prose counts once; a wholly
hidden tool reply or inherited message does not count. Fold/footer space remains
in the numerator. The existing window membership count still controls when to
resample, and the visible-message walk happens only after that guard. The generated
202-message test has 601 hidden render rows, 198 pt of placed content, and two
visible messages: **99 pt/message**, rather than the minimum 24 pt caused by
dividing by all 202 messages. Ten newer tokens perform **10 row reconciliations,
60 visibility visits, and zero history-sample visits**. These are operation counts,
not Release timing claims. Helper projection/delivery code is unchanged.

## Failing first and mutation

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
pixel measurement distinguish these.

## Commands and isolated suites

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

## Gallery and geometry

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

## Machine comparison and remaining work

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

No known FOLD-GAP failure remains. The two opt-in checks above were not run.
Lead review and the merged release gate remain with the lead.
