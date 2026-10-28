# A finished live turn folds without a scroll (0.1.135)

Workstream `dev/a135-turnfold`, based on release candidate `a20a317f`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a135-turnfold`.
All app runs use the isolated `com.belloware.PiAppTests.Host`, generated journals,
and loopback fixtures. No installed app, real chats, credentials, or paid requests.
The lead reviews and merges; this branch does not release or publish.

Owner, 2026-10-28, reporting 0.1.131:

> "the expected behavior is that I don't need to scroll up to load more to have the tool result being collapsed. It should be collapsed by default."

## Reproduction on a20a317f

Production sources were unchanged for the failing-first runs. The new tests use
sixty tool calls and their results, then watch the final answer arrive without a
reader scroll or load request.

| Path | Baseline |
| --- | --- |
| New chat, first snapshot after the question left the live suffix | Reproduces: 60 scripted rows / 61 real helper rows, no question, no fold |
| Freshly adopted edit/resend branch, same delayed first observation | Reproduces: 60 scripted rows / 61 real helper rows, no question, no fold |
| A finished partial first turn followed by a newer running turn | Reproduces: 62 scripted rows, first `r30`, no fold |
| New chat observed from its question through overlapping snapshots | Passes: 122 scripted rows, one fold |
| Ordinary real send and edit/resend observed early | Both pass: 243 / 244 rows, one fold |

The scripted cases exercise `WorkspaceModel.refresh` with the existing synthetic
host. `failing-first-3.log`: **4 tests, 1 passed / 3 failed, 9 assertions**.
The real cases use `StreamedReplyEndTests` and `ui-gateway.py`: sixty local README
reads, a barrier before the answer, and a streamed answer. Delaying the first
snapshot models a coalesced tool burst or late edit acknowledgement; the app
observes the running suffix before the answer is released. `baseline-gateway-late.log`:
**2 tests failed, 7 assertions**, including a new-chat settlement assertion while
its question is absent. Early-observed controls: `baseline-gateway-2.log`, **2/2**.

Initial test-development logs are also retained: `failing-first.log` did not
compile (fixture Sendable captures and a missing branch field);
`failing-first-2.log` additionally had a non-overlapping early-control sequence,
corrected in the primary run above. `baseline-gateway.log` was interrupted after
a fixture chat ID containing a space failed before sending; the corrected IDs
are used above. These are not product reproduction evidence.

## Cause and design

SCROLL-1 made history reads and resident eviction respect display turns, but the
helper's live snapshot still contains at most three turns / sixty rows within its
256 KiB preference. A fresh window may therefore first receive a suffix without
the question. Subsequent deltas preserve that suffix. The fold correctly refuses
to hide an unidentified partial turn. The existing extent recovery reads a whole
page for positions but does not adopt its missing rows. A reader's later history
load used to be the first operation that restored the question and made the turn
fold.

The app now completes that missing prefix automatically when the cut first turn
finishes, including when a newer turn is already running. The viewport-ready
path also covers a turn that finished before its first presentation. It reuses
`loadHistoryPage` for one bounded whole-turn read, source/navigation validation,
accounting, resident limits, and the native reader's existing anchor. Only the
missing first turn is admitted; an older unrelated turn in that read is discarded.
If the completed turn and later turns cannot coexist within the resident budget,
the first turn leaves whole while the newer reading position stays resident.
A turn that alone exceeds the resident row/byte caps remains incomplete and
unfolded, as previously decided (Known item 2).

This is smaller than extending the helper projection: no helper, wire, page caps,
fold rules, or disclosure state change. The helper's per-token projection remains
bounded at sixty settled rows and still sends deltas. The app's completion check
uses a cached membership/run key; repeated tokens do not scan the long turn or
repeat its history read. A running turn retains its rows, and an opened fold
keeps its existing disclosure choice.

The native no-jump test exposed a second part of the same completion: bringing
back the question removes the footer's "Partial history" note. Its height falls
from 124 to 106 points, which moved an answer being read at the end down by
18 points. The document now holds that released height as space below the same
footer. If folding makes the entire turn shorter than the viewport, the spare
room stays above the turn, keeping the short answer at the same screen position.
Both spaces are released on a new tail or presentation. No extra row is
shown; the completed footer loses its obsolete note and the answer stays put.
A reader inside the newer turn continues to use the existing visible anchor.
Steady token updates add only constant checks; completion layout can reposition
the rows once when the folded turn no longer fills the viewport.

## Validation

All commands run from the worktree with:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-turnfold
```

