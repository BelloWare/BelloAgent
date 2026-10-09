# Activity-ordering r2: Rust LOC audit

Exact published baseline: `1f351cd828ec878e5c0f40b861af5a3a1337c184`; tree `89c3bc6a81a1e5a2c0e11b356683e47ff4fb4269`.
Original 28-path freeze SHA-256: `6796ed5bd63f7066b8a5538ddbc12337bb8a0456635ab5dfabdd794966a7e9e4`.
The source-only candidate reference `6aad4189ff7ee494c837055ae5b3ebe38948cb9c` is not used as the published baseline and is not represented as rust-branch publication.

| Category | Published baseline | Activity-ordering delta | Candidate current |
| --- | ---: | ---: | ---: |
| Production | 50,754 | +950 | 51,704 |
| Tests/support | 70,336 | +1,560 | 71,896 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 122,282 | +2,510 | 124,792 |

All 242 product Rust files are counted once: five added, 22 modified, zero deleted. All 237 baseline product hashes match the published sidebar-status/FIFO audit. The frozen scope is exactly 27 Rust paths and one excluded Markdown document, and all 28 postimages match. Production includes 145 unchanged build-support lines, leaving 51,559 runtime-only production lines. Shared workbench remains counted only under Box.

## Critical classification review

- sidebar_activity.rs: +537 production/+23 support. The positive cfg(test) child declaration 174–176 contributes three support lines. The separate positive cfg(all(test, feature = "synthetic-authority")) helper implementation at 556–575 contributes 20 support lines. Production ranges are 1–173 and 177–555. Platform-specific native/non-native event paths within those ranges remain production.
- sidebar_activity_tests.rs: all 615 physical lines are test-owned, yielding 596 support lines.
- semantic_activity.rs: lines 1–81 production (77 nonblank); positive cfg(test) child declaration 82–84 support (3).
- semantic_activity_tests.rs: all 438 physical lines are test-owned, yielding 424 support lines.
- workspace_activity_tests.rs: all 356 physical lines are test-owned, yielding 347 support lines via workspace.rs:20–22. Existing Topics test declaration shifts exactly to 23–25 without double counting.
- native_menu.rs: +109 production/+60 support. Candidate production range is 1–567 (529 nonblank), including actual macOS code and pure coordinate helpers. The positive cfg(test) module is 568–851 (268 nonblank). Lack of native execution on Linux does not make native implementation test support.
- workspace.rs: +87 production/+4 support; v11 catalog/activity schema and persistence are production, while the new child declaration and added fixture field are support.
- runtime.rs: +29 production for semantic-watermark integration; inherited support classifications remain unchanged apart from line movement.
- shutdown_barrier.rs: +28 production for serialized shutdown persistence. Its existing three-line test declaration remains support.

All other files retain exact source-matching historical classifications. Nonblank physical lines include comments; adjacent non-test comments remain production. `loc-audit.json` records explicit before/after production/support ranges, boundary text, source hashes, changed-hunk category counts, source additions/modifications/deletions and the full independent physical inventory. `REVIEW.md` gives readable per-file detail.

## Existing excluded evidence

The existing formatter oracle and Search/Copy r2 harness remain unchanged: 366 excluded nonblank Rust lines in four files. Their exact baseline Git blobs and current hashes are verified. The duplicate product source inside the old harness is not counted again as product code. Full on-disk reconciliation is 125,158 nonblank Rust lines across 246 files.

No new standalone validation Rust is included in the evidence total or proposed for publication. Independent helper-source copies remain local. The complete before/after product-source snapshots in this local audit directory support reproduction; they are not additional product contributions or a request to publish duplicate source files.

## Portable verification

    python verify.py
    python verify.py --root /path/to/agent-sidebar-activity-integrated
    python verify.py --root /path/to/agent-sidebar-activity-integrated --binary /path/to/bello-agent-default-activity-r2
    python negative-controls.py

Portable and live-source/binary checks passed with no drift. The default binary was independently hashed and matches seal `bcacca7acaf4e17d03119ab999173769f77f238ccdfbc7632cc4c946c385b5a5` (135,640,568 bytes). It is not bundled. The verifier binds exact published commit/tree and Rust blob identities, prior ledger, unchanged original freeze, seal, all postimages, explicit ranges, complete inventory and physical sums.

Ten deliberate corruptions were rejected, including treating the synthetic-test helper as production or the native implementation as support. Reports: verification.json, live-verification.json, negative-controls.json. The original freeze and seal are preserved; source-r1-manifest.json is merely this audit's structured index of the r2 freeze.

Prior audits are preserved. No product edits, Cargo/build commands, screenshots or remote writes were performed. The source-only commit remains distinct from publication. LOC does not certify runtime correctness, platform acceptance, parity, performance or ETA.
