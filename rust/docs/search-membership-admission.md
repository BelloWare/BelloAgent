# Catalog membership certainty for future sidebar search

This bounded Core prerequisite provides membership evidence only. It enables no
App search call site, projection, unloaded scan, persistent cache or new tool
capability. Existing production authority, credentials, capture, native signing,
macOS behavior and shared inspection-lane gates remain unchanged.

## API and payload

`WorkspaceStore::search_membership_snapshot(&Arc<Mutex<WorkspaceStore>>)` returns
one certain accepted membership snapshot paired with its opaque stamp and witness.
Both this capture and initial `search_membership_witness` acquisition lock the
catalog, may wait for persistence, and must run on a background worker. Once
obtained, witness checks never acquire the catalog, Controller actor, filesystem,
authority or inspection lane. Never hold an actor lock while acquiring membership.

The stamp binds a fresh process-local workspace incarnation, checked admission
epoch, absolute catalog path, canonical project path, existing optional project
UUID and accepted catalog revision. Membership contains only chat ID, exact
checkpoint path and materialization. No title, archive flag, draft, queued intent,
read state, connection/mode metadata or private catalog container escapes. Archive
visibility remains a separate future UI decision; archive is not membership
removal. Debug and notifications omit private paths and chat IDs.

Capture allocates only the bounded member list (the existing catalog limit is
512 chats). Mutation publication clones only small binding metadata, never another
complete catalog or its drafts. The existing transaction's own state clone and
serialization are unchanged. Reads do not create a project UUID, bind authority,
materialize a chat or rewrite legacy catalog bytes. A new catalog with no on-disk
catalog file can supply valid empty membership; this does not assert that a durable
catalog file or any checkpoint exists. A CheckpointRequired member is catalog
provenance, not proof that readable checkpoint bytes are certain or searchable.

The paired snapshot is a point-in-time receipt. Recheck `is_current()` before
making async results current, releasing held results and revealing hits. Loaded
content still requires its separate source receipt; unloaded bytes require their
own future reviewed acquisition contract. Neither receipt grants runtime/tool
authority. Snapshot getters intentionally remain readable after revocation, but
stale data is ineligible for current search results.

## Mutation and lifecycle

A guard covers the complete private `transact` operation, including closure,
validation, encoding and persistence errors. Entry revokes earlier receipts under
a checked new epoch. Success publishes Certain only after the existing accepted
memory update. A definite failure retains previous accepted state with a new epoch;
old receipts never revive. Post-rename/directory-sync uncertainty publishes
Uncertain even when catalog revision and accepted memory remain unchanged. Unwind
or unfinished finalization becomes terminal search-only Unavailable. No return
values, storage format, durability ordering or persistence refusal policy changes.
Operations that return before entering `transact` do not change accepted catalog
state and need not invalidate membership. Every actual transaction, including a
draft-only change, invalidates conservatively.

WorkspaceStore Drop retires before writer resources are released. Reopening the
same path/UUID/revision receives a distinct incarnation. Uncertain, Retired and
Unavailable cannot be overwritten by later successful finalization. Epoch
exhaustion disables membership admission without imposing a new storage error.

## Shared owner and poison contract

The associated APIs accept the existing shared owner rather than offering a public
unbound `&self` receipt. Before any receipt escapes, they bind a private weak probe
to that exact Arc allocation. Repeated binding to the same owner is idempotent;
binding the moved store to another owner is refused and revokes search admission.
The weak probe creates no strong ownership cycle. It checks owner liveness and the
mutex poison bit without locking the catalog. A retained receipt immediately
refuses an observed poisoned/dropped owner without waiting for another capture.
Poison observed by a witness or acquisition is sticky search-only Unavailable,
even if external code subsequently calls `clear_poison()`.

Once bound, keep the store in that owner for its lifetime. Moving it to another
mutex or clearing the owner's poison as a recovery mechanism is unsupported.
Because external code owns a standard public Mutex, poison cleared before any
membership check/acquisition cannot be detected retrospectively; this API does
not claim that impossible guarantee. Recover by normal store disposal/reopen with
a fresh incarnation, subject to existing preservation/recovery requirements.
Replacing and dropping a store retires its escaped receipts even if the surrounding
mutex remains alive. No application owner-recovery policy is added in this slice.

## Notifications and lock order

Updates use Notify plus private opaque generation tokens. Subscription exposes no
watch borrow or mutex guard that could delay persistence or Drop. Registering a
wait precedes the token check, so completion cannot fall into a missed-wakeup gap;
multiple subscribers and cancelled waits do not consume each other's updates.
Notifications coalesce and contain no members. They are scheduling hints only.
External mutex poison alone does not actively notify; synchronous eligibility
checks remain mandatory. Repeated unavailable health reads do not generate a
notification feedback loop.

The only nested lock is catalog owner → small membership state. Witness checks
never acquire the owner. No witness lock spans catalog cloning, persistence,
awaiting or notification wakeups. There is no new actor/catalog nesting, second
scanner, writer or inspection lease.

## Validation scope

Focused tests cover exact payload and diagnostics; empty new and byte-preserving
legacy catalogs; existing optional project identity; member removal, path rebinding
and materialization; conservative draft/archive invalidation; before/after rename;
early closure/validation/overflow errors; unwind with a still-healthy owner mutex;
external owner poison and poison-clear after observation; same/different owner
binding; Drop/reopen/replacement; Changing while catalog lock is held; final capture
revalidation after releasing that lock; epoch exhaustion; poisoned witness; and
coalesced/cancelled/multiple registered notification waiters.

Command results and deliberate negative controls are recorded separately. Source
and synthetic Core validation do not establish GUI, native acceptance, a working
sidebar search feature or performance improvements.
