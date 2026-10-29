# PERF-1: very long chats, 0.1.136

The phase-A findings below are retained as measured. Phase-B round 1 is recorded at the end.

Phase A was measure-and-propose only: workstream `dev/a136-perf`, base `21e30eb1`.
The lead reviewed it before authorizing the phase-B work recorded below.
Phase A made no production behavior, storage-format or paging-policy changes.
Instrumentation is compiled only with `PI_TEST_HOST`; shipping code has no
new probes or probe branches. Tests enable it with `TEST_RUNNER_PI_PERF_TRACE=1`.

The owner, 2026-10-29: "I have like a session that's like 50k interactions
already, and it feels kind of slow"; "especially the scrolling experience";
"It has to be backward compatible."

The recommended first three changes, subject to the lead's review, are:

1. Coalesce useful page reads and start bounded read-ahead earlier. At 50k,
   upward scrolling cancels **205/218 desktop** and **160/174 helper** source
   calls. Consecutive observed low-coverage gaps reach **1.37 / 1.80 seconds**
   upward; the desktop return has a **6.31-second** gap and a **999.64 ms**
   frame interval. Completed source-call p95 is **0.268 / 1.577 seconds**.
2. Defer inherited-plan discovery until after first paint. That serial scan
   costs **1.84 / 7.13 / 14.46 seconds** at 50k / 200k / 50k exchanges,
   even with a checkpoint.
3. Avoid Find refreshes caused only by presenting a page, and batch its
   disposable cache writes. The first full 50k scan takes **111.17 seconds**;
   a separate profile measures **17.81 CPU seconds in the next 20 seconds**
   while a refresh repeats work on the unchanged journal.

The larger, higher-risk helper-history change is also significant: its
checkpoint-backed first older-page request takes **55.18 seconds** at 50k
exchanges, with **3.15 GiB** peak physical footprint. Cold helper open peaks
at **5.14 GiB**, and large opens can cross the production 30-second deadline.
The first three changes need no stored-data migration. Optional persistent
indexes would be versioned, disposable derived caches; journals stay
canonical and readable by older versions. The ranked proposal below gives
risks, expected effects, proof requirements and decisions for phase B.

**Coverage and remaining gaps:** all 24 opening/switch cases were attempted
under the quiet rule (21 passed; three hit the helper deadline), all eight
source/size paced-scroll cases cover twelve upward windows and return to the
end, and both slower-wheel controls completed. Full desktop Find is accepted
at 10k, 50k and 200k. Full 375k desktop Find and full 200k helper-owned Find
still need a quieter rerun; their load-rejected timings are excluded. The
record is ready for proposal review with those two explicit measurement gaps.

## Reproduction and boundaries

All content is generated. The only application launched is
`com.belloware.PiAppTests.Host`, with an in-memory configuration vault, the
test isolation guard and scratch storage below
`/Users/admin/Library/Caches/BelloSwiftWork/build-a136-perf`.
No installed app, owner chats, preferences, Keychain, live capture or paid
provider is used. Helpers have generated homes and a loopback-only profile.
No `xctrace --launch` or named result bundle is used.

The existing `LongChatScroll` driver, native `ConversationPaneView`,
`HistoryReader`, real helper stdio transport, `TranscriptLayoutClock` and
`SoakStallWatchdog` are reused. The generator streams JSONL directly to disk;
the native fixture opens the file without loading/copying its entire body.
Each measured attempt gets a fresh APFS clone (ordinary copy fallback),
removed afterward. A helper, not the generator, writes each warm `.meta`.
The cold variant has neither that checkpoint nor process-local indexes.
The desktop reader opens both variants without a running helper. The live
variant opens the real helper and routes pages through `session.history`.

"Cold" means a new process, reader, view and indexes. The OS filesystem cache
is **not purged**. Process-launch-to-draw includes XCTest startup and fixture
setup; it is an isolated-host launch measurement, not the shipping app's
full library/sidebar startup. Selection-to-draw excludes that startup.
First-switch trials start with another generated chat already drawn in the
same pane; cached switches retain the previously read long-chat page.
For helper-owned fixtures, helper open/prewarming happens before selection
and is reported separately. The helper selection column is not the combined
cost of starting that helper; process-launch-to-draw includes that preparation.

Frames are the existing harness's 60 Hz main-actor input/layout/display
observations, not GPU presentation timestamps. Wheel events use AppKit's
real scroll-wheel path, with explicit finger/momentum phases, 70 steady
frames, 30 decaying momentum frames, then quiet frames per burst. The final
`scroll-paced480-*` matrix uses 480-point steps and **180 quiet frames**
(three seconds); the separately labelled short-dwell stress uses 20;
scroller motion follows the existing knob driver. Blank frames mean less
than half the viewport is covered by drawable rows. Jumps are the driver's
row/clip displacement checks. The stricter `visibleJumps` subset requires
the row to be on screen before and after the displacement; raw jumps also
include corrections to unloaded scroll-room estimates. Zero verified jumps
does not prove every possible visual jump absent. These are CPU/geometry measurements, not
physical-trackpad or pixel-capture claims. Empty retained rows count as
blank, including the expected wait before the first viewport. Counts above 16.7 ms include
ordinary scheduler jitter around the 60 Hz target; 33/50/100 ms counts and
main-queue acknowledgements distinguish larger stalls. A separate continuous
wheel knob removes the quiet frames. A timed-out operation is censored at its
reported duration, never counted as a successful landing.
The coverage check uses the first/last drawable row bounds; it does not
detect internal gaps between folded rows. FOLD-GAP is a separate workstream.
Active-input blank counts are reported separately so the quiet frames do
not dilute them. Consecutive blank durations run from the first low-coverage
observation to the next covered observation; a trailing span is censored.
They do not reconstruct pixels between observations. A read-to-visible
episode can include prefetch, travel and dwell while old rows remain visible;
it is not all empty-viewport delay. These are single accepted trials per scenario, not a
statistical confidence interval. Enabled trace logging and probe work are
part of the measurement overhead; profiles are separate trials.
The paced wheel matrix starts after opening fill and a cached switch back,
with history indexes ready. It measures subsequent paging; gesture
contention during the first full-index build is not isolated by that matrix.
Opening/index waits and deadline failures are measured separately.

The `proc_pid_rusage` CPU counters are converted from Mach ticks using this
machine's timebase (125/3 ns per tick), checked against `getrusage`. Physical
footprint and lifetime peak footprint are reported separately from the direct
helper runner's final peak RSS. CPU totals are cumulative; subtract phase
endpoints for phase CPU. An async span marked `main=true` records where it
ended, **not** CPU time spent blocking the main thread. Main-queue watchdog
delays and the sampled main-thread stacks answer that question.

### Environment

macOS 14.8 (23J21), arm64 VirtualMac2,1, 10 logical CPUs, 16 GiB RAM;
Xcode 16.1 (16B40), Swift 6.0.2, Python 3.14.1. The source base is
`21e30eb15f9ee3bb9d6aef9b0a21f5d2ea16f9a5`; its bundle still identifies
itself as 0.1.135/build 139. This is the 0.1.136 workstream's baseline,
without the parallel cut-in or folded-gap changes.

The application uses Release `-O` whole-module optimization with
`ENABLE_TESTABILITY=YES`. The test bundle also uses Release `-O`, compiled
incrementally so editing a probe does not require
optimizing the entire test suite as one unit. The two optional build settings
below select this; ordinary Release builds keep their existing defaults.
`xcodebuild` uses two build jobs. Although the command requests Swift `-j2`,
Xcode's emitted driver line also contains `-j10`; a two-job Swift compiler
cap is not assumed in this record.
Only one Release DerivedData
directory is used; no Debug copy is needed. Machine/build details are also
recorded in `build-a136-perf/perf/environment.json`.

## Fixtures

`scripts/perf-longchat-fixture.py`, seed 136, Python's seeded generator.
Message targets finish the last whole turn, so actual counts can exceed
the requested count slightly. An exchange is one human question through its
final answer, including intervening reasoning/tool/delivery rows. Both
interpretations of "50k interactions" are covered explicitly.

The mix has short questions with occasional Unicode text; Markdown/code replies (including occasional
35-section answers); reasoning; read/bash calls and results; 320×180 synthetic PNGs;
typed sub-agent mail; task-terminal and idle state receipts; compactions
every 128 exchanges retaining two complete turns, plus a final compaction.
Tool outputs have a long tail up to 160 KB. The final checkpoint intentionally
has a short retained tail, exercising the transition into older history.
IDs are short and readable, and the journal is linear. Sub-agent mail uses
the native delivery envelope, but this fixture does not create a full child
plan/family directory. It does not cover every imported/edited/branched/family
journal. The app fixtures have an empty generated accounting database; a
separate existing 100k-attempt accounting fixture is measured below.

| Fixture | Messages | Human exchanges | Tool calls/results | Images | Agent mail | Compactions | MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 10k | 10,009 | 1,230 | 3,768 | 8 | 13 | 10 | 33.622 |
| 50k | 50,016 | 6,591 | 18,383 | 39 | 68 | 52 | 170.571 |
| 200k | 200,001 | 26,443 | 73,421 | 153 | 273 | 207 | 688.389 |
| 50k exchanges | 375,272 | 50,000 | 137,378 | 289 | 516 | 391 | 1,286.403 |

"Messages" includes typed sub-agent deliveries in the user lane. Display
positions also include compaction rows, so their totals are respectively
10,019, 50,068, 200,208 and 375,663. The runner verifies those totals before
accepting an app trial. The helper runner verifies the checkpoint and opening
page totals as well. Tool output p50/p95/p99 is approximately 2.5/26/112 KB,
with a 160 KB maximum. Exact byte counts, distributions and SHA-256 values
are in each manifest and the evidence file. Large journals stay in the build
root. Accepted unprofiled frame arrays are also embedded in the compressed
evidence archive; rejected/profiled raw arrays remain in the build root.

## Commands

From the worktree, always:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-perf
```

Before every build, check `full-lane.lock/owner` and wait while it names
`perf` or `soak`. Builds do not hold the measurement lock.

```sh
python3 scripts/build-bundle.py
xcodegen generate --quiet
xcodebuild build-for-testing -jobs 2 -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2
python3 scripts/test-perf-longchat-fixture.py
python3 scripts/test-perf-longchat-report.py

python3 scripts/perf-longchat-fixture.py "$PI_BUILD_ROOT/fixtures/10k" --messages 10000
python3 scripts/perf-longchat-fixture.py "$PI_BUILD_ROOT/fixtures/50k" --messages 50000
python3 scripts/perf-longchat-fixture.py "$PI_BUILD_ROOT/fixtures/200k" --messages 200000
python3 scripts/perf-longchat-fixture.py "$PI_BUILD_ROOT/fixtures/50k-exchanges" --exchanges 50000
```

`perf-longchat-run.py` owns the full-lane lock only for a trial, with `perf`
in its owner line, and releases it on failure too. It records
`sysctl -n vm.loadavg` before/after and samples the one-minute value every
two seconds. Any trial whose observed peak exceeds 4 is marked invalid and
retried, with fresh fixture state. Timing evidence excludes those trials.
`--profile` samples only the PIDs supplied by the generated test process,
or a newly launched executable matching the guard-validated test host in
this build root. That fallback also permits cleanup of interrupted existing
test classes which do not write the PERF-1 PID file.
Profile runs are separate from unprofiled comparisons. Runs start below a
one-minute load of 3 by default to leave headroom; later matrix/profile runs
use `--start-load 2.0`. The current runner waits for cooling before acquiring
the lock. A run is stopped and
retried as soon as its observed load exceeds 4. `sample <fixture-pid> 10 10`
collects ten seconds at 10 ms intervals. `--profile-after <log-marker>`
can target scrolling instead of startup.

```sh
# This also measures the cold replay and checkpoint creation.
python3 scripts/perf-longchat-run.py --label prepare-50k -- \
  python3 scripts/perf-longchat-helper.py "$PI_BUILD_ROOT/fixtures/50k" --prepare

