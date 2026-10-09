# Existing-chat read attention

This slice adds durable read attention to the existing Rust chat identities. It
uses catalog v12 metadata and accepted Controller observations, not UI message
counts, semantic activity timestamps, provider replay, or live-token callbacks.

## Persistence and admission

The workspace owns the read map even when a chat is unloaded. First inspection
or opening establishes an in-memory baseline without rewriting a catalog or
journal. Before Send, Retry, Resume, queued edit save/remove, or cancellation
that can release queued work, the exact registered chat ID/path and workspace
identity must have a confirmed baseline. A failed or uncertain write prevents
that dispatch and preserves the existing draft/intent/cancellation machinery.
The submission outcome distinguishes a proven pre-dispatch failure from an
uncertain actor acceptance: only the former restores/merges the original input
with newer typing while retaining the catalog/read-state uncertainty fence.
Unknown acceptance after actor dispatch keeps the preexisting receipt policy.

Automatic unread debt and its advanced observed baseline are one catalog
transition. The 600 ms foreground bottom-follow grace hides only the newly added
portion in memory; it never removes durable debt. Older unread remains visible.
Relaunch displays the persisted obligation without inheriting a timer. Changed
Controller generations, Mark as Read, replacement and deletion invalidate held
presentation. Metadata does not reorder activity or change the transcript.

One background writer per workspace coalesces dirty state. It releases the UI
metadata mutex before filesystem I/O. Receipts acknowledge only their own saved
revision; a newer mutation remains dirty. Definite failures have a bounded
three-attempt automatic budget. Explicit admission/close can retry; uncertain
storage retains the admission fence. Errors before the flush body runs (including
an unavailable catalog mutex) also consume the bounded retry budget. Removed/path-replaced rows are pruned from
background work, while an admission for such a row fails explicitly.

The read-state writes and the modified output-admission completion chains use
exact workspace Arc identity, including rejected-Send draft recovery and Cancel
settlement before adopting uncertainty. This is a bounded lifecycle integration,
not a whole-app concurrency retrofit: older unrelated selection, title and draft
debounce callbacks are outside this change.

Orderly close joins Controllers before directly capturing their final accepted
observations. The final flush includes every dirty read-map entry, including
unloaded chats and chats absent from the draft-save list. A flush failure is not
a successful close.

## Reader actions and actual visibility

A genuine explicit focus change clears manual unread and failure attention.
Reselecting the same chat clears only failure attention. Startup, reconnect and
recovery do not count as opening. Mark as Read clears all attention. Merely
seeing a reply never clears a manual unread marker. The sidebar row menu and
selected-chat action share eligibility checks; archived, missing, unregistered
and unsent pending chats cannot be marked. Loaded persistent Controllers retain
precedence. Unloaded actions require a current identity-bound scanner receipt;
checkpoint identity is rechecked asynchronously at the action boundary. Missing,
replaced or symlinked checkpoints cannot gain a manual marker from a stale scan.
This metadata check does not parse history or acquire a second inspection lease.

Failure attention has its own source-level rule: a selected conversation in an
active application suppresses a new failure marker. It does not require reply-end
visibility or an uncovered window. macOS uses NSApplication.isActive; Linux uses
verified platform keyboard focus in an owned application window. If application
activity is unavailable, failure attention is retained conservatively. This is
separate from the stronger automatic acknowledgement/grace visibility gate.

Automatic acknowledgement requires the exact newest retained output identity,
current Controller generation and accepted source revision, the current
transcript presentation, and the actual final projected row end inside the
post-layout viewport. Overdraw, materialization, a long reply's first line,
bottom-follow intent, older replies and pending scroll/layout are insufficient.
A deferred callback rechecks identity, generation, current revision and scroll
position before acknowledging.

On macOS, read-only queries use the existing exact-window AppKit bridge:
application active, key and visible window, not miniaturized, visible occlusion
state, no attached sheet, and a nonhidden GPUIView with a positive finite visible
rectangle. In-app modal/file surfaces also block acknowledgement. This code
requires native compilation and focused native acceptance; Linux and synthetic
GPUI tests do not prove AppKit behavior. In macOS test builds, application-active
and native-visibility adapters deliberately report unavailable/false instead of
calling AppKit from TestAppContext. Pure explicit evidence/reducer matrices still
exercise every condition on every platform. The foreground/background GPUI test
is explicitly Linux-scoped; production macOS builds compile the real bridge.

**Linux automatic visibility acknowledgement is deliberately unavailable.**
The pinned GPUI API cannot establish external occlusion. An active synthetic or
Linux window is not treated as proof. Automatic unread accumulation and manual
Mark as Read/Unread remain available. Synthetic geometry tests can establish
row-end calculations independently, without claiming native visibility.

## Counts and limits

Row count is max(automatic replies, manual marker ? 1 : 0). Manual-only wording
is “Unread.” Failure attention is separate from the existing run-status label.
Collapsed topic/project headings aggregate attention. Archived rows hide all
attention while retaining metadata for restore. The pure Dock predicate counts
one chat for manual unread, or automatic unread without failure; failure alone
and automatic-plus-failure do not count. Actual native Dock delivery, bounce,
VoiceOver, native menus and native focus/occlusion acceptance remain separate.

The classifier is exact only for output representations actually retained by
this Rust implementation. It does not reconstruct discarded timeline-only
failed output. Accepted failure occurrences are accumulated during a Controller
lifetime and flushed after orderly join; this is not a crash-durable historical
failure-event journal. Unknown/contradictory history cannot become a false
baseline or automatic acknowledgement. No new side/fork/utility identities,
credential access, production authority, or provider execution were added.
