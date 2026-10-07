# BelloAgent source-path identity: integrated Bash-baseline LOC audit

Verified 2026-10-07 UTC against the isolated integrated source freeze. This supersedes the earlier candidate totals for use with baseline 2ffbc323, while preserving that earlier audit unchanged as historical evidence. No source edits, builds, functional tests, desktop operations, Git changes or publication were performed by this audit.

## Result

| Category | Published Bash baseline 2ffbc323 | Source-path delta | Integrated candidate |
|---|---:|---:|---:|
| Production | 43,570 | +72 | 43,642 |
| Tests and test support | 58,083 | +429 | 58,512 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Total | 102,845 | +501 | 103,346 |

The integrated candidate has 199 Rust files: two modified, two new, and 195 unchanged. All 988 preserved nonblank lines in the changed files retain their categories: 579 production and 409 test/support. No unchanged span was reclassified.

## Per-file accounting

Paths are relative to rust/crates/bello-agent-core/.

| File | Before production / support | After production / support | Production delta | Support delta |
|---|---:|---:|---:|---:|
| src/project_resources.rs | 587 / 0 | 624 / 2 | +37 | +2 |
| src/project_resources/source_path.rs | 0 / 0 | 35 / 0 | +35 | 0 |
| src/project_resources/identity_tests.rs | 0 / 0 | 0 / 303 | 0 | +303 |
| tests/project_skills_native.rs | 0 / 419 | 0 / 543 | 0 | +124 |

These four complete file records, including their exact before/after hashes, classification spans, preserved spans and changed-line attribution, are identical to the earlier c0df340-based audit.

- project_resources.rs:23–24 is the positive `cfg(all(test, unix))` attribute and its private test module declaration. Both lines are support. Line 25, `mod source_path;`, remains production.
- source_path.rs:1–36 is production: 35 nonblank lines including documentation and platform branches. macOS/non-macOS gates are platform gates, not test gates.
- identity_tests.rs:1–309 is the private test-only module gated above: 303 nonblank support lines, including fixture helpers.
- project_skills_native.rs:1–545 is a Cargo integration-test target: 543 nonblank support lines, including its macOS-only attribute.
- Before-side classifications for the two modified files match exact immutable Skills-ledger source blobs, which remain unchanged through the published Bash baseline.

## Immutable baseline chain

The historical Skills ledger remains byte-identical, with totals 42,590 / 56,228 / 1,192. The historical Bash ledger also remains byte-identical, with totals 43,570 / 58,052 / 1,192. Their original publication metadata has not been rewritten.

The historical Bash Rust manifest differs from published 2ffbc323 in exactly two test files:

1. transcript_read_native_ui_tests.rs: +11 support lines from the already-published native Read correction.
2. compaction_runtime_tests.rs: +20 support lines from the explicit compaction publication-settlement barrier.

These bridge additions give the published baseline 43,570 / 58,083 / 1,192. The new audit records both bridges separately, including hashes, inherited whole-test classifications, preserved spans and changed-line deltas. It does not charge those 31 lines to the source-path correction. The compaction test module's positive cfg(test) gate is checked; the tracked final Bash verifier also verifies the native Read test-module chain.

The exact published-baseline final Bash verifier was independently rerun against 2ffbc323 and passed. It re-verifies the original Bash source freeze, classifications and source carry. The result is saved as published-bash-baseline-verification.json. This is a source/LOC verification, not a build or functional-test pass.

All 12 sealed artifacts in the earlier c0df340 audit directory were rehashed and remain unchanged; see historical-audit-preservation.json. Its entire machine ledger is retained here as historical-c0-source-path-audit.json and pinned by the new verifier. The four Rust patch records are required to equal that historical audit exactly. Five of the six frozen patch files have identical postimages to the earlier freeze; only the oracle-validation Markdown changed to describe Apple validation limits. That Markdown remains excluded from Rust LOC.

## Source identities

- Baseline commit: 2ffbc323b9ad006683c2fef1eafa23f4990d8da5
- Baseline tree: 529ba4b5b54031db5d40c63413f1d1f5df6e3c21
- Integrated candidate: /workspace/shared/agent-skill-path-integrated-2ffbc323
- Original final manifest: /workspace/shared/agent-skill-path-integrated-manifest.json
- Exact manifest copy: frozen-six-file-manifest.json
- Six-file manifest SHA-256: 0a9f8d4edac1b664b6d917727683f61cdb31da5d19fba05de43c9a026f889c31
- Baseline full-source manifest SHA-256: adcffe9c00ccbf1fc37dc325ed632e46c56e30f8e316834ce33331bc6ce5cad8
- Candidate full-source manifest SHA-256: ed2135584530b8cca2ade657d3d9296502de2c45df07ce624c25ada70fef48d8
- Baseline Rust-only manifest SHA-256: 6c98db87d7fd1d5a18bb0e50e51ff176114bb8c3ca8849576b47592a0651507f
- Candidate Rust-only manifest SHA-256: 03d3440a41cf198f6dfcfcabcb13c3d9f8952980d9a53c9236ad007083c01d66

