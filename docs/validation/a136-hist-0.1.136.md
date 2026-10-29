# PERF-1 phase B, H1: committed helper-owned history, 0.1.136

Workstream `dev/a136-hist`, from `6d38ddd4` (phase A over `dev/next`
`0d6bc320`). Implementer: Codex; reviewer: the lead. Scope stops at H1.
H2's persistent index and H3's Find cache changes are not included.

## Contract and source ownership

The app negotiates `committed-history-v1`, then requests
`session.history.source` with `version: 1`. A null answer keeps
`session.history`. The description contains session/path/device/inode,
header and marker record checks, the last complete record's offset,
length, ID and SHA-256, lineage, runtime identity, presentation revision,
display count, the oldest row already loaded by the helper (`availableFrom`),
and an optional live-tail entry/position. There is no chat
text, provider context, permission state or accounting in this reply.
The last record's newline defines the exclusive committed byte boundary.

The helper captures the description synchronously on its session actor.
It does not load older rows. It declines ephemeral/memory-only chats,
uncertain writers, cut transactions still being delivered, and committed
cuts missing any projection. Opening recovery must finish the projections
before an opened runtime can offer a source. Legacy accepted-plan cards
whose navigation is synthesized only by the helper keep the helper path.

The app reads only the captured prefix. It verifies device/inode,
header/marker, last ID/digest/newline and lineage, and reopens the pathname
before publication. A second helper description validates the captured
source and live-tail exclusion. Ordinary appends may grow beyond the
boundary; edits, runtime changes, marker promotion and journal replacement
invalidate it. No numeric position is rebound across a file replacement:
the held entry must still exist on the held lineage. The helper remains
authority for live rows, partial streaming, run state and accounting.
Unsaved presentation replacements stay behind the live boundary even if a
terminal write fails after its ordinary live identifier was cleared. An
unsaved update does not revoke older committed rows; a durable replacement
increments the presentation revision.

A full file index still honors a checkpoint-backed helper's loaded-tail
range. Requests before that range may index the full prefix without
forcing the helper to replay it. Latest-page reads, including initial
paint, stay with the helper's loaded tail and live snapshot attachment.
The file serves explicit history navigation. A numeric
request crossing into live rows hands off the validated target by entry
ID; it cannot silently land on the previous held page.

This is an additive wire capability, not a journal or checkpoint migration.
The reader's SQLite index is still disposable and temporary. H2 can add
its versioned metadata cache and append extension behind the same prefix
contract. H1 reuses that temporary index only while the described prefix
is unchanged. A later description with a larger boundary rebuilds it;
this work does not implement append extension. The existing cursor
fingerprint is already bounded to the length and first/last 64 KiB. The cold
cost is the full temporary index build, which H2 must persist and extend
while implementing its specified cache validation.

## Validation and evidence

Raw logs and generated fixtures are outside git under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a136-hist`.
Only generated journals, synthetic credentials and isolated test hosts
are used. No installed app, real user preferences, chats, Keychain,
capture or provider requests are involved.

The initial Release build uses the unchanged H1 production path, with two
new differential regressions and test-host-only stdio byte counters.
The first regression requests the missing source capability. The second
compares a real helper's call card against a file page whose result falls
beyond the page boundary.

Every command uses:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-hist
```

Fixture copies are APFS clones of the phase-A `50k`, `200k`, and
`50k-exchanges` directories. Builds check the shared full-lane owner and
wait while it contains `perf` or `soak`. Timing runs use the phase-A
`perf-longchat-run.py` lock, load sampling and load-4 rejection policy.
One Release DerivedData directory is used, with testability enabled;
Debug timing is not evidence.

### Failing first and baseline

Commit `1fe820d4` contains the original two real-helper regressions and
test-host-only raw stdio counters. `evidence/failing-first.log` records
**2 tests, 2 failures**: the old helper rejects `session.history.source`
as unsupported; the file reader's cross-page tool card says `recorded`,
with empty output and no duration, while the helper says `completed`,
retains the full result and reports 12 ms. These are behavioral failures,
not build failures.

The unchanged production path was then measured in the isolated Release
host. Each fixture is checkpoint-warm, but the host and app reader are
new. The probe opens the newest page, requests the first older page with
`edge:start`, then requests numeric position 2500. CPU is the per-request
process CPU delta; footprint is each process's lifetime peak, so the
second page's footprint includes the first page's replay.

