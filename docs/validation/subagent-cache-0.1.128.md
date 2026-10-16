# Sub-agent prompt caching — 0.1.128

Date: 2026-10-15. Stream: `dev/a128-subagent-cache`, based on `152725f0`.
Build/artifact root: `/Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache` (abbreviated `$B` below).

## Result

The final generated, actual-helper workflow sends **26 Responses requests** across one parent and three children. Before the fixes, **8 of 22 consecutive comparisons** rewrite the prompt prefix; afterwards **all 22 preserve the complete previous instructions/tools/input prefix**. The byte-based input estimate is 111,893 tokens across requests in both runs. Reusable prefix estimate improves **68,055 → 97,124 tokens**, or **60.82% → 86.80%** of all input including four cold starts and every new tail. Previous-prefix retention improves **70.07% → 100%**. These are serialization estimates, **not measured provider cache reads or billing savings**.

There is no evidence of live progress, spend, timestamps or a growing roster being injected into earlier prompt text. Automatic child results are delivered once, through the agent-event lane. The fixes address two other sources of churn:

1. Child follow-up effort changed the first instruction's role. `Profile.overriding(thinkingLevel:)` turns the effective reasoning flag off for Model default; `responsesProjection` used that flag to choose `developer` versus `system`. The child's text was unchanged but its first item was not. Managed v3 children now derive a fixed instruction role from their immutable creation grant on every open. Effort and include options still behave exactly as before. Budget/profile copies, including compaction's summary profile, retain this runtime-only role. No journal field or format changes.
2. Parent start-tool model enums inherited picker/catalog order. A refresh containing the same grants in another order changed both the common schema and members of the per-capability branches. Both v3 and historical v2 start schemas now sort model IDs for serialization. The offered set, capability validation, picker order and execution permissions are unchanged.

**Limit on the owner's requested proof:** stable visible inputs cannot prove every upstream request is cacheable. The helper sends only Responses. Gateway translation, hidden provider instructions and cache residency are outside its capture boundary. In particular, **changing effort can change hidden model-side instructions**, even after the visible role fix. OpenAI documents effort as a cache-affecting setting and offers model-specific configuration-update items; adopting those would change the current pi 0.85.1 request contract and is not part of this change. [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching), [cache diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).

## Audit of prompt inputs

Paths below are relative to `packages/swift-host/Sources/PiAgentCore/` unless specified. This covers both the parent and each child; it does not assume siblings share a prefix/cache identity.

