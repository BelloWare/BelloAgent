# Skill source identity: scoped publication candidate

Baseline: `2ffbc323b9ad006683c2fef1eafa23f4990d8da5`, tree
`529ba4b5b54031db5d40c63413f1d1f5df6e3c21`. This record packages a bounded
source correction; it does not establish its publication or passing Apple CI.

## Implementation and retained-input contract

The six-file [source freeze](source-freeze.json) separates Foundation-compatible
new skill path/ID spelling from canonical filesystem identity. Canonical targets
remain authoritative for bounded reads, race checks and deduplication. Source
`baseDir` follows the visited parent, including leaf-file symlinks; `sourceRoot`
retains the pre-visit root spelling. Both spellings must identify the same target.

Only queued delivery can look up a legacy canonical-path-derived ID. Current
discovery must supply one unambiguous target and the exact retained canonical
path/hash. Two IDs cannot select one target. Metadata, policy, dependencies and
existing controller scope checks remain in force. Fresh selection stays strict:
old unsubmitted chips must refresh and explicitly reselect. No frozen skill,
recorded field, receipt, historical expanded byte, Retry carrier or schema is
rewritten. Global instruction and authority path normalization is unchanged.

The [native oracle](../project-skills-native-oracle.md) now asserts exact fresh
skill IDs/paths/base directories/source roots, recorded fields and expansion
across Darwin aliases and leaf/directory/root symlinks, using production-equivalent
workspace roots. Full resource-instruction spelling remains a separate gap.

## Portable evidence and exact scope

- Combined Bash-baseline candidate: **387 unit + 125 integration = 512 default
  core tests passed**, including four new identity tests and 18 skill integration
  tests. Strict all-target core Clippy and workspace fmt also passed. See
  [combined log](logs/combined-default.log) and
  [machine-readable attribution](integrated-validation.json).
- Earlier c0-based candidate: 489 default core tests and strict Clippy/fmt passed.
  Six isolated mutations each failed the intended runtime assertion: legacy
  lookup removal, fresh remapping, duplicate target acceptance, metadata
  revocation removal, source-target check removal and receipt identity bypass.
  [Control hashes/results](detecting-controls.json) retain their original
  attribution and exact restored hashes. The integrated candidate's production
  and test files are byte-identical to that final correction; only its oracle
  Markdown received a validation-limit clarification.
- One earlier Clippy attempt found a test-only cloned-slice warning; it was fixed
  with `slice::from_ref`, followed by a successful full default rerun. That
  cleanup changed no production source or assertions. Historical manifests and
  audit records are preserved verbatim rather than relabeled.

The integrated candidate's full synthetic-authority/all-feature matrix and
Controller provider-Retry/scope regressions were **not rerun locally**. The
portable identity test covers queue reopen, unchanged receipts, retained content
and `Session::retry_turn`; it is not a new provider-dispatch or GUI acceptance
claim. The seventh planned synthetic controller-scope mutation was not run.

## Apple checks and remaining acceptance

The exact new `source_path.rs` passed isolated `aarch64-apple-darwin` metadata
checking against installed Apple Rust std and cached official objc2 bindings.
Only a lightweight Result/error adapter surrounded that unchanged source; the
[helper-check inputs](helper-check/lib.rs.txt) and
[pass log](logs/apple-helper-only-passed.log) preserve this narrow evidence.

The [full-core cross-check](logs/apple-full-core-blocked.log) stopped before the
changed core code: ring's C build used host `cc`, which rejects Darwin `-arch`
and `-mmacosx-version-min` flags. No SDK/toolchain installation or fake native
success was substituted. Neither check executed Foundation, Swift or the native
oracle. Actual Apple CI on the exact published correction remains required.
Native UI, IME, VoiceOver, signing, Keychain/authority and production startup stay
separate gates. No desktop or paid provider requests were used for this correction.
Portable runtime tests use generated loopback traffic.

## Source accounting and documentation overlay

The [rebased immutable LOC report](loc-report.json) records **+72 production /
+429 support / 0 benchmark**, yielding **43,642 / 58,512 / 1,192**, 103,346 total
nonblank Rust lines across 199 files. All 988 preserved nonblank changed-file
lines retain their prior classifications. The baseline bridges remain separate.
The audit's [26 detecting controls](loc-negative-controls.json) and baseline
verifier passed. Source volume is not feature completion or performance.

The [complete LOC archive](loc-audit.tar.gz) preserves every sealed audit file,
including inherited ledgers, report, verifier and evidence. Its original
[README](loc-audit-README.md) and [artifact hashes](loc-artifact-sha256.json) retain
historical paths and source attribution. This evidence/documentation overlay is
separate from the audited six-file source freeze and adds no Rust lines.

The [readiness patch](readiness/readiness-docs.patch) is a separate documentation-
only overlay for `rust/README.md` and `rust/docs/parity.md`. It applied with zero
fuzz to exact baseline preimages and matched its reviewed afterimages. Its
[justification](readiness/SOURCE-JUSTIFICATION.md) and
[original verification](readiness/verification.json) are unchanged. It describes
its audited baseline and does not claim this correction's native acceptance.

## Reproduce publication/source verification

From a checkout retaining the immutable baseline Git objects and this evidence:

```sh
python3 -B rust/scripts/verify-skill-source-identity-final-2026-10-07.py \
  --repo . --after <exact-candidate-commit>
```

Before publication, the same read-only verifier accepts `--overlay /path/to/files`
for the scoped payload. It verifies every baseline preimage and afterimage,
rejects unexpected source changes, reconstructs the historical six-file candidate
in memory, and reruns its immutable LOC verification. It does not build, access
the network, alter Git state, or establish remote publication/CI acceptance.