All 1,847 baseline files and 1,849 candidate files were hashed. The exact source difference is the six-file manifest: four Rust files, one Swift oracle, and one Markdown validation document. No unexpected/missing source file was found. Per-entry metadata includes Git-blob SHA-1, SHA-256 and byte length; Rust entries also include nonblank count. Digest input is sorted-key compact JSON. These manifest schemas include byte lengths, so their digests intentionally differ from older manifests that omitted lengths.

Only owned rust/**/*.rs is counted, using nonblank physical lines including comments. Swift, logs, recovery.rs.txt, documents, dependencies and build output are excluded. Shared workbench is counted only under BelloBox; no workbench delta is added here. The two changed non-Rust files are checked for source identity but contribute zero Rust LOC.

## Reproduce

With Python 3, the exact candidate directory, and a repository containing the published baseline/Skills trees and inherited bridge blobs:

```sh
python3 -B /path/to/audit/verify-skill-path-loc.py \
  --repo /path/to/BelloAgent \
  --source-root /path/to/agent-skill-path-integrated-2ffbc323
```

The verifier defaults to the immutable baseline tree. `--baseline-ref 2ffbc323b9ad006683c2fef1eafa23f4990d8da5` is also supported, but any supplied reference must resolve to exactly 529ba4b5b54031db5d40c63413f1d1f5df6e3c21. A different tree or a blob object is rejected. The main verifier does not need unpublished local commit aliases.

The candidate must match the complete exact freeze, including the two non-Rust files. If audit artifacts are later added to a published snapshot, that is a different full-source snapshot and needs separate publication/source attribution.

Run the controls:

```sh
python3 -B /path/to/audit/test-loc-negative-controls.py \
  --repo /path/to/BelloAgent \
  --source-root /path/to/agent-skill-path-integrated-2ffbc323
```

All 26 negative controls and two positive controls pass. Rejections cover source changes, added/missing Rust, Swift/Markdown drift, unrelated source drift, invalid baseline object/tree, immutable Skills/Bash ledger drift, historical source-path audit drift, bridge/preimage/classification tampering, altered counts/provenance/spans, a self-consistent production-helper reclassification, false publication metadata and unchanged-line reclassification. Controls mutate source only in memory. The positive controls cover the baseline commit/tree alias and the blank-line/comment convention.

To rerun the tracked published-baseline verifier from a checkout that retains the original validation scripts and evidence:

```sh
python3 -B /path/to/BelloAgent/rust/scripts/verify-loc-bash-final-2026-10-07.py \
  --repo /path/to/BelloAgent \
  --after 2ffbc323b9ad006683c2fef1eafa23f4990d8da5
```

Its script SHA-256 is a8a18ee7339b6865e8f5523afccd9e488494a072208da1211ceecacea75c62b4. historical-verify-bash-final.py is a byte-identical forensic copy; run the tracked script in its repository layout because it uses relative validation-evidence paths.

A separate raw byte-line inventory independently recomputed 102,845 → 103,346 nonblank Rust lines across 197 → 199 files, agreeing with the +501 category total. See independent-count-check.json.

## Main artifacts

- loc-skill-source-path-delta.json: complete manifests, baseline bridge, per-file/per-span evidence and totals.
- verify-skill-path-loc.py, verification.json: reproducible read-only verifier and result.
- test-loc-negative-controls.py, negative-controls.json: controls and results.
- immutable-prior-skills-ledger.json, immutable-prior-bash-ledger.json: preserved historical ledgers.
- historical-c0-source-path-audit.json, historical-audit-preservation.json: unchanged previous audit and preservation proof.
- published-bash-baseline-verification.json: independently rerun exact baseline verification.
- per-file-counts.csv, independent-count-check.json: tabular delta and separate physical count.
- frozen-six-file-manifest.json, artifact-sha256.json: frozen source identity and final artifact hashes.

This is source-volume/provenance evidence only. It establishes no functional parity, GUI/macOS acceptance, performance/memory result, completion percentage or candidate publication. Remote publication was not queried by this audit; local immutable Git identities were verified.
