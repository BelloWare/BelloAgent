# Bello Agent 0.1.132 — sub-agents fall back to the parent's model; local model catalogs

Status: **packaged; publication pending.** Marketing version 0.1.132, build 136. Previous public release: 0.1.131/build 135. A hotfix of 0.1.131 cut from `main`; the work planned as 0.1.131 on `dev/next` ships as 0.1.133.

## Owner request

On 2026-10-27: "also, I am seeing "not offered for the parent's saved session" when sub agent tried to be spawn. for the model catalog, let's also support local version. And please release this ASAP". Earlier the same night: "don't check too much for edge case that might not happen for now".

## Change

Base `df38fe1f` (the 0.1.131 record on `main`). Codex Astra implemented both on their own branches; the lead reviewed both diffs; no review rounds (owner).

- **Sub-agent model** (`a132-subagent-model-0.1.132.md`, merge `27d5498b` of `0c5fdd7d`): the helper refused `subagent_start` with `subagent_model` "The model is not offered for the parent's saved connection" whenever the requested model was missing from the grants the app sent. Those grants are the connection's catalog entries, so they were empty when the catalog had not loaded in this launch (a chat sent before any model picker opened) and lacked any model the catalog does not list. A requested model that is not offered now runs on the parent's own model; the start receipt and the result carry `model` and a `model_notice` naming the requested model, and the tool's `model` description says so. The app starts loading a connection's catalog in the background when a chat needs grants and its catalog has not loaded, without delaying the send. Grant validation and the parent's route, headers and credentials are unchanged.
- **Local model catalogs** (`a132-local-catalog-0.1.132.md`, merge `6c2ee8cc` of `f977feb0`): a connection's custom model catalog also accepts a `file://` URL, an absolute path or a `~/` path; relative paths are refused as malformed. The file is read off the main actor with the remote catalog's size limit and parser, never with the gateway key; a missing or invalid file is reported like a failed fetch and the last good list stays. The field is now "Custom model catalog" ("HTTPS URL or local JSON file") in Settings and onboarding; `docs/Model-Catalog.md` describes it.

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1. No full gate, soak, review rounds or live test (owner: release ASAP, no edge cases).

- Branches (Astra): sub-agent model, helper 157 tests and app 4, 0 failures; local catalog, app 94 tests (catalog 23, ModelSwitch 24, Onboarding 22, SettingsSave 15, SettingsFlow 7 and others), 0 failures, Settings screenshot checked.
- Merged release tree:
  - helper suite (`swift test`, StreamingCostTests excluded as in the gate): 1,187 tests, 8 skipped, 0 failures;
  - wire 40, concurrent 4 and acceptance 3 against the Release helper: passed;
  - `scripts/test-subagent-streaming.py --steering --modes loop flow` against the Release helper: passed (loop 41 children, flow 2);
  - app `ModelCatalogEndpointTests`, `SubagentModelGrantTests`, `ConnectionSettingsFlowTests`, `ModelSwitchTests`: 58 tests, 0 failures.

## Known

- A sub-agent that falls back runs on the parent's model with the parent's reasoning choices; the parent learns this from the receipt, not before it starts.
- A local catalog is read again under the remote catalog's refresh rules (when a picker next asks after five minutes), not when the file changes.

## Release

RELEASE_IDENTITY
