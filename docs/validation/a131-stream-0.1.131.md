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


## Round 2: fast first rows, then fill (2026-10-24)

Owner decision: open on about 250 rows, then fill the normal 1,000-row
page behind the first viewport; subsequent pages remain 1,000 rows in a
3,000-row resident window. Round 1's comparison is 527 ms to first rows
with 974 source rows admitted at once, versus SCROLL-1's 320–323 ms with
206 source rows. Streaming cost was 2.2 / 2.1 / 2.8 ms at 300 / 750 /
3,000 history rows.

The two review regressions reproduce on `81c14cca`:

- P1: `TranscriptIncrementalTests.testEnteringEstimatedHistoryPlacesNewlyMeasuredRows`
  fails **1 assertion**: entering an estimated band measures the row but
  leaves its frame at 80.994 pt instead of its exact 82 pt. The viewport
  correction now lowers `dirtyFrom` for each measured row before placing
  the suffix (`r2-failing-review.log`).
- P2: `LiveAccountingTests.testStreamingDeltasRefreshNewAndFinishedAttributionTargets`
  fails **4 assertions**: dispatch usage stays on the input, the new
  answer has none, and ending its streaming state schedules no refresh.
  The fast path now compares accounting targets only among its touched
  sources, before adoption, and schedules the existing attribution refresh
  when those targets change. The regression also holds a stale query in
  flight across answer admission (`r2-failing-review.log`).

The opening-budget checks fail before implementation:
`HistoryWindowTests.testOpeningHistoryIsSmallAndLaterReadsKeepTheFullPage`
(**1 test, 3 assertions**, `r2-helper-failing.log`) and the matching wire
case (**1 test, 1 assertion**, `r2-wire-failing.log`) both receive 1,000
rows when requesting the 250-row opening. The wire fixture uses generated
journals and the loopback helper only.

Fresh independent disclosure baseline: unmodified `origin/dev/next`
`afab7da73b57cb9bf17dc944d18a75aacaa42c4e`, verified not to contain
`81c14cca`. Extracted that exact Git tree under this build root and rebuilt
Release into the same owned DerivedData (no extra DerivedData copy).
`TranscriptDisclosureTests.testACardAndReasoningMoveOnTheSameCurve`
failed **1 test / 8 assertions**: card/reasoning do not start their motion,
keep the closed frame height when opened, and do not animate closed.
The standalone run held the perf lock; start/end/peak one-minute load
**2.50 / 2.46 / 2.50** (`r2-baseline-disclosure.log`, build in
`r2-baseline-build.log`). This confirms the scroll workstream's independent
baseline failure on the current `dev/next`, without this branch.

### Round 2 implementation

`PageLimits.opening` prefers 250 rows / 1 MiB, retaining the normal
3,000-row / 24 MB allowance for a single whole turn. Only an initial
latest/saved-position read requests it. The helper accepts the additive
`session.history` `opening` flag; the journal reader takes per-read limits.
Subsequent reads keep 1,000 rows / 4 MiB and the 3,000-row resident window.
A turn larger than the preferred opening still reads whole.

After the native first viewport is ready, `startOpeningFill` reads the
adjacent normal page by its stable cursor. Helper-frame decoding and the
fill planner run off the main actor. Each admission also prepares its full
presented projection and activity plan off the main actor, then validates
its captured projection context, accounting revision, lifecycle and display
mode before publication. Tokens received during preparation patch only
their changed sources; structural changes retry preparation. A bounded,
one-presentation handoff delivers the prepared plan to `TranscriptPage`.
The planner chooses the missing part
of the normal 1,000-row whole-turn page and admits it on separate 16 ms
beats, preferring 128 rows per batch and keeping each turn whole. In the
30-turn fixture the first page is 206 rows (`u28`…`a29_z`), followed by
resident counts **288, 398, 494, 576, 686, 782, 864, 974**. These are eight
whole-turn admissions rather than one large main-thread adoption.

Every admission joins the display's *current* rows, retaining tokens and
accounting that arrived after the read began. Navigation, display identity,
read generation, source path/workspace, lineage, and the near cursor fence
publication. Historical openings fill forward from the saved turn; latest
openings fill backward. A manual page cancels the speculative fill and
uses the normal page budget. An automatic edge request waits for the fill
and checks its generation and cursor before proceeding. A failed fill leaves ordinary automatic
paging available. Each successful admission updates the cached page's
identity/count; a partial cached opening resumes after revisiting.
Replacing a page cancels its previous fill, and a canceled task cannot
clear its successor's task handle. The held-read replacement test covers
both ownership checks.

