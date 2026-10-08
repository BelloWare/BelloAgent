# Test observation crosses final actor publication — 2026-10-08

Base: `a73f56acdf5847e7a9e34c1cb2aceeb051df0db3`, tree
`fe00046cf3eb3122d283de274cf513b72d291159`. Runtime source is the only changed Rust
file; every change lies inside an existing positive test configuration region.
`test-only-source-proof.json` exactly reverses the helper/regression edits and
reproduces the baseline file byte-for-byte. Production source, trust checks,
checkpoint adoption, pending configuration, worker launch and physical join
ownership remain unchanged.

## Failure and diagnosis

[Linux run37848622747/job113555703052](https://github.com/BelloWare/BelloAgent/actions/runs/37848622747/job/113555703052)
failed the exact command:

    cargo test --locked -p bello-agent-core --lib --features synthetic-authority saved_runtime::tests

28tests passed; `compaction_revalidates_trust_after_summary_before_checkpoint_adoption`
observed published phase Summarizing instead of Failed. Original failure bytes and
complete retained log hash are bound in the provenance/excerpt files. No blind CI
rerun or longer fixture deadline was used.

The test's settled helper polled only worker_active. worker_finished clears that
atomic while still holding the actor mutex; the final snapshot publication occurs
later under the same mutex. Thus an observer can see an inactive worker before
reading its terminal published snapshot. Compaction's own test helper already
crosses this actor barrier; saved-runtime and other users of the shared worker
observation did not. Production admission/retirement instead use actor barriers
and registered joins, so the repair is restricted to test observation.

The regression holds the real actor mutex after worker_finished clears the atomic,
with a committed terminal checkpoint still unpublished. The old test helper
returns `(false, "New chat")`; the repaired helper returns `(false, "terminal
checkpoint published")` after release/publication. The100ms channel receive is a
bounded observation while the test deliberately holds that boundary, not a delay
or retry added to production settlement. This reproduces the mechanism; the
original CI interleaving itself was not traced. The observer-start signal precedes
helper execution, so extreme descheduling could let old code miss the100ms window.
This is a controlled held-publication RED/GREEN, not a universally deterministic
scheduler proof. The captured old-code RED and the mutex barrier's source-level
correctness are independent evidence.

The shared cfg(test, synthetic-authority) helper now crosses the actor publication
mutex before reading worker activity. Its meaning is settled actor publication,
not physical task/thread/process joining. All existing Failed-phase, revoked-trust,
retained-context and no-dispatch assertions are untouched; their original deadlines
are unchanged. It cannot conceal a genuinely incorrect terminal state.

## Verification

Rust1.99.0, locked cached dependencies, synthetic files and loopback only.

- New controlled publication regression: old code RED, repaired code GREEN.
- Exact failed saved-runtime selection:29pass,0fail, unchanged authority assertions.
- Clean default core suite:431unit+127integration pass.
- Clean all-feature core suite:610unit+127integration pass. Repeated isolated child
  tests in logs are not counted again.
- Default and all-feature core all-target Clippy with `-D warnings`:pass.
- `cargo fmt --all -- --check`:pass.

The core package was cleaned after the old-code probe; no core test executable
survived before the final rebuild. Final source hashes and raw build/test logs are
recorded. No final test executable was sealed before releasing the shared build
lane; later target timestamps did not establish identity, so no final binary hash
or executable acceptance is claimed.
No App production code changed or new interactive GUI/native/performance acceptance
is claimed. The separately observed GUI sidebar/footer snapshot lag remains an
observation and was not folded into this test-support repair.