# Use the single .xctestrun produced by the Release build; verify isolation.
RUN=("$PI_BUILD_ROOT"/release/Build/Products/*.xctestrun)
python3 scripts/check-test-host.py "$RUN[1]"
TEST_RUNNER_PI_PERF_SOURCE=journal TEST_RUNNER_PI_PERF_STREAM=1 \
  python3 scripts/perf-longchat-run.py --label journal-50k-warm \
  --fixture "$PI_BUILD_ROOT/fixtures/50k/warm/chat.jsonl" -- \
  xcodebuild test-without-building -xctestrun "$RUN[1]" \
  -derivedDataPath "$PI_BUILD_ROOT/release" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:PiAppTests/LongChatPerformanceTests/testMeasureLongChat

# Independent trials, each with its own lock and fresh fixture clone.
python3 scripts/perf-longchat-matrix.py --suite helper --resume
python3 scripts/perf-longchat-matrix.py --suite open --resume
python3 scripts/perf-longchat-matrix.py --suite scroll --resume
python3 scripts/perf-longchat-matrix.py --suite rate --sizes 50k --resume
python3 scripts/perf-longchat-matrix.py --suite find --resume
python3 scripts/perf-longchat-matrix.py --suite profile --resume
```

Use `PI_PERF_SOURCE=helper` for real helper-owned pages, the original
`fixtures/<size>/chat.jsonl` for the cold variant, `PI_PERF_OPEN_ONLY=1`
for opening trials, and `PI_PERF_SWITCH_FIRST=1` for the first switch.
`PI_PERF_HELPER_HOT=1` first reads the start of the journal in the helper,
so a switch can measure an already-owned chat with its full history index
ready. The preparation is timed separately as `helper.indexReady`.
`PI_PERF_FIND_ONLY=1`, `PI_PERF_SKIP_FIND=1`, `PI_PERF_WHEEL_ONLY=1`,
`PI_PERF_STREAM_ONLY=1` and `PI_PERF_CONTINUOUS_WHEEL=1` select focused variants.
The ordinary scroll trial observes Find for 60 seconds; `--suite find`
allows 3,600 seconds to finish before stepping around the result boundary.
The separate rate control uses 120-point steady wheel steps, 180 quiet
frames and a 180-second limit per direction. It reports actual coverage
even when the limit precedes twelve windows. Three earlier 120-point,
20-quiet-frame desktop attempts exceeded the load limit (4.21, 6.21, 4.08)
and are excluded; their waiting helper control was canceled before launch.
The final control matches the main matrix's quiet frames to compare speed.
The combined 200k helper scenario exceeded load 4 on all three attempts
(4.04, 4.26, 4.05). Its `-split-find` retry keeps the same wheel, drag,
edge and resize protocol with `PI_PERF_SKIP_FIND=1`; the separately labelled
`find-complete-helper-200k-ack180` runs the full scan and navigation with
`PI_PERF_SOURCE=helper`, `PI_PERF_FIND_ONLY=1`, `PI_PERF_FIND_SECONDS=3600`
and the same 180-second acknowledgement diagnostic. Both use a starting
load limit of 1.8. No portion of a rejected combined run is promoted into
accepted evidence. Whole-trial CPU endpoints with different phase coverage
are not like-for-like comparisons.
`--no-trace` disables test-host
span logging for a control run; it does not change application behavior.
All test knobs are passed with `TEST_RUNNER_` and read with `testEnvironment`.
The runner supplies `PI_PERF_ROOT`, `PI_PERF_JOURNAL`, the PID file, trace
switch, raw-frame destination and scratch root in the same way. The trace
switch is explicitly included in the test manifest's environment too.

Exact per-trial argv, environment, fixture manifest, binary hashes, raw
start/end load strings and two-second load samples are retained in
[`a136-perf-0.1.136-data.json.gz`](/Users/admin/Library/Caches/BelloSwiftWork/perf-evidence/a136-perf-0.1.136-data.json.gz), together
with full-precision events/spans, accepted frame arrays and complete sampled
stacks. The readable tables round values; the archive does not. Regenerate:

The final archive contains 102 attempt records: 56 eligible unprofiled
trials and nine eligible profile trials, with the remaining calibration,
load-rejected, interrupted and failed attempts retained explicitly. Its
SHA-256 is `bed720f4481d59fcda3a232edb728fe0fd231f4c5d54c4f8897c8e817d0ac33d`
(8,062,098 bytes). The unchanged phase-A archive was moved out of git in phase B; it is also recoverable from commit `d683c4b7` at its former `docs/validation/` path. Obsolete smoke journals were removed; the four canonical
cold/warm fixture pairs remain in the build root, with one Release
DerivedData directory, no Debug DerivedData, and about 11 GiB free afterward.

```sh
python3 scripts/perf-longchat-report.py "$PI_BUILD_ROOT" \
  /Users/admin/Library/Caches/BelloSwiftWork/perf-evidence/a136-perf-0.1.136-phase-b-data.json.gz
```

`unprofiledTimingEvidence` excludes load violations, failed tests, calibration
and profiled trials. Failures and rejected attempts remain in the archive
with their reasons. `timingEvidence` additionally permits accepted profile
trials for stack analysis, never for unprofiled before/after comparisons.
These flags screen a whole trial; per-operation readiness/censoring and
`phaseLimitations` still apply. They do not certify every observation as a
completed operation or a verified comparison of modes.

The initial `smoke-*`/`probe-*` runs are calibration only. In particular, a
cut-in Debug host overlapped `probe-10k-1` while the perf lock was held;
the one-minute load exceeded 44 before that run was stopped. Its CPU units
also predate the calibration correction. Those timings are excluded. An
initial smoke command omitted `-derivedDataPath`; its automatically created
test-log directory was removed, and the runner now always supplies the lane's
DerivedData path. No installed application was launched.
The opening matrix used the same-volume OS temporary directory for its
disposable SQLite index. Later probes use a test-bundle-only temporary-directory
override to keep those files in the build root. Its constructor is inactive
when the perf environment is absent. Through build 8 the app and helper
binaries were identical across the matrix; build 9 also corrects the
test-host-only fingerprint byte counter for overlapping 64 KiB windows in
small files. All measured long-chat files exceed 33 MiB and their counts
are unaffected. The helper is unchanged. Exact artifact hashes and
test-bundle revisions are in the evidence archive. Build 10 restores the
legacy scroll fixture's original selection-before-pane setup by default;
the new PERF-1 test explicitly selects its already-used pane-before-selection
mode, so its measurement setup is unchanged. The earliest SQLite microbenchmark used an incorrect
ctypes variadic declaration and is marked calibration-only; the corrected
system-SQLite run is the one cited below.

Build 11 adds a test-host-only Find completion callback and scan spans.
Earlier probes waited for `searching == false` and a drawn highlight in the
same frame; that can include a later content refresh. New `find.scanComplete`
events time each completed scan directly, while `find.search` reports the
initial scan and separately records highlight readiness and whether another
scan is running. Step measurements retain the real controller behavior.
The optional `PI_PERF_FIND_REFRESH_DIAGNOSTIC=1` observes twenty seconds
after that first completion, allowing a separate `sample` of any refresh.
The fixture-path check also resolves symlinks and returns before reading
if the journal is outside the generated root. Valid fixture paths and
application behavior are unchanged.
The final build-11 host SHA-256 is
`14f13ade65327a120e89f4c9fca582a837e511324677950d540d50b6d0bcd95a`;
the test bundle is
`fb1ad8c67f985ac3a4bee39eee17364ffdddb27686b9f34c0dbdad543603327a`.
The unchanged Release helper is
`211447877aa618f3ee0e515b1e00991de6c44f66cd772c1284214c26bd573ed3`.
Later, writing the test manifest was moved inside the lock so a queued
trace-disabled control cannot change a running trial's environment. Its
first retry exposed a variable-name collision with the fixture manifest;
`find-complete-50k-exchanges-2` aborted before launching an application.
The names and per-attempt load initialization are corrected, that wrapper
failure is excluded, and the case is rerun. No accepted timing changed.

The separate refresh profile is reproduced with:

```sh
TEST_RUNNER_PI_PERF_SOURCE=journal TEST_RUNNER_PI_PERF_FIND_ONLY=1 \
TEST_RUNNER_PI_PERF_FIND_SECONDS=3600 TEST_RUNNER_PI_PERF_FIND_REFRESH_DIAGNOSTIC=1 \
  python3 scripts/perf-longchat-run.py --label profile-find-refresh-50k \
  --profile --profile-after '"event":"find.scanComplete"' --start-load 2.0 \
  --fixture "$PI_BUILD_ROOT/fixtures/50k/warm/chat.jsonl" -- \
  xcodebuild test-without-building -xctestrun "$RUN[1]" \
  -derivedDataPath "$PI_BUILD_ROOT/release" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:PiAppTests/LongChatPerformanceTests/testMeasureLongChat
```

## Results and proposal

### Opening — Release, unprofiled

Seconds; `cold / checkpoint` pairs. Selection is first use of the chat; the separate switch column starts with another chat drawn. Process launch includes the isolated XCTest host and fixture setup.

| Size | Reader | Selection → first useful draw | Process launch → draw | Opening fill finished | First switch → draw |
|---|---|---:|---:|---:|---:|
| 10k | journal | 2.019 / 0.712 | 2.638 / 1.183 | 2.786 / 2.732 | 0.615 |
| 10k | helper | 0.728 / 0.685 | 2.787 / 1.226 | 2.495 / 3.544 | 0.663 |
| 50k | journal | 7.761 / 2.047 | 8.325 / 2.541 | 8.389 / 9.188 | 2.292 |
| 50k | helper | 1.999 / 2.189 | 9.632 / 2.777 | 3.723 / 11.010 | 2.400 |
| 200k | journal | 30.072 / 7.475 | 30.570 / 8.049 | 30.825 / 34.627 | 9.180 |
| 200k | helper | — / 8.029 | — / 8.633 | — / 128.031† | 7.960 |
| 50k-exchanges | journal | 60.060 / 15.026 | 60.515 / 15.588 | 61.068 / 70.670 | 15.652 |
| 50k-exchanges | helper | — / 13.516 | — / 14.042 | — / 133.521† | — |

`—`: the app’s 30-second helper acknowledgement deadline expired. The 200k and 50k-exchange cold helper trials failed before first rows. The 50k-exchange hot-helper switch failed during *prewarming*, before the switch, so it is not a measured switch failure. `†`: initial rows were visible, but opening fill had not completed after the original probe’s 120-second observation; its history request timed out at 30 seconds and the fill catch left `openingPage` set. Later probes stop observing when that fill task ends and report `ready=false` directly.

Position totals and the first row-height estimate were ready at first draw in every successful opening; this already supplies whole-chat scroller geometry. “Opening fill finished” is the additional background fill and first crossing beyond a short checkpoint, not the first scroller appearance. The trace records exact `adopted`, `viewport ready`, index-start/end and fill publication times.

The diagnostic 180-second acknowledgement setting permits these failed
baseline cases to complete; it is not a production speed improvement:

| Diagnostic | Helper open / prewarm s | Selection → draw s | Process launch → draw s | Opening fill after selection s |
|---|---:|---:|---:|---:|
| Cold helper, 200k | 28.394 / — | 7.652 | 36.680 | 9.274 |
| Cold helper, 50k exchanges | 54.118 / — | 13.840 | 68.609 | 15.701 |
| Hot helper switch, 50k exchanges | 0.032 / 52.267 | 16.990 | 69.955 | 18.868 |

The 200k case sits near the default deadline and can fall on either side;
the original failure and this successful diagnostic are both retained.

| Size | Checkpoint opening: inherited-plan scan (s) | Cold desktop index (s) | First index crossing checkpoint (s) | Host CPU to checkpoint first draw (s) | Host current / peak footprint at that draw (MiB) |
|---|---:|---:|---:|---:|---:|
| 10k | 0.510 | 1.273 | 1.338 | 1.109 | 52.3 / 96.6 |
| 50k | 1.844 | 5.462 | 6.515 | 2.474 | 67.7 / 412.1 |
| 200k | 7.134 | 22.586 | 26.599 | 7.914 | 80.6 / 1596.8 |
| 50k-exchanges | 14.459 | 46.358 | 54.851 | 15.524 | 76.2 / 2984.7 |

### Helper open and history — Release, unprofiled

Direct stdio calls to the same Release helper, including display-transfer reassembly. Times below are wall milliseconds; CPU seconds and peak physical footprint are separate. No provider turn is sent. Cold open includes replay and real checkpoint publication. Warm means a fresh helper process opening that checkpoint, not a previously replayed runtime.

| Size | Cold open ms / CPU s / peak MiB | Checkpoint open ms / CPU s / peak MiB | Warm first older page ms / CPU s / peak MiB | Warm next position page ms | Checkpoint bytes |
|---|---:|---:|---:|---:|---:|
| 10k | 1408.84 / 1.405 / 132.4 | 11.16 / 0.010 / 5.8 | 1667.74 / 1.740 / 91.2 | 608.23 | 23,538 |
| 50k | 6855.94 / 6.837 / 676.7 | 25.18 / 0.024 / 6.8 | 7126.22 / 7.293 / 457.6 | 612.23 | 30,637 |
| 200k | 27723.90 / 27.661 / 2766.8 | 38.91 / 0.037 / 9.3 | 26148.64 / 26.691 / 1737.2 | 597.32 | 49,442 |
| 50k-exchanges | 52172.16 / 52.005 / 5267.0 | 24.11 / 0.021 / 7.5 | 55178.80 / 55.625 / 3230.1 | 642.75 | 66,002 |

The warm replay peaks are temporary. At 200k the helper returns to about 44 MiB after the older-page request, versus a 1,737 MiB lifetime peak. The cold-open path still holds roughly 1.5 GiB after its history pages. Do not interpret either peak as the 24 MB transcript-window budget. The evidence archive retains every RPC, transfer chunk, opening-page row count, CPU endpoint and final RSS reading.
Cold helper CPU closely tracks elapsed open time: 6.84 / 6.86 seconds at
50k, 27.66 / 27.72 at 200k and 52.00 / 52.17 at 50k exchanges. Replay is
predominantly CPU work in these runs with an unpurged filesystem cache.

### What the opening path is doing

The UI waits for `WorkspaceModel.readInheritedSubagents` before reading its
first page. `HistoryReader.subagentPlans` has a process-local revision cache,
but its first lookup scans the whole file, including chats with no inherited
plans. `subagentRecords` already streams 64 KiB chunks: this is **not** a
proposal to replace a whole-file `Data(contentsOf:)` call. The measured scan
still reads 170.6/688.4/1,286.4 MiB before a checkpoint-backed first viewport.
The temporary footprint rises with file size and falls after opening; an
allocation/autorelease investigation is needed before attributing every byte
to a particular allocation site. The opening profile captures this scan on a
worker, not a multi-second block of the main thread.

The desktop index is a bounded SQLite metadata index, currently temporary
and discarded with its reader. A checkpoint can supply total positions and a
small tail in milliseconds, but the first older page requires the full
index. The helper likewise opens the checkpoint quickly, then
`AgentSession.wholeJournalReplay` reparses the complete journal when it first
needs older history. These are separate costs from drawing the first tail.
The direct helper measurements above include the real checkpoint write in
cold `session.open`; they do not isolate a checkpoint-write-only duration.

The 30-second acknowledgement failures are product behavior in this baseline,
not skipped measurements. A diagnostic with the existing test-only timeout
injection set to 180 seconds permits the larger helper-owned scroll trials.
That does not demonstrate that the production deadline works. The fixture
also extends its in-memory idle grace to 7,200 seconds so a live-helper trial
stays helper-owned; normal idle retirement at 120 seconds is separately
identified. No owner preference is read or changed.

<!-- PERF136_TABLES_BEGIN -->
### Scrolling — Release, accepted paced runs

480 points per steady input frame; 70 steady + 30 momentum + 180 quiet frames per burst. Milliseconds unless marked seconds. `B/A` is blank observations during active input / active observations. Thresholds are counts above 16.7 / 33 / 50 / 100 ms. `J/V` is raw geometry corrections / verified visible-row jumps. `†` uses the labelled 180-second helper acknowledgement diagnostic; baseline 30-second failures are above. `‡` separates Find from the scroll trial after the combined run failed the load limit; the scrolling protocol is unchanged.

| Trial / direction | Seconds / intervals | p95 / max ms | >16.7 / 33 / 50 / 100 | Blank / B/A | J/V | Longest observed blank ms |
| --- | --- | --- | --- | --- | --- | --- |
| helper-10k / up | 99.13 / 5049 | 45.10 / 305.65 | 2516 / 643 / 162 / 21 | 398 / 288/1810 | 5/0 | 2235.01 |
| helper-10k / down | 94.39 / 4824 | 43.77 / 393.61 | 2464 / 673 / 122 / 10 | 323 / 139/1765 | 0/0 | 3900.90 |
| journal-10k / up | 110.70 / 5711 | 46.02 / 306.40 | 2849 / 636 / 182 / 20 | 295 / 295/2100 | 5/0 | 1557.40 |
| journal-10k / down | 91.71 / 4773 | 43.20 / 270.64 | 2418 / 589 / 114 / 10 | 352 / 240/1714 | 0/0 | 3478.95 |
| helper-50k / up | 131.18 / 6846 | 43.95 / 241.90 | 3401 / 790 / 186 / 19 | 419 / 325/2500 | 5/0 | 1795.42 |
| helper-50k / down | 113.58 / 5958 | 40.85 / 385.64 | 3054 / 648 / 131 / 15 | 457 / 346/2179 | 0/0 | 2208.45 |
| journal-50k / up | 114.10 / 5991 | 42.38 / 239.42 | 2993 / 633 / 142 / 25 | 262 / 262/2200 | 4/0 | 1369.67 |
| journal-50k / down | 65.85 / 3430 | 42.00 / 999.64 | 1732 / 404 / 78 / 5 | 420 / 215/1271 | 0/0 | 6310.95 |
| helper-200k†‡ / up | 140.61 / 7119 | 47.33 / 293.68 | 3631 / 912 / 280 / 28 | 464 / 316/2600 | 4/0 | 1961.78 |
| helper-200k†‡ / down | 128.47 / 6743 | 40.63 / 288.42 | 3411 / 749 / 123 / 22 | 609 / 440/2424 | 0/0 | 2082.69 |
| journal-200k / up | 111.29 / 5429 | 50.11 / 336.00 | 2748 / 811 / 278 / 25 | 201 / 201/2000 | 4/0 | 1208.60 |
| journal-200k / down | 18.11 / 844 | 47.74 / 179.53 | 438 / 209 / 26 / 3 | 46 / 46/305 | 0/0 | 1142.20 |
| helper-50k-exchanges† / up | 111.86 / 5791 | 44.45 / 323.33 | 2911 / 736 / 185 / 19 | 431 / 308/2100 | 2/0 | 2289.09 |
| helper-50k-exchanges† / down | 94.54 / 5040 | 39.56 / 268.64 | 2579 / 512 / 75 / 12 | 575 / 310/1801 | 0/0 | 4636.99 |
| journal-50k-exchanges / up | 121.04 / 6268 | 44.76 / 241.97 | 3173 / 744 / 180 / 19 | 219 / 219/2300 | 2/0 | 1450.47 |
| journal-50k-exchanges / down | 20.20 / 925 | 50.31 / 114.17 | 491 / 231 / 51 / 5 | 44 / 44/386 | 0/0 | 960.51 |

Frame-observed read episode → new rows visible includes cancellations/retries; its precision is the observation cadence. These episodes differ from individual source calls and include travel/dwell before new rows enter view, so they are not all blank-screen delay. Longest-blank values above are durations of observed low coverage; any trailing censored spans remain marked in the archive. Upward coverage is twelve settled visible windows (at least ten requested pages), or the first edge.

| Trial | Up windows / coverage | Up episode p50 / p95 / max ms (n) | Down episode p50 / p95 / max ms (n) | Down reached end |
| --- | --- | --- | --- | --- |
| helper-10k | 12 / True | 2335.79 / 3731.60 / 17678.14 (10) | 4551.74 / 4659.21 / 13817.96 (5) | True |
| journal-10k | 12 / True | 1393.13 / 4583.81 / 4833.84 (8) | 3550.45 / 4903.45 / 16119.12 (4) | True |
| helper-50k | 12 / True | 3058.99 / 12516.23 / 13757.98 (11) | 2096.45 / 4361.92 / 11374.82 (6) | True |
| journal-50k | 12 / True | 1477.80 / 4423.48 / 5197.55 (7) | 5702.27 / 5702.27 / 6400.96 (2) | True |
| helper-200k†‡ | 12 / True | 2753.73 / 14194.90 / 19227.31 (12) | 1909.16 / 13342.99 / 23305.00 (7) | True |
| journal-200k | 12 / True | 1307.56 / 5130.75 / 5319.24 (7) | 1343.25 / 1343.25 / 1343.25 (1) | True |
| helper-50k-exchanges† | 12 / True | 1764.54 / 3447.93 / 4008.95 (8) | 1284.82 / 14806.20 / 20417.83 (6) | True |
| journal-50k-exchanges | 12 / True | 1525.40 / 4798.85 / 4936.11 (7) | 0.00 / 0.00 / 0.00 (0) | True |

Source calls, cancellation and eviction are separated by direction. Return-trip readmissions are expected after bounded-window eviction; the upward readmission count is the stronger same-direction thrash check. Read MiB counts decoded record bytes, including canceled work, not physical disk misses.

| Trial / direction | Calls / canceled / returned | Completed source p95 / max ms | Decode MiB | Publications / added / evicted / readmitted |
| --- | --- | --- | --- | --- |
| helper-10k / down | 61 / 53 / 8 | 1658.39 / 1678.69 | helper IPC | 8 / 4477 / 4521 / 4477 |
| helper-10k / up | 150 / 136 / 13 | 1591.19 / 2192.15 | helper IPC | 13 / 5161 / 3568 / 0 |
| journal-10k / down | 191 / 182 / 9 | 206.60 / 288.73 | 61.16 | 7 / 4072 / 3509 / 3403 |
| journal-10k / up | 242 / 229 / 13 | 249.44 / 298.84 | 59.35 | 16 / 5267 / 4222 / 0 |
| helper-50k / down | 214 / 205 / 9 | 1773.74 / 1903.99 | helper IPC | 9 / 4579 / 5029 / 3939 |
| helper-50k / up | 174 / 160 / 13 | 1576.75 / 1599.74 | helper IPC | 13 / 4992 / 4550 / 0 |
| journal-50k / down | 222 / 217 / 5 | 196.48 / 230.84 | 62.99 | 5 / 2325 / 3995 / 2325 |
| journal-50k / up | 218 / 205 / 13 | 268.03 / 308.72 | 62.66 | 16 / 5500 / 3918 / 0 |
| helper-200k†‡ / down | 226 / 214 / 12 | 1714.04 / 2012.88 | helper IPC | 12 / 6716 / 5557 / 6206 |
| helper-200k†‡ / up | 161 / 147 / 13 | 1908.68 / 2150.86 | helper IPC | 13 / 6698 / 6354 / 0 |
| journal-200k / down | 23 / 21 / 2 | 21.93 / 185.82 | 9.75 | 2 / 668 / 2169 / 668 |
| journal-200k / up | 157 / 145 / 12 | 225.32 / 251.31 | 47.73 | 17 / 6874 / 5429 / 0 |
| helper-50k-exchanges† / down | 196 / 185 / 11 | 1365.27 / 2339.85 | helper IPC | 10 / 4655 / 5767 / 3497 |
| helper-50k-exchanges† / up | 139 / 127 / 12 | 1484.39 / 1929.73 | helper IPC | 17 / 6946 / 5974 / 0 |
| journal-50k-exchanges / down | 25 / 23 / 2 | 19.30 / 216.27 | 6.16 | 1 / 560 / 1878 / 560 |
| journal-50k-exchanges / up | 174 / 161 / 13 | 204.40 / 237.87 | 56.56 | 17 / 7565 / 5844 / 0 |

### Wheel-rate control — Release

120 points per steady frame, 70 steady + 30 momentum + 180 quiet frames; up to 180 seconds per direction. This is a separate slower-input sensitivity check, not the same protocol as the paced matrix.

| Source / direction | Seconds / intervals | p95 / max ms | >16.7 / 33 / 50 / 100 | Active blank / observations | Up windows / down reached | Calls / canceled / returned |
| --- | --- | --- | --- | --- | --- | --- |
| helper-50k / up | 180.00 / 10313 | 29.00 / 267.67 | 5007 / 404 / 97 / 12 | 184 / 3700 | 7 | 67 / 59 / 8 |
| helper-50k / down | 176.24 / 10421 | 22.57 / 217.82 | 4998 / 132 / 24 / 4 | 125 / 3762 | True | 43 / 40 / 3 |
| journal-50k / up | 180.02 / 10355 | 23.93 / 276.23 | 5031 / 297 / 107 / 10 | 0 / 3700 | 4 | 6 / 1 / 5 |
| journal-50k / down | 173.34 / 10369 | 20.19 / 86.51 | 4969 / 11 / 4 / 0 | 0 / 3710 | True | 0 / 0 / 0 |

### Drags, edge impulses, Find and resize — Release

Drag fractions are .17, .73, .39 and .91. An edge impulse is the explicit synthetic ±100,000,000-point wheel event, followed by a Home/End check; it is not a physical-trackpad fling claim. `!` means the target was not reached at the observation deadline.

| Trial | Four drags ms | Impulse first / last ms | Home / End ms | Resize p95 / max ms | Resize >16.7 / 33 / 50 / 100; blank |
| --- | --- | --- | --- | --- | --- |
| helper-10k | 1162.41 / 5449.76 / 3644.71 / 11819.99 | 1343.44 / 30014.65! | 0.47 / 1405.86 | 55.32 / 65.80 | 43 / 39 / 10 / 0; 0 |
| journal-10k | 819.13 / 1183.89 / 1154.82 / 1245.85 | 302.62 / 30007.15! | 0.54 / 267.49 | 63.48 / 100.73 | 43 / 36 / 16 / 1; 0 |
| helper-50k | 3300.31 / 11923.12 / 2000.85 / 5776.48 | 1240.32 / 30010.42! | 0.51 / 5.02 | 76.44 / 86.69 | 35 / 35 / 25 / 0; 0 |
| journal-50k | 911.64 / 2070.17 / 814.62 / 465.40 | 271.25 / 30002.11! | 0.54 / 3.85 | 91.72 / 190.50 | 32 / 30 / 20 / 1; 0 |
| helper-200k†‡ | 2881.98 / 4274.97 / 3571.79 / 10224.40 | 1481.48 / 30015.13! | 0.57 / 1104.63 | 36.27 / 38.84 | 72 / 7 / 0 / 0; 0 |
| journal-200k | 802.35 / 2389.61 / 927.78 / 2650.81 | 284.59 / 30008.12! | 0.48 / 281.09 | 90.66 / 125.89 | 28 / 27 / 23 / 2; 0 |
| helper-50k-exchanges† | 1219.33 / 6136.66 / 1664.20 / 6158.21 | 1066.29 / 30017.56! | 0.42 / 1287.59 | 53.83 / 66.03 | 48 / 39 / 6 / 0; 0 |
| journal-50k-exchanges | 828.68 / 3442.74 / 925.47 / 3077.20 | 489.24 / 30000.45! | 0.54 / 20.92 | 76.54 / 83.68 | 36 / 31 / 25 / 0; 0 |

Find during the combined scroll trials is observed for at most 60 seconds, followed by five steps. Older probes conflate initial completion and refresh readiness; these are operation observations, not comparable first-scan timings. A ready step may reach only a partial result set. The dedicated full-scan trials below verify global counts and wrap.

| Trial | Observation ms / hits / ready | First highlighted match ms | Steps ready / attempted | Step min / max ms | Last step record |
| --- | --- | --- | --- | --- | --- |
| helper-10k | 43181.81 / 5 / True | 13460.42 | 5 / 5 | 1342.72 / 2851.41 | a1004_z |
| journal-10k | 43019.74 / 5 / True | 11236.98 | 5 / 5 | 410.68 / 603.87 | a1004_z |
| helper-50k | 60006.66 / 11 / False | 19478.80 | 5 / 5 | 1344.09 / 2942.66 | a3012_z |
| journal-50k | 60012.55 / 13 / False | 11335.13 | 5 / 5 | 407.14 / 551.74 | a3012_z |
| journal-200k | 60013.92 / 13 / False | 13670.59 | 5 / 5 | 407.21 / 529.70 | a3012_z |
| helper-50k-exchanges† | 60015.82 / 0 / False | not drawn in observation | 5 / 5 | 1402.30 / 4955.27 | a251_z |
| journal-50k-exchanges | 60019.34 / 13 / False | 11790.05 | 5 / 5 | 428.83 / 539.19 | a3012_z |

Full Find scans use the journal reader, also the production search path for a helper-owned chat. The helper-labelled trial additionally routes hit navigation through the live helper. Each scans `perfneedle`, then steps +1,+1,-1,-1,-1, wrapping from the first to the last global match. Full precision and every step/frame budget are in the archive.

| Find trial | First highlighted match ms | Initial scan ms / matches / complete | Five step ms | Final wrapped record |
| --- | --- | --- | --- | --- |
| find-complete-10k | 13428.10 | 24870.29 / 5 / True | 355.83 / 563.25 / 540.05 / 449.53 / 431.43 | a1004_z |
| find-complete-200k | 13320.49 | 401912.93 / 106 / True | 407.60 / 493.67 / 445.76 / 389.56 / 400.52 | a26355_z |
| find-complete-50k | 12987.90 | 111167.02 / 27 / True | 388.25 / 546.46 / 441.87 / 397.57 / 464.92 | a6526_z |
| find-complete-50k-exchanges | — | No accepted full-scan result | — | — |
| find-complete-helper-200k-ack180 | — | No accepted full-scan result | — | — |

### CPU, memory and main-queue responsiveness — Release

Endpoints cover the named complete trial, including opening, any Find and resize (and 50k desktop scrolling also includes streaming). Full-Find trials are listed separately. CPU is cumulative process user + system seconds; peaks are lifetime physical footprint, not retained transcript bytes.

| Trial | App CPU s / current / peak MiB | Helper CPU s / current / peak MiB | Main-queue >100 ms count / max ms | Peak temporary index MiB |
| --- | --- | --- | --- | --- |
| helper-10k | 239.10 / 113.96 / 178.02 | 102.42 / 69.96 / 103.30 | 39 / 375.73 | 4.50 |
| journal-10k | 201.17 / 100.86 / 198.61 | — | 40 / 346.10 | 4.50 |
| helper-50k | 265.81 / 158.85 / 412.78 | 103.99 / 41.99 / 438.35 | 33 / 370.33 | 23.23 |
| journal-50k | 218.24 / 158.82 / 413.32 | — | 28 / 1054.65 | 23.23 |
| helper-200k†‡ | 225.62 / 99.05 / 1596.99 | 132.16 / 83.95 / 1663.01 | 47 / 277.69 | 0.00 |
| journal-200k | 233.50 / 152.98 / 1596.94 | — | 39 / 417.57 | 96.82 |
| helper-50k-exchanges† | 263.70 / 206.24 / 2985.59 | 184.69 / 135.88 / 3292.65 | 34 / 307.11 | 183.43 |
| journal-50k-exchanges | 259.83 / 149.77 / 2985.91 | — | 29 / 319.54 | 183.43 |
| find-complete-10k | 42.50 / 105.71 / 132.88 | — | 9 / 198.09 | 4.50 |
| find-complete-200k | 464.15 / 190.37 / 1597.43 | — | 6 / 282.13 | 96.82 |
| find-complete-50k | 138.26 / 192.68 / 413.32 | — | 6 / 221.58 | 23.23 |
<!-- PERF136_TABLES_END -->

### What happens while scrolling

`TranscriptPage` starts an edge read within three viewports, with a minimum
2,400-point lead in the travel direction; the opposite edge normally uses
240 points. Farther into unloaded scroll room, `jumpToHistoryPosition`
replaces the window at an ordinal. A different desired ordinal cancels a
modern helper/journal read even when the new destination is nearby. The
fixed 2,400-point lead is only about 83 ms at the fast protocol's nominal
28,800 points/second, or 333 ms at 120 points/frame. These are calculations
from the input protocol, not measured page latencies.

In the accepted 50k desktop upward phase, 205 of 218 source calls are
canceled. Completed calls have p95 268 ms / maximum 309 ms, but the visible
read episodes reach 5.20 seconds. Canceled and completed decoding reads
62.66 MiB; it is file-byte work, not a physical-disk cache-miss count. The
helper equivalent cancels 160 of 174 calls; completed calls have p95
1.58 seconds while visible episodes reach 13.76 seconds. There is already
cooperative cancellation and a bounded physical helper-command slot;
adding a second cancellation mechanism would not address this scheduling
problem.
The cancellation percentage is a request count, not a percentage of CPU
wasted: many requests stop before decoding a complete page.
Across all four accepted desktop paced runs, the upward/downward phases
contain **zero full-index rebuilds and zero fingerprint reads**. Stable
file identity reuses those results. Repeated page decoding is the relevant
hot scrolling work; full-index construction is an opening/first-history cost.
The same 50k traces show longest consecutive low-coverage spans of
1,369.67 / 1,795.42 ms upward and 6,310.95 / 2,208.45 ms returning,
desktop / helper. Those completed observation spans are distinct from
read-to-visible episodes containing travel/dwell, and directly quantify
the driver's blank-coverage condition. They are still geometry observations,
not pixel captures.

At one-quarter the wheel step with the same quiet frames, the accepted
50k desktop control has no low-coverage observations: interval p95 is
23.93 ms upward and 20.19 ms returning, but an upward hitch still reaches
276.23 ms. It covers only four settled windows in 180 seconds, and the
return publishes no new window. That shorter, resident return is not a
matched-distance or matched-eviction comparison with the twelve-window
fast protocol. It supports rate/coverage sensitivity and remaining
main-thread hitches, not a claim that ordinary wheel scrolling is always
free of blanks. Its 58.70-second read-to-visible episode also demonstrates
why prefetch/travel time must be separated from empty-viewport time.

Reading/decoding is asynchronous. Publication still builds/measures rows
and places the document on the main thread: the 50k desktop upward phase
spends 8.49 seconds in row-host building in total, and its separate profile
captures measurement, host creation and placement. The existing idle
scheduler admits work with a 1.5 ms budget; a single expensive admitted
unit can overrun it. Main-queue delays and interval counts include async
publication, while the frame's `workMS` includes only its explicit input/
draw slice.

No upward published row is readmitted after eviction in either accepted
50k source. The return journey readmits 2,325 desktop / 3,939 helper rows,
as expected for a bounded resident window. Thus these runs demonstrate
repeated canceled reads and expected return reads, not proven same-direction
eviction/re-read thrashing. Partial canceled decode overlap is not resolved
to exact byte ranges by this probe. The correct first experiment is request
coalescing/read-ahead; changing the window cap alone has weaker evidence.

Reaching the end does not prove that the return retraced every page. The
200k desktop return publishes only two windows after twelve settled upward
windows: one beginning at `u25783`, then the tail at `u26442`. Its wheel
input totals about 114,107 points, versus 744,714 upward, while estimated
document height ranges from 8.01 to 8.31 million points on the return.
That is an additional navigation-continuity concern to investigate with
per-frame ordinal/clip tracking, especially after FOLD-GAP. The current
visible-row check cannot verify continuity across blank/unloaded room;
the absence of a verified row jump does not clear that transition.

### Find scan lifecycle — Release

The exact completion probe gives **24.870 s / five hits** at 10k,
**111.167 s / 27 hits** at 50k and **401.913 s / 106 hits** at 200k.
All three verify the expected count, a usable highlight, and five successful
navigation steps ending at the last global match (`a1004_z` / `a6526_z` /
`a26355_z`). The 200k first highlight takes 13.320 seconds; its five steps
take 390–494 ms. All three have already started a refresh at the
next observed frame. The journals are static; navigating to a hit changes
the presented page, and the pane's `presentationChanges` subscription marks
Find content dirty. Suppressing a refresh must distinguish that from a real
change in searchable content, not simply ignore all presentation events.

The separate accepted 50k refresh profile waits twenty seconds after the
first completion. The application consumes **17.813 CPU seconds** during
that diagnostic interval. Its main thread is waiting in 588/613 sampled
observations, while a worker is again in `SearchCache.store` (269) and
SQLite step (304). The refresh is canceled when the probe closes Find,
22.384 seconds after it started. Those are **profiled diagnostic** costs,
not an unprofiled before/after comparison or a measured complete-refresh
duration. The initial result set stays usable throughout.

The earlier 10k combined-readiness result (46.118 s) and the rejected 50k
attempts which had all 27 hits while still searching are retained in the
archive. They must not be presented as first-scan timings. No production
Find optimization accounts for the revised numbers; the completion
instrumentation separates the work that was previously conflated.

The separate **helper-owned 200k full-Find trial has no accepted timing**:
all three attempts exceeded the load limit (4.32, 4.32, 4.11) before
completion. Its accepted scrolling/drag/resize case is the `-split-find`
trial. The desktop 200k scan verifies all 106 global matches, but that does
not replace the missing full helper-owned navigation timing. Rerun
`find-complete-helper-200k-ack180` in a quieter window with the command
environment above. Rejected partial scans are retained as diagnostics,
not extrapolated into full-scan results.

The **375k-message desktop full-Find scan also has no accepted completion**.
Five launched attempts exceeded the load limit (4.23, 4.06, 5.98, 4.06,
4.63); a sixth attempt record is the pre-launch wrapper failure noted above.
Even the final run, starting at load 1.37 with a 1.5 start limit, was
rejected. The accepted 375k scrolling case retains its 60-second censored
Find observation and steps, not a completed global result set. Use
`--suite find --sizes 50k-exchanges --resume` in a quieter window to finish
this measurement; no full-scan duration is inferred from rejected progress.

### Streaming and accounting — Release

`stream-verified-50k-1` opens the full 50,016-message journal, then delivers
120 native assistant-row updates in each mode. This reuses the
`SessionDisplay.replaceMessage` boundary used by `TranscriptFrameBudgetTests`.
It measures display delivery, not provider traffic, helper snapshot transport
or journal appends. The window contains 581 rows (50,070 total positions
after the two synthetic live rows). Away means 3,000 points up within the
resident history, not an evicted far-history page.
The streaming phases attached to the earlier
`scroll-paced480-journal-50k-3` did not verify reader mode and are diagnostic
only. Its whole-trial CPU endpoint still includes that delivery work; the
following/away comparison here uses the separate verified trial.

| Verified state | Delta mean / max ms | Frame intervals | >16.7 / 33 / 50 / 100 ms | Frame p95 / max ms | Blank |
|---|---:|---:|---:|---:|---:|
| Following; stream on screen | 18.92 / 40.20 | 240 | 240 / 43 / 5 / 0 | 43.38 / 60.92 | 0 |
| Away; stream off screen | 21.57 / 50.31 | 240 | 240 / 67 / 14 / 1 | 50.28 / 158.30 | 0 |

Both modes verify `pageFollowsBottom` before/after and deliver all 120
updates: 118 incremental appends and two rebuilds each. The away endpoint
is 5,400 points from the end. Document-update clocks total 2,224.75 / 2,502.22
ms, versus only 4.65 / 7.31 ms in the explicit text-layout clock. The
completed trial uses 19.57 CPU seconds and ends at 84.88 MiB current /
413.02 MiB peak footprint, including opening. Passive observation's `workMS`
covers its explicit draw slice; token delivery is timed separately and is
included in the frame interval. Passive observations do not perform the
wheel driver's row-displacement checks, so their zero jump fields are not
a separate proof of anchor stability.

The text intentionally grows one Markdown paragraph, with soft line breaks
and inline code, to about 11 KB. The profile below attributes most update
work to reparsing/reconciling that live tail, including while its existing
host is off screen. This is evidence of a remaining streaming-content cost,
not proof of O(total-history) delivery: only the bounded resident window is
updated. Following runs first; away continues the same growing paragraph.
The two means therefore are not a same-length comparison of reader modes.
The earlier STREAM-1 small/simple-row figures are not a matched
comparison with this coding-agent fixture.

The main journal fixtures contain no retained accounting ledger. Their
page-accounting spans therefore cannot rule out a ledger-related delay in
a real chat. The existing
`AccountingScaleTests.testHundredThousandRetainedAttemptsAndFullVisiblePagePreserveAttributionAndCoverage`
passes separately in Release: 100,000 attempts, 300,100 links, 101 visible
rows; **1,423.879 ms** for the page query, **227.077 ms** for session totals
alone, **242.423 ms** for its single-message case. This is a deliberately
dense attribution stress fixture (many origins per answer), not those same
50k journal rows with normal one/few-origin density. It establishes a
possible additional page cost, not a claim that every real page costs 1.42 s.
`withAccounting` already bounds its pre-publication wait to **150 ms** and
uses existing figures if the query misses that deadline. The late query
continues and its answer is dropped; the full 1.42 s is not a synchronous
UI wait. Repeated heavy queries can still consume worker/database capacity.

### Profiles — Release, separate from baseline timings

Each accepted profile is `sample <fixture-pid> 10 10`. The script waits for
the PID file and, where specified, a log marker. Only generated test-host
and helper PIDs are sampled. The evidence archive includes the complete
stacks, hashes and reproducible category counts. Counts below are inclusive
stack observations, with recursion deduplicated within each category;
categories overlap and worker counts across threads are **not CPU ms**.
The main-thread denominator joins both queue-labelled roots of that thread.

| Profile | Main-thread wait / observations | Dominant sampled work |
|---|---:|---|
| Desktop cold open, 200k | 785 / 800 | `subagentRecords` / plan scan 563; early `HistoryReader.buildIndex` 158; JSON decode 197 |
| Desktop index, 200k, after `draft read` | 791 / 801 | `HistoryReader.buildIndex` 800; JSON decode 322; JSON encode 98; SQLite prepare 136, step 88 |
| Helper cold replay, 200k | 802 / 802 | Replay consumer 599; `JSONByteParser.escapedString` 451 |
| Helper first older page, 200k | 819 / 819 | `wholeJournalReplay` 819; escaped strings 572; JSON decode 19, encode 45 |
| Desktop wheel, 50k, after first cancellation | 136 / 520 | Main: `layoutRows` 97, `RowContainer.measure` 70, row hosts 57, `placeRows` 44, page publication 31. Worker: `decodePage` 170 |
| Helper wheel, 50k, after first cancellation | app 677 / 807; helper 793 / 793 | Helper worker `storedRow` 2,370, escaped strings 1,787, JSON encode 199; app JSON decode 37 off-main |
| Find, 10k | 173 / 495 | Worker `SearchCache.store` 209, SQLite step 227, decode 57; main row measurement 108 and layout 82 |
| Find refresh after first completion, 50k | 588 / 613 | Worker `SearchCache.store` 269, SQLite step 304, prepare 15, JSON decode 74; no sampled main row/layout work |
| Native streaming, 50k | 209 / 673 | Main document update 305; `appendStreaming` 296; Markdown parse/live-tail state 222; TextKit 23 |

The replay stack is `wholeJournalReplay → JournalReplayConsumer.consume →
JSONByteParser.value/object/array/string → escapedString →
UnicodeScalarView.append/map`. It repeatedly parses escaped tool-output
strings. The helper wheel stacks instead read individual stored rows and
encode replies. Cancellation resumes the app's waiter immediately, while
`HostSupervisor` keeps the physical command slot until the helper replies;
the helper checks cancellation between units of work. The multi-worker
profile is evidence of substantial outstanding read work, not proof that
one particular canceled request consumed a stated number of milliseconds.

Desktop page decoding is already on the `HistoryReader` actor; helper page
projection already uses `Task.detached`. The source-window trace's
`main=true` therefore must not be read as a blocking-main duration. During
opening the main thread mostly waits for dependencies. During the desktop
wheel profile, row measurement, host construction and document placement
consume main-thread samples. `HistoryPositions` / scroll-room arithmetic
does not appear as a dominant sampled stack. The rare largest unprofiled
frame is not individually attributed by these separate samples.

Find's cache stack reaches SQLite transaction completion, close and unlink
for individual inserts. The corrected disposable-cache experiment uses
the system SQLite 3.43.2 with its defensive setting left at 1; a request for
`journal_mode=OFF` actually returns `delete`. For 10,000 negative-match rows,
autocommit is 5,526.053 ms, batches of 64 are 116.013 ms, and batches of
5,000 are 32.588 ms; all resulting databases are 352,256 bytes. This does
not bypass defensive mode or change the application's database. It tests
one mechanism, not the speedup of a completed application fix.

### Proposal for discussion before phase B

These are proposed effects and acceptance targets, **not measured speedups of
the app**. No implementation below is in this branch. The first three are the
recommended first tranche by expected benefit and implementation risk.

1. **Keep useful page reads alive and read ahead according to travel speed.**
   The short-dwell 10k desktop run cancelled 247 of 265 window requests. The
   source decoder often takes about 0.18–0.29 seconds, while new visible rows
   typically arrive around a second later; one wait was 7.07 seconds.
   `jumpToHistoryPosition` cancels whenever the desired ordinal differs,
   even when nearby destinations could be served by the same page. Coalesce
   destinations by the page/range already being fetched, retain one useful
   read, and place its result at the latest offset. Start bounded read-ahead
   early enough for measured velocity and read latency; the existing fixed
   screenful margin is shorter than a page read during fast travel.

   Expected effect: reduce empty-viewport waits and repeated partial
   decoding. In phase B, measure request-to-rows-ready separately from
   viewport-demand-to-draw: earlier prefetch can increase the current
   request-to-visible episode simply because the reader has not reached
   those rows yet. Proposed demand-to-draw targets are desktop p95 below
   500 ms and helper p95 below 1.5 s on these fixtures, under 1% active-input blank observations, and no
   verified visible-row jumps. These targets require measurement, especially
   for helper IPC. Risks are a stale page landing after a direction/branch/
   reader change, moving an anchor, excessive speculative work, or evicting a
   pinned selection. Keep lineage/incarnation, navigation and selection
   checks authoritative. No stored-data or migration change. Prove with the
   short-dwell and paced protocols, rapid reversals, drag destinations,
   scrolling during the first index build, edits/appends during a read,
   cancellation, held selections, and unchanged
   resident byte limits. Track ordinal progress through unloaded room and
   verify a steady return does not skip large ranges as height estimates
   change. Re-read counts on the return journey are expected;
   same-direction repeated reads are the stronger thrashing signal.

2. **Remove the full inherited-plan scan from the first-paint dependency.**
   Checkpoint-backed first paint spends 1.84/7.13/14.46 seconds in that scan
   at 50k/200k/50k exchanges. Read the tail first, then enrich presentation
   with verified inherited-agent information, or populate a small revision
   cache alongside the existing metadata work. The arithmetic upper bound
   is removal of those serial seconds, not a promised end-to-end result;
   target a checkpoint-backed viewport below 500 ms, then account for any
   remaining first-paint work. Also measure peak allocation while bounding
   temporary Foundation objects inside the existing streaming scan.

   Risks: changing inherited labels or card geometry while the reader moves,
   showing stale agent availability, or accidentally treating cached
   presentation as authority. `InheritedSubagent` is explicitly presentation
   evidence; original-availability, reciprocal-origin, trust, permission and
   cost-owner checks must remain authoritative. Keep copied/forked journals,
   missing children and changed plans in the proof set. Deferral and an
   in-process cache need no migration. A persistent plan summary would use
   the additive, disposable cache contract described below, not a journal
   rewrite. Prove first-paint timing, peak footprint, anchor stability and
   the existing inherited-agent/permission tests.

3. **Remove avoidable Find rescans, then batch its disposable cache writes.**
   The revised 10k probe measures the first full scan at 24.87 seconds,
   with all five hits and a usable highlight. A refresh starts about 4 ms
   later, while those same hits remain usable. The older 46.1-second
   combined-readiness observation is not a first-scan timing and the
   difference is not a speedup: no Find behavior changed. This static
   50k fixture takes 111.17 seconds for its first scan, finds all 27 hits,
   and likewise has a refresh already running at the next observed frame;
   five steps, including the global wrap, succeed in 388–546 ms. The
   fixture has no journal appends or edits. `presentationChanges` calls
   `contentChanged`, and a pending refresh restarts the full query as soon
   as its previous scan finishes. Separate page-only presentation changes
   from changes to searchable content before requesting another full scan.
   This removes avoidable follow-up work; it does not shorten the initial
   scan by itself. Prove no repeat scan on unchanged history page arrivals,
   while preserving refresh after actual edits, live tokens, task/agent
   changes, fetched inputs and changes in searchable tool presentation.

   Samples show `HistoryOffsetIndex.SearchCache.store` entering SQLite
   transaction completion, file deletion and close paths for individual
   records. The system SQLite's defensive default rejects `journal_mode=OFF`
   by leaving `DELETE` selected; the code checks the SQL status, not the
   returned mode. A generated 10,000-insert microbenchmark with that policy
   takes 5,526 ms in autocommit, 116 ms in batches of 64, and 32.6 ms in
   batches of 5,000. These are **cache-write microbenchmarks**, not whole-Find
   speedups. Do not disable SQLite's defensive mode as the fix.

   Expected first-scan improvement from batching is material but much smaller than the
   microbenchmark ratio; use a provisional 20–40% target and measure it.
   Keep transactions bounded around work batches and statements reusable,
   while preserving yields so a page read can interrupt a search. A smaller
   first search batch is a separate experiment for first-result latency.
   Risks: stale results after an incorrectly suppressed refresh, retaining
   an open transaction across cancellation, replacing a
   continuation under a newer query, leaking cache tables, or blocking other
   reader work. Prove whole-chat hit/order/count/Unicode/tool-ownership parity,
   cancellation and query replacement, bounded memory/disk, and concurrent
   page latency. The cache is temporary today: no stored-data migration or
   downgrade issue is required for batching it.

4. **Replace whole-body helper history replay with bounded metadata reads;
   persist reusable offset/turn indexes if the cold-index cost remains.**
   A warm helper's first older page costs 7.13/26.15/55.18 seconds and reaches
   transient peaks of 458/1,737/3,230 MiB at 50k/200k/50k exchanges. Cold open
   reaches about 5.1 GiB at the largest size. The replay sample spends most
   of its active worker observations parsing JSON strings, especially escaped
   tool-output text. Reuse the metadata/offset approach already used for
   historical edits and decode only the requested whole-turn page. A faster
   UTF-8 escaped-string path is a smaller, format-preserving experiment if
   replay must remain, but must preserve existing JSON acceptance/rejection,
   UTF-8 validation and surrogate handling.
   In the older-history sample, escaped strings account for 572 of 819
   replay observations. As a sensitivity calculation, making just that work
   five times faster would leave about 44% of the sampled replay CPU work;
   this is not a measured app speedup and would not remove retained payloads.

   Expected effect: bound historical payload memory and avoid decoding most
   old output bodies. A validated persistent index could remove the measured
   5.46/22.59/46.36-second desktop cold-index pass on subsequent opens, and the
   6.51/26.60/54.85-second checkpoint-crossing pass. Cold cache construction
   would still cost time; no subsecond cold-open promise is made. Risks are
   branch/compaction/presentation replay correctness, edited/truncated files,
   append races, runtime handoff and crash recovery. This is a larger change
   than the first three, with a wider proof burden. Reuse existing replay,
   edit, history, cancellation and recovery tests and compare every page and
   position against an uncached read of legacy and generated journals.
   Bound presentation-history reads without replacing authoritative runtime
   restoration, permission or cost-owner checks with cached presentation data.
   The sampled 200k temporary desktop index reaches 74.20 MiB on disk, so
   persistence needs a global cap, eviction and temporary-build headroom.
   Whole trials including Find reach 96.82 MiB at 200k and 183.43 MiB at
   50k exchanges; budget query caches and active builds as well as a saved index.

   **Migration/downgrade contract:** use a versioned derived-cache directory
   with bounded disk use, atomic publication and safe concurrent ownership.
   Keep ownership within the existing vault/workspace boundary and remove
   the cache when its chat is forgotten or deleted.
   Old journals and existing checkpoint versions remain canonical and
   unchanged. Older apps ignore the new cache; missing, corrupt, stale or
   unknown-version caches rebuild. Validate file identity, captured length,
   content/lineage and the actual target record; stat metadata alone is not
   authority. Append extension and edits/truncation need distinct validation.
   This is an additive cache-schema migration, not a user-data conversion.
   The lead must choose its location and disk budget before implementation.

5. **Reduce row construction/measurement and work on the live Markdown tail.**
   The short-dwell desktop up/down run spends 10.3 seconds building row hosts,
   and has 200–253 ms frame intervals at page changes. Existing geometry
   caching, off-main journal decoding and off-main helper projection already
   exist; merely proposing those again would not address the remaining work.
   The wheel profile attributes 97 main-thread observations to layout,
   70 to measurement, 57 to hosts and 44 to placement (overlapping categories).
   Reuse stable hosts and reduce the work in each measurement/publication unit
   without moving the anchor. `TranscriptIdleScheduler` already has a 1.5 ms
   admission budget; it cannot interrupt an expensive unit after it starts.
   Adding another scheduler is not the proposed fix. Re-measure after the
   separate FOLD-GAP branch lands.
   Streaming adds a distinct case: one growing paragraph costs 18.9/21.6 ms
   per native update, following/away, with 222 main-thread parse observations
   versus 23 in TextKit. Bound repeated parsing of unsettled content, or
   defer expensive reconciliation of an off-screen host while retaining
   accurate model text and safe height estimates. Compare both a growing
   paragraph and settled paragraphs/code blocks before choosing the fix.

   Expected effect: reduce the page-arrival spikes even after read scheduling
   is fixed; proposed gates are p95 below 33 ms and no intervals above 100 ms
   in the matched protocol, subject to the lead's hardware target. Risks are
   stale glyphs, selection/accessibility regressions and width/fold-dependent
   heights. Keep the cached-glyph drawing regressions and narrow/resize tests.
   No migration is needed for in-memory reuse. Persistent row-height caches
   are deferred: width, scale, font, theme, disclosure, content and renderer
   version invalidate them, and their measured advantage is not established.
   Live-tail changes must additionally preserve emphasis/link/code-fence
   completion, Unicode, copy/Find text and the held reading anchor. Target
   native delivery below 8 ms for the matched text as a separate phase-B
   experiment; the 50k total alone does not explain this parsing cost.

6. **Tune page/window size or lazy payload transfer only after scheduling.**
   Current limits are 1,000 rows / 4 MiB per whole-turn page, 250 rows at
   opening, and 3,000 rows / 24 MB resident, with two automatic fills. The
   payload mix frequently hits the byte cap before 1,000 rows. Larger pages
   could reduce calls but increase IPC and main-thread publication spikes;
   smaller pages could land sooner but amplify cancellation and overhead.
   Source inspection also finds that the helper hydrates the candidate
   range (`range.map { shown.row($0) }`) before the byte-budget fill. The
   wheel profile is dominated by stored-row parsing, while a direct warm
   50k position page transfers about 3.35 MiB in 612 ms. Test lazy candidate
   decoding before changing the public limits; the exact avoided helper
   read bytes are not instrumented in this phase, so its gain is unproven.
   Compare 250/500/1,000-row policies with the same byte cap and velocity
   trace, changing one variable at a time. Do not simply increase residency.
   Lazy folded-tool payloads could reduce multi-megabyte transfers, but copy,
   Find, disclosure and legacy-helper fallback must retain exact content.
   Page/window tuning has no migration; a negotiated lazy-payload wire
   capability would require the wire/concurrent/acceptance gates in phase B.

7. **Avoid repeating unchanged accounting aggregates, if a linked-ledger
   fixture confirms their cost in normal-density chat history.**
   The dense 100k-attempt fixture costs 227 ms for session totals and 1.42 s
   for its page query. The UI already caps its initial wait at 150 ms, so
   this is primarily a candidate to reduce repeated worker/database work
   and missed accounting deadlines, not a demonstrated 1.42-second UI block.
   Cache unchanged session totals by ledger revision and request only newly
   needed message attribution, preserving the existing deadline. First build
   a generated ledger linked to these journals at normal origin density;
   the current stress fixture cannot predict its exact gain. Proposed gates:
   no unchanged session re-aggregation per page, query completion within the
   150 ms budget in that fixture, and unchanged attribution/coverage results.
   Risks are stale cost displays, retention races and crossing session,
   workspace or family ownership. Keep permission/cost-limit authority out
   of presentation caches. In-memory query reuse needs no migration; no new
   persistent accounting schema is proposed here.

A separate correctness decision is needed for long operations and their
loading state: 200k/50k-exchange cold helper opens can exceed the 30-second
acknowledgement deadline, and a failed opening fill leaves its opening flag
set. A longer/progress-aware cancellable wait and an explicit retry/error
state can make these cases usable while deeper work is optimized. Raising
the deadline alone is not a speed improvement. This branch only records the
failure and uses the existing timeout injection for labelled diagnostics.

### Decisions requested from the lead

- Confirm the first tranche: page scheduling, first-paint plan discovery, and
  Find refresh/cache work. Alternatives are to replace Find with bounded
  helper history because 200k+ opens cross the deadline, or with row/live-tail
  work if frame smoothness takes precedence over search latency.
- **Needs owner decision — persistence:** the conservative first tranche
  keeps indexes ephemeral. Later options are to keep that policy, introduce
  a 256 MiB global cache budget, or use a 1 GiB budget, each with separate
  build headroom and vault-scoped ownership in the application's cache root.
  Choose the location/budget before implementation; preserve canonical
  journals and downgrade readability.
- **Needs owner decision — long waits:** conservatively keep the existing
  deadline while showing a correct error/retry state; alternatively permit
  a longer wait while measurable progress continues and Cancel remains
  responsive. Increasing the deadline alone is not a speed improvement.
- Agree the frame/blank/page-latency targets and long-operation cancellation/
  loading behavior, and rerun the same fixtures after FOLD-GAP is merged.

### Focused validation

The Release helper bundle and the isolated Release app/test bundle build.
The generator's two contract tests pass: identical seed/bytes/hash, valid
parent/tool/compaction references and content mix, different seeds, complete
last turns, and refusal to overwrite a fixture. Python compilation and
`git diff --check` pass. No production fix is being claimed, so there is no
before/after or mutation-based fix result in phase A.
The report's **two duration tests pass**, checking that a blank span ends
at the next covered observation, that trailing spans stay censored, and
that missing timestamps cannot supply a duration.

The focused Release checks use the same guarded runner and DerivedData:

```sh
APP=(xcodebuild test-without-building -xctestrun "$RUN[1]" \
  -derivedDataPath "$PI_BUILD_ROOT/release" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -collect-test-diagnostics never)
python3 scripts/perf-longchat-run.py --label regression-history --no-trace \
  --start-load 3.0 -- "${APP[@]}" \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/HistoryTurnPagingTests
python3 scripts/perf-longchat-run.py --label regression-long-chat-scroll-no-trace \
  --no-trace --start-load 2.5 -- "${APP[@]}" \
  -only-testing:PiAppTests/LongChatScrollTests
python3 scripts/perf-longchat-run.py --label regression-find-no-trace \
  --no-trace --start-load 2.0 -- "${APP[@]}" \
  -only-testing:PiAppTests/TranscriptFindTests
TEST_RUNNER_PI_BUILD_ROOT="$PI_BUILD_ROOT" \
  python3 scripts/perf-longchat-run.py --label accounting-scale-100k \
  --start-load 2.0 -- "${APP[@]}" \
  -only-testing:PiAppTests/AccountingScaleTests/testHundredThousandRetainedAttemptsAndFullVisiblePagePreserveAttributionAndCoverage
```

- `HistoryReaderCheckpointTests`: **7 passed**; `HistoryTurnPagingTests`:
  **6 passed**, no failures, 7.38 seconds combined, peak one-minute load 2.70.
- The focused `AccountingScaleTests` case: **1 passed**, 4.75 seconds,
  peak load 1.82; its query measurements are above.
- `TranscriptFindTests`: **12 passed**, no failures, 12.59 seconds,
  peak load 3.18, build 11 with trace disabled.
- `LongChatScrollTests`, final control: **4 cases passed, 2 failed**, with
  four timing assertions. The fling has p95 **56.13 ms** against 50 ms,
  maximum **269.77 ms** against 150 ms, and **6.93%** of intervals above
  50 ms against 5%. Steady upward scrolling has maximum **194.84 ms**
  against 150 ms. Neither case reports a blank or visible-row jump.
  The whole-chat scroller, drag-to-top, Home and streaming cases pass.
  This is build 10 with span logging disabled and the original fixture
  setup order restored; peak load is **3.06**. The preceding control
  attempt exceeded load 4.72 and is excluded.
- An earlier trace-enabled build-9 run had **3 cases passed, 3 failed**,
  six assertions, peak load 2.58. Besides timing failures, its scroller
  knob was 0.6887 at the 0.75 target (tolerance 0.05). Restoring the legacy
  fixture setup and disabling trace are two simultaneous control changes;
  the passing knob control does not isolate either as the cause. These
  failures are retained, not reclassified as a clean gate or silently
  repaired. No performance budget was relaxed.

The old scroll tests are evidence about this measurement host, not a
separately built pristine-base comparison. The new long-chat measurements
and the relevant history/accounting checks are the scope of this phase;
the lead's merged release gate remains separate.

### Comparison with 0.1.131

No same-fixture 0.1.131 timing is claimed. That tag is
`275b442c6297a828a837d91d227d61d8f54d87f2`; an isolated Release binary with
these measurement seams was not available. Rebuilding/backporting the probe
would require a separate validation of its older paging and checkpoint
contracts, and was deferred while keeping one Release DerivedData and the
shared measurement lane available. The earlier SCROLL-1/STREAM-1 records are
useful design history, not matched numbers for these fixtures. Since that
release, the source already gained whole-turn paging, larger bounded windows,
incremental streaming, first-tail drawing before fill, lazy image reads and
cached-width glyph preparation. This record measures what remains on
`21e30eb1`; it does not assign a numerical speedup to 0.1.133–0.1.135.

<!-- PERF136_LOAD_LEDGER_BEGIN -->
### Quiet-window ledger

One-minute load, start / end / observed peak. Exact raw three-value strings, UTC offsets and two-second samples are in the evidence archive. `accepted` means the command passed within the load limit, not that every censored navigation operation landed. `profile` runs support stack attribution only. Calibration, aborted and load-rejected runs are excluded from baseline timing evidence; quiet test failures are reported explicitly.

| Trial | Outcome | Start / end / peak | XCTest passed / failed |
|---|---|---:|---:|
| find-complete-50k-exchanges-2 | aborted: TypeError | — / 1.92 / 4.23 | — |
| smoke-open-1 | calibration | 3.99 / 3.99 / 3.99 | 1 / 0 |
| probe-10k-1 | aborted: Calibration interrupted: cut-in test host overlapped the perf lock; observed load > 44; CPU values pre-calibration | 3.44 / — / — | — |
| prepare-10k-1 | accepted | 2.80 / 2.80 / 2.8 | — |
| helper-cold-10k-1 | accepted | 2.80 / 2.82 / 2.82 | — |
| helper-warm-10k-1 | accepted | 2.82 / 2.82 / 2.82 | — |
| prepare-50k-1 | accepted | 2.75 / 2.69 / 2.75 | — |
| helper-cold-50k-1 | accepted | 2.69 / 2.66 / 2.69 | — |
| helper-warm-50k-1 | accepted | 2.66 / 2.61 / 2.66 | — |
| prepare-200k-1 | accepted | 2.61 / 3.20 / 3.22 | — |
| helper-cold-200k-1 | accepted | 2.78 / 2.54 / 2.78 | — |
| helper-warm-200k-1 | accepted | 2.54 / 2.34 / 2.57 | — |
| prepare-50k-exchanges-1 | accepted | 2.34 / 2.56 / 2.67 | — |
| helper-cold-50k-exchanges-1 | accepted | 2.56 / 2.53 / 2.66 | — |
| helper-warm-50k-exchanges-1 | accepted | 2.53 / 3.02 / 3.23 | — |
| open-journal-cold-10k-1 | accepted | 2.85 / 2.94 / 2.94 | 1 / 0 |
| open-journal-warm-10k-1 | accepted | 2.94 / 3.27 / 3.27 | 1 / 0 |
| switch-journal-10k-1 | accepted | 2.90 / 2.91 / 2.91 | 1 / 0 |
| open-helper-cold-10k-1 | accepted | 2.91 / 2.92 / 2.92 | 1 / 0 |
| open-helper-warm-10k-1 | accepted | 2.92 / 2.70 / 2.92 | 1 / 0 |
| switch-helper-10k-1 | accepted | 2.70 / 2.73 / 2.73 | 1 / 0 |
| open-journal-cold-50k-1 | accepted | 2.73 / 2.77 / 2.77 | 1 / 0 |
| open-journal-warm-50k-1 | accepted | 2.77 / 2.96 / 2.96 | 1 / 0 |
| switch-journal-50k-1 | accepted | 2.96 / 3.12 / 3.12 | 1 / 0 |
| open-helper-cold-50k-1 | accepted | 2.77 / 2.91 / 2.91 | 1 / 0 |
| open-helper-warm-50k-1 | accepted | 2.91 / 2.92 / 3.0 | 1 / 0 |
| switch-helper-50k-1 | accepted | 2.92 / 2.86 / 2.93 | 1 / 0 |
| open-journal-cold-200k-1 | accepted | 2.86 / 2.72 / 2.94 | 1 / 0 |
| open-journal-warm-200k-1 | accepted | 2.72 / 2.59 / 2.72 | 1 / 0 |
| switch-journal-200k-1 | accepted | 2.59 / 2.63 / 2.63 | 1 / 0 |
| open-helper-cold-200k-1 | failed, exit 65 | 2.63 / 2.72 / 2.84 | 0 / 1 |
| open-helper-warm-200k-1 | accepted | 2.72 / 2.35 / 3.04 | 1 / 0 |
| switch-helper-200k-1 | accepted | 2.35 / 3.71 / 3.71 | 1 / 0 |
| open-journal-cold-50k-exchanges-1 | accepted | 2.71 / 2.29 / 2.78 | 1 / 0 |
| open-journal-warm-50k-exchanges-1 | accepted | 2.29 / 2.75 / 2.75 | 1 / 0 |
| switch-journal-50k-exchanges-1 | accepted | 2.75 / 3.08 / 3.1 | 1 / 0 |
| open-helper-cold-50k-exchanges-1 | failed, exit 65 | 2.70 / 2.60 / 2.7 | 0 / 1 |
| open-helper-warm-50k-exchanges-1 | accepted | 2.60 / 2.50 / 3.24 | 1 / 0 |
| switch-helper-50k-exchanges-1 | failed, exit 65 | 2.50 / 2.39 / 2.55 | 0 / 1 |
| find-journal-10k-1 | accepted | 2.88 / 2.92 / 3.06 | 1 / 0 |
| scroll-journal-10k-1 | accepted | 1.67 / 3.44 / 3.44 | 1 / 0 |
| scroll-helper-10k-1 | load rejected | 2.88 / 4.63 / 4.63 | — |
| scroll-helper-10k-2 | load rejected | 2.87 / 4.20 / 4.2 | — |
| scroll-helper-10k-3 | load rejected | 2.43 / 4.54 / 4.54 | — |
| profile-find-10k-1 | profile | 2.66 / 3.54 / 3.54 | 1 / 0 |
| profile-open-journal-200k-1 | profile | 2.82 / 2.57 / 2.82 | 1 / 0 |
| profile-helper-200k-1 | profile | 2.57 / 2.70 / 2.85 | — |
| profile-helper-older-200k-1 | profile | 2.70 / 2.98 / 2.98 | — |
| sqlite-cache-batches-1 | calibration | 2.16 / 2.16 / 2.16 | — |
| scroll120-helper-10k-1 | load rejected | 2.16 / 4.39 / 4.39 | — |
| scroll120-helper-10k-2 | aborted: KeyboardInterrupt | 2.76 / 2.70 / 2.76 | — |
| sqlite-cache-batches-2 | accepted | 2.94 / 3.34 / 3.34 | — |
| scroll-paced480-journal-10k-1 | accepted | 2.93 / 2.93 / 3.11 | 1 / 0 |
| scroll-paced480-helper-10k-1 | load rejected | 2.93 / 4.27 / 4.27 | — |
| scroll-paced480-helper-10k-2 | accepted | 2.94 / 3.63 / 3.8 | 1 / 0 |
| scroll-paced480-journal-50k-1 | load rejected | 2.94 / 4.02 / 4.02 | — |
| scroll-paced480-journal-50k-2 | load rejected | 2.99 / 4.01 / 4.01 | — |
| scroll-paced480-journal-50k-3 | accepted | 2.69 / 2.92 / 3.73 | 1 / 0 |
| profile-wheel-journal-50k-1 | profile | 1.96 / 2.57 / 2.57 | 1 / 0 |
| profile-wheel-helper-50k-1 | load rejected | 1.86 / 5.70 / 5.7 | — |
| profile-wheel-helper-50k-2 | profile | 2.00 / 3.75 / 3.82 | 1 / 0 |
| profile-index-200k-1 | profile | 1.82 / 2.58 / 2.6 | 1 / 0 |
| diagnostic-open-helper-cold-200k-ack180-1 | accepted | 2.00 / 2.39 / 2.66 | 1 / 0 |
| stream-verified-50k-1 | accepted | 1.89 / 2.24 / 2.29 | 1 / 0 |
| profile-stream-50k-1 | profile | 1.98 / 2.13 / 2.13 | 1 / 0 |
| accounting-scale-100k-1 | accepted | 1.80 / 1.82 / 1.82 | 1 / 0 |
| diagnostic-open-helper-cold-50k-exchanges-ack180-1 | accepted | 1.82 / 2.33 / 2.33 | 1 / 0 |
| diagnostic-switch-helper-50k-exchanges-ack180-1 | accepted | 1.85 / 2.68 / 2.68 | 1 / 0 |
| regression-long-chat-scroll-1 | failed, exit 65 | 1.88 / 2.45 / 2.58 | 3 / 3 |
| regression-long-chat-scroll-no-trace-1 | load rejected | 2.32 / 4.72 / 4.72 | 2 / 1 |
| regression-long-chat-scroll-no-trace-2 | failed, exit 65 | 2.31 / 3.06 / 3.06 | 4 / 2 |
| regression-history-1 | accepted | 2.50 / 2.56 / 2.7 | 13 / 0 |
| scroll-paced480-helper-50k-1 | accepted | 1.78 / 3.54 / 3.94 | 1 / 0 |
| wheel-rate120-journal-50k-1 | load rejected | 1.67 / 4.21 / 4.21 | — |
| wheel-rate120-journal-50k-2 | load rejected | 1.74 / 6.21 / 6.21 | — |
| wheel-rate120-journal-50k-3 | load rejected | 1.96 / 4.08 / 4.08 | — |
| find-complete-50k-1 | load rejected | 1.67 / 4.22 / 4.22 | — |
| find-complete-50k-2 | load rejected | 1.99 / 4.03 / 4.03 | — |
| find-complete-50k-3 | load rejected | 1.70 / 4.31 / 4.31 | — |
| scroll-paced480-journal-200k-1 | accepted | 1.85 / 3.12 / 3.14 | 1 / 0 |
| find-complete-10k-1 | accepted | 1.84 / 2.94 / 2.94 | 1 / 0 |
| find-complete-50k-4 | accepted | 1.73 / 3.46 / 3.64 | 1 / 0 |
| profile-find-refresh-50k-1 | profile | 1.96 / 3.66 / 3.88 | 1 / 0 |
| scroll-paced480-helper-200k-ack180-1 | load rejected | 1.88 / 4.04 / 4.04 | — |
| scroll-paced480-helper-200k-ack180-2 | load rejected | 1.80 / 4.26 / 4.26 | — |
| scroll-paced480-helper-200k-ack180-3 | load rejected | 1.90 / 4.05 / 4.05 | — |
| scroll-paced480-journal-50k-exchanges-1 | accepted | 1.98 / 2.80 / 3.15 | 1 / 0 |
| scroll-paced480-helper-50k-exchanges-ack180-1 | accepted | 1.78 / 3.74 / 3.9 | 1 / 0 |
| find-complete-200k-1 | accepted | 1.88 / 3.12 / 3.89 | 1 / 0 |
| find-complete-50k-exchanges-1 | load rejected | 1.83 / 4.23 / 4.23 | — |
| wheel-paced120-journal-50k-1 | accepted | 1.79 / 2.11 / 3.17 | 1 / 0 |
| wheel-paced120-helper-50k-1 | load rejected | 1.99 / 6.16 / 6.16 | — |
| find-complete-50k-exchanges-3 | load rejected | 1.72 / 4.06 / 4.06 | — |
| wheel-paced120-helper-50k-2 | accepted | 1.89 / 2.21 / 3.93 | 1 / 0 |
| regression-find-no-trace-1 | accepted | 1.98 / 3.15 / 3.18 | 12 / 0 |
| find-complete-50k-exchanges-4 | load rejected | 1.92 / 5.98 / 5.98 | — |
| find-complete-50k-exchanges-5 | load rejected | 2.00 / 4.06 / 4.06 | — |
| scroll-paced480-helper-200k-ack180-split-find-1 | accepted | 1.55 / 2.69 / 3.32 | 1 / 0 |
| find-complete-helper-200k-ack180-1 | load rejected | 1.59 / 4.32 / 4.32 | — |
| find-complete-helper-200k-ack180-2 | load rejected | 1.66 / 4.32 / 4.32 | — |
| find-complete-helper-200k-ack180-3 | load rejected | 1.73 / 4.11 / 4.11 | — |
| find-complete-50k-exchanges-6 | load rejected | 1.37 / 4.63 / 4.63 | — |

Ledger outcomes: aborted: Calibration interrupted: cut-in test host overlapped the perf lock; observed load > 44; CPU values pre-calibration: 1, aborted: KeyboardInterrupt: 1, aborted: TypeError: 1, accepted: 56, calibration: 2, failed, exit 65: 5, load rejected: 27, profile: 9.
<!-- PERF136_LOAD_LEDGER_END -->


## Phase B, round 1 (2026-10-29)

The lead authorized three separate commits: external evidence and the baseline
A/B, first paint/opening cleanup, then bounded read scheduling. This branch
keeps the existing page/window limits and the old scroll budgets. Helper
history routing, persistent indexes and Find belong to `dev/a136-hist`;
parser, opening acknowledgement and checkpoint refresh belong to
`dev/a136-json`. No cache or journal migration is made in this round.

### Item 1: evidence and trace-off baseline

The phase-A archive was copied to
`/Users/admin/Library/Caches/BelloSwiftWork/perf-evidence/` and verified against
its SHA-256 above before `git rm`. No binary evidence is added to git.
`perf-longchat-report.py` now defaults to the phase-B archive in that directory
and rejects destinations inside the repository. The record retains hashes
and commands; the external archive retains full arrays and rejected trials.

The report tests first failed with two missing-function errors (2/4 cases),
then passed 4/4. Removing the repository-destination guard produced the
expected assertion failure (1/4); the restored implementation passed.
Logs: `logs/b1-report-{failing-first,mutation,pass}.log` under `PI_BUILD_ROOT`.

The A/B compares `0d6bc320` (A) with `6d38ddd4` (B), each with span tracing
disabled. Both use the same temporary detached worktree, checked out first
at A and then B. A's generated project receives
only B's optional **test-target** compiler settings, so both builds use the
same flags. The application remains Release `-O`, whole-module compilation;
the XCTest bundle uses incremental compilation with the invocation below.
B also compiles the two new opening regression classes for the following
failing-first runs; those tests are not selected during the A/B. The helper source
is identical between these revisions. Both use the same isolated bundle IDs,
single Release DerivedData and generated legacy scroll fixture. The quiet
window runner holds the shared lock only for each measurement, samples load
every two seconds and rejects peaks over 4. The two repetitions per revision
use fresh test processes and fixtures.

While the shared host was busy, B's products were preserved under
`$PI_BUILD_ROOT/baseline-b-products` before rebuilding the same DerivedData
for item 2. The remaining B trial, opening baseline and failing-first tests
use those preserved products, after the build finishes. Their executable
hashes match B's first accepted trial: host
`353519a6898af813abe02a936743642d09e3dba593d230140a4bd5ffea8d622e`,
tests `65f538b7c5eb21ba6982d9538cad014b2a6a90e639535a351a11ed7b19ed416f`.
This is a product copy, not another DerivedData. It is removed after the
baseline finishes; no measurement overlaps our build.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-perf
# In each revision's source tree, after checking the shared measurement lock:
xcodegen generate --quiet
xcodebuild build-for-testing -jobs 2 -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2
# LABEL is b1-ab-{a,b}-r{1,2}; RUN is the sole .xctestrun in Build/Products.
python3 scripts/perf-longchat-run.py --label "$LABEL" --no-trace \
  --start-load 2.5 --attempts 5 -- \
  xcodebuild test-without-building -xctestrun "$RUN" \
  -derivedDataPath "$PI_BUILD_ROOT/release" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:PiAppTests/LongChatScrollTests
```

All four accepted A/B trials executed six cases: **4 passed / 2 failed**, with
five timing assertions per trial. The same cases fail on both revisions:
`testAFlingToTheFirstMessageNeverStopsOrJumps` and
`testScrollingToTheFirstMessageAndBackIsSmooth`.

| Release, trace off | Accepted trial | 1-minute load start / end / peak | Fling p95 / p99 / max (ms) | Fling >50 ms | Steady up p95 / max (ms) |
|---|---|---|---|---|---|
| A `0d6bc320` | `b1-ab-a-r1-2` | 2.33 / 2.70 / 2.77 | 60.3 / 121.8 / 250.2 | 35/462 (7.58%) | 28.8 / 178.2 |
| A `0d6bc320` | `b1-ab-a-r2-3` | 2.21 / 2.46 / 2.96 | 57.1 / 109.2 / 215.5 | 33/463 (7.13%) | 27.7 / 155.0 |
| B `6d38ddd4` | `b1-ab-b-r1-3` | 2.30 / 3.03 / 3.44 | 69.0 / 133.6 / 175.0 | 43/463 (9.29%) | 31.1 / 256.8 |
| B `6d38ddd4` | `b1-ab-b-r2-1` | 2.05 / 3.26 / 3.26 | 62.6 / 123.9 / 255.9 | 39/463 (8.42%) | 30.3 / 197.8 |

The unchanged budgets are p95 ≤50 ms, p99 ≤100 ms, maximum ≤150 ms and
≤5% of frames over 50 ms. The fling exceeds all four; steady up exceeds the
maximum. Steady down maxima are 140.9 / 133.2 / 114.6 / 136.2 ms in the
same order. The fling/steady probes record zero jumps in all four trials;
B's second fling records one blank observation, the other three zero, and
steady up/down record zero. The drag/scroller probes do have blanks; these
figures are not a claim that the entire suite is blank-free. Full legacy
summaries and all test assertions are retained in the external archive.

**Conclusion:** these two failures were already present before phase A's
instrumentation. B does not fix them. Its fling p95 is higher in both pairs,
while maxima are mixed; this sample establishes pre-existing failures, not
latency parity or absence of a regression. A→B changes in app sources are
confined to the phase-A test-host instrumentation. All old budgets remain
unchanged and will be rerun after scheduling. A/B tracing is off, so it does
not provide source-cancellation counts or a new profile attribution.

Rejected A/B attempts remain in the evidence: A r1-1 peak 5.00; A r2-1
4.22; A r2-2 **9.42 at exit**; B r1-1 16.96; B r1-2 4.33. The exit sample
is part of validity, even when every periodic sample was below 4. Waiting
for a quiet window holds no lock. The focused fixture runner starts with
1-minute load ≤2.5 and still rejects **every** sampled/start/end peak over 4.

The Release helper was built at A with `python3 scripts/build-bundle.py`
(`logs/b1-ab-a-helper-build.log`); helper sources are identical at A and B.
It stays fixed through these three items. Opening cells use the original
checkpoint-backed phase-A fixtures, a fresh clone and isolated process per
trial, another chat already open, and the real 30-second acknowledgement:

```sh
python3 scripts/perf-longchat-round.py b1-base --suite open \
  --products "$PI_BUILD_ROOT/baseline-b-products" --resume
# Item 2, then item 3 use the same commands with their current Release products:
python3 scripts/perf-longchat-round.py b2-first-paint --suite open
python3 scripts/perf-longchat-round.py b2-first-paint --suite scroll
python3 scripts/perf-longchat-round.py b3-scheduling --suite open
python3 scripts/perf-longchat-round.py b3-scheduling --suite scroll
```

Each wheel cell is a bounded 60-second up/down probe with real phased wheel
input, momentum and 180-frame dwell periods, at 120 or 480 points per steady
input frame. This round's subset is not the final ten-page/full-matrix gate.
Default sizes are 50k messages and 50k exchanges; sources are journal and
helper-owned. No `PI_PERF_ACK_SECONDS` or helper-hot override is passed.

Item 1 opening baseline (Release, checkpoint-backed, tracing on):

| Source / fixture | Accepted trial | Selection → useful draw (ms) | Helper open request → useful draw (ms) | Opening fill observation (ms) | 1-minute load start / end / peak |
|---|---|---:|---:|---|---|
| journal / 50k | `b1-base-open-journal-50k-1` | 2650.21 | — | 10996.46; ready=true | { 2.19 2.63 3.47 } / { 2.51 2.68 3.47 } / 2.51 |
| helper / 50k | `b1-base-open-helper-50k-1` | 2469.48 | 2819.97 | 12145.36; ready=true | { 2.17 4.92 5.56 } / { 2.36 4.83 5.52 } / 2.36 |
| journal / 50k-exchanges | `b1-base-open-journal-50k-exchanges-1` | 16944.77 | — | 78319.81; ready=true | { 2.36 4.83 5.52 } / { 2.91 4.44 5.31 } / 3.27 |
| helper / 50k-exchanges | `b1-base-open-helper-50k-exchanges-1` | 19090.24 | 19478.29 | 49108.43; ready=false | { 2.30 4.09 5.14 } / { 3.72 4.16 5.10 } / 3.72 |

All four miss the 500 ms first-useful-draw target. The helper-request column
includes the fixture’s intervening setup of the other chat; the selection
column starts at the actual long-chat selection. The last fill observation
does **not** imply an index is ready: the largest helper fill returns after
its 30-second acknowledgement timeout with `openingPage` still set. The
checkpoint supplies an extent before older history is hydrated. These opening
cells contain no wheel input, so demand-to-draw, input blanks and cancellation
shares are not applicable here; their before/after comparisons start in item 2.

Item 1 snapshot: `/Users/admin/Library/Caches/BelloSwiftWork/perf-evidence/a136-perf-b1-data.json.gz`
(8,224,628 bytes), SHA-256
`bf05d285b43bb53bd00af9b28f0106d7851a39eb6e54272836b5f201e8d08bf4`.
It retains the accepted and rejected A/B runs, raw opening events, frame
observations, exact commands, binary hashes and raw start/end load strings.
The relocated phase-A archive remains unchanged. No chat data format changes
or migration are introduced by item 1.