The reading fixture's blank-frame check now ignores zero-height/folded
rows when finding the page's painted edges. A zero-height terminal summary
at the end of a just-published plan previously made it report eight blank
frames even while `u5` stayed visible at exactly **17 pt** below the clip's
top. The saved-position fill now runs the real select-away/select-back
flow; both it and the latest fill retain the soak's independent jump/lost
row checks. The counter correction is also mutation checked.

### Round 2 regression and mutation evidence

- Before app implementation: **2 opening tests / 5 assertion failures**,
  `r2-opening-failing.log`, quiet Release peak **2.97**. The 974-row page
  arrived immediately and no fill admissions occurred.
- Fixed review classes: **23 tests, 0 failures** (LiveAccounting 11,
  TranscriptIncremental 12), `r2-review-fixed.log`.
- Functional opening checks: **7 tests, 1 gallery skip, 0 failures** before
  the timing/galleries run. Latest and saved-position fills have **0 jumps,
  0 lost rows, 0 blank frames**. `r2-opening-functional.log`.
- Initial physical mutations: **8 negative cases**, all caught. Removing P1,
  suppressing P2's refresh, disabling the fill, and blocking retry after a
  failed fill: **4 tests / 11 assertions** (`r2-mutant-review-fill.log`).
  Restoring the large initial read: **1 / 3** (`r2-mutant-opening.log`).
  Removing replacement cancellation/task ownership and restoring the
  incorrect blank counter: **2 / 4** (`r2-mutant-replacement.log`). Ignoring
  the helper's opening flag: **1 / 3** (`r2-helper-opening-mutant.log`).
- Every mutant was restored; the restored Release build and **9 regression
  tests, 1 gallery skip, 0 failures** precede the final quiet measurements
  (`r2-build-restored.log`, `r2-restored-regressions.log`). Functional/mutation
  runs do not supply timing claims.
- Helper history classes: **18 tests, 1 skip, 0 failures**;
  `r2-helper-history-final.log`. Release helper and bundle staged; both wire
  cases pass (**2 tests**), `r2-wire-history.log`.

Additional focused commands (the shared lock/quiet-window wrapper and exact
argv/start/end/peak/exit ledger are retained in `runs.txt`):

```sh
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 2 \
  --filter 'PiAgentCoreTests\.(HistoryWindowTests|HistoryReadCancellationTests)'
python3 scripts/test-native-host.py \
  "$PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host" \
  NativeIntegration.test_opening_history_is_small_and_following_pages_keep_the_full_budget \
  NativeIntegration.test_a_result_beyond_the_frame_limit_is_read_back_whole_through_a_display_transfer
```

App runs use the Release `test-without-building` command above, with
`-parallel-testing-enabled NO -collect-test-diagnostics never` and only the
classes/cases reported below. Token runs set `TEST_RUNNER_PI_PERF_ROWS` to
300, 750, and 3000. Reading probes set `TEST_RUNNER_PI_TURN_PROBE=1`;
opening galleries set `TEST_RUNNER_PI_OPENING_GALLERY` to the output folder.

Measurement setup notes: two early load-qualified attempts still ran beside
an already-running Release compiler. Unchanged encode/decode/Markdown work
was uniformly slower (300-row paint mean 4.6 ms, then 750-row mean 3.7 ms).
They are retained as `r2-token-*-during-build.log` and excluded from the
before/after comparison. Final timing preflight again waits for all existing
compilers as well as load below 2.8, matching Round 1; every run holds the
perf lock, samples load every five seconds, and repeats any peak above 4.

One early probe selection included the legacy full-frame
`testPerDeltaStageCosts` at 3,000 rows; it throws `oversized` because that
synthetic full display frame exceeds the transport limit
(`r2-token-3000-legacy-selection-interrupted.log`). This is outside the
helper's bounded live-display contract. The intended comparison, as in
Round 1, is `testPerDeltaStageCostsWithRowUpdates` plus
`testRefreshRoundTripOccupancy`, with `TEST_RUNNER_PI_DELTA_ROWS` set for
each size. No frame limit was relaxed; the history-transfer wire case passes.


### Final fill preparation and measurements

