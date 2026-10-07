# BelloAgent Rust + GPUI migration handoff — 2026-10-07

## Start here

This repository contains the Swift application/specification and the Rust migration.
Continue on **`rust` only**. The owner's explicit migration instruction overrides
AGENTS.md's unrelated `dev/next` release workflow. Preserve Swift behavior; do not
merge to main, force-push, publish releases, sign software, or access the owner's
Mac/credentials as an incidental development step. Use the original Swift files as
the behavior specification, not old screenshots or assumptions. Target native
macOS Apple Silicon; Linux is a development/validation platform. Keep extra service
spend at zero: use disposable loopback model servers and synthetic authority, not
paid model calls. Use parallel independent ownership and focused tests; coordinate
shared Cargo/link/desktop lanes. Never infer performance or feature completion from
LOC, CPU callback timings, successful compilation, or synthetic tests.

All implementation through `df548008411b602e19ad2c3ac466a7a469ff6ae5` is published.
Its tree is `39de1c4d8847ca337c0013a80ece00bb760cf181`; parent
`88a0ddbb762703c47010f3eb2e537aa1eb0a3d71` contains the synthetic runtime checkpoint.
This handoff's commit adds documentation, reproducible LOC evidence and a one-line
Inspector test macro correction. **Read the final branch SHA and exact CI after
cloning. Do not assume this handoff commit's CI passed.**

```sh
git clone --branch rust https://github.com/BelloWare/BelloAgent.git
cd BelloAgent
git status --short
git log -5 --oneline
```

Read these project documents next:
- `rust/docs/parity.md`: chronological implementation/evidence ledger. Later entries
  supersede older “missing” rows; it is not a current completion percentage.
- `rust/docs/storage-and-privacy.md`, `held-edit-recovery.md`,
  `multichat-and-tools-checkpoint.md`: durable queue/draft/recovery constraints.
- `rust/docs/current-project-host.md`, `project-authority-contracts.md`,
  `native-authority-contract.md`: trust, writer ownership and vault boundaries.
- `rust/docs/read-only-tool-controller.md`, `native-find-contract.md`,
  `native-grep-contract.md`, `synthetic-project-runtime.md`.
- `rust/docs/context-preview.md` and `rust/packaging/macos/README.md`.
- `rust/docs/transcript-benchmark.md`, `rust/perf/README.md`: measurement scope.

## Current feature state

### Usable implemented workflows

The app has CLI-configured model streaming, independent chats in one explicitly
selected project, durable drafts/selection, deferred chat materialization,
follow-up and steering queues, held-edit recovery, reorder/promotion, cancellation,
Retry/Resume/Stop, and partial-response preservation. Transcript paging,
virtualization, scroll/focus handling, raw Copy, and truthful tool-result cards are
implemented. Sidebar Pin/Unpin, Copy Session ID, Archive/Restore, archive visibility
and read-only archived composer behavior are implemented. Quick Open, adjacent file
tabs, dirty-close handling, file conflict protection, shared text editing and a
bounded opt-in Vim subset are available. These are bounded Rust workflows, not a
claim that the whole Swift app is complete.

The new Context footer/Inspector opens a separate read-only Next request window:
actual provider request construction, redacted credentials, active/idle/waiting-tool
semantics, 64 KiB selectable pages, immutable Copy and manual Refresh. Its core
contracts passed locally; **the new GPUI window tests have not yet executed** due
the CI compile failure described below. Do not label that UI accepted yet.

### Backend or explicitly synthetic/test-only

- `ls`, macOS Foundation/libc `find`, and macOS Foundation-regex `grep` have durable
  Controller invocation/result/replay paths and source-oracle tests. Desktop
  constructors still default to tools disabled; core availability is not app enablement.
- Instruction discovery has source precedence, budgets, hashes and diagnostics.
  The synthetic-only host now connects explicit fixture paths to per-delivery
  snapshots, real loopback requests and read-only tools. It does not discover the
  process home/settings/skills or enable production tools.
