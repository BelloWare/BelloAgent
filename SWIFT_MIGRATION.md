# Native Swift migration — start here

Target branch: **master**. The repository's default branch may still be `main`; do not accidentally continue from the old Node implementation.

Read [implementation status](docs/Implementation-Status.md), [Features.md](Features.md), [Design.md](Design.md), [feature parity](docs/Swift-Feature-Parity.md), and [test handoff](docs/Swift-Test-Handoff.md). A copyable continuation prompt is in [docs/Continue-Implementation-Prompt.md](docs/Continue-Implementation-Prompt.md).

The recovered code replaces the shipped Node/Pi host with a native Swift helper and retains the existing native UI and React transcript. The old TypeScript source is a development reference, not a runtime fallback. Node remains a build dependency for React.

This is a source/testing handoff, NOT a finished macOS release. The newest requirements still need work: deduplicated durable exact captures, a single Keychain configuration item, a percentile dashboard, LiteLLM-only configuration and reliable auto-router model identity. Custom endpoint/key support exists in the earlier profile implementation but has not been consolidated into the new vault.

Linux verification does not establish macOS UI correctness, release signing, Keychain isolation or DMG size. No release feed, notarization or deployment is performed by this handoff. Old Features/Design documents are preserved under `docs/archive/`; do not treat their bundled-Pi architecture as current.