The first batched implementation still reprojected unchanged rows on the
main actor. The new per-admission visit bound failed **1 test / 1 assertion**
(**5,062 > 1,000** main-actor source visits, `r2-projection-failing.log`).
It also measured 12–47 ms main-actor admissions. Preparing the projection
and activity plan off the main actor fixes both. Two further physical
mutations — discarding the prepared activity plan and accepting a changed
lifecycle — fail **2 tests / 2 assertions** (`r2-prepared-mutant.log`).
That brings Round 2 to **10 caught negative cases**. Every mutant is
restored in `r2-build-final-prepared.log` and the final results below.

Release timings use the same tool-heavy 30-turn journal as SCROLL-1.
Fresh-process medians of three runs, with a same-binary full-first control:

| Measurement | Full first page control | Small opening, then fill |
| --- | ---: | ---: |
| First visible rows | 530.3 ms | **347.6 ms** |
| Source read | 424.8 ms | 277.6 ms |
| Full 974-row whole-turn page | 530.5 ms | **830.2 ms** |
| First viewport footprint increase | 39.6 MiB | 16.1 MiB |
| Full page footprint increase | 39.6 MiB | 51.4 MiB |
| Further pages to read all 30 turns | 2 | 2 |
| Resident rows after reading back | 2,880 | 2,880 |
| Footprint after reading back | 78.0 MiB | 87.5 MiB |

The first-row samples are **352.3 / 347.3 / 347.6 ms**; full-page samples
**830.2 / 833.3 / 823.3 ms** (`r2-final-reading-{1,2,3}.log`). Control
first rows are **521.7 / 531.4 / 530.3 ms**
(`r2-full-first-control-{1,2,3}.log`). The control uses only the test
fixture's existing history loader and disables speculative fill; there is
no production switch. This is a **34%** reduction to first rows against
the current 1,000-row opening, close to the earlier 320–323 ms small-page
measurement. A warm fixture in the final opening class gives **308.0 ms**
first / **790.7 ms** full. The background fill trades later full-page
completion and some temporary projection memory for earlier useful rows.
Memory is physical footprint above each process's opening baseline; it
includes allocator retention and is not a bound on live transcript payloads.

After filling, the two normal read-back pages remain 1,000-row reads.
Their mean source read is **151.9 / 154.5 / 153.4 ms**, main-thread landing
mean **119.8 / 122.8 / 124.8 ms**, maximum **134.9 / 143.7 / 137.0 ms**.
Those subsequent explicit page adoptions retain the existing path. The
probe's separate synthetic full-page decode diagnostic remains 22–23 ms;
actual helper page decoding now runs off the main actor.

| History rows | Round 1 token mean | Round 2 token mean / worst | Delivery apply + merge + activity |
| --- | ---: | ---: | ---: |
| 300 | 2.2 ms | **2.1 / 3.5 ms** | 0.030 ms |
| 750 | 2.1 ms | **2.0 / 2.6 ms** | 0.035 ms |
| 3,000 | 2.8 ms | **2.4 / 3.0 ms** | 0.060 ms |

`r2-final-stream-{300,750,3000}.log` uses
`TranscriptFrameBudgetTests.testWhereAStreamingDeltaSpendsItsTime`,
`TEST_RUNNER_PI_PERF_ROWS` and 28 rich Markdown deltas per size. These
retain Round 1's flat per-token cost, below the old 60/500 policy's
3 / 12 ms comparison. `r2-final-delta-{300,750,3000}.log` uses
`StreamingDeliveryCostTests.testPerDeltaStageCostsWithRowUpdates` and
`testRefreshRoundTripOccupancy`; the unchanged Release **1 ms** delivery
budget passes at every size. Refresh reply-to-publication median is
**0.41 / 0.39 / 0.65 ms** (max 2.53 / 4.33 / 15.60 ms).

During the actual staged fill, **20 real 300-byte Markdown tokens** cost
**4.312 ms mean / 7.572 ms max**; twelve subsequent control tokens cost
**2.903 / 6.698 ms**. The full 975-row page including that live answer is
ready at **1,190.9 ms** (`r2-opening-final.log`). Both sets continue growing
the reply; neither measures repeated no-op text. Native content and the
complete activity-planner oracle match after admission.

