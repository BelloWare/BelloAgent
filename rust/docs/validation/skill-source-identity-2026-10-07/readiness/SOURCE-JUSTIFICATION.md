# Readiness documentation correction

Base: BelloAgent `2ffbc323b9ad006683c2fef1eafa23f4990d8da5`.
Scope: only `rust/README.md` and `rust/docs/parity.md`; no original-checkout edits, builds, commits or publication.

## Source justification

- Shared pin: `rust/crates/bello-agent-app/Cargo.toml` lines 20–21 and both shared-package entries in `rust/Cargo.lock` agree on BelloBox `393133cd19d134ffd93c3a86449d94a7b1040683`.
- App tool exposure: `rust/crates/bello-agent-app/src/saved_runtime_adapter.rs`, `AppRuntime::options`, keeps normal capabilities empty; explicit fixtures offer Linux/macOS ls and Editing Bash, with macOS Read/Find/Grep and Editing Write/Edit. `rust/crates/bello-agent-core/src/tools.rs`, `NativeTools::new`, refuses the native Foundation capabilities on other platforms.
- Connections and production gates: `connection-settings.md`, `saved-runtime-app-integration.md` and `native-authority-contract.md`. Actual saved-runtime Linux GUI evidence is retained under `validation/saved-runtime-app-2026-10-07/README.md`.
- Later scoped workflows: `trusted-bash-workflow.md`, `native-read-contract.md`, `native-edit-contract.md`, `project-mcp-workflow.md`, `picker-image-attachments.md`, `context-preview.md`, `manual-compaction.md` and `validation/project-skills-2026-10-07.md`. Skills evidence explicitly extends older Context/compaction limits.
- Historical scope: `MIGRATION-HANDOFF-2026-10-07.md` identifies df548008 as its implementation base. The parity ledger's early tests, pins and failure records remain intact and are labeled historical. The new index and eight corrected inventory rows replace only plainly stale readiness statements.
- Platform boundaries: `.github/workflows/rust-macos.yml` compiles native targets and defines source-oracle/lifecycle checks; this is distinct from actual owner-Mac UI/signing/vault acceptance.

## Verification and uncertainty

`git apply --check --whitespace=error` passes against the original checkout. All 39 relative Markdown link targets in the two resulting files exist; the readiness anchor matches. Before files match the exact base Git blobs. Original Git status remains clean. `verification.json` records hashes and patch counts.

No current CI result is frozen into this correction. Linked records retain their original revision/binary and historical pending statuses. The audited base still records the Darwin skill identity/text gap; the pending correction is not described as accepted. No native GUI, Keychain, signing, full parity or performance claim is added.
