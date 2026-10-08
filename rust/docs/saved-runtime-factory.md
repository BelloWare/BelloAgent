# Saved settings, project authority and chat runtime

The bounded vertical path uses `SavedRuntimeFactory` for saved-ID chats. The
factory consumes an explicitly supplied `ProjectAuthority`, the existing
workspace owner and explicit home/capability/static-instruction options. It
owns expected-ID checkpoint opening and Controller construction. It creates no
second host registry, credential cache, fallback route or automatic request.

This is production-capable composition code exercised through injected storage
and numeric loopback. It does **not** enable native app startup. Default and
all-feature app composition still use unavailable native authority unless the
existing debug fixture switch is selected. No signing, real Keychain read/write,
user credentials, permission prompt, Mac access or paid API call is part of this
checkpoint. The acceptance gates in `native-authority-contract.md` and
`packaging/macos/README.md` remain open. Synthetic Settings still accepts only the
fixed fake credential/header values and numeric loopback endpoints.

## Source contract

`WorkspaceConfiguration.swift:187–245` supplies save-before-configure,
blank-secret preservation, empty-object header clearing, route forks, and active
run configuration freezing. `WorkspaceHosts.swift:8–90,157–235` supplies saved
trusted roots, connection identity, cold open and late completion checks.
`WorkspaceConnectionSwitch.swift` supplies close/join before durable selection and
reopen. `WorkspaceFolders.swift` supplies save-before-host-restart. Swift's
`ChatRecord.path` is optional and `WorkspaceChatLifecycle.swift` separates pending
on-screen identity from durable chat metadata; Rust's former always-present path
did not carry the equivalent materialization evidence.

## Credentials and provenance

`ProjectAuthority` provenance is minted only by its explicit storage constructor.
Production validation uses the supported bounded `Profile`/credential contract;
it does not require the fake key or loopback endpoint. Fixture provenance adds
those restrictions and selects a no-proxy/no-redirect client. The fixture
constructor cannot be turned into a production route by editing stored bytes.
Unsupported profile/policy records remain opaque and unavailable. Neither runtime
nor Settings falls back from a missing saved ID to CLI credentials.

`SavedConnectionRuntime` holds the same opaque lease used by the fixture wrapper.
A same-route settings update supplies a fresh immutable `Configuration` to
`Controller::configure`. Entered work retains its original configuration; pending
settings apply at full worker settlement. Changing route creates a new saved ID.
The public saved-configuration constructor still cannot activate tools without
the crate-private trusted-project factory guard.

Vault mutations retain full optional-byte CAS and unknown raw fields. Runtime
project continuation instead performs one fresh read and validates exact saved
project identity, trust, roots, canonical primary path and supported policy.
Unrelated connection saves do not invalidate project authority merely by advancing
the envelope revision. Unknown project policy, changed roots/trust/ID, catalog
mode/connection/path changes, removal and uncertainty fail closed.

## Runtime admission and ownership

The always-built runtime authority guard is distinct from the older fixture-only
dynamic-resource workflow. Static factory instructions/tools are the actual
Controller options used by requests, Context inspection and manual compaction.
Dynamic fixture resources retain their explicit Context/compaction refusal.

Full vault/catalog/filesystem checks run outside actor and catalog mutexes, before
new delivery, provider continuation and tool batches. Mutation calls recheck after
pre-effect asynchronous admission. Actor admission uses only cheap
atomic validity checks. A guard's observed authority/catalog failure is sticky;
restoring trust cannot reactivate that old Controller. Compaction rechecks before
summary dispatch and again before durable checkpoint adoption. Configuration Arc
identity, pending settings, Stop, retirement and storage uncertainty remain gates.

Owners still fence, retire and join previous Controllers before replacement. The
factory never borrows an old writer. `Controller::is_never_materialized()` uses
checkpoint identity and uncertainty, not a live lock: retirement releasing a lock
cannot convert a persistent actor into an unsaved placeholder. Missing saved
connections may be presented as explicitly disconnected history for inspection;
that surface has no request configuration. Historical tool calls never execute on
open, and cancelled or uncertain effects retain their truthful outcome records.

## Catalog v7 and crash boundaries

Each v7 row requires an explicit `materialization` tag:

- `pending`: host-created identity with no checkpoint created yet
- `checkpoint-required`: a checkpoint is expected, including conservative legacy
  records whose origin was not represented

Factory new-chat creation derives a fresh UUID and managed snapshot path without
saving or sending. A registered pending draft can reopen without creating a
checkpoint. Any unexpected filesystem entry for a Pending row is refused before
recovery, including a same-ID checkpoint. A missing required checkpoint never
becomes an empty actor automatically.

Before the first checkpoint creation, `begin_submission` atomically retains the
existing exact-text submission receipt and advances the row to
CheckpointRequired. The guard requires that durable state and receipt, and binds
`materialize` to the exact recorded path. This ordering deliberately fails closed
if the process stops after the catalog commit but before checkpoint creation:
the draft/receipt remains recoverable, but reopening cannot infer that an empty
session would be safe. A still-live pending actor may explicitly retry its
failed materialization; an uncertain store cannot do so.

