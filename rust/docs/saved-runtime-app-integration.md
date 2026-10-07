# Saved settings → trusted project → chat app integration

Source specification: `WorkspaceHosts.swift`, `WorkspaceFolders.swift`,
`WorkspaceConnectionSwitch.swift`, `WorkspaceChatLifecycle.swift`, and
`WorkspaceConfiguration.swift`. This is a bounded native-app integration, not
full Swift parity or native macOS signing/Keychain acceptance.

## One composition route

`AppRuntime` is the app adapter around core `SavedRuntimeFactory`. Main startup,
New Chat, unloaded selection, project folder replacement, confirmed read-only →
editing transition, and explicit connection switching use this route. The app
keeps the explicitly supplied legacy CLI configuration separate. A saved
connection ID never borrows it or another connection when its own route is missing.

The ordinary launch still uses unavailable native authority and enables no native
production tools. The existing debug-only `--synthetic-connections` /
`--synthetic-project-authority` flags inject an in-memory fake vault into the same
factory. They require the fixed fake credential and numeric loopback transport;
no real credentials, native Keychain, signing prompts, or paid providers are used.
The current Linux fixture offers real `ls`; the native capability set is explicit.
The explicit fixture project is also the fixture's `~` resolution home in startup
and every later runtime. This is not a filesystem sandbox or process-home discovery.

## Identity and lifecycle

- Catalog v7 distinguishes `pending` from `checkpoint-required`. Missing files
  never prove that a previously saved chat is pending. Legacy versions are decoded
  conservatively by core.
- Registered records are checked against their exact ID, snapshot path, saved
  connection and mode. Expected session ID is checked before recovery or migration.
- An unloaded UI placeholder has no configuration. Opening a replacement retires
  and joins its predecessor before obtaining another same-path writer.
- A fresh unregistered legacy placeholder changes to the workspace-derived path
  when an explicit saved connection is selected. Its session ID and composer
  entity stay the same; no history exists to move. Registered Pending drafts keep
  their catalog-bound path.
- Preflight checks project trust and the selected connection before a connection
  switch fences the current actor. Full confirmation is repeated after retirement
  and durable metadata publication. Choosing a connection does not submit a turn.
- Project changes keep the existing save → confirm/bind → retire/join → reopen →
  final confirmation ordering. An unloaded Pending draft has no idle writer lease;
  the change fails closed with an instruction to open that chat first, rather than
  creating an empty checkpoint as supposed idle evidence.
- Pending replacement authority uses immutable `is_never_materialized` provenance.
  Releasing a persistent writer lock cannot convert it into a new pending actor.
- Missing/deleted connections can leave an explicitly unconfigured, expected-ID
  history actor for inspecting and removing queued input. Send, Retry, Resume and
  Compact are visibly unavailable. Saved disconnected submissions are refused
  before receipt or checkpoint creation. Legacy CLI rejection/recovery semantics
  remain covered separately.
- Same-route settings saves use the actor's configuration handoff: entered workers
  retain their settings, later runs receive the confirmed replacement. No Settings
  Save, trust confirmation or connection selection itself sends a provider request.

## First-send interrupted recovery

The first submission's receipt durably changes Pending to CheckpointRequired
before materialization. If interruption occurs between those steps, the loader
must not create an empty replacement checkpoint. The recovery card can still
insert the complete retained intent into the draft, via a catalog-only transaction,
while loading remains failed and provider admission stays disabled. The test uses
more than 1 KiB of Unicode input to ensure recovery is not limited to the card's
short preview.

## Tests and reproducible cloud UI fixture

The integrated app suite passed **457 tests / 3 ignored** with synthetic authority,
and **394 tests / 1 ignored** in the default build. Strict app all-target Clippy
passed in both configurations, and workspace formatting passed. Ignored native
acceptance tests remain unexecuted. Added controller regressions cover:

- Settings Save → rejected untrusted selection → actual Projects trust UI → same
  pending chat and retained composer → configured runtime, with no request
- Composer → saved factory → actual `ls` execution → durable tool result → real
  loopback continuation (not a hand-built tool-card fixture)
- Required missing checkpoint: inert placeholder, retained draft, no replacement
  checkpoint or lock, and no dispatch
- Interrupted first-send receipt: complete draft recovery without empty history
- Previously materialized actor: retirement cannot authorize forged Pending
- Existing route-fork, same-connection saved draft, deletion, active stream Stop,
  queued-history cleanup, stale callback and uncertainty coverage remains active

`rust/fixtures/saved_runtime_gateway.py --port 47871 --log /absolute/log.jsonl`
provides a no-cost manual UI server. It records sanitized model/tool/route facts
and booleans about the known fake credential/header, never credential bytes.
`list fixture` requests actual `ls`; `stall fixture` holds a partial SSE response
for Stop/deletion tests. It is a test server, not a model or production gateway.

Actual desktop acceptance must use an immutable copied binary plus a source/binary
hash manifest and preserve the original screenshots. GPUI tests and type checks
alone do not establish native desktop or macOS acceptance. The separate native
signing/Keychain/real-credential gate remains disabled.

Actual cloud native UI acceptance is preserved in [the exact-candidate report](validation/saved-runtime-app-2026-10-07/README.md), including the original behavioral matrix and separately attributed final capability-presentation rerun.
