# Loaded search acquisition and bounded admission

This is a Core backend integration on catalog membership candidate
`be66ab6551ba3b1114e05f86055ff7a0618048ae`. It enables no sidebar UI,
unloaded receipt/scan, SQLite/cache, new provider or production tool, capture
archive, vault, native signing, or macOS acceptance. Existing authority and shared
inspection-lane boundaries remain unchanged. No screenshot or real user data was
used. Source/synthetic tests do not establish feature completion or performance.

## Acquisition and preparation

`SearchRequest::new` creates a unique process-local request identity, caller-supplied
numeric generation, bounded normalized query, digest, and atomic cancellation flag.
Numeric generation reuse cannot make an old request match a new slot. `cancel()`
is explicit, immediate and irreversible for that request. The synchronous sealed
projection cancellation probe supports both AtomicBool and CancellationToken; no
arbitrary implementation or callback is admitted. Final admission uses the request
atomic flag, avoiding a cancellation-token mutex within witness guards.

Run `LoadedSearchEvidence::capture` and consuming `prepare` on a worker. Capture
obtains canonical membership under its catalog owner, releases that owner lock,
then upgrades a Weak Controller only around `loaded_search_source`. It releases the
strong Controller before projection, serialization, hashing and matching. It joins
exact member chat ID and checkpoint path with a CheckpointRequired member and the
accepted loaded source stamp. Membership and source must be jointly current.
Pending, failed, retired, dropped or mismatched loaded owners never fall back to
readable checkpoint/journal bytes. Accepted active journal text is included;
reasoning and transient live overlays are not.

The existing raw accepted Session Arc transfers without a second full clone into
short-lived evidence. Preparation consumes it and retains no Session, whole
membership vector, borrowed projection or prefix-chain vector in the resulting
candidate. It uses the reviewed pure projection/matcher and semantic content
identity. All projected pieces are validated before a Match or NoMatch is returned;
NUL/resource/ownership/cancellation failures never become a fresh NoMatch.

Match is newest matching message, prose before ordered calls, earliest occurrence.
Tool output identifies its own result row and owning assistant/call. Full canonical
pretty tool arguments are searched, even beyond the existing renderer's preview.
Name/input boundary matches retain honest card fallback. Reasoning, provider data,
compaction, hidden skill bodies, drafts, image containers and live tool previews
remain excluded. Visible argument strings are not heuristically redacted. The
pure original projection tests still compare mapping with unchanged Find source.
Factoring a single canonical renderer/mapping utility and full-input reveal remain
separate presentation integration work.

## Bounded retained output

A candidate contains two opaque stamps, one exact member, two small live witnesses,
request identity/query digest/generation, version tuple, content digest and either
NoMatch or one OwnedHit. Each retained binding field is capped at 16 KiB before
candidate cloning. Projection-validated piece identifiers are at most 256 bytes.
The request query has at most 256 normalized scalars and a 16 KiB raw-input bound.
OwnedHit retains only owned piece identity, occurrence ordinal, original and
normalized UTF-8 ranges, source target, and an excerpt of at most 4,096 bytes.
Witnesses contain weak owners, not Session/catalog ownership. An admission operation
pins owners only during its bounded critical section.

The excerpt uses up to 40 source scalars before and 160 after, without a UI
word-aware/layout claim. If normalization maps a small query over an original
whitespace envelope larger than the excerpt budget, the full exact original range
is preserved but the bounded excerpt has no fabricated highlight and explicitly
reports MatchEnvelopeExceedsBudget. Debug diagnostics redact excerpts and private
identity fields.
The resource bounds are not a process-memory ceiling: capture can temporarily own
one bounded raw Session, tool serialization and content prefix hashes.

## Joint admission and lock order

`SearchAdmissionSlot` retains at most one candidate for one request. It has no
public callbacks or guards. `try_install` validates the exact request, membership,
source and cancellation, then swaps the bounded Arc under the fixed order:

1. Pin private owner-health leases before either witness guard.
2. Acquire membership witness, then source witness, then slot mutex.
3. Check both pinned owners' poison bits without weak upgrades, owner locks or
   revocation calls, and check request cancellation before swapping the Arc.
4. Release all guards before sticky poison revocation, old-result destruction,
   owner-lease destruction, notification or any other work.

The lease prevents the final Weak upgrade/drop from destroying an owner under its
own witness guard. Catalog owner poisoning can occur independently from a witness
mutation, so initial owner checks alone are insufficient. Both final owner checks
are required; any observed poison is remembered and revokes outside the guards.
The preexisting rule remains: clearing externally owned mutex poison before any
observation is unsupported and cannot be detected retrospectively.

`current` briefly clones the slot's candidate and releases that mutex first. It
then follows membership → source → slot, verifies that the same Arc is still
installed, repeats owner/cancellation checks and returns point-in-time eligibility.
A concurrent clear/replacement cannot return the previously cloned candidate.
An empty slot is None; an invalid installed candidate is Stale or Unavailable,
never NoMatch. No actor/catalog lock, I/O, hash, parse, serializer, external callback
or await runs under either witness guard. Invalidation writers do not take slots.
Mutation after the admission linearization point can immediately make returned
output stale; callers must recheck on every installation, held release and reveal.

## Scope of caller responsibilities

This Core slot binds a request, not an App project/window/row route. A caller can
prepare another currently valid member/workspace for the same request and put it
in the slot. No App routing fence is claimed. Future App integration must bind and
revalidate selected project/window, query/navigation/opening generations, exact
row/load generation and Controller incarnation, and cancel on replacement,
cleanup blockers and shutdown. Archive visibility remains its independent existing
filter. Merely capturing/projecting does not mark read, edit drafts or run tools.

The next usable all-chat workflow still needs a separate reviewed
UnloadedObserved adapter through the existing shared inspection coordinator,
coalesced scans and selected-opening preemption, exact checkpoint/journal binding,
loaded-owner precedence through failed/retiring replacement states, cache privacy
and lifecycle gates, query scheduling and UI health states, and exact snippet/reveal
integration. SQLite dependency/location/temp/WAL/deletion/crash gates remain open
for product use. This change does not silently substitute loaded-only search for
all saved-chat coverage.

## Validation

The companion validation JSON records exact source hashes, command wall times,
initial failures, restored negative controls and the final source closure. Inference
time is unavailable. Focused tests exercise exact binding/materialization, accepted
active text, all four kinds/full input ownership, exclusions, NoMatch versus errors,
UTF-8 bounded excerpts, cancellation/request reuse, source/catalog invalidation,
nonoverlapping acquisition receipts, retained ownership, owner poison in the final
admission gap, jointly held witness guards, slot replacement and concurrent writers.
Shared Cargo uses the existing official 1.99.0 toolchain/cache, jobs=2 and locked
commands. Builds/tests are synthetic Linux validation, not native or GUI acceptance.

### Reproducible source accounting and build provenance

Run from the repository root:

```sh
python3 rust/scripts/verify-loc-loaded-search-projection.py --repo . --output /tmp/loaded-search-loc.json
```

The verifier checks every immutable baseline Rust inventory hash, then counts the
reviewed changed files using nonblank physical Rust lines including comments,
positive cfg(test) spans and wholly test-owned files. The exported Core backend
and projection count as production code; imported unchanged Find tests count only
as the source files they occupy, not as duplicated production. This slice adds
1,424 production and 1,310 support lines, no benchmarks. Cumulative counts are
59,566 production / 81,932 support / 1,192 benchmark (142,690 total), excluding
366 existing documentation/evidence lines and shared Box sources.

Negative controls were compiled in a separate detached worktree. After switching
back, the shared Cargo target initially reused its last mutant binary despite
restored source hashes. That invalid restored run is preserved in the receipt.
A package-scoped `cargo clean -p bello-agent-core` followed by a real final-worktree
rebuild passed all focused and projection tests before subsequent gates. Never use
cross-worktree cache reuse alone as exact-source execution proof.
