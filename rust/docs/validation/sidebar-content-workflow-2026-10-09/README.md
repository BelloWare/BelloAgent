# Sidebar saved-content integration verification

This is an exact-source, gated migration checkpoint. It connects lifecycle fencing,
the shared inspection/source scheduler, a private SQLite cache, bounded sidebar
snippets and fresh normal-open reveal. **Linux and macOS production acceptance
records remain `None`. No production content-search activation or full parity is
claimed.** The SQL reader still runs on the serialized source job; a dedicated,
independently cancellable concurrent query worker remains an explicit next gate.

## Source binding

- Baseline: `92fca5871240788f9da9c109fe451c76fb128480`, source-identical to
  published `4bde7489a19974ca4d250209f8cc0b05d3afb340`.
- Swift main checked at 2026-10-09 15:08:15 UTC:
  `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`, tree
  `43ed6d8843a09b58fe00d436dd0e0c1a56c76972`.
- The final v3 seal binds all 49 changed source/config/workflow/document leaves.
  Core's separate 25-leaf frozen source remains byte-identical. See
  [verification.json](verification.json) for every SHA-256 and Git blob identity.
  These added verification artifacts were produced after compiled-source freeze.

## Executed gates

Core Linux: 1,070 all-feature and 883 default aggregate tests passed, together
with strict Clippy, format and dependency-union checks. App final v3: 124 focused
sidebar/fixture tests; restored 831 all-feature tests (3 explicitly ignored) and
651 default tests (1 ignored); strict all/default, format and synthetic/ordinary
builds passed. Tests were source-bound, jobs=1; package-clean preceded restored
validation after isolated mutations. Native ignores are not counted as acceptance.

Seven earlier semantic controls were killed. The first GUI-repair controls caught
two faults but a forced-re-navigation control survived a weak post-landing assertion.
That survivor is preserved, not labeled a pass. The final stronger assertion kills
forced re-navigation by checking permanent navigation-token cancellation. A second
final control kills reused paint ownership at the actual old 500 ms timeout while
fresh geometry is still measuring. Both negative worktrees were restored exactly.
Earlier compile, style and test failures remain in the compact receipt history.

## Actual GUI and remaining startup limitation

[GUI evidence](gui.md) describes the final debug Linux synthetic-feature build,
using only a private disposable fixed fixture and unavailable provider authority.
After native window expose/input recovery, fresh and same-root restart runs verified
Find independence, first-unopened automatic reconciliation and exact reveal,
repeated result actions, tool IN/OUT mapping, truthful truncated-preview fallback,
distant history landing and completed-reveal wheel/no-resnap. Both exited normally.
No screenshot or binary is published here.

**Synthetic/cache-enabled materialized-history initial painting remains unaccepted:** synthetic fresh and
restart windows initially stayed black until window expose/input recovery. The
ordinary isolated empty pending-session control and a corrected private five-chat
materialized-history copy both painted their first capture without expose/input.
The ordinary CLI rejected the synthetic route without creating a fixture; its
content search visibly stayed privacy-gated. A first diagnostic copy omitted lock
files and correctly showed unavailable storage; that setup failure is preserved.
These controls narrow the difference to synthetic launch/cache setup without proving
a cause. No speculative redraw fix was made. A separate StorageFull launch failure
was preserved; it was not a source-test failure or a successful startup.

## Privacy and freshness boundaries

Read-only unloaded observations remain as-of receipts, distinct from healthy
LoadedAccepted durability/current ownership. Every eligible member, including
negatives and failures, is reconciled; cached hints cannot manufacture fresh results.
Pending/uncertain/retired/failed-cleanup/map-gap loaded ownership blocks disk fallback.
Live cache barriers suppress hits and geometry. Selection/read persistence uses
owned completion, not sleeps. An explicit reveal survives expected metadata changes
until actual geometry or terminal fallback completes it; later revalidation can
restore decoration only. New user navigation permanently revokes the older intent.

See [workflow design](../../sidebar-content-workflow.md) and
[private-cache constraints](../../sidebar-private-cache.md). The denied OS tracing
route was not bypassed. SQLite VFS/build/runtime evidence is not whole-process
tracing, swap protection or forensic erasure. Native privacy/UI/IME/accessibility,
production readiness and exact published-commit CI remain separate gates.

## LOC and timing

[LOC ledger](loc.json): 64,183 production, 86,673 support and 1,192 benchmark
nonblank Rust lines, delta +3,493/+3,771/+0 from the immutable baseline. Comments
count. The [verifier](loc-verifier.py) checks baseline and current inventories;
[controls](loc-controls.json) include positive/negative cfg gates and comma-less
braced match arms. Shared BelloBox source and non-product evidence remain excluded.

Command and GUI process intervals are observed wall time, not performance results
or inference effort. Parallel API intervals are not additive elapsed time.
Inference timing is unavailable. All claim limits and exact receipts are in
verification.json. Integration must preserve unrelated leaves and timing files;
this evidence does not claim a branch update or terminal CI result.
