# Performance review follow-up for 0.1.62

Baseline: `fe5b1daf2359117fa6e257722af1544b1b72c1a6`, released 0.1.61.
This implements the second uploaded Performance-Review.md. The older
[performance record](Performance-Review-Implementation-2026-09-20.md) describes
changes already included in 0.1.61, not new results for this release.

## Finding dispositions

- **PF01 — implemented targeted invalidation and live code leaves.** Work-list
  geometry is keyed by actual tool rows, reasoning, usage rendered within that
  list, disclosure, fetched inputs, width and environment. Reply prose, freshness
  and turn-footer changes do not discard it. Outer rows still remeasure wrapping
  usage/prose. A fence arriving live starts with persistent TextKit storage;
  crossing the old 16 KiB cutoff does not replace its selection owner. Small
  completed fences retain the previous SwiftUI path. Full active-row component
  virtualization remains a follow-up; no paint-only usage assumption was made.
- **PF02 — partial, exact-geometry memory improvement.** Markdown records create
  hosts on measurement/mount and release distant unselected native trees through
  the existing shared input-quiet scheduler. Source, exact per-width geometry,
  copy targets and selection remain owned independently. Initial exact sizing
  still measures all blocks. Provisional inner-block sizing and full incremental
  first-paint virtualization are deferred: the existing outer anchor identifies
  a transcript row, not the logical block/character within one giant row. Shipping
  estimated inner heights as exact would reintroduce scroll jumps. No shared
  sizing host or universal native-code replacement was introduced.
- **PF03 — implemented bounded large-table rendering.** Tables above 40 rows or
  8 columns show an explicit 20-row/8-column preview. “Open full table” opens a
  native table window with visible-cell reuse, bounded-sample stable column
  widths, full selected-cell text and complete TSV copy. Small tables keep their
  existing layout. Whole-message/section Markdown copy remains source-based.
- **PF04 — implemented.** Growing trace bodies/events belong to private objects
  owned solely by TraceStore's actor; no mutable reference crosses the wire.
  Published packets and inspector pages remain immutable. Retained-byte
  accounting is incremental, including trim, clear and eviction. Durable capture
  remains independent of memory prefixes and credential masking remains explicit.
- **PF05 — implemented ingress limits and sender coalescing; separate pipelines deferred.** URLSession
  callback admission accounts bytes before enqueueing, with a 64 MiB total
  response limit, 4 MiB pending per request and 32 MiB pending per helper. The
  task suspends at 1 MiB and resumes below 512 KiB; headroom covers queued
  callbacks. Budget overflow fails with an explicit partial prefix. Processing
  releases reservations only after ordered capture and parsing. At most one
  32 KiB batch enters the consumer at a time; callbacks already received while
  it waits for capture ACKs coalesce into the next batch. Original callback
  byte boundaries/timestamps remain separately bounded and drive event timing.
  There is no timer or wait for a future packet. The existing
  durable begin/ACK and finalization ordering remains. Capture and parsing were
  not split into independently advancing pipelines, and no new dispatch-before-
  durable-begin behavior was introduced. Additional stage timing is deferred.
- **PF06 — implemented.** Reports use a dedicated serial worker and read-only
  SQLite connection. Each query owns a short WAL snapshot, with reader-only
  progress cancellation and explicit close/drain. Request paging and session
  expansion issue count/row queries, not aggregate percentile/window queries.
  Headlines publish before secondary groups. Paging retains the summary's
  observation and explicitly labels later row refreshes; refresh recomputes
  totals. Offset paging remains bounded to 100,000; keyset cursor semantics are
  deferred. Nearest-rank percentiles and missing-sample coverage are unchanged.
- **PF07 — partial.** Combined Response is built off-main only when selected;
  Events is the initial stream view. Generation/cancellation checks guard
  publication, and closing releases the controller document. UTF-8/Hex remain
  demand-driven. A full byte-offset/lazy-event outline, bounded derived-format
  eviction and lazy Copy View are deferred: the current outline/export contract
  still eagerly materializes parsed/formatted event frames. No truncated view is
  labeled complete and no retained bytes were dropped.
