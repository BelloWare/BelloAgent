# Concurrent tools: main 0.1.121 reconciliation

Specification: main `f4f80ddda3c27fac9e266896f69b725a06242e8f`, specifically
`SessionTools.swift`, `Tools.swift`, and `MCP.swift`. Rust reconstruction base:
`cf63b6d6f4007e65fe8e6e23bb211caf75b6e6ba`.

## Contract

All calls in one reply run concurrently, including write/edit/Bash and MCP.
Chats and even edits of one file do not serialize each other. This does not
introduce filesystem compare-and-swap or rollback. Completed results are retained
in original call order before provider continuation. Pre-entry cancellation is
NotExecuted; entered interruption can be Unknown. A full bounded worker queue
(`tool_busy`) is a known pre-effect rejection and therefore Failed.

Native work retains the existing four-active/64-waiting physical pool. Dropping
an awaiter cancels work but never pretends an entered OS operation or Bash reaper
has joined. Session writer retirement still waits for physical ownership.

MCP active admission is separate from durable result ownership. Existing
settings admission remains fail-fast and exclusive, refusing active work and
pending receipts before vault CAS. A test-only queued configuration writer
exercises fair drain/cancellation and the late-sibling deadlock boundary. Completed Tickets retain the Ledger/OS writer lease,
not active admission: a fair queued configuration writer must not deadlock a
later sibling while the batch holds an earlier completed Ticket.

MCP persistence uses a separate pool bounded to four physical blocking workers.
Its owned permit moves into the actual blocking closure and survives awaiter
drop. No persistence permit is held during network I/O. Pre-effect waits can
cancel; after an effect, retention/settlement remains owned and durable, or
preserves truthful Unknown evidence. One sibling cannot erase another's marker.
The four-worker persistence limit counts physical closures; it does not claim
the independent asynchronous MCP callers/waiters have the native 64-entry queue.

Production trust/tool/vault/native gates, explicit Editing mode, immutable
authority checks, session writer ownership, and no automatic replay are retained.
No App facade or new native permission is introduced.

## Prior staging Linux validation — 2026-10-08

Rust 1.99.0, offline/locked dependencies, one compiler job during shared GUI
validation. All inputs are temporary fixtures and numeric-loopback services.

- Full all-feature core: **589 unit + 127 integration tests passed**, zero failed
  or ignored. Two one-test subprocess repetitions are excluded from that count.
  Native macOS-only suites compiled out on Linux and did not execute.
- Default core unit suite: **415 passed**, zero failed or ignored.
- Focused concurrency: **21 passed** (17 MCP, four native/Controller tests).
- Saved Bash live-preview regression: **20 consecutive isolated passes** after
  replacing timing assumptions with a test-controlled finish marker and bounded
  repeated output. The original three-second command timeout remains unchanged.
- `cargo fmt --all -- --check` passed. Strict core `cargo clippy --all-targets`
  with `-D warnings` passed in default and all-feature configurations against the
  final source.
- App all-feature/all-target `cargo check` passed, including the narrowly scoped
  asynchronous acknowledgment caller. This is not App test execution or GUI
  acceptance. Cargo reported an existing dependency future-incompatibility notice
  for `proc-macro-error2 2.0.1`.

