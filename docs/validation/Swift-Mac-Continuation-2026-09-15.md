# Native Swift macOS continuation evidence

Base: `da6028153bea8d0b94a4b9a5bbae11158a64030d`, branch `master`.
Environment: macOS 14.8 arm64, Xcode 16.1 (16B40), Swift 6.0.2, XcodeGen 2.44.1.
All scratch/build products use the remote session temporary directory's
`native-master` subdirectory. No real gateway requests, notarization or feed
publication occurred in the baseline pass.

## Step A — integration baseline

- `swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests"`:
  22 XCTest cases pass. `baseline-core.log`.
- `python3 scripts/test-native-host.py HELPER`: eight cases each against Debug
  and `-Osize` Release helpers pass, including real loopback Responses/Messages,
  tool cycles, cancellation/queue pausing, MCP stdio/HTTP and side keep/resume.
  `baseline-executable-debug.log`, `baseline-executable-release.log`.
- `PI_BUILD_ROOT=... python3 scripts/build-bundle.py`: first failed because
  `lipo -verify_arch` consumed the filename as another architecture. Corrected
  ordering passes. Staged arm64 helper: 1.29 MiB, no Node/node_modules.
  `baseline-bundle.log`, `baseline-bundle-fixed.log`.
- `xcodegen generate`; `PI_BUILD_ROOT=... xcodebuild test -project PiApp.xcodeproj
  -scheme PiApp -configuration Debug -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$PI_BUILD_ROOT/xcode" CODE_SIGNING_ALLOWED=NO`: first failed
  typechecking ResourceInspector's combined instruction view. Split summary
  formatting and the source row into bounded view expressions. All 34 native
  tests then pass, with strict Swift concurrency and warnings-as-errors.
  `baseline-macos.log`, `baseline-macos-fixed.log`.
- The supervisor integration regression starts the actual bundled Swift helper,
  verifies engine/version/protocol/no-Node and waits for EOF shutdown; the old
  V8 heap assertions are retired, not dropped without a replacement.
- `python3 scripts/smoke-native-bundle.py APP`: arm64 architecture, manifest,
  workspace/MCP protocol and EOF checks pass. `baseline-packaged-smoke.json`.
- `scripts/with-runtime.sh npm run typecheck`: strict TypeScript passes for the
  retained transcript/protocol and reference source. `baseline-typescript.log`.

This is build/unit/executable evidence, not a completed signed Mac product.
F13–F17 and the remaining handoff acceptance matrix are still required.

## Step B — one vault and LiteLLM configuration

Implemented schema/revision/CAS updates in one native-owned Keychain item,
LiteLLM-only settings, direct scoped MCP configuration, explicit child env,
resource/runtime/capture/dashboard/update preferences and no external credential
fallback. Old user files/history/config are preserved. A header injection
regression exposed Swift Character matching's CRLF grapheme behavior; validation
now checks bytes. Failed workspace configuration no longer partially binds a host.

- Core: 25 XCTest cases pass (`vault-final-core.log`).
- Native app: 40 XCTest cases pass (`vault-final-macos.log`). These use explicit
  injected test storage and do not prove production Keychain access.
- Synthetic provisioning profile authorization/expiry regression passes:
  `python3 -B scripts/test-provisioning.py` (one case, five rejection subcases).
- Early legacy login-Keychain signed experiment: owner and authorized update
  access passed; other same-team read was denied but raw update succeeded.
  Restricting every ACL did not fix write isolation. Logs:
  `keychain-identity-fixed.log`, `keychain-identity-restrict-writes.log`.
  This was a **failed isolation experiment**, not a passing security gate.