| Input / source | Parent | Child / stability boundary |
|---|---|---|
| Route and body builder: `Profile.swift`, `Providers.swift`, `Routing.swift` | `Profile.init` accepts only `openai-responses`; endpoint is `/responses`. No Chat or Anthropic request builder is dispatched. Legacy Messages parsing is read/replay compatibility. | Same connection and fixed selected model. The loopback verifies the real endpoint, model and physical session on every request. No invented Anthropic/Chat fixtures are presented as coverage of a nonexistent writer. |
| Base instructions: `Resources.swift`, `SessionQueue.swift`, `SessionRun.swift` | CWD/workspace roots, resolved global/project/approved instructions and implicit skill catalog. Snapshot is applied at task/submission boundaries and reused through the model/tool loop. No current time or family state. Directory/skill traversal is sorted. | `SubagentOrigin.frozenResources` saves the original snapshot. `AgentSteeringCoordinator.makeChild` starts from that snapshot and appends its fixed delegated-role paragraph exactly once on each open; it never starts from a previously appended child paragraph. New turns reuse that prefix. |
| Selection policy: `SessionContext.requestInstructions` | One fixed explicit-skill-authority paragraph. Explicit skill bodies, selection IDs, arguments and expansion turn ID are frozen in their own user row; later selections append rows. | No inherited explicit skill consent or parent transcript. The resource snapshot does not contain the request-only selection/delegation additions, so the child does not accumulate copies. |
| Conditional delegation policy | Included when `subagent_start` or v2 `subagent` is offered. Eligibility is durable-session/role/feature based, **not** whether any child is active, finished or retained. It stays present through waits, result delivery and Resume. | Only `subagent_report` is added; no parent delegation paragraph. Changing actual eligibility/tool availability is a real configuration boundary. |
| Instruction role: `ResponsesInput.swift`, `Profile.swift` | Ordinary pi mapping is unchanged. An intentional parent effort/default/model/compatibility change can still change the role. It is not a child-status-dependent toggle. | Fixed to the initial resolved role, derived from origin at reopen. Model default still suppresses inherited reasoning options; unsupported developer-role compatibility still selects system. Older origins without a saved initial effort cannot reconstruct unknown historical request settings; configuration changes can require a one-time cache rebaseline. |
| Work-tool list: `Tools.swift`, `RestrictedTools.swift` | Native definitions use fixed array order. MCP is the existing generic schema, not a fresh enumeration of remote tools. Permissions and actual configuration remain authoritative. | Original allowed tool-name ceiling intersects live parent permissions, retaining base order. No delegation tools. Permission narrowing must remove unavailable tools even though that changes the prefix; freezing unauthorized tools for caching would be wrong. |
| Sub-agent tools: `SubagentSteeringContract.swift`, `SubagentTool.swift`, `SubagentEffort.swift` | Fixed parent order: start/send/wait/status/stop. Start model IDs are now sorted, including capability branches; effort vocabulary has fixed order. Per-model capability branches are deterministic. Grant sets are frozen per active parent turn. Real model/capability/map changes can change schemas. | Fixed report schema. No child IDs, roster, progress, cost or timestamps in schemas. Send has the fixed effort vocabulary and no retained-child scan, as implemented by the earlier policy stream. |
| Native model grants | `apps/macos/PiApp/Workspaces/SubagentModels.swift` uses the saved connection's `ModelCatalog.Entry.offered(current:)` list; that list keeps catalog order. Order alone is no longer a schema change. | Model/grants and accepted effort stay subject to the existing coordinator checks. No alternate connection or new capability source. |
| Tool calls/results: `SessionTools.swift`, `SessionAgentReceipts.swift` | Calls and results append in assistant-call order. Background start is an acceptance receipt; later completion does not overwrite it. Wait computes a response once, then stores ordinary result text. Status is a new snapshot only when explicitly called; replay uses its saved row. Interrupted recovery repairs missing outcomes, not previously consumed rows. | Report receipts are acceptance metadata, not a second copy of report text. Native tool-card progress is display state and is excluded from provider input. Tool-result timestamps and `nativeSubagent` metadata are not sent. |
| Agent-event lane: `AgentSteeringMessaging.swift`, `SessionAgentDelivery.swift`, `AgentFamilyJournal.swift` | Reports/results append after complete tool batches. Child FIFO plus fair rotation selects a batch once; persisted order/payload/row ID are replayed rather than reselected. IDs, sequence, bounded task label, turn, author, text, optional correlation and sealed result metadata occur only in the new row. Later accounting corrections do not rewrite a delivered envelope. | Initial task/follow-up are parent-authored rows; running-child steering appends at the next safe boundary. No in-flight splice. Delivery IDs are deduplicated across reopen. Helper-owned provenance never supplies human skill consent. |
| Reasoning replay: `Routing.swift`, `ResponsesInput.assistantItems` | Pinned replay requires matching saved route/binding/observed model. Portable mode consistently omits opaque state; incompatible opaque replay fails or uses the existing portable rule, rather than silently guessing a route. Calls retain IDs and canonical argument text. | The loopback supplies synthetic opaque reasoning on every reply and checks that later requests retain it. Effort itself is not part of the saved replay binding, so this workflow does not drop earlier reasoning when effort changes. Switching model/replay policy/connection is a separate boundary. |
| Cache controls and identity: `Providers.swift`, `SessionSide.swift` | `prompt_cache_key` is the stable chat ID, clamped to 64 characters. `session_id` and `x-client-request-id` affinity headers use the same cache identity; `x-session-id` and body `metadata.session_id` identify the physical chat. No `user` field, `cache_control`, explicit breakpoint or retention setting is added by sub-agents. | Each child has its own original ID/cache key across turns/relaunch, not the parent's side-cache affinity. `x-turn-id` changes with turns, outside the body/prompt. Attempt IDs, cost lineage and consumed delivery IDs belong to local capture/scope, not prompt metadata. |
| Generation/configuration fields | Model, stream/store, fallback setting, output cap, reasoning/include and user-configured sampling fields are inspected separately from prompt bytes. `samplingParams` can override normal body fields under the existing contract; intentionally changed settings are not frozen by this work. Custom headers can also affect gateway routing. | Effort/default changes still change `reasoning` and `include`; output budgets can change caps. These are not claimed cache-neutral. Binding/revision checks preserve routing boundaries. No secrets or real credential paths were used in fixtures. |
| Serialization: `JSON.data`, `ResponsesInput` | `JSONEncoder` already uses sorted keys and no slash escaping. Argument JSON is encoded deterministically. No whitespace/key-order fix was necessary. Appending input changes the raw body's closing array delimiter, so raw-body LCP is not a cache-hit metric. | Same encoder, replayed reasoning items and stable assistant IDs. Fallback message indices remain stable while earlier input is unchanged; compaction/branch edits can legitimately change them. |
| Waiting, retry, Resume and compaction | Family wait sleeps without polling the provider. New events wake a request at a safe boundary. Retries without new input reuse context; refreshed retries append steering/events. Explicit Resume uses saved context and never reexecutes accepted child tools. Summary requests retain the normal prefix and append their summary instruction; committing a checkpoint changes earlier model context. | Follow-ups reopen the same journal and frozen resources. A failed in-flight request is not replayed as a successful assistant item. Summary profile copies now retain the fixed role; post-compaction summary/retained-tail replacement is an inherent prefix break. |

