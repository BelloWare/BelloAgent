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
- If the child model cannot support the inherited parent choice, omission uses `default`, matching the existing picker fallback. Explicit unsupported values are errors; they are never silently clamped. The start schema offers `default` alongside supported levels only when that model has effort control. Profile map entries explicitly set to null are unavailable; a different model does not inherit another model's map.
- Start schemas put supported values in an enum. When model capabilities differ, disjoint branches bind the enum to the selected model; no-effort branches omit the property. Models with the same capability set share a branch. Following review round 2, send always advertises the fixed full effort vocabulary without child IDs or a retained-plan scan; the coordinator validates the addressed child's frozen capabilities before acceptance. Thus send's size is independent of family history, including for models without effort control.
- No journal version, marker or record kind changed. New optional fields are `reasoning` inside the saved model grant and `effort` on existing child-turn records. Older records without them decode normally; missing turn effort inherits the saved model grant. Cold recovery settles accepted work without executing it, and subsequent explicitly requested follow-ups use the same saved conversation.
- No UI layout or controls changed. The app edit only forwards model capabilities, and the shared wire type gains an optional field. Gallery paths: **not applicable; no scenes changed**. Effort display belongs to the separate UI stream.

## Exact added model-facing texts

The following sentence is appended to both start-tool descriptions and, only when parent delegation tools are offered, once on its own system-prompt line:

> Start sub-agents only when the user explicitly asks for sub-agents/agents, delegation, or parallel work; otherwise do the work yourself, even for large tasks.

The following sentence is added to the `subagent_send` description:

> Optional effort applies only to a follow-up; steering keeps the running turn's effort.

The `subagent_start` effort property's description is:

> Reasoning effort for the chosen child model. Omit to inherit the parent's current effort; use "default" for the model's own default.

The `subagent_send` effort property's description (review round 2) is:

> Reasoning effort for a follow-up; the child's model must support it. Omit to inherit the parent's current effort; use "default" for the model's own default.

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

## Lead review round 1

Baseline: `0894e8ce96f21546df7d1f8af553a9a5cd6e0535`. Both P2 findings and the wording note are addressed.

- **Mixed-version replay:** released 0.1.127 accepts v3 journals but its typed turn decoder discards the new optional effort field. Its recovery terminal consequently omits effort, which previously failed the new immutable-identity comparison. Replay now fills only a missing value from the previously accepted turn. If the child terminal precedes its first turn mirror, recovery takes the missing value from the owning parent's acceptance. Explicit effort conflicts, changed input/execution identity, and changed sealed terminal state remain errors. Saved result envelopes are preserved exactly.
- **Related origin crash window:** 0.1.127 can finish publishing a marker-only child's origin without the new model capability list. Recovery and follow-up opening accept a missing list using the owner's accepted origin; explicit conflicting lists and altered tools/identity still fail. No permission or resource field is relaxed, and the parent's accepted grant remains authoritative.
- **Related checkpoint shortcut:** an older helper's typed checkpoint can discard effort and capabilities even though the authoritative journal rows retain them. Checkpoint helper metadata now carries `subagentEffortVersion: 1`; old caches containing a family, child origin or plans force full journal replay. Ordinary chat caches and current family caches retain their shortcut. This is a disposable cache change: journal markers, versions and record kinds are unchanged, and no historical journal bytes are rewritten.
- **Capability source:** manual/custom-catalog models with no reasoning list now use the saved connection's capability flag in schemas and admission, carried separately from the effective parent profile. Model default still inherits/sends default when effort is omitted, but no longer hides supported explicit levels or persists an empty capability list. Selecting an effort also cannot invent capabilities on an unsupported connection. Catalog lists and frozen child lists remain authoritative.
- **Wording:** the effort property now uses the exact revised text recorded above. Policy and send-description sentences are unchanged.

