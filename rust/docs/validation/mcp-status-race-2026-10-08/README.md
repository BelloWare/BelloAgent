# MCP status observation and schema-fixture repair — 2026-10-08

Exact published base: `ca6136b57ee6f3bce84ab67ae0a12559bbfa51ca`.
This local repair's six Rust postimages are in `source-r3-manifest.json`.
Publication and exact repair CI are tracked separately by the integrator.

## Original failures

[Linux run37844995502/job113543535109](https://github.com/BelloWare/BelloAgent/actions/runs/37844995502/job/113543535109)
failed `cargo test --locked -p bello-agent-app --features synthetic-authority`:
590passed,1failed,3ignored. The MCP Inspector exactly-once test observed zero
invocations after returning idle; its earlier focused CI selection had passed.
The complete decoded connector log is verified and retained locally; committed
failure excerpts and `original-linux-provenance.json` bind its exact identity. A local
focused rerun also passed; it was not treated as proof that the race was absent.

The original `McpManager::status()` probed busy by taking the actual exclusive
admission gate, holding it across its status read. Concurrent confirmed Inspector
admission uses try-write and could fail as busy because of that observer alone.
A deterministic regression pauses this exact observation point: the old code
rejects with `McpError { code: "mcp_busy", not_executed: true }`; the repaired code
allows exactly one invocation and durable receipt settlement. This is a proven
mechanism consistent with the CI symptom. The original CI interleaving was not
traced and is not claimed proven.

[macOS run37844995497/job113543535251](https://github.com/BelloWare/BelloAgent/actions/runs/37844995497/job/113543535251)
failed two different native read/edit workflow assertions: actual snapshot9 versus
expected8 (583passed,2failed,1ignored). Both fixtures explicitly create a fresh
pending session, persist it, perform native tool work via loopback, then reopen
and replay. Their schema expectations now correctly require9. Explicit legacy
version/byte-preservation fixtures were not changed. Exact failure/command excerpts
are retained; `original-macos-provenance.json` identifies the independently hashed
complete decoded log, which is retained locally rather than included here.

## Repair and ownership

An Arc-shared admission wrapper retains the original Tokio read/write lock as the
sole exclusion mechanism. A separate RAII activity count reports queued/owned
work without acquiring the gate. Status is presentation only; it never authorizes
work. All real read/write/configuration/Inspector/acknowledgment/receipt admission
and durable ledger checks remain authoritative.

Read/write guards drop the actual lock before their activity field. Queued-future
cancellation, failed try-admission and panic unwind release their own count. Rebound
managers share the same wrapper. Acknowledgment moves its complete owned guard
into physical persistence exactly as before, including when the UI awaiter drops.
Completed pending receipts retain their independent gate checks and quarantine.

The checked increment uses compare-exchange rather than saturating or wrapping.
An intermediate fetch_update implementation was rejected by Rust1.99 strict lint
because the API was renamed; its failure log is retained. The explicit checked
loop avoids warning suppression and remains compatible with the older native
peer toolchain. No dependencies or permission gates changed.

## Validation

Rust1.99.0; locked offline dependencies and isolated cloud GPUI prerequisites.
From `rust/`:

- `cargo test --offline --locked -p bello-agent-core`:431unit+127integration pass.
- Same command with `--all-features`:609unit+127integration pass. Isolated child
  invocations in the log are not added again to these parent-suite counts.
- `cargo test --offline --locked -p bello-agent-app --features synthetic-authority`:
  the exact failed feature combination passes591,0failed,3existingignored.
- Same App command with `--all-features`:598pass,0failed,3existingignored.
- Default and all-feature `cargo clippy --offline --locked -p bello-agent-core
  -p bello-agent-app --all-targets -- -D warnings`:both pass.
- `cargo fmt --all -- --check`:passes.

The focused MCP suite passed61 tests, including real read/write/configuration,
receipt, queued cancellation, drop/unwind, rebind and confirmed-observer overlap
controls. Existing App assertion diagnostics now include Inspector state so a
future rejected invocation exposes its reason instead of only a count mismatch.

Both Agent packages were explicitly cleaned after the old-code red regression;
no Agent executable survived before rebuilding. The subsequent checked-CAS
compatibility adjustment was rebuilt and all final gates rerun. Source hashes
were reverified after those gates; final binary identities are in verification.json.

The two corrected macOS-only workflow assertions still require peer/CI execution.
Linux's ignored native workflow tests are not native acceptance. No interactive
GUI, owner-Mac, TCC/AX/Keychain/signing, speed or release claim follows from this repair.
