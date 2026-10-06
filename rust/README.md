# BelloAgent Rust / GPUI migration

An incremental native implementation alongside the unchanged Swift application.
This is **not feature parity** or a release replacement. The source-backed
[parity ledger](docs/parity.md) separates implemented, partial, and unported work.

## Build and test

Rust 1.89+ (tested with 1.89.0 and 1.99.0 on Linux), Cargo, and GPUI Linux build
dependencies are required. GPUI is pinned to 0.2.2; libc is pinned to 0.2.186 for its transitive
xattr compatibility. Both shared workbench crates are pinned to BelloBox Git
revision `ee0d27a89aa52524c29b2be5937716b5e799e748`. This includes atomic CRLF
deletion, composed-character navigation, selection collapse and guarded IME
commit handling in the shared editor. Native IME/macOS interaction is not yet
validated. A standalone checkout needs no
sibling BelloBox directory; Cargo fetches that exact published revision.

```sh
cargo test -p bello-agent-core
cargo build -p bello-agent-app
cargo run -p bello-agent-app -- --project ../
```

The app opens an honest disconnected workspace until a connection is supplied.
It never discovers credentials in the shell, environment, or source app files.
The temporary Linux credential entry point is explicit stdin; it is kept only in
memory and is not a native vault integration. An optional, explicitly composed
macOS authority adapter and separate Rust identity are documented in
[the native authority contract](docs/native-authority-contract.md); the app still
uses unavailable production authority, and no source vault is imported. Native
acceptance, host composition and full settings flows remain separate gates.
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
- Tools are not offered or executed in this slice. Unexpected function calls
  stop visibly instead of inventing tool results or silently claiming success.

## Multiple chats and durable drafts

The existing New Chat controls (Ctrl/Command-N) and sidebar now support multiple
chats within the selected project. Saved drafts debounce in the background; closing
flushes them and stops active runs. A failed save keeps the window and draft.
`--session FILE` anchors a Rust-only workspace catalog beside that initial snapshot;
relaunch restores its last saved chat. Use another anchor for a different project.
See [the exact scope, recovery semantics and unported limits](docs/multichat-and-tools-checkpoint.md).

The standalone ls tool module is fixture-tested groundwork only. Production model
tools remain disabled. Latest multi-chat native interaction QA is blocked by the
disconnected test desktop; Linux compile/test success is not visual verification.

## Measurement

Set `BELLO_PERF_LOG=/tmp/bello-agent-perf.jsonl` for measured startup and render
callback CPU durations. These **do not measure displayed FPS, GPU present time,
or input-to-photon latency**. Rendering on Linux software Vulkan must be labelled
as such. No speedup claim is justified until equivalent workflows are measured
against the Swift baseline on the same hardware.

## Platform status

Linux is the current build/run target. The shared native UI is portable GPUI and
macOS storage paths are cfg-selected, but macOS build, native vault, signing,
accessibility, and platform interaction require validation on the owner's Mac.

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