Across 48 main-actor admissions, `openingFillStepMs` is **4.554 ms p50,
7.501 ms p95, 7.835 ms max** (`r2-fill-metrics.json`), versus the initial
12–47 ms batched implementation and Round 1's single approximately
149 ms page landing. The stationary latest-opening reader has frame
interval p50/p95/p99/max **16.6 / 26.1 / 26.4 / 31.1 ms** and frame work
p95/max **4.1 / 4.5 ms**; the saved-position reader gives
**16.6 / 26.6 / 28.2 / 29.2 ms**, work **3.9 / 4.1 ms**. Both report
**0 intervals over 50 ms, 0 row jumps, 0 lost rows, 0 blank frames**.
The saved row stays 17 pt below the viewport top. Light, dark and narrow
first/full galleries are regenerated in `r2-opening-gallery`; the gallery
also checks horizontal row origin and width as well as the soak's vertical
stability checks.

All final numeric comparisons held the shared lock with `perf` in the
owner, recorded start/end and sampled peak load every five seconds.
Start/end/peak one-minute loads (full argv in `runs.txt`):

| Run | Start | End | Peak |
| --- | ---: | ---: | ---: |
| Token 300 | 2.37 | 2.34 | 2.37 |
| Token 750 | 2.31 | 2.37 | 2.37 |
| Token 3,000 | 2.37 | 2.57 | 2.58 |
| Delivery 300 | 2.34 | 2.31 | 2.34 |
| Delivery 750 | 2.37 | 2.37 | 2.37 |
| Delivery 3,000 | 2.57 | 2.68 | 2.68 |
| Opening / live fill | 2.68 | 2.73 | 2.73 |
| Cold reading 1 / 2 / 3 | 2.68 / 2.63 / 2.58 | 2.63 / 2.58 / 2.61 | 2.68 / 2.63 / 2.61 |
| Full-first control 1 / 2 / 3 | 2.61 / 2.43 / 2.56 | 2.83 / 3.57 / 2.62 | 2.83 / 3.57 / 2.62 |
| Streaming stress | 2.62 | 2.80 | 2.80 |

Earlier reading attempts peaking at 4.38 and 5.94 were redone and are not
used above. Functional and mutation runs supply correctness evidence only.

### Final Round 2 validation counts

Primary green results: **156 unique app tests**, **167 executions** including
the three-size token/delivery sweep and six cold/control reading runs.
There are no app skips in this final selection. Gallery-only reruns add
executions of an already-counted method. `r2-test-summary.json` records
counts by log.

| App class | Unique tests |
| --- | ---: |
| TranscriptStreamingStressTests | 15 |
| NativeTranscriptScrollTests | 5 |
| TranscriptGeometryCacheTests | 7 |
| TranscriptWirePageTests | 4 |
| TranscriptOpeningFillTests | 10 |
| WorkspaceLoadingTests | 13 |
| HistoryTurnPagingTests | 6 |
| LongTurnPagingTests | 4 |
| HistoryEdgeTests | 16 |
| TranscriptIncrementalTests | 12 |
| LiveAccountingTests | 11 |
| TranscriptActivityTests | 11 |
| TranscriptFindTests | 12 |
| TranscriptTurnFoldTests | 26 |
| TranscriptFrameBudgetTests (selected method) | 1 |
| StreamingDeliveryCostTests (selected methods) | 2 |
| LongTurnPagingProbeTests (selected method) | 1 |

The focused class logs are `r2-<Class>.log`; opening uses
`r2-opening-final.log`. The entire Find class first encountered a
20-second tool-output timeout under load **4.44**, failing one test / two
assertions (`r2-TranscriptFindTests-loaded.log`). The exact method passes
alone at peak **2.07** (`r2-find-tool-alone.log`), and its full class passes
**12 / 12** at peak **2.22** (`r2-TranscriptFindTests.log`); the fold class
then passes **26 / 26** at peak **2.22**. No Find behavior was changed.

Helper: **18 tests, 17 passed / 1 skipped / 0 failed** — HistoryWindowTests
14 and HistoryReadCancellationTests 4. The skip is the existing opt-in
`testRapidSupersessionMeasurement` (`PI_SCROLL14_PERF=1`), outside this
change. The opening-history and transfer wire cases pass **2 / 2** against
the staged Release helper. No full app/helper lanes or unrelated wire
suites were run in Round 2.

Shipped policy: **~250 initial rows / 1 MiB, then 1,000-row / 4 MiB pages,
3,000 resident rows / 24,000,000 bytes**; each preference yields to the
existing single-whole-turn allowance. No new unresolved regression. The
standalone disclosure-curve failure remains independently confirmed on
unmodified `dev/next` as recorded above; no animation fix is included.


