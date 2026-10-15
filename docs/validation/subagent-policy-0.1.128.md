# Sub-agent policy and effort — 0.1.128

Stream: `subagent-policy` · branch: `dev/a128-subagent-policy` · baseline: `558630c8`.
Owner scope: 2026-10-15. Build/log root: `/Users/admin/Library/Caches/BelloSwiftWork/build-subagent-policy` (`$PI_BUILD_ROOT` below).

## Root causes and changes

- Both start-tool descriptions described concurrent delegation without requiring a user request. Parent request instructions had no conditional delegation policy. The same short policy now appears in the v3 `subagent_start` and legacy `subagent` descriptions and as exactly one additional parent system-prompt line when either tool is offered. Request preparation, preview, compaction sizing and agent-delivery sizing share it. Child prompts, disabled delegation and all other instruction bytes are unchanged.
- Picker grants carried a selected `thinkingLevel`, but discarded the catalog's supported reasoning levels. Optional `SubagentModelGrant.reasoning` now forwards the existing descriptor capability list. Missing means unreported; an empty list means no effort control. No new catalog, provider lookup or configuration switch was added.
- Start/send argument validation rejected `effort`; child turns had no saved per-turn choice, and follow-up submissions used the original child profile. `subagent_start` and finished-child `subagent_send` now validate an optional effort against the chosen model before acceptance or scheduling. The accepted start saves its effective choice in the existing model grant, and every new turn freezes optional `AgentChildTurn.effort`. Submission uses that frozen value.
- Summaries and control results omitted effort. The optional `SubagentSummary.effort` is now carried by listing/progress/history projections; start/send receipts and native metadata, terminal results/events, and both `subagent_status` actions expose it. Recovery also retains it in reconstructed receipts/results.
- The provider request builder and capture implementation are unchanged. A real loopback child request with the existing `low` → `wire-low` profile mapping verifies that both transport and captured request contain `reasoning.effort: "wire-low"`; the model-facing choice and summary remain `low`.

## Decisions and compatibility

- This is a prompt rule, not a new runtime permission or switch. The helper still accepts an otherwise valid start; the model is instructed to delegate only on an explicit user request.
- Omitted effort on **each new turn**, including a finished child's follow-up, inherits the parent's **current effective** effort. This follows the owner's stated default. A supported explicit follow-up choice can differ from the previous turn. Running/queued steering validates a supplied value but keeps the turn's existing effort and reports that unchanged value in its receipt.
- If the child model cannot support the inherited parent choice, omission uses `default`, matching the existing picker fallback. Explicit unsupported values are errors; they are never silently clamped. `default` is offered alongside supported levels only when that model has effort control. Profile map entries explicitly set to null are unavailable; a different model does not inherit another model's map.
- Schemas put supported values in an enum. When model capabilities differ, disjoint branches bind the enum to the selected model (or existing child); no-effort branches omit the property. Models/children with the same capability set share a branch, and uniform sets keep a compact schema.
- No journal version, marker or record kind changed. New optional fields are `reasoning` inside the saved model grant and `effort` on existing child-turn records. Older records without them decode normally; missing turn effort inherits the saved model grant. Cold recovery settles accepted work without executing it, and subsequent explicitly requested follow-ups use the same saved conversation.
- No UI layout or controls changed. The app edit only forwards model capabilities, and the shared wire type gains an optional field. Gallery paths: **not applicable; no scenes changed**. Effort display belongs to the separate UI stream.

## Exact added model-facing texts

The following sentence is appended to both start-tool descriptions and, only when parent delegation tools are offered, once on its own system-prompt line:

> Start sub-agents only when the user explicitly asks for sub-agents/agents, delegation, or parallel work; otherwise do the work yourself, even for large tasks.

The following sentence is added to the `subagent_send` description:

> Optional effort applies only to a follow-up; steering keeps the running turn's effort.

The new `effort` property's description is:

> Reasoning effort for the chosen child model; omit to inherit the parent's current effort. default uses the model default.

Unsupported explicit values return tool error code `subagent_effort` with:

> Effort is not supported by the chosen child model

Existing start/send description text remains in place around these additions. The legacy synchronous tool gains the policy sentence only; its argument contract is unchanged.

## Validation evidence

All fixtures are generated; network requests use a local Python loopback gateway. No installed app launch, `xctrace --launch`, real preferences, Keychain access or paid-provider calls. All builds use this stream's build root. No named result bundle and no full native lane.

| Check | Result | Text log under `$PI_BUILD_ROOT/logs` |
|---|---|---|
| Corrected-fixture baseline, production sources at `558630c8` | 4 tests, 7 failing assertions/errors, including missing policy/schema and rejected explicit effort | `helper-baseline-red.log` |
| Native baseline before capability forwarding | 2 tests, 2 failing capability-wire assertions | `native-red-final.log` |
| New helper behaviors, including loopback capture | 15 tests passed | `helper-loopback.log` |
| Real validation-guard mutation | Bypassing `!allowed.contains(requested)` causes 1 test to fail with 3 assertions: unsupported effort accepted and operation/turn created; source restored | `helper-mutation-effort.log` |
| Restored helper regression selection, repeated on final source | 266 tests passed, zero failures (including the 15 new tests) | `helper-regressions.log`, `helper-final.log` |
| Affected native classes | 19 tests passed, zero failures: Capture 7, Metadata 6, ModelGrant 2, SteeringWorkspace 4 | `native-green.log` |

The 15 new helper tests cover conditional descriptions/system instructions, child exclusion, per-model schema enums, omission for models without effort control, inherited effective effort, strict unknown/type/capability rejection without acceptance or requests, changed follow-up effort, unchanged running-turn effort, summaries/status, completed and queued cold recovery, repeated recovery without execution, older journals, draft-context preview, and real request capture. The native tests also round-trip the new summary field and decode summaries that omit it.

The first helper fixture used `DisabledTools`, which deliberately identifies a connection-test session and cannot delegate. It was corrected to `RecordingTools`; the corrected tests were rerun against baseline production sources to retain valid failing-first evidence. Early native setup attempts had a test-only `WireValue` accessor compilation error and an input-modified-during-build error; these were corrected before the recorded native behavioral baseline. Those diagnostic logs are retained as `helper-red.log`, `helper-initial-green.log`, `native-red.log` and `native-red-behavior.log`; they are not passing validation claims.

Commands:

```sh
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 4 \
  --filter SubagentPolicyEffortTests

swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 4 \
  --filter '(Subagent.*Tests|AgentSteering.*Tests|AgentFamilyRecoveryTests|ContextPreviewTests|ContextScopeTests|TurnCapacityTests|PiParityTests|ContinueRunTests|Compaction.*Tests|PausedFamilyCompactionTests|CaptureTraceTests)'

PI_BUILD_ROOT="$PI_BUILD_ROOT" scripts/test-macos.sh \
  -only-testing:PiAppTests/SubagentModelGrantTests \
  -only-testing:PiAppTests/SubagentMetadataTests \
  -only-testing:PiAppTests/SubagentSteeringWorkspaceTests \
  -only-testing:PiAppTests/SubagentCaptureTests
```

`python3 scripts/test-lanes.py list` marks all four selected native classes parallel; no serial-lane classes are combined. The lead owns separate Codex review, UI display integration and the full release gate. No merge or push to `dev/next` is part of this stream.