Reproduction from the repository root (use the workspace's pinned Rust toolchain):

```sh
cargo fmt --manifest-path rust/Cargo.toml --all -- --check
cargo test --manifest-path rust/Cargo.toml --offline --locked -p bello-agent-core --all-features --tests -- --test-threads=2
cargo test --manifest-path rust/Cargo.toml --offline --locked -p bello-agent-core --lib -- --test-threads=2
cargo clippy --manifest-path rust/Cargo.toml --offline --locked -p bello-agent-core --all-targets --all-features -- -D warnings
cargo clippy --manifest-path rust/Cargo.toml --offline --locked -p bello-agent-core --all-targets -- -D warnings
cargo check --manifest-path rust/Cargo.toml --offline --locked -p bello-agent-app --all-features --all-targets
```

The default unit suite was executed directly from the freshly compiled test
binary to release the shared Cargo lane; the command above reproduces that suite.
Independent source review identified and required moving acknowledgment's actual
state-lock/fsync operation into owned bounded persistence; that correction and its
one-line App `await` adaptation are included and re-reviewed.

### Failure history retained

Initial reconstruction: 576 passed/three failures in direct Read/Find/Grep
pre-cancellation enum assertions. Direct `NativeTools::invoke` now preserves its
existing Cancelled contract; Controller pre-entry NotExecuted and entered-worker
Unknown remain distinct, with explicit regressions.

The next complete run had 588 passes/one saved Bash preview observation failure.
A finish barrier alone passed a full suite but failed isolated repeat four: live
updates intentionally use try-lock and may be discarded during sibling completion.
The fixture now keeps producing small bounded updates until observation releases
it. No production live-update behavior, assertion or deadline was weakened.
Final full and repeat runs above supersede these failed candidates; old logs remain
part of the handoff evidence, not mislabeled successes.

Selected prior staging raw-log SHA-256s (not the normalized publication logs):
- Full core: `7b32d5182666686c41bebd5d2d6eb471506741d4ea797bf891a814d841b1dcad`
- Default unit: `91afb5d4880986bcfff5ec96c667a6779f2cba8823e61ff4a0e75e3fa3e6b1ec`
- Focused concurrency: `abc54fc315d0e54a88502ffca06d2f75ebc86f4b269c46084478c681fc1377fc`
- Twenty Bash repeats: `c285aa67ae95b04cc4b4b37d012ebe4784957ff61f636080e680a436e5021242`
- App type-check: `ca4764f870bdb4be18e29cdc64c3b8c61d4e3eb54c86677d11c71fcdb9822f78`

## Integrated Linux validation before lease repair — 2026-10-08

The local candidate based on published `9a07b0062a4e500f1dc49cc9656b90d15b970d93`
combines the exact 29-path A5 patch with the paired Swift source/oracle update.
Fresh Rust 1.99.0 checks used two compiler jobs and two test threads:

- Default core: **415 unit + 127 integration tests passed**.
- All-feature core: **589 unit + 127 integration tests passed**.
- Both runs had zero failures and ignored tests. Subprocess repetitions are not
  counted twice. Native macOS-only tests executed zero cases on Linux.
- Formatting, strict default/all-feature core Clippy, and all-feature/all-target
  App typechecking passed. The existing dependency future-incompatibility advisory
  remains. Typechecking is not App test or GUI execution.

These are separate executions against the integrated candidate, not recycled
staging counts or proof that the candidate is published. Commands, exit codes,
normalized logs, source binding, staging failures and paired-oracle hashes are in
[the integration validation record](validation/concurrent-tools-2026-10-08/README.md).

## Integrated lease-repair validation — 2026-10-08

A subsequent acquired-only workspace lease guard explicitly unlocks after final
owner drop, including when a duplicated descriptor remains alive. It preserves
writer exclusion and does not unlink the sidecar. The original shutdown test now
proves its last workspace owner is gone before the immediate reopen.

Fresh combined-source validation passes 61 workspace-focused tests, three
process-lock tests, **591 all-feature core units + 127 integrations**, four App
shutdown tests, and **581 synthetic-authority App tests with three ignored**.
Strict core and App Clippy and formatting pass. The initial App link failed only
because the GPUI library-search settings were omitted; its recorded configured
retry passes. The default full suite above predates this supplement and was not
rerun. See the integration validation record for exact source bindings and logs.

## Limits and integration gates

The separate four-physical-worker pool covers async invocation persistence,
receipt reads/writes, result settlement and acknowledgment. Existing synchronous
MCP new/rebind APIs still perform authority confirmation and Ledger open/OS lease
acquisition through SavedRuntimeFactory construction; those constructors are not
claimed to use this pool.

The deferred-cleanup/all-owner-drop regression tests actual same-process project
reopen under contention. Existing subprocess lease tests cover OS exclusion, but
there is no new subprocess version of that exact deferred-cleanup case. Delayed
old-session success/404 and existing generation-change coverage pass; the exact
old-session SSE list-change race is not separately exercised.

The integrated candidate includes the paired main-pinned Swift `Tools.swift` and
Write/Edit oracle update with exact verified postimage hashes. The source file is
identical to main specification `f4f80ddda3c27fac9e266896f69b725a06242e8f`; the
expanded oracle retains the A4 BOM matrix. Native execution of these oracles
remains pending. The candidate preserves the A4 decoder, workflows and catalog.
The retained earlier A4 same-artifact receipts are separately attributed and do
not validate this concurrent candidate. Native macOS concurrency/oracles, exact
published CI and interactive GUI acceptance remain separate gates; synthetic App
tests passed with three ignored cases. Nothing in this record authorizes production tools, vault access,
credentials, signing, a release or native capture.
