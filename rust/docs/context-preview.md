# Read-only request context preview

The Context footer and Session Inspector icon open a separate, read-only
Next request window for the current chat. It implements a bounded part of
SessionInspectorWindow.swift, InspectorNextRequestPage.swift and
WorkspaceContextPreview.swift: one window per owner/chat, manual Refresh,
selectable JSON pages, Copy request and Close. Source default size is 1120×820,
minimum 700×520. It does not implement the complete request archive, request
comparison, resource inspector, request capture or token counter.

## The prepared body

Controller preparation uses the same effective profile, tool definitions,
provider body builder and serialized wire limit as dispatch. It reads the
certain in-memory session without materializing or rewriting the journal,
starting a request, invoking a tool, reading resource files or accessing native
authority. Missing configuration and uncertain/retired state are explicit
failures. Instructions are the controller's existing literal text and tools are
its existing options; this checkpoint enables neither.
The separate synthetic-resource runtime is explicitly refused by this preview
API: its per-delivery snapshots cannot be represented by lifetime-fixed options,
and inspection does not perform new resource or authority reads.

An idle preview includes a nonempty draft exactly as entered. An active preview
uses the delivered turn's model/effort, excludes draft and pending input, and
uses the pre-tool-call boundary while tools are waiting. Paused/error inspection
previews the next idle input, not an implicit Retry. Retained partial responses
stay excluded by the ordinary history projection. Drafts are bounded to 256 KiB,
wire and pretty JSON independently to 32 MiB. Token count and occupancy remain
unavailable; configured context capacity/output settings are not token usage.

Known credentials and configured header values are fingerprinted in exposed
fields. Authorization-style headers include the token suffix under the source's
case-insensitive header and ASCII scheme rules. The preview is a redacted
prepared body, not a captured HTTP request; headers and credentials are not
shown. A weak controller owner prevents stale allocation identity reuse without
retaining its writer. Final semantic checks borrow authoritative actor state,
not a possibly older published snapshot, and do not clone history on UI checks.

## Window and input ownership

The window is bound to the original workspace, owner window, chat and controller.
Changing the selected chat does not retarget it. Loading/edit guards and captured
draft equality protect installation; partial streaming and undelivered queue
changes do not change the core request binding. A completed document remains an
explicitly labeled captured snapshot until Refresh or Close. Copy uses those
immutable bytes, including when later typing changes the next request. A newer
refresh, replaced owner/runtime or closed window rejects late callbacks/copies.

Each editor page contains at most 64 KiB on UTF-8 boundaries, with an explicit
byte/page indicator. Whole-body preparation and full Copy cloning run in the
background. Closing/rebinding/shutting down releases inspector content and
never changes the owner composer or restores focus over a newer target. Existing
read-only editor selection, scrolling and keyboard copy remain available.

The source's leading-command and selected-skill workflow is not ported. Rust
currently sends literal slash text, so this preview describes that actual
request rather than inventing a command classifier. Production resource
discovery remains separate work.

## Validation boundary

Focused core tests cover actual loopback dispatch equality, unchanged journal
bytes, active and waiting-tool projection, paused/error state, unavailable
configuration/counts, credential suffix redaction, stale state and weak lifetime.
The pure paging property test reconstructs every byte across Unicode pages.
GPUI regressions cover actual footer clicks, window reuse, original-chat
binding, IME/Undo, stale results/copies, bounded pages and teardown. Local GUI
compilation/execution is unavailable because cloud build prerequisites remain
blocked; exact CI and native interaction remain distinct validation gates.