Eight added behavioral tests cover actual child start requests, omission, follow-ups after relaunch, live/preview schemas, eight mixed-journal crash combinations reopened twice without dispatch, missing/conflicting origin capabilities, immutable identity/terminal conflicts, and loss of typed fields in an older helper checkpoint. These tests generate 0.1.127-shaped records/caches; they do not launch an installed helper or app.

| Check | Result | Log under `$PI_BUILD_ROOT/logs` |
|---|---|---|
| Corrected baseline for the two reported findings and wording | 6 tests fail, 34 assertions/errors | `review1-baseline-red.log` |
| Origin publication regression before its fix | 1 test fails | `review1-origin-red.log` |
| Older checkpoint regression before its fix | 1 test fails, 2 assertions/errors | `review1-checkpoint-red.log` |
| Policy/effort plus checkpoint classes after fixes | 30 passed, including all 23 policy/effort tests | `review1-checkpoint-green.log` |
| Real effort-membership guard bypassed | 1 test fails, 3 assertions | `review1-mutation-validation.log` |
| Capability source reverted to the effective request flag | 1 test fails, 2 assertions | `review1-mutation-capability-source.log` |
| Missing-effort inheritance removed from replay/recovery | 1 test fails, 16 assertions across crash/reopen cases | `review1-mutation-replay-inheritance.log` |
| Replay allowed to overwrite explicit conflicting effort | 1 test fails | `review1-mutation-replay-conflict.log` |
| Origin comparison allowed to overwrite conflicting capabilities | 1 test fails | `review1-mutation-origin-conflict.log` |
| Old-family checkpoint guard bypassed | 1 test fails, 2 assertions/errors | `review1-mutation-checkpoint.log` |
| Final restored regression selection, including checkpoint/replay/fork classes | 318 passed, 1 intentional fixture-writer skip, zero failures (319 total) | `review1-final.log` |

All six mutations were restored before the final regression run. The initial `review1-red.log` also caught a test-fixture setup error: the generated child lacked `managedChild: true`. That fixture was corrected before the recorded baseline above; the initial log is not counted as valid recovery evidence.

The first expanded regression run (`review1-regressions.log`) had 317 passed, one skip and one failure: the shared ordinary-chat fork fixture detected the new cache marker. Marker emission was narrowed to families/child origins/plans, preserving ordinary-chat metadata; the unchanged fixture then passed in the final run. The sole final skip is `ForkCloneTests.testWriteTheSharedForkFixture`, which intentionally requires `PI_WRITE_FORK_FIXTURE` to regenerate a fixture.

Final command:

```sh
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-host" --jobs 4 \
  --filter '(Subagent.*Tests|AgentSteering.*Tests|AgentFamilyRecoveryTests|ContextPreviewTests|ContextScopeTests|TurnCapacityTests|PiParityTests|ContinueRunTests|Compaction.*Tests|PausedFamilyCompactionTests|CaptureTraceTests|JournalCheckpointTests|DurableReplayTests|ReplayParityTests|ForkReplayHandoffTests|ForkCloneTests|ForkPointTests|ForkAtReplyTests|SideForkTests)'
```

Round 1 touches helper code only. Native results remain the original 19 passing affected tests above; no new native build or full lane was run. Gallery paths remain **not applicable; no UI scenes changed**. The lead's independent review, UI integration and release gate remain outside this branch.

## Lead review round 2

Baseline: `6b726a8d751437c0f9ec9f62860cafd62ea89217`. Both P2 findings are addressed.