The first build used:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testNewChatLongTurnFoldsWithoutReaderLoad \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testEditBranchLongTurnFoldsWithoutReaderLoad \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testCutFinishedTurnFoldsWhileANewerTurnRuns \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testLongTurnObservedFromItsQuestionFoldsWithoutReaderLoad
```

Subsequent builds and runs use the same products and explicit arguments:

```sh
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  -parallel-testing-enabled NO -only-testing:PiAppTests/<Class-or-Class/method>
# After a successful build, replace `test` with `test-without-building`.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_ui_gateway
```

Each class runs alone. Exact expanded argument arrays are at the start of the
focused/final logs; the runner and selectors are in `baseline-gateway.py`,
`fixed-focused.py`, `final-checks.py`, `restored-checks.py`, and
`completion-checks.py` under the build root.
Focus/gallery runs hold the shared lock and release it in `finally`; builds wait
for other workstreams' performance/soak locks. No full native/helper lanes ran.
The helper is unchanged, so helper and wire/concurrent/acceptance reruns are not
required. The real app integration cases use the staged Release helper built by
`scripts/test-macos.sh`.

Initial fixed checks: scripted **4/4** (`fixed-scripted.log`); real helper/gateway
**4/4** (`fixed-gateway.log`). The native checks use the actual conversation pane
and journal reader, measure the reading row on every drawn frame, count automatic
versus reader loads, and verify that the current live tail survives the read.
They wait for Jump to latest's 350 ms animation before measuring and send no
scroll gesture during the fill.

Before the footer fix, `final-LongTurnPagingTests.log` recorded **7 tests, 5 passed /
2 failed**: the following reader and the opened fold each moved about 18 points.
The newer-turn reader stayed put. With the spacing fix, `geometry-diagnostic.log`
recorded **3/3**: following-end row -604.05 → -604.00 pt, opened fold -604.05 →
-603.75 pt, newer-turn row -120.006 → -120.000 pt (one-point tolerance throughout).
The short-answer check then reproduced a further clamp: the answer jumped
487.87 → 327.00 pt when the folded page became shorter than the viewport
(`short-answer-before.log`, **1 failed test / 2 assertions**). With spare room
above the turn it stays at 488.00 pt. All four geometry cases pass in
`geometry-final.log`. The tests also check that the footer space is 18 pt, is
absent for the newer reader, and that both spaces are released when another
question arrives.

## Mutations

- Make `fillFinishedTurn` return for every real chat (`guard id.isEmpty else {
  return }`): `testCutFinishedTurnFoldsWhileANewerTurnRuns` fails **1 test / 3
  assertions** (`mutation2-scripted.log`); the native
  `testFinishedTurnFillKeepsAReaderInTheNewerTurnStill` also fails **1 / 3**
  (`mutation2-geometry.log`). Both miss the question/fold/automatic read.
- Remove `+ completionBottomSpace` from document height: the native
  `testFinishedTurnFillKeepsTheFollowingReaderAtTheEnd` fails **1 test / 2
  assertions**, detecting the 18.05-point jump on every settled frame
  (`mutation-footer.log`).

- Force the spare room above a short completed turn to zero: the native
  `testFinishedTurnFillKeepsAShortAnswerAtTheEnd` fails **1 test / 2 assertions**,
  detecting the 160.87-point jump (`mutation-short.log`).

All three mutations were restored before the final run. The first mutation attempt was
an unconditional `return`, rejected at compile time by warnings-as-errors;
`mutation-scripted.log` is not counted as a caught mutation. The valid selectors
above were rebuilt with the `xcodebuild test` command; the second native selector
used those products with `test-without-building`. Scripts `mutation.py`,
`footer-mutation.py`, and `short-mutation.py` in the build root preserve and restore
the production files.

## Gallery

The `LongTurnPagingTests` gallery run set
`TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/turnfold-gallery"` and captured
`finished-turn-{light,dark,narrow-light,narrow-dark}.png` from the actual pane
at 900 and 520 pt widths. All four were opened and inspected: the sixty-call
fold is closed, the answer and completed footer are visible, and the partial
history note is gone, with no clipping or overlap. This retains the existing
one-point slots for folded rows (`TranscriptRowContainer.swift:695`), so the
sixty-call scene still has space above its answer; this task does not change
fold row layout. The fixture's retained-history project notice is expected.

