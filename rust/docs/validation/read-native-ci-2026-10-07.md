# Native read CI: first run and fixture correction

Published read checkpoint: `21e7481b7b7073846afd7f9c0a2208405f4d871e`, tree
`c67c1db4f62bf0238d17899395f8a1300734607c`.

- [Linux run 37580297270](https://github.com/BelloWare/BelloAgent/actions/runs/37580297270): succeeded.
- [macOS run 37580297313](https://github.com/BelloWare/BelloAgent/actions/runs/37580297313),
  job 112658173510: native compile/link succeeded; the core test step failed with
  270 passed and one failure. Later native fixture/UI steps did not run.

The failing test was `metadata_budget_rejects_bomb_before_full_decode`, at its
ImageIO width assertion: `None` versus `Some(100000)`. It had patched a 1×1 BMP's
header to claim 100,000×100,000 pixels without supplying those pixels. ImageIO
returned no width for that malformed data. The stronger assertion correctly
prevented malformed-file rejection from masquerading as pixel-budget evidence.
This did not demonstrate a production decode-budget defect.

The same native run passed `native_pipeline_matches_checked_in_swift_image_oracle`
(the 27-case synthetic Swift comparison), byte-preserving supported-image checks,
Foundation UTF-8/path reads, FIFO/error ordering, native read cancellation, typed
storage recovery and budget tests. These scoped successes do not make the failed
workflow green or prove the later trusted-project/native UI stages.

## Correction

Only test code changes. The guard stays at 16,777,216 pixels. A fully valid,
transparent PNG is generated from a known 4097×4096 CoreGraphics bitmap, exactly
one column beyond that guard. ImageIO must report those dimensions before the
test requires `size()` rejection and the normal resize-omission result. Fixture
dimensions are approximately 64 MiB of RGBA8 pixels; native row/encoder allocations
are additional. All fixture owners drop before the tested read starts, and the
encoded PNG must fit read's 16 MiB file bound.

The original truncated BMP is retained as a separate malformed-input omission
test, with no claim that it exercises the pixel guard. No production code, pixel
limit, oracle assertion, authority gate or provider behavior is relaxed.

After correction, the isolated Apple-target tests type-check and strict Clippy
pass; all five portable image-policy tests pass. Actual execution of the corrected
native fixture and the full exact workflow remains a new-commit CI gate.

## Fixture correction LOC

The correction changes only native test support: +42 nonblank lines. Production
remains 28,194; tests/support become 40,153; benchmark/example stays 1,184, for 69,531
total nonblank Rust lines. The original read ledger remains pinned to 21e7481.
Test blob before: `930179ce59768b175f1b72a7d73e0597dbb4c0cb`. Test blob after: `0563ac2244c746afb93fc6df07744369735f94ae`.

## Second native run: filesystem identity assertion

Correction checkpoint `73c8cd9bcfaa9b9c75c9fe0360bf35c503b8f660`, tree
`cc4acf8e46699bc9acbd9708d440d4750c8f8517`, passed
[Linux 37582044133](https://github.com/BelloWare/BelloAgent/actions/runs/37582044133).
[macOS 37582044194](https://github.com/BelloWare/BelloAgent/actions/runs/37582044194),
job 112663699951, passed native compile/link and the complete pure domain/filesystem
step, including the valid oversized PNG fixture. The later synthetic runtime
batch failed with 16 passed and one failure: the text-read fixture compared
Foundation's `/var/folders/...` result with Rust's `/private/var/folders/...` spelling.
The native image runtime fixture passed; later native UI steps remained skipped.

The text-read fixture now canonicalizes both existing filesystem paths before
comparison, matching the native read path test's established identity assertion.
It still checks exact text, line stats, snapshot version and persisted replay after
the source is deleted. This changes no production path output or normalization,
and does not loosen any Swift image oracle. Actual macOS execution of this
correction remains pending on its exact published commit.

This assertion adds three nonblank test-support lines: production 28,194;
tests/support 40,156; benchmark/example 1,184; total 69,534. Concurrent unpublished
write/edit and compaction work is excluded.
