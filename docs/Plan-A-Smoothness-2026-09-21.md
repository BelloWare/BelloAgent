# Plan A implementation and validation

This follows the uploaded **Plan-A-App-Wide-Smoothness.md** against starting
revision `c0608e2` (Bello Agent 0.1.68/build 72). It changes scheduling,
invalidation, organization persistence and inspector preparation. No release,
version bump, screen redesign, content limit or motion-policy change is included.

## Organization and navigation — A1/A2

- Archive, restore and pin submit one bounded metadata batch, with the existing
  500-session limit. Validation classifies changed, unchanged, missing and
  individually invalid records before writing. A fatal SQLite error rolls the
  whole transaction back. WAL and `synchronous=FULL` are unchanged.
- The batch updates only organization fields against current stored records.
  Revisions prevent stale path/model/title-job writes from undoing organization.
  Publication rebases onto live records, skips deleted identities, and assigns
  the chat array once. Side metadata publishes only when it changes.
- A per-ID coordinator orders overlapping archive/restore/pin/rename/topic
  moves/reorders. It does not lock unrelated sessions or their composers.
- Marks clear immediately. The final selection reducer simulates the old ordered
  policy without opening intermediate conversations. If everything is archived,
  the same final archived destination remains open in the active sidebar filter.
  A later deliberate selection, side focus or page change wins over the batch.
- Busy sessions still receive Stop. Four shared workers bound outstanding Stop
  acknowledgements; metadata and typing do not await a terminal model/tool result.
  A later restore supersedes only Stop commands not yet admitted. It cannot undo
  a dispatched command. Host loss remains explicit and uncertain. A storage
  failure does not claim that already-issued Stops were rolled back.
- Discarding a pending empty chat while its materialization write is suspended
  removes the new desktop row instead of resurrecting it on restart. Pending
  materialization retains its separate creation/draft writes; the one-transaction
  claim applies to already-persisted eligible targets.
- `PiMotion.glide` owns the sidebar structural transition. Transcript/editor
  stable-layout boundaries and app-owned motion remain intact.

## Activity and usage reads — A3

- Activity subscribes to committed phase/queue and nested usage/timing changes.
  Text, draft and unrelated workspace notifications do not rebuild activity rows.
  Dirty session IDs are projected once; unchanged snapshots are cached. Fresh
  nested footer accounting no longer depends on a later text event.
- Archived counts are indexed once per structural revision. Project unread and
  Dock counts share a cache invalidated by their complete record/read/side inputs.
- Popup and session-usage SQL run on the existing serial read-only Report worker,
  with a short WAL snapshot and consumer-owned cancellation. They no longer run
  historical aggregates on the capture writer. The worker's close drains queries.
- Route paging reuses recent summary/chart observations and performs only route
  count/page queries. Popup routes skip unused latency medians; session usage
  requests medians only for the displayed routes. Summary and route observation
  times are retained and exposed in existing help text. Newer page percentages
  use the same query's totals, never an older summary denominator.
- Cache retention is bounded to 16 scopes. Generation checks prevent late reads
  from restoring cache entries after close. Existing token/cost provenance,
  missing-value coverage, compaction attribution and raw capture are unchanged.

## Inspector and rich text — A4

- SSE indexing retains one immutable byte body and frame/line offsets. Opening
  the Events tree does not parse every JSON object or construct full formatted
  text. Visible/expanded frames parse through one serial worker and a derived
  cache with a conservative 4 MiB accounting budget. Expanded visible nodes own
  their requested content separately; this budget is not a process RSS limit.
- Full Copy View and redaction format the complete selected view off-main.
  UTF-8/Hex/raw exports, malformed data, unfinished frames and exact retained
  bytes are preserved. Combined Response remains demand-driven.
- Changing attempts, closing, changing selection and collapsing cancel pending
  work and reject stale results. Expand all includes offscreen events, using one
  task with bounded batches instead of a task for every frame. Outline anchors
  are preserved as expanded rows are inserted above the viewport.
- Completed Markdown blocks retain their exact per-width heights and native
  owners. Active suffix changes update only the invalid aggregate suffix and
  frame placements. Width changes still perform correct full reflow. Native
  selection and final Markdown reconciliation remain tested.
