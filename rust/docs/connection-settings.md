# Connections Settings and per-chat runtime binding

The original checkpoint below implements the explicitly synthetic workflow.
The [2026-10-08 native host](native-authority-host.md) additionally composes these
same forms and transactions with the separate signed Rust vault through an
explicit feature and launch flag. Native mode accepts ordinary validated
connection inputs, starts new endpoint/model fields empty, and labels its storage
truthfully. It does not enable model tools or establish native Keychain/input
acceptance or full Swift Settings parity. The nondefault
`synthetic-authority` feature plus `--synthetic-connections` (or the existing
`--synthetic-project-authority` debug flag) shares one in-memory authority envelope
between Projects and Connections. Normal launches expose an unavailable Settings
state. The synthetic path enables no signed native adapter, real key, Keychain
access, credential discovery, paid provider, production tool or source-vault migration.

## Source contract and supported workflow

The specification is the original Swift `ProfileSettings.swift`,
`ConnectionSettingsController.swift`, `SettingsConnectionForm.swift`,
`WorkspaceConfiguration.swift`, `WorkspaceConnectionSwitch.swift`,
`WorkspaceChatLifecycle.swift`, `ModelSwitchControls.swift`, `ConfigurationVault.swift`
and `Sessions.swift` / `SessionRun.swift`.

- Open Connections from the existing Settings button. Saved tabs precede new
  tabs; switching tabs retains each form and editor ownership. Save All captures
  edited tabs in a stable sequence, current tab last. Each tab is a separate
  whole-envelope CAS; successful earlier tabs remain saved when a later one fails.
  The failed tab and edits remain visible. An untouched new tab is not saved.
- Empty key/header replacement fields preserve saved values; `{}` clears headers.
  Saved key/header values are never displayed. This fixture accepts only
  `synthetic-project-fixture-only`, custom header values
  `synthetic-header-fixture-only`, and numeric loopback HTTP/HTTPS endpoints.
  It rejects real credentials, hostname routing, inherited proxies and redirects.
  Name/model/URL/budget inputs are validated before each tab's write.
- Changing API/endpoint/model forks a fresh connection ID and retains the old
  connection for its earlier chats. A model change clears its old catalog ceiling.
  Same-route saves keep ID, generate a revision, and apply to idle loaded actors;
  an active worker keeps its original complete configuration until settlement.
  The next worker applies the latest pending configuration. Save never sends.
- Cancel discards all form edits. Close and Reload ask before losing edits;
  Keep Editing retains them. Native workspace close captures local editor text
  instead of relying on a potentially delayed dirty notification. IME composition
  blocks the view's close/save/tab action until it settles. Saved outcomes remain
  owned by the workspace across presentation changes.
- The source-positioned Connection picker selects the current chat's saved route.
  New Chat uses the current explicit new-chat choice. A null-ID legacy chat uses
  only the immutable CLI configuration supplied at launch, never another chat's
  saved configuration. A missing saved ID opens disconnected; there is no fallback.
- Switching requires an idle eligible chat without queued work/held edits or
  overlapping load, organization, recovery or mode operation. It fences old
  admission, retires/joins, rereads the current catalog, persists only connection
  identity when registered, then opens the replacement. Pending chats remain
  unmaterialized. Composer entities and drafts survive. Old runtime Arcs stay dead.
  A committed binding stays authoritative if the new runtime cannot open; a retry
  cannot revive the old route. Publication patches connection fields only.
- Delete explicitly stops/joins affected loaded actors before removing the
  connection, then verifies absence. It opens disconnected viewers with retained
  history/paused queue and untouched composer entities. A definite rejected write
  also leaves safely disconnected viewers, allowing queue inspection/removal and
  explicit reselection of a still-saved connection. Unknown write/teardown outcomes
  remain blocked; Reload alone does not claim recovery.

## Catalog-assisted setup

In Fixture mode, the Connections form now has an optional custom catalog URL and an explicit
Choose model action. Blank uses the existing checked-in Bello catalog, embedded
from `catalogs/bello-agent.models.json`; a custom catalog replaces it completely.
Native manual forms, storage labels and async route/new-chat fences remain unchanged;
this catalog slice adds no Native-mode preparation or catalog controls.
Neither path falls back to a provider `/models` endpoint. Remote catalog access
remains a numeric-loopback, fake-credential fixture, behind the existing startup
and authority gates. This does not enable production networking or credentials.