- **PF08 — implemented the measured hot-cache cost; broader component reuse
  deferred.** The Darwin cache checks an internal type/length-framed SHA-256
  identity over original UTF-8 before JSON serialization. It includes the entire
  request and profile/endpoint, preserves baseline invalidation, retains only
  small digests, and never substitutes that identity for the existing actual-byte
  fingerprint. System SHA-256 replaces the portable implementation on macOS,
  verified against it and known vectors. Cold request serialization, per-item
  baseline hashing, image-dimension caching and sharing final capped dispatch
  bytes remain follow-ups; their correctness boundaries are unchanged.
- **PF09 — implemented bounded prepared-statement reuse and sender coalescing.** Writer and reader
  connections independently retain at most 96 prepared statements. Each use
  resets bindings and statement counters, including failures. Execution,
  preparation, sort and commit counters are distinct. The PF05 sender combines
  already-received bytes before capture admission. Active-attempt scope
  caching and filesystem/transaction batching are deferred. Every existing data and
  directory durability barrier, manifest ordering and ACK remains; no producer
  waits for a later packet that cannot be sent before its current ACK.

## New measurements and validation

Measured on the same virtual Apple M3 Max, 10 CPUs, 16 GiB, macOS 14.8,
Xcode 16.1/Swift 6. Helper and native tests use Release. Native windows are tested
serially; early development samples that overlapped compilation are exploratory.
Final comparable figures and release validation are recorded below before publication.

Initial isolated baseline: 134 rich streaming deltas in a 300-row pane averaged
20.4 ms; the 640-block/83,288-byte answer sized in 721.60 ms and retained 640
hosts; a 1,500-row table sized in 496.47 ms. These are native layout opportunities,
not physical presentation or a measured 60/120 Hz frame rate.

No physical trackpad, external-display, VoiceOver or macOS 26 result is claimed.
No installation/update rehearsal is run under the owner's standing policy.

### Observed improvements and remaining limits

- The real TraceStore append fixture (three samples per size, Darwin Release)
  improved its 8 MiB median from 461.79 ms to 2.07 ms in memory mode, and
  570.22 ms to 62.91 ms with an acknowledging capture sink. This is append-loop
  time, not native filesystem latency or total application speedup. Immutable
  prior snapshots, credential transformations, trimming and final hashes remain tested.
- Repeated 32 MiB context counts fell from 1,283 ms to 15.22 ms after moving the
  identity lookup ahead of serialization. The initial preparation baseline
  overlapped native compilation; treat the ratio as exploratory, not an isolated
  whole-app speedup. Final isolated results are linked in the release record.
- A 68,309-byte/1,500-row table sized in 496.47 ms before and 16.68 ms after the
  explicit preview. This changes presentation, not the retained/copyable source.
- The isolated 134-delta rich-row run did **not** improve: baseline mean 20.4 ms,
  p50/p95/max 20.25/28.48/34.00 ms; follow-up mean 21.6 ms,
  p50/p95/max 21.98/30.21/56.04 ms. Required full-row sizing remains the primary
  renderer limit. No one-frame or universal smoothness claim is made.
- The 640-block answer still performs a full cold exact measurement. Its follow-up
  sizing sample was 917.18 ms versus 721.60 ms baseline; host construction moved
  into the measured phase, so these do not isolate a regression or a speedup.
  Once idle, the viewport test retains fewer than 40 native trees for 160 block
  records and preserves the selected field, exact height and full source.
- A new 160-delta live-fence fixture measures p50/p95/max 4.60/10.63/15.47 ms
  while growing from a tiny fence through 16 KiB and completing without replacing
  the selected TextKit view. This is distinct from the old complete-90-KB fixture.
- The first 20-session single-project test hit its unchanged 25-second deadline:
  1,400 tiny byte packets were queued behind delayed capture acknowledgements.
  Sender coalescing fixed that case. All three executable concurrency cases now
  pass; the slow-ACK single-project run completes in 7.903 s, 20 tool rounds,
  peak 20 concurrent HTTP requests and 80 exact captured bodies. Cancellation
  and one provider failure remain isolated from the other 18 sessions.

Detailed final test counts, combined native/helper load and signed/public artifact
checks belong to [the release record](validation/Bello-Agent-0.1.62-2026-09-20.md).
