# Unloaded observed source and shared inspection adapter

Baseline: `61da953fb0f9394ace06be39f7bac9071971e49e`, tree
`00cbb0345c2e4c936e87c71a063b59b45ce7686d`. This bounded prerequisite enables
no sidebar content UI, persistent cache, SQLite dependency, provider/tool action,
read acknowledgment, recovery, production capture, vault, native signing, or
macOS acceptance. It is not all-history indexed search or full Swift parity.

## Two distinct source contracts

Loaded search retains its existing LoadedAccepted source witness and admission.
UnloadedObserved means complete validated bytes read under the existing cooperating
writer lock during one interval. It does not certify fsync acceptance, clear a
loaded writer's uncertainty, or promise the disk remains current after release.
A reconciliation pass is a vector of observations over an interval, not an atomic
cross-chat snapshot. Metadata/notifications can prioritize later work; only fresh
source inspection supplies the next unloaded query's evidence.

The new source receipt is opaque, bounded and Debug-redacted. It includes exact
checkpoint path/session identity, initial schema/generation/sequence/revision,
checkpoint SHA-256 and file identity, stable lock identity, journal presence and
full SHA-256/consumed bytes/complete record count/sequence range/final boundary,
final revision and observation start/end. Legacy, absent and empty-present journals
are distinct. Lock identity is metadata only (its digest field is zero), since the
lock's contents are not session source. No receipt serializes a live capability.
The search result binds this source to exact catalog membership, query/pass/attempt
and versions/content digest, plus bounded Match or NoMatch from the shared matcher.

`InspectionPermit::inspect_search` validates exact work and unloaded routing before
any disk access. The work attempt is bound into the lease at acquisition, so a
later pass/request cannot relabel an older parse. `prepare_search` shares that
parsed Session, includes complete validated active retained text under the distinct
ObservedRetained policy, then checks checkpoint, journal (including absence), lock
and ancestor closure again after projection. No valid torn prefix escapes. The
Session and all descriptors drop on the worker; no corpus history is retained.

The ordinary `inspect`/direct inspection entry points preserve existing legacy
path behavior and do not hash or retain journal observation receipts. Observed
replay explicitly opts into that extra work; a regression asserts the distinction. Search-specific acquisition rejects symlink/parent aliases and
captures ancestor identities. Legitimate exact absolute anchor paths are allowed;
paths need not be generated UUID names. This is conservative: a previously accepted
noncanonical alias can be unavailable for search until separately resolved, never
silently canonicalized into authority. Final descriptor/path checks detect observed
substitution. They are not a sandbox against arbitrary same-user attackers or
noncooperating in-place mutation that restores metadata during the read interval.
Cooperating direct SessionStore callers and other processes use the same advisory
lock, but can mutate immediately after release without notifying App. Reinspection
is mandatory for a new as-of pass; digest equality cannot renew an old receipt.

## Cancellation and ownership

One mutable existing inspection permit spans parsing, summaries, projection and
receipt completion. No catalog/actor lock is held through disk or CPU work, or an
await. Request, per-row attempt/lifecycle and selected-open/permit cancellation are
composed through checkpoint chunks, serde's 4,096-byte budget, journal buffers and
records, validators' existing stage boundaries, projection and hashing. Existing
semantic validator inner loops and individual filesystem calls remain cooperative
latency gaps; no hard cancellation deadline or performance claim is made.

A later row attempt cancels the earlier one. Counter exhaustion cancels and
suppresses the old outcome before returning a sticky blocked resource failure. Route transition/removal cancels its
work and immediately withholds its result. Numeric query generation reuse does not
reuse request identity. Selected-open registration still cancels background work
without releasing the lane before the actual lease and permit drop. The public
exclusive-borrow compile-fail contract remains in place.

## Reconciliation and App wiring boundary

`ReconciliationPass` starts every materialized authoritative member Pending on each
pass, including old negatives and missing-cache members. Pending unmaterialized
rows are excluded. It records explicit observed/loaded Match or NoMatch, pending
and failures; a failure is never a completed negative. New attempts discard prior
hits before work. Exact current membership epoch and complete eligible set are
required at finish. Added/rebound/removed membership invalidates the old pass and
requires a new full pass; an uncertain catalog cannot produce completed coverage.
Loaded routes require existing live loaded evidence and reject disk fallback.
Blocked rows remain unavailable until an explicit successful lifecycle transition.
No title/topic/archive/viewport filter defines the reconciliation corpus.

Production restored run/read demand now calls `sidebar_inspection::inspect` through
its original one-in-flight scheduler and WorkspaceStore coordinator. Its summary
and FileIdentity/read-baseline admission behavior is preserved. A frozen demand can
coalesce run/read and search in that one parse; search-only demand returns no
run/read payload and cannot synthesize a read-baseline update. A subscriber arriving
after dispatch needs a new pass, never an old receipt relabeled as fresh. Cancelled
search does not cancel the shared permit or a later run/read subscriber. If search
cancels during shared acquisition, the operation returns Cancelled and valid
run/read demand must be retried through the same scheduler.

