# Synthetic CI fixture ancestry and native diagnostics

Base: `b50a00fd84c0f8289a5daf73c2d4c792096871d2`.

## Established failure and bounded repair

The [exact Linux run](https://github.com/BelloWare/BelloAgent/actions/runs/37957524396)
passed Core/cache privacy checks, then failed synthetic launcher preparation:
`/home` had a real `system.posix_acl_default` value (44 bytes, no errno,
first attempt). Rejecting this ancestor was correct. It was not EINTR.

Only the launcher's `cfg(test)` fixture helper gains an explicitly configured
parent. It verifies canonical private ownership, mode 0700, no-follow traversal,
full ancestor ACL checks and final identity before creating a fixture child.
Production launch/cache admission is unchanged.

Linux CI creates a collision-safe, exclusively new directory beneath `/opt`
after validating existing ancestors. Existing runner sudo is used only to
prepare and clean up the new fixture objects. No existing path's
permissions or ACLs are modified. A bounded marker binds purpose, run, attempt,
UID and GID. Always-run cleanup verifies the marker and held/path identity,
refuses nonregular markers, and uses descriptor-safe recursive removal without
following symlink destinations. Unsafe ancestry still fails the job.

Actual elevated `/opt` setup has not run on the cloud development machine.
Acceptance of the hosted-runner location remains an exact next-CI gate.

## Native failure visibility

The [exact macOS run](https://github.com/BelloWare/BelloAgent/actions/runs/37957524331)
failed Core tests. Its bounded text artifact exists, but artifact materialization
was blocked; decoded full-job logs also failed to return. No macOS failing
assertion or cause is inferred.

The unchanged Core command and its bounded diagnostic-text steps now run after
compile/link and before the unchanged decoder-bundle emission. All original
commands, public-repository guards and successful-run gates remain. This order
improves early-failure observability; it does not establish why prior log
transport failed. No additional job or paid transfer fallback is introduced.

## Source-bound validation

- Fifteen focused fixture tests passed, including real default-ACL rejection,
  unsafe/aliased configured roots, explicit `/` rejection, and existing launcher
  isolation/restart tests.
- Final-source all-feature App aggregate: 837 passed, 3 ignored.
- Default App aggregate: 653 passed, 1 ignored; default strict passed before the
  final added test assertion. That assertion is inside the excluded synthetic
  test module and changes no default compiled source.
- Final all-feature strict checks and formatting passed.
- Python controls passed for real default ACLs, malformed/FIFO markers, wrong
  provenance, exclusive creation, setup-failure rollback and symlink-safe cleanup.
- Two isolated script mutants were killed by the intended assertions: omitted
  real-ACL denial and omitted marker equality. Candidate bytes stayed unchanged.
- Workflow structural checks preserve every original step object and command.
- Every local fixture was removed by provenance-checked cleanup. No local sudo,
  existing-path ACL repair, source/ref publication or GUI claim is part of these
  local checks.

Rust LOC is **64,199 production / 86,961 test-support / 1,192 benchmark** under the
existing verified nonblank-line classifier. This repair changes test-support Rust
only. Production readiness remains closed; native acceptance and exact published
CI success are still separate gates.
