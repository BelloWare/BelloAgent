# Concurrent tools: integrated validation

This is a local candidate based on published
`9a07b0062a4e500f1dc49cc9656b90d15b970d93` (tree
`3030469aaf9be46506700530daf27dc7b1747ec3`). These records do not claim
publication or passing exact-commit CI for the candidate.

## Source and scope

The candidate combines the frozen 29-path concurrency migration with the paired
main-pinned Swift source and Write/Edit oracle. It preserves the A4 decoder,
catalog and workflows. The subsequent two-file workspace-lease repair overlaps
`workspace.rs` and adds the App shutdown ownership assertion. The integration
scope is therefore 32 source/documentation paths; validation records are additional evidence.

- A5 patch SHA-256: `513f7d548a1a78a5065ccc71eb9eb847825ff0d6c396d7b8997275b022a3662b`.
- Paired source/oracle patch: `1ed739faeb7b33936c734ca8db458799a94cf2b52542a913458e3eb9b3ab0fec`.
- Lease supplement: `85865abf1207d4807e91018ca326265601eaa3aad541ce3500e0cb73b79e43d2`.

All 29 A5 postimages originally matched the frozen manifest exactly. Only the
authorized lease supplement subsequently changes its workspace implementation.
The Bash overlap retains the complete `done` marker wait and four-second physical
slot-retirement check. Obsolete edit-gate contention is replaced by a process-join
timeout; dropping a caller cannot pretend physical cleanup completed.

`paired-oracle-verification.json` records exact postimages. `Tools.swift` matches
the Git object at specification `f4f80ddda3c27fac9e266896f69b725a06242e8f`;
the expanded Write/Edit oracle preserves the A4 BOM matrix. Native execution of
the updated oracle has not occurred in this Linux validation.

## Fresh combined checks after the lease repair

Pinned Rust 1.99.0, two compiler jobs, two test threads, offline/locked dependencies:

- Workspace-focused core tests: **61 passed**.
- Cross-process lock tests: **3 passed**.
- All-feature core: **591 unit + 127 integration tests passed**, zero failures
  and ignored tests. Subprocess repetitions are not counted twice.
- App shutdown tests: **4 passed**, including the new Weak-owner assertion before
  the original immediate reopen and saved-draft/intent comparisons.
- Full synthetic-authority App suite: **581 passed, zero failed, 3 ignored**.
- Formatting and strict all-feature core and synthetic-authority App Clippy passed.

The first App link attempt omitted the GPUI prerequisite library-search settings
and failed to find xcb/xkbcommon. No tests ran in that attempt. Its log is retained;
the exact retry with the verified GPUI sysroot passed. The existing
`proc-macro-error2` future-incompatibility advisory remains, without a current
Clippy failure.

`fresh-validation.json` contains commands, exits, counts, raw/normalized log
digests and the 303-file `post-lease-source-binding.json` binding verified unchanged
through validation. No interactive GUI or native Mac execution was performed.

## Earlier evidence remains separate

`pre-lease-validation.json` retains the previous integrated-source runs:
default **415 unit + 127 integration**, all-feature **589 unit + 127 integration**,
formatting, both strict core Clippy configurations and App typechecking. The full
default suite was not rerun after the lease supplement; these counts must not be
presented as its final-source execution.

`staging-history.json` attributes the earlier cf63-based migration runs and retains
12 logs. This includes the initial **576/3** cancellation-contract failure,
subsequent **588/1** live-preview observation failure, intermediate full pass
followed by isolated-repeat-four failure, and final staging successes including
20 isolated repeats. Staging raw-log digests differ from the normalized publication
logs. Neither failed attempts nor prior successes are relabeled as fresh runs.

`lease-diagnosis.json` preserves the separate original-CI excerpt and deterministic
before/after duplicated-descriptor regression. Explicit acquired-only RAII unlock
fixes the proven close-only ownership gap without unlinking the lock sidecar,
adding retries/sleeps, or weakening exclusion. The exact inheriting process in
the historical CI failure was not traced and remains an inference.

## Reviewed boundaries and remaining acceptance

The acknowledgment correction moves its actual state-lock/fsync work into owned,
bounded persistence and includes the narrow asynchronous App caller adaptation.
The four-worker pool counts physical persistence closures and retains permits
through awaiter drop. It does not claim a 64-entry asynchronous MCP waiter queue.
Existing synchronous MCP constructor/rebind authority confirmation and Ledger
open/OS-lease acquisition remain outside that pool.

The [retained A4 two-host receipts](../source-utf8-integration-2026-10-08/same-bundle-receipts/README.md)
are attributed evidence for the earlier A80 decoder artifact, with explicit
independent-verification limits. They are not native concurrency acceptance for
this combined candidate. Native source oracles, exact published CI, interactive
GUI, macOS input/accessibility, Keychain, signing and performance remain separate
gates. Synthetic headless App tests do not close them; three ignored tests remain
unexecuted. No production tools or authority capabilities are enabled by this record.

## Rust source counts and visual parity limits

Reviewed cumulative delta over the published9a07 source is +159 production,
+1,232 test/support and zero benchmark lines. Nonblank physical Rust lines,
including comments, total **45,908 production /63,398 test-support /1,192
benchmark-example**, or110,498 lines across212 Rust files. Production includes
145 unchanged build-support lines. `loc-pre-lease.json` and `loc-final.json`
bind reviewed category ranges and the14-production/48-support lease supplement.
Shared workbench source is counted only in BelloBox, not again through Agent's
Git dependency. Counts do not establish parity, performance or a delivery date.

This checkpoint is a backend concurrency workflow: the loopback provider tests
exercise mixed MCP/native/Bash work, ordered durable replay, and Stop/retirement.
Only Bash currently publishes terminal live-card updates independently. Other
tool cards can remain Awaiting until the whole batch settles. General per-call
terminal-card publication is a separate follow-on, as is batch/cumulative wall
time accounting. No complete visual Swift0.1.121 parity is claimed here.
