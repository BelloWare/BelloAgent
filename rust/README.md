# BelloAgent Rust / GPUI migration

An incremental native implementation alongside the unchanged Swift application.
This is **not feature parity** or a release replacement. Current status, release
blockers and same-Mac Swift/Rust measurements: [STATUS-2026-10-10](docs/STATUS-2026-10-10.md). The source-backed
[parity ledger](docs/parity.md) separates implemented, partial, and unported work.
Start with its [native connection checkpoint](docs/parity.md#native-saved-connections-2026-10-08)
and [readiness index](docs/parity.md#readiness-index-2026-10-07)
for ordinary startup gates, explicit workflows and scoped evidence;
older checkpoint records are not a current feature inventory.

## Build and test

Rust 1.89+ (tested with 1.89.0 and 1.99.0 on Linux), Cargo, and GPUI Linux build
dependencies are required. GPUI is pinned to 0.2.2; libc is pinned to 0.2.186 for its transitive
xattr compatibility. Both shared workbench crates are pinned to BelloBox Git
revision `393133cd19d134ffd93c3a86449d94a7b1040683`. This includes atomic CRLF
deletion, composed-character navigation, selection collapse and guarded IME
commit handling in the shared editor. Native IME/macOS interaction is not yet
validated. A standalone checkout needs no
sibling BelloBox directory; Cargo fetches that exact published revision.

```sh
cargo test -p bello-agent-core
cargo build -p bello-agent-app
cargo run -p bello-agent-app -- --project ../
```

On Apple Silicon macOS, select a complete Xcode installation and export
`MACOSX_DEPLOYMENT_TARGET=14.0` before these Cargo commands. Core builds compile
a small static Swift decoder with the selected Xcode SDK, preserving the original
Swift tool's UTF-8 behavior on the host runtime. Rust and Swift use the same
deployment target. Unsupported Darwin cross-builds fail explicitly; Linux builds
do not discover or invoke Swift. The adapter does not enable any native tool or
authority capability. See the [build contract and validation bundle](docs/validation/macos-utf8-bridge-2026-10-08.md).

The app opens an honest disconnected workspace until a connection is supplied.
It never discovers credentials in the shell, environment, or source app files.
The temporary Linux credential entry point is explicit stdin; it is kept only in
memory and is not a native vault integration. Ordinary launch keeps saved native
authority unavailable. The nondefault app `native-authority` feature plus explicit
`--native-authority` flag composes the separate macOS Rust vault with Connections,
project trust and saved provider chats. This mode offers no model tools, MCP or
project instruction/skill discovery. It requires the approved signed identity;
an unsigned development binary has no fallback. See the
[host contract](docs/native-authority-host.md) and
[native storage contract](docs/native-authority-contract.md). No source vault is
imported. Signed Keychain, native input and full Settings acceptance remain open.
Profile JSON must contain no key. Accepted fields
are validated and unknown fields rejected rather than silently ignored.

For a real endpoint, pass `--profile path/to/profile.json --credential-stdin`
using a secure stdin source of your choosing. Do not put real keys in arguments,
committed scripts, screenshots, or example files. The profile shape is shown in
`fixtures/profile.json`; replace the endpoint and model only when you intend to
send requests. The app never sends merely from opening a project.

## Local-only transport/UI test

```sh
python3 fixtures/gateway.py
# Separate terminal, fake credential only:
printf 'fixture-only' | cargo run -p bello-agent-app -- \
  --profile fixtures/profile.json --credential-stdin \
  --session /tmp/bello-agent-fixture/session.json --project ../
```

Type and send a message to exercise the real streaming client, transcript, local
snapshot, queue, Stop, Resume, and Retry. The fixture identifies itself in every
response; no AI service or billing is involved. Core automated tests run their
own random-port loopback servers and require no credentials or external services.

## Storage and safety

See [storage, privacy, and recovery boundaries](docs/storage-and-privacy.md) for
the source-backed comparison, exact durability contract, and backup guidance.

- Rust snapshots use a separate `BelloAgent-rust/sessions` directory. macOS uses
  Application Support; Linux uses XDG_DATA_HOME or `~/.local/share`.
- `--session FILE` anchors another **Rust workspace and initial snapshot**, never a Swift journal.
- Exclusive file locks prevent simultaneous writers. User-command checkpoints
  use private 0600 temporary files, fsync, atomic rename, then directory fsync.
- Streamed deltas use a separate generation-scoped JSONL journal, synchronized
  before publication and folded into later durable checkpoints. Both snapshots
  and journals contain plaintext conversation data, not encrypted storage.
- Every acknowledged session change is persisted. Interrupted output is retained
  but excluded from replay. Restarted in-flight work and pending queues pause.
- Queue edits hold both lanes; Save/Cancel/Remove are atomic and idempotent.
- HTTPS is required except loopback HTTP. Redirects are not followed. Request,
  stream, line, event and JSON sizes are bounded. Error text redacts supplied
  credentials and custom header values.
- Ordinary startup and opt-in native connection chats offer no model tools.
  Explicit synthetic saved-project
  workflows have platform-specific capabilities and trust/mode gates; see the
  [readiness index](docs/parity.md#readiness-index-2026-10-07). Unoffered calls are
  rejected visibly; unknown outcomes are retained without automatic reexecution.

## Multiple chats and durable drafts

The existing New Chat controls (Ctrl/Command-N) and sidebar now support multiple
chats within the selected project. Saved drafts debounce in the background; closing
flushes them and stops active runs. A failed save keeps the window and draft.
`--session FILE` anchors a Rust-only workspace catalog beside that initial snapshot;
relaunch restores its last saved chat. Use another anchor for a different project.
See [the exact scope, recovery semantics and unported limits](docs/multichat-and-tools-checkpoint.md).

The explicit synthetic saved runtime now executes tools through the Controller;
production model tools remain disabled. [Saved-runtime Linux GUI evidence](docs/validation/saved-runtime-app-2026-10-07/README.md)
and the later tool records in the readiness index identify their exact tested
scope and binary. The older multi-chat checkpoint is historical evidence.

## Measurement

Set `BELLO_PERF_LOG=/tmp/bello-agent-perf.jsonl` for measured startup and render
callback CPU durations. These **do not measure displayed FPS, GPU present time,
or input-to-photon latency**. Rendering on Linux software Vulkan must be labelled
as such. No speedup claim is justified until equivalent workflows are measured
against the Swift baseline on the same hardware.

## Platform status

macOS Apple Silicon is the target; Linux is a development/validation platform.
The [macOS CI recipe](../.github/workflows/rust-macos.yml) covers native builds and
selected source-oracle/lifecycle checks. Exact-commit CI and native UI, vault,
signing, accessibility and owner-Mac acceptance are separate gates.

## Existing UI contract and isolated visual QA

The shell follows the existing Swift hierarchy and literal design tokens rather
than introducing a new navigation design. See [the independent UI checklist](docs/ui-parity-review.md).
The original branding asset is embedded unchanged. Linux uses proportional system
fallback fonts and geometric counterparts for macOS SF Symbol controls.
Unported controls remain unavailable; their presence is not functional parity.

The following process-only variables support repeatable visual QA without changing
the desktop's theme or persisting a test appearance:

```sh
BELLO_TEST_APPEARANCE=dark BELLO_TEST_WINDOW_SIZE=920x600 cargo run -p bello-agent-app
```

Omit them to follow the native window appearance. Sidebar width (200–420 pixels,
default 300) and adjacent-pane ratio (30–70%, default 50%) use the source bounds
and persist after dragging. The temporary UI layout record contains no credentials.

### Project skills (explicit picker)

The normal `SavedRuntimeFactory` path now discovers only the confirmed project's
`.agents/skills` and project instruction chain. The Skills picker creates an
explicit ordered selection with optional literal arguments. Typed or pasted
`/name` text does not select a skill. Selection neither runs scripts nor grants
tools; dependencies reflect the chat's actual builtins and enabled configured
MCP names, without probing or installing servers.

Skill-only and skill+image input share durable receipts, queue preparation,
retained provider content, Stop/Resume/Retry, Context and task-root-aware
compaction. Pending input freezes the selected bodies; delivery rechecks current
metadata/policy/dependencies. Retry replays delivered bytes after source removal.
New user deliveries record task provenance in snapshot v8; skill drafts and
receipts use catalog v9. Older supported files open without rewriting; mutations
promote versions. Expanded text remains bounded, skill-bearing UserContent is
limited to 32 MiB, legacy image-only content to 20 MiB, and the complete provider
request to 32 MiB. Oversized combinations are refused without truncation.

Ordinary saved-authority/tool startup remains gated on separate production
signing, Keychain and authority acceptance. The disposable no-cost
[GUI fixture recipe](docs/project-skills-gui-fixture.md) exercises this same saved
runtime using generated project files and numeric-loopback synthetic authority.
Home/Codex configuration discovery, leading-command parsing, implicit execution,
and complete native token/accessibility parity remain outside this slice.
See the [implemented checkpoint and observed GUI evidence](docs/validation/project-skills-2026-10-07.md)
for tested paths and exact binary attribution, and the readiness index for
remaining compatibility/acceptance gaps. Check CI against the exact commit.