### Final gallery verification

The added horizontal assertions initially fail **1 test / 2 assertions**
(`r2-gutter-failing.log`): the first light reply origin changes **30 → 24 pt**,
width **840 → 837 pt**. The diagnostic capture proves a viewport change:
AppKit's preferred scroller style changes **overlay → legacy**, and clip
width **900 → 885 pt**. The document has the correct width at both captures
(`r2-gallery-style-diagnostic.log`). This is the test host's asynchronous
initial scroller preference, rather than stale row placement or a fill
changing a fixed viewport. The gallery now fixes its scroller style before
first capture, as the existing streaming fixture does. Production scroller
behavior is unchanged; experimental width corrections were removed.

Removing that fixture normalization reproduces **1 test / 2 assertions**
(`r2-gallery-style-mutant.log`), bringing Round 2 to **11 caught negative
cases** (the ten above plus this fixture case). The fixed and restored
standalone gallery both pass **1 / 1**, with **0 jumps, 0 lost rows,
0 blank frames**, stable horizontal origin/width, and all six first/full
PNGs regenerated and inspected in light, dark and narrow layouts
(`r2-gallery-style-fixed.log`, `r2-gallery-style-final.log`). No new clipping
or overlap is visible; existing folded-row spacing is retained.

These gallery runs hold the focus lane and supply correctness evidence,
not timing claims. The final production sources are identical to those
used for the accepted quiet measurements above. Final build:
`r2-gallery-style-restored-build.log`. The primary 167 green executions plus
the two final gallery executions give **169 selected green app executions /
156 unique tests**, recorded in `r2-test-summary-final.json`. Earlier
expected failures, mutations and diagnostic attempts are reported separately.

## Round 3: live-tail catch-up, held-prefix release and integration (2026-10-26)

Reviewed `a35fc7fc`; fixes committed as `5af7c454`, then merged
`origin/dev/next` `1ef3a524` without rewriting either history.

- A saved-position opening could read a partial last reply while an idle
  snapshot omitted rows because history browsing was still on. Closing its
  newer gap now clears the retained projection and requests fresh live rows,
  matching ordinary forward paging. The regression holds the stale read,
  finishes the run, then checks a fresh full snapshot, the finished reply
  and a final response part absent from the read.
- The streaming shortcut treated any held ID as requiring the entire
  over-budget prefix. It now checks the earliest held row's turn through
  the retained position index, off the main actor; a later held turn falls
  back to canonical trimming. With an eight-row fixture cap, advancing
  either the anchor or selection keeps **12, then 10 rows**, instead of all
  **14**, preserving the held row, live tokens and earlier paging boundary.

Both generated/scripted-helper regressions live in
`WorkspaceRefreshLifecycleTests`. Release failing-first: **2 tests failed /
10 failures** (eight prefix assertions, the missing-refresh timeout and its
thrown XCTest error; one marked unexpected), `r3-failing.log`. Fixed and
restored selections each pass **2/2** (`r3-fixed.log`, `r3-restored.log`).
Physical mutations are caught separately: removing gap catch-up fails
**1 test / 2 failures**; restoring the old held-prefix shortcut fails
**1 test / 8 assertions** (`r3-mutant-opening.log`,
`r3-mutant-held-prefix.log`). Both production files were restored and
rebuilt before integration. These are correctness checks, not speed claims.

### Merge and focused validation

Only `NEXT-RELEASE.md` and the generated project had textual conflicts
(`r3-conflicts.txt`). The plan preserves every incoming line and owner
decision, with checked FIND-1/STREAM-1 entries winning their unchecked
alternatives; `xcodegen generate --quiet` produces the union of sources.
The automatic code merges were checked explicitly: `SessionDisplay` keeps
incremental projections, the brief run-end tracker and queued skills;
native scrolling keeps prefix placement/measured-row invalidation and
PERF-3's legacy gutter reservation; reasoning prepares its indented width
before `read`. `HistoryReader` keeps EDIT-2's independent edit readers and
direct target read alongside per-read opening limits. Completion is still
observed before the snapshot row fast path. Incoming paste, edit/slash
and brief hook paths remain intact.