## Measurement method and workflow

`scripts/test-subagent-cache.py` drives the actual package-built helper via `HostPeer` and a loopback HTTP server. The server records the **exact received HTTP body bytes** plus correlation headers for every request. All tasks, policy text, skill catalog, journals, tool files and opaque reasoning are generated under `$B`. The final fixtures set Foundation's `CFFIXED_USER_HOME` to their private directory as well as specifying generated `codexHome`; a generated `.git` directory stops instruction discovery at the fixture root. This isolates both implicit skill roots. No installed app, preferences, Keychain, xctrace, real data or paid provider is involved.

The workflow starts A/B/C in background, holds them in generated bash tools, steers A, receives A's report during a bounded wait, waits for A's result, follows up with A using Model default instead of low effort, receives all results, then sends **five further parent turns**. Those turns alternate two orders of the identical model-grant set. A final parent request is killed without a response; a fresh helper opens the journals without dispatching, explicitly resumes, follows up with the same A using high effort, waits and finishes. There are 16 parent requests, 6 A requests and 2 each for B/C. Test-controlled terminal barriers keep the request sequence deterministic while children still execute concurrently. No production fault-injection switch was added.

For every pair within a physical conversation, the harness measures:

- Raw-body byte LCP, including normal array delimiter changes and request settings.
- A separate canonical prompt projection: a JSON object containing `instructions` (null for this writer) and the complete ordered `tools`, followed by one newline-framed JSON value per complete `input` item. The first item includes the instruction text and role. Nothing is removed from schemas, item IDs, arguments, reasoning or content. Framing avoids treating a closing array bracket as lost prompt content.
- Total estimate = ceil(projected bytes / 4); stable estimate = floor(LCP bytes / 4); reuse percentage = exact LCP bytes / projected bytes. Aggregate estimates use aggregate bytes before rounding. This is an ASCII-heavy serialization proxy, includes JSON overhead and synthetic ciphertext, and is not the app's context counter, a provider tokenizer, a rendered hidden prompt, or an estimate of real encrypted-state token cost.
- A stronger assertion independent of that estimate: tools must be identical and **the entire previous input array must equal the start of the next array**. Model, body metadata and cache identity must also be unchanged. Settings changes are recorded independently.

