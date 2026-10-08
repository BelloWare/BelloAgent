# Context rejection recovery: Core r3 / App r2 Rust LOC audit

Exact published baseline: `3a566ae58ee334c3b317a47ce099306c0d6535b5`; tree `aea95773bda0991946d86b7523a4d612860ed2e8`.
Original Core r3 manifest SHA-256: `619eccd739fc010350d9b138e75128fba37ad1e2237a9639052534e8e6de54e8`.
Original App r2 SHA256SUMS SHA-256: `e451143d03c3015fccdf221bbc703893af4770ee8c638fbbc339e6c7b98c397f`.

| Category | Published Topics baseline | Recovery delta | Candidate cumulative |
| --- | ---: | ---: | ---: |
| Production | 47,538 | +1,828 | 49,366 |
| Tests/support | 66,186 | +2,702 | 68,888 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 114,916 | +4,530 | 119,446 |

Core contributes +1,658 production/+2,193 support. App contributes +170 production/+509 support. The candidate has 229 owned Rust files: six added, ten modified, zero deleted. All 223 baseline product-source hashes match the prior published Topics ledger. All 12 Core r3 and four App r2 postimages match their original freeze records, and no other product Rust path changed. Production includes 145 unchanged build-support lines, leaving runtime-only production of 49,221. Shared workbench is counted only under Box.

## Reviewed ranges and ownership

- Core `context_recovery.rs`: lines 1–744 production (736 nonblank); positive cfg(test) module 745–1348 support (603).
- Core `provider_failure.rs`: lines 1–270 production (263); positive cfg(test) module 271–447 support (177).
- Core `context_recovery_runtime.rs`: 430 production / 16 support. Support spans are 35–38 (synthetic-only resource refusal), 72–73, 175–177, 179–180, 238–239 (positive cfg(test) pause seams), and 450–452 (test-module declaration). All complementary ranges are production. The adjacent comments on lines 33–34 remain production.
- Core `context_recovery_runtime_tests.rs`: all 714 physical lines are test-owned, yielding 696 support lines through the preceding positive cfg(test) declaration.
- Core `context_recovery_mcp_tests.rs`: all 478 physical lines are test-owned, yielding 474 support lines through runtime.rs:1–3 positive cfg(all(test, feature = "synthetic-authority")). The new declaration itself adds three support lines; the separate runtime-module declaration adds two production lines.
- App `context_recovery_feedback_tests.rs`: all 515 physical lines are test-owned, yielding 506 support lines through compaction_actions.rs:288–290. The declaration adds three support lines.
- App `compaction_actions.rs`: +163 production/+3 support. Existing support declaration maps to 253–255. Production labels and usage projection after that declaration are not swept into support; only the new three-line declaration at 288–290 is support.
- Core `provider.rs`: +67 production/+221 support, with the existing positive cfg(test) module mapping to 595–900.
- Core `tool_runtime.rs`: +60 production/+3 support, with the new positive cfg(test) pause seam at 526–528. All existing support spans are inherited and mapped.

Nonblank physical lines include comments. Existing exact-blob category ownership is preserved; no filename heuristic or broad cfg-substring classifier is used. `loc-audit.json` records explicit before/after production and support ranges, boundary text, hashes, per-file and changed-hunk counts, additions/modifications/deletions, and the full independent physical inventory. `REVIEW.md` provides readable per-file detail.

## Freeze binding and portable verification

The original Core manifest and App SHA256SUMS are preserved unchanged. `source-r1-manifest.json` is the audit's combined 16-path index, derived from those originals; it does not replace either freeze. The verifier checks that its path/hash map exactly equals their disjoint union.

    python verify.py
    python verify.py --root /path/to/agent-context-recovery
    python negative-controls.py

Portable and live-source checks passed. The verifier binds the baseline Git commit/tree and product blobs, prior ledger, both original freeze records, all candidate postimages, exact source inventory, explicit production/support ranges and category arithmetic. Full baseline/candidate product source snapshots are bundled. Eight deliberate corruptions of counts, range boundary, source bytes, combined manifest, baseline tree, inventory, Core freeze or App freeze were rejected. No source drift was detected.

Reports: `verification.json`, `live-verification.json`, `negative-controls.json`.

The unchanged 73-line standalone formatter oracle remains separately inventoried and excluded under published docs/evidence scope. Full on-disk Rust reconciliation including it is 119,519 nonblank lines across 230 files. Recovery Markdown documentation is excluded. Previous audits are preserved. No product edits, Cargo/build commands or remote writes were performed. This audit makes no parity, runtime correctness, performance or ETA claim; validation gates are separate evidence.