Search spans names, aliases and descriptions. Results use bounded 40-row pages;
deprecated entries appear only when already selected. An unlisted alias remains
editable directly. Choose stages optional context capacity, the model output
ceiling and compatible reasoning metadata, clamping the existing reply budget
without increasing it. Same-alias metadata changes are dirty, survive final form
capture and participate in the existing whole-envelope Save CAS. Refresh never
adopts model metadata. Manual alias changes clear the prior model ceiling and
image-input declaration. Catalog image badges are descriptive; they do not grant
attachment capability.

Save retains existing model/route fork behavior. The saved connection picker and
New Chat consume those saved routes, and only explicit composer submission sends
a Responses request. The catalog URL and source lineage remain separate from
runtime dispatch configuration. See [catalog contracts](model-catalog-setup.md)
for origin, parser, cancellation, cache, metadata and validation boundaries.

## Catalog, authority and lifecycle invariants

Catalog v7 retains the explicit nullable `connection_id` introduced by v6 and
adds required Pending/CheckpointRequired materialization provenance. Valid saved
IDs are UUIDs. v1–6 read without byte rewriting; actual writes promote to v7. v5
retains its strict required tool mode, and old schemas cannot smuggle newer fields.
Stale draft/sidebar writes preserve newer connection and checkpoint bindings. See
[saved runtime and recovery contracts](saved-runtime-factory.md) for ambiguous
legacy missing checkpoints and the first-receipt-before-materialization ordering.

Connections patch the existing authority envelope, preserving unrelated project,
preference, profile and opaque raw fields. Same-revision different bytes conflict.
Save failures preserve form baselines; an uncertain native-style write never
silently advances them or retries. Unsupported records remain retained and
unavailable. Public profile metadata has no key/header values or credential-bearing
URL; draft/event Debug output redacts typed secret fields and URL.

Saved connection confirmation is read outside actor locks; opaque configuration
identity and worker epoch are then rechecked inside admission. This closes delayed
active-to-idle and out-of-order configure races. The active worker owns one frozen
configuration across its request/tool continuation boundary. Existing immutable
synthetic resource constructors cannot be reconfigured with ordinary CLI credentials.
The shared saved-runtime factory now composes a saved connection with freshly
confirmed project/catalog authority and explicit capabilities. Saving or selecting
alone still sends nothing. The debug fixture launch can run those capabilities
through the same factory; native startup remains gated. The separate synthetic
dynamic-resource constructor is unchanged.

## Explicit gaps and bounded differences

This preview excludes other Settings sections, mini models,
advanced routing/reasoning controls, imported/legacy Messages conversion, connection
probe chats, multi-project/sides/background connection switching, native secure
keyboard/IME/accessibility acceptance and signing. Native vault composition is
implemented only through the explicit host mode described above.
Key and header replacement entry is now masked by an isolated GPUI control; see
[secure input contracts](secure-connection-inputs.md).

To avoid overlapping writer/open ownership, this slice refuses save/delete while
an affected chat is loading/materializing or finishing an edit/catalog operation;
it gives a Wait explanation and retains edits. Full Swift late-open deletion
coordination remains a separate integration task. Active provider runs themselves
are supported by deferred configure and stop/join deletion.

Swift `WorkspaceConfiguration.deleteProfile` clears displayed queue rows, while
`Sessions.stop()` pauses durable queues and `HostService` can refuse unloading a
non-idle session. Rust shows its retained paused queue in a disconnected viewer
instead of hiding it. The confirmation/result explains inspection/removal before
choosing another connection. Nothing implicitly resumes or replays queued input.

Key and header replacement inputs have atomic 16 KiB / 256 KiB byte caps and no
Undo history. They never pass replacement text to shaping, platform surrounding-text
retrieval, Debug, Copy or Cut; only masks are rendered or returned. Paste keeps exact
bytes and over-limit input is rejected with a generic message. Select All + Delete
clears the replacement; a blank replacement still preserves saved credentials.
The input-owned buffers and local paste strings are zeroized on replacement/drop.
This is not complete memory erasure: coordinator forms/events and platform clipboard
copies are outside that buffer's lifetime. Synthetic mode rejects real credentials;
all automated native-mode acceptance also uses fake values. Actual native secure
keyboard/IME/accessibility and signed Keychain acceptance remain separate work.

Other fields still use the pinned shared editor's 8 MiB text / roughly 16 MiB Undo
caps. Retained per-tab entities, coordinator forms and event clones add memory. No
whole-Settings memory bound or performance-parity claim is made.

## Validation

The checkpoint requires default and synthetic core/app tests, strict Clippy,
formatting, independent review, actual Linux interaction and exact-commit Linux
and Apple CI. Fake-platform GPUI typing/marked-text tests do not establish native
macOS IME, focus, accessibility or Keychain acceptance. Validation results are
recorded separately once the final candidate is frozen and exercised.