The merged Release native build, Release helper rebuild and bundle staging
pass (`r3-merged-build.log`, `r3-helper-release.log`, `r3-helper-stage.log`).
The entire Round 2 selection passes again: **156 unique tests / 167
executions**, with the same per-class counts listed above. Additional
merged app selections are:

| Class | Passed | Skipped |
| --- | ---: | ---: |
| WorkspaceRefreshLifecycleTests (includes both regressions) | 40 | 0 |
| TranscriptUpdateIsolationTests | 8 | 0 |
| EditHistoryReaderTests | 1 | 0 |
| HistoricalEditingTests | 5 | 0 |
| ReasoningLayoutTests | 1 | 0 |
| TranscriptScrollerSizingTests | 1 | 0 |
| ChatBriefTests | 22 | 0 |
| QueueEditInteractionTests | 18 | 0 |
| EditSlashCommandTests | 12 | 1 |
| ComposerPasteLifecycleTests | 7 | 0 |
| TranscriptRowGalleryTests (capture method) | 1 | 0 |

Merged app total: **273 unique tests: 272 passed / 1 skipped / 0 failed**;
**284 executions: 283 passed / 1 skipped** (`r3-test-summary.json`). The
skip is the existing opt-in edit-slash gallery. Helper:
**23 registered / 22 passed / 1 skipped / 0 failed** — HistoryWindowTests
14, HistoryReadCancellationTests 4, EditPreparationTests 5
(`r3-helper-history.log`); the skip remains the opt-in rapid-supersession
measurement. The two opening-history/large-transfer wire cases pass
**2/2** against the merged Release helper (`r3-wire-history.log`).
No full app/helper lanes or unrelated wire suites were run.

Exact expanded argv, environment recipes and selectors are in `runs.txt`,
`r3-test-manifest.json` and `r3-postmerge.py` under the same build root.
App checks use `xcodebuild test-without-building -xctestrun
$PI_BUILD_ROOT/native-tests/Build/Products/PiApp_macosx15.1-arm64.xctestrun
-destination platform=macOS,arch=arm64 -parallel-testing-enabled NO
-collect-test-diagnostics never -only-testing:PiAppTests/<selection>`, one
class per invocation. Helper: `swift test --package-path packages/swift-host
--scratch-path $PI_BUILD_ROOT/swift-host --jobs 2 --filter
'PiAgentCoreTests\.(HistoryWindowTests|HistoryReadCancellationTests|EditPreparationTests)'`.

### Merged Release measurements

| Resident rows | Before STREAM-1 mean | Round 2 mean | Merged mean / worst | Apply + merge + activity |
| --- | ---: | ---: | ---: | ---: |
| 300 | 8.4 ms | 2.1 ms | 2.7 / 9.8 ms | 0.038 ms |
| 750 | 17.0 ms | 2.0 ms | 3.0 / 7.5 ms | 0.045 ms |
| 3,000 | 60.7 ms | 2.4 ms | 3.0 / 4.2 ms | 0.065 ms |

The three-size FrameBudget and Delivery probes use `PI_PERF_ROWS` and
`PI_DELTA_ROWS` via `TEST_RUNNER_`, as before (`r3-stream-*.log`,
`r3-delta-*.log`). The 300-row Release **1 ms** delivery budget passes;
per-token cost stays flat and the 3,000-row result meets the old **3 / 12
ms** opening/full-window comparison. These new samples are slower than
Round 2; no timing gain is claimed for the two correctness fixes.

Three cold generated tool-heavy openings: first rows median **374.7 ms**
(range 368.6–386.0), versus **579.0 ms** (551.9–583.4) for full-first controls;
full 974-row page median **909.8 ms** (895.7–927.7). Round 2 medians were
347.6 / 530.3 / 830.2 ms respectively. Whole turns yield 206 initial rows;
reading all 30 turns still takes **two further pages**, ending at **2,880
rows**. Footprint increases (MiB, median): **18.9 first / 57.2 full / 85.8
read back**, versus Round 2's 16.1 / 51.4 / 87.5 (`r3-reading-*.log`).

Opening-fill class: 22 tokens during fill cost **5.228 / 8.991 ms**
(mean/max), versus 12 after at **3.599 / 8.251 ms** (Round 2:
4.312 / 7.572 and 2.903 / 6.698). Its live fill finishes at **1,397.7 ms**.
The 56 main-actor admissions take **5.542 / 8.479 / 9.318 ms**
(p50/p95/max), with preparation off-main and a yield between admissions
(`r3-fill-metrics.json`). Historical and stationary-reader checks report
**0 jumps, 0 lost rows, 0 blank frames**, no interval over 50 ms (max
35.5 / 34.6 ms). All six first/full light/dark/narrow PNGs and ten row,
opened-reasoning/card, stopped-reply and fold PNGs were regenerated and
inspected: no new clipping or overlap; existing folded-row spacing remains.