| Fixture | First older / next older, ms | First app / helper CPU, s | Next app / helper CPU, s | First app / helper peak, MiB | Next app / helper peak, MiB | Start / end / peak 1-minute load |
|---|---:|---:|---:|---:|---:|---:|
| 50k | 7156.37 / 909.87 | 0.299 / 7.063 | 0.346 / 0.650 | 95.50 / 448.91 | 129.00 / 448.91 | 2.74 / 3.51 / 3.64 |
| 200k | 27117.39 / 887.21 | 0.401 / 27.319 | 0.387 / 0.597 | 96.42 / 1688.01 | 134.21 / 1688.01 | 2.88 / 3.14 / 3.25 |
| 50k exchanges | 53342.39 / 848.69 | 0.517 / 53.748 | 0.357 / 0.691 | 95.24 / 3307.04 | 132.44 / 3307.04 | 2.76 / 2.61 / 3.00 |

All three baseline fixtures send/receive **4411 / 4609198 bytes** for
the first older page and **4412 / 4687402 bytes** for the next. They return
479 rows (`u0` through `a54_z`, start 0) and 791 rows (`u310` through
`a420_z`, start 2459), respectively. Totals 50068 / 200208 / 375663 were
independently checked against each generated manifest; the raw probe uses
`HIST136`, not the phase-A runner's `PERF136 event=open` row-check format.
`evidence/before-summary.json` retains that check. All three runs passed,
one test each, with no load rejection.

The original queued run used start load 2 and was stopped before it
acquired the lane. Accepted runs use the runner's normal start load 3;
the mandatory sampled maximum remains 4. Raw evidence:
`perf/hist-before-{50k,200k,50k-exchanges}-1.{log,json}`.

```sh
RUN=("$PI_BUILD_ROOT"/release/Build/Products/*.xctestrun)
for size in 50k 200k 50k-exchanges; do
  TEST_RUNNER_PI_PERF_JOURNAL="$PI_BUILD_ROOT/fixtures/$size/warm/chat.jsonl" \
    python3 scripts/perf-longchat-run.py --label "hist-before-$size" \
    --start-load 3.0 -- xcodebuild test-without-building \
    -xctestrun "$RUN[1]" -derivedDataPath "$PI_BUILD_ROOT/release" \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:PiAppTests/CommittedHistoryPerformanceTests/testHelperOwnedOlderPages
done
```

The probe itself clones the generated fixture for each run and removes it
at teardown. Functional tests and mutations also use one Debug DerivedData
directory, `$PI_BUILD_ROOT/native-tests`; no Debug timings are speed evidence.

```sh
python3 scripts/build-bundle.py
xcodegen generate --quiet
xcodebuild build-for-testing -jobs 2 -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2
```


### Differential parity

The real-helper harness creates and opens generated journals with the
packaged Release helper. It compares the same requested range, row IDs,
all decoded presentation fields, start/total, lineage, cursor entries,
turn boundaries, partial-turn input and task-terminal records. The only
excluded field is the file reader's local image locator; its row identity
is checked separately. Runtime/file incarnation intentionally differs.
Live run status and accounting remain on the helper-owned display.

| Cases | Coverage and result |
|---|---|
| Edits and branches | Original/revised questions, retained compaction prefix, abandoned tool results; identical selected rows and version marks. |
| Compaction | Legacy and native v2 summaries, task root, caption and operation identity. |
| Tools across pages | Call and receipt on separate pages; repeated call IDs, abandoned branch, complete large result and file statistics. |
| Tasks and presentation updates | Task roots/executions, terminal receipts, candidate-range filtering before byte admission, durable request-ledger replacement. |
| Interrupted saved progress | Reopened unfinished request-ledger and execution rows retain the helper's interrupted caption, terminal, coverage and part state. |
| Mail and cuts | Typed sub-agent delivery; prepared but uncommitted cut hidden; committed cut reopened with zero, one and both reserved rows already projected; retained assistant prefix and cancelled call agree after recovery. |
| Transfer payloads | Escaped Unicode/control characters and large assistant/tool output exceeding the display envelope retain complete content. |
| Page budgets | Long string-form replies, usage metadata, long detail captions and task receipts produce the same page boundaries. |
| Checkpoint and cursors | Tail ranges agree even with an already full file index; older/newer entry handoffs agree after helper replay. |
| Live and ephemeral | Real loopback streaming keeps live state with the helper while older rows use the file; numeric jump keeps its target. Ephemeral/memory-only and closed sessions decline a descriptor. |
| Compatibility | Old ready capability uses the existing helper path; latest pages keep the helper's live attachment and avoid a cold full index. |
| Images/inherited rows | Image count/caption and inherited metadata agree; no extra inherited-count overlay is introduced. |

Discovered divergences were fixed before enabling this path:

