# MCP Inspector outcome admission, 2026-10-07

## Observed native CI and limits

Baseline: `af1ce5f7567b67358db03fd56339bce1c83bcb3f`, tree
`b3f558ca185153e60c5fe82227fad009c7b2424b`.

- [Linux run 37630731740](https://github.com/BelloWare/BelloAgent/actions/runs/37630731740)
  passed for that baseline.
- [macOS job 112823991278](https://github.com/BelloWare/BelloAgent/actions/runs/37630731761/job/112823991278)
  passed the corrected native attachment path oracle and all 358 default core
  unit tests. That is native acceptance of the attachment-oracle correction,
  not a green result for the entire baseline.
- The later focused MCP app suite passed 43 tests and failed
  `reload_recovers_latest_durable_inspector_result_without_reexecution` at its
  pre-reload call-count assertion: zero calls rather than one. The old assertion
  did not record the controller notice, so the exact macOS refusal was not
  captured.
- Locally, the unchanged backend passed the reload test over GPUI seeds 0–199,
  and the controller suite with `ITERATIONS=50` and four test threads. These
  successful stress runs do not reproduce or explain away the native failure.

## Deterministic backend defect and correction

`Ledger::status()` intentionally uses a nonblocking cached-status read for UI
presentation. Lock contention returns a conservative unknown/pending projection.
Invocation admission incorrectly treated this projection as authoritative
evidence of a previous unknown invocation. Another harmless status reader could
therefore cause an authorized one-shot invocation to fail before dispatch.

The regression pauses a cached-status reader and directly polls the invocation
future once while that reader owns the cache lock. On the unchanged backend it
fails with `mcp_outcome_unknown`, `not_executed: true`, before any gateway call.
See [the failing baseline log](baseline-status-contention.log). This establishes
a real false-refusal race; it does not establish that the same error was the
unrecorded cause of the original macOS assertion.

Both invocation admission checks now read actual ledger state on the Tokio
blocking pool. Cancellation can abandon this read; its retained ledger owner
keeps the physical writer lease until the blocking read really ends. Poisoned
state or a failed read worker rejects as `mcp_outcome_unavailable` with
`not_executed: true`. The model-tool adapter maps that flag to `NotExecuted`;
Inspector displays the fixed `Not executed` message without creating a receipt.

The UI's nonblocking, conservative status projection is unchanged. Genuine
unknown-outcome quarantine, explicit acknowledgment, read-only restrictions,
both project gates, repeated authority confirmation, and the final durable
begin marker remain in place. Neither failure nor reload retries an invocation.
The app fixture now asserts successful Save, discovery, and Editing admission,
and captures presentation, manager, configuration, and controller state if a
stage or the original call-count check fails. No timing sleeps were added.

## Verification

All local checks use temporary files, synthetic authority, and loopback servers
on Linux. They do not establish native GUI, signing, vault, or macOS acceptance
of this new checkpoint.

- `cargo test --locked -p bello-agent-core --lib --features synthetic-authority mcp::tests`:
  31 passed. This includes deterministic cache contention, preserved genuine
  quarantine, cancellation behind a held durable-state lock, unavailable
  authoritative evidence, physical writer ownership, receipt crash cuts, and
  the existing nonblocking UI status check.
- `cargo test --locked -p bello-agent-core --features synthetic-authority`:
  473 unit tests and 107 integration tests passed.
- `cargo test --locked -p bello-agent-app --features synthetic-authority mcp_inspector`:
  44 passed.
- Controller scheduling stress: final binary, `ITERATIONS=50`,
  `mcp_inspector_controller::tests`, four test threads. Eighteen GPUI tests run
  seeds 0–49; two ordinary tests run once. All 20 tests passed.
- Strict Clippy for core and app, all targets with synthetic authority;
  formatting and `git diff --check`: passed.

The four tested Rust source hashes are in [SHA256SUMS](SHA256SUMS). Final local
test executables had SHA-256 `39dab8bebd62f97d48c1dbcdc092a69ed3868be901762829031514d5e7d69ce7`
(app) and `e316f57f7b48d08876ab38ca82b907bf5280c9f6470c405d05ec5ac4201f20d9`
(core).

Independent review confirmed that authoritative checks, cancellation ownership,
NotExecuted errors, physical leases, and genuine quarantine remain fail-closed.
The final checkpoint requires fresh Linux and macOS CI after publication.

Raw diff lines against baseline: production `+37/-12` (net +25); test/support
`+183/-2` (net +181). These raw diff counts include blank lines.

The migration's nonblank physical Rust LOC rule gives **+25 production / +174
test-support / 0 benchmark**. The app test file adds 61 nonblank support lines;
the core test module adds 103; the outcome module adds 10 production and 10
support; the manager adds 15 production. Published-baseline totals therefore
become **38,796 production / 53,005 test-support / 1,189 benchmark** after this
checkpoint is published. Documentation and the baseline failure log are separate.