## Before / after measurements

The final baseline disables the three production protections (child role pin plus v3/v2 enum ordering) to reproduce the original behavior, using the same isolated fixture as the restored run. The earlier untouched-source failing-first run also found those same eight workflow breaks. Raw inputs have equal aggregate size in the final pair. UUIDs and generated paths are intentionally different between runs; comparison is always within each conversation/run.

| Request | Total est. before / after | Stable est. before / after | Reusable before / after | Raw LCP bytes before / after | Cause before → after |
|---|---:|---:|---:|---:|---|
| P1 | 3,431 / 3,431 | 0 / 0 | 0.00% / 0.00% | 0 / 0 | cold |
| P2 | 3,855 / 3,855 | 3,430 / 3,430 | 88.99% / 88.99% | 5,840 / 5,840 | tail → tail |
| P3 | 4,074 / 4,074 | 3,855 / 3,855 | 94.63% / 94.63% | 7,538 / 7,538 | tail → tail |
| P4 | 4,352 / 4,352 | 4,073 / 4,073 | 93.61% / 93.61% | 8,413 / 8,413 | tail → tail |
| P5 | 4,749 / 4,749 | 4,352 / 4,352 | 91.64% / 91.64% | 9,526 / 9,526 | tail → tail |
| P6 | 4,967 / 4,967 | 4,749 / 4,749 | 95.62% / 95.62% | 11,114 / 11,114 | tail → tail |
| P7 | 5,523 / 5,523 | 4,966 / 4,966 | 89.94% / 89.94% | 11,984 / 11,984 | tail → tail |
| P8 | 5,610 / 5,610 | 1,061 / 5,522 | 18.91% / 98.44% | 14,207 / 14,207 | enum order → tail |
| P9 | 5,705 / 5,705 | 1,061 / 5,610 | 18.60% / 98.34% | 14,558 / 14,558 | enum order → tail |
| P10 | 5,800 / 5,800 | 1,061 / 5,704 | 18.29% / 98.37% | 14,937 / 14,937 | enum order → tail |
| P11 | 5,895 / 5,895 | 1,061 / 5,799 | 18.00% / 98.38% | 15,316 / 15,316 | enum order → tail |
| P12 | 5,991 / 5,991 | 1,061 / 5,895 | 17.71% / 98.41% | 15,698 / 15,698 | enum order → tail |
| P13 | 6,094 / 6,094 | 1,061 / 5,990 | 17.41% / 98.31% | 16,080 / 16,080 | enum order → tail |
| P14 | 6,094 / 6,094 | 6,093 / 6,093 | 100.00% / 100.00% | 24,592 / 24,592 | identical Resume |
| P15 | 6,259 / 6,259 | 6,093 / 6,093 | 97.36% / 97.36% | 16,492 / 16,492 | tail → tail |
| P16 | 6,587 / 6,587 | 6,258 / 6,258 | 95.01% / 95.01% | 17,152 / 17,152 | tail → tail |
| A1 | 2,488 / 2,488 | 0 / 0 | 0.00% / 0.00% | 0 / 0 | cold |
| A2 | 2,659 / 2,659 | 2,487 / 2,487 | 93.56% / 93.56% | 5,969 / 5,969 | tail → tail |
| A3 | 2,784 / 2,784 | 2,659 / 2,659 | 95.54% / 95.54% | 6,654 / 6,654 | tail → tail |
| A4 | 2,868 / 2,868 | 2,783 / 2,783 | 97.07% / 97.07% | 7,151 / 7,151 | tail → tail |
| A5 | 2,957 / 2,957 | 2,455 / 2,867 | 83.07% / 96.96% | 29 / 29 | role → tail; effort changes |
| A6 | 3,047 / 3,047 | 2,455 / 2,957 | 80.60% / 97.05% | 29 / 29 | role → tail; effort changes |
| B1 | 2,488 / 2,488 | 0 / 0 | 0.00% / 0.00% | 0 / 0 | cold |
| B2 | 2,568 / 2,568 | 2,487 / 2,487 | 96.89% / 96.89% | 5,969 / 5,969 | tail → tail |
| C1 | 2,488 / 2,488 | 0 / 0 | 0.00% / 0.00% | 0 / 0 | cold |
| C2 | 2,568 / 2,568 | 2,487 / 2,487 | 96.89% / 96.89% | 5,969 / 5,969 | tail → tail |