- Projects UI supports current-primary trust/retrust and additional-root review.
  Production storage remains unavailable in normal app composition; explicit
  synthetic authority is memory-only and labeled as such.
- Catalog v5 saves a confirmed SavedProject UUID and explicit per-chat tool mode.
  The one-way confirmed ReadOnly→Editing lifecycle boundary exists, but no visible
  mode control or new side/import workflow was invented to expose it.
- Optional `native-authority` implements a separate Rust vault adapter and identity
  templates. Default/new authority constructors remain unavailable. Fake contracts
  and native type checks are not actual signing/Keychain acceptance.

### Major remaining parity work

1. Production Settings/profiles/model selection, persistent credential lifecycle,
   native trust-to-runtime composition, and user-approved native acceptance.
2. Remaining tools, especially full `read`, write/edit/shell and other source tools;
   multimodal tool results; MCP configuration/transport/permissions/lifecycle.
3. Complete resource settings/import, skill discovery/metadata/dependencies,
   picker/leading-command selection, frozen queued skill bodies and delivery checks.
4. Attachments/images and declared model input capability, with durable bounded
   payloads and correct provider replay. Literal slash text currently follows Rust
   dispatch; the source app-command/skill workflow is not implemented.
5. Multiple projects, relocation/Locate Folder, topics, richer tabs/organization,
   side chats, forks, import/export and associated identity/lifecycle rules.
6. Context compaction, token counting, budgets/cost limits, pricing/usage dashboards,
   background title/suggestion/utility tasks, notifications/webhooks and reports.
7. Full Inspector request archive/capture/search/comparison/resource views; rich
   Markdown/links/accessibility and remaining transcript/composer interactions.
8. Source macOS last-window detach/Dock reopen/cancellable Quit behavior, native
   keyboard/IME/accessibility/focus acceptance and same-hardware Swift comparisons.

## Architecture and invariants

Rust workspace: `crates/bello-agent-core` owns provider/session/store/Controller,
queue state, tool history/execution, resources and authority. `crates/bello-agent-app`
owns GPUI views, per-chat models, admission/generation coordination and editor
entities. Shared workbench/editor packages are pinned to BelloBox commit
`393133cd19d134ffd93c3a86449d94a7b1040683` in manifest/lock. Do not silently advance
one pin or mix unreviewed shared-source changes. The Swift spec is under
`apps/macos/PiApp` and `packages/swift-host/Sources/PiAgentCore`.

One Controller owns each session writer. Actor mutations serialize under its mutex;
durable commits precede acknowledgment. Stop is distinct from permanent retirement.
Retirement rejects stale Arc mutations and releases writer ownership only after
workers join; failed joins retain ownership. Idle-admission guards are RAII,
single-owner and fail closed. They own no mutex across await; retirement cannot
release the writer before a guard drops/seals. Inspection leases reuse existing
writer locks and validate journals in memory without recovery writes. Nonblocking
regular-file checks prevent FIFO/path replacement hangs.

Session locks explicitly unlock on Drop, including inherited-descriptor cases.
Never restore close-only unlock behavior. Journals/checkpoints, queued intents,
cancellation receipts and held drafts are not interchangeable recovery evidence.
Before-rename failures preserve memory; uncertain commits fence future mutations.
Reading a file is not confirmation of durability. Do not clear uncertainty or
recommend restarting when unsaved drafts could be lost. Unknown tool outcomes are
recorded honestly; historical calls never automatically reexecute.

Catalog v1–4 reads remain byte-preserving; mutations promote to v5. v5 modes are
explicit and strict. Project UUID binding consumes fresh authority confirmation
obtained outside the catalog mutex. An existing ID/root cannot be replaced or used
to relocate path-derived storage. Ambiguous unbound same-path projects are refused.
Stale row writes preserve the latest mode, archive state, drafts and receipts.
Project saves use save→confirm/bind→retire/join→reopen→confirm→publish ordering.
Any post-save uncertainty keeps admission blocked. One-chat mode changes use
per-chat fences and close/join→persist→publish, retaining composer/Undo entities;
unrelated chats remain usable. Definite failed mode writes may reopen a fresh
unchanged read-only actor; uncertain writes never revive old actors.