- Cross-page tool receipts were absent from call cards. The branch index now
  resolves each call's receipt before byte admission, including reused IDs.
- String-form assistant content lacked the canonical timeline, changing
  both visible presentation and page weight. Tool timeline arguments used
  pretty JSON rather than the helper's compact JSON. Negotiated helper
  pages now use the helper projection; standalone journal reads preserve
  their existing projection.
- Branch defaults, native/legacy compaction captions, native compaction
  task roots, 1024-byte detail previews and null tool metadata differed.
- An absent usage field replayed as JSON null created an empty helper reply
  annotation. The helper now omits that empty annotation.
- Task-terminal receipts were selected after byte admission in one path.
  Selection now uses candidate-range IDs and task keys before admission,
  and accounts for receipt metadata in the budget.
- The app's decoded row omits unknown usage fields and explicit null card
  fields, and adds image locators/captions. A wire-weight adapter accounts
  for the helper's original fields without adding them to UI state.
- A cached full file index widened a checkpoint-backed helper's tail range;
  `availableFrom` preserves it. A numeric fallback into live rows lost its
  target; it now rebinds the validated target entry.
- Saved progress without a terminal receipt used a different caption and
  left its timeline streaming. Negotiated reads now apply the same
  `RetainedConversation.endWithoutReceipt` recovery projection as the helper.

Legacy accepted-plan navigation synthesized by the helper cannot be
reproduced from this contract. Such sessions explicitly decline the new
source and continue through `session.history`. No known visible divergence
is admitted through the negotiated file path.

### Additional failing-first evidence

`evidence/parity-detail-before.log`: 10 tests, 209 assertion failures
across five cases (zero unexpected errors), exposing the projection,
byte-budget, checkpoint-range and live-target differences above.
`evidence/parity-projections.log`: 15 tests, four assertions failing in
two cases: retained usage metadata changed the opening page from 50 to
200 rows, and native compaction lost its historical-data caption/task
root. `evidence/parity-wire-budget.log`: the same 15 tests pass.
`evidence/parity-checkpoint-ledger.log`: two additional handoff/update
cases pass. The final clean run is recorded below.

`evidence/helper-transient-before.log`: one test fails two assertions
when an in-memory presentation update both escapes its live boundary and
revokes a useful older read. `helper-transient-fixed.log` passes 42 tests.
Earlier compilation-only failures are retained separately and are not
counted as behavioral failing-first evidence.

The Debug build excludes the existing phase-A `LongChatPerformanceTests.swift`
probe: its non-Release guard triggers the project's unreachable-code
warning-as-error. That source belongs to the parallel stream and was not
edited. Release builds include it; this workstream's probe has a complete
conditional compilation guard. No Debug result is used as speed evidence.

### Commands and isolation

The generated helper and both test hosts use this workstream's build root.
Fixtures were copied with `mkdir -p "$PI_BUILD_ROOT/fixtures"` and
`cp -c -R /Users/admin/Library/Caches/BelloSwiftWork/build-a136-perf/fixtures/<size> "$PI_BUILD_ROOT/fixtures/"`.
Every probe clones its journal and `.meta` again under this root and removes
that trial directory. No other workstream's build root is written.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a136-hist
export TMPDIR="$PI_BUILD_ROOT/scratch/"
export TEST_RUNNER_TMPDIR="$TMPDIR"
export TEST_RUNNER_PI_APP_SCRATCH_ROOT="$PI_BUILD_ROOT/scratch"
# Before every build/test: wait while full-lane.lock/owner contains perf or soak.
python3 scripts/build-bundle.py
xcodegen generate --quiet
xcodebuild build-for-testing -jobs 2 -project PiApp.xcodeproj -scheme PiApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/release" ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  PI_PERF_TEST_COMPILATION_MODE=incremental PI_PERF_TEST_COMPILER_FLAGS=-j2

# Focused Debug tests; append the -only-testing selections recorded below.
xcodebuild test -jobs 2 -project PiApp.xcodeproj -scheme PiApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  EXCLUDED_SOURCE_FILE_NAMES=LongChatPerformanceTests.swift \
  'OTHER_SWIFT_FLAGS=$(inherited) -j2' -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:PiAppTests/CommittedHistoryTests

swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 2 \
  --filter 'CommittedHistorySourceTests|MailboxCutPersistenceTests|HostServiceTests|JournalPromotionTests|JournalSlimmingTests|JournalCheckpointTests|JournalCloneTests|HistoryWindowTests|HistoryReadCancellationTests|HistoryFillTests|TaskPresentationTests|FullDisplayTests|SubagentJournalTests|MailboxCutReviewTests'
