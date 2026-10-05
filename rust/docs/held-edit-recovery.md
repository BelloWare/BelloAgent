# Held queued-edit recovery: implementation invariants

Design baseline: `0bfc12042c3464c10fad72df5f870218cf208a7e`.
This records the reviewed implementation boundary, not completed parity.

Specification: `QueuePanel.swift:185–232,331–338,370–739`,
`NativeComposer.swift:160`, and `SessionQueueEdit.swift:44–52,132–146`.

1. A Begin/Resume request never freezes ordinary typing or captures a displaced
   draft before its reply. Adoption captures the latest draft, rechecks chat,
   project, controller, edit/turn, window generation and focus, and waits while
   marked composition is active. Pending adoption blocks conflicting submission
   actions, not typing. Cancellation invalidates deferred adoption immediately.
2. Cancel first marks local abandonment, then durably prepares its exact identity
   before dispatch. A crash before preparation is acknowledged can leave an
   unowned hold. After durable preparation, recovery retries Cancel, never Begin.
3. A separate per-chat catalog receipt fences cancellation independently of
   debounced drafts. Prepare/settle compare identity, operation revision and
   payload. Settlement may retain a newer draft while clearing the exact intent;
   equal draft revision with unequal contents is a conflict. Retain settled
   receipts to reject delayed preparation. Never overwrite newer live text with
   a returned background catalog snapshot.
4. Every Save/Remove route, including generic removal of the held row, keeps an
   exclusive operation barrier from exact-draft flush through definitive
   settlement. No competing Begin/Resume/Cancel can cross it. Uncertain storage
   blocks authoritative recovery until reopened and confirmed durable.
5. Cached session snapshots are presentation only. Startup, refresh and explicit
   recovery use typed edit status under the actor mutex, checking fatal state and
   storage uncertainty. Reopen confirms the validated existing file and parent
   directory before an authoritative answer. Unknown Cancel tombstones only its
   identity and never releases another edit's hold.
6. Validate the complete reconciled draft before changing live ownership or text.
   Oversized merges and revision overflow preserve all original recovery material.
   Protocol revisions use checked allocation. Explicit owned Cancel discards its
   rewrite; unowned/recovered reconciliation preserves genuinely unsaved rewriting.
7. Catalog v3 promotion is monotonic; old valid v1/v2 files are readable without
   an opening rewrite. New tagged records, chat references and revision consistency
   are validated; malformed bytes are preserved. Only edit/outcome invariants are
   strengthened. No general operation journal, retention policy, provider, shared
   editor, native lifecycle or unrelated schema changes belong in this slice.

Required checks include crash cuts around prepare/actor/settle, newer autosave
winning settlement, equal-revision payload conflict, Cancel before Begin and
beside another hold, uncertainty/reopen, generic held-row Remove, oversized merge,
revision overflow, IME defer/cancel, navigation/controller/window replacement and
unchanged active streaming. Source row controls require real Linux interaction
and minimum-width checks; Linux and headless tests do not establish native macOS
IME, accessibility or pixel parity.

Checkpoint boundaries: first wire certain status into existing recovery; then
wire durable Cancel receipts, nonfreezing adoption and source held-row controls.
Every published checkpoint must build and expose useful behavior, with independent
review and its actual validation scope recorded separately.
