# Search/Copy r2: latest occurrence-count contract LOC audit

Published baseline: `4c4315bc7a8c9f36e59a1bb8992a33e5813fa830`; tree `5d10e58a55fcf1bcb5c25e81f2cf900c4bfec2e9`.
Swift specification binding in the source seal: `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`.
Original r2 source SHA256SUMS SHA-256: `c60009ad190c322f19088e2eff4dc71ae7a84d75942a50c7d9af379a180c60fc`.
Full r2 patch SHA-256: `1854a436e0bfc4c432c91b9831a1ceaf7271858ba96e3adcd13d90ec109ba368`.
Incremental r1→r2 patch SHA-256: `61228ffefda45781e35670462a6351ca9e0520ef1e28981233f8a23e4866f058`.

| Category | Published 4c baseline | Full r2 delta | r2 current |
| --- | ---: | ---: | ---: |
| Production | 49,366 | +1,098 | 50,464 |
| Tests/support | 68,888 | +851 | 69,739 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned physical total | 119,446 | +1,949 | 121,395 |

All 234 owned product Rust files are counted once: five added, three modified versus published baseline, zero deleted. All 229 baseline source hashes match the published recovery ledger. All nine r2 frozen paths (eight Rust plus one Markdown document) match the source manifest, independent review and full patch scope. Production includes 145 unchanged build-support lines, leaving runtime-only production of 50,319. Shared workbench remains counted only under Box.

## Exact r1 to r2 increment

| Rust source | Production delta | Support delta |
| --- | ---: | ---: |
| conversation_content.rs | +13 | 0 |
| conversation_content_tests.rs | 0 | +52 |
| conversation_content_view_tests.rs | 0 | +53 |
| Total | +13 | +105 |

All other 231 product Rust hashes are unchanged. The fourth incremental patch path is excluded Markdown documentation. The count field/algorithm is production; the new pure and UI fixtures are support. The original r1 audit is preserved unchanged in `/workspace/shared/conversation-content-loc-audit`. Its ledger and the three changed before-images are bundled here for portable `verify-r1-to-r2.py`. No r1 GUI result is relabeled as r2 validation.

## Explicit ownership ranges

- conversation_content.rs: 270 production lines; seven support lines at positive cfg(test) spans 82–85 and 282–284. Complementary ranges 1–81 and 86–281 are production, including comments.
- conversation_content_controller.rs: 318 production lines in 1–319; three support lines at 320–322.
- conversation_content_view.rs: 394 production lines in 1–395; no support span.
- conversation_content_tests.rs: all 390 physical lines test-owned, yielding 383 support lines.
- conversation_content_view_tests.rs: all 462 physical lines test-owned, yielding 458 support lines.
- Existing integration deltas remain compaction_actions.rs +27 production, main.rs +26 production and transcript_view.rs +63 production; baseline test spans are retained exactly with mapped positions.

Nonblank physical lines include comments. Exact positive cfg(test), test-module and inherited synthetic-only ownership is retained. `loc-audit.json` contains all changed-file hashes, explicit production/support ranges with boundary text, hunk counts, complete physical inventory and additions/modifications/deletions. `REVIEW.md` is readable per-file detail.

## R2-only excluded evidence

The publication plan includes only the r2 standalone harness, not a second copy of r1 Rust evidence:

| Evidence source | Nonblank Rust lines |
| --- | ---: |
| Exact restored r2 product copy conversation_content.rs | 277 |
| Standalone independent conversation_content_tests.rs | 12 |
| Minimal main.rs type shim | 4 |
| R2 harness total | 293 |
| Prior standalone formatter oracle | 73 |
| Combined excluded evidence | 366 |

The harness module hash exactly matches frozen r2 production source. All harness files are excluded validation evidence; duplicate product code is never counted as another product contribution. The prior 277-line r1 harness remains local historical evidence and is not included in this publication inventory. `additional-evidence.json` binds the r2 evidence copies and counts.

The current frozen product tree plus its existing 73-line oracle has 121,468 nonblank Rust lines across 235 files. With the three planned r2 harness evidence files, physical reconciliation is 121,761 across 238 files. Product totals remain 121,395. These are distinct scopes, not additive product categories.

## Portable verification

    python verify.py
    python verify.py --root /path/to/agent-conversation-content
    python verify.py --root /path/to/agent-conversation-content --binary /path/to/bello-agent-search-copy-r2
    python verify-r1-to-r2.py
    python verify-evidence.py --source /path/to/r2-harness
    python negative-controls.py

Portable, live-source, revision-comparison and evidence checks passed. The current r2 binary was independently hashed and matches the seal: `1ccee19cbadf3dc6d42e4fcea96775454c17ebab347e1586c5ada84575820740`. It is not bundled. The verifier binds exact baseline commit/tree/product blobs, prior ledger, r2 source manifest, full and incremental patches, seal, independent review, postimages, explicit category ranges and complete physical sums. Ten deliberate corruption controls were rejected. No source drift was detected.

Reports: verification.json, live-verification.json, r1-to-r2-verification.json, evidence-verification.json, negative-controls.json. Complete source snapshots and original evidence records are bundled. The audit-derived source-r1-manifest.json filename is a structured index of the r2 SHA256SUMS, not the original r1 freeze.

No product edits, Cargo/build commands or remote publication occurred. Prior audits remain intact. Behavioral gates and GUI/native acceptance are separate evidence; no parity, correctness, performance or ETA inference comes from LOC.
