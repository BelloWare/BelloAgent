# Project MCP Inspector

Source behavior: `ResourceInspector.swift:315–479`,
`WorkspaceConfiguration.swift:334–432`, `ConfigurationVault.swift:320–349`,
`ConversationPane.swift:393`, and `WorkspaceSides.swift:622–648`.

## Current bounded surface

The sidebar MCP button opens a project-scoped modal Inspector. It displays the
saved project UUID and original path and uses `AppRuntime::mcp_manager()` from the
same saved-runtime factory as all chats. It never constructs a fixture-only host.
Native storage, credentials and production tools remain unavailable. The existing
explicit synthetic-authority launch uses a memory vault, numeric-loopback HTTP,
and fixed fake credentials. Only Streamable HTTP is supported; stdio is refused.

Configuration is JSON without headers. Each draft server has an isolated masked
header-replacement field backed by the already reviewed `SecureInput` entity.
Saved header values never enter UI metadata or an ordinary editor. Blank preserves
headers at the same endpoint; `{}` clears them. Moving to another endpoint requires
an explicit replacement or clearing. Input/result limits are checked by the core;
configuration and invocation input are additionally limited to 256 KiB. Output is
shown as selectable UTF-8-safe pages of at most 64 KiB.

Save captures immutable project/input identity, asks the user to trust that exact
configuration, and checks the whole project idle. The host acquires loaded actor
admission guards, unopened-chat writer/idle leases, and the manager's configuration
reservation before the whole-envelope vault CAS. Save precedes apply. Definite
pre-write failures release admission; uncertain writes and post-save failures keep
old actors fenced. RAII retains those fences if a post-save future is dropped.
Reload never clears uncertainty or automatically revives an old actor.

Server/tool listing and schema description do not invoke tools. One-shot invocation
captures one server, one tool, one arguments object and the exact selected Editing
controller, then asks for confirmation. Core admission independently checks that
saved Editing capability. No automatic retry occurs. Cancel waits for an honest,
durably settled result; a dispatched invocation may leave the project outcome
unknown. Acknowledgment requires a separate explicit question and the exact
unknown-marker fingerprint, and cannot clear active or uncheckpointed results.

Existing ordinary-chat Editing defaults and every explicit saved mode are preserved.
A genuine saved ReadOnly chat exposes the source-backed one-way Enable Editing
question. Confirmation calls the existing retire → persist mode → reopen
transaction. It preserves the composer entity/history and never itself invokes MCP.

## Lifecycle and draft handling

- Opening the Inspector reads saved configuration; it sends no discovery/invocation.
- All callbacks carry presentation revision and opening generation. The coordinator
  also verifies workspace pointer, original path, saved UUID and native binding.
- Confirmations own captured input/target identities, rather than later selection.
- Close with dirty configuration offers Keep Editing, Close and Keep Draft, or
  Discard and Close. Reopening retains ordinary and masked editor identities.
- Native window close cannot silently lose a retained unsaved MCP draft.
- Saving cannot be dismissed mid-write. Cancel/Close during Inspector-owned
  discovery or invocation requests cancellation and waits for settlement, without
  retrying. Work owned by another chat, mode transitions and atomic acknowledgments
  offer a truthful wait message, never a Cancel button without a matching token.
- Manager status/unknown state is project-wide, shared with model-driven MCP calls.
- Configuration changes preserve unresolved outcome history, including after server
  removal. A changed config never means an uncertain external effect was undone.

## Verification

Focused host/GPUI/controller tests cover real numeric-loopback discovery,
one-shot invocation, cancellation, exact unknown acknowledgment, retained-result
reload, external configuration reapplication, stale callbacks and catalog mutex
contention. The full suites and strict default/synthetic Clippy also run before
immutable GUI validation. Exact candidate hashes, test counts and manual outcomes
are recorded in `validation/mcp-2026-10-07/`; superseded candidates are explicitly
marked preliminary rather than relabeled as final acceptance.
The masked-input implementation itself is shared by visibility-only changes;
its existing platform-boundary and non-disclosure tests remain applicable.

Candidate 3 completed the broad actual Linux cloud GUI matrix; final candidate 4
passed the focused writer-lease invocation/continuation/reopen smoke. See
[`validation/mcp-2026-10-07/README.md`](validation/mcp-2026-10-07/README.md).
Headless GPUI tests and synthetic Linux GUI acceptance do not establish native macOS secure keyboard, IME, accessibility, signing,
Keychain acceptance, or production enablement. The synthetic vault is in-memory;
Inspector/chat reopen does not imply cross-process native-vault persistence.
