# Standalone Linux validation — 2026-10-04

The final app/core source and Cargo manifests were copied into an independent
directory with the original tracked Swift assets and **no sibling BelloBox
checkout**. Cargo had first fetched the published BelloBox revision
`3dc2fa3c585927aca0493018c3830d7d1cffedbb` over HTTPS. Both shared packages resolved
from that exact Cargo Git source; neither retained a local sibling path.

With the installed Rust/Cargo 1.99.0 Linux toolchain and cached dependencies:

- `cargo fmt --all -- --check`: passed
- `cargo test --locked --offline --workspace`: 48 passed, zero failures/ignores
  - 7 app tests, 34 core unit tests, 2 runtime integration tests, 5 transport tests
- `cargo clippy --locked --offline --workspace --all-targets -- -D warnings`: passed
- `cargo build --locked --offline --workspace`: passed

The source files and Cargo manifests were compared byte-for-byte with the
publication checkout after those checks. This validates an independently located
source tree using the pinned dependency, but is not a cold-cache build. Cargo
reported a future-incompatibility notice in upstream `proc-macro-error2` 2.0.1;
it did not fail the current compiler or strict workspace lint checks.

Historical raw benchmark diagnostics and their archive are retained locally and
are not part of this public checkpoint. Published reports provide aggregate
results and limitations; scripts support new local runs. See
[`perf/evidence/README.md`](../../perf/evidence/README.md) for availability.

No real provider calls, production user sessions, or Swift storage migration were
used. Latest desktop interaction, displayed frame rate, GPU-present latency,
macOS build/runtime/vault integration, and full feature parity remain unvalidated.