- **Conditional work remains deferred:** cold provisional inner-block sizing and
  full active-row decomposition. Exact cold sizing is still expensive; an outer
  row anchor is insufficient to preserve position inside one giant answer while
  provisional inner heights change. No guessed height enters the exact cache,
  and no shared sizing host or detached pre-drawing experiment was reintroduced.

## Measurements and their limits — A0/A5/A9

Native fixtures run serially on the same virtual Apple M3 Max, 10 CPUs, 16 GiB,
macOS 14.8, Xcode 16.1/Swift 6. Debug runs enable actor data-race checks; stopwatch
comparisons use optimized Release. No simultaneous compilation runs during
reported native benchmarks. Timing fixtures include actual NSWindow layout and
display opportunities, not physical screen scanout. New percentile fixtures use
nearest-rank percentiles; the existing five-session/scroll fixtures retain their
original percentile calculation for before/after comparison.

The baseline worktree contains unmodified `c0608e2` product code. Its test-only
changes add the identical public-action archive fixture and fix an obsolete
`block:tail` expectation: journal IDs, including `stream:`, are opaque. The old
fixture was waiting for a row that the correct renderer never creates.

The retention fixture now waits for bounded real animation settlement rather
than a fixed number of queue turns. Both the baseline and initial optimized run
retained outgoing graph values when those turns elapsed before the animation
deadline. The retained-object assertions are unchanged, and animations stay on.

Opt-in `PerformanceProbe` adds organization click/store/transaction/patch timing,
commit/publication/changed-ID counts, sidebar invalidation, badge/selection counts,
activity projection and per-consumer SQL queue/execution/statement/sort counts.
Pending-chat creation, discarded-creation cleanup and draft writes have separate
counters so they are not mistaken for the normal single metadata transaction.
It logs no prompt text, credentials, paths or raw arguments. Normal builds leave
it disabled. Existing transcript sizing, host-identity, heartbeat, input-draw and
memory fixtures supply the remaining local evidence.

A separate 15-second Time Profiler recording sampled 8,580 ms of main-thread CPU
in the five-session fixture. Inclusive app frames include 3,386 ms in row sizing,
1,087 ms in inner Markdown sizing and 2,288 ms in the existing idle scheduler;
these overlap and must not be added. SwiftUI/AppKit exact rich-row sizing, rather
than a hidden full-workspace publication per token, remains the dominant cost in
that workload. The profiled run is excluded from the clean timing comparison.

### Acceptance coverage

- Storage sizes 100/1,000/10,000; batch sizes 1/5/25/100/500 where enough records
  exist, plus archive-all; one commit/publication and no intermediate opens.
- Current target first/middle/last/non-target, ordered and reversed archive-all
  selection, multiple project isolation, existing topic/side/pin/filter/drag tests.
- Overlapping restore/pin/rename/topic operations; navigation to Report during a
  delayed write; late path/model updates; deleted records; invalid records;
  SQLite-trigger transaction failure; durable reopen after commit.
- A real composer retains identity, text and focus across 120 edit/draw samples
  while 20 simulated session streams update and a 500-chat batch is both pending
  and committing. This tests native delivery, not 20 new deployed-provider calls.
- Busy archive Stop admission/restore/host-disconnection behavior, native workspace
  concurrency, capture durability and Report cancellation/writer isolation tests.
  The unchanged executable helper's earlier 20-request gateway evidence is reused;
  this task does not rerun deployed-provider or helper throughput benchmarks.
- Lazy 20,000-event indexing and full-copy tail coverage; native visible-only
  loading, offscreen Expand all, collapse, replacement and cancellation; bounded
  derived-cache accounting; complete raw and combined-response fixtures.
- Completed-block identity/measurement reuse, selected native text during tail
  streaming, width reflow, long scrolling and streaming fences. Existing shell
  tests cover hover, queue/error expansion, sidebar resize, keyboard navigation,
  main/side focus, project/topic disclosure, Settings, Report and reading anchors.
- Native request/combined JSON, popup and usage-window appearance captures were
  rendered during integration. A fixture now expects the existing 980-point
  usage window; production dimensions did not change.

### Final optimized evidence

