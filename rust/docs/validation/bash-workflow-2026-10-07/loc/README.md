# BelloAgent Bash: independent frozen-source LOC audit

Status: independently verified, read-only, 2026-10-07 UTC. Baseline and candidate publication remain unverified. No builds, Cargo, desktop operation, source edits, or Git-state changes were performed for this audit.

## Result

| Category | Skills baseline | Bash delta | Frozen candidate |
|---|---:|---:|---:|
| Production | 42,590 | +980 | 43,570 |
| Tests and test support | 56,228 | +1,824 | 58,052 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Total | 100,010 | +2,804 | 102,814 |

The candidate contains 197 Rust source files: 21 changed files (13 modified, 8 new) and 176 unchanged files. All 17,244 preserved nonblank lines in changed files retain their inherited category: 8,155 production and 9,089 support. No unchanged nonblank line was reclassified.

## Source identity

- Original local baseline commit: `b44e47c9a4ad882431c567889df72c35fe574da8`. This audit does not describe it as published.
- Required immutable baseline tree: `e41551e2cdc390c040820870eede7fdd2d4363ce`.
- Frozen manifest: `agent-shell-rebased-files.json`, SHA-256 `0129e22e28ac05f2c610804dc6d1bdde366f98ff4e2d6243addcdfc4dca546e4`.
- Baseline Rust manifest SHA-256: `d5402de8e36c31ae70d245e78624dc3ca9efa7bf9ddb7d110f8eeac259f8d9f4`.
- Candidate Rust manifest SHA-256: `74fcbe4cfd34dfce465afdf088c2e92576c5b263efa224f7bdaa5a17b8c5079e`.

Every one of the 1,768 manifested candidate files was SHA-256 checked. Every one of the 1,757 immutable baseline blobs was checked against the freeze's baseline manifest. The exact difference is the frozen 25-file change set, including 21 Rust files and four non-Rust files. There are 11 new files overall and no deleted source files.

One generated Python cache file is present outside the source manifest: `rust/fixtures/__pycache__/bash_workflow_fixture.cpython-312.pyc`, SHA-256 `db8ad27c9aeff6951a9cd5a3c1fd2909ea890421553f43b0bca417b487e800bb`. The task owner confirmed it came from the earlier fixture `py_compile` check. It is excluded from the deliverable and Rust count and was left untouched. `.git`, `target`, and generated `__pycache__/*.pyc` are not source inputs. Any other extra source file is rejected.

## Counting and classification

Count nonblank physical lines in `rust/**/*.rs`, including comments. Shared source is counted once per repository path. Do not count dependencies, build outputs, Python/shell scripts, Cargo metadata, Swift, Markdown, or images. Benchmark/example files remain separate.

Before-side classifications are inherited only from committed ledgers that identify the exact same Git blob. Positive test-only spans start at their attribute. Whole test modules and Cargo integration tests count as support. Platform-only gates and shared production composition remain production. All changed source and new positive test-only spans were reviewed; the new `tools/bash.rs` and `live_tool_runtime.rs` modules and all six new test files received a separate source review.

No new Bash mixed production-feature/test gate was classified as support. There is one inherited methodology nuance: the unchanged baseline already treats explicit generated-image fixture spans under `cfg(any(test, feature = "synthetic-authority"))` as support, notably `attachment_runtime.rs:263–268` and `tools/attachment_images.rs:37–54`. These exact-blob fixture classifications are intentionally preserved. This audit does not silently recategorize baseline code.

The two named inherited exceptions have these exact source identities (the ledger also records range text hashes and committed classification provenance):

- `rust/crates/bello-agent-core/src/attachment_runtime.rs:263–268`: 6 nonblank support lines; Git blob `c6f7435f6d99da9d94beb44f2570bc1b893a399a`; file SHA-256 `7f68966c1df362c3e91573988c6a3e1df2d87329e6d49263f812c30319fd9410`; range text SHA-256 `963c6055235499996495301f337f5358a49384bf4fe995e0f4347a84639fb36d`.

- `rust/crates/bello-agent-core/src/tools/attachment_images.rs:37–54`: 18 nonblank support lines; Git blob `75710003d7e48d9f74cd8c118edb4c6d1e2eb485`; file SHA-256 `80d2e8c8e261d97c81263a77ed52f4d2f571ce430af5ab713fb32af41febe5ca`; range text SHA-256 `74e8aab17df5b62af934aed8276e34c1523fd00f9696ad4243c3cd7060eb6b7d`.

