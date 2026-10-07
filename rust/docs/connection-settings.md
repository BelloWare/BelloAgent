# Fixture Connections Settings and per-chat runtime binding

This is a usable, explicitly synthetic Connections workflow, not production
credential management or full Swift Settings parity. The nondefault
`synthetic-authority` feature plus `--synthetic-connections` (or the existing
`--synthetic-project-authority` debug flag) shares one in-memory authority envelope
between Projects and Connections. Normal builds expose an unavailable Settings
state. No signed native adapter, real key, Keychain access, credential discovery,
paid provider, production tool, or source-vault migration is enabled.

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

## Catalog, authority and lifecycle invariants

Catalog v6 stores an explicit nullable `connection_id` for every row. Valid saved
IDs are UUIDs. v1–5 read without byte rewriting or invented connection identity;
actual writes promote to v6. v5 retains its strict required tool mode. Old versions
cannot smuggle the new field, malformed/future metadata fails before confirmation,
and stale draft/sidebar writes cannot overwrite the newer connection binding.

Connections patch the existing authority envelope, preserving unrelated project,
preference, profile and opaque raw fields. Same-revision different bytes conflict.
Save failures preserve form baselines; an uncertain native-style write never
silently advances them or retries. Unsupported records remain retained and
unavailable. Public profile metadata has no key/header values or credential-bearing
URL; draft/event Debug output redacts typed secret fields and URL.

Synthetic connection confirmation is read outside actor locks; opaque configuration
identity and worker epoch are then rechecked inside admission. This closes delayed
active-to-idle and out-of-order configure races. The active worker owns one frozen
configuration across its request/tool continuation boundary. Existing immutable
synthetic resource constructors cannot be reconfigured with ordinary CLI credentials.
Strict project-runtime confirmation remains unchanged. Settings connections do not
activate tools or the synthetic resource runtime.

## Explicit gaps and bounded differences

This preview excludes other Settings sections, model catalog discovery, mini models,
advanced routing/reasoning controls, imported/legacy Messages conversion, connection
probe chats, multi-project/sides/background connection switching, native secure
fields, signing and production vault composition.

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

The pinned shared editor limits editable text to 8 MiB per field and roughly
16 MiB Undo history per editor; it exposes no per-field byte-limit setter. Core
save limits are much smaller (for example 16 KiB key, 256 KiB header JSON and
2 MiB vault), but editable draft memory is bounded coarsely, not to those source
field limits. Active-field cloning and retained per-tab editors are additional
memory. No total-memory bound or performance-parity claim is made. Oversized
input remains available for correction rather than being silently truncated.

## Validation

The checkpoint requires default and synthetic core/app tests, strict Clippy,
formatting, independent review, actual Linux interaction and exact-commit Linux
and Apple CI. Fake-platform GPUI typing/marked-text tests do not establish native
macOS IME, focus, accessibility or Keychain acceptance. Validation results are
recorded separately once the final candidate is frozen and exercised.