## Final focused runs

The class runs use this exact argument set, one class per test process (the
Python runners add log capture and the shared focus lock):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-turnfold
X=(-project PiApp.xcodeproj -scheme PiApp
   -destination 'platform=macOS,arch=arm64'
   -derivedDataPath "$PI_BUILD_ROOT/native-tests"
   CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO
   -parallel-testing-enabled NO)
TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/turnfold-gallery" \
  xcodebuild test "${X[@]}" -only-testing:PiAppTests/LongTurnPagingTests
classes=(
  TranscriptTurnFoldTests StreamedReplyEndTests TranscriptPagingTests
  HistoryTurnPagingTests HistoryExtentTests FreshPresentationTests
  TranscriptOpeningFillTests HistoryEditTests MessageVersionTranscriptTests
  WorkspaceRefreshLifecycleTests WorkspaceLoadingTests HistoryEdgeTests
  TranscriptRevealTests TranscriptFindTests StreamingDeliveryCostTests
  TranscriptIncrementalTests InheritedSubagentReaderTests WorkspaceConcurrencyTests
  WorkspaceRaceTests WorkspaceDisplayMemoryTests NativeTranscriptDocumentTests
  NativeTranscriptScrollTests NativeTranscriptSafetyTests NativeTranscriptTests
  TranscriptGeometryCacheTests TranscriptKeptRowsTests TranscriptStreamingScrollTests
  TranscriptStreamingStressTests TranscriptUpdateIsolationTests TranscriptFrameBudgetTests
  TranscriptWidthChangeTests TranscriptPageStressTests
)
for cls in "${classes[@]}"; do
  xcodebuild test-without-building "${X[@]}" "-only-testing:PiAppTests/$cls"
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_ui_gateway
```

The final geometry change reran the ten requested classes, all twelve listed
native document/layout classes, and StreamingDeliveryCostTests
(`completion-<Class>.log`). The other workspace classes are recorded from
`restored-<Class>.log`; their production sources did not change afterward.

Final selected app coverage: **435 passed, 0 failed, 2 optional skips in 33 classes**; Python fixture coverage **27/27**.

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| LongTurnPagingTests | 9 | 0 | 0 |
| TranscriptTurnFoldTests | 26 | 0 | 0 |
| StreamedReplyEndTests | 8 | 0 | 1 |
| TranscriptPagingTests | 11 | 0 | 0 |
| HistoryTurnPagingTests | 6 | 0 | 0 |
| HistoryExtentTests | 26 | 0 | 0 |
| FreshPresentationTests | 21 | 0 | 0 |
| TranscriptOpeningFillTests | 11 | 0 | 1 |
| HistoryEditTests | 3 | 0 | 0 |
| MessageVersionTranscriptTests | 8 | 0 | 0 |
| WorkspaceRefreshLifecycleTests | 46 | 0 | 0 |
| WorkspaceLoadingTests | 13 | 0 | 0 |
| HistoryEdgeTests | 16 | 0 | 0 |
| TranscriptRevealTests | 12 | 0 | 0 |
| TranscriptFindTests | 12 | 0 | 0 |
| StreamingDeliveryCostTests | 4 | 0 | 0 |
| TranscriptIncrementalTests | 12 | 0 | 0 |
| InheritedSubagentReaderTests | 8 | 0 | 0 |
| WorkspaceConcurrencyTests | 12 | 0 | 0 |
| WorkspaceRaceTests | 65 | 0 | 0 |
| WorkspaceDisplayMemoryTests | 2 | 0 | 0 |
| NativeTranscriptDocumentTests | 10 | 0 | 0 |
| NativeTranscriptScrollTests | 5 | 0 | 0 |
| NativeTranscriptSafetyTests | 5 | 0 | 0 |
| NativeTranscriptTests | 5 | 0 | 0 |
| TranscriptGeometryCacheTests | 7 | 0 | 0 |
| TranscriptKeptRowsTests | 10 | 0 | 0 |
| TranscriptStreamingScrollTests | 3 | 0 | 0 |
| TranscriptStreamingStressTests | 15 | 0 | 0 |
| TranscriptUpdateIsolationTests | 8 | 0 | 0 |
| TranscriptFrameBudgetTests | 6 | 0 | 0 |
| TranscriptWidthChangeTests | 6 | 0 | 0 |
| TranscriptPageStressTests | 24 | 0 | 0 |
| Python `scripts.tests.test_ui_gateway` | 27 | 0 | 0 |

The two pre-existing opt-in skips are the timed streamed-reply interference
stress (`PI_STREAM_STRESS_SECONDS`) and the opening-fill gallery
(`PI_OPENING_GALLERY`). The turnfold gallery above was enabled and inspected.
The final LongTurnPagingTests run is `longturn-final.log` (9/9), after adding a
short-newer-answer control: it stays at 630.00 pt before and after completion,
using the existing reader anchor; no additional production change was needed.

## STREAM-1 and remaining observations

The snapshot and transport are unchanged. The native isolation tests still prove
that a token visits only its changed presented/document rows. Debug-only output
from `completion-StreamingDeliveryCostTests.log` (300 resident fixture rows):
190-byte row-update frame; encode 0.018 ms, decode 0.167 ms, apply 0.013 ms,
merge/compare 0.001 ms, regroup 0.062 ms. Forty refresh deltas publish at a median
0.58 ms / maximum 5.34 ms; these **Debug figures are not Release speed evidence**.
No snapshot-size change was made, so no new STREAM-1 snapshot benchmark is needed.

Two earlier focused runs (`final-StreamingDeliveryCostTests.log` and
`restored-StreamingDeliveryCostTests.log`) each failed the projection-visit
assertion once: 301 visits instead of at most 1 in the 40-delta refresh test.
The other three tests passed. This was not ignored or patched: restoring all
four production files to `a20a317f` and rebuilding gave **4/4 twice**
(`baseline-delivery-{1,2}.log`), and the fixed code subsequently gave **4/4**
both alone (`delivery-isolated-final.log`) and at the end of the final class run.
`baseline-delivery.py` temporarily omitted only the new native-field assertions
from the unselected geometry tests so the baseline app could compile, then
restored all files. The initial count intermittency remains unclassified; these
passing reruns do not establish its cause or prove it is a baseline failure.
The active capture remained present (`replayd` observed at 88% CPU). None of the
four machine-note suites was run, and this count assertion is not attributed
to the known capture failures.

Known item 2 is unchanged: a turn exceeding the resident 3,000-row / 24 MB budget
may still be cut and unfolded. There is no outstanding failure in the selected
final runs. Lead review and the merged release gate remain with the lead.

