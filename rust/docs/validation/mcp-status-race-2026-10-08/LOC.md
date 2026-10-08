# MCP status-observer repair r3: Rust LOC audit

Published baseline: `ca6136b57ee6f3bce84ab67ae0a12559bbfa51ca`. Exact tree: `0f5fe28e3249a0526c46bde220c152ad8eb8c0a4`.
Frozen six-path manifest SHA-256: `c12b87e39eff053098121eea4adbf284a1595702e10a771b83a8d73731f847d8`.

| Category | Published baseline | Repair delta | Candidate current |
| --- | ---: | ---: | ---: |
| Production | 46,356 | +74 | 46,430 |
| Tests/support | 64,976 | +121 | 65,097 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 112,524 | +195 | 112,719 |

The candidate has 218 owned Rust files versus 217 baseline files: one added, five modified, zero deleted. All 217 baseline product-source hashes match the published timing r3 ledger, and all six candidate postimages match the frozen manifest. The old audit is preserved. Production includes 145 unchanged build-support lines; runtime-only production is 46,285. Shared workbench remains counted only under Box.

## Reviewed changes

- `mcp/activity.rs`: new file, +69 production / +71 support. Production includes the RAII activity counter, guard ownership and drop ordering, admission methods, busy observation, and their comments. Exact positive cfg(test) support spans are 62–70 (`write_owned`), 79–87 (`read`), 88–96 (`write`), and 99–142 (tests module). The implementation closing brace at line 97 stays production. No adjacent production comment is swept into a test span.
- `mcp.rs`: +5 production / 0 support. The production status path now observes activity; the existing exact-blob test/support ranges are preserved and shifted. The status callback helper is production because the ordinary production status method calls it.
- `mcp/tests.rs`: +44 support in its existing wholly test-owned module.
- `mcp_inspector_controller_tests.rs`: +5 support in its existing wholly test-owned module.

Nonblank physical lines include comments. Existing positive cfg(test), test-module and synthetic-only support ownership is retained. No filename heuristic or broad cfg substring match changes established classifications. Per-file source SHA-256, before/after range boundaries, changed-hunk counts and the complete physical inventory are in `loc-audit.json`; `REVIEW.md` is readable detail.

## Excluded evidence reconciliation

The unchanged standalone formatter oracle remains separately inventoried: 73 nonblank Rust evidence lines, SHA-256 `7bc8d5d06841f383ba898e156218adfc3fafc337f391ca6c68c2dabeb606310a`. It is excluded under the established docs/evidence scope, not added to product support. The full on-disk Rust physical sum including it is 112,792 across 219 files. The oracle hash matches both the prior ledger and exact baseline Git blob.

## Portable verification

Complete baseline/candidate product Rust snapshots, baseline commit/tree records, classification evidence, source manifest, candidate postimages and excluded oracle are bundled.

    python verify.py
    python verify.py --root /path/to/agent-timing-ci-fix
    python negative-controls.py

Both portable and live-source verification passed with no drift. The verifier checks exact baseline commit/tree binding, Rust blob hashes, prior ledger hashes, all six postimages, path additions/modifications/deletions, complete Rust inventory, category arithmetic and physical sums. Six deliberate corruptions of category totals, a support boundary, source bytes, manifest, base tree and inventory were rejected.

Reports: `verification.json`, `live-verification.json`, `negative-controls.json`.

Full clean CI-equivalent gates remain separate from this audit; the focused test result does not change counting. No source edits, builds or remote writes were performed. These counts make no parity, runtime correctness, performance or ETA claim.

## r1 to r2 correction

Only two existing test-only sources changed. `transcript_edit_native_ui_tests.rs` adds one explanatory comment and changes the fresh-session expected version from 8 to 9: +1 support. `transcript_read_native_ui_tests.rs` replaces one comment and changes 8 to 9: zero LOC delta. Production and the other 216 owned Rust hashes are unchanged. No explicit legacy fixture is changed by these two edits. The r1 audit remains preserved in its original directory; its ledger and both before-images are bundled. `r1-to-r2.json` binds exact hashes and changed spans; verify with `python verify-r1-to-r2.py`.

## r2 to r3 compatibility change

The only source change is the production activity increment implementation in `mcp/activity.rs`: five nonblank lines using fetch_update are replaced by ten using checked_add and compare_exchange_weak. Exact delta: +5 production / 0 support / 0 benchmark. All other 217 product Rust hashes remain unchanged. Support ranges shift by five physical lines without changing membership or count. r1 and r2 audits remain untouched. `r2-to-r3.json` records hashes and exact spans; verify with `python verify-r2-to-r3.py`. This LOC audit does not independently certify compiler compatibility.

## Repository publication scope

This summary, loc-audit.json, LOC-REVIEW.md and loc-verification.json are published. The full local snapshot/verifier bundle and other referenced scripts are retained separately, not uploaded here. Final runtime tests and native pending scope are recorded in the repair validation report.