Synthetic runtime confirmation is point-in-time evidence, not a filesystem sandbox.
Absolute/parent/tilde/symlink paths may leave roots as in Swift. Synthetic constructor
requests require numeric loopback, fixed fake credentials and a no-proxy/no-redirect
client. Atomic generation checks run inside actor admission; full authority/catalog
checks run outside locks. Revocation prevents new admission/continuation; already
admitted reads can settle truthfully, while Stop/retirement cancel and join them.

Swift freezes selected skill bodies at submission, but resolves instructions and
catalog at delivery. Do not persist all resource bytes on every Submission.
Synthetic instruction preparation happens before dequeue, rechecks exact candidate,
edit/Stop/retire/generation, and tolerates harmless appended input. Active requests
and same-controller Retry retain applied snapshots; next delivery/reopen refreshes.
Steering preparation failure still records completed tool results and retains input.
Context preview explicitly refuses the synthetic dynamic-resource constructor,
rather than falsely showing its lifetime-fixed options or performing new reads.

Native authority uses whole-envelope byte CAS and retains unknown raw fields.
Failed Security updates and nonduplicate adds are Unconfirmed because platform
repair can mutate before failure; only duplicate-add is Conflict. No delete/replace
fallback, unsigned fallback or plaintext vault exists. Approved separate identity:
`com.belloware.BelloAgentRust`, service
`com.belloware.BelloAgentRust.configuration`, account `vault-v1`, Developer ID team
`43TXHV3TM3`. Templates are not installed signing identity or Keychain proof.
No actual owner credentials, signing, security prompts or native vault access were
performed. Those remain separate explicit native gates.

## Validation status at handoff

- `f443882`: Linux run 37536120539 and macOS run 37536120509 passed. Linux included
  four new project/mode GPUI regressions, 57 synthetic project tests, 9 workspace
  identity tests, strict Clippy/build and software UI smoke. macOS compiled native
  targets, ran 17 pure project-host/8 mode tests, identity tests and own-window
  lifecycle smoke. Both ran authority/native fake contracts.
- `df548008`: Linux run **37567909975 failed** in Core and integration tests,
  job112619820039, before new tests could execute: recursion limit expanding
  `#[test]` at `context_inspector_tests.rs:83`. `super::*` inherited GPUI's test
  macro. The final handoff commit qualifies this pure test as
  `#[::core::prelude::v1::test]`; that exact built-in syntax passed a local rustc
  test. This is not a claim that the full app now compiles. Inspect new exact CI.
- `df548008` macOS run **37567909976 was pending** at handoff preparation. macOS
  compiles all app tests but only executes selected pure app tests; Context GPUI
  execution is a Linux gate. New final-commit runs may supersede these statuses.
- Local integration: 40 synthetic-feature tests, 43 default focused tests and
  strict core all-target Clippy in both configurations passed. Independent core,
  host, Inspector and integration reviews completed.
- Context: 11 core tests, 15 affected provider/tool regressions and an exact-source
  standalone Unicode paging property test passed. Two negative controls caught
  credential-suffix redaction and stale published-state errors, then passed after
  exact restoration. Twelve GPUI Inspector tests are written, still unexecuted.
- Synthetic: 28 focused resource/host tests, 31 affected default regressions;
  negative controls caught proxy inheritance and pre-recovery identity errors.
  FIFO/regular-file and proxy tests use bounded disposable subprocesses.
- Earlier exact native Find/Grep Swift oracle and loopback/replay tests passed in
  `a4299df` macOS run37531951386; Linux run37531951350 also passed.

Links: https://github.com/BelloWare/BelloAgent/actions — filter by exact commit,
not latest branch badge. Never blindly rerun a failure: inspect its failed step.

## Reproduce on a fresh machine