# The final repeat uses --skip-build after restoring and rebuilding mutations.

python3 scripts/test-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
python3 scripts/test-native-acceptance.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

The helper's additional presentation checks use the same `swift test`
command with filter
`CommittedHistorySourceTests|HostServiceTests|MailboxCutPersistenceTests|DisplayObservationTests|ResponseTimelineTests|TaskPresentationTests`.
`evidence/helper-final-focused.log` passes **54 tests**. The final Release
helper wire/concurrent/acceptance logs pass **41 / 4 / 3**, respectively.
The new negotiation case is in `HostServiceTests`; the new source and cut
cases are included in the focused helper gate rather than changing the
Python suite counts.

Serial app classes run individually through `perf-longchat-run.py`
(`--label hist-functional-<Class> --start-load 3.0`) with the Debug
`.xctestrun`, `test-without-building`, `-parallel-testing-enabled NO`, and
`-only-testing:PiAppTests/<Class>`. This takes the shared focus/timing lock
and records load; those runs prove assertions only, never speed.

### Mutation results

Each mutation was applied alone, compiled, exercised by its targeted test,
and restored in a `finally` block. All **25** were caught by test assertions
or the expected unsafe-read failure, rather than compiler errors.
`evidence/app-mutations.json` and `helper-mutations.json` contain commands
and exit statuses; `mutation-app-*.log` and `mutation-helper-*.log` retain
raw failures and the original sources.

| Mutation removed/broke | Regression that caught it |
|---|---|
| Committed byte limit | Append during indexing could no longer return the useful captured prefix. |
| Device/inode validation | Identical bytes at a replacement pathname were incorrectly accepted. |
| Source lineage validation | A descriptor for a different branch was accepted. |
| Stable-entry reanchor | Replacement reused numeric position zero instead of `m40`. |
| Cross-page receipt lookup | The call card lost the completed result/duration. |
| Helper wire byte weight | Retained usage metadata no longer limited the opening page. |
| Task candidate-range receipts | Page task-terminal evidence disappeared. |
| Numeric live target handoff | Jump landed on the previous held page. |
| Checkpoint loaded-range floor | A cached full index widened the helper's tail page. |
| Already-loaded first-paint fallback | Initial paint built a cold full file index. |
| Native compaction caption | Historical-data caption differed from the helper. |
| String-form canonical timeline | Visible timeline and byte-limited page range differed. |
| Cut projection completeness | A committed cut with missing projections offered a source. |
| Unsaved presentation live boundary | In-memory-only replacement escaped the helper tail. |
| Live update revision rule | A live update revoked a useful older page. |
| Writer/path replacement check | A writer described another inode at its pathname. |
| Capability negotiation guard | An unnegotiated client obtained the new description. |
| Null usage guard | Replay created an empty reply annotation. |
| Disconnect capability reset | A retired connection retained the new capability. |
| Legacy accepted-plan fallback | File authority was offered despite helper-only navigation. |
| Exact numeric target | The turn's first row replaced the requested live row during handoff. |
| Latest-page helper ownership | Empty/small latest pages used a file incarnation and a cold index instead of the existing helper attachment. |
| Standalone projection scope | Forcing helper projection on a standalone read changed the original discarded-ledger/retry presentation. |
| Negotiated helper projection | Disabling it changed tool timelines and branch fields relative to the real helper. |
| Interrupted progress recovery | Restoring the caption-only projection changed both saved progress rows relative to the helper. |

The final lifecycle regression first failed in
`evidence/capability-reset-before.log` (one test, one assertion), passed in
`capability-reset-fixed.log`, and failed again with only the reset removed
in `mutation-app-capability-reset.log`. The source was restored afterward.
`evidence/parity-final.log` then passes **17 tests, zero failures**.

The final helper gate in `evidence/helper-final-all-focused.log` runs
**116 tests: 113 passed, three expected opt-in skips, zero failures**.
Class counts: CommittedHistorySource 5, FullDisplay 5, HistoryFill 18,
HistoryReadCancellation 4 (one perf opt-in skip), HistoryWindow 14,
HostService 11, JournalCheckpoint 8, JournalClone 9, JournalPromotion 5
(two fault-harness opt-in skips), JournalSlimming 10,
MailboxCutPersistence 9, MailboxCutReview 5, SubagentJournal 8,
TaskPresentation 5. The separate 54-test presentation gate also covers
DisplayObservation 9 and ResponseTimeline 15. Together these cover 140
unique helper tests, with the same three opt-in skips.

