# Source UTF-8 integration checkpoint

This checkpoint integrates the reviewed native decoder from PR #3 with the
published model-catalog checkpoint. It preserves the source macOS 14 deployment
floor and all production tool, authority, and vault gates.

## Immutable source lineage

- Published catalog baseline: `cf63b6d6f4007e65fe8e6e23bb211caf75b6e6ba`.
- Peer integration: `4ca6bcb048e9671c52e1950a2ff383089f5d5bfa`.
- Its complete tracked tree was verified as the exact union of the catalog
  baseline and the 18 decoder files from
  `ab624240bd3e4841d06fc149080d7b3bf126d209`.
- Two test-only Bash race repairs were recovered from
  [the peer's report](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6060705396).
  The combined patch SHA-256 is
  `46cd4d80e0b9f1a9f9e932f70895002ef2e9479a94a3e37cf6978fe4eb5ae261`;
  its final `tools/bash_tests.rs` SHA-256 is
  `e941733d14d7bb23e06811ea6439e927608b2c1b76c3974c9ec6165736e353e0`.

The first repair waits for executor occupancy to retire after joining the physical
process registry, retaining the original held-gate and escalation assertions.
The second waits for the complete escaped-process marker payload, rather than
mistaking file creation for payload completion. Neither changes production process
ownership, cancellation, or escaped-process behavior.

## Native validation contract

The macOS workflow explicitly sets `MACOSX_DEPLOYMENT_TARGET=14.0`, pins the
selected `DEVELOPER_DIR` for subsequent steps, and retains the existing native
compile, source-oracle, synthetic authority, app, and own-window smoke gates.

The source decoder's operating-system-sensitive Foundation behavior must be
checked using one immutable modern-built bundle on both the modern host and a
macOS 14 host. An old-host rebuild is useful separate evidence, but does not
satisfy that same-binary requirement. Linux tests cannot execute this adapter.

The bundle includes a release Rust probe, Swift oracle, static bridge, generated
header, build identity, oracle source, and a hash manifest. The modern host writes
a receipt before transport. The bounded transport helper emits only synthetic
bundle data into the CI job log, with whole-archive and per-chunk hashes. It does
not use artifact-storage uploads or a paid fallback. A transport-size failure
remains an explicit blocker.

Recover the bundle using the helper's `decode` command and verify its expected
archive SHA-256 and exact CI source commit. Then run
`validate-source-utf8-macos.py run-bundle` on the recovered directory without
rebuilding. Compare manifest SHA-256 and the complete file hash map across the
two receipts; each host's Rust result must equal its own same-bundle Swift oracle.
Host results need not be identical across operating-system versions.

## Evidence boundaries

The peer reported 585/585 native unit tests after both Bash repairs, plus the
isolated test. That is attributed native synthetic evidence, not a new local
rerun. The earlier 584/1 failure is preserved in the peer discussion.

The prior unpublished local workspace and its validation artifacts were
unavailable during recovery. Source was restored from immutable GitHub objects
and the exact peer patch. Source recovery does not recover missing screenshots
or recreate prior test executions. Fresh validation is recorded separately.

Modern-built same-bundle receipts on both hosts remain pending until recorded.
No interactive native GUI, TCC, AX, Keychain, signing, release, or performance
acceptance is implied. The concurrent-tool migration from main 0.1.121 is a
separate change and is not included in this decoder checkpoint.

## Rust source counts

Compared with the exact published catalog baseline, the decoder adds 75 runtime
Rust lines and 145 build-support Rust lines (220 production-category lines), plus
389 test/support lines. The Bash repairs add 13 test/support lines. Nonblank
physical lines, including comments, total **45,749 production / 62,166
test-support / 1,192 benchmark-example**, or 109,107 lines.

The reviewed per-file delta and before/after hashes are in `loc-audit.json`.
Shared workbench code is counted only in BelloBox, not again in this repository's
Git dependencies. These counts are not parity percentages or delivery estimates.