Use official tools/package sources. Rust toolchain is **1.99.0**, minimum manifest
1.88. Workflow files `.github/workflows/rust.yml` and `rust-macos.yml` are the
canonical CI recipes. Full clone history is needed for the LOC verifier.

Linux Debian/Ubuntu build prerequisites (normal administrator environment):
```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential pkg-config curl ca-certificates libfontconfig1-dev libxkbcommon-x11-dev libwayland-dev libx11-xcb-dev libasound2-dev libzstd-dev libssl-dev libvulkan-dev cmake clang lld xvfb xauth openbox xdotool imagemagick tesseract-ocr fonts-dejavu-core mesa-vulkan-drivers
rustup toolchain install 1.99.0 --profile minimal --component rustfmt --component clippy
cd rust
rustup override set 1.99.0
cargo fmt --all -- --check
cargo test --locked -p bello-agent-core
cargo test --locked -p bello-agent-core --lib --features synthetic-authority runtime::resource_runtime::tests
cargo test --locked -p bello-agent-core --lib --features synthetic-authority synthetic_project_runtime::tests
cargo test --locked -p bello-agent-core --lib --features synthetic-authority runtime::context_preview::tests
cargo test --locked -p bello-agent-app context_inspector::
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo build --locked --workspace
```
Also run the focused project/native-authority commands in CI when changing those
boundaries. The full workspace suite is a final gate, not a loop to run after every
small edit. Use bounded build parallelism (e.g. jobs2) and coordinate heavy links.
For manual app startup, run `cargo run -p bello-agent-app -- --help`; use the app's
existing explicit profile/credential-stdin contract without putting real keys in
shell history, files, examples or a handoff. Use `rust/fixtures/gateway.py` and
fixture profiles for no-cost tests. `--synthetic-project-authority` additionally
requires the nondefault synthetic-authority app feature and is memory-only.

For Apple Silicon, use an actual supported macOS environment with Xcode command
line tools and pinned Rust. Follow the macOS workflow. Adding
`rustup target add aarch64-apple-darwin` on Linux only enables metadata/type checks;
it is not a Mac SDK, native execution, signing or UI acceptance.

The deleted cloud environment must not be assumed to exist. It had task-local
`.cargo`, `.rustup`, and `target` directories; those paths are disposable caches,
not repository inputs. Local GUI prerequisites were unavailable. The newest
approved `apt-get update` retry reached apt (the older sandbox-bootstrap failure
had changed) but exited100: permission denied reading
`/etc/apt/apt.conf.d/80-applied-apt-retries`, and missing
`/var/lib/apt/lists/partial`. No packages were installed. Do not edit protected
runtime paths or system security settings to bypass that environment failure.
A fresh normally configured development machine should use the official recipe.

## Worktree/recovery audit and durable source

At final freeze all ten preexisting Agent worktrees were clean. The primary was
at df548008. The final handoff changes are committed on top; none of the old worktrees
contains unique uncommitted source. Historical local commits below differ in Git
metadata or precede a documented integration; do not reapply them as new features.

| Historical worktree/checkpoint | Local SHA | Published representation |
|---|---|---|
| Find recovery | 2619b46 | exact tree acd39c1, published bee278d |
| Grep recovery | 0a3bbcd | recovered original tree0861009; integrated with Darwin fixture into0e464d2 |
| Grep integrated | 7b6bfba | exact tree of0e464d2 |
| Native authority | 889b4fa | integrated without dropping feature intoa4299df |
| Native authority integrated | 44f4ff3 | exact tree ofa4299df |
| Project identity/mode | cd799dd | exact tree off443882 |
| Synthetic runtime | d2ba636 | exact tree of88a0ddb |
| Context separate fork | 779bdc3 | integrated into5b22e75/df548008 with explicit synthetic-preview refusal |
| Integrated local | 5b22e75 | exact tree ofdf548008 |
| Historical rust / rust-lock-published refs | 1fc26e8 / b8ce9e3 | exact trees of6744f8b /75f5e04 |

