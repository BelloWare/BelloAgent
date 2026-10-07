# Project-only picker skills: LOC review

Status: **source frozen; publication and final acceptance pending**. The
integration owner confirmed the freeze on 2026-10-07. Exact source hashes bind
these counts to that freeze; a later source change requires another review.

Baseline: published Darwin test-socket correction
`110cde32753930599b2e10d76388bcffcf23624e`, tree
`fc7b6081d08544282a711078d54f23e1dbf6019c`: 38,796 production, 53,044 test and
test-support, and 1,189 benchmark/example nonblank Rust lines, totaling 93,029.

The original audited attachment anchor
`38a9d1f3efc414eb018a5a170cc01acfbc52aacd` (tree
`28da463ee997e3fada3dfd0817264e41d10423b4`) passed the existing attachment LOC
verifier. The ledger explicitly verifies three published baseline bridges:

- `38a9d1f` → `af1ce5f7567b67358db03fd56339bce1c83bcb3f` (tree
  `b3f558ca185153e60c5fe82227fad009c7b2424b`): +19 support lines in the native
  attachment oracle.
- `af1ce5f` → `a890af0`: +25 production and +174 support lines in the MCP
  admission correction. The raw +181 support diff includes seven blank lines.
- `a890af0a7797197ee5eee4a538098eabbed2a492` (tree
  `8bfe718df279f5131c5b280ce1342ab48243e971`) → `110cde3`: +39 support lines
  in four app test files. Production and benchmark source volumes are unchanged.

Each bridge records exact source blobs/SHA256s, committed prior classifications,
reviewed support spans, preserved lines, changed spans and its committed review
document. The verifier checks parent/tree identity and independently recounts
complete Rust totals at each checkpoint.

The frozen project-skills ledger records:

- Production: 42,590 (+3,794)
- Tests and test support: 56,228 (+3,184)
- Benchmarks/examples: 1,192 (+3)
- Total: 100,010 across 189 Rust files; 86 changed and 103 unchanged

These are physical nonblank lines, including comments. They measure source
volume, not feature parity, completion percentage or performance.

## Preserved classification

The ledger inherits the audited baseline, exact-blob prior support spans, and
the positive-cfg convention: support begins at the attribute; preceding comments
keep their existing category. Whole test/explicit-fixture modules are support;
ordinary saved-runtime project-resource and picker code is production. Platform
gates alone are not test classification.

Only added/deleted spans contribute to the delta. Equal nonblank lines under the
existing `SequenceMatcher(autojunk=False)` method keep their original category.
The verifier checks all 55,959 such lines in changed files, and all 103 unchanged
Rust blobs retain their audited classification. Two repeated Context closing
delimiters align with inherited support lines in this exact diff. They remain
support for accounting, explicitly recorded as inherited adjustments; a fresh
whole-file syntax recount would shift two lines to production. The unchanged
`instructions.rs` test tail at baseline lines 274–289 was reviewed directly,
as were the wholly test-owned `read_synthetic_tests.rs` and integration
`tests/production_tools.rs` files, because no previous full-file span entries
existed for those baseline blobs. Their existing categories are preserved.

The MCP baseline bridge has one explicit source-reviewed alignment anchor:
`mcp/outcome.rs`'s original production method terminator stays at line 158 on
both sides. Without that anchor, repeated-brace matching would pair it with a
new test-helper terminator. Pinning the actual unchanged source location
preserves classification and the published +25/+174 correction. This bridge-only
disambiguation does not change the skill delta method. The inserted MCP tests
remain inherited support in the rebased skills source.

The JSON preserves each baseline/final Rust file's Git blob, SHA256 and nonblank
total, exact span anchors, prior committed-ledger provenance, preserved-line
mapping, changed-span hashes, per-file deltas and independently recounted totals.
It does not require a parser, Cargo, network access or checkout changes to verify.

## Reproduce

For the staging directory, before publication:

```sh
python3 rust/scripts/verify-loc-project-skills-2026-10-07.py \
  --repo /path/to/BelloAgent-with-baseline-history \
  --source-root /path/to/staging --after WORKTREE
```

After publication, use the exact publication revision from a clone containing
the baseline history:

```sh
python3 rust/scripts/verify-loc-project-skills-2026-10-07.py \
  --repo . --after EXACT_PUBLISHED_COMMIT
```

The latter also verifies baseline ancestry. Publication identity stays pending
in this same-checkpoint ledger to avoid a self-referential commit hash; the
verifier prints the resolved after-commit. The frozen source manifest is
`d5402de8e36c31ae70d245e78624dc3ca9efa7bf9ddb7d110f8eeac259f8d9f4`.

Candidate 1 remains separately archived, unchanged: ledger SHA256
`8a1caf2dca8c32b192ef8bc5c3a762f51123412621ff37aea750e90c6d0820f1`, source
manifest `857d1fcb772f3799da8496b5568243fea2dee7a2341f9f41bc603ce18b8bffbf`.
The verifier checks that the production/benchmark skill delta is unchanged and
that the only subsequent slice delta is the explicitly recorded +61 support
lines below. Candidate-1 build/GUI evidence is not a candidate-2 acceptance result.

Candidate 2's pre-socket-fix ledger is also archived unchanged: SHA256
`412da3994046adffb3b66ec1fba9dd47cc32d1f805d8c7e4a5df5fdb3112ab50`, source
manifest `9aaf4c1572c4d5460ba80e10f1c74addc060284211b383df75c9589061ca8482`.
Its complete Rust manifest is retained in this ledger. The verifier permits
exactly five changed test files and accounts for the changes separately:

- Published-baseline correction: `connection_settings_controller_tests.rs`,
  `mcp_inspector_controller_tests.rs`, `transcript_read_native_ui_tests.rs` and
  `transcript_edit_native_ui_tests.rs`, totaling +39 nonblank support lines.
- Slice-owned, post-build oracle correction: `core/tests/project_skills_native.rs`,
  +61 support lines (358 → 419). The exact ID/expansion equality matrix now uses
  repository-target temporary resource paths. The same bounded Swift process
  separately characterizes Darwin aliases without claiming cross-language
  path-derived-ID or expansion-byte parity for those aliases.

Runtime source is unchanged. The existing candidate-2 GUI binary keeps its
original source attribution. See the separately maintained
[acceptance record](project-skills-2026-10-07.md) for GUI and platform results;
LOC verification does not establish those results.

Verifier checks passed for this frozen manifest. Negative controls rejected a
changed source SHA256, a reclassified unchanged nonblank line, an altered
baseline-bridge delta, an incorrect bridge alignment anchor and reclassified
inserted MCP tests. These are checks of the LOC evidence tooling, not application
acceptance or a final regression result.
