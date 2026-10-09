# Unread source R6 Rust LOC audit

Baseline is published `464222b4b72ccb684d501a6301be1f1479591554`, tree `599a0d9413603668e1e449538eb0dcfcfbbb1fb2`. The complete immutable bd4e6ebb migration handoff was read and is preserved. Original 33-file source freeze SHA-256: `2f4acc3d00ce73fbc7145f652df10181aaca9b51640065e17052cfecaa4ca87a`. Counts use the copied immutable postimages; live sources are checked independently.

| Category | Baseline | Unread delta | Candidate |
|---|---:|---:|---:|
| Production | 51,704 | +2,123 | 53,827 |
| Tests/support | 71,896 | +3,261 | 75,157 |
| Benchmark/example | 1,192 | 0 | 1,192 |
| Owned total | 124,792 | +5,384 | 130,176 |

All 242 baseline product hashes match the prior audited ledger. The candidate owns 250 Rust files: eight added, 24 modified, none deleted. The freeze is exactly 32 changed Rust paths plus one Markdown document. Comments are included as nonblank physical lines. Build-support production remains 145 lines; runtime-only production is 53,682. Shared workbench is counted only under Box.

## Critical classifications

- New sidebar_read_state.rs: 978 production and 25 support. Support is exactly 159–166 (test baseline helper), 883–890 (non-macOS test helper), 984–989 (macOS test-only fail-closed adapter), and 1012–1014 (test child declaration).
- NativeReadEvidence at 950–976 is production: cfg(any(macOS, test)) includes the real macOS product. The macOS AppKit paths 979–983 and 1001–1004 are production. The Linux/test fail-closed fallback 1005–1009 is production because it is also the actual non-macOS product path, even though tests execute it. The actual native visibility bridge in native_menu.rs remains production; only its trailing positive cfg(test) module 667–951 is support. Native menu delta is +96 production / +1 support. Lack of native execution does not reclassify implementation as support.
- WorkspaceStore AfterRename hook is synthetic/test-only support: 842–845 fields, 847–855 fault enum, 912–915 initializers, 935–940 one-shot arming API, 1103–1105 setup, 1113–1116 restoration, and 1787–1792 injection. The existing test-only BeforeRename branch 1782–1785 also remains support. These spans total 36 nonblank lines; preceding comments 932–934 remain production under the established cfg-start rule. No ordinary production branch enables the synthetic hook. Workspace delta +112 production / +21 support includes the new test child declaration and historical test spans.
- sidebar_run_state.rs new positive test adapters are 85–88 and 89–92; the inherited test declaration shifts to 358–360. Delta +61 production / +8 support.
- read_observation.rs is 192 production / 3 support; workspace_read_state.rs is 312 production / 3 support. Each three-line positive test declaration is support.
- Runtime read-observation integration adds 28 production / 3 support; transcript measured reply-end integration adds 85 production / 4 support. All source-matching inherited test and synthetic spans remain classified as support after line movement.
- New test-only child files contribute 2,984 support lines: sidebar_read_state_tests.rs 1,445; read_observation_tests.rs 595; runtime_read_observation_tests.rs 152; workspace_read_catalog_tests.rs 471; workspace_read_state_tests.rs 321. They are counted once through their own files, not again through parent declarations.

## Excluded evidence and portable reproduction

The four existing formatter/Search-Copy evidence Rust files remain unchanged at 366 nonblank lines. Duplicate product source inside the historical harness is not counted as another product contribution. Full physical on-disk reconciliation is 130,542 lines in 254 Rust files. Audit before/after copies are local reproducibility inputs, not product source additions or proposed duplicate evidence publication.

Run `python verify.py` for portable checks or `python verify.py --root /path/to/agent-unread-workflow` for additional live source/inventory checks. Run `python negative-controls.py` for deliberate corruptions. The verifier authenticates baseline commit bytes, recursive Git tree objects and all baseline blobs; checks all postimage hashes, exact 33-file freeze, immutable-copy manifest, prior ledger, support/production range partitions, category and changed-hunk counts, complete inventory, evidence exclusions and physical reconciliation. No Cargo/product edits, remote writes or new validation Rust were performed.

LOC is not parity, runtime acceptance, performance, completion percentage or ETA. Build, GUI and native acceptance results are deliberately not asserted by this audit.

## Cached-paint checkpoint delta

Checkpoint r5 (76649be3) is preserved separately and is superseded for source accounting by this r6 freeze. The four changed Rust files add 59 production and 146 support lines; the fifth changed path is documentation outside Rust scope. Main read-surface tracking adds four production lines and bounded child invalidation adds 55 production lines. The two real GPUI cache/timer regressions add 89 and 57 support lines. Core/catalog bytes and classifications are unchanged. r5-to-r6.json binds exact hashes and deltas. The independent cached-paint review is preserved for context; execution/native/seal acceptance is separate from LOC verification.

## R6 source-only candidate binding

Candidate `eba8565c9fd4b01ad9875b338db47125fc2710dd`, tree `90434aee2c85187765b629ab017218941dd5b8ce`, parent `76649be3adef49cc4054ea4d479cd1b144780c33`. The full single-parent commit ancestry through 766, ec9, ba3, d40 and af5 to published464 is authenticated from immutable commit bytes. Recursive Git trees, exact 33 baseline-to-candidate changed paths and all 250 owned Rust blobs match freeze2f4acc3d. Parent's independent remote readback verifies all 33 postimages and five r5-to-r6 changed paths; receipt preserved separately.

Portable and live-source verification passed without drift. Ten tamper controls passed. Counts apply to the exact r6 source-only candidate and do not assert rust-branch publication, platform/native acceptance, binary correctness, parity or ETA. Historical r5 wording is checkpoint-relative; r5 is superseded for current accounting while its bundle remains preserved.