Before-rename catalog failures preserve the Pending row and draft. After-rename
uncertainty fences memory and later reopening reads the committed marker plus
receipt. Stale draft/register/pin/archive writes preserve the latest marker.

Catalog v1–6 reads remain byte-preserving. Their rows acquire a conservative
CheckpointRequired value only in memory; an actual later mutation promotes the
catalog to v7. An older registered draft with no checkpoint is therefore
ambiguous and opens disconnected with its saved text/error retained. It is not
automatically rewritten, recreated, replayed or recovered by guessing. The
bounded project-change UI may require an unloaded Pending chat to be opened
before changing project folders, so its live actor can supply the existing idle
admission fence rather than creating an empty checkpoint to obtain a lock.

## Validation scope

Focused tests exercise this same factory from fake storage through loopback
Responses requests, tool results and durable replay. They cover no-send
save/trust/new/pending reopen, active/deferred settings, connection deletion,
project policy/trust/root changes, mode/path mismatch, exact-ID open-before-
recovery safety, stale and uncertain catalog saves, queued mutation revocation
after pre-effect admission, and compaction dispatch/adoption revocation. Production
validator tests use ordinary-format test-only inputs with an injected memory
backend; they never invoke native storage or network endpoints.

These portable results do not establish native signing, Keychain behavior,
secure keyboard input/IME/accessibility, or macOS tool/UI acceptance.

### Frozen-source review and portable verification

The checkpoint's exact Rust source is anchored by all 148 Git blob IDs in
[the reviewed LOC ledger](validation/loc-saved-runtime-2026-10-07-delta.json),
manifest SHA-256
`41613e1af2cad79301c42a1bc60bbcb31d7c7732a621c4e60d4a38bcac9a4716`.
Publication metadata and GUI binary/source manifests are verified separately.

Independent read-only review required and verified these corrections before the
final test pass:

- Runtime project membership uses one fresh full-record check; a concurrent
  unrelated envelope save cannot create an artificial CAS conflict and revoke it.
- Pending origin is based on checkpoint identity/uncertainty, because retirement
  deliberately releases a live writer lock. A previously persistent actor cannot
  be recast as a new Pending identity after joining.
- Pending rows reject unexpected checkpoints, including same-ID history, before
  recovery. Missing required checkpoints retain exact draft/receipt text rather
  than becoming empty sessions.
- Context inspection retains its nonblocking busy-actor contract. It captures the
  original snapshot/configuration/worker epoch with `try_lock`, performs full
  authority checks outside locks, then checks both epoch and semantic input
  identity. A bounded one-second lock regression fails without hanging the test
  suite; a delayed active confirmation cannot cross settlement or a newer epoch.
- Tool dispatch rechecks saved connection/project state after a returned model
  call, and mutation admission rechecks again before concurrent native entry.
  Compaction confirms authority both before summary dispatch and before adoption.

Independent Linux verification before the final presentation-only helper:

- Core all features: **410 unit + 107 integration tests passed**
- Core default: **308 unit + 107 integration tests passed**
- Context inspection: **13 focused tests passed**
- Strict core all-target/all-feature Clippy passed
- Included **14 shared-factory**, **3 materialization fault/merge**, **2 production
  validator/membership**, and **8 existing configuration-race** unit tests
- Factory recovery specifically reopens a dangling historical write as Unknown,
  sends its retained no-automatic-replay result on explicit Retry, and proves no
  historical filesystem execution occurred

These counts include the tests named above; they are not additive suite totals.
The app/secure-input worker records UI suites and actual Linux interaction
acceptance separately. No macOS execution of this new checkpoint is inferred
from these Linux results.

The prior published baseline is `67b02843cdc353cfa6f5b760c4164a5af4b6da8c`, tree
`e736a261f92185d6925a07ac0bc4a7dfe5c3bd88`. Its exact
[Linux run](https://github.com/BelloWare/BelloAgent/actions/runs/37587116298) and
[macOS run](https://github.com/BelloWare/BelloAgent/actions/runs/37587116338) passed.
That macOS run includes native write/edit source/file-effects oracle and native
tool-to-fake-platform transcript workflow tests. It is baseline native test
coverage, not actual macOS GUI, signing or Keychain acceptance for this new slice.

### Final capability presentation correction

The starter badge uses the centralized app label helper and
`Controller::has_available_tool_definitions()`. It says Fixture tool runtime only
for an explicit fixture actor with actual implemented definitions, a saved
configuration and factory guard, no known revocation/retirement/admission fence,
and certain nonfatal actor state. The query uses only atomics, `try_lock` and
`try_read`; it never reads the vault, catalog or filesystem and does not grant
runtime admission. External authority changes become known through the normal
full-confirmation path. Default, legacy, disconnected and known-invalid actors
remain visibly unavailable.

Two focused core capability tests passed after this correction, including bounded
actor/configuration contention, no-vault-I/O proof, and absent/fatal/uncertain/
retired/known-deleted state. Strict all-target/all-feature core Clippy and default
core check also passed. The app owner rebuilds the final candidate and records the
scoped visual smoke after this label-only change.
