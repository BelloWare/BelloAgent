# Reviewed edit/compaction Rust LOC delta

Baseline published checkpoint: `49b5e9330f3d11082efce5809090117887625499`.
Baseline tree: `e9f9f59525ce5d532bd5ccd029752d4d5679e223`.
After-source manifest SHA-256:
`16569aa1135367004c51fb2d4e65d462b454e5def86070651ca9865af4c433a2`.

| Category | Baseline | Delta | Joint checkpoint |
| --- | ---: | ---: | ---: |
| Production | 28,194 | +2,675 | 30,869 |
| Tests and test support | 40,156 | +3,978 | 44,134 |
| Benchmark/example | 1,184 | +2 | 1,186 |
| Total | 69,534 | +6,655 | 76,189 |

There are 142 Rust files and 46 changed Rust blobs. Counts are nonblank physical
lines, including comments, not feature-completion percentages or performance
measurements. The two benchmark/example additions initialize the new optional
message metadata; they do not add benchmark machinery or a performance result.

The ledger inherits the audited baseline and records source-reviewed positive
`cfg(test)`/synthetic-only spans in changed mixed files. Platform-or-test spans
that permit production execution remain production. All test files and the
explicitly synthetic-only project runtime/test mutation adapter are support.
Comments before positive cfg attributes retain the preceding category; nested
spans count once. Full old/new Rust totals independently match the category sums.

To avoid a self-referential commit ID in a ledger included in that same commit,
the after identity is the complete mapping of Rust paths to exact Git blob IDs.
This also tolerates authorized publication metadata changes and documentation-only
changes without weakening source verification. The publication's full commit and
tree are verified separately. No unreviewed successor Rust source can pass this
manifest check.

From a clone containing the baseline and the joint checkpoint:

```sh
python3 rust/scripts/verify-loc-edit-compaction-2026-10-07.py --repo . --after <joint-checkpoint-revision>
```

`--after` defaults to HEAD. The explicit `WORKTREE` value is only for pre-commit
verification. The verifier checks baseline identity/ancestry, every after Rust
blob, changed-file set, span boundary text, category deltas and full source totals.
It needs no dependency download or general Rust parser. The [JSON ledger](loc-edit-compaction-2026-10-07-delta.json)
preserves the reviewed spans; it is not an automatic classifier for future code.

Independent review reproduced both baseline totals, all changed-file counts,
18 exact inherited read-ledger span/count overlaps, the mixed cfg/platform spans,
and the seven new compaction modules (1,453 production/1,585 support). All 142 Rust
blobs also matched the separate 146-input compiled GUI source/Cargo manifest.