Scope notes: the shared `WorkspaceHistory.swift` edit only selects the
source and preserves the stable target on fallback. `HostSupervisor.swift`
adds negotiation/reset and the test-host byte counter; `HostService.swift`
adds only the read-only description request. Projection fixes are in
`HistoryReader.swift` and `TranscriptMessage.swift`. No scheduler, first-paint
UI, Markdown, JSON parser, helper opening wait, checkpoint-refresh mechanism,
H2/H3 cache, or `NEXT-RELEASE.md` change is included.


The first parallel app gate (`evidence/app-focused-parallel.log`) ran 116
tests with two opt-in skips and one failed assertion in
`ResponseTimelinePresentationTests.testDiscardedRequestLedgerCannotResurrectReplyPartsAfterHistoryReload`.
The discarded ledger remained empty, but the accepted retry gained a
canonical part from the helper-specific normalization. An initial narrower
assertion passed all 13 tests (`app-focused-timeline-fixed.log`). Subsequent
long-turn controls exposed another standalone-presentation regression, so
that test edit was reverted. The final change scopes helper projection
rules to negotiated file reads and preserves the original test expectations.

The first serial-run driver also stopped before launching any test because
`xcodebuild test` had not produced a `.xctestrun`. A Debug
`build-for-testing` with the same flags and DerivedData creates that
manifest (`evidence/debug-manifest-build.log`); no extra DerivedData or
named result bundle was created. The corrected timeline class and the
serial classes are recorded separately below. The optional long-index
fixture and standalone opening probe were skipped in this Debug gate;
the generated Release opening probe runs separately.

The temporary assertion edit's first attempt had a compile-only type error,
preserved in `app-focused-timeline-compile.log`; no behavioral result is
attributed to it. `ResponseTimelinePresentationTests.swift` has no final diff.


Additional boundary checks:

- `helper-legacy-fixed.log` and `helper-source-final.log` pass all six
  `CommittedHistorySourceTests`. The added case retains the helper's
  synthesized navigation for a legacy accepted plan and declines a file
  source. Removing only that decline fails in
  `mutation-helper-legacy-fallback.log`. This adds one unique helper case
  (141 total, three opt-in skips) and one caught mutation.
- The ephemeral/memory boundary is exercised on the actual `AgentSession`
  implementation with its memory page. Current public `side.open`
  immediately preserves a side before exposing it, so it cannot supply an
  externally opened ephemeral runtime for the process differential test.
  The process test covers live and legacy-helper fallback; the core test
  proves that a memory-only runtime never offers a file descriptor.
- `live-target-exact-before.log` records a further failing-first assertion:
  a numeric jump to the second live row handed off `live-input` rather than
  that row's ID. Page-first reanchoring is insufficient if the live row's
  byte weight changes before the helper answers. An earlier observer
  wiring mistake and a compile-only failure are retained in
  `live-target-exact-observer.log` and `live-target-exact-compile.log` and
  are not claimed as behavioral evidence.

`live-target-exact-fixed.log` passes the exact-target regression. Reverting
only the handoff to the page's first row fails it again in
`mutation-app-exact-live-target.log`. The restored implementation passes
all **17** differential cases in `parity-final-exact.log`. Numeric
handoffs now select the requested row within the validated page; a
replacement uses the already validated held entry.

The serial gate exposed a live-opening regression in H1: five of the
15 `SubagentOpeningTests` cases failed (nine failures, four unexpected
errors; `perf/hist-functional-SubagentOpeningTests-1.log`, peak load 2.85).
The affected child opening returned an empty file page and did not reach
its streamed final reply. Disabling only the new route made the sidebar
case pass (`perf/hist-diagnostic-subagent-no-source-1`, peak load 2.54).
The initial fallback had covered only large fully loaded runtimes.

Latest-page requests now always retain the helper source, including empty
and small runtimes and non-opening latest reads. Explicit older navigation
still uses the committed source. The expanded regression first fails 16
assertions in one test (`latest-source-before.log`), then passes together
with the integrated live handoff test (`latest-source-fixed.log`, two tests).
Restoring only the previous fallback fails the same 16 assertions in
`mutation-app-latest-source.log`. The integrated check adopts an older file
page, verifies that a live snapshot preserves it, adopts the helper live
page, and observes the streamed reply through completion. The restored
implementation passes all 17 differential tests in `parity-final-latest.log`.
The serial class then passes all 15 cases in
`perf/hist-functional-SubagentOpeningTests-fixed-1.log`, with start/end/peak
load 2.67 / 2.53 / 2.67.

The other completed serial gates use `perf/hist-functional-<Class>-<attempt>`:

| Class | Tests passed | Accepted attempt | Peak load |
|---|---:|---:|---:|
| HistoryEdgeTests | 16 | 2 | 3.21 |
| HistoryEdgeTimingTests | 2 | 2 | 2.92 |
| HistoryEditTests | 3 | 2 | 2.69 |
| HistoryExtentTests | 26 | 1 | 3.07 |
| HostSupervisorTests | 12 | 1 | 2.70 |
| InheritedSubagentReaderTests | 8 | 1 | 2.70 |
| StableToolPresentationTests | 10 | 1 | 2.72 |
| SubagentReaderTests | 60 | 1 | 2.79 |
| WorkspaceRefreshLifecycleTests | 48 | 1 | 2.75 |
| TranscriptWirePageTests | 4 | 2 | 2.92 |

The rejected first attempts for HistoryEdge, HistoryEdgeTiming, HistoryEdit
and TranscriptWirePage exceeded load 4 and were repeated. Their aborted logs
are retained but are not passing evidence.

The initial `LongTurnPagingTests` gate ran ten cases with one failed
assertion: the finished-turn fill kept the reader's row still, but requested
seven extra reader loads (`hist-functional-LongTurnPagingTests-2`, peak 3.34).
It reproduced on the full current class (`hist-functional-LongTurnPagingTests-current-1`,
peak 2.72). Restoring the pre-H1 `TranscriptMessage.swift` made the individual
case and the whole ten-test class pass; reverting only argument formatting
did not fix it. These controls identified an H1 standalone-projection
regression, rather than an unrelated baseline failure.

Helper projection is now explicit and used only for negotiated committed
pages. Standalone reads retain their earlier string-content timelines,
argument formatting, captions and detail previews. The scoped gate passes
51 tests: CommittedHistory 17, FullDisplay 4, HistoryTurnPaging 6,
ResponseTimelinePresentation 13 (original assertions), and TranscriptPaging
11 (`evidence/projection-scope-fixed.log`). The serial long-turn class then
passes all ten tests (`hist-functional-LongTurnPagingTests-scoped-1`, load
2.34 / 2.55 / 2.60), and StableToolPresentation passes all ten again
(`hist-functional-StableToolPresentationTests-scoped-1`, 2.55 / 2.74 / 2.74).

Forcing helper projection back onto standalone pages fails the original
timeline regression (one assertion, `mutation-global-helper-projection.log`).
Disabling it for negotiated pages fails real-helper parity with seven
projection assertions (`mutation-committed-helper-projection.log`). Both
mutations were restored. The runner initially expected an `XCTAssertEqual`
message for the second case, while this comparator reports `XCTFail` with
field differences; the actual seven behavioral failures were verified
before continuing the restored-source gate.

`parity-final-scoped.log` passes 30 tests after restoration: all 17 parity
cases plus the 13 original timeline tests. `app-focused-projection-final.log`
then passes 80 of 81 remaining focused cases, with the expected large-index
opt-in skip and no failures. Those classes are EditHistoryReader (1),
HistoryIndexFiles (8, one skip), HistoryReaderCheckpoint (7),
HistoryReaderStateTail (4), LongJournalHistory (1), MailboxCutPresentation
(6), RunHold (18), SubagentCodexStorage (7), SubagentDiscovery (15),
SubagentTranscript (11), TranscriptImageRow (2), and TranscriptImage (1).
No existing test expectations are changed in the final diff.

Visual checks used the same isolated Debug host under the shared lock:
`TranscriptRowGalleryTests` passes two tests and `MailboxCutGalleryTests`
passes one. They write 12 row PNGs and 12 cut PNGs to `gallery-rows/` and
`gallery-cut/`. Inspected light/dark work rows, expanded tool output,
stopped replies, saved response details, and wide-light/narrow-dark cancelled
calls. Cards and retained text remain readable; a tall narrow scene uses
its scroll viewport. The accepted row run's load was 2.37 / 2.34 / 2.37;
cut attempt 1 exceeded load 4 and was discarded, and attempt 2 passed at
2.72 / 3.31 / 3.31.

```sh
RUN=("$PI_BUILD_ROOT"/native-tests/Build/Products/*.xctestrun)
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/gallery-rows" \
python3 scripts/perf-longchat-run.py --label hist-gallery-rows --start-load 3.0 --attempts 5 -- \
  xcodebuild test-without-building -xctestrun "$RUN[1]" \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:PiAppTests/TranscriptRowGalleryTests
TEST_RUNNER_PI_APP_CUTIN_GALLERY="$PI_BUILD_ROOT/gallery-cut" \
python3 scripts/perf-longchat-run.py --label hist-gallery-cut --start-load 3.0 --attempts 5 -- \
  xcodebuild test-without-building -xctestrun "$RUN[1]" \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:PiAppTests/MailboxCutGalleryTests
```

