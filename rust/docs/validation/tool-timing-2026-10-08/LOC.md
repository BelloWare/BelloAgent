# Tool timing r3: Rust LOC audit

Exact published base: `fdc5bb0232f54def59b7a7df5363b6d73bdc2573`; tree `2e4bf271caafe192fcbb19ba1cbfe41ab6603b92`.
Frozen 57-path manifest SHA-256: `74ac72bdaef874f88ac7ac3ec13349b294c7acc7e8ab09ee0fa90d9d3e926264`.

| Category | Published baseline | r3 delta | r3 cumulative |
| --- | ---: | ---: | ---: |
| Production | 45,980 | +376 | 46,356 |
| Tests/support | 64,128 | +848 | 64,976 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 111,300 | +1,224 | 112,524 |

All 217 owned Rust files are counted once; 43 changed versus the published baseline. All 213 baseline Rust hashes match the previous published live-card ledger. All 57 frozen manifest postimages match. Production includes 145 unchanged build-support lines, leaving runtime-only production of 46,211. Shared workbench remains counted only under Box.

## Exact r2 to r3 changes

- `main.rs`: +3 production. Replaces one spacing line with two spacing lines and two production comments.
- `queue_geometry_tests.rs`: +10 support within its established wholly test-owned module.
- `tool_timing_presentation.rs`: +24 support inside its existing positive cfg(test) module, adding the 36-case native-formatter fixture comparison.
- All other 214 owned Rust hashes are unchanged. Core production is unchanged.

The original r1 and r2 audits remain unchanged in their separate directories. The r2 ledger and three before-images are bundled here; `r2-to-r3.json` binds both ledgers/manifests and exact changed spans. Cumulative r3 counts include the earlier r2 +15 MCP support-line correction exactly once.

## Evidence scope

The 57-path manifest contains 43 owned Rust paths and 14 excluded documentation/evidence paths. The generated validation file `rust/docs/validation/tool-timing-2026-10-08/native-formatter/oracle-comparison.rs` has 73 nonblank physical Rust lines. It is a standalone test oracle, inventoried and hash-verified separately, and remains excluded under the published documentation/evidence scope. Including it solely for reconciliation, the full on-disk Rust physical sum is 112,597 across 218 files. It is not added to product production or support totals. The integrated App fixture test is already included in support.

## Method and verification

Nonblank physical Rust LOC includes comments. Existing exact-blob classifications are retained. Support includes exact positive cfg(test) spans, test-only module ownership and inherited synthetic-authority-only support. Adjacent non-test comments stay production. Platform-or-test production ownership remains unchanged. In particular, `resource_runtime.rs` retains whole synthetic-support ownership; runtime-like filenames do not override it.

`loc-audit.json` contains per-file before/after SHA-256 values, reviewed support ranges and boundary text, category counts, changed hunks and the full physical inventory. `REVIEW.md` is the readable review. Complete baseline/candidate Rust snapshots and all 57 candidate postimages are bundled.

Portable stdlib-only checks passed:

    python verify.py
    python verify.py --root /path/to/agent-tool-timing
    python verify-r2-to-r3.py
    python negative-controls.py

Verification binds the baseline Git commit object/tree, Rust blob hashes, published ledger, manifest, all candidate postimages, exact Rust inventory and independent physical sums. Six deliberate corruptions of totals, support boundary, source bytes, manifest, base tree and inventory were rejected. Reports are `verification.json`, `live-verification.json`, `r2-to-r3-verification.json`, and `negative-controls.json`.

No source drift was detected. The manifest recorded full App/lints pending at freeze; test/lint outcomes are independent evidence and are not certified by this LOC audit. Any source drift requires an explicit new revision. No source changes, builds or remote writes were performed. No parity, correctness, performance or ETA inference is made.

## Repository publication note

This repository publishes this summary, loc-audit.json, LOC-REVIEW.md and loc-verification.json. The full local audit bundle, snapshots, scripts and additional verification reports referenced above are not uploaded here. Final tests and review are recorded separately in README.md; this audit is accounting only.
