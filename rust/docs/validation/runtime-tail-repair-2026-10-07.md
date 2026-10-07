# Completed-worker tail retirement repair

Scope: narrow lifecycle repair on published
`50da4e9969a75182461dd24619bbad083155d4cb`
(tree `b328816ff6b6ae9b99f3cbae2a6297d4ffbf9f2a`). It does not include the next MCP
implementation. All diagnosis/tests used isolated exact source, temporary files,
fake credentials and numeric-loopback providers. No timeout was increased.

## Failure and discriminating reproduction

Linux [run 37596398489, job 112709997840](https://github.com/BelloWare/BelloAgent/actions/runs/37596398489/job/112709997840)
failed the saved-editing mutation/replay test in the 20-test synthetic project
runtime batch. The other 19 tests passed. The old assertion wrapped both socket
accept and HTTP-body reads and did not identify which of three requests timed
out. The same commit's macOS run passed; that did not establish the absence of a
scheduling race.

The exact unchanged batch passed locally and then passed 100 four-thread repeats.
With test-only phase/transport/controller diagnostics, the varying-concurrency
repetition failed at iteration 327 (four test threads):

- Phase: reopened replay; transport: socket accept
- Zero request bytes; no Content-Length observed
- Controller: Paused, error Stopped, no active/retry, one pending input,
  queue_paused=true and no active worker
- All four tool results and the final assistant row were completed
- The captured executor observation was zero active/zero waiting

The checked-in timeout diagnostics use only a published snapshot and atomic
worker witness; they do not take the actor or worker-executor mutex and do not
print request bodies or tool arguments.

## Root cause and fix

A worker can publish the completed Idle reply, pass its tail check, and then see
retirement/Stop before its next queue scan. The resource loop interpreted this
as cancellation before checking that no work remained and persisted Paused with
Stopped. A reopened explicit submission was correctly retained behind that
unintended durable pause, so no HTTP request was ever initiated. The normal
saved-runtime loop had the analogous ordering problem. The resource-loop race
also existed before this checkpoint; an earlier green run was not contrary proof.

Both loops now settle an empty completed tail under the existing actor lock
before interpreting late cancellation. The common helper requires Idle, empty
pending input, no active turn/reply, no held edit and no retry. It finishes the
worker and publishes current state without a session transaction. It neither
clears an intentional queue pause nor rewrites transcript/checkpoint bytes.
Unfinished or accepted pending work still uses the cancellation path.

The test-only, session-keyed scheduling barrier is after the old tail check,
with no actor mutex held. It makes the precise race deterministic without a
production delay. Tests cover both resource and saved-authority runtimes:

- Late retirement and late explicit Stop preserve the exact completed checkpoint
- An existing intentional pause remains byte-for-byte intact
- Accepted queued input, including a held edit, stays paused across Stop/retirement
  and only dispatches after explicit resolution/Resume
- Idle with a retained retry is excluded from the completed-tail helper
- Reopen or subsequent explicit submission reaches the real loopback provider

Both workflows now explicitly run the synthetic `saved_runtime::tests` filter,
in addition to the already-covered resource-runtime tests.

## Validation

- 403 synthetic-feature core unit tests passed after the final predicate/tests
- Strict core all-target Clippy with synthetic-authority passed
- 500 repaired filtered batches passed: 10,000 test executions while cycling
  one, two, four and twenty test threads; approximately 73 seconds locally
- Removing the common-helper checks made both deterministic retirement tests fail
  immediately with Paused versus expected Idle; exact source was restored
- Formatting and whitespace checks passed; the root independently reviewed the
  transaction-free fix, cancellation exclusions, tests and diagnostics

Representative focused commands (from `rust/`):

```sh
cargo test --locked -p bello-agent-core --lib --features synthetic-authority tail_
cargo test --locked -p bello-agent-core --lib --features synthetic-authority idle_retry_without_pending
cargo test --locked -p bello-agent-core --lib --features synthetic-authority synthetic_project_runtime::tests -- --test-threads=4
cargo test --locked -p bello-agent-core --lib --features synthetic-authority saved_runtime::tests
cargo clippy --locked -p bello-agent-core --all-targets --features synthetic-authority -- -D warnings
```

These are local source-repair checks. Exact published-repair Linux/macOS CI is a
separate gate, and this report does not claim that unrelated pending MCP work was
part of the tested repair baseline.

## Reviewed LOC delta

The repair changes seven Rust blobs (one new wholly test-only barrier file).
Nonblank physical Rust lines, including comments:

| Category | 50da baseline | Repair delta | Repaired source |
| --- | ---: | ---: | ---: |
| Production | 32,567 | +26 | 32,593 |
| Tests and test support | 46,121 | +377 | 46,498 |
| Benchmark/example | 1,186 | 0 | 1,186 |
| Total | 79,874 | +403 | 80,277 |

149 Rust files. The synthetic-only resource runtime remains support; test hooks
and files remain support. The existing runtime mixed-file classification was
cross-checked against the exact inherited saved-runtime ledger. Counts are not a
feature-completion percentage or a performance result.

The [exact source-blob/span ledger](loc-runtime-tail-repair-2026-10-07-delta.json)
excludes MCP WIP. Reuse the existing verifier with the published repair revision:

```sh
python3 rust/scripts/verify-loc-edit-compaction-2026-10-07.py --repo . \
  --report rust/docs/validation/loc-runtime-tail-repair-2026-10-07-delta.json \
  --after <repair-revision>
```

After-source Rust blob-manifest SHA-256:
`b7ee72b24118f1e294754d59ce0c628cb131860ba7d693beee36072dbf67448f`.
