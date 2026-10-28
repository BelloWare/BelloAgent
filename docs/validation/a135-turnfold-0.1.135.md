# A finished live turn folds without a scroll (0.1.135)

Workstream `dev/a135-turnfold`, based on release candidate `a20a317f`.
Round 1: `1a7e29e5`. Round 2 implements the lead's F1/F2 review of that commit.
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
uses a cached membership/run key, so repeated tokens do not scan the long turn.
Round 2 also remembers a returned completion page by **read generation and cursor**,
before checking its turn start or resident caps. A page that cannot be adopted
therefore still consumes that boundary's one automatic completion read. An
existing older-boundary error blocks completion reads; the reader's Retry owns
that boundary. The error and memo guards are checked again after an opening fill
has been awaited. Cancellation before the page arrives, or a cursor already
changed when it arrives, does not consume the attempt; its membership check is
cleared so it can run again. A new cursor or read generation starts fresh, and
presentation reset clears both completion keys. A running turn retains its rows,
and an opened fold keeps its existing disclosure choice.

Bringing back the question removes the footer's "Partial history" note, reducing
its height from 124 to 106 points. The document retains the released **18 points
below the footer** (`completedFooter` / `completionBottomSpace`) so a following
reader's answer stays still when the chat is taller than the viewport. That hold
ends on a new tail or presentation. Round 2 removes `completionTopSpace` and its
row shift: a short completed turn now starts at `pageTopInset + leadingSpace`,
just as a turn whose question was already present does. Its answer moves up with
the fold; no blank room above the question waits for the reader's next send.
The newer-turn reader still uses the existing visible anchor.

## Round 2 failing first on 1a7e29e5

Production sources were unchanged. Both F1 tests extend the existing
`longLiveTurn` fixture: a 122-row first turn exceeds a 90-row resident test cap;
the loaded suffix has 60 rows, then a newer running turn adds two rows and gains
ten more across **five row-membership deltas**. The older cursor stays `r30`, the
window stays cut and unfolded, and only the newer rows are added (62 → 72 rows).
Completion reads are counted separately from the existing extent read.

| New test | Round 1 result | Round 2 result |
| --- | --- | --- |
| `testFinishedTurnPastTheResidentCapIsReadOnceWhileANewerTurnGrows` | **6** completion reads, expected 1 | **1** |
| `testFinishedTurnBoundaryErrorWaitsForReaderRetry` | **6** completion reads, expected 0; boundary error erased | **0**; exact error preserved |

`round2-failing-F1-2.log`: **2 failed tests / 3 assertions**.
`round2-fixed-F1.log`: **2/2 passed**. The initial fixture-development log,
`round2-failing-F1.log`, omitted the row-order field required for membership
deltas and did not add rows; it is not the repeat-read reproduction evidence.

The F2 replacement, `testFinishedTurnFillLaysOutAShortTurnFromTheTop`, also fails
on round 1: first row **173 pt**, expected **12 pt**, and the document is stretched
to the 681-pt viewport (`round2-failing-F2.log`: **1 failed test / 2 assertions**).
It passes after removing the top hold. `testFinishedTurnFillKeepsAShortNewerAnswerAtTheEnd`
remains and passes: its answer stays at **630.00 → 630.00 pt**.

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
Round 2's `round2-LongTurnPagingTests.log` preserves these checks: following-end
row **-604.05 → -604.00 pt**, opened fold **-604.05 → -603.75 pt**, newer-turn
reader **-120.006 → -120.000 pt**. The short completed turn now lays out from
the top, moving its answer **487.87 → 327.00 pt** with the fold. The tests retain
the 18-pt footer assertion, its absence for the newer reader, and its release on
a new question. They assert the normal first-row inset before that next question.

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

- Round 2: remove the assignment to `finishedTurnRead` after the page arrives.
  `testFinishedTurnPastTheResidentCapIsReadOnceWhileANewerTurnGrows` fails with
  **6 reads instead of 1**. The errored-boundary test still passes:
  `round2-mutation-F1.log`, **2 tests, 1 passed / 1 failed, 1 assertion**.

All mutations were restored. The first round-1 attempt was an unconditional
`return`, rejected at compile time by warnings-as-errors; `mutation-scripted.log`
is not counted as a caught mutation. The valid round-1 scripts are `mutation.py`
and `footer-mutation.py`; round 2's `round2-mutation.py` restores the source in
`finally`, and the subsequent full WorkspaceRefreshLifecycleTests run rebuilds
those restored products.

## Gallery

Round 2's `LongTurnPagingTests` run set
`TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/turnfold-gallery-round2"` and
regenerated `finished-turn-{light,dark,narrow-light,narrow-dark}.png` from the
actual pane at 900 and 520 pt widths. All four were opened and inspected: the
question is at the top inset with **no completion room above it**, the sixty-call
fold is closed, the answer and completed footer are visible, and the partial
history note is gone. No clipping or overlap. The retained-history project
notice is expected for the generated fixture.

Geometry logged at each capture (`round2-LongTurnPagingTests.log`, document
coordinates in points):

| Gallery | First row top | Fold row bottom | Answer row top | Gap | Folded rows |
| --- | ---: | ---: | ---: | ---: | ---: |
| Light / dark, 900 pt | 12 | 134 | 327 | 193 | 193 |
| Narrow light / dark, 520 pt | 12 | 158 | 351 | 193 | 193 |

The light PNGs also measure **205 pt of visible blank space** from the drawn
divider's bottom to the answer's first glyph scanline: wide pixels 252 → 662,
narrow pixels 300 → 710, both at 2× scale (`round2-gallery-pixels.txt`). The
12-pt difference from the row-frame gap is existing internal padding. The
existing gap below the fold is recorded under Known below.