Measurements waited for IMG-1, then held the shared lock as
`a131-stream perf merged validation`, with start/end and five-second peak
load samples. Every measured run stayed below 4; no measurement needed a
load redo. One-minute loads, ordered 300/750/3,000 or repetitions 1/2/3:

| Run | Start | End | Peak |
| --- | --- | --- | --- |
| Token | 2.18 / 2.39 / 2.51 | 2.25 / 2.51 / 2.45 | 2.25 / 2.51 / 2.51 |
| Delivery | 2.25 / 2.51 / 2.45 | 2.39 / 2.51 / 3.13 | 2.39 / 2.51 / 3.13 |
| Cold reading | 2.75 / 2.21 / 2.20 | 3.01 / 2.20 / 2.17 | 3.01 / 2.21 / 2.20 |
| Full-first controls | 2.17 / 2.08 / 1.99 | 2.08 / 1.99 / 2.07 | 2.17 / 2.08 / 2.07 |
| Streaming stress | 2.07 | 2.89 | 2.89 |
| Native scroll | 2.53 | 2.48 | 2.57 |
| Geometry cache | 2.48 | 2.48 | 2.48 |
| Wire page | 2.48 | 2.52 | 2.52 |
| Opening / live fill | 2.52 | 2.76 | 2.76 |

Policy remains **250 initial / 1,000 following / 3,000 resident rows**,
with **1 MiB / 4 MiB / 24,000,000 byte** caps and whole-turn allowances.
Per the lead's evidence on `a9f34673`, the standalone disclosure-curve
failure is pre-existing test isolation; it was left unchanged and not
rerun here. Both review findings are resolved.

## Round 4: bounded opening retries (2026-10-26)

Fast-forwarded to `origin/dev/next` `c03168e0`. A stale prepared batch used
to rebuild its full detached projection immediately, without a bound.
It now waits **16 / 32 / 64 ms**, then stops after **four projections per
batch**. Every validation is unchanged; the readable rows and current
paging boundary remain intact, and ordinary automatic paging still works.
Each admitted batch starts with a fresh retry allowance.

The existing opening-step seam injects a new response part after each
projection, before validation. Failing first: **2 tests, 1 passed / 1 failed**;
the busy-tail regression reaches its fixture safety stop at **12 projections**
instead of four (`r4-failing.log`). Fixed: **2/2 pass**, busy tail **4**;
a transient edit per batch completes **8 batches / 16 projections**
(`r4-fixed.log`). A physical mutation removes the wait and limit: **1 test /
1 expected assertion failure**, again **12 projections** (`r4-mutant.log`).
The fixed source is restored in `finally`, rebuilt and hash-checked.

Final Release classes: **TranscriptOpeningFillTests 12/12**,
**WorkspaceLoadingTests 13/13**, **WorkspaceRefreshLifecycleTests 40/40**:
**65 unique tests passed, no skips/failures**; the earlier fixed selection
adds two green executions. Logs are `r4-<Class>.log`; exact build/test argv
is in `runs.txt`, with selectors in `r4-failing.py`, `r4-fixed.py` and
`r4-checks.py` under the same build root. These use Round 3's Release
build-for-testing and serial test-without-building arguments; the opening
class enables `TEST_RUNNER_PI_OPENING_GALLERY=$PI_BUILD_ROOT/r4-opening-gallery`.
Helper and wire code did not change.

The opening class holds the lane as `a131-stream perf`: one-minute load
start/end/peak **2.35 / 2.72 / 2.72**, so no redo. Its existing budget check
passes: 22 tokens during fill **5.240 / 9.872 ms** (mean/max), versus 12
after at **3.571 / 8.371 ms**. The opening fixture shows first/full rows
at **339.7 / 889.7 ms** (one sample); historical and stationary fills have
**0 jumps / 0 lost / 0 blank frames**, no interval over 50 ms. All six
first/full light/dark/narrow captures were regenerated and inspected;
no new clipping or overlap. The 250 / 1,000 / 3,000 row policy is unchanged.
