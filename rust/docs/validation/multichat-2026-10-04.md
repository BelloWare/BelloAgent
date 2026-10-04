# Multi-chat and durable-draft validation — 2026-10-04

Base published Rust checkpoint: `07c6a2b2c7052f91e0157b452964ed697b1d5078`.
This record describes the subsequent development candidate, not complete feature
parity or a release replacement. Source implementation scope and remaining limits:
[multichat-and-tools-checkpoint.md](../multichat-and-tools-checkpoint.md).

## Final checks

At 05:53 UTC, the candidate passed:

- `cargo test --locked --workspace`: **84 passed**, zero failed/ignored
  - 7 application unit tests
  - 43 core unit tests
  - 9 chat-workspace integration tests
  - 2 runtime integration tests
  - 18 standalone ls/executor fixture tests
  - 5 loopback provider transport tests
- `cargo clippy --locked --workspace --all-targets -- -D warnings`
- `cargo build --locked -p bello-agent-app`
- `cargo fmt --all -- --check`
- `git diff --check`

Rust/Cargo 1.99.0; Linux x86_64; development profile without debug information.
Shared crates remain pinned to published BelloBox commit
`3dc2fa3c585927aca0493018c3830d7d1cffedbb`. There is an upstream
`proc-macro-error2` future-incompatibility notice; current strict Clippy passes.
No original Swift source, release assets, tags or feeds were modified.

## Race and recovery coverage

Independent review identified and the final candidate repaired:

1. Queued-edit identity/displaced text lost during cold-load replacement.
   Loading now replaces only the controller, preserving the actual composer and
   metadata; reconciliation is failure-atomic.
2. Shutdown of a still-loading selected chat; duplicate/stale cold loads.
   Readiness guards and load generations prevent stale results taking ownership.
3. Uncertain accepted input losing its durable recovery receipt.
   Uncertain outcomes retain the receipt, and accepted-ID reconciliation runs
   only after the real session is loaded.
4. Typing during Send inheriting submitted text, or debounce clearing text before
   receipt persistence. Return clears immediately; every in-flight draft write
   atomically carries the captured intent. Settled revisions reject stale work.
5. Missing-receipt rejection later resurrected by an old debounce.
   Explicit rejected-settlement records its captured revision even without an
   earlier receipt. Tests cover failed registration and late debounce ordering.
6. Failed first Send or partial quit-flush leaving a saved chat marked pending.
   Materialization receipts update lifecycle state, including partial failures;
   the rejection-settlement barrier remains held until its write completes.
7. Stale queued-edit outcomes, cross-edit original-text leakage, and steering
   while rewriting. Durable outcomes restore only unsaved rewriting, every new
   hold captures its own original text, and submission guards preserve the edit.

Tests include before-/after-rename intent failure cuts: either the old draft
survives or a cleared draft is accompanied by its durable receipt. Uncertainty
blocks further mutation. Concurrent A/B debounce threads, bounded event-driven
local SSE fixtures, cancellation/reopen, and failed reconciliation preserving the
entire original draft are covered. These are deterministic software failure tests,
not physical power-loss or all-filesystem proofs.

The latest read-only source review found no remaining blocking issue in that
reviewed scope. Source review is separate from the automated checks above.

## Source and binary identities

| File | SHA-256 |
|---|---|
| `crates/bello-agent-core/src/workspace.rs` | `ad89549c8d49f863d721a614b4c05d52c1be339c4a097d2807135b359e6643ad` |
| `crates/bello-agent-core/src/session.rs` | `dfbf8e6de14916ff614487db1b15cc2e4b669846b41870bb5774157bda33155c` |
| `crates/bello-agent-core/src/runtime.rs` | `9b2684f8f2ded9930fcfab3d9953a92caea101625c82e3198e2eb9985ed3b83e` |
| `crates/bello-agent-app/src/chat.rs` | `84fd75fd1aca9858edf0aaa1800f399f99dfeb546ba430ff2a9af764177bc55a` |
| `crates/bello-agent-app/src/chat_navigation.rs` | `1b3cb9d810782d0c21865abdd9ad136a8d503957b05358e3ff55e992e8d3ecea` |
| `crates/bello-agent-app/src/main.rs` | `e53188875cecc11f4a62fd38a5f8d4c0eb9d8103ad42416da6471d30a811d424` |
| Linux development `bello-agent` binary | `7badde1b3a6837cd88290f4dbb72abb4e4b2230993006f0e7d525796178bf67e` |

## Not verified / not enabled

- The native desktop transport is disconnected. Latest multi-chat, recovery
  banner, minimum-size/dark layout, and quit-flush interactions have not been
  visually tested. Earlier source-shell screenshots do not verify this candidate.
- macOS build, interaction, native vault, accessibility and distribution remain
  unverified/unported as indicated in the parity ledger.
- Production model tool definitions/execution are disabled. The ls module is
  fixture-only groundwork, not a completed tool loop.
- Multiple projects/roots in one window, source eight-display LRU eviction,
  organization, attachments, rich transcript, tool replay and retained tool
  outputs remain unported. All test requests use fake credentials and loopback
  fixtures; no external model call or user conversation was used.
