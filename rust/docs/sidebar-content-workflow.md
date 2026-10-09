# Sidebar saved-content workflow integration

## Status and source parity

This slice connects the existing sidebar filter, lifecycle records, shared source
worker, private cache, bounded snippets and normal-open reveal. **Production cache
readiness remains closed.** Only a debug Linux `synthetic-authority` disposable
fixture launch can exercise the enabled UI. That is synthetic-feature validation,
not ordinary production activation, native macOS acceptance, or provider/tool QA.

The implementation baseline is `92fca5871240788f9da9c109fe451c76fb128480`, whose
Rust source is identical to published `4bde7489a19974ca4d250209f8cc0b05d3afb340`.
The latest independently checked Swift main at 2026-10-09 13:59:10 UTC remains
`6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`, tree
`43ed6d8843a09b58fe00d436dd0e0c1a56c76972`. Existing sidebar design,
unloaded-reconciliation and privacy reports remain inputs, not product acceptance.
No Swift import, other-project search or native authority gate is added.

## Actual demand and ownership

- Committed filter text gets a 120 ms token-owned debounce. IME notification-only
  commit is observed, and identical committed text receives its own full delay.
  Oversized/replaced/composing queries revoke pending reveal and decorations before
  any cleanup or debounce early return. Title/topic matching remains independent.
- All materialized exact members participate, including verified negatives,
  never-opened rows and failures. Explicit Check again and foreground reactivation
  start fresh passes; a cached negative cannot hide a later journal-only match.
  Unknown/foreign/missing/unsafe sources are unavailable, never NoMatch.
- Existing run/read demand and content preparation share one retained in-flight
  marker and the catalog's inspection coordinator. Search-only scans produce no
  read acknowledgment and never create/recover a Controller, invoke providers or
  tools, or mutate the source. Explicit click/Return uses normal chat opening and
  its existing read consequences before fresh loaded reveal.
- A loaded snapshot invalidates only that member. Repeated loaded updates cannot
  repeatedly cancel unrelated saved scans: queued-again work is coalesced and
  never-visited members precede repeated members. Membership and query changes
  still revoke the whole pass. Selected opening keeps its existing priority.
- The cache connection is worker-owned while used. Foreground disposal uses the
  existing background executor. No actor/catalog guard spans SQL, source I/O or
  await. Cached hints require fresh source receipts and exact occurrence agreement;
  they cannot manufacture a fresh UI receipt or replace full reconciliation.
- SQL queries currently use a separate reader connection **on the serialized
  source job**. A dedicated independently cancellable concurrent query worker is
  still a scheduling/performance gate. This slice does not claim that architecture
  or warm-cache parity, and does not introduce a RAM-only parity substitute.

## Lifecycle and cleanup

Search-only lifecycle records survive Controller-map gaps without changing existing
connection block retention. Pending/loading, retired/uncertain owners and failed
cleanup cannot fall through to disk. Actual invalidation is wired at chat load,
chat-mode change, project-folder save, connection save/removal/switch, known catalog
uncertainty, window binding/close, foreground activation and shutdown. Project,
Connections, connection-picker and MCP modal opening synchronously revoke reveal
admission before delayed geometry can run.

Successful exact installation establishes Loaded ownership; it does not itself
mint LoadedAccepted evidence. Operation restoration is token-scoped and cannot
undo a newer retirement. Certain configuration failures, including partial settings saves, restore their
exact prior ownership routes; Loaded still requires fresh healthy source evidence
and cannot fall back to disk. Uncertainty retains fences. Authoritative membership removals queue
cache deletion, separately from lifecycle invalidation. Binding-owned membership
ledgers are cleared on namespace replacement, and old workspace completions cannot
restore cache ownership into a new workspace.

Cleanup intents retain every failed ID, including first/middle failures, and merge
new arrivals with deletion taking precedence. Two automatic retries (100/200 ms)
are bounded; explicit refresh resets retry admission. Pending cleanup suppresses
hits. The live atomic cache barrier is checked at display and reveal admission;
failed cleanup never becomes an available result. No mtime-only freshness claim is
made. Observed disk data is as-of an inspection interval, not loaded durability or
continuous live currency. Advisory locking and same-user/out-of-band limitations
remain those documented in `unloaded-observation.md` and
`sidebar-private-cache.md`.

