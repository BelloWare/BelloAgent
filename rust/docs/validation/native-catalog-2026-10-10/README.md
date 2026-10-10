# Native-authority model catalog — 2026-10-10

Worktree `/Users/admin/projects/pi-app-rust-catalog`, branch `rust-catalog`
(based on `rust` at `94664143`). Commits: `b2ed6b20` (core catalog transport,
authority-local cache, model input resolution), `f5c21a15` (unreviewed Codex
work in progress: native Settings catalog controls and tests), then a review
commit that corrects and completes them (passive chat listing, freshness,
Swift's per-chat model rules) and replaces the earlier logs, two commits
addressing the Codex reviews (see below), and a merge of `origin/rust`
(`c4bfc55f`, automatic compaction and transcript work rows) on which the
final gate ran.

Swift source read only, at `6319e368` (0.1.122):
`Workspaces/ModelCatalogEndpoint.swift`, `ModelCatalog.swift`,
`WorkspaceCatalogSources.swift`, `ConnectionSettingsController.swift`,
`ModelSwitchControls.swift`, `WorkspaceConnectionSwitch.swift`,
`Composer/Attachments.swift`, `GatewayModelDiscovery.swift` and
`catalogs/bello-agent.models.json`.

No Keychain calls, GUI launches, real credentials or real provider/catalog
endpoints were used. Native provenance in core tests uses the core's private
in-memory vault storage; app tests use GPUI's fake platform. Every HTTP server
binds `127.0.0.1` on an ephemeral port, and every key and header is fake.

## What matches Swift

**Which URL.** A blank catalog URL means the bundled catalog (byte-identical to
Swift's, SHA-256 `f925021201808c8d305e1490c96d555a52ab140743880ddc1a35b3dde2097419`),
read with no key and no request. A custom URL replaces it entirely: no
`/models` discovery and no fallback when it fails. URLs are HTTPS or HTTP to
exactly `localhost`, `127.0.0.1` or `::1`, without userinfo, fragment,
whitespace or control characters. A route lists through its recorded catalog
source (`catalogSources`), never through a guessed similar connection, and the
source never becomes the dispatch route.

**Which credential.** The gateway key goes only to a catalog on the gateway's
own origin (scheme, host and effective port). In Settings: a valid typed key,
else the saved key by ID (an invalid typed key falls back, as Swift's
`listModels(forDraft:)` does); an unchanged saved connection lists through its
source with the source's key. A chat's listing reads the source's saved key from
the vault only when it lists. Other catalogs are anonymous. The GET carries only
`Accept: application/json`, `Cache-Control: no-cache` and the optional bearer:
no provider headers, cookies or redirects.

**When.** Save sends nothing. Settings Choose model lists (reusing a five-minute
fresh list, a failure for thirty seconds) and Refresh always lists, as Swift's
picker does. A shown native chat lists its source when it appears, as Swift's
model pill does (`ModelSwitchPills.refresh` → `listModels(for:)`): when a new
runtime or configuration is installed for it, and when the saved connections
changed since that chat last resolved its source (each chat records the saved
revision it resolved at; it then resolves the source from the vault again, so a
chat following another connection's catalog picks up that connection's new URL
or key, as `catalogProfile(for:)` does, even if it was hidden at the time); only for a custom URL, only when the
shared list is not fresh or past its failure retry, and joining a listing
already in flight. Switching chats never cancels a listing (Swift's fetch
outlives the pill's task). An unforced Settings Choose model shows a list a
chat or another form fetched within five minutes, or a failure within thirty
seconds beside the last good list, and joins a listing in flight instead of
superseding it; Refresh always fetches. Settings prepares a listing (a vault
read) off the UI thread. A failed refresh, including an idle or total
timeout, keeps the last good list and starts the failure retry window. Lists are shared within one authority, keyed
by the source's API, base URL, catalog URL and (same-origin only) a key
fingerprint, so Settings and chats see one list and a changed URL or key lists
anew; older listings are generation-fenced.

**Model input and limits.** A native chat's model is its own choice or the
connection's (`modelInput(for:)`). Its input is the declared input plus the
catalog descriptor's input for that model, ordered text, image; either listing
`image` enables attachment, request images and admission, and the composer
re-reads it when a listing lands. As in `applyModelChoice`, only a chosen model
(one other than the connection's own, which every send records) takes the descriptor's context/output limits (when it has any) and an effort it
offers (else `default`); the connection's own model keeps the limits and
reasoning saved with it. Choosing a model in Settings applies context, output
ceiling with budget clamping and compatible reasoning (`applying(to:)`), and
leaves the declared input alone in native mode.

**Fixture provenance.** Unchanged: numeric loopback URLs, the synthetic key and
header only; fixture chats never list passively and keep declared input. A
native UI over fixture storage gets the same restrictions.

## Tests

Core (`native_catalog_tests.rs`, `model_catalog_tests.rs`,
`connection_catalog_tests.rs`): offline Save; exact GET path, bearer and
headers; anonymous public catalogs; custom failure never falling back to the
bundled list; inherited source key and route; invalid typed key fallback;
bundled/declared input; model override limits and effort; cache generation,
key and authority fencing; freshness, failure retry and in-flight joining;
passive chat listing (one GET, shared by a second chat, none for bundled,
revoked or fixture chats, none after the URL changed); and on macOS an
image-only submission whose fake provider request contains `input_image`.
App: native catalog controls, browse/refresh/choose/save, preparation failure,
cancellation, and no passive listing for fixture-provenance chats.

## Gate

Supplied `env.sh`, shared `CARGO_TARGET_DIR`, `CARGO_PROFILE_DEV_DEBUG=0`,
`CARGO_PROFILE_TEST_DEBUG=0`, `CARGO_INCREMENTAL=0`. Each command's output and
exit status is in the adjacent `*.log` file:

```sh
cargo fmt --all -- --check                                    # fmt.log
cargo clippy --locked -p bello-agent-core --all-targets --all-features -- -D warnings          # core-clippy.log
cargo clippy --locked -p bello-agent-app --all-targets -- -D warnings                          # app-clippy-default.log
cargo clippy --locked -p bello-agent-app --all-targets --features synthetic-authority -- -D warnings   # app-clippy-synthetic.log
cargo clippy --locked -p bello-agent-app --all-targets --features native-authority -- -D warnings      # app-clippy-native.log
cargo clippy --locked -p bello-agent-app --all-targets --features native-authority,synthetic-authority -- -D warnings  # app-clippy-both.log
cargo test --locked -p bello-agent-core --all-features         # core-tests.log
cargo test --locked -p bello-agent-app --features synthetic-authority   # app-tests-synthetic.log
cargo test --locked -p bello-agent-app --features native-authority      # app-tests-native.log
```

## Remaining differences

- No chat model picker: no per-chat model or effort choice, so no explicit
  per-chat Refresh, utility-model choice or catalog-repair UI. Settings Refresh
  is the explicit refresh; the core applies Swift's per-chat model rules for
  when a picker exists.
- Swift drops a profile's list whenever its saved record changes; Rust keys the
  list by source URL, origin and key, so editing other fields (a model alias,
  limits) keeps a fresh list instead of listing again.
- Swift lists for the one chat its pill shows whenever its source record
  changes; Rust lists for the shown chat when its runtime, configuration or the
  saved connections' revision changes, still bounded by the shared freshness
  window. A chat-level per-send model equal to the connection's own is treated
  as no choice (Rust records the model on every send).
- Errors are Rust's sanitized ones without Swift's HTTP status and parser
  detail. The transport disables system proxies (Swift's URLSession uses them).
- No interactive run against a real catalog or provider.

## Codex reviews (gpt-6.1-sol, xhigh, read-only)

Round 1, six findings, all valid and fixed: sends record the connection's model, so it
was taken for a model choice and replaced saved limits/reasoning; a saved
URL/key change reconfigures the same controller, which the pointer check missed;
switching chats on one source cancelled the shared in-flight listing and left
the new chat unlisted; followers kept their old source after it changed;
unforced Settings Browse refetched despite a fresh shared list; and a total
timeout skipped the failure bookkeeping. Each has a test except the two app
scheduling fixes, which are covered by the core behavior they call.

Round 2, five findings, all valid and fixed: the window-wide revision check
missed a follower whose source changed while it was hidden (now per chat);
unforced Settings Browse superseded a chat's in-flight listing and ignored a
shared recent failure (now joins and honors it); the composer was not notified
after a resolve that needed no fetch; and Settings preparation read the vault
on the UI thread (now on the background executor). Core tests cover per-chat
resync, joining and shared failure; the app tests exercise background
preparation through the existing Settings catalog workflows. While merging,
`validate_prepared_request` was also moved to the effective profile, so its
size check sees the same input kinds as dispatch.
