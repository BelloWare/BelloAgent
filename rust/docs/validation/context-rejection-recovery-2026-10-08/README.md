# Context-rejection recovery: frozen local validation

Baseline commit: `3a566ae58ee334c3b317a47ce099306c0d6535b5`.
Source behavior and intentional bounds: [context-rejection-recovery.md](../../context-rejection-recovery.md).

Core r3 source manifest SHA-256:
`619eccd739fc010350d9b138e75128fba37ad1e2237a9639052534e8e6de54e8`.
App r2 source manifest SHA-256:
`e451143d03c3015fccdf221bbc703893af4770ee8c638fbbc339e6c7b98c397f`.
Both received independent source review. Source review is separate from the executed gates below.

## Executed gates

- Core default: **480 unit + 127 integration tests passed**.
- Core all features: **665 unit + 127 integration tests passed**.
- App all features: **619 passed, 3 existing native-platform tests ignored**.
- App focused compaction/recovery: **13 passed**, included again in the full App run.
- Strict Clippy: core default/all features and App all features/all targets passed.
- Workspace formatting and final App all-feature debug build passed.

Commands use pinned Rust 1.99.0 and the existing Linux GPUI prerequisites. Core commands use `--locked`. App's preserved worker logs/report record its successful all-feature test, Clippy and build commands; Cargo.lock was unchanged.

The regression matrix covers real HTTP/JSON/SSE classification and redaction; exactly one summary and one automatic retry; repeated rejection and explicit Retry consumption; genuinely successful manual Retry followed by a new tool continuation; partial rejected output; oversized intact-history refusal; summary tools/errors; Stop before/after durable boundaries and after observed rejection; pre/post-rename faults; every persisted recovery phase on reopen; receipt retargeting/corruption; held steering; source authority revocation; sparse/conflicting/unknown usage; and actual MCP invocation count 1 with unchanged ordered durable results, timings and settled ledger.

App tests exercise actual TestAppContext painted rows, stale publication rejection, safe labels and sparse/overflow token display. The 920×600 split/nonsplit geometry case preserves 150px reading reserve, composer entity/selection/IME state and transcript scroll anchor. These are synthetic GPUI tests, not interactive computer-use evidence.

The sealed ordinary debug GUI binary SHA-256 is
`e32ab153e116f4ce97f8783c38c367975ca65f0f1bbf1b761e264e2558bcd83e`.
Its 16 changed Rust source hashes are recorded in `build-source-SHA256SUMS`.
The binary itself is not stored in Git. Interactive evidence is collected separately.

## Development failures retained in the engineering record

Initial schema assertions were updated when consumed-request resolution and safe error contracts became stricter; no validator was weakened. New saved-MCP fixtures initially tried to materialize before their first submission receipt and were corrected to use normal admission. Non-route connection edits intentionally preserve frozen runs, and route edits intentionally fork the saved connection; the final revocation test deletes the original fixture connection and passes.

App strict Clippy exposed an actual Error size issue under its unified serde_json features. The new typed failure variant was boxed; persisted receipt shape and classifier behavior are unchanged. Strict App then passed. The initial failing App raw log was overwritten during the retry, so it is not represented here as a preserved complete artifact. Final logs below are successful frozen-source gates. Published log copies remove trailing empty lines only; original logs remain in the local validation package.

## Source size, not completion or performance

Independent reviewed audit: **49,366 production /68,888 tests-support /1,192 benchmark-example** nonblank Rust lines across 229 owned files. Delta from Topics: **+1,828 production /+2,702 support**, no benchmark delta. Shared workbench code is counted only under BelloBox. The unchanged 73-line standalone formatter oracle is separately inventoried and excluded from product-source totals.

The audit ledger SHA-256 is
`3daea990d3a3e751ad2d341a7fea7f618a6c7a8422684191cd5f423154b3a892`.
`loc-live-check.json` verifies these exact source postimages. The integrator packages the independent ledger/verifier separately. These counts establish neither feature completeness nor an ETA.

No real model credentials, paid provider, user Mac, native vault, signing, TCC/AX, release or comparative-performance acceptance is claimed. Current commit CI must be checked independently after publication.
