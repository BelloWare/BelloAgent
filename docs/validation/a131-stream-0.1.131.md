# STREAM-1: a fragment updates its own transcript rows (0.1.131)

Workstream `dev/a131-stream`, base `dev/next` `9f771ac1`. Build root
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-stream`; text logs below
are relative to it. Generated journals, in-memory vaults and loopback only;
the isolated test host, never the installed app, real chats or Keychain.

The owner's choice on 2026-10-23 was "250 now, 1,000 later": first remove
the cost per resident row from each streamed update, then raise history pages.
SCROLL-1's baseline and method are in [its record](a131-scroll-0.1.131.md).

## Cause and implementation

For every fragment the display mapped every source through the agent overlay,
the activity patch compared every message and searched every planned item,
and the document updated every container and rebuilt its message lookup.
History-position adoption walked the window again. Provisional geometry also
made an otherwise local tail change traverse the unfinished history.

Removing the walks alone was not sufficient: copying the activity array
copied each large enum payload, and admitting the first reply still rebuilt
the whole plan. The intermediate build passed the visit tests but cost
3.1 / 4.7 / 13.4 ms at 300 / 750 / 3,000 rows; delivery stages cost
0.602 / 1.556 / 6.558 ms (`incremental-stream-*`, `incremental-delta-*`).
Those runs had peak loads at or below 2.70. Activity values now share their
immutable payloads (`indirect enum`), retaining value semantics.

The display now retains its projection and source positions. Helper deltas
are applied to the resident rows off the main actor, with the display and
accounting revisions checked when they land. Cosmetic fragments update only
their projected sources. A bounded index-only change log lets a page or
document skip presentations and take the union of the intervening edits;
an expired log or changed row order takes the complete reconciliation.
The activity planner retains source-to-item membership. The document updates
those items and keeps its message index and all other native containers.
A new source or response part replans the affected display turn, including
the context needed by its task summary, tool-result pairing and whole-turn
fold. The prefix and its native containers survive. Ambiguous pairing,
expired change logs, history replacement and changed projection context
retain the complete path. Partial placement preserves the existing
provisional geometry above the changed row. Detached reading anchors use
the document's existing frame index rather than scanning the history.

The native document tracks disclosure/input ownership by reference count,
so removing a tail prunes its stale keys without forgetting a bare tool ID
also owned by the prefix. Find and selection keep their native text storage.
Live task requests receive changed sources even when the live bar's visible
figures are unchanged.

## Page size

After the quiet streaming sweep below passed, raised the shared policy to
**1,000-row / 4 MiB pages, 3,000 rows / 24,000,000 bytes resident**. Whole-turn
boundaries and the existing live snapshot limits are preserved. The helper
and app byte-weight regressions keep their original explicit 6 MB fixture
boundary, so increasing the default does not weaken those reproductions.

## Failing first

- `TranscriptUpdateIsolationTests`: **2 tests, 12 assertion failures**
  (`failing-visits.log`). Each of the projection, activity-message,
  activity-item and native reconciliation stages inspected 301 / 751 /
  3,001 rows for one changed source, rather than one or two. The tests
  drive the display's `replaceMessage` boundary (initially the old setter).
- Helper `HistoryWindowTests.testAThousandRowPageReadsFourThousandRowsInFourWholeTurnLoads`:
  **1 test, 24 assertion failures**, before the paging change
  (`helper-failing-page-debug.log`). The 4,000-row fixture needed 20 loads of
  200 whole-turn rows, against the target four loads of 1,000; its byte and
  resident budgets were also too small.
- `TranscriptIncrementalTests.testAPartialPlacementKeepsUnresolvedHistorySliced`:
  **1 test, 2 assertion failures** (`slice-failing-first.log`). A local edit
  near the start of a 1,000-source chat measured **1,442 native rows** and
  left just 34 estimated rows. The partial-placement optimization had
  assumed its suffix was already measured. It now counts the unresolved
  suffix and retains the viewport measurement band; the unchanged prefix
  still needs no visit. This also addresses the multi-second reading pause
  reproduced in the preliminary normal-chat probes below.

An initial Release helper-test build could not compile the unrelated
`SideOriginIndexTests` because `SideOriginReadProbe` is Debug-only
(`helper-failing-page.log`). Helper validation therefore uses Debug, as
`scripts/verify-release.sh` does; performance validation uses Release app
products. The first attempt also caught a missing `forward:` argument in
the new test; corrected before the failing assertion run above.

The first structural-tail check found a runtime exclusivity conflict in
the cached projection's `replaceSubrange` bounds. Locals now separate the
read and modification; the rerun passed all 31 core tests
(`structural2-Transcript{UpdateIsolation,Incremental,RowUpdate,Activity}Tests.log`:
8 + 7 + 5 + 11). The new-part test compares the incremental result with
the complete planner through prose, reasoning, preparing/running tools,
completion and task receipts in both normal and compact display modes.

The broader retention check then caught a copied snapshot whose messages
and items were replaced without recording an edit: the inherited empty
change stamp incorrectly skipped native reconciliation
(`structural-TranscriptVisibilityTests.log`, 1 test, 4 failures). A native
incremental adoption now requires an advanced stamp. The page records an
empty edit when it has actually proved an unchanged plan at a new task
revision; copying a snapshot alone provides no such proof.

Mutation checks (`mutation-visits.log`): disabling the projection cache,
the document hint, the activity changed-source hint and the document tail
hint each failed the intended test. Projection / document / activity:
1 test and 3 assertion failures each; tail: 1 test and 9 failures. Restored
code had already passed the corresponding 31-test core run above.

Physical code mutations with the new storage and snapshot proof
(`mutation-code-{copy,proof}.log`): omitting the unique-copy check failed the
single-thread nested-copy test with **5 assertions**; omitting the advanced
stamp guard failed the history replacement test with **4 assertions**.
Restored both fixes before the final build. Restoring 250-row pages failed
the new helper paging test with **21 assertions** (`mutation-paging.log`),
then restored 1,000 rows before rebuilding either final product.

The final cache mutations (`final-mutations-five.log`) also catch removing
the empty-edit proof for a revision-only task presentation: **1 test,
1 assertion**. Disabling the frame index before each fragment below a
detached reader fails the new anchor-visit check: **1 test, 1 assertion**
(`final-mutation-anchor.log`, peak 3.14). Combined mutation runs above load
4 were discarded; non-timing visit checks then ran serially, and the
streaming anchor case was repeated under the perf lock. Intentional
failures use `-collect-test-diagnostics never` for the final timing runs,
avoiding an unrelated system-diagnostic capture after the assertion.

Removing the idle-batch minimum failed the existing history-placement
check: **1 test, 1 assertion**, 443 placement passes versus a ceiling of
363 (`mutation-idle.log`, Release, perf-lock peak 2.83). The final normal
code uses 246 passes in that fixture. Disabling slicing on partial passes
failed the new unresolved-suffix reproduction again: **1 test, 2
assertions** (`mutation-slice.log`). All **11 mutation checks** were caught;
restored the production file and rebuilt Release successfully
(`mutation-slice-restored-build.log`) before committing.

## Measurements and checks

Unfixed Release, base plus visit instrumentation (`before-300.log`,
`before-750.log`, `before-3000.log`):

| resident fixture rows | 300 | 750 | 3,000 |
|---|---:|---:|---:|
| display to drawn document, mean | 8.4 ms | 17.0 ms | 60.7 ms |
| worst | 14.6 ms | 24.1 ms | 91.3 ms |
| apply + merge + activity patch | 1.768 ms | 4.480 ms | 19.299 ms |

The 300-row delivery budget fails at 1.768 ms against its unchanged 1 ms
Release ceiling. At 3,000 rows the original document probe also exceeds
its 50 ms mean ceiling. Each run executed the streaming document method
and the delivery-stage/refresh methods (3 tests); the valid peak loads
were 3.09 / 3.31 / 3.34. Two 3,000-row attempts had peaks 4.56 and 4.08
and were repeated (`before-3000-busy-1.log`, `-busy-2.log`).

The baseline refresh's 3,000-source fixture still had the old 750-row cap,
so its nested overlap search spent about 297 ms publishing each token.
That is not a 3,000-resident-row comparison and is excluded from the table.

The first valid structural delivery run at 300 rows passed the unchanged
1 ms ceiling: apply 0.067 + merge 0.006 + regroup 0.148 = **0.221 ms**;
refresh median 0.88 ms (`structural2-delta-300.log`, peak load 3.41).
Its preceding attempt and the first 750-row GUI attempt exceeded load 4
and were discarded. A concurrent Release compiler continued through this
period; subsequent timing preflight waits for existing compilers as well
as low load.

The next quiet structural sweep (`structural3-*`, peak loads 2.46–3.09)
reduced the real path to 4.4 / 2.4 / 2.4 / 4.0 ms at 300 / 750 / 1,000 /
3,000 fixture rows. The first run still paid cold native text work. The
3,000-row model's remaining 1.5 ms, versus 0.4–0.5 ms at the smaller sizes,
exposed another cost: arrays of the wide `TranscriptMessage` value copied
all their neighbours' fields when changing one element. The message value
now privately shares its fields and takes a unique copy only on mutation.
Its custom Codable forwarding keeps the existing flat representation;
nested edits and independent task copies have explicit value-semantics
checks. This retains the source-facing value API.

The same sweep's delivery stages cost 0.087 / 0.199 / 0.261 / 0.985 ms.
The 3,000-row refresh fixture still exceeded the old production window and
reported one 749-row reprojection; it was not holding a 3,000-row window.
That probe now explicitly holds its requested fixture whole, so its final
timing measures streaming rather than trimming/reacquiring a smaller window.

The complete shared-fields implementation then passed **37 focused tests**
(10 incremental/value-semantics, 3 visibility, 8 isolation, 5 row update,
11 activity), including independent task copies, the flat Codable shape,
the history replacement regression and a revision-only update visiting no
native rows (`sharing-Transcript*Tests.log`).

Quiet shared-fields sweep, still before increasing the default policy
(`sharing-{stream,delta}-{300,750,1000,3000}.log`, peak loads 2.49–2.83):

| fixture history rows | 300 | 750 | 1,000 | 3,000 |
|---|---:|---:|---:|---:|
| display to drawn document, mean | 2.2 ms | 2.1 ms | 2.1 ms | 2.3 ms |
| model work | 0.1 ms | 0.2 ms | 0.2 ms | 0.3 ms |
| reply to publication, median | 0.33 ms | 0.51 ms | 0.41 ms | 0.57 ms |

The final delivery-stage benchmark also uses the page's local tail planner
for first content (previously its isolated fallback planned the whole
fixture once, amortized over 60 deltas). It checks the final result against
the complete planner and retains the original 1 ms Release ceiling.

## Final validation

Release helper built and staged with `python3 scripts/build-bundle.py`.
The focused history-paging wire case passed **1 test**
(`final-wire-history.log`). Focused helper history classes passed **106
tests, 6 skipped, 0 failures** (`final-helper-history.log`):
`HistoryWindowTests`, `FullDisplayTests`, `OlderRowsTests`,
`JournalCheckpointTests`, `HistoryFillTests`, `HistoryReadCancellationTests`,
`ForkCloneTests`, `SessionOpenPerformanceTests`, `ConversationReadTests`,
`CommandReceiptsTests`, `DurableReplayTests`, `MessageVersionTests`,
`TimelineDurabilityTests`.

The app measurements use Release `-O` with single-file compilation and two
compiler jobs; the original baseline used the standard Release whole-module
build. Both use the same isolated build-for-testing host. The visit-count
assertions and within-build size sweep establish the bounded work
independently of that compilation-mode difference. macOS 14.8, Xcode 16.1
(16B40), Swift 6.0.2, arm64, 10 cores / 16 GB.

The preliminary broader pass (`structural-app-summary.txt`) ran 432 tests,
2 skipped, with 17 assertion failures under load (peak 19.08). Four were
the snapshot replacement regression described above. The other failures
were scroll/drag timing limits and SCROLL-1's previously recorded
`testACardAndReasoningMoveOnTheSameCurve` animation case. The final quiet reruns below replace that loaded evidence.

Every timing-sensitive run holds the full-lane lock with `perf` in its
owner line. `runs.txt` records the exact commands, start/end load,
peak one-minute load sampled every five seconds, and exit status. Runs
above load 4 are retained with a `-busy-N` suffix and repeated.

## Final streaming result

`slice-fixed-stream-{300,750,3000}.log`,
`slice-fixed-delta-{300,750,3000}.log` (after preserving suffix slicing):

| fixture history rows | 300 | 750 | 3,000 |
|---|---:|---:|---:|
| before: display → drawn, mean | 8.4 ms | 17.0 ms | 60.7 ms |
| after: display → drawn, mean | **2.2 ms** | **2.1 ms** | **2.8 ms** |
| after: worst | 3.2 ms | 3.1 ms | 8.0 ms |
| before: apply + merge + activity | 1.768 ms | 4.480 ms | 19.299 ms |
| after: apply + merge + activity | **0.029 ms** | **0.034 ms** | **0.052 ms** |
| after: reply → published, median | 0.34 ms | 0.43 ms | 0.67 ms |

The real path remains in the same 2–3 ms band across a tenfold increase in
history. At 3,000 rows it is below both SCROLL-1's old 60-row opening cost
(3 ms) and 500-row full-window cost (12.2 ms). The unchanged default
300-row delivery ceiling is 1 ms; the final implementation also passes it
at 3,000 rows. Each size ran one native streaming test and two delivery
methods: **9 tests, no failures**. Valid peak loads were 2.29 / 2.43 / 2.75.
The refresh maxima (2.26 / 4.18 / 15.82 ms) include the initial complete
page, before any deltas; the subsequent fragments each project one row.

The fixture names count prior history rows and add one live reply, as in
SCROLL-1. The refresh probe explicitly holds that complete fixture rather
than trimming it to a smaller policy window. Actual production paging and
resident limits are exercised by the separate paging classes and probes.

## Reading measurements

Same SCROLL-1 generated journals and 120 pt/frame gestures. Opening probe
`slice-fixed-read-open-30.log`; gestures
`slice-fixed-read-turn-30-{1,2}.log`, `slice-fixed-read-turn-120.log`,
`slice-fixed-read-normal-400.log`. All reached both ends; all windows
started at a turn boundary; no rows were lost. Valid peak loads: 2.77 / 2.97 / 2.95 / 3.22 /
3.17. SCROLL-1's 250/750 measurements are comparisons from its record.

| tool-heavy, 30 turns / 2,880 rows | SCROLL-1 250/750 | STREAM-1 1,000/3,000 |
|---|---:|---:|
| first rows (journal ready) | 320 / 323 ms (256 / 259) | 527 ms (414) |
| initial window | 206 rows, from turn 28 | 974 rows, from turn 20 |
| earlier page read; main-thread landing, mean | 28 ms; 55 ms | 158 ms; 149 ms |
| up: loads; time; p95 | 19 / 19; 4.1 / 4.1 s; 69 / 69 ms | 3 / 3; 9.8 / 10.1 s; 43.2 / 44.2 ms |
| up: frames >50 ms; jumps; lost | 19 / 19; 0 / 0; 0 / 0 | 5 / 8; 0 / 0; 0 / 0 |
| down: loads; time; p95 | 17 / 17; 3.0 / 3.0 s; 61 / 60 ms | 0 / 0; 2.6 / 2.7 s; 28.1 / 29.6 ms |
| down: blank frames / jumps | 13 / 15; 0 / 0 | 0 / 0; 0 / 0 |
| footprint after both gestures | +29 / +21 MB | +62.3 / +72.1 MB |

The direct opening/read-back probe holds the entire 2,880-row chat after
**two earlier reads**, and ends at +80.2 MB footprint (+43.9 MB at first
rows). Its 1,000-row helper page decode costs 24.5 ms mean / 29.4 ms max
on the main thread. Gesture
load events include their initial load; use the gesture counter for the
comparison, consistent with SCROLL-1. The larger window reads more at
once and uses more memory; its longer up gesture traverses the larger
initial estimated document while the estimates settle.

Tool-heavy **120 turns / about 11,500 rows**: up **12 loads** (was 91),
18.6 s, p95/max 44.6/165.1 ms, no jumps/lost/blank frames; down **9 loads**
(was 91), 10.8 s, p95/max 30.6/163.2 ms, 7 blank frames (was 58), no
jumps/lost rows. Largest window 2,990 rows; footprint after both +50.8 MB.

Normal **400 turns / 2,000 rows**: initial window 815 rows (the byte budget
binds before 1,000). Up **2 loads** (was 7), 137.9 s, p50/p95/p99/max
16.7/25.7/41.3/133.3 ms, 26 frames over 50 ms; down **0 loads** (was 5),
134.6 s, p95/p99/max 20.0/22.9/105.0 ms, 12 frames over 50 ms. Both
directions had zero jumps, lost rows and blank frames.

Before the suffix-slicing correction, two quiet normal-chat runs paused
for **7.66 s** and **9.06 s** in one upward interval, while bulk native
measurement ran outside the probe's explicit draw step
(`read-normal-400.log`, `read-normal-400-repeat.log`). The failing-first
partial-placement reproduction above isolated that work. The final
normal-chat maximum is **133 ms**; neither direction has a multi-second
pause. Sliced measurement retains unresolved history while it moves,
rather than measuring that entire suffix at once.

## App checks, visual review and remaining observations

The 42-class final pass ran **456 tests, 2 skipped**, with 7 assertion
failures: 4 in the previously recorded card/reasoning curve case; 1 in idle
history batching; 2 from one Find reveal during a high-load period.

The faster partial placement shortened the adaptive idle unit below one
native measurement, yielding 417 placement passes for 726 estimated rows
(`final-TranscriptStreamingStressTests.log`). Reconciliation now measures
for at least two scheduler allowances before placing the batch, while a
costly row still ends the unit alone. The existing test passes unchanged:
**235 passes**, 391 ms layout / 774 ms measuring, 5.7 s to exact history
(`corrected-TranscriptStreamingStressTests.log`).

After that correction, the affected 12 classes ran **76 tests, no failures**
under the perf lock, peaks 2.23–2.58: streaming stress 15, Find 12, native
document 10, native scroll 5, geometry cache 7, deferred views 3, height
sampling 1, streaming scroll 3, timeline streaming 2, long-chat scroll 6,
idle scheduler 6, frame budget 6. This includes the new 3,000-row detached
reader test, first/new reply admission, skipped presentations, selection,
Find storage/highlights and raw helper delivery revision guards.

After preserving slicing in a partially placed suffix, the affected 12
classes passed **85 tests, no failures** (`slice-fixed-*Tests.log`), adding
the 11-test incremental class to the relevant geometry, scroll, Find,
idle and frame-budget coverage. Timing-sensitive classes ran under the
perf lock with peaks at or below 3.23; the functional runs peaked at 3.39.
The new regression itself fell from 9.0 s to 0.14 s.

Using the latest result per class: **44 classes / 469 unique app tests**,
2 skipped, **1 known failing test / 4 assertions**. `final-counts.txt`
lists each class and count; `final-app-summary.txt`, `corrected-*.log`
and `slice-fixed-*Tests.log` preserve the passes and corrections. Gallery cases: **5 tests passed**
(`slice-fixed-gallery.log`), 24 PNGs regenerated and inspected in `gallery-rows/screenshots` and `gallery-bugs` (light, dark,
narrow; folds, reasoning, cards/diffs, saved replies, Find highlights and
summary/agent rows). No new clipping or overlapping rows in these scenes.

Remaining observations:

- `TranscriptDisclosureTests.testACardAndReasoningMoveOnTheSameCurve`
  still fails four assertions in the quiet Release run (peak 2.61). The
  same case failed on unmodified `dev/next` in SCROLL-1's independent
  baseline, documented in its “Unrelated failures” section. No animation
  implementation was changed here.
- Before preserving suffix slicing, `read-turn-30-2.log`, up frame 320,
  showed one 111.5 pt correction while estimates settled. It did not recur
  in either final 30-turn repeat or the final 120-turn run; each has zero
  jumps. All streamed row-stability assertions also pass.

## Reproduction commands

All commands run from this worktree with the exported `PI_BUILD_ROOT`.
The coordinator checks the shared lane before heavy work, holds it for
focus/timing runs, writes an owner containing `perf` for measurements,
records start/end/peak `vm.loadavg`, and repeats any peak above 4. `runs.txt`
is the exact argv/load/exit ledger; files suffixed `-busy-N` are discarded
measurements, not passes.

```sh
xcodegen generate --quiet
python3 scripts/build-bundle.py
xcodebuild build-for-testing -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -jobs 2 \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES COMPILER_INDEX_STORE_ENABLE=NO \
  SWIFT_COMPILATION_MODE=singlefile 'OTHER_SWIFT_FLAGS=$(inherited) -j2'
