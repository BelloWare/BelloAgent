# Outcome writer lease validation

Source was frozen at the hashes in `mcp-writer-source-sha256.txt`.
`writer-lease.diff` compares outcome.rs, mcp.rs, and tests.rs with their copied
pre-task contents. It includes the coordinated same-workspace rebind method/test
from the MCP workflow owner. The owner's saved_runtime.rs, workspace.rs,
mcp_vault.rs, and documentation deltas are outside that three-file diff.

## Results

- All-feature focused MCP: 33 passed (`mcp-writer-focused.log`).
- Default-feature outcome suite: 5 passed (`mcp-writer-default.log`).
- Negative controls: only `file.try_lock()` admission was removed in an isolated
  source copy at `/workspace/scratch/8b6fda578834/mcp-writer-negative/rust`.
  The subprocess exclusion and distinct-catalog tests each failed with Cargo
  exit 101, as required (`mcp-writer-negative-*.log`). No original source changed.
- The shared Cargo target was
  `/workspace/scratch/8b6fda578834/agent-mcp-staging/rust/target`. A first attempt
  to rerun original sources reused the mutated copy's binary because their
  package identity and preserved mtimes overlapped. That attempt is not valid
  restored-source attribution. No other builds were running. `cargo clean -p
  bello-agent-core` in that target removed only the package's generated artifacts
  (406 files, 489.5 MiB); a clean original-source compile then passed all 33 MCP
  tests (`mcp-writer-restored.log`). Future mutation runs must use distinct targets.
- The exact `WriterLease` implementation and `nonblocking_nofollow` helper were
  extracted unchanged into `mcp-writer-macos-compile.rs` (archived here as
  `mcp-writer-macos-compile.rs.txt`, a validation artifact), with only Error/Result
  stubs surrounding them. `rustc --edition 2024 --target aarch64-apple-darwin
  --crate-type lib --emit metadata -D warnings` succeeded using installed
  rustc 1.99.0. This verifies API/target compilation only, not macOS execution,
  full-crate cross-compilation, native Keychain, signing, or GUI acceptance.

All runs used existing offline dependencies and jobs1; fixtures are synthetic and
numeric loopback. No credentials, desktop interaction, dependency changes, or
production/native gate changes were introduced. Final integrated all/default core suites and strict Clippy subsequently passed;
see `final-core-*.log` and source-before/after checks. The candidate 4 build and
scoped GUI record are tracked separately.
