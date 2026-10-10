# Native-authority catalog validation — 2026-10-10

Worktree: `/Users/admin/projects/pi-app-rust-catalog`, branch `rust-catalog`,
starting at `946641438e6fe165a9b4d07619c560c733d2f403`. Core change:
`b2ed6b20` (native catalog transport/cache and model input resolution). The
Settings change and this evidence are committed separately. No push or history rewrite.
Swift source was read only at `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`
(0.1.122). No Keychain calls, GUI app launches, real credentials or remote
provider/catalog requests were used. GPUI tests use its fake platform; native
provenance uses the core's private in-memory storage seam. HTTP servers bind
`127.0.0.1` on ephemeral ports, and every key/header is fake.

## Swift behavior matched

Sources read: `Workspaces/ModelCatalogEndpoint.swift`, `ModelCatalog.swift`,
`ConnectionSettingsController.swift`, `WorkspaceCatalogSources.swift`,
`CatalogModelPickerView.swift`, `WorkspaceConnectionSwitch.swift`,
`Composer/Attachments.swift`, and `catalogs/bello-agent.models.json`.

- Blank catalog URL uses the bundled catalog without a key or network request.
  A custom catalog completely replaces it; there is no `/models` discovery or
  fallback on failure. The bundled file is identical to Swift (SHA-256
  `f925021201808c8d305e1490c96d555a52ab140743880ddc1a35b3dde2097419`).
  Its six models currently have **no `input` fields**; no image capability was
  invented for those entries.
- Settings Choose model / Refresh is available in native mode. Merely editing
  or saving does not issue a GET or a provider request. Opening the list reuses
  the existing five-minute cache, with a thirty-second failure retry; explicit
  Refresh bypasses freshness. Unchanged saved sources retain their recorded
  catalog lineage. Model/route similarity does not establish lineage.
- URLs are bounded HTTPS or explicit HTTP `localhost`, `127.0.0.1`, `::1`, with
  no userinfo, fragment, whitespace/control characters or invalid port.
  Noncanonical numeric loopback spellings are rejected for HTTP, as in Swift.
- Same-origin catalogs use the valid typed key or the saved source's key; invalid
  typed native keys fall back to the saved key by ID, as Swift draft listing
  does. Scheme, host and effective port must all match. Public catalogs are
  anonymous and preparation does not decode saved keys or provider headers.
  Inherited sources use their own key; they never become the dispatch route.
- GET has only catalog transport headers (`Accept: application/json`,
  `Cache-Control: no-cache`, optional bearer). No provider headers, cookies,
  redirects or proxy discovery. The shared transport retains byte/model limits,
  separate idle/total deadlines, cancellation and sanitized errors.
- Choosing a descriptor applies context, output ceiling/budget clamping and
  compatible reasoning. Native declared input remains a separate vault field.
  Runtime attachment admission, request dispatch, preview, context recovery and
  compaction use declared input union the effective model's catalog input.
  A model override resolves its own descriptor and limits; declared image
  support still applies across aliases, matching `modelInput(for:)`.
- The cache is shared only within one authority, bounded, and bound to URL,
  route origin/API and a credential fingerprint when needed. Older refresh
  publications are generation-fenced; a changed URL/key or another authority
  cannot use the old result. Same-source refresh failures retain descriptors.
  Catalog loading never saves the vault or starts a turn.
- Fixture storage still accepts only numeric loopback routes and the synthetic
  key/header constants. Even native UI mode with fixture storage cannot grant
  catalog-derived image capability or accept ordinary keys. Feature flags do
  not select production provenance.

## Evidence and gate

Environment: supplied `env.sh`, Rust 1.99.0, macOS, existing shared
`CARGO_TARGET_DIR`; `CARGO_PROFILE_DEV_DEBUG=0`, `CARGO_PROFILE_TEST_DEBUG=0`,
`CARGO_INCREMENTAL=0`. No new target directory was created. Shared build output
initially returned an older worktree's test binary. Each final build/test command
therefore touches this worktree's crate roots to force compilation; source
contents are unchanged by that step.

Focused tests cover native provenance with fake storage, exact requested path
and bearer, public/inherited sources, invalid typed-key fallback, offline Save,
refresh retention and source changes, bundled/declared input, model override
limits, cache generation/credential/authority fencing, and an actual native
macOS image-only submission whose fake provider request contains `input_image`.
App tests cover native catalog controls, browse/refresh/select/save, preparation
failure, cancellation and fixture provenance. Existing transport and vault
privacy/lifecycle tests remain in the gate.

Final gate results are recorded in the adjacent `*.log` files. Commands:

```sh
cargo fmt --all -- --check
cargo clippy --locked -p bello-agent-core --all-targets --all-features -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets --features synthetic-authority -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets --features native-authority -- -D warnings
cargo clippy --locked -p bello-agent-app --all-targets --features native-authority,synthetic-authority -- -D warnings
cargo test --locked -p bello-agent-core --all-features
cargo test --locked -p bello-agent-app --features synthetic-authority
cargo test --locked -p bello-agent-app --features native-authority
```

Results: pending completion of the final app gate. The core gate passed all
941 unit tests plus its integration and doc tests. Tests use
`RUST_TEST_THREADS=6` to bound concurrency on the shared build machine.
The default-parallelism core run passed the new catalog tests but missed the
existing bash background-pipe test's 2.4-second timing threshold; the complete
rerun passed. The first app run passed the native catalog workflow but failed
an incorrect new test expectation for a navigation button on the current page;
that assertion was corrected. A subsequent test looked for a debug selector
which the shared button helper does not install; it now checks the actual
measured control geometry instead. Initial logs are retained alongside the
final results.

## Remaining differences

Rust has the Settings catalog picker, not Swift's per-chat model picker, utility
model selection or catalog-repair UI. Custom descriptors are memory-only; after
relaunch a deliberate Settings Choose model / Refresh loads them again. Swift
also keeps descriptors in memory, but its chat picker performs lazy loading.
This change makes no production HTTP or interactive macOS acceptance claim.
The separate native signing/Keychain gate, project trust, permission policy,
credential replacement and runtime revocation remain in force. Existing
sanitized Rust errors omit Swift's HTTP status and parser reason details.
