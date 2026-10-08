# Topics r1: integrated Rust LOC audit

Exact integration baseline: `ea2e2ed970cacd13d90e40eed5d1aaa3a565bd1a`; tree `4f6ced57637b3979ad4c5ff5dbc0e14025144930`.
Original source manifest SHA-256: `1b9f00fc123b7e268a43cefbd7f06ae892432ce4e8d4382119b590b0dc86d945`.
Original patch SHA-256: `d0bdca53e69d4e4da85e49e1aa8fa01ecf77ed758ff47947efd6dce55f801a0e`.

| Category | Published ea2e2ed9 baseline | Topics delta | Candidate cumulative |
| --- | ---: | ---: | ---: |
| Production | 46,430 | +1,108 | 47,538 |
| Tests/support | 65,148 | +1,038 | 66,186 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 112,770 | +2,146 | 114,916 |

The original Topics manifest records source-worktree base a73f56acdf5847e7a9e34c1cb2aceeb051df0db3. This audit instead compares the integrated candidate against the requested published ea2e2ed9 baseline, preserving its preceding +51 support-only compaction-observer repair. The original manifest and patch are copied byte-for-byte, not rewritten. All 218 baseline product hashes match the prior published audit; all 21 Topics postimages match the original manifest. Patch path scope matches all 21 manifest paths exactly.

There are 223 owned Rust files: five added, 15 modified, zero deleted; one additional changed Markdown document is excluded. Production includes 145 unchanged build-support lines, giving 47,393 runtime-only production lines. Shared workbench is counted only under Box.

## Explicit schema/controller/view/test ranges

Physical ranges are inclusive; nonblank lines including comments count.

| Source | Production range and count | Support range and count |
| --- | --- | --- |
| Core workspace_topics.rs | 1–245; 243 lines | None |
| Core workspace_topics_tests.rs | None | 1–385; 381 lines |
| App topics.rs | 1–221; 219 lines | 222–224; 3-line positive cfg(test) child declaration |
| App topics_tests.rs | None | 1–635; 627 lines |
| App topics_view.rs | 1–446; 445 lines | None |

The core test file is owned by the new positive cfg(test) declaration at workspace.rs:20–22. App topics_tests.rs is owned by topics.rs:222–224. The new schema, production controller and view contain no other test-only spans. Their comments remain production.

Other important deltas: workspace.rs +52 production/+5 support (three-line declaration plus two fixture fields); main.rs +84 production; sidebar_actions.rs +58 production. Sidebar's existing test declaration is mapped exactly from 369–371 to 429–431; platform-only code and the trailing ArchiveVisibilityHint render implementation stay production. Existing exact-blob support classifications are retained for all other changed files. Adjacent non-test comments and platform-or-test production ownership are unchanged.

`loc-audit.json` contains explicit before/after production and support ranges for every changed file, their boundary text and hashes, changed-hunk counts, path additions/modifications/deletions, and the full physical inventory. `REVIEW.md` provides readable per-file details.

## Evidence reconciliation and verification

The 73-line standalone formatter oracle remains unchanged, hash-verified and separately excluded under published documentation/evidence scope. Including it only for full on-disk reconciliation gives 114,989 nonblank Rust lines across 224 files.

Portable stdlib-only checks passed:

    python verify.py
    python verify.py --root /path/to/agent-topics-integrated
    python negative-controls.py

The verifier binds the exact integration baseline commit/tree and product blobs, preceding ledger, unchanged original manifest and patch, all 21 postimages, exact source-path scope, complete product/evidence inventory, all production/support ranges and category arithmetic. Full baseline/candidate Rust snapshots and classification evidence are bundled. Seven deliberate corruptions of totals, support boundary, source bytes, manifest, base tree, inventory or patch were rejected. No source drift was detected.

Reports: `verification.json`, `live-verification.json`, `negative-controls.json`. Extraction scripts are environment-specific; the verifier is portable. Prior audits are preserved. No source edits, builds or remote writes were performed. Clean full validation gates are independent and were running when this audit was requested. No parity, correctness, performance or ETA inference is made.

## Repository scope

This summary, loc-audit.json, LOC-REVIEW.md and loc-verification.json are published. Full local snapshots and verifier scripts referenced above are retained separately. Final runtime tests and actual GUI observations have independent receipts.