## Round 2 focused runs

Every class runs alone, with parallel testing disabled; the shared focus lock is
held per invocation and released in `finally`. All products and logs remain in
the assigned build root. No machine-note suites, full lanes, or helper/wire
reruns were run. Helper sources and the wire contract are unchanged.

Exact invocation arguments are the first line of every `round2-*.log`, generated
by `$PI_BUILD_ROOT/round2-run.py`. The baseline, fixed, and mutation F1 selections
use `xcodebuild test`; F2 uses the built baseline products. The expanded common
arguments and final class selections are:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-turnfold
X=(-project PiApp.xcodeproj -scheme PiApp
   -destination 'platform=macOS,arch=arm64'
   -derivedDataPath "$PI_BUILD_ROOT/native-tests"
   CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO
   -parallel-testing-enabled NO)
# Fixed products, before mutation; source is identical to the restored result.
TEST_RUNNER_PI_TURNFOLD_GALLERY="$PI_BUILD_ROOT/turnfold-gallery-round2" \
  xcodebuild test-without-building "${X[@]}" -only-testing:PiAppTests/LongTurnPagingTests
# Rebuild after restoring the mutation.
xcodebuild test "${X[@]}" -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests
classes=(
  StreamedReplyEndTests TranscriptTurnFoldTests HistoryTurnPagingTests
  TranscriptPagingTests NativeTranscriptDocumentTests NativeTranscriptScrollTests
  TranscriptStreamingScrollTests TranscriptKeptRowsTests TranscriptWidthChangeTests
  TranscriptGeometryCacheTests
)
for cls in "${classes[@]}"; do
  xcodebuild test-without-building "${X[@]}" "-only-testing:PiAppTests/$cls"
done
for round in 1 2 3; do
  xcodebuild test-without-building "${X[@]}" -only-testing:PiAppTests/StreamingDeliveryCostTests
done
```

`round2-final.py` runs these final non-gallery classes and records each exit in
`round2-summary.json`. **161 passed / 0 failed / 1 optional skip**, across
13 classes (15 isolated invocations, counting the three delivery runs).

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| LongTurnPagingTests | 9 | 0 | 0 |
| WorkspaceRefreshLifecycleTests | 48 | 0 | 0 |
| StreamedReplyEndTests | 8 | 0 | 1 |
| TranscriptTurnFoldTests | 26 | 0 | 0 |
| HistoryTurnPagingTests | 6 | 0 | 0 |
| TranscriptPagingTests | 11 | 0 | 0 |
| NativeTranscriptDocumentTests | 10 | 0 | 0 |
| NativeTranscriptScrollTests | 5 | 0 | 0 |
| TranscriptStreamingScrollTests | 3 | 0 | 0 |
| TranscriptKeptRowsTests | 10 | 0 | 0 |
| TranscriptWidthChangeTests | 6 | 0 | 0 |
| TranscriptGeometryCacheTests | 7 | 0 | 0 |
| StreamingDeliveryCostTests (run 1) | 4 | 0 | 0 |
| StreamingDeliveryCostTests (run 2) | 4 | 0 | 0 |
| StreamingDeliveryCostTests (run 3) | 4 | 0 | 0 |

The one expected skip is `testAStreamedReplyEndsWholeOnScreenUnderInterference`,
which requires the opt-in `PI_STREAM_STRESS_SECONDS` setting. The turnfold
gallery was enabled. No requested class has an outstanding failure.

Round 1's selected coverage was **435 passed / 0 failed / 2 optional skips in
33 classes**, plus **27/27** Python fixture checks; these are historical counts,
not a claim that those broader classes were rerun in round 2. The earlier exact
commands and 33-class table remain in this record at `1a7e29e5`.

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
assertion once: **301 visits instead of at most 1** in the 40-delta refresh test.
In `testRefreshRoundTripOccupancy`, the first row `m0` is a user row that starts
a turn and every reply has `before: null`, so `fillFinishedTurn` returns at its
initial guard. There is no pane, so `NativeTranscriptScrollView` is not involved.
**None of round 1's completion-read or native spacing behavior runs in that test.**

The other three tests passed in each failing run. Restoring round-1 production
files to `a20a317f` and rebuilding gave **4/4 twice** (`baseline-delivery-{1,2}.log`),
and round 1 subsequently gave **4/4 twice** (`delivery-isolated-final.log` and
`completion-StreamingDeliveryCostTests.log`). These passes do not establish the
cause of the 301-visit intermittency or prove a baseline failure. It remains
unclassified and is not attributed to the known screen-capture failures. Round 2
ran the entire class three times alone: **4/4, 4/4, 4/4**, with **0 failures or
skips** (`round2-StreamingDeliveryCostTests-{1,2,3}.log`). None reproduced the
301-visit assertion. The lead reruns it too.

## Known, not changed here

- Folded-away rows retain **one-point slots** (`TranscriptRowContainer.swift:693`,
  estimate at `:283`). The regenerated sixty-call gallery contains **193 folded
  rows**, leaving **193 pt** between row frames (134 → 327 pt wide; 158 → 351 pt
  narrow), or **205 pt** from the drawn fold divider's bottom to the answer text
  in the light PNGs at both widths. This blank space below the fold predates this
  change and is **deferred to 0.1.136**. This round removes
  only the separate room above the question; it does not change folded-row layout.
- As already decided in SCROLL-1 Known item 2, a turn exceeding the resident
  **3,000-row / 24 MB** budget can remain cut and unfolded.

Lead review and the merged release gate remain with the lead.