These are isolated local trials, not universal performance guarantees.

| Fixture | Starting revision | Plan A |
|---|---:|---:|
| Archive 500 of 540 chats, real window, click through committed UI | 14,429 ms | 69.45 ms |
| Chat-array publications for that archive | 500 | 1 |
| Same action's synchronous acknowledgement | 2.91 ms | 3.08 ms |
| Foreground rich-block arrivals with four hidden streams, p95 layout/display + deferred work | 34.64 ms | 36.63 ms |
| Foreground 32-byte arrivals with four hidden streams, p95 | 14.29 ms | 15.25 ms |
| Scroll 300 rich rows, p95 | 28.10 ms | 28.31 ms |
| Scroll a single 88 KiB answer, p95 | 18.74 ms | 17.73 ms |
| Cold exact geometry of that answer | 969.67 ms | 988.86 ms |

The large archive gain is directly supported by the removal of 499 publications
and commits. The renderer comparisons are broadly unchanged, with some worse
samples; they do **not** demonstrate a general frame-time improvement. Small
active suffixes now visit/place one changed block rather than 300 completed ones
in the structural regression, but full native row sizing remains expensive.

The separate 500-chat archive plus 20 simulated streams fixture takes **2.77 ms**
to acknowledge and preserves the same composer/focus through **120 edit/draw
samples**: p95 **2.78 ms**, p99 **3.80 ms**, maximum **20.69 ms**. Typing covers
both delayed persistence and the real commit/publication. The all-store matrix
has a maximum measured organization patch of **3.12 ms** and a maximum metadata
transaction of **19.65 ms** in the optimized run. Internal enqueue timing is
separate from the complete click handler.

After 50 chat visits, the optimized retention fixture settles in 547 ms with
exactly eight live displays/pages; resident footprint is 77.0→100.4 MiB. The next
360 synthetic deltas leave 100.3 MiB and a bounded 128-sample timing history. This
is a repeat-operation check, not an hour-long battery or process-family test.

- `integration-a`: **96 tests, zero failures/skips**, including native request,
  response, popup and usage captures, actor-checked race/durability/query tests.
- `edgecases-a`: **90 tests, zero failures, four skips**. Includes bounded archive
  Stop admission, newer-page shares, lazy Expand all and shell/motion checks.
- `optimized-final`: **89 tests, zero failures, four skips**. Includes the final
  selection reducer, native benchmarks, inspector, usage and read-worker tests.
- `correctness-final`: **70 tests, zero failures/skips**, Swift actor data-race
  checks enabled. Includes the complete 100-record archive/restore case, ordering,
  failure/restart, sidebar pointers, reference copy, unread, concurrency and motion.
- `topics-final`: **37 tests, zero failures/skips**, actor checks enabled; topic
  storage, organization, dragging and native presentation, with the additional
  materialization counters compiled.

The four skips are two opt-in screenshot exports already exercised in integration
and two pre-existing pointer-delivery fixtures. No content/privacy/transport
semantics were relaxed to obtain passing tests.

### Verification limits and follow-up

The local VM cannot establish physical 60/120 Hz smoothness, trackpad feel,
power/energy consumption, VoiceOver behavior or a live CJK input-method candidate
window. Two pre-existing pointer-delivery tests explicitly skip in this XCTest
desktop; the actual sidebar pointer/keyboard tests remain in the executed suites.
Existing high-contrast/RTL/motion fixtures are retained; this is not a complete
manual accessibility certification or a captured accessibility-tree diff.

Cold giant-answer sizing, full rich-block streaming and tab mounting remain above
the proposed 5 ms presentation target. These measurements are not a claim that all
frame hitches are fixed. The next renderer change needs a logical block/character
anchor and a measured isolated prototype, as required by A-07. No product delay,
reduced content, animation disablement or weaker durability was used to improve a
number. No install/update rehearsal, provider billing experiment or release ran.

Scratch evidence for this session is `tmp/smoothness-a`: `baseline-a/b`,
`optimized-a`, `profiler-b`, `five-session-b.trace`, `integration-a`,
`final-debug`, `edgecases-a` and the final optimized/correctness runs. These
synthetic logs, result bundles and profiling data are kept outside the repository.
