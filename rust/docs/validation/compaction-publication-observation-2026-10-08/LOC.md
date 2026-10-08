# Test-only compaction observer repair: Rust LOC audit

Exact published base: `a73f56acdf5847e7a9e34c1cb2aceeb051df0db3`; tree `fe00046cf3eb3122d283de274cf513b72d291159`.
Frozen source manifest SHA-256: `6b4f5edda18cfb88897710dfe44986b3c14a4c35e8b00144053834489ef21fb4`.

| Category | Published baseline | Repair delta | Current candidate |
| --- | ---: | ---: | ---: |
| Production | 46,430 | 0 | 46,430 |
| Tests/support | 65,097 | +51 | 65,148 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 112,719 | +51 | 112,770 |

All 218 owned Rust files were inventoried: runtime.rs modified, the other 217 unchanged, no additions or deletions. All baseline product hashes match the preceding published repair ledger. The sole changed source matches the frozen manifest. Production includes 145 unchanged build-support lines; runtime-only production is 46,285. Shared workbench remains counted only under Box.

## Positive test-region proof

There are exactly two insertions in `rust/crates/bello-agent-core/src/runtime.rs`:

- Candidate lines 422–425: four nonblank support lines inside `test_has_active_worker`, owned by the positive `cfg(all(test, feature = "synthetic-authority"))` span 420–427. This adds the publication-barrier mutex acquisition and its explanatory comments.
- Candidate lines 1129–1176: 48 physical lines, 47 nonblank support lines, inside `edit_status_tests`, owned by positive `cfg(test)` span 1065–2461.

Removing just these two inserted regions exactly reconstructs the baseline runtime.rs bytes and SHA-256. The production-only source projection is byte-for-byte identical before/after. These checks go beyond a zero net production count: no production replacement is hidden by offsetting additions/deletions. The independent proof is in `test-only-proof.json` and reproduces with `python verify-test-only.py`.

Nonblank physical lines include comments. Exact historical support classifications, positive test spans, and synthetic-only ownership are retained. Per-file hashes, inclusive support ranges with boundary text, changed-hunk category counts and the full inventory are in `loc-audit.json` and `REVIEW.md`.

## Evidence and verification

The separate 73-line generated formatter oracle remains unchanged and excluded from product totals. Full on-disk Rust reconciliation including this evidence is 112,843 nonblank lines across 219 files.

Portable checks passed:

    python verify.py
    python verify.py --root /path/to/agent-compaction-ci-fix
    python verify-test-only.py
    python negative-controls.py

The complete baseline/candidate product source snapshots, exact Git commit/tree binding, prior ledger, classification evidence, frozen manifest and unchanged oracle are bundled. Six deliberate corruptions of counts, support boundaries, source bytes, manifest, baseline tree and inventory were rejected. Live verification found no drift. Reports are `verification.json`, `live-verification.json`, `test-only-proof.json`, and `negative-controls.json`.

Prior audits are preserved. No source edits, builds or remote writes were performed. The focused selector result and pending full clean gates are separate from this audit. The figures make no parity, runtime correctness, performance or ETA claim.

Repository scope: this summary, loc-audit.json, LOC-REVIEW.md and loc-verification.json are published. Full local snapshots and verifier scripts referenced above are retained separately. The runtime test results and controlled-regression scheduling caveat are independently documented in README.md.