## Display and reveal

Existing archive/topic/pin/activity ordering is retained. Held lists defer newly
arriving matches while immediately removing inadmissible ones. Previously admitted
IDs retain hold credit during Pending reconciliation, but never retain stale hit
bytes; query changes and terminal no-match/failure remove that credit. Snippets are fixed
single-line bounded text. Click and Return capture the same displayed render's
identity/ticket, rather than recomputing Return's order after a later notification.

A reveal ticket names the retained message/call, piece order, occurrence and source
mapping. Opening reacquires a fresh LoadedAccepted candidate through the same lane.
A complete selected-piece semantic digest detects changed bytes outside the snippet
and normalized-equivalent edits while permitting checkpoint-generation rotation.
At most two fresh retries handle opening-time receipt revocation; no stale receipt
is admitted. Transformed, omitted, truncated or cross-field previews use explicit
owning-card fallback rather than guessed character ranges.

First cross-chat reveal waits for the exact owned selection-persistence callback,
pending read-state writes, and current reconciliation/cleanup, rather than a fixed
sleep. Selection completion is revision/workspace/window/navigation fenced. An
explicit intent remains after landing only to reacquire decoration when metadata
transactions revoke membership. Such refresh still revalidates the full selected
piece and fresh source/cache evidence, and cancels its navigation token before
installation. It cannot scroll again. Wheel, Find, query, scope and window changes
cancel the intent and its source request. Even rejected old worker completions wake
new demand when releasing the shared lane.

Sidebar decoration has a separate owner from transcript Find. It preserves Find's
field/current match and manual editor selection. New explicit navigation revokes
older opposing navigation; old Find pages may update counts but cannot overtake a
new sidebar action. Manual wheel permanently revokes the navigation ticket. Fold,
preview and virtualization changes invalidate geometry even when source revision
is unchanged. Actual geometry delivery, deferred notices and bounded fallback
recheck source, presentation owner, shared UI revocation and live cache admission.

## Private cache and synthetic launch

See `sidebar-private-cache.md` for the official pinned SQLite dependency, build and
runtime no-spill checks, private platform namespace, repository/forwarding-VFS tests,
cleanup barriers and remaining native gates. The denied OS tracing route was not
retried or bypassed. VFS assurance is SQLite-specific, not whole-process tracing,
swap prevention or forensic erasure.

The only enabled QA route is
`--synthetic-sidebar-search-fixture ROOT`, compiled only with debug assertions,
Linux and the nondefault `synthetic-authority` feature. It rejects every additional
argument before ordinary path/profile/stdin handling. A private, canonical,
explicitly disposable root, versioned marker, stable lease and exact fixed catalog
confine source/cache/layout files. Unknown siblings, links, external catalog paths,
connections and unsafe roots fail closed. Restart preserves the fixed synthetic
chats. The typed cache installer requires the exact WorkspaceStore owner and cannot
set a public readiness boolean. The window is visibly labeled synthetic, authority
is unavailable, and no provider configuration or credential global is installed.

## Validation and remaining acceptance

Focused TestPlatform regressions exercise actual filter notifications, shared
worker/cache dispatch, loaded and unopened members, negative-to-journal-match
transitions, missing-source failures, normal unopened opening and fresh reveal,
exact debounce/IME boundaries, workspace/window cancellation, loaded-update
coalescing, source/presentation geometry races and independent Find ownership.
The first sealed synthetic GUI attempt found a genuine cross-chat first-open
failure that isolated initial-paint tests missed: selection persistence and held
Pending rows cleared the reveal/results. That failed attempt is retained. Follow-up
regressions advance the actual selection timer and a later real read-state write,
retaining the pointer hold and asserting fresh decoration without re-navigation.
These are not substitutes for actual GUI interaction. Local GUI captures, when
used, are not published.

Final command receipts distinguish failed attempts, exact tested source, restored
full Core/App feature matrices, strict checks, semantic negative controls and the
sealed synthetic binary. Timing records contain observed command/workflow intervals;
inference time is unavailable. Native cache ACL/VFS/dependency execution and native
UI acceptance remain separate gates. Production activation requires accepted
privacy/platform readiness evidence and resolution of the outstanding scheduling
and native workflow acceptance items; this commit does not turn it on.
