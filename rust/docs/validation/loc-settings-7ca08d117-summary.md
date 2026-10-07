# Reviewed Settings Rust LOC delta

Exact published checkpoint: `7ca08d1176a23cd268ad891665c80ceb867c42bd`.
Tree: `88c7d724c7fc830d0e43c19b9ce1ad28e8c51d13`.
Baseline: `de82d56d94099e0fb49434cf28ea0d34ee9f06f9`.

The exact Settings checkpoint passed both required workflows:
[Linux 37577081642](https://github.com/BelloWare/BelloAgent/actions/runs/37577081642)
and [macOS 37577081644](https://github.com/BelloWare/BelloAgent/actions/runs/37577081644).
These are compile/test/CI gates; native credential/signing/IME acceptance remains
separate from the synthetic desktop workflow evidence.

| Category | Baseline | Settings delta | Exact checkpoint |
| --- | ---: | ---: | ---: |
| Production | 23,194 | +3,305 | 26,499 |
| Tests and test support | 33,993 | +3,303 | 37,296 |
| Benchmark/example | 1,184 | 0 | 1,184 |
| Total | 58,371 | +6,608 | 64,979 |

There are 106 tracked Rust files at the checkpoint; 28 Rust blobs changed.
These are nonblank physical lines, including comments, not semantic statements,
feature-completion percentages or a same-hardware performance comparison.

## Method

The delta reads immutable Git objects for both commits, preserving the previously
audited baseline categories. Explicit support spans were located with Rust syntax
parsing and reviewed against the source; the preserved verifier uses those reviewed
spans without requiring a Rust parser or dependencies. It is not a new arbitrary
whole-project classifier.

Positive test/synthetic-only gates count as support, including struct-literal
fields, declarations, match arms, locals and expressions. Entire externally owned
test files and the synthetic connection runtime count as support. Mixed conditions
that allow production execution and negative synthetic fallbacks remain production.
Support begins at the positive cfg attribute; comments immediately before it retain
the preceding category. Overlapping nested gates count once. Existing lifecycle
probe spans are unchanged and have no effect on the delta.

Unmodified Rust files inherit the reviewed baseline. Complete old/new tree totals
are independently recounted and must equal the category sum. The exact 28 changed
blob identities and line-boundary anchors are verified. Unregistered Read-tool work,
third-party dependencies, caches, images, Markdown and scripts are excluded.

## Reproduce

From a clone with the published history:

```sh
python3 rust/scripts/verify-loc-settings-2026-10-07.py --repo .
```

The [JSON ledger](loc-settings-7ca08d117-delta.json) preserves every reviewed support
range, exact boundary text, old/new blob identity, per-file nonblank count and
category delta. The verifier checks the parent/tree identities, changed-file set,
span anchors, per-category deltas and complete tree totals. It makes no source,
index, branch or external-service changes.
