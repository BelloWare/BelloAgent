# Sidebar restored run-state and read-only FIFO repair: Rust LOC audit

Published baseline: `e2a67c855442a22a24d71a26707df425c5fe277f`; tree `904ddb2772351fda32a00d04dd9afb8398c8ae16`.
Original changed-files manifest SHA-256: `d43c411f8084f6bb0976d9a72d32d8d476bc877d3ad95776556b0bb848dd5840`.

| Category | Published baseline | Candidate delta | Candidate current |
| --- | ---: | ---: | ---: |
| Production | 50,464 | +290 | 50,754 |
| Tests/support | 69,739 | +597 | 70,336 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 121,395 | +887 | 122,282 |

All 237 owned Rust files are counted once: three added, three modified, zero deleted. All 234 baseline product hashes match the preceding Search/Copy r2 ledger. All seven frozen paths (six Rust and one excluded Markdown document) match original preimages/postimages, overlay, full build-source manifest and patch scope. Production includes 145 unchanged build-support lines; runtime-only production is 50,609. Shared workbench is counted only under Box.

## Explicit ownership and per-file delta

- sidebar_run_state.rs: lines 1–287 production, 278 nonblank lines; positive cfg(test) declaration at 288–290 adds three support lines. Platform-only Unix branches remain production.
- sidebar_run_state_tests.rs: entire positive-test-owned module, lines 1–487, adds 473 support lines.
- main.rs: -6 production; its inherited support ranges are unchanged apart from mapped positions.
- session.rs: +10 production for the regular-file metadata/open helper refactor; inherited test ranges are unchanged apart from mapped positions.
- stream_journal.rs: +8 production/+3 support. Baseline inline-test span 175–226 maps to 184–235. The new positive cfg(test) declaration at 237–239 owns the FIFO inspection test module; other lines remain production. Existing Unix synchronization is production, not test support.
- stream_journal_inspection_tests.rs: whole positive-test-owned module, lines 1–123, adds 118 support lines.

Nonblank physical lines include comments. Exact historical category ownership is retained. `loc-audit.json` records explicit before/after production/support ranges with boundary text, SHA-256 values, hunk counts, additions/modifications/deletions and the full physical inventory. `REVIEW.md` provides readable per-file detail.

## Evidence-only Rust

The published tree contains the prior formatter oracle (73 lines) and r2 Search/Copy harness (293 lines), totaling 366 excluded validation lines in four Rust files. Their hashes and counts are verified against the baseline Git blobs and the preceding audit's separate evidence ledger. The exact product-source copy in the harness is not counted again as product code. Full on-disk reconciliation is 122,648 nonblank Rust lines across 241 files.

## Freeze and review binding

The sealed default-feature binary was independently hashed and matches `222173280c9d25378c7d8955206197c89a84aa25980ad5f8a964158953a62de0`. It is not bundled. The seal's original changed-files and full source-manifest hashes match, and all product/evidence Rust postimages match the build-source manifest.

The independent review is preserved unchanged as historical evidence. Its sidebar_run_state_tests.rs hash is older (`a3035dc9da4e9ca65504d9e9bad3e360f735280c1a5ae1b97dab9ac4e74b1a1c`) than the frozen final test source (`f4ed6611c60ea0f023128713b689592528237e65183db639919e906b6a6c60aa`). Its other five source hashes match. This mismatch is explicitly recorded in the ledger; the review is not represented as a full current-source binding. It does not affect the independently verified final LOC counts or source seal.

## Portable checks

    python verify.py
    python verify.py --root /path/to/agent-sidebar-run-state
    python verify.py --root /path/to/agent-sidebar-run-state --binary /path/to/bello-agent-sealed --overlay /path/to/overlay
    python negative-controls.py

Portable and live/overlay/binary checks passed, with no source drift. Ten deliberate corruptions of totals, test boundaries, source, manifest, baseline tree, inventory, patch, seal or full build binding were rejected. Full baseline/candidate product snapshots, original evidence records and excluded Rust copies are bundled. Reports: verification.json, live-verification.json, negative-controls.json.

Previous audits are preserved. No product edits, Cargo/build commands, screenshots or remote writes occurred. LOC does not certify runtime correctness, native acceptance, performance, parity or ETA; those remain separate gates.