`P` = parent. All four first requests are cold. Every unmarked comparison appends only new input; P14 replays an identical unanswered input after relaunch. The four cold requests and newly appended tails account for the remaining 13.20% after the fixes. Reuse with unchanged request settings retains **100% of previous projected input** after the fixes (69.16% before). A5 and A6 change effort/include and therefore remain **provider-dependent cache boundaries**, despite their now intact visible prefix.

Every avoidable break and the readable difference:

| Comparison | First differing prompt location before | Difference | After |
|---|---|---|---|
| A4 → A5 | `input[0].role` | `..."role":"developer"...` → `..."role":"system"...` | Initial `developer` retained; default generation options still applied |
| P7 → P8, P8 → P9, P9 → P10, P10 → P11, P11 → P12, P12 → P13 | `tools[8].parameters.properties.model.enum[0]` | `["z-model","fixture-model","a-model"]` ↔ `["a-model","fixture-model","z-model"]` | Always `["a-model","fixture-model","z-model"]` |
| A5 → A6 (cold follow-up) | `input[0].role` | `..."role":"system"...` → `..."role":"developer"...` | Initial role reconstructed from origin after relaunch |

Raw-body differences for ordinary appends are the previous `input` closing `]` becoming `,` plus the new item; fields after the input do not disappear from the provider prompt. A5/A6 also change `include`/`reasoning`, so their **raw** LCP can be short even with an intact projected prompt. Complete numeric first-difference offsets, JSON paths and 150-byte readable before/after windows for **every pair**, including ordinary appends, are in the two `measurements.json` artifacts. `measurements.md` has the individual run tables; `P-NN.json` is named `parent-NN.json` on disk, with A/B/C named similarly.

## Token waste

The final parent input has one report and five result events, with six unique event IDs. None of their `FINDING-*`/`REPORT-A:` content occurs in a tool result. No full `TASK-*` text occurs in wait/start/status receipts. Child A's original task, prior answers, tool outputs and parent steering remain once in its saved conversation. The already implemented result event removes the result envelope's duplicate `text`; only the automatic excerpt is included, not both full and excerpt text. UI and capture provenance do not add another model message.

Status list rows contain child identity, turn, status, effort, delivery state and pending count; they do not repeat full tasks, progress text or full transcripts. Automatic excerpts remain bounded (8 KiB within delivery capacity); larger saved answers are read explicitly by byte page. An explicit `read_result` can repeat text by request, which is correct behavior. Routine progress is not automatically reported, and wait itself issues no model polls.

There is small structural redundancy: each of the four wait results in this fixture is 399 UTF-8 bytes and repeats the same 64-character handle as `operation_id`, top-level `wait_id`, and nested `wait.wait_id`. Removing two copies and their keys could save roughly 40 tokens per wait in a future contract revision. **No receipt fields were removed here**: they are existing addressing/recovery contracts and saved receipts, and replay must not rewrite them. Likewise, task labels and event attribution are useful disambiguation rather than repeated full task bodies. There was no safe large-content trimming needed after the duplicate-delivery checks. Total tool-result text in the final parent input is 2,906 bytes.

## Validation and evidence