Search demand, SearchLifecycles and reconciliation dispatch are explicit tested
APIs but are NOT wired into production AgentView query/lifecycle dispatch. The
small lifecycle map retains Loaded/Blocked records across map gaps and new passes;
map absence is not an unblock operation. It must be applied to every new/current
pass by the future adapter. There is no production content service to expose these
results yet. No second scanner, RAM-only corpus index, or competing scheduler is
introduced. Runtime late-subscriber queueing, full lifecycle integration, holds,
reveal and persistent storage remain gates, not implied implementation.

Exact upcoming pre-worker integration points audited on this baseline:
- chat_load.rs::start_chat_load: load_generation/loading before retirement;
  existing selected_open cancellation already owns priority.
- project_manager_controller.rs: chat_mode_operations/chat_mode_blocked insertion
  before ChatModeChange; projects.operation/admission_blocked before folder change.
- connection_settings_controller.rs: save operation assignment; connection removal
  blocked.extend before retirement; connection switch retirement/block insertion.
- chat_navigation.rs: workspace replacement already cancels sidebar run-state scope.
- Failed LoadRetirementOwner cleanup, project/mode/MCP/connection admission fences,
  uncertainty, shutdown and unloaded/member removal must withhold search immediately.

Connection removal's existing completion retains its unrelated blocks only for
currently live map IDs. Do not change that behavior for search or infer safe
unloading from it: the separate search lifecycle record must survive that gap.
Only successful ordinary reopen/install or an explicit safe unloading transition
may clear a search block. AppRuntime::disconnected is a real loaded writer. Direct
host inspections and public writer factories remain outside a claimed global App
parser registry; the new APIs do not silently alter their authority behavior.

## Remaining gates and evidence

Persistent-cache dependency/location/privacy, no-spill/WAL/deletion/crash tests,
canonical full tool-input presentation, UI typing/snippets/holds/keyboard/reveal,
actual native interaction, and performance acceptance remain separate. No source
image, real user data, paid provider, screenshot or user computer was used.

Validation receipts record exact source hashes, observed wall times, failures,
negative controls and final gates. Inference time is unavailable. Run exact LOC
accounting from repository root:

    python3 rust/scripts/verify-loc-unloaded-observation.py --repo . --output /tmp/unloaded-loc.json

New dormant App/backend APIs count as production LOC, not completion. Tests and
support remain separate. Shared Box source and existing documentation/evidence
Rust files remain excluded under the immutable baseline's ledger.

### Frozen validation result

The reviewed r3 Rust source closure contains 22 changed/new Rust files; the
combined sorted-path/SHA-256 JSON digest is
`b93abc6aae67750b66703a2f39ace82dd0ac05a3a84fdec6e05ca1a87c63ac2a`.
Independent review accepted r2, including the overflow and ordinary-inspection
cost fixes. The integrator verified r3 differs only in two corrected module-doc
lines. Default tests began on r2 and remain applicable under that exact comment-only
delta; all-feature/strict/build checks and final formatting bind r3. The automatic
source guard stopped when those comments changed rather than silently accepting drift.

- Core: 688 default / 873 all-feature unit tests, plus all integration targets and
  the exclusive-permit compile-fail doctest. Commands: 44.894 / 77.356 seconds.
- App: 641 default passed with one existing intentional ignore; 786 all-feature
  passed with three existing intentional ignores. Commands: 50.713 / 64.231 seconds.
- Strict all-target workspace Clippy: default 16.765 seconds; all features 20.721.
  Formatting and diff checks passed. Package-clean ordinary workspace build passed
  in 24.381 seconds. The existing proc-macro-error2 future-compatibility notice remains.
- Focused coverage includes 20 new Core observation/reconciliation tests, four
  adapter tests, 13 restored-run-state tests, 17 coordinator tests, five process-lock
  tests and 44 projection/source regressions. Full matrices include these tests.
- Seven isolated semantic mutants were caught: wrong journal digest, omitted
  journal evidence, torn-tail acceptance, skipped final closure, late-work rebinding,
  failure-as-negative and loaded disk fallback. Mutant command total: 132.426 seconds.
  Exact source was restored, followed by package-scoped clean and the full matrices.

Initial compile-signature, legacy-fixture and strict-check failures are preserved
in the receipt with their corrections. The receipt records the review-found
late-work/cancellation, overflow and ordinary-hashing corrections, not an invented
first-pass success. These are synthetic Linux/backend results, not new GUI/native
or performance acceptance; inference time is unavailable.

LOC: +1,124 production / +970 tests and support / zero benchmark. Cumulative:
60,690 production / 82,902 support / 1,192 benchmark, 144,784 nonblank physical
Rust lines. Comments count; the immutable baseline inventory is verified.
Existing 366 documentation/evidence Rust lines and shared Box remain excluded.