Local shared checkpoint bundles/patches were also audited: they contain these same
synthetic, Context and integrated commits, not another unmerged implementation.
Their source is now durable in the public branch; local verification JSON is
historical evidence, not another code branch to apply. Current handoff contains
project-relevant conclusions rather than private assistant notes.

A previous environment reset lost pre-reset screenshot/binary/desktop evidence.
Published source and some frozen patches were recovered with exact Git-tree proofs;
that did **not** recover lost screenshots. Earlier recorded Linux interaction QA
is historical, not fresh acceptance of this final Inspector. No current immutable
Inspector GUI binary or fresh desktop screenshots exist. CI software smoke is not
an interactive feature matrix or native macOS input/accessibility proof.

## LOC and performance

At df548008: **23,193 production /33,983 tests and support /1,184 benchmark/example**
nonblank physical Rust lines, **58,360 total**, 97 Rust files. Comments count.
Synthetic-only modules are support, not production. Positive cfg spans start at
the cfg attribute; preceding comments retain the prior classification. These are
source-reviewed deltas over audited baselines, not a recovered general AST counter
and not a feature-completion percentage. The one-line final test-attribute fix
changes no category or line count; added Python/docs are outside Rust scope.

Run this command from the repository root (not the `rust/` directory used above).

```sh
python3 rust/scripts/verify-loc-df548008.py --repo . --output-dir /tmp/agent-loc
```

The portable verifier reads published immutable Git objects, validates exact trees,
recounts all Rust lines and checks reviewed category spans. Results are preserved
in `rust/docs/validation/loc-df548008-delta.json` and the companion TSV.
Performance work includes viewport-limited transcript rendering, paging, retained
UI identity, event-driven snapshot updates and benchmark harnesses. CPU submission
or callback time is not frame presentation. Earlier synthetic Linux results are
not a same-machine Swift-vs-Rust/macOS comparison. Re-establish reproducible native
baselines, long-session scrolling/typing/resize latency, idle CPU, memory and frame
presentation before making performance claims. Do not start new benchmark machinery
instead of missing functional integration.

## Recommended next steps

1. Check final exact CI and fix compile/test failures narrowly. Run the 12 Inspector
   GUI regressions, then actual Linux interaction and native Mac focus/IME/selection/
   clipboard/window-close acceptance. Preserve drafts and prove zero preview sends.
2. Establish a working fresh GUI build environment. Keep native signing/Keychain
   acceptance distinct and explicitly authorized; do not enable production tools
   merely because identity templates or synthetic contracts compile.
3. Close production profile/credential/trust/runtime composition as a complete
   vertical workflow with generation, revocation, uncertainty and recovery tests.
4. Next read-tool investigation is complete but **no implementation was started**:
   Swift `Tools.swift:248–275,318–359`, `Support.swift:56–86` and
   `TextPreviews.swift:14` define UTF-8/image read. Rust currently flattens tool
   results to text (`tool_runtime.rs`) and replays string function_call_output
   (`tool_history.rs`); Profile has no image-input declaration. Full read therefore
   requires multimodal history/schema/provider work, not just an image decoder.
   A deliberately text-only capability must advertise that limitation and reject
   recognized images explicitly. Source text behavior: 16MiB bounded regular-file
   read; file errors precede paging validation; offset default1/max10,000,000,
   limit default2,000/max10,000; LF preserves final empty lines/CR; 32,768-byte lossy
   preview trims edge U+FFFD; viewer lines use different CR/LF rules. Existing Mac
   Foundation/libc dependencies can cover text; do not blindly reuse grep's 2MiB
   reader, which suppresses errors. Test connected loopback→durable result→replay,
   cancellation and default-disabled production paths.
5. Add frozen skill selection, multimodal attachments, remaining tools/MCP,
   compaction/budgets and multi-project/side workflows as coherent vertical slices.
   Reuse the failure/identity boundaries above; do not accumulate misleading UI
   facades or disconnected helpers and call them feature parity.
