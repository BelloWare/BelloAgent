# Reviewed saved-runtime and secure-input Rust LOC delta

Baseline published checkpoint: `67b02843cdc353cfa6f5b760c4164a5af4b6da8c`.
Baseline tree: `e736a261f92185d6925a07ac0bc4a7dfe5c3bd88`.
After-source manifest SHA-256:
`41613e1af2cad79301c42a1bc60bbcb31d7c7732a621c4e60d4a38bcac9a4716`.

| Category | Baseline | Delta | Joint checkpoint |
| --- | ---: | ---: | ---: |
| Production | 30,869 | +1,698 | 32,567 |
| Tests and test support | 44,134 | +1,987 | 46,121 |
| Benchmark/example | 1,186 | 0 | 1,186 |
| Total | 76,189 | +3,685 | 79,874 |

There are **148 Rust files and 47 changed Rust blobs**. These are nonblank
physical Rust lines, including comments, not feature-completion percentages or
performance measurements. No benchmark machinery or performance claim is added.

The ledger inherits reviewed ranges from exact matching old source blobs in the
prior ledgers. The unmatched old files were independently inspected: chat mode,
project host, project manager view, queue actions, and native authority modules;
their test modules/files remain support. Changed mixed files carry explicit
old/new support spans with boundary text. Positive test/synthetic/native-smoke
spans are support; platform-or-test spans that permit production remain production.
Comments before positive cfg attributes retain the preceding category. Nested
spans are counted only once.

## Generalized code is reclassified, not merely added

This checkpoint moves existing fixture-only behavior into the shared factory.
The category delta therefore includes reclassification of retained behavior,
not just newly written production lines:

- `saved_connection_runtime.rs`: **119 production / 4 fixture-support** lines.
  Its previous synthetic module had **115 support** lines; the remaining
  compatibility wrapper now has **31 support** lines.
- `runtime.rs`: **850 → 977 production**, **1,410 → 1,356 support**. Saved
  Configuration/lease/client selection and authority admission are always built;
  dynamic fixture resources remain support. This includes new guard code as well
  as retained former synthetic spans.
- `session.rs`: the expected-ID existing-only opener moves from a synthetic-only
  span into production; immutable materialization evidence is added.
- `provider.rs`: the no-proxy/no-redirect fixture-client implementation is now
  callable by the always-built provenance-aware constructor. Its former
  **12 support** lines become **11 production** lines after removing the cfg.
  Fixture selection still requires fixture provenance; no native startup changes.
- Trusted editing constructor, NativeTools gate setter, and workspace gate
  ownership become always-built crate-private factory infrastructure. Public
  read-only constructors still reject mutation capabilities.
- `connection_vault.rs`: confirmed entry/authority evidence is always built;
  fixture validation remains explicitly support-only and production validation
  follows a separate provenance branch.
- New `saved_runtime.rs`: **359 production / 37 test-support** lines. New app
  adapter: **223 production / 17 test support**. New secure-input module: **581 production / 3
  test-module support**. Their separately stored test files are support.

No source was classified as production merely because a fake test passed. Native
app startup and signed/Keychain acceptance gates remain closed. The legacy
dynamic resource/project fixture modules stay support-only.

## Reproduce exact source verification

```sh
python3 rust/scripts/verify-loc-saved-runtime-2026-10-07.py --repo . --after <joint-checkpoint-revision>
```

The default after revision is HEAD. `WORKTREE` is for pre-commit verification only.
The verifier checks baseline identity/ancestry, all 148 after Rust blob IDs, the
changed-file set, span boundary text, category deltas and independently recounted
full source totals. It needs no dependencies or generalized Rust classifier.
The complete [JSON ledger](loc-saved-runtime-2026-10-07-delta.json) preserves the
reviewed spans and exact source mapping in the repository, so verification does
not depend on ephemeral build folders or an assistant report.

Independent read-only review verified the earlier 46-file checkpoint spans and
all 148 source blobs with no corrections. The final presentation-only correction
adds 52 production and 160 support lines relative to that reviewed source, and
brings the changed set to 47 files. It adds capability-aware labels, a nonblocking
actual-definition query, and focused guard/contention tests. The refreshed exact
manifest and ranges above are verified by the same recorded-span script.
