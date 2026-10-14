# Sub-agents in Bello Agent — Design v2

**Status:** Proposed implementation design, incorporating lead review  
**Date:** 2026-10-13  
**Source baseline:** `fb09bc70a257d1cc0f74644531d9ce32a26b58e9`  
**Target:** Swift helper and AppKit macOS application; owner-approved addition to pi 0.85.1 behavior

This document was prepared read-only. No files were changed and no builds or tests were run.

## Changes from v1

- Preserve existing capture preferences, quota, and retention. Defer general Inspector pagination.
- Keep parent journals in their existing format. Create only managed child journals with a v2 native marker.
- Store family accounting in the parent journal through the parent `AgentSession`; remove the separate budget journal and `BudgetScope` actor.
- Keep the model-visible result compact; move identities and result references into `nativeSubagent`.
- Put children behind one folded sidebar disclosure. Remove child unread state and defer child forks.
- Use exactly the saved connection’s existing picker list for model overrides.
- Retain ⌘[ for Back to Parent with explicit focus guards.

## V1 scope at a glance

| Area | V1 behavior |
|---|---|
| Model tool | Synchronous `subagent`; multiple calls can run concurrently |
| Execution | Durable child `AgentSession`s managed by a helper-side coordinator |
| Context | Fresh task context with the parent’s resolved project instructions |
| Tools | Subset of the parent’s effective permissions; no child delegation |
| Models | Inherit parent, or choose an override from its saved connection’s existing picker list |
| Limits | Owner: 16 active children per owning chat; no per-project/helper or per-response cap (extra calls wait); depth 1 |
| Budget | Parent owns the limit and pays for all child attempts, retries, and summaries |
| Recovery | Parent Resume uses `run.continue`; interrupted child calls never restart automatically |
| Transcript | Live tool card in parent; full child transcript in the main conversation area |
| Child interaction | View, copy, find, inspect requests, and Stop |
| Sidebar | One “N sub-agents” disclosure under the parent, folded by default |
| Notifications | Only the parent’s final reply participates; no child unread or notifications |
| Capture | Same policy as parent; typed lineage and family Inspector view |
| Compatibility | Parent journals remain v1; child journals use a distinct v2 marker |
| Rollout | Hidden until execution, accounting, recovery, capture, and UI are complete |

Background delegation, nested delegation, child composers, child Resume, child forks, global capture-quota changes, and general Inspector pagination are deferred.

The owner decisions in §15 are final and are applied below.

## 1. Existing machinery and architectural choice

Paths beginning with `Core/` refer to `packages/swift-host/Sources/PiAgentCore/`. App paths refer to `apps/macos/PiApp/`.

| Existing machinery | Relevant files/types | Reuse or required change |
|---|---|---|
| Session actor and lifetime | `Core/Sessions.swift`, `AgentSession` | Use a real child session; add managed-child identity and family lifetime rules |
| Run loop and retries | `Core/SessionRun.swift`, `SessionSummarizer.swift` | Reuse ordinary turns, retries, overflow recovery, and compaction |
| Parallel tool batches | `Core/SessionTools.swift`, `ToolOutcome` | Dispatch sub-agent calls alongside other tools; preserve result order |
| Resume | `run.continue`, existing continuation receipts | Resume only the parent; recover results before continuing |
| Journal and replay | `SessionJournal.swift`, `SessionReplay.swift`, `JournalCheckpoint.swift`, `SessionCheckpointing.swift`, `JournalSlimming.swift` | Add optional parent records, managed-child records, and durable accounting indexes |
| Existing cost limits | `SessionCost.swift`, `SessionSpend` | Extend to owner totals and physical-attempt deduplication |
| Sides | `HostService.swift`, `SessionPersistence.swift`, `Workspaces/WorkspaceSides.swift` | Reuse durable identity, discovery, and navigation patterns |
| Native tools and MCP | `Tools.swift`, `MCP.swift`, `ToolExecuting` | Enforce a narrower effective tool policy and preserve outcome retention |
| Capture | `Providers.swift`, `TraceStore.swift`, `CaptureDelivery.swift` | Carry immutable request lineage from capture creation |
| App capture/accounting | `Storage/CaptureArchive/`, `Workspaces/WorkspaceAccounting.swift` | Index lineage; update parent totals when child attempts change |
| Transcript | `Transcript/TranscriptToolRow.swift`, native card implementations, `TranscriptActions` | Add a sub-agent card and navigation actions |
| Sidebar and organization | `SidebarList.swift`, `SidebarGroups.swift`, `ProjectSidebarState.swift`, `WorkspaceSessionOrganization.swift` | Add a synthetic child group and family-aware operations |
| Durable UI state | `MetadataStore.swift`, `WorkspaceRunHolds.swift`, `WorkspaceReadState.swift` | Persist relationships and holds; exclude child unread |
| Inspector | `Inspector/Session/` | Add family scope and bidirectional navigation |

### Why children are not sides

Sides have different semantics: inherited conversation context, side-specific cache behavior, read-only execution policy, independent spending, and their own user interaction.

Sub-agents need fresh context, automatic return to a waiting tool call, parent-owned spending, and a managed lifecycle. They therefore use ordinary `AgentSession` machinery through a new coordinator, without calling `side.open`.

An ordinary kept side may itself delegate if it is a durable, eligible project chat. In that case, the side owns the budget. Its existing sidebar parent does not become the budget owner.

### Core invariants

1. Every child belongs to one immutable delegation call and one budget owner.
2. The parent’s journal owns family accounting.
3. Child permissions never exceed the parent’s effective permissions.
4. No child request starts before durable delegation identity and budget admission.
5. A successful child result becomes durable before the parent can consume it.
6. Recovery never executes a previously accepted child call.
7. Capture retains physical request identity; lineage adds relationships without relabeling requests.
8. App registration and visibility are not execution authority.

## 2. Model-facing tool contract

### 2.1 Tool definition

**Name:** `subagent`

```json
{
  "type": "object",
  "properties": {
    "task": {
      "type": "string",
      "minLength": 1,
      "description": "A self-contained delegated task. The child does not receive this conversation."
    },
    "description": {
      "type": "string",
      "maxLength": 120,
      "description": "A short label for the task."
    },
    "model": {
      "type": "string",
      "description": "Optional model ID from the allowed models for this connection."
    },
    "tools": {
      "type": "array",
      "items": { "type": "string" },
      "uniqueItems": true,
      "description": "Optional narrower set of the parent's available tool names."
    }
  },
  "required": ["task"],
  "additionalProperties": false
}
```

The helper also validates UTF-8 byte bounds. `task` uses the existing 256 KiB text-input bound.

The tool description explains that:

- The call waits for the child’s result.
- Multiple calls in one assistant response can execute concurrently.
- Children share the project’s files and the parent’s cost limit.
- The task must contain the necessary context.
- Children cannot delegate further.
- Interrupted calls are not automatically replayed.

`description` is a display label. If absent, derive a short label locally from the task. Do not make a title-generation request.

### 2.2 Availability

Offer the tool only in eligible durable native project sessions with the feature enabled and a compatible helper.

Do not offer it in:

- Scratch and connection-test sessions.
- Title, webhook, or other utility sessions.
- Managed sub-agents.
- Archived or imported read-only histories.
- Legacy transient sides that have not been durably kept.

A read-only project chat may delegate within its actual read-only permissions. A tool appearing in a side’s cache-compatible advertised list is not sufficient authorization.

### 2.3 Model selection

Omitted `model` uses the parent’s effective `turnProfile`, frozen for the delegation.

For an explicit override:

1. The app obtains the same offered descriptors used by the model picker for the parent’s saved connection.
2. It passes that list through the session configuration as `SubagentModelGrant`s.
3. The helper validates the requested ID against the list frozen for the issuing parent turn.
4. Existing model-choice logic supplies supported context, output, and reasoning settings.

Use the existing resolved catalog source and `ModelCatalog.Entry.offered(current:)`; do not add discovery, fallback catalogs, or alternate connection selection.

The grant list does not authorize arbitrary aliases through the picker’s manual-entry affordance. An existing unlisted parent alias remains usable through inheritance.

If the offered list is empty or unavailable, inheritance still works; explicit overrides are rejected. An unsupported gateway model produces the ordinary provider error rather than a silent model substitution.

### 2.4 Child context

A child starts with:

- The parent’s resolved global/project instructions and resource-policy revision.
- A fixed application instruction describing its delegated role and boundaries.
- One user message containing `task`.

It does not inherit parent messages, queued work, drafts, attachments, opaque provider items, or explicitly selected skill authorizations.

A model-written task cannot fabricate an explicit user skill selection. Existing skill-selection rules remain authoritative.

The child has its own provider session identity and cache identity. There is no side-style parent cache prefix.

### 2.5 Scheduling

V1 is synchronous: each tool call completes when its child reaches a terminal outcome.

Recommended limits:

| Limit | Value |
|---|---:|
| Active child runs per budget owner | 16 |
| Active child runs per project/helper | No cap |
| Accepted sub-agent calls per assistant response | No cap |
| Delegation depth | 1 |

A slot covers the whole child run, including its tools, retries, and compaction. It is not released between requests.

Calls beyond the per-owner active limit wait in assistant-call order. There is no per-project, helper, or response cap.

The parent’s existing parallel tool batch remains intact:

- Tool cards finish as their calls finish.
- Results enter model context in original call order.
- The parent proceeds after the whole batch settles.
- Steering is consumed at the existing batch boundary.

There is no background handle, polling tool, or detached task that survives the parent’s execution.

### 2.6 Result text and metadata

The model-visible text is a compact JSON envelope:

```json
{
  "status": "completed",
  "text": "The delegated task's final answer.",
  "truncated": false
}
```

Failure example:

```json
{
  "status": "interrupted",
  "text": "",
  "truncated": false,
  "error": {
    "code": "parent_stopped",
    "message": "The parent was stopped. Effects may already have occurred. This task was not restarted."
  }
}
```

Allowed statuses:

- `completed`
- `output_limited`
- `failed`
- `cancelled`
- `interrupted`
- `not_executed`

The final text is limited to **64 KiB of UTF-8**, cut at a valid boundary. `truncated: true` describes application truncation of the returned text. `output_limited` describes an incomplete answer caused by the provider’s output limit; these are distinct.

Return the child’s final assistant text, excluding reasoning and intermediate tool transcripts. On interruption, any returned partial text must be identified by the non-success status. Empty final text remains empty.

`isError` is false only for `completed`.

The ordinary tool-result row carries local metadata:

```json
{
  "nativeSubagent": {
    "version": 1,
    "delegationId": "...",
    "sessionId": "...",
    "budgetOwnerSessionId": "...",
    "parentAssistantMessageId": "...",
    "toolCallId": "...",
    "resultRef": {
      "messageIds": ["..."]
    },
    "effects": "completed",
    "accountingRevision": 12
  }
}
```

`delegationId`, `sessionId`, `resultRef`, and accounting provenance do not appear in model-visible text.

Use a dedicated `SubagentToolResult` row builder. It must preserve the bounded inline answer instead of triggering `recordTool`’s generic large-output file replacement. JSON escaping and bounded error fields require a somewhat larger serialized-row allowance than the 64 KiB text allowance.

The exact returned envelope and metadata are saved in the child terminal record. Recovery adopts those bytes rather than regenerating an answer or making a summarization request.

## 3. Helper structure and protocol

### 3.1 Proposed types and files

| Proposed file | Responsibility |
|---|---|
| `Core/SubagentTypes.swift` | `SubagentSpec`, `SubagentCallKey`, `SubagentOrigin`, `SubagentOutcome`, `SubagentSummary`, `SubagentModelGrant` |
| `Core/SubagentCoordinator.swift` | Scheduling, runtime registration, cancellation, completion, discovery |
| `Core/SessionSubagents.swift` | Parent tool integration and managed-child command restrictions |
| `Core/SubagentRecovery.swift` | Cross-journal recovery without execution |
| `Core/RestrictedTools.swift` | `ToolExecuting` wrapper with immutable maximum permissions |
| `Core/RequestScope.swift` | Typed request identity, lineage, and request-lifecycle interfaces |
| `Core/RequestAccounting.swift` | Attempt-accounting value types and replay/index logic |

`SessionCost.swift` remains the owner of cost policy and accounting entry points.

There is no separate budget journal and no `BudgetScope` actor.

### 3.2 Identity

A delegation is keyed by:

```text
parentSessionID + parentAssistantMessageID + toolCallID
```

A raw provider tool-call ID is insufficient because IDs can be reused in later responses or other sessions.

Allocate separate stable `delegationID` and `childSessionID` values. Persist:

- Parent session, turn, execution, assistant-message, and request-attempt identities.
- Tool-call ID.
- Child session and budget-owner identities.
- Effective model, tool policy, and configuration revision.
- The reserved parent tool-result message ID.

The budget owner is explicit. It is not inferred by walking sidebar ancestry.

### 3.3 Coordinator ownership

`NativeHostService` owns the coordinator and all managed runtimes, including children the app has not yet registered.

The coordinator creates children through the existing session construction path, with restricted tools and parent accounting access. It does not introduce another provider loop, process, or MCP-hosted agent.

Use the runtime creation gate only during creation/publication. Holding it while awaiting a child would serialize unrelated work.

The current session `runTask` is an independently created task. Cancelling the parent’s task group does not, by itself, provide sufficient child cancellation. The coordinator must explicitly stop every owned child and cancel queued admissions.

### 3.4 Wire additions

| Message | Purpose |
|---|---|
| `ready` capabilities | Advertise `subagents-v1` and `shared-budget-v1` |
| `session.open` / `session.configure` additions | Feature policy and model grants supplied by the app |
| `subagent.list` | Read-only parent/owner-scoped summaries, revision, and cursor |
| `subagent.stop` | Stop one delegation; short acknowledgement |
| `subagents.changed` event | Notify changed family revision |
| `budget.attempts` | App-only paged unresolved dispatch identities registered in the owner journal |
| `budget.reconcile` | App-only submission of retained terminal accounting evidence for a registered attempt |
| Snapshot additions | Child origin, family counts, accounting revision, own usage, owner total |

Reuse existing messages for:

- `session.changed`
- Session snapshots and history/content reads
- Debug capture reads and capture mode controls
- Parent `turn.stop`
- Parent `run.continue`

Do not expose a long-running public spawn command. Model execution happens within the tool call; UI commands continue to fit the existing short acknowledgement model.

### 3.5 Managed-child command restrictions

Persisted managed-child identity controls behavior, independently of `AgentSession.readOnly`.

Reject independent child:

- Submit, steer, retry, Resume, and queue mutation.
- Model, connection, tool-policy, and cost-limit changes.
- Manual compaction.
- Fork, promotion, archive, delete, pin, and topic move.

Allow transcript and capture inspection plus Stop. Internal coordinator operations use a separate authorized path.

## 4. Journals, durability, and recovery

### 4.1 Journal records

| Record | Location | Contents |
|---|---|---|
| `pi-app.subagent-call.v1` | Parent | Immutable call identity, child ID, task/specification, frozen permissions, budget owner, reserved result-row ID |
| `pi-app.subagent-origin.v1` | Child | Validated reciprocal relationship to parent call and owner |
| `pi-app.subagent-state.v1` | Child | Semantic lifecycle transitions |
| `pi-app.subagent-terminal.v1` | Child | Terminal outcome, final-message references, exact result envelope/metadata, accounting revision, uncertainty |
| `pi-app.budget-attempt.v1` | Parent/owner | Durable physical-attempt admission and dispatch/non-dispatch evidence |
| Existing `pi-app.cost.v1` | Parent/owner | One initial contribution per physical attempt, extended with source session and delegation |
| Existing `pi-app.cost.v1` | Child | Child-local mirror of its own attempt contribution |
| `pi-app.cost-update.v1` | Parent and affected child | Rare idempotent replacement of an existing attempt contribution using later validated evidence |
| Ordinary `message` / `toolResult` | Parent | Compact result plus `nativeSubagent` metadata |

Continue using existing native state, task-terminal, compaction, branch, command-receipt, and partial-reply records.

Progress text is not journaled on every token. Persist semantic transitions and ordinary transcript data through existing mechanisms.

### 4.2 Creation ordering

Before dispatching any child request:

1. Validate the tool call and freeze permissions/model grants.
2. Persist the issuing parent assistant row and accepted delegation records.
3. Synchronize the parent journal.
4. Create and publish the child journal with its native marker, origin, and accepted task.
5. Register it with the coordinator.
6. Recheck cancellation and configuration generation.
7. Obtain an active-run slot.
8. Admit its first physical request through the parent’s accounting entry point.

For a response containing several delegations, prepare their records together and synchronize once before starting them.

A stop during creation is checked again after each await. A published child cannot escape the stopped generation.

### 4.3 Completion ordering

Before returning a successful tool result:

1. Settle the child’s provider and tool work.
2. Durably record final usage in the parent journal and the child’s own accounting projection.
3. Persist the child’s final transcript and terminal record.
4. Return the saved result to the parent’s tool batch.
5. Append the batch’s ordinary tool-result rows in call order.
6. Synchronize those rows before the parent’s next request.

A completed child may already be durable while another tool in the parent’s batch is still running. Recovery must preserve that completed result.

### 4.4 Recovery decisions

Recovery examines both the parent call and child journal.

| Durable evidence | Recovery outcome |
|---|---|
| Parent plan, no child publication or admission | `not_executed` |
| Child created, proven never admitted | `not_executed` |
| Request may have dispatched, no terminal child result | `interrupted`; effects and missing cost remain unknown |
| Child terminal exists, parent result absent | Adopt the saved result once |
| Parent result already exists | Keep it; do not append a second result |
| Child missing or damaged after possible execution | Explicit recovery error; no assumed success or zero cost |
| Parent call and child origin disagree | Inspectable recovery failure; no execution |

`Sessions.swift` currently repairs unresolved tool calls during initialization. For recognized delegation calls, defer that repair until `SubagentRecovery` has checked for a durable child result.

The parent is not continuable until this recovery completes. Inspection remains available during recovery or failure.

### 4.5 Stop, pause, Quit, and update

| Action | Behavior |
|---|---|
| Stop parent | Close family admission, stop active children and parent work, cancel queued children |
| Stop one child | Stop only that child; return its cancellation result; parent may continue after its batch |
| Hide or leave a transcript | Work continues |
| Check for Updates | No pause |
| Install update | Existing pause/install flow stops the entire family before helper replacement |
| Quit | Stop families and finish durable settlement within the shutdown flow |
| Helper crash or forced kill | Relaunch recovers a paused parent; no requests start automatically |
| Resume parent | Repair outcomes/accounting, then send `run.continue` |

The parent remains **Stopping** until its children settle or the helper is known lost. App display eviction or missing child metadata cannot make the family appear safely idle.

`AgentSession.close()` currently sets `closed` before awaiting the run, while `countAttempt` ignores closed sessions. Replace this with distinct closing and closed phases:

- Closing rejects new work.
- Accounting callbacks for registered attempts remain accepted.
- Journal release occurs after family settlement.
- If the helper is killed first, unresolved admitted attempts remain recoverable and unknown.

Do not await complete family shutdown from a child’s final-accounting callback. That would create a cycle involving the very child being awaited.

### 4.6 Resume semantics

The parent’s existing `run.continue` path is the sole continuation action.

Resume:

- Adds no new user message.
- Does not relaunch old child sessions.
- Does not re-invoke cut-off tool calls.
- Supplies recovered success, failure, or interruption results to the model.
- Preserves existing continuation-command idempotency.
- Sends queued follow-ups only after the continued turn reaches its normal boundary.

If the model subsequently issues a new delegation, it receives a new identity. Do not deduplicate tasks by prompt text.

Managed children may have an internally paused run state after interruption, but their UI presents **Interrupted**, without an independent Resume action.

## 5. Parent-owned budget and accounting

### 5.1 Storage choice

**The parent owns the budget and the accounting writer.**

Extend the parent’s `AgentSession` with an `AttemptAccounting` value/index and extend `SessionSpend` to expose:

- Owner total.
- Parent’s own contribution.
- Child contributions.
- Reported and unreported cost coverage.
- Token totals and their coverage.

The parent actor can receive accounting calls while suspended in `runToolBatch`. Its existing journal handle remains the only writer to the parent journal.

This is simpler than a separate ledger because it uses the existing:

- Session lock.
- Journal append and synchronization rules.
- Replay and checkpoints.
- Cost-limit configuration.
- Archive/delete lifecycle.
- Durable parent identity.

Reentrancy solves access to the writer; it does not solve durability or deduplication. Those require the changes below.

### 5.2 Physical-attempt records and deduplication

Every normal request, retry, and compaction-summary attempt has a distinct physical attempt ID.

An extended cost record contains:

```json
{
  "attemptId": "...",
  "sourceSessionId": "...",
  "budgetOwnerSessionId": "...",
  "delegationId": "...",
  "purpose": "turn",
  "outcome": "completed",
  "usd": 0.012,
  "reported": 1,
  "unreported": 0,
  "usage": {},
  "accountingRevision": 1
}
```

The optional delegation field is absent for the parent’s own requests.

Rules:

- Persist one initial `pi-app.cost.v1` contribution per attempt.
- Repeated delivery of identical evidence is a no-op.
- Maintain a replayable attempt index; the current 512-entry in-memory guard is insufficient.
- A later validated correction uses `pi-app.cost-update.v1`, replacing that attempt’s contribution rather than adding another charge.
- Apply existing cost validation. Missing, invalid, or conflicting cost is unknown.
- Checkpoints carry the required accounting state and revision; missing support forces full replay.

Existing legacy spend seeds remain unchanged. A chat uses ordinary single-session accounting until its first accepted delegation. That first `pi-app.subagent-call.v1` plan carries an optional `adoptionSeed`: the existing spend at that exact journal boundary, with `reset: true` and `source: family-adoption`. One synchronized append accepts the delegation and establishes the family ledger. Replay resets the derived attempt index to this seed, then counts subsequent physical attempts. Nothing is copied into another store; chats that never delegate retain their existing cost records and best-effort write behavior. Pre-adoption token coverage is unknown rather than zero.

Reconciliation is limited to registered attempts. It must not re-import historical request-log totals already covered by an existing legacy seed.

Child-local records are projections of the same physical attempts. They do not create additional owner or project charges.

### 5.3 Admission before dispatch

Introduce explicit throwing request-lifecycle hooks alongside observation callbacks:

```swift
admitAttempt(scope: RequestScope, attemptID: String) async throws -> RequestPermit
settleAttempt(_ settlement: AttemptSettlement) async throws
```

The parent owns these hooks for itself and its children.

Before every physical request:

1. Allocate the attempt identity.
2. Validate the owner, source session, delegation, and current generation.
3. Check the owner’s reported total against its limit.
4. Append and synchronize the admission record.
5. Register cancellation for the attempt.
6. Create capture with the same identity and immutable lineage.
7. Recheck cancellation before transport starts.

Integrate this into `ModelClient`/`ProviderClient` so it covers both `SessionRun.completeWithRetries` and `SessionSummarizer.summaryReply`.

The current nonthrowing `onObservation` callback cannot serve as a reliable dispatch gate.

A cancelled or failed preparation that is proven not dispatched is recorded as such. If a crash leaves only admission evidence, dispatch and cost are unknown rather than assumed absent.

### 5.4 Settlement and crash recovery

Normally, settle the owner’s cost record first, then the child’s local mirror. Both must be durable before successful child completion is delivered.

If either write fails:

- Preserve the available evidence in the other journal where possible.
- Close admission for the affected family.
- Report an accounting persistence failure.
- Do not continue with an in-memory-only total.

Recovery can repair:

- A parent cost record missing its child mirror.
- A child terminal cost record missing from the parent, after validating the registered attempt.
- A registered unresolved attempt using retained capture metadata through `budget.reconcile`.

A may-have-dispatched attempt without reliable terminal evidence contributes an **unknown request**, not a zero-cost request.

Capture being off, expiring, or hitting its configured quota does not erase journal accounting.

Corrupt or contradictory accounting authority blocks further family requests until recovery succeeds. Legitimately unreported gateway pricing retains the application’s existing partial-cost behavior; it does not invent a price.

### 5.5 Limit enforcement

When the owner’s reported spend reaches its limit:

1. Close admission immediately.
2. Invalidate outstanding request permits.
3. Cancel active provider requests, retry waits, child tools, and summaries.
4. Cancel queued delegations.
5. Stop the parent and hold its follow-ups.
6. Continue accepting final accounting for already-admitted attempts.
7. Present the owner’s cost-limit notice.

This family behavior applies to delegation-enabled families. Unrelated ordinary-chat cost behavior is not otherwise redesigned by this feature.

Lowering a family’s limit below its current reported total also stops the family. Raising or removing the limit does not restart anything automatically.

The limit cannot be a guaranteed exact billing ceiling: concurrent requests already admitted may report cost later, and some providers do not report cost. Display that coverage honestly.

### 5.6 Budget lifetime and display

The owner total includes previous turns and all delegated work, including interrupted tasks and earlier transcript versions. Editing, compaction, and archiving do not refund spend.

Ordinary sides and ordinary forks retain their existing independent budgets.

Display:

- **Parent footer:** family total, with “This chat” and “Sub-agents” breakdowns.
- **Child footer/card:** own usage and “Charged to parent.”
- **Cost-limit editing:** available through the parent.
- **Parent inline assistant metrics:** that response’s own request metrics.
- **Turn/family reports:** physical attempts counted once.
- **Project/global reports:** physical attempts counted once, without adding parent rollups again.
- **Context ring:** the selected session’s context occupancy, not family token consumption.

Late child accounting must invalidate the parent’s cached totals even when neither transcript is visible.

Do not sum concurrent elapsed durations and present the result as wall time.

## 6. Parent card and child transcript

### 6.1 Parent tool card

Extend `ToolView` with optional `SubagentToolView` data and add `.subagent` to the native card selection.

Proposed implementation: `Transcript/TranscriptNativeSubagentCard.swift`, using existing native work-line/card components and `PiKit` styling.

Collapsed card:

- “Sub-agent” and short description.
- Queued, Running, Retrying, Compacting, Stopping, or terminal status.
- Elapsed time and compact activity indication.

Expanded card:

- Full task through a bounded viewport.
- Effective model and tool policy.
- Current phase/tool and completed-request/tool counts.
- A short latest-output preview.
- Returned result and truncation indication.
- Child usage.
- Open, Inspect Requests, and Stop actions.

Do not show a fabricated percentage or copy the child’s entire reasoning stream into the parent.

Preserve the existing default-collapsed behavior and manual disclosure state across updates.

Coalesce progress publication, targeting existing low-frequency metric updates. Terminal state changes publish immediately. UI batching does not alter capture.

Update both helper projections and offline `HistoryReader` decoding so reopened cards behave consistently.

### 6.2 Child transcript

Use the normal `ConversationPaneView` and transcript renderer for:

- The task message.
- Assistant responses.
- Native tool cards.
- Compaction.
- Errors and interrupted partial output.

Replace the composer with an input-free footer showing status, own usage, parent attribution, and Stop when applicable.

V1 children have no:

- Composer or draft.
- Follow-up or steering queue.
- Message editing.
- Resume.
- Manual compaction.
- Fork or promotion.

Copy, find, file links, and request inspection remain available.

## 7. Navigation and keyboard

### 7.1 Main-area navigation

Open a child from:

- The parent card’s title/Open action.
- An expanded sidebar sub-agent group.
- Inspector lineage links.
- Search results.

Show a breadcrumb or Back to Parent button above the child transcript.

The parent-return target includes the issuing assistant message and tool-call identity. Reuse `TranscriptReveal` to restore the parent and reveal that card, including when it belongs to an earlier transcript version.

Preserve the parent’s scroll position, folds, composer state, and draft. If the parent is unavailable, retain the child viewer with an explanatory navigation state.

Opening a child through a card does not unfold its sidebar group.

Extend every `TranscriptActions` forwarding adapter so the action survives normal, historical, and alternate transcript presentations.

### 7.2 Keyboard behavior

- Tab reaches the card’s navigation and disclosure controls.
- Return/Space activates the focused control.
- Existing ⌥⌘↑/↓ navigation continues through visible chat rows.
- A sub-agent group disclosure is keyboard-expandable but is not itself a chat.
- Hidden child rows are skipped by ordinary adjacent-chat navigation.
- ⌘[ activates Back to Parent when the child conversation owns focus.

Implement `canBackToSubagentParent` with explicit checks:

- Workspace window is key.
- Main conversation displays a managed child.
- First responder belongs to that conversation.
- No sheet or keyboard-owning picker covers it.
- Parent target exists.

The action is disabled while focus belongs to a file tab, Git panel, terminal, or Inspector.

### 7.3 Verified existing bindings

| Surface | Source finding |
|---|---|
| Application menu | Bracket folding shortcuts require Option, optionally Shift |
| File viewer | Explicit shortcuts cover Find, Go to Line, and find navigation |
| Git panel | Back-to-file button has no ⌘[ binding; diff keyboard handler does not claim it |
| Terminal | Command keys pass onward; Control-[ remains Escape |
| Inspector | ⌘[ and ⌘] navigate requests and retain that behavior |

Implementation tests must verify actual responder routing, not just menu declarations.

## 8. Capture and request Inspector

### 8.1 Immutable lineage

Add typed `RequestScope` data before `TraceStore.begin` publishes its first event.

Retain physical:

- Session ID.
- Turn and execution ID.
- Attempt ID.
- Request purpose.
- Model and connection identity.

Add optional delegation lineage:

- Delegation ID.
- Budget-owner session ID.
- Parent session, turn, execution, assistant-message, and tool-call IDs.
- Parent request-attempt ID.

A child compaction request remains purpose `compaction`; it is not relabeled merely as “subagent.”

Provider headers and body metadata keep the child’s actual identity. Parent grouping must not alter `x-session-id`, message links, or provider-visible identity to make requests look as though the parent sent them.

### 8.2 Capture policy

Children use exactly the parent’s effective capture policy:

- Off, memory, or persistent mode.
- Existing credential masking and disclosure rules.
- Existing quota.
- Existing retention and deletion behavior.
- Existing acknowledged delivery and export semantics.

Apply parent capture-mode changes to active managed children through the coordinator. Children cannot choose a different capture mode.

There are no new sub-agent byte, event, request-count, or result-preview caps on capture. The 64 KiB tool result and UI previews do not truncate captured request/response bodies.

This feature does **not** change `CapturePreferences.quotaBytes`, `quotaUnlimited`, defaults, settings controls, or archive quota enforcement. The existing quota versus the owner’s no-cap rule is a separate workstream.

### 8.3 Archive schema and queries

Extend typed attempt columns with nullable lineage fields and indexes for:

- Workspace plus budget owner.
- Workspace plus delegation.
- Parent request/tool-call relationship.

Preserve physical `message_links`: a child’s answer is not an output of the parent’s HTTP request.

Keep delegation relationships available even for children that never dispatched a request. A small rebuildable relationship table can support those Inspector groups.

Existing rows have null lineage and retain their present interpretation.

### 8.4 Inspector presentation

The parent Inspector defaults to **This chat + sub-agents** once the chat has delegated work.

Provide filters for:

- This chat only.
- This chat + sub-agents.
- A selected sub-agent.

Group child requests beneath the issuing parent request/tool call. Within each child, show its own requests, retries, and compaction in order.

Provide bidirectional links:

- Parent card → delegation Inspector group.
- Parent request → child requests.
- Child request → parent request and originating card.
- Child transcript → its own request and family Inspector.

Add `InspectorFocus.subagent` and a corresponding group page or navigator selection.

Request models and body readers must use the selected request’s actual child session. Existing previous-request comparisons stay within that physical session, rather than accidentally comparing siblings.

### 8.5 Existing 5,000-row window

Keep `InspectorArchive.inspectorRows`’ existing window size and older-row indication.

Family grouping requires:

- Scoped lineage queries.
- Group summaries independent of which request rows are loaded.
- Direct lookup of an explicitly selected linked request outside the current window.

It does not require loading every retained request into the navigator.

Do not render a missing group parent as if capture were absent merely because its request lies outside the current window. Fetch the relationship or requested target directly.

General older-request pagination remains a follow-up unless implementation demonstrates a specific family-navigation failure that cannot be handled by these focused queries.

## 9. Sidebar, notifications, organization, and search

### 9.1 Managed-child identity

Extend `ChatRecord` with optional typed delegation metadata while retaining `parentSessionID` for ancestry.

Distinguish:

- Ordinary chat.
- Ordinary side.
- Ordinary fork.
- Managed sub-agent.
- Utility/background session.

Narrow the current broad “parented and not fork” side classification. A managed child must never inherit side editing, composer, or promotion actions.

Default decoding preserves existing records. Metadata merges must not drop delegation identity or overwrite newer organization state.

### 9.2 Folded sub-agent group

Add a synthetic `SidebarEntry.subagentGroup(parentID: …)` directly beneath the parent:

```text
Parent chat
  ▸ 12 sub-agents
```

When expanded:

```text
Parent chat
  ▾ 12 sub-agents · 3 running
      Check parser behavior
      Review journal recovery
      …
```

The group:

- Is folded by default.
- Has its own persisted disclosure state.
- Is separate from ordinary side folding.
- Appears consistently in Topics and Flat views.
- Is not a `ChatRecord`, a request, or an accounting row.
- Shows compact activity counts without unread indicators.
- Keeps children out of the ordinary side-row projection.

Creating or updating a child does not unfold the group. Manual expansion persists. Search can temporarily reveal matching children without changing the saved default.

Cards and the Inspector are the primary entrances.

### 9.3 Running, stopping, and paused state

The parent remains running while it awaits children.

Family state must influence:

- Sidebar state.
- Stop availability.
- Quit/update quiescence.
- Idle eviction.
- Project/connection changes.
- Archive/delete eligibility.

Persist a compact family extension to `RunHoldRecord` for immediate launch presentation. Journals and coordinator state remain authoritative.

After interruption:

- Parent shows Paused/Resume where eligible.
- Children show their recovered terminal or interrupted statuses.
- No child shows an independent Resume affordance.

Child progress does not rebuild sidebar ordering per token. Meaningful lifecycle changes may update family activity under the existing sorting rules.

### 9.4 No child unread or notifications

Managed children never create:

- Unread markers.
- Dock badge contributions.
- Completion sounds.
- Generated titles.
- Webhooks.
- Manual Mark as Unread actions.

Do not introduce a detail-unread record.

Labels come from `description` or a local task fallback. Child failures appear in their cards/group state and are returned to the parent; they do not independently notify the user.

Only the parent’s final reply uses the normal reply-notification path.

Children have no drafts. Parent draft persistence and its sidebar indicator remain unchanged.

### 9.5 Archive, delete, move, and fork

Archive and restore operate on the parent and its managed children as a family. Archive uses the existing stop-before-archive path, extended to all coordinator-owned children.

Topic moves follow the parent. Children cannot be independently pinned, moved, archived, or deleted in v1.

Deletion:

- Uses the existing confirmation and settled-work requirement.
- States how many managed children are included.
- Checks helper-owned work, including children missing from app metadata.
- Uses a durable deletion intent/tombstone to prevent rediscovery.
- Cleans journals, stream artifacts, checkpoints, metadata, and relevant capture relationships through existing storage paths.
- Remains recoverable after partial filesystem failure.

Ordinary sides retain their existing organization semantics.

Forking a **child** is deferred.

Existing forks of a **parent** still work. Copied delegation history is provenance, not ownership: the fork must not adopt children, revive runs, inherit original charges, or take over their Stop controls. Its budget follows existing fork-reset semantics.

### 9.6 Search

Index each child’s task, label, and ordinary transcript through `ChatSearchIndex`.

Search results:

- Identify the child and its parent.
- Show matching snippets.
- Reveal the correct message in the child viewer.
- Expose the matching child through its group while the search requires it.

The parent’s in-transcript Find searches its own transcript, including returned tool text. It does not silently combine all child histories.

Index meaningful saved content using existing background scheduling, not every streamed token.

## 10. Permissions, MCP, vault, and data boundaries

### 10.1 Effective tools

The maximum child policy is:

```text
requested tools
∩ parent’s effective executable tools
∩ current project permissions
− subagent
```

With the recommended default, omitted `tools` inherits the parent’s effective set, excluding `subagent`. An empty array gives a tool-free child.

Explicitly requested forbidden or unknown tools produce validation errors.

`RestrictedTools` must enforce the policy in:

- Advertised definitions.
- Capability enumeration.
- Actual invocation.

Filtering definitions alone is insufficient.

A permission narrowing during a run applies before subsequent invocation. Permission widening does not expand an already-created child’s frozen maximum.

Children share project files; this does not introduce isolated worktrees or editing locks.

### 10.2 Project and vault identity

The model cannot select:

- Another project or working directory.
- Another trusted-root set.
- Another vault.
- Another connection or credentials.
- Another capture policy.
- Another budget owner.

Model grants contain effective model settings, not alternate endpoints or credential access.

Continue using the parent helper’s workspace and vault binding.

Existing native tools accept absolute paths under their current policy. “Same project” is not a new OS filesystem sandbox guarantee.

### 10.3 MCP

Reuse the workspace’s MCP manager, enabled-server configuration, and allowed-tool policy.

A child cannot gain MCP invocation authority merely because the top-level `mcp` definition is visible. Preserve current read-only restrictions and actual allowed-tool checks.

MCP annotations are not permission grants.

Namespace invocation/outcome-retention identity by session and issuing assistant/tool-call identity. Concurrent children can reuse provider call IDs.

Preserve:

- Invocation deadlines.
- Unknown-outcome markers.
- Durable tool-result synchronization before retention acknowledgement.
- Protection against late callbacks from closed/replaced managers.

### 10.4 Approvals and instruction boundaries

The existing native path does not provide a general new per-tool approval broker. This feature preserves project trust, tool modes, vault access, and existing confirmations.

It does not invent blanket approval from delegation.

Any approval path must remain scoped to the actual child operation and identify its parent. A child cannot approve its own permission change.

Task text, child output, MCP content, and compaction summaries cannot modify helper-owned grants, workspace bindings, or explicit skill-selection authority.

## 11. Compatibility, discovery, and migration

### 11.1 Parent journals remain unchanged in format

Do not rewrite parent journals or change their native marker.

Parent additions are optional custom records plus ordinary assistant/tool-result messages. Existing record IDs and published history remain intact.

App metadata and capture-database changes are additive. Derived checkpoints may be regenerated; that is not a parent journal migration.

### 11.2 Child-only v2 marker

New child journals use:

```text
customType: pi-app.native.v2
```

They must not also contain a v1 native marker.

The old helper recognizes the v1 marker by its custom type and does not enforce its `data.version` as a format gate. Therefore:

- A v1 marker with `version: 2` is insufficient.
- A distinct v2 custom type causes the current old helper’s writable-open check to reject the child.
- Both full-open and checkpoint-open paths must be tested.

New helper and app readers accept v1 parents and v2 managed children.

### 11.3 Downgrade behavior

An old helper can continue opening parent journals:

- Unknown delegation/accounting custom records are ignored.
- Ordinary saved tool calls/results remain valid.
- Unresolved calls receive the existing generic interrupted tool result.
- No child is automatically re-executed.

Known limitations:

1. The old helper does not enforce shared family admission or cancellation.
2. It understands ordinary `pi-app.cost.v1` figures already written into the parent, but ignores newer admission and reconciliation semantics.
3. It cannot adopt a child’s terminal result when the parent result was not yet saved.
4. Old UI may not understand managed-child organization or controls.

After upgrading again, an already-written parent tool result remains authoritative for that call. Do not replace it with a different child answer. The full child history remains inspectable, and accounting can still reconcile independently.

These limitations are documented and accepted; they do not justify rewriting existing parents.

### 11.4 Replay, checkpoints, and slimming

Update together:

- `SessionReplay`.
- Full-history and durable replay paths.
- `SessionCheckpointing`.
- `JournalCheckpoint`.
- `JournalSlimming` equivalence checks.
- App `HistoryReader`.

The derived checkpoint schema must identify support for delegation and accounting indexes. Unsupported or incomplete checkpoints fall back to full replay.

Equivalence checks include:

- Delegation ownership.
- Terminal outcomes.
- Attempt identities and contributions.
- Accounting revisions.
- Pending recovery state.

Unknown custom records remain preserved.

### 11.5 Discovery independent of app registration

The helper publishes child identity before any request can dispatch.

The app upserts `ChatRecord`s from validated coordinator summaries. A failed metadata save does not orphan the runtime or allow it to evade Stop.

At launch, reconcile managed child journals off the main thread and rebuild missing metadata.

Validate:

- Parent and child reciprocal identity.
- Session-directory containment.
- Same workspace.
- Explicit budget ownership.
- No cycles.
- Originating parent session matching the journal header.

A copied parent journal or fork does not acquire ownership simply because it contains old delegation records.

An orphan or invalid child remains inspectable but cannot execute.

Recovery support remains active for existing data even when the new-tool rollout flag is disabled.

## 12. Failure handling

| Failure | Required behavior |
|---|---|
| Invalid model/tool grant | Error result; no child request |
| Queue slot unavailable | Queued card; cancellable before dispatch |
| Parent stops during creation | Published child is stopped or marked not executed before request admission |
| Provider transient error | Existing retry policy; each retry separately admitted and accounted |
| Child compaction | Existing compaction safeguards; every summary attempt charged to parent |
| Child tool has uncertain effects | Preserve uncertainty in journal, card, and returned error |
| Child fails while siblings run | Return that outcome; siblings continue unless owner/family cancellation applies |
| Family limit reached | Close admission and stop all family work |
| Cost or result synchronization fails | Stop further admission; retain recovery evidence; no fabricated success |
| Child finishes before parent result append | Recover terminal result once |
| Parent batch contains repeated tool IDs across turns | Match full call identity |
| App fails to register child | Helper still owns, stops, accounts, and discovers it |
| Capture off, quota reached, or expired | Existing policy applies; accounting remains independent |
| Helper dies | Parent paused; no automatic child execution |
| Parent result already repaired by old helper | Preserve it; do not rewrite transcript history |
| Parent/child files inconsistent | Explicit recovery state; inspectable, execution blocked |
| Delete partially completes | Resume cleanup through tombstone; do not rediscover deleted children |
| Shutdown deadline expires | Preserve available partial output and durable uncertainty; do not report clean completion |

## 13. Validation plan

Write failing-first tests for behavioral changes. Mutation-check the critical guards under the repository’s workflow.

### 13.1 Helper unit tests

Add suites covering:

- `SubagentContractTests`: schema, eligibility, model grants, compact results, metadata exclusion.
- `SubagentExecutionTests`: scheduling, parallel execution, ordered results, child-only Stop.
- `SubagentRecoveryTests`: every creation/completion crash boundary and no replay.
- `SharedBudgetTests`: parent ownership, admission, limits, deduplication, correction, unknown cost.
- `SubagentBoundaryTests`: tool subset, project/vault identity, MCP policy, managed-child command rejection.
- `SubagentJournalTests`: marker compatibility, reciprocal origin validation, checkpoints and slimming.

Extend existing continuation, parallel-tool, retry, compaction, request-shape, cost, side, and MCP-retention suites.

Specific regressions:

- More than 512 attempts followed by replayed accounting evidence still counts each once.
- Owner accounting works while the parent awaits its batch.
- Owner close continues accepting registered final usage.
- A child’s cost-limit callback does not deadlock waiting for itself.
- Parent cost saved/child mirror missing and the reverse recover without duplication.
- No registered attempt is converted from unknown to zero.
- Child-specific model metadata never changes connection identity.
- A read-only side’s advertised editing definitions do not authorize child editing.
- A 64 KiB result plus envelope remains model-visible text.
- `nativeSubagent` metadata never enters provider tool-result text.

Mutate or remove cancellation fan-out, subset checks, admission synchronization, durable deduplication, and terminal synchronization; the corresponding tests must fail.

### 13.2 Real-helper integration

Use loopback provider fixtures and the packaged helper to demonstrate:

- Several children overlap.
- Each has distinct request/session identity.
- Retry and summary attempts charge the parent exactly once.
- Parent synthesis begins only after ordered durable results.
- Parent Stop cancels registered children even when app metadata is absent.
- Quit/update handles the family.
- Resume performs no old child request or tool invocation.

SIGKILL the helper at controlled barriers:

- After parent plan persistence.
- After child publication.
- After request admission.
- During child streaming/tool execution.
- After child terminal persistence.
- Before/after parent tool-result synchronization.

Count actual network requests and external tool effects after reopening and Resume.

### 13.3 Downgrade tests

Run the actual previous helper against fixtures produced by the new format:

- Parent opens and retains ordinary tool-call/result validity.
- Unresolved delegation is repaired without execution.
- Child writable open is rejected.
- A child with a forged v1 marker demonstrates why marker type matters.
- Re-upgrade preserves the old helper’s existing parent result.
- Accounting reconciliation does not duplicate old `.cost.v1` charges.
- Parent forks/clones do not adopt copied delegation ownership.

### 13.4 App tests

Cover:

- Card action forwarding and stable disclosure.
- Main-area child viewer and exact Back target.
- Earlier-version parent cards.
- No composer, draft, Resume, or fork actions in children.
- Family totals and physical-attempt-only global totals.
- Child updates invalidating hidden parent accounting.
- Folded group defaults, persistence, Topics/Flat behavior, and search reveal.
- No child unread, Dock, sound, title, or webhook activity.
- Parent drafts surviving navigation.
- Family archive/delete and metadata-registration recovery.
- Inspector parent/child links using the correct session and body.
- Linked requests outside the 5,000-row window.
- Keyboard focus in conversation, Inspector, file viewer, Git panel, terminal, sheet, and picker.

### 13.5 Gallery scenes

Add `UIScreenshotTests` scenes in light/dark, at 920×600 and a wider size:

- Collapsed and expanded running cards.
- Several running/queued children.
- Completed, failed, cancelled, interrupted, output-limited, and truncated results.
- Child transcript with Back to Parent.
- Parent paused after relaunch.
- Family cost-limit notice and usage breakdown.
- Family Inspector grouping.
- Folded/expanded sidebar groups in Topics and Flat.
- Parent unread/draft state with children having neither.
- Search-revealed child.
- Missing-parent and recovery-error views.
- Long task labels, keyboard focus, and reduced motion.

### 13.6 Performance and release checks

Measure:

- Four concurrent children streaming.
- Stop and shutdown latency.
- Parent card updates without transcript-wide relayout.
- Sidebar stability without per-token rebuilds.
- Child/parent switching and scroll restoration.
- Capture delivery during concurrent requests.
- Family Inspector queries and targeted outside-window navigation.

Use `scripts/check-next.sh` and required release checks. Run serial-lane classes alone.

Keep the known scratch-helper shutdown issue separate from new regressions; do not treat an existing failure as a passing result.

## 14. Phased implementation and hidden rollout

Work through reviewable workstream commits toward `dev/next`, following `NEXT-RELEASE.md`.

The public tool remains unavailable and production entry points remain hidden through phases 1–11. Tests and gallery fixtures may enable the feature explicitly. Parsing and recovery for existing managed data are not disabled by the rollout flag.

| Commit | Deliverable |
|---|---|
| 1. Types and protocol | Delegation identity, optional wire fields, capabilities, managed-child metadata, disabled feature gate |
| 2. Child journal format | V2 child marker, v1 parent compatibility, custom records, replay/checkpoint support, downgrade fixtures |
| 3. Permissions and grants | Restricted tool executor; exact existing picker-list grants; managed-child command restrictions |
| 4. Parent accounting | Durable attempt index, extended cost records, correction/replay rules, no separate ledger |
| 5. Request admission | Typed `RequestScope`, throwing lifecycle hooks, retries/summaries, family budget cancellation |
| 6. Coordinator and tool | Durable child creation, bounded scheduling, synchronous tool, compact result builder |
| 7. Stop and recovery | Parent/child cancellation, settlement ordering, real-helper crash barriers, `run.continue`, shutdown |
| 8. Capture lineage | Immutable lineage at capture creation, archive columns/indexes, inherited capture policy, parent accounting invalidation |
| 9. Family Inspector | Grouping, filters, bidirectional links, correct physical-session reads, direct outside-window lookup |
| 10. Transcript navigation | Live card, main-area viewer, Back target, focus-scoped shortcut, action forwarding |
| 11. Sidebar and organization | Folded group, no child notifications, search, discovery, archive/delete, parent-fork provenance |
| 12. Enable and validate | Complete gallery, integration and performance checks, documentation, clean whole-change review, then enable |

Each commit includes the necessary failing-first tests and focused validation. Phase boundaries may be split further if a change becomes difficult to review.

Do not expose a partially implemented version that can run children before budget ownership, cancellation, durable recovery, capture lineage, and managed-child restrictions are complete.

Update pi-parity documentation to identify sub-agents as an owner-approved addition. Update release notes and `NEXT-RELEASE.md` when implementation actually lands.

Future implementation follows the repository’s commit/push workflow. This design revision remains read-only.

## 15. Owner decisions (2026-10-13)

- **Default when `tools` is omitted:** inherit the parent's effective tools (option A). The model can narrow them and never widen them.
- **Scheduling limits** (owner: "unlimited, maybe 16 at most for a given session, unlimited per project"):
  - at most **16 active children per budget-owner chat**;
  - **no per-project or per-helper limit**;
  - **no per-response limit** on accepted calls: calls beyond 16 active wait for a slot in assistant-call order;
  - delegation depth stays one.

  This supersedes the 4/8/16 figures used elsewhere in this document.

## Implementation notes

- Round 7 validation also found that a transport failure followed by process exit notified the workspace twice for one helper connection. `HostSupervisor` now reports loss once per connection and resets that guard on reconnect, so family interruption/update handling runs once. A generated two-reconnect regression and both guard/reset mutations cover it.

- Round 7 merges the isolated native test host, TTFT-inclusive output speed and SCROLL-14 cancellable reads before testing. Family totals reuse the common physical-attempt throughput calculation; retained-version around-message reads keep the cancellable helper pager.
- Round 7 captured-cost recovery: cold parent opening pages unresolved registered dispatch identities through `budget.attempts` (128 per wire page, no total limit). The app reads only retained terminal metadata for those IDs in the same workspace and budget owner, then submits compact evidence through `budget.reconcile` before returning the host to Resume/send callers. Exact saved `RequestScope`, attempt, source, turn, purpose and delegation must match. Missing or unreported capture remains unknown. Corrections flush `cost-update.v1` to the owner before writing the child mirror; repeated evidence does not charge twice. A mirror failure keeps the owner charge and closes admission until reopen recovery repairs it. All restored family readers are released under the existing runtime gate before mirror writes. Live sessions and chats that never delegated do not run recovery. The model's already-written tool result is unchanged.
- Round 7 missing-child recovery: a durable dispatched admission or a completed parent outcome requires its child journal, including for already-paired calls. Missing/damaged evidence blocks opening for execution; saved journal inspection remains available. Accepted but never-dispatched children may still settle as not executed.
- Round 7 output ownership: both shell logs (including short, failed and crash-left output) and oversized tool results now belong to `Sessions/tool-output/<physical-session-id>/`. This is helper-supplied identity, never a model argument, and symlink/traversal aliases are rejected. Family deletion recycles only its members' directories as part of the existing durable intent. Older flat UUID outputs without any ownership evidence cannot safely be assigned to a chat; they are left intact rather than guessing and deleting another chat's data. No released sub-agent data uses that old layout. The physical-session layout also permits future follow-ups without changing ownership.
- Round 7 cleanup: filesystem enumeration failures retain the deletion intent; only an absent directory is harmless. Exact `.<journal>.meta.<UUID>` checkpoint temporaries are removed under the journal's existing writer lock on open and included in family deletion. Unrelated/malformed temporary names are preserved. MCP discovery keeps no invocation-retention mapping; actual invocations retain the existing durable-result/unknown-outcome rules.

- Round-5 navigation review: `WorkspaceModel.select` owns live managed-child attachment, including reselection. Cards validate their immutable target before selecting; sidebar, search, Inspector, report/menu-bar links and launch restoration converge on the same selection path. `revealMessage` also passes an already selected child through it. A cold saved child still opens from its journal without starting a helper or resuming work. Inspector lineage actions share `showSubagentParent` and bring the main window forward; standalone child Inspectors resolve the immutable origin from child metadata or the owner's retained capture group. Parent request → Show in Chat uses the issuing attempt's delegation link too.
- Round-5 retained-version review: the delegating turn need not be the edited turn. The read-only `session.versions` query now accepts `containing: <assistantMessageID>` and returns the containing group's usual `versions`/`current`, a 1-based `selected` version and a visible `anchor`. Nested edits can leave the containing group with no current member; the anchor then belongs to a visible ancestor. `session.version.page` still pages the selected old version around the exact assistant row, and `TranscriptReveal` targets its tool-call ID. No journal, branch, draft or model context is rewritten by this lookup.
- Round-5 discovery review: the app distinguishes a recorded terminal outcome from the disk scanner's interrupted fallback. That fallback cannot replace a live listed summary during topic moves or archive/restore. Helper loss invalidates nonterminal summaries, and late listing callbacks check the helper connection before publishing. Discovery metadata uses the existing `ChatRecord.merged` rules so an older callback cannot undo a newer committed topic move or archive.

- Round-4 recovery review: every cold session construction releases all idle restored child readers belonging to that budget owner under the helper's existing runtime gate. This covers sidebar Resume, parent previews, Back to Parent and multiple open siblings; live queued/running/settling jobs remain pinned and other families remain attached. `session.unloaded` invalidates the app's opened set and cancels any overtaken child-opening task before it can reinsert stale state. Recovery cleanup no longer depends on one navigation action.
- Round-4 listing review: preparation is tracked before the accepted plan is persisted, so a list during creation reports queued rather than interrupted. Rejected preparations retain their actual terminal status until parent consumption. Listing reads the parent's journal state and revision together, then retries if coordinator state changed during that await; pruned jobs cannot turn an earlier snapshot into a false interruption. Old-helper recovered outcomes retain the interrupted fallback. No journal or capture format changes.
- Round-4 organization review: archive replacement selection removes the parent's newly archived managed family together, including when the selected transcript is a child. The ordered ordinary-chat fallback policy and independent side organization remain unchanged. Live listing and disk discovery also compare and store canonical child journal paths, allowing macOS path aliases while rejecting a different file, workspace or origin.

- Round-3 review: deletion validates owner paths before detaching the helper or saving tombstones. Owners accept the existing `<id>.jsonl`, `fork_<id>.jsonl` and `side_<id>.jsonl` names inside the project's session directory; managed children retain their strict UUID filename. The same validation handles durable deletion retries, including intents written before this correction.
- Round-3 review: an explicit manual compaction request may use a paused owner's family accounting without resuming queued follow-ups. This is a request-local allowance, limited to the independent owner's manual summary and its retries; Stop generation, permit cancellation, closed sessions and cost limits are still checked at admission and dispatch. Ordinary requests and automatic summaries cannot use it.
- Round-3 gallery review: the sub-agent disclosure button sizes to its Pi face within the available width. Its chevron stays at the same indentation as progress counts change between the parent and child scenes; selected-child reveal still leaves the saved fold unchanged.

- Post-audit review: opening a managed viewer reads the helper's inherited capture mode and does not send `debug.mode`. Sidebar child selection uses the same validated live-runtime opening path as a parent card. A selected child temporarily reveals its group; leaving it restores the saved disclosure state without writing a preference.
- Post-audit review: parent topic moves pass only independently selected roots to the metadata transaction, which discovers and moves their managed descendants atomically. Child-only moves remain prohibited.
- Post-audit review: cancellation during delegation preflight settles all already-journaled assistant calls as not executed before ending the turn. Resume therefore works without reopening and never replays those calls.
- Post-audit review: after durable terminal settlement, the host evicts coordinator-created children that were never explicitly opened. `session.open` pins a child reader until normal unload; opens, closes, forgets and eviction share the runtime gate and eviction checks runtime identity. Cleanup is awaited from an uncancelled task so Stop cannot skip it. Durable summaries, transcripts and accounting remain available after eviction.
- Post-audit review: explicit Inspector request links widen an excluding family filter through its normal setter, keeping request rows and usage scope synchronized, including when the requested row is outside the 5,000-row navigator window.

- Phase 12 Inspector review: overview aggregates and model pages now use the same family/physical-session filter as the request navigator. Their cache key includes that filter and the workspace boundary remains enforced. Only the family overview uses the parent's complete live footer and budget-spend figure; filtered pages use physical capture totals. Empty loaded footers fall back to captured family totals, and snapshot observers consume the newly published value instead of the previous value. Global/project metrics remain physical, without double counting or new capture limits.
- Phase 12: the sole `SubagentPolicy.enabled` switch is enabled after phases 1–11. There is no preference, environment or wire override. The model-facing tool is still subject to durable-session eligibility and the inherited permission boundary. The owner's effective-tool, 16-active/FIFO and depth-one decisions are unchanged.
- Phase 12 compatibility review: an older helper's existing cut-off tool result is preserved verbatim. The upgraded helper projects child navigation from the owning parent's accepted plan without rewriting that model-visible result. Generic `unknown` results display as interrupted. A missing or invalid child file retains its Inspector group and does not prevent healthy siblings from registering; only a validated header becomes a transcript entry. Expanded child groups remain contiguous when the parent also has an unsaved side.
- Phase 12 large-family review: managed metadata is excluded from the existing 10,000 ordinary-chat window, so accepted children cannot evict their parent or vanish on relaunch. Ordinary-chat limits and per-record validation stay unchanged. Durable deletion intents use a complete, strict read instead of the generic capped metadata listing; a family larger than 10,000 members is recovered in full, and a damaged intent cannot silently disappear. This does not change capture policy or the Inspector's request window.
- Phase 12 desktop downgrade recovery: when an older app saves a child record without the new fields, discovery rebuilds its absent managed identity from the validated child header and reciprocal parent plan. The existing workspace/path must match; a conflicting saved identity still fails closed. An older app's saved title is retained. Journals remain the authority, without migrating parent journals.
- Phase 12 full-gate correction: idle tool schemas use the current picker grants, while active turns retain their frozen grants. Previously a reopened idle helper advertised an empty model enum, invalidating an otherwise compatible saved usage baseline. A context preview may describe the app's current picker selection without granting it to execution or writing a journal; duplicate/invalid grants are rejected. An actual idle grant change invalidates the old preview. The strict loopback fixture now requires the enabled tool in its exact capability list, and the native fork fixture asserts deliberate fallback from its old derived checkpoint.
- Phase 12 gallery correction: a narrow sidebar uses a fitting child-count label so the Pi disclosure button's chevron stays visible. Running/queued counts remain complete in its tooltip and accessibility label; wider rows show them inline. This changes presentation only, with no limit on family membership.
- Phase 12 validation uses generated data, in-memory credentials, loopback gateways and an isolated test-host bundle identifier. `check-next.sh` selects another branch and build root, so its underlying checks are run directly in the authorized worktree and `PI_BUILD_ROOT`. Installed-app, signing/Keychain, paid-provider and public-release checks are outside this task. The detailed record distinguishes fixture measurements and preserved passing checks from a public-release certification.

- Phase 11: managed children have a separate, initially folded disclosure in Topics and Flat. Expansion is a desktop preference; search reveals matching children without saving expansion. Children never contribute unread/failure/draft markers, completion sounds, webhooks, title jobs or independent run holds. The parent's hold can persist active/queued family counts. Archive/restore and topic moves follow the owner; saved sides retain their existing independent archive behavior.
- Phase 11 discovery streams child headers and parent plans without opening a helper. Reciprocal origins, workspace containment and terminal delegation IDs are checked. Missing/mismatched parents produce a view-only recovery entry; copied parent plans do not transfer ownership. Queued tasks are indexed from the complete accepted parent plan (the desktop preview alone is not the search source).
- Phase 11 deletion takes an unload-and-rescan barrier after confirmation, including when the preview reported zero children. This closes a race with a first delegation accepted while the sheet is open. Each member has its own durable deletion intent and permanent tombstone; child journals, sidecars, captures and metadata are removed before the parent. Partial deletion retries after relaunch without another confirmation. Late metadata/capture callbacks cannot recreate family entries. The capture archive must open before retrying cleanup. Production rollout remains off through this phase.

- Phase 10: parent cards use the existing native tool rows, disclosure state and action relays. Coalesced child progress updates at most four times per second and does not advance the discovery revision; terminal metadata saves the model, effective tools, local usage and final progress for offline cards. The child viewer has no composer, draft writes, editing, Resume, independent cost control or fork. Its Stop routes to the coordinator. Only the owning parent's card has Stop authority; copied cards retain navigation provenance.
- Phase 10 navigation validates the child header and project directory before registering a view. Back and Inspector links share one path, release a restored idle child reader before parent recovery, and reveal the exact tool card. The existing `session.version.page` accepts an optional `around` message ID, validated within that version, so a linked card beyond the first loaded page of an edited version remains reachable without loading its entire transcript. Focus-scoped ⌘[ is tested against real main-window, file-viewer, Git, terminal, Inspector, sheet and picker responders; the Inspector keeps its own Back binding.

- Phase 9: `CaptureSubagents` keeps rebuildable, workspace-scoped group summaries even for queued tasks with no request. Capture establishes reciprocal identity if packets arrive before journal discovery; terminal summaries cannot be revived by late live evidence. `subagentsRevision` changes for delegation state, not ordinary token events, and the app pages `subagent.list` only when that revision changes. The final metadata/sidebar discovery layer remains phase 11.
- Phase 9 Inspector: family/own-chat/selected-child filters retain the existing 5,000-row window. Selecting a child queries that child's own window. An explicit linked request gets one scoped direct lookup outside the window; it does not remove the window or cap capture. Typed physical-session fields route bodies, raw events, summaries, exports and comparison baselines. Group pages and navigation use lazy request rows. Request-kind labels are computed once per index, avoiding repeated scans of a long turn. Exact originating-tool navigation is completed with the transcript reveal work in phase 10.

- Phase 8: shared `RequestScope` is validated against the physical capture and immutable after `begin`. Capture schema 6 adds nullable lineage columns and indexed family/tool-call relationships; old rows are backfilled in pages without changing raw metadata. Metric-expiration tombstones keep identity. Parent chat totals include its children's physical attempts; child totals remain local and global/project dashboards do not duplicate spend. Inline answer attribution and timing comparisons remain physical-session scoped. Hidden parents are invalidated directly from capture lineage before child metadata is discovered.
- Phase 8 capture policy uses a validated child-to-owner binding in `TraceStore`, so each future attempt reads the parent's current mode without racing a fan-out of mode commands. Existing attempts retain their original policy. Reopened child readers inherit the binding too; child controls cannot change it. Existing capture quota, retention, credential masking, delivery and export rules are unchanged.

- Phase 7: reopen reconciles parent plans and child evidence before `run.continue` can launch. A saved child terminal envelope, metadata and result ID are adopted byte-for-byte; an existing parent result (including an old helper's repair) is preserved. Marker-only v2 child creation is completed from the accepted parent plan only when no other child content exists. Dispatched attempts without cost remain unknown; an admission without dispatch intent can be marked not dispatched. Child cost evidence must match the owner's registered attempt, and missing mirrors are repaired without duplicate owner charges. Inconsistent origins, result identities or unregistered charges fail closed.
- Phase 7 lifecycle: direct child Stop cancels its coordinator job, including queued work, and host shutdown drains coordinator completions before detaching child journals. The merged helper's closing-session accounting already accepts registered final charges while `closed` rejects new work; a second closing-state enum is unnecessary. A live queued/settling child remains pinned. A child runtime restored for viewing has no live coordinator job and may unload; the helper releases all such family readers before cold parent recovery under the runtime gate, then viewers can reopen if needed. This avoids a second writer to any sibling journal on every parent-opening path.
- Phase 7 crash validation uses a generated copy of the actual helper under `PI_BUILD_ROOT`, with the single policy switch enabled and SIGSTOP barriers injected only in that copy. SIGKILL/reopen/Resume uses the unmodified helper. No environment or IPC override exists in production. The test covers plan/origin/admission/dispatch/owner-cost/child-cost/terminal/parent-result persistence, external tool effects, Stop, update quiescence and shutdown. Parent results always precede resumed synthesis; no child or cut-off tool is replayed.

- Lead review after phase 6 (2026-10-14): family accounting now activates only inside the first accepted `registerDelegation`, with an atomic adoption seed in that plan. The pre-delegation request keeps the ordinary accounting path, including journal-write failure behavior. A preserved side follows the same activation path. Reopening a parent with its own plans restores family ownership; a fork never adopts copied plans.
- Coordinator review fixes: owner slot/queue keys consistently use `budgetOwnerSessionID`; cancellation generations include the parent runtime identity. Child submission checks its original Stop generation, and unfinished children cannot unload their journals. After synchronized parent result consumption, terminal jobs, rejections, queues and cancellation bookkeeping are removed; paged discovery uses the parent's replayed call order/outcomes with live-job overlays. Parent close also releases terminal jobs. A throwing restricted MCP invocation drops only its private retention mapping, leaving the base executor's unknown-outcome evidence intact. Copy-based forks omit admissions and corrections along with cost records.

- Phase 6: the hidden helper coordinator creates durable children without `side.open`, freezes the parent's resolved resources and actual executable tools, and uses the existing run loop. It owns independent FIFO queues with 16 active slots per owner; paged `subagent.list` preserves assistant-call order without imposing a call or capture limit. Completed jobs release their runtime/credential/parent references after saving and publishing their exact result.
- Phase 6 creation detail: each accepted parent plan is synchronized before its child is created; all plans are prepared before any child starts. This currently uses one flush per plan instead of §4.2's proposed batch flush, favoring simple durable ordering across actor awaits. The queued task is durable in the parent plan; the child receives its ordinary `Submission` only when it gets a slot. Existing submission delivery immediately launches a run, so delaying it avoids a separately resumable child queue. Phase 7 recovery must derive queued outcomes from these plans without submitting them.
- Phase 6 permissions detail: child origin/plan records retain a helper-only frozen MCP server-configuration digest; calls recheck it under the existing invocation/configuration gate. A changed configuration conservatively refuses further child MCP calls, including changes that only narrow permissions. This avoids silently widening the original grant; it adds no editing lock or new catalog. Capture mode is copied unchanged at creation; dynamic family capture controls and archive lineage remain phase 8.
- Phase 6 settlement detail: completed result text is limited to 64 KiB at a UTF-8 boundary before JSON encoding. JSON escaping does not trigger the generic tool-output file fallback. Stable IDs and references remain in `nativeSubagent`. Parent Stop cancels queued and active jobs by execution generation; a late callback cannot cancel a later Resume generation. A late accounting correction that reaches the limit also stops the family, and null token fields remain unknown.
- Phase 6 checkpoint: production remains disabled. Real-helper crash/relaunch adoption and shutdown barriers remain phase 7; archive/Inspector/UI/discovery/organization work remains phases 8–11. Live in-process Stop/Resume coverage is not a claim that crash recovery or release validation is complete.
- Phase 5: `ModelClient` has an explicit throwing lifecycle overload; clients that cannot honor it fail closed for a managed request. Scope and physical ID enter `TraceStore.begin` now, before any capture packet; archive indexing/UI work remains phase 8. Dispatch intent is synchronized before transport; a permit cancelled before transport can durably correct that intent to `not_dispatched`. Ordinary sessions keep their existing between-request cost-limit behavior; an enabled family cancels all permits at its limit and accepts already-admitted final charges.
- Phase 4: admissions provisionally count as unknown requests until settled or proven not dispatched. The existing journal owns the complete attempt index, replacement revisions and usage totals; snapshots read cached totals rather than scanning all attempts. Checkpoint helpers without this index fall back to a full replay. The cost fixture now supplies its actual source session identity, since accounting rejects unrelated-session observations.
- Phase 3: the existing picker descriptors supply model grants; a submission retains the offered list so queued turns cannot inherit a later list. Restricted executors recheck live definitions and keep the original read-only ceiling. MCP result-retention keys are invocation UUIDs, mapped back from each child's model call IDs. No extra MCP host or catalog was added.
- Phase 2: only child journals use `pi-app.native.v2`. The derived `.meta` checkpoint version advances to 2 so it cannot omit delegation state; journal bytes are not migrated. An actual `v0.1.125` helper accepts the v1 parent and refuses the v2 child without writing it. The generated Xcode project also picks up phase 1's shared source and tests.
- Phase 1: the shared `SubagentPolicy.enabled` constant is the single production rollout switch. There is no preference or IPC override. Model grants and origin types are shared source between the helper and app. Parent metadata keeps managed origin immutable across stale updates. The scheduling table now reflects the owner decisions in §15.
- Base: `dev/a126-helper` already includes closing-session accounting; preserve and extend that implementation instead of reverting to the older lifecycle described in §4.5.