These are inherited synthetic-fixture exceptions, not newly proved universal rules for feature/test gates. Any deliberate baseline policy reconciliation belongs in a separate audit; it must not be charged to the Bash-only delta.


The preserved-line accounting uses `SequenceMatcher(autojunk=False)`. Every equal nonblank line retains its old category. Changed spans alone contribute to the delta. Endpoints, source hashes, per-file counts, preserved spans, changed spans, aggregate totals, and both full Rust manifests are independently recomputed.

## Verification and portability

The Bash verifier requires only Python 3 and Git. It reads immutable Git objects and the frozen directory. It does not write source or Git state. Run from any directory, adjusting the repository and candidate paths:

```sh
python3 -B /path/to/audit/verify-loc-bash-workflow-2026-10-07.py \
  --repo /path/to/BelloAgent \
  --source-root /path/to/frozen-bash-candidate
```

The default baseline lookup is the immutable tree, not the unpublished local commit. In a future clone where the API-created commit has a different SHA, pass that revision if desired:

```sh
python3 -B /path/to/audit/verify-loc-bash-workflow-2026-10-07.py \
  --repo /path/to/BelloAgent \
  --source-root /path/to/frozen-bash-candidate \
  --baseline-ref ACTUAL_BASELINE_REVISION
```

The supplied revision must resolve to exactly `e41551e2cdc390c040820870eede7fdd2d4363ce`; another valid tree or a blob object is rejected. The original local baseline commit need not exist for the Bash verifier. `--after EXACT_REVISION` can replace `--source-root` to verify a Git snapshot only if its full source file set matches this exact freeze; it does not establish remote publication. An API commit identity must be verified separately, then recorded as separate publication evidence.

The original Skills verifier was independently rerun against the immutable local baseline and passed. Its original script, exact ledger, and result are included as `verify-baseline-project-skills.py`, `baseline-project-skills-ledger.json`, and `baseline-skills-independent-verification.json`. That historical verifier retains its original commit-history dependencies. The portable Bash verifier checks the exact Skills ledger, baseline source manifest, and inherited category records from the required tree; it does not claim to rerun the complete prior Skills verification in every future clone.

All 18 negative controls passed. They detect changed, added, or missing source; non-Rust fixture drift; baseline drift; category/count/provenance tampering; changed/preserved evidence tampering; support-anchor errors; self-consistent unauthorized reclassification; false publication metadata; wrong baseline object/tree; and equal-line reclassification. Source changes for controls exist only in memory. Reproduce:

```sh
python3 -B /path/to/audit/test-loc-bash-negative-controls.py \
  --repo /path/to/BelloAgent \
  --source-root /path/to/frozen-bash-candidate
```

The negative-control runner's matching-local-commit and earlier-baseline checks use this audit's historical objects, unlike the portable main Bash verifier.

## Artifacts

- `loc-bash-workflow-2026-10-07-delta.json`: completed machine-readable audit with exact source manifests and all per-file evidence.
- `verify-loc-bash-workflow-2026-10-07.py`: portable read-only verifier.
- `bash-independent-verification.json`: successful tree-based verification output.
- `test-loc-bash-negative-controls.py`, `bash-negative-controls.json`: tamper-detection checks and results.
- `independent-source-verification.json`, `independent-classification-review.json`: source-inventory and classification review evidence.
- `reviewed-support-ranges.json`: frozen reviewed span registry, pinned by the verifier.
- `bash-loc-per-file.csv`: 21-file category comparison.
- `artifact-sha256.json`: hashes of completed deliverables.

Earlier `prepare_audit.py`, `review-source.diff`, `baseline-classification-review.json`, `mapped-support-review.json`, and `baseline-skills-verification.json` are retained as draft/history evidence. They are not the independent verification result.

## Limits and functional status

This is a source-volume and provenance audit. It establishes no completion percentage, ETA, speed, memory result, functional parity, GUI acceptance, macOS acceptance, or remote publication.

The task owner reported candidate-2 core checks at 508 default-feature tests and 661 all-feature tests, and app checks at 551 passed / 3 ignored, before the final test-only Skills baseline carry. Those runs were not repeated or independently inspected in this read-only audit. They must not be presented as a final-candidate full pass. GUI verification and the macOS Swift source-oracle acceptance remain pending.
