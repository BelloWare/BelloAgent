# Reviewed read-tool Rust LOC delta

Published checkpoint: `21e7481b7b7073846afd7f9c0a2208405f4d871e`.
Tree: `c67c1db4f62bf0238d17899395f8a1300734607c`.
Baseline published checkpoint: `28aa1ef165f085a0f1c9843c88700b941cc16f83`.
The exact source commit and parent are recorded in the JSON ledger; publication
metadata and exact CI links are verified separately before describing a run green.

| Category | Baseline | Read delta | Read checkpoint |
| --- | ---: | ---: | ---: |
| Production | 26,499 | +1,695 | 28,194 |
| Tests and test support | 37,296 | +2,815 | 40,111 |
| Benchmark/example | 1,184 | 0 | 1,184 |
| Total | 64,979 | +4,510 | 69,489 |

There are 123 tracked Rust files and 35 changed Rust blobs. These are nonblank
physical lines, including comments, not semantic statements, feature-completion
percentages or measured performance gains.

The delta uses immutable Git source on both sides and reviewed support spans.
Positive test/synthetic-only attributes count as support, including fields and
expressions; mixed platform/test conditions that permit production execution
remain production. External test files are wholly support, including the native
ImageIO/read `tests.rs` files. Comments before an inline positive attribute retain
the preceding category. Nested spans count once. Benchmarks are unchanged.

Classifications overlapping the Settings ledger were cross-checked exactly.
Unmodified Rust files inherit that audited baseline. Full old/new tree totals
are independently recounted and equal the category sum. Markdown, scripts,
third-party sources, caches and unregistered successor work are excluded.

## Reproduce

From a clone containing the recorded commits:

```sh
python3 rust/scripts/verify-loc-read-2026-10-07.py --repo .
```

The verifier checks tree/parent identities, the complete changed-file set, blob
hashes, reviewed span boundary text, category deltas and whole-tree counts. Its
[JSON ledger](loc-read-2026-10-07-delta.json) preserves the reviewed boundaries;
it does not claim to classify arbitrary later Rust source automatically.