| Check | Result / log under `$B/logs` |
|---|---|
| Untouched-source failing-first tests | 3 tests, 6 assertion failures; role and enum regressions, ordinary parity passes — `cache-red.log` |
| Initial actual-helper workflow | 26 requests, 8 broken comparisons — `loopback-before2.log`, `$B/cache-before2/` |
| Initial fixes | 3 tests pass — `cache-green.log`; 26-request workflow has zero breaks — `loopback-after1.log` |
| Real production mutation | Disable child role pin and both schema sorts; 3 tests, 9 assertion failures with isolated fixture — `cache-final-mutation.log`. Restored afterwards. Earlier mutation also failed — `cache-mutation.log` |
| Summary-copy failing-first | 1 test, 2 assertion failures when summary reconstruction loses fixed role — `cache-summary-red.log`; fixed via the same profile-copy preservation path |
| Final affected helper selection | **291 tests, zero failures**, including all 4 `SubagentCacheTests`, subagent/steering/family, routing, pi parity, provider streaming, context, capacities and all compaction classes — `cache-final-regressions.log` |
| Final actual-helper baseline/restored | **26 requests / 22 comparisons each**; baseline 8 breaks, restored zero. `loopback-baseline.log`, `loopback-restored.log`; bodies, headers, summary, table and per-pair diff windows in `$B/cache-baseline/` and `$B/cache-restored/` |
| Native/gallery | Not applicable: no native app or shared UI source changed (`project.yml` checked), no scenes added. Lane inventory inspected. No native build, named xcresult, app launch or full native lane. Gallery paths: none. |

Reproduce in this stream's own build root:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache \
TMPDIR=/Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache/tmp \
swift test --package-path packages/swift-host \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache/swift \
  --jobs 3 \
  --filter 'Subagent|AgentSteering|AgentFamily|PiParityTests|ProviderStreamingTests|RoutingTests|Compaction|TurnCapacityTests|RequestContextTests|ContinueTests'

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache \
python3 scripts/test-subagent-cache.py \
  --binary /Users/admin/Library/Caches/BelloSwiftWork/build-subagent-cache/swift/debug/pi-native-host \
  --label new-run
```

Use a new label; the fixture refuses to overwrite evidence. The first prototype workflow (`loopback-before.log`) exposed a harness assumption: wait can wake on an event before all children settle. The corrected fixture waits on journal terminal barriers before its final collection response; no production wait semantics changed. Earlier fixture artifacts are retained and are not counted as passing runs.

## Remaining boundaries and decisions

- **No guarantee of actual gateway/upstream hits.** The Responses capture shows no Anthropic `cache_control` placement or Chat projection. A gateway that routes to those APIs must preserve its own translated tools/system/messages and arrange supported breakpoints. Its configuration and post-translation bodies were not available in this generated-only task. Do not inject unsupported upstream fields or assume route-group/deployment headers identify a fixed model. `Routing.swift` preserves that distinction.
- **Effort, model/route and configuration changes:** A5/A6 deliberately change effort. OpenAI's documented hidden-prefix behavior means those two comparisons are not evidence of a cache hit, even though visible input is append-only. The exact result on any gateway/model remains unmeasured. New configuration-update inputs require a separate compatibility decision; ordinary non-sub-agent pi prompt behavior is unchanged.
- **Compaction, edits/branches, changed resources/skills/permissions/tool sets and replay-policy changes** are genuine earlier-context changes. Summary generation itself is prefix-preserving at the app-content level; the committed checkpoint is not. Never retain obsolete permissions, stale instructions or incompatible reasoning merely to improve caching.
- **Cold starts, cache expiry/eviction, minimum cacheable lengths and gateway routing** can prevent reuse without any app-visible difference. Reopening a journal retains the cache key; it cannot keep a remote cache resident.
- No receipt schema, semantic tool behavior, permissions, capture policy, vault binding or journal format changed. Existing journals remain readable. The role pin is reconstructed rather than persisted. No transcript-size work was added to views/layout; all changes are helper request/profile/schema construction.
- Lead's independent branch review and integration gate remain. Only this stream branch is to be pushed; no merge, `dev/next` push or release action is part of this validation.