### Final recovery parity check

A final projection audit found that saved request-ledger and execution rows
without terminal receipts were recovered differently. The helper changes
their caption, timeline terminal, coverage and streaming parts to interrupted;
the file reader had only appended a caption suffix. The new real-helper case
first fails two row comparisons in one test
(`evidence/incomplete-progress-before.log`). Negotiated reads now call the
shared `RetainedConversation.endWithoutReceipt` projection. Standalone reads
keep their existing behavior.

`incomplete-progress-fixed.log` passes the new test. Restoring just the old
caption-only projection fails the same two comparisons with zero unexpected
errors (`mutation-incomplete-progress.log`). After restoring the fix,
`parity-final-recovery.log` passes **39 tests, zero failures**:
CommittedHistory 18, FullDisplay 4, HistoryReaderStateTail 4, and
ResponseTimelinePresentation 13. The extra regression brings the mutation
total to 25. An earlier overlapping-inout compile error was corrected before
the passing run; no compiler failure is claimed as behavioral proof.

```sh
"$PI_BUILD_ROOT/run-debug.sh" \
  -only-testing:PiAppTests/CommittedHistoryTests/testReplayedIncompletePresentationsMatchTheHelper
# Apply the one-block caption-only mutation, repeat that command, then restore.
"$PI_BUILD_ROOT/run-debug.sh" \
  -only-testing:PiAppTests/CommittedHistoryTests \
  -only-testing:PiAppTests/FullDisplayTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests
```

`run-debug.sh` expands to the Debug command and isolation variables above.
`$PI_BUILD_ROOT/finish-h1-recovery.py` records the mutation, restoration,
final focused gate and final Release build/measurements. The helper production
code is covered again by the final wire/concurrent/acceptance runs below.

### Final Release results

The final Release build includes the recovery fix. Every accepted probe passes
one test and stays at or below load 4. The same row IDs, ranges and totals
are checked in `evidence/history-summary.json`; opening retains a helper
incarnation, and both older pages use a file incarnation.

| Fixture | First older before / after, ms | Next older before / after, ms | After start / end / peak load |
|---|---:|---:|---:|
| 50k | 7156.37 / 8075.57 | 909.87 / 457.74 | 2.81 / 2.88 / 2.88 |
| 200k | 27117.39 / 32874.94 | 887.21 / 446.86 | 2.88 / 3.81 / 3.81 |
| 50k exchanges | 53342.39 / 51989.00 | 848.69 / 366.04 | 2.44 / 2.72 / 2.87 |

The following CPU, footprint and IPC figures are for the final implementation;
the matching baseline figures are in the earlier table. CPU is per-request,
and each footprint is that process's lifetime peak. Adding the two process
peaks would not measure their simultaneous combined peak.

| Fixture | First app / helper CPU, s | Next app / helper CPU, s | First app / helper peak, MiB | Next app / helper peak, MiB | First sent / received bytes | Next sent / received bytes |
|---|---:|---:|---:|---:|---:|---:|
| 50k | 8.0326 / 0.0020 | 0.4598 / 0.0013 | 268.38 / 9.69 | 268.38 / 9.69 | 406 / 1670 | 406 / 1670 |
| 200k | 31.8975 / 0.0023 | 0.4505 / 0.0012 | 889.54 / 12.38 | 889.54 / 12.41 | 406 / 1674 | 406 / 1674 |
| 50k exchanges | 49.3445 / 0.0015 | 0.3694 / 0.0011 | 1485.94 / 7.64 | 1485.94 / 7.64 | 406 / 1676 | 406 / 1676 |

Accepted final evidence:

- `perf/hist-after-50k-2.{log,json}`
- `perf/hist-after-200k-2.{log,json}`
- `perf/hist-after-50k-exchanges-1.{log,json}`

Opening probes (before / after milliseconds, same helper source):

- 50k: 43.96 / 53.00.
- 200k: 100.05 / 163.32.
- 50k exchanges: 18.57 / 15.78.

These are single accepted observations per fixture and phase, not confidence
intervals or an opening-speed claim. The earlier after runs for 50k and 200k
(`hist-after-50k-1`, `hist-after-200k-1`) predate the recovery projection fix
and are superseded here. They also show the cold cost: 7.33 / 29.33 seconds,
with next pages 471 / 423 ms. The earlier queued exchange run was terminated
before it launched so that the recovery fix could be tested; it contributes
no measurement. Shared build/load waits are retained in the driver logs.

