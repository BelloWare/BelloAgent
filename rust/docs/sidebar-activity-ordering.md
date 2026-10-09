# Sidebar activity ordering

Implementation source: Swift `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`,
`MetadataStore.swift`, `WorkspaceActivityOrder.swift`, `WorkspaceRunHolds.swift`.
The immutable migration handoff restrictions remain applicable.

## Durable key

The catalog stores an optional Unix-microsecond `last_activity_at`. The effective
key is `max(last_activity_at, sidebar_order)` with missing values treated as zero.
Pinned is a boolean grouping, followed by descending effective key and ascending
chat ID. Pin timestamps do not rank pinned chats. Legacy creation fallback remains
presentation-only when opening an older catalog; reading/sorting does not save.

Activity is emitted by the Controller at accepted semantic boundaries, not from
Session-watch arrivals, revision changes, token updates, journal hydration, draft
changes, or history loads. The separate latest-value watermark survives a
coalesced start/finish pair. New/recovered actors start with an empty watermark.
Observer delivery checks exact workspace, chat ID, snapshot, and weak actor identity.
The workspace is captured at ChatState construction, not lazily inferred during
callback delivery. Construction captures the current semantic watermark, and the
subscription also delivers its exact initial value so an event between capture
and subscription cannot disappear. Recovered actors' empty initial values are
neutral. Same-snapshot retirement captures the outgoing actor before replacement;
a different snapshot gets a new coalescer identity.

A chat has at most one activity catalog write in flight and one dirty maximum.
An older confirmed result cannot clear a newer timestamp. A pending chat can
accumulate activity without creating a catalog row; registration captures the
current stamp and a later dirty maximum drains after registration. Writes patch
only the activity column. Definite failures retain dirty state and have a budget
of three attempts. Unconfirmed persistence preserves the workspace-wide fence,
including a result whose originating actor is no longer current.

## Presentation holds

Only changed activity keys are held. Pointer ownership and the newest menu token
are independent reasons; ending one cannot release the other. A stale menu
completion cannot end a newer menu's hold. Pin/archive/topic membership and new
rows remain live. Held identities include snapshot path and are pruned when
records disappear or are replaced. There is no manual drag-order workflow or
invented side-family hierarchy.

The pinned GPUI 0.2.2 source has list-level `on_hover`, actual mouse-event
callbacks, `Context::observe_window_activation`, and `App::on_window_closed`.
The actual sidebar list is measured during layout. Every fresh MouseMove resolves
pointer ownership against those bounds, even when GPUI's previous hover boolean
has not changed. Activation and window resize invalidate measured bounds; a stale
painted mouse callback cannot clear Unknown until its geometry matches the current
measurement. Native completion and activation query the exact active retained
AppKit window/content/GPUIView for a fresh logical-pixel point. A cached
`Window::mouse_position` is never treated as fresh evidence after activation,
rebind, or native menu tracking.

An active binding with no fresh pointer evidence holds an explicit Unknown reason
until a native query or actual mouse event resolves it. Unknown is not a claim
that the pointer is inside the sidebar. This conservative fallback can retain
activity order during keyboard-only activation on a platform without a successful
fresh query; explicit pin/archive/topic/new-chat changes remain live. Background
and detach release all reasons. A stale menu token cannot consume a fresh point
or dismiss a replacement menu. Closed native windows discard menu completion, so
independent detach cleanup is necessary. Native AppKit behavior still requires
separate native acceptance.

Shutdown keeps the existing draft-save/selection/worker-join policy. It captures
admitted record maxima and flushes the final Controller watermark only after the
workers join. An activity save failure blocks successful closure; an empty
pending chat is not registered merely because it has activity state. No draft,
intent, journal, admission, or uncertainty barrier is relaxed.

The restored-status implementation keeps exact ChatRecord equality guards.
Activity is observed only for loaded actors, which the read-only status scanner
already excludes; ordinary activity therefore does not trigger unloaded-history
scans. No status hydration produces semantic activity.

## Evidence boundaries

Pure state and fake-platform tests live in `sidebar_activity_tests.rs`. They cover
max-only acknowledgment, pending-registration races, stale observer identities,
bounded failures/fences, held-key overlap, explicit organization changes, initial
subscription delivery, fresh/unknown pointer evidence, and shared keyboard/render
order. The shutdown suite covers post-stop watermark capture, and the connection
suite injects late activity during actual retire/reopen failure and retry.

Linux full App validation passed 685 tests with three preexisting native-only
ignores after the final geometry and connection race tests. Strict App
all-targets/all-features clippy and workspace formatting passed. Final source
hashes, run logs, and negative-control evidence are maintained with the
coordinator's release evidence. This is synthetic/fake-platform validation;
macOS compilation, native menu/pointer/focus/IME acceptance, and interactive
loopback/restart acceptance remain distinct gates.