- Production backend therefore uses a Data Protection Keychain access group,
  with a strict Developer ID requirement for the native owner and an embedded
  authorized profile required by signing scripts. No legacy backend is retained.
  [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
  describes the different access-control systems; [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
  describes entitlement authorization and embedded profiles.
- Final signed Data Protection test **not run**: installed profiles authorize
  BelloWall bundle IDs only. `scripts/test-keychain-identity.py --profile ...`
  is ready for a PiApp Developer ID profile; do not substitute BelloWall's.

No real LiteLLM request, notarization or release publication occurred. The new
public LiteLLM [Messages documentation](https://docs.litellm.ai/docs/anthropic_unified)
documents proxy support and API-key use, but is not evidence for the user's
deployed gateway version. Deployment/version/aliases remain requested inputs.

## Step C — shared payloads and private capture delivery

- Six `PayloadArchiveTests` pass: arbitrary packet splits/shifted prefix/one-byte
  edits, encrypted sharing and exact export/restart, crash prefix/corruption/key
  protection, quota and injected disk-full, session privacy/separate retention,
  quota eviction and cancelled-prefix completeness.
- Added a true packaged integration test: the native supervisor starts the
  optimized bundled Swift helper, both Responses and Messages execute a read-tool
  round trip through loopback HTTP, the native actor retains the original bytes,
  every visible user/assistant/tool message has a request link, and reopened
  archive bytes match the fixture server's observed request and response bytes.
- `capture-final-core.log`: 25 core tests pass. `capture-executable-fixed.log`:
  ten executable cases pass, adding both-API durable byte delivery/compaction and
  recorder rejection without failing or repeating tool work.
- `capture-integration-macos-final.log`: **47 native cases pass**, including the
  packaged test above; strict Swift concurrency and warnings-as-errors remain on.
  An initial test-harness port read waited for more bytes; using `availableData`
  fixed the harness. The interrupted failed run is retained separately and is
  not passing product evidence. Xcode 16.1's non-Sendable CryptoKit key annotation
  was handled with immutable Data and local CryptoKit values, not relaxed checks.
- `capture-bundle.log`: optimized arm64 helper 1.31 MiB, no bundled Node.
  `capture-typescript.log`: strict transcript/protocol TypeScript passes.
- Replaced the old polling path (which expected obsolete Pi trace field names)
  with one acknowledged capture packet at a time per helper, at most 32 KiB of
  original body bytes. Recorder failure does not replay agent/tool work.

This does not yet prove live GUI operation, final metric-expiry/reader-race
semantics, signed Keychain access, real gateway routing or a release DMG.

### Capture retention, reader races and SSE indices

Core 25 and executable 10 cases pass (`capture-retention-core.log`,
`capture-retention-executable.log` in session scratch). Native XCTest: 49 pass,
zero failures (`capture-retention-macos-realpath.log`). The first native runs
failed opening SQLite: NOFOLLOW rejects macOS's /var ancestor alias, and
Foundation's resolvingSymlinksInPath normalizes /private/var back to /var.
Using POSIX realpath for the validated parent preserves NOFOLLOW on the database
leaf; errors now report the SQLite operation/code without SQL or bound data.

New tests cover export/deletion interleaving on shared chunks, metric expiry
preserving message relationship tombstones, and event-index paging/duplicate
rejection/expiry. Both API executable fixtures verify SSE index offsets against
actual response bytes. The full Mac run still uses the prior optimized helper;
a fresh packaged event-index test is required with the next staged helper build.
No signed identity, live gateway or GUI acceptance is implied.

### Independent timing boundaries

26 core XCTest and 11 executable cases pass (`timing-final2-core.log`,
`timing-final2-executable.log`). Both API fixtures delay between a ping and content,
and between the model terminal event and HTTP EOF. Tests assert distinct times,
null missing terminal/TTFT on errors, nonstreaming timing, and cancellation with
an observed URLSession completion. Native archive completion uses HTTP EOF plus
observed byte counts, not model success. URLSession callback totals reveal unread
queued bytes after parse failure as a partial capture, never a complete body.

The optimized helper built successfully at 1.35 MiB before the final timing-version
marker/count addition. The next integrated rebuild must include that addition.
OpenAI's [streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses)
was fetched/read for response.completed lifecycle semantics. Deterministic gateway
fixtures, not an unverified deployed proxy contract, are the current evidence.

### Durable native dashboard

Xcode 16.1 / Swift 6.0.2 / macOS 14.8 arm64: all five `DashboardTests` pass
(0.416 seconds, `dashboard-tests-2.log`). The first attempt captured an unrelated
in-progress SwiftUI property-wrapper declaration; the corrected tree passes.
All app/test sources compiled with warnings treated as errors. The existing
eight `PayloadArchiveTests` also pass after the schema-3 migration changes
(0.891 seconds, `dashboard-storage-regression.log`).

The dashboard tests exercise a 101-value distribution with a large outlier,
exact global and per-bucket nearest-rank p50/p99, explicit zeros versus nulls,
failure/cancellation/in-flight/truncated counters and selected latency scopes,
every exact filter, dispatch wall time, unknown model evidence, SQL-like input,
128-row paging, schema migration, restart/interruption, body purge, metric expiry
and durable message-link tombstones. These are synthetic native archive tests,
not a claim of GUI interaction or a paid/deployed LiteLLM request.

Reproduce with the ordinary native app test command in `Swift-Test-Handoff.md`
and `-only-testing:PiAppTests/DashboardTests` (or `/PayloadArchiveTests`). Scratch
DerivedData for these checks is the session's `native-master/dashboard-xcode`;
logs remain in session scratch. No production Keychain item was accessed.

A sixth regression found and fixed a retention-order dependency: metrics could
not previously expire while body references remained. `dashboard-retention-final.log`
now passes all six dashboard cases and all eight storage cases (14 total,
1.322 seconds). The new case chooses a shorter metric TTL, verifies excluded
metrics plus an explicit tombstone, and still reads/exports the original body
bytes until the separate body TTL. Saving dashboard filters preserves the
current metric retention preference.

Final dashboard review adds schema-4 typed identity status and a seventh
regression. Conflicting and incomplete evidence remain distinct from unreported
identity after schema-3 migration; the “No resolved model” filter includes all
three without inventing an effective model. `dashboard-identity-final.log` passes
all seven dashboard and eight storage cases (15 total, 1.373 seconds). Inspector
message-link paging uses link counts, and partial-body wording no longer equates
model success with HTTP completeness.

### Initial native version integration

Functional source integration: 38 core XCTest pass (including seven additional
restart/side/skills/tool-state cases and five routing cases). The optimized native
helper passes all 13 provider/capture executable cases plus two real-process/MCP
acceptance cases (`initial-final-optimized.log`,
`initial-final-optimized-acceptance.log`). Full Xcode test run passes 60 registered
cases: 59 executed successfully, one opt-in interactive harness skipped in the
regular run (`initial-cut-macos.log`). The interactive harness separately passed
three actual CUA sessions; see [UI evidence](Native-UI-Acceptance-2026-09-15.md).

The final fixture UI verifies completed tool cards after helper restart. Root
review also fixed workspace-scoped request lookup for parent messages inherited
by a side: parent-origin and side-context attempts appear together, unrelated
workspaces remain excluded, and exports use the actual selected request owner.
All nine storage cases pass; this regression is included in the full Mac run.

TypeScript passes (`initial-typescript.log`). Eleven local release/update/signature
script tests pass (`initial-release-tests.log`), plus the provisioning validator
synthetic test (`initial-provisioning.log`). Unsigned Release build and packaged
Swift handshake/EOF smoke pass (`initial-cut-release.log`,
`initial-cut-smoke.json`). The final stripped arm64 helper is 1,488,432 bytes
(1.42 MiB), with no shipped Node or node_modules.

Signed isolation remains blocked by the missing profile for
43TXHV3TM3.com.belloware.PiApp. Read-only Xcode account availability found zero
configured developer accounts. No private key was exported or portal state
changed. Apple's [Mac distribution signing documentation](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
requires a distribution profile for keychain-access-groups; using a development
or BelloWall profile is not an accepted substitute. Actual LiteLLM endpoint/
version/aliases and paid-call authorization remain missing. No production
notarization, release upload or Sparkle feed change was performed.

### Unsigned distribution size — initial source cut 692b591

The complete Release app from `initial-cut-release.log` was copied with `ditto`
into a scratch DMG source directory, alongside the Applications symlink.
`hdiutil create -fs APFS -format ULFO` produced a **3,011,806-byte (2.87 MiB)**
unsigned validation DMG. `hdiutil verify` passes. App logical file bytes excluding
symlinks: 9,374,410 (8.94 MiB). The Release bundle has no XCTest bundle, Node
executable or node_modules tree.

SHA-256: `e046df82ab20e5b9b5a193d92d7af49641f630197d0d66106863f109079b97f0`.
Scratch artifact: `$PI_BUILD_ROOT/PiApp-native-unsigned-validation.dmg`; creation
and verification logs are `initial-dmg.log` / `initial-dmg-verify.log`. This is a
local unsigned engineering measurement, not the complete signed/notarized DMG
gate or a published download. It was not placed in the session outbox; the normal
app correctly cannot open its production vault until its provisioning/signing
requirements are met. The final synthetic UI preview alone was copied to outbox.

Remaining acceptance work is explicit: release-signed Data Protection read/write
isolation and authorized app-update behavior with a Pi App distribution profile;
authorized deployed LiteLLM routing for both APIs; language IME/global-menu and
maximum-scale UI/process-tree measurements; then signed DMG validation. The
existing fixture/code coverage must not be relabeled as those unrun gates.