- **Desktop reciprocal validation:** helper recovery normalized missing origin capabilities, but desktop discovery compared the raw origins literally. A valid older-helper mirror was therefore registered with a persistent recovery issue and no parent relationship. Discovery now fills only absent/null `model.reasoning` from the accepted parent origin before comparing the complete raw values. It does not compare only the desktop's smaller decoded header, which would discard tools, frozen resources and unknown fields. Explicit capability differences and all other origin differences remain invalid. Generated tests verify discovery, persisted metadata and repeated live follow-up registration retain the parent relationship without modifying either journal or opening a helper.
- **Unbounded send schema:** each request built a dictionary of all saved child plans, then included every child ID in capability-dependent schema branches. Lifetime family membership is unbounded. The send schema now always advertises the fixed vocabulary `default`, `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; it has no child-ID enum or capability branches, and preparing tool definitions no longer reads saved plans. The existing coordinator still validates the addressed child's frozen grant before accepting work or sending a request, including rejecting explicit values for a model without effort control. The error remains `subagent_effort`: “Effort is not supported by the chosen child model”. Start schemas still use their model-specific capability enums.
- **Model-facing wording:** only the send effort property's description changes in this round, to the exact text above. It explains that the addressed child's model must support the selected value. The policy, start description, send tool description, start effort description and error text are unchanged.

Two helper tests exercise byte-for-byte identical send schemas and prepared tool definitions at 0, 1, 3 and 2,048 retained children (a 16,384-token parent), plus child-specific validation for low-only, high-only and no-control models. The schema stays below 1,024 bytes. Two native tests cover omitted/null capability lists and ten conflicting origin cases, including permissions, resources and fields the desktop header does not decode. Existing quarantine and attachment authority rules are unchanged.

| Check | Result | Log under `$PI_BUILD_ROOT/logs` |
|---|---|---|
| Helper baseline | 2 tests: schema regression fails with 22 assertions; existing per-child validation passes | `review2-helper-red.log` |
| Native discovery baseline | 13 tests: compatibility regression fails with 14 assertions; conflict checks pass | `review2-native-red.log` |
| Policy/effort after fix | 25 passed | `review2-helper-green.log` |
| Actual per-child effort guard bypassed | 1 test fails with 20 assertions; restored | `review2-mutation-send-validation.log` |
| Final helper regression selection | 320 passed, 1 intentional fixture-writer skip, zero failures (321 total) | `review2-helper-final.log` |
| Discovery, metadata and steering workspace classes after fix | 23 passed | `review2-native-green.log` |
| Missing-field normalization removed from the desktop guard | 13 tests: compatibility test fails with 7 assertions; source restored | `review2-mutation-missing-origin.log` |
| Desktop guard made to overwrite explicit capability conflicts | 13 tests: conflict test fails with 4 assertions; source restored | `review2-mutation-explicit-origin.log` |
| Restored discovery, metadata and steering workspace classes | 23 passed, zero failures | `review2-native-final.log` |
| Serial opening class, run alone | 10 passed, zero failures; real generated loopback attachment/navigation paths | `review2-native-opening.log` |

The first desktop mutation removed the normalization statement entirely, which produced unused-variable warnings under the native warnings-as-errors setting before tests ran. `review2-mutation-missing-origin-compile.log` is diagnostic only. The corrected mutation removes the missing-field case from the real guard while retaining its null case; the behavioral failure above is the evidence. All mutations are restored.

Helper commands use the same scratch root and final class filter recorded in round 1. Native commands use `PI_BUILD_ROOT` and `scripts/test-macos.sh`; `python3 scripts/test-lanes.py list` classifies discovery, metadata and steering workspace as parallel, and opening as serial. Opening is run alone. No full native lane, installed app, real preferences, Keychain or paid-provider request is involved. Gallery paths: **not applicable; no UI scenes changed**.

```sh
PI_BUILD_ROOT="$PI_BUILD_ROOT" scripts/test-macos.sh \
  -only-testing:PiAppTests/SubagentDiscoveryTests \
  -only-testing:PiAppTests/SubagentMetadataTests \
  -only-testing:PiAppTests/SubagentSteeringWorkspaceTests

PI_BUILD_ROOT="$PI_BUILD_ROOT" scripts/test-macos.sh \
  -only-testing:PiAppTests/SubagentOpeningTests
```

Final round-2 totals: **320 helper tests passed, one intentional skip; 33 native tests passed**. The lead's independent review and release gate remain separate; this stream does not merge or push `dev/next`.
