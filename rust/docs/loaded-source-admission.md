# Loaded-session source certainty for future sidebar search

This is a bounded Core prerequisite. It does not enable sidebar content search,
project membership admission, App search call sites, the separate pure projection,
unloaded search acquisition or a persistent cache. Existing provider/tool, capture,
vault, native authority, signing and macOS acceptance gates remain unchanged.

## Paired capture and revocation

`Controller::loaded_search_source()` captures an immutable raw accepted Session
and private-constructor source stamp from one actor-locked boundary. It checks
retirement and store certainty and rechecks its receipt after the actor lock is
released. Run capture on a background worker: it may wait for persistence and
clone a large transcript. A streamed token updates only a small witness; it does
not cause another full transcript clone for search.

The stamp binds process-local source incarnation, admission epoch, chat ID,
absolute checkpoint path, accepted revision, stream generation and sequence.
A returned snapshot is a point-in-time receipt, not permanent permission. Check
`is_current()` again before admitting asynchronous output, releasing held results
or revealing a hit. Project/catalog membership must be separately established by
a later reviewed integration. A receipt is never tool/runtime authority or an
unloaded-file durability receipt. Existing display/Find/read-state publications
are deliberately not reinterpreted as this evidence.

The captured raw Session still contains private containers, including reasoning,
provider items, pending inputs and other nonsearchable metadata. **It is not an
approved search projection.** Future projection must exclude those containers and
transient live previews under its own reviewed contract. Do not log, persist,
index or expose the raw Session merely because capture succeeds. Receipt/snapshot
Debug output and notification messages omit transcript and source paths.

## Mutation, durability and lifecycle

The store publishes Pending, Changing, Certain, Uncertain, Retired or Unavailable.
Whole-operation guards wrap existing materialization, checkpoint and stream-delta
paths. All returned errors reach finalization, including errors for which the
Controller never publishes a new display snapshot. Definite failures retain old
accepted content under a fresh epoch. Earlier receipts cannot revive just because
revision/content stayed unchanged. Wrapping whole operations also invalidates
preflight/no-op failures conservatively. Uncertainty, retirement and search-only
unavailability are terminal within that source lifetime; epoch exhaustion fails
closed without imposing a new persistence refusal.

Existing durability order is preserved. Checkpoints are accepted after file write,
file synchronization, rename and directory synchronization. Streamed deltas are
accepted after journal append/file synchronization and, for a new journal, parent
directory synchronization. Thus accepted active text can be captured from a
certain store, while attempted unsynchronized text cannot. No snapshot/journal
wire format, dependency, error-return or recovery policy is changed.

Initial materialization preserves its Controller's witness and incarnation when
the pending store is replaced. SessionStore Drop revokes receipts before writer
resources drop. Controller retirement revokes before potentially waiting on stop
or the actor; late admitted completion cannot overwrite Retired. Worker joins and
idle-admission ownership still govern actual writer release. Controller Drop also
revokes if a temporary internal actor reference remains.

A private weak owner-health probe checks the actor mutex poison bit without
locking it. It is bound before the Controller escapes and creates no strong
cycle. An old retained receipt immediately refuses a poisoned/dropped owner,
without relying on another capture to notice. A standalone SessionStore remains
valid without a Controller binding. No strong actor reference is publicly exposed.

A defensive unexpected error applying a delta after successful journal write
marks search Unavailable before returning the original error. Current target
prevalidation makes this unreachable in ordinary execution; a test-only injection
covers future fallible apply changes. It is not a claimed reachable storage bug.

## Notifications and locking

Source notifications use Notify and opaque generation tokens. Subscriptions expose
no borrow guard that could block retirement. Registration precedes the token check;
updates coalesce without queuing transcript snapshots. Multiple subscribers and
cancelled waits do not consume each other's updates. Waking occurs outside the
source-state mutex. Notifications schedule work; receipt checks decide eligibility.

Actor operations may briefly lock the source witness. Witness checks never lock
the actor or read the filesystem, catalog, vault or runtime authority. Raw Session
cloning occurs outside the witness lock, followed by revalidation. There is no
new catalog lock or shared inspection lane in this slice. Later unloaded work
must reuse the existing coordinated lane and cannot clear a loaded uncertainty
by reading disk. No hard responsiveness or performance guarantee is claimed.

## Review and verification

Thirty-three focused regressions cover materialization, unchanged-revision commit
failures, stream metadata/append/partial-append/sync/directory-sync failure, accepted
active text, generation rotation, capacity/revision/sequence/record limits, old
row/role/tool-input changes, mutation unwind, owner drop/reincarnation, complete/
torn/malformed recovery, recovery-checkpoint failures, capture/retirement races,
failed/cancelled joins, immediate poison refusal, epoch exhaustion, diagnostics
and notification interleavings. Read-only inspection cannot revive an old receipt.

Review corrected a watch-borrow retirement deadlock hazard, lazy actor-poison
observation, defensive post-write failure handling and notification race coverage.
Independent final source review found no remaining blocking issue in this bounded
slice. Six deliberate mutants failed their intended regressions: omitted checkpoint
publication, revival after retirement, omitted poison checks, lost materialization
witness, omitted final capture check and reused incarnation. Original source bytes
were restored before the final full suites.

Detailed command results, source hashes, timing and LOC provenance accompany the
[validation receipt](validation/loaded-source-admission-2026-10-09.json). An initial
zero-test compile probe is not a test pass. A role-edit fixture initially retained
invalid user task-root provenance and was corrected without weakening validation.
The first App attempt omitted existing GPUI sysroot paths and failed at linking;
that attempt ran no tests and is retained separately from corrected validation.

This slice has no new UI. Prior ordinary Linux navigation evidence for 9881049
remains prior evidence only; it does not accept a new search feature. No actual
GUI, native macOS behavior, production credential access or user-data search was
exercised here. LOC and command durations are not feature-completion percentages
or application-performance measurements.

Final restored Linux gates passed: Core 622 default and 807 all-feature unit tests,
all integration targets and the inspection compile-fail doctest; App 637 default
(one intentional benchmark ignore) and 782 all-feature tests (three intentional
benchmark/macOS-only ignores). Strict Core/App all-target Clippy passed in both
configurations, along with workspace formatting and diff checks. Final command
wall times were 36.792 s Core default, 45.407 s Core all features, 22.022 s combined
Core strict/format, 70.988 s App default, 51.217 s App all features and 34.619 s
combined App strict. The first missing-GPUI-environment link failure took 65.765 s
and is not included as a successful gate.

The [LOC delta ledger](validation/loc-loaded-source-2026-10-09-delta.json) chains the
full verified 9881049 Rust inventory and inherited categories: +455 production,
+957 tests/support, zero benchmark; totals 57,688 /80,052 /1,192 respectively.
Shared Box and 366 documentation/evidence Rust lines remain excluded. Three ledger
negative controls rejected wrong totals, wrong source hashes and lost exclusions.