The measured next page takes about half as long at 50k and 200k, and 43% as
long at 50k exchanges. Response traffic drops from 4,609,198 / 4,687,402 bytes
for the first/next pages to 1,670–1,676 bytes for each metadata-only round trip
pair. Helper CPU and peak footprint fall sharply, while the app now bears
the index-build CPU and a larger peak. H1 does **not** consistently improve
the first older page: it is slower at 50k and 200k, and still takes 52 seconds
at 50k exchanges. The temporary full index build remains the limiting cost.

The standalone Release opening check passes one test, reports 50,068 rows
in 58 ms, and records load 2.72 / 2.67 / 2.72
(`perf/hist-release-reader-open-1.{log,json}`). It uses the checkpoint tail;
it is not a cold full-history measurement.

```sh
# After the final Release build above, with the isolation variables exported:
RUN=("$PI_BUILD_ROOT"/release/Build/Products/*.xctestrun)
for size in 50k 200k 50k-exchanges; do
  TEST_RUNNER_PI_PERF_JOURNAL="$PI_BUILD_ROOT/fixtures/$size/warm/chat.jsonl" \
    python3 scripts/perf-longchat-run.py --label "hist-after-$size" \
    --start-load 3.0 --attempts 5 -- xcodebuild test-without-building \
    -xctestrun "$RUN[1]" -derivedDataPath "$PI_BUILD_ROOT/release" \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:PiAppTests/CommittedHistoryPerformanceTests/testHelperOwnedOlderPages
done
TEST_RUNNER_PI_PERF_OPEN_JOURNAL="$PI_BUILD_ROOT/fixtures/50k/warm/chat.jsonl" \
TEST_RUNNER_PI_PERF_REPEAT=1 \
  python3 scripts/perf-longchat-run.py --label hist-release-reader-open \
  --start-load 3.0 --attempts 5 -- xcodebuild test-without-building \
  -xctestrun "$RUN[1]" -derivedDataPath "$PI_BUILD_ROOT/release" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:PiAppTests/HistoryReaderOpenPerformanceTests
python3 "$PI_BUILD_ROOT/summarize-history.py"
```

### Final counts and review decision

Distinct passing cases, deduplicated from the final logs:

- App focused gates: **347 passed, one expected large-index opt-in skip**,
  including 18 new differential/boundary cases and the Release opening check.
- Galleries: **3 passed**; light, dark and narrow screenshots inspected.
- Helper focused gates: **138 passed, three expected opt-in skips**.
- Release helper wire / concurrent / acceptance: **41 / 4 / 3 passed**.
- Mutations: **25 caught**, all restored; no compile failure counts as a catch.
- Measurements: **six accepted before/after fixture runs**, one passing test
  each, with matching golden ranges and all peak loads at or below 4.

The final timestamp audit found that the earlier wire logs preceded the
legacy-plan fallback guard. All three suites were therefore rerun after
the final Release build: `evidence/final-native-host.log` (41),
`final-concurrent-native-host.log` (4), and `final-native-acceptance.log` (3),
all passing. They use the same commands shown above and the same helper
as the final measurements, SHA-256
`8b38da0ba4b4805d44ba1fc59a058066d0d53cb7a66bcd460ffddfb6ccd6ce72`
(`evidence/final-wire-helper.sha256`).

`evidence/focused-app-counts.json` and `focused-helper-counts.json` retain
the distinct test names and source logs. Existing test expectations are
unchanged. Raw logs, artifact hashes, load samples, screenshots and fixture
manifests remain under the build root. The generated fixture clones and
abandoned test scratch directories are removed after validation; the
commands above recreate the clones. One Debug and one Release DerivedData
directory remain for review, with the single packaged helper.

No known visible divergence is admitted through the new source. Legacy
accepted-plan sessions still use the helper because their synthesized
navigation is not in this metadata contract. Ephemeral behavior is proved
at the actual session layer rather than through public `side.open`, which
preserves the side before exposing it. H2 and H3 remain unimplemented.

Lead options:

1. **Recommended:** review/merge H1 as the compatibility foundation, then
   complete H2 before calling PERF-1's long-history loading problem fixed.
   Persistent reuse and append extension address the remaining cold work.
2. Ship H1 alone for subsequent-page and IPC improvements, accepting the
   measured cold-read cost and conservative legacy-plan fallback.
3. Expand the legacy-plan metadata contract first if those sessions dominate
   the owner's workload; this improves coverage but leaves cold indexing.

This work stops after H1 for the lead's review. `NEXT-RELEASE.md`, the other
streams' UI/scheduler/parser implementations, and published release identities
are unchanged. The small shared-file edits are identified in the scope notes.