# Each focused class runs alone; substitute the class from final-counts.txt.
xcodebuild test-without-building \
  -xctestrun "$PI_BUILD_ROOT/native-tests/Build/Products/PiApp_macosx15.1-arm64.xctestrun" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptStreamingStressTests
# Same command, selected method, with these test-runner variables:
# TEST_RUNNER_PI_PERF_ROWS=300|750|1000|3000
#   TranscriptFrameBudgetTests/testWhereAStreamingDeltaSpendsItsTime
# TEST_RUNNER_PI_DELTA_ROWS=300|750|1000|3000
#   StreamingDeliveryCostTests/testPerDeltaStageCostsWithRowUpdates
#   StreamingDeliveryCostTests/testRefreshRoundTripOccupancy
# TEST_RUNNER_PI_TURN_PROBE=1 [TEST_RUNNER_PI_TURN_PROBE_TURNS=120]
#   LongTurnPagingProbeTests/testProbeOpeningAndReadingBack
#   LongTurnPagingProbeTests/testProbeGestureToTheFirstMessageAndBack
# TEST_RUNNER_PI_LONG_PROBE=1 TEST_RUNNER_PI_LONG_TURNS=400
#   LongChatScrollProbeTests/testProbeGestureUpAndDown
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 2 \
  --filter 'PiAgentCoreTests\.(HistoryWindowTests|FullDisplayTests|OlderRowsTests|JournalCheckpointTests|HistoryFillTests|HistoryReadCancellationTests|ForkCloneTests|SessionOpenPerformanceTests|ConversationReadTests|CommandReceiptsTests|DurableReplayTests|MessageVersionTests|TimelineDurabilityTests)'
python3 scripts/test-native-host.py \
  "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" \
  NativeIntegration.test_a_result_beyond_the_frame_limit_is_read_back_whole_through_a_display_transfer
# Galleries use the same xctestrun command with:
# TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/gallery-rows"
# TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/gallery-bugs"
```
