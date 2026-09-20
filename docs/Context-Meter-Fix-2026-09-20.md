# Context meter scope and lifetime fix — 2026-09-20

Implements the owner's uploaded Context-Meter-Fix-Plan against `2f7621e`, following
the 0.1.64 compaction changes and 0.1.65 activity/retry changes. Native Swift
architecture, Responses transport, gateway usage parsing and exact captures stay
in place. No new token counting endpoint or tokenizer is introduced.

## Cause and implementation

The baseline retained a heuristic count while busy, independently published a
manual preview, then expired that preview on any later event sequence. An old
fallback could reappear without the replay input changing. A new optimistic send
could also promote a previous request's report, and reset adoption retained old
fallback state. Two native regression tests reproduced four failed assertions on
the unchanged implementation before the fix.

The helper now sends an additive version-1 `contextState` envelope, with session,
runtime epoch, replay revision, request generation, presentation phase, current
request and historical request. Unchanged envelopes are omitted by a separate
`contextStateRevision`, including when metrics are omitted. State is captured in
one actor turn before trace awaits; lightweight reads never wait on trace links.
Durable message/checkpoint adoption and applicable configuration changes advance
replay revision. Streamed partial output, usage arrival and undelivered queue edits
do not. The existing compaction mutation counter is reused; journals need no
migration.

A new request publishes `preparing` plus its bound estimate immediately, before
recorder preparation. Allocated attempt/body identity follows; `awaiting` is
published after transport starts. Native idle submissions also show preparing
before their first await. Queued/steering messages do not reset an active request.
Rejected submissions and delivery failures reconcile that local pending state.
Existing helper purpose/session/generation and event-order guards remain.

The pure native `ContextPresentation` resolver is shared by footer and inspector:

- Current request: bound estimate until valid input usage arrives, then reported
  input with its dispatch-time capacity. A lower report, including zero, is valid.
- Tools/retry wait: explicitly labeled last-request input. This does not claim to
  count upcoming tool results.
- Idle: a matching next-input preview, or pending while its inputs change. Prior
  usage remains available in historical details.
- Compaction/restart/reset: pending for the new scope, never an old current count.

Previews retain small immutable count metadata after detailed body cleanup.
Singleflight and adoption check semantic input identity, configuration and draft
bindings, plus existing connection/selection guards. Startup callers can join the
same snapshot once its first epoch is known. Output-event sequence traffic cannot
expire it. The helper checks replay/profile/resource/tool inputs across awaits,
excludes incomplete tool groups at the last complete boundary, and never assigns
its preview count to `currentContextCount`. The complete serialized preview still
has its own body fingerprint and resource/tool/profile binding, distinct from
actual dispatched bytes. External resource files are re-read on preparation;
there is no new filesystem watcher, and the existing five-minute cache bound
remains.

## Acceptance evidence

These are executed native reducer/helper/integration checks, not a claimed
reproduction of the owner's installed application's exact path. `ContextScopeTests`
exists in both the app and helper test modules.

| Plan ID | Evidence / outcome |
| --- | --- |
| CTX-01 | Baseline native rollback/reset tests fail first, then pass; fresh busy heuristic accepted; same-input preview survives status events. |
| CTX-02 | Held helper preview survives 200 text/thinking/usage/queue events without input revision change; singleflight reuses its calculation. |
| CTX-03 | Native new-submission test hides the prior 12k report before helper reply; rejection/early delivery failure reconciles pending state. |
| CTX-04 | Native current-request estimate 42k accepts 40k and zero; configured dispatch capacity stays fixed. |
| CTX-05 | Tool-boundary historical scope changes to a new generation estimate; older generation delivery is rejected. |
| CTX-06 | Different retry attempt/generation remains distinct; helper observation and executable gateway retry/recovery suites pass. |
| CTX-07 | Prior observation cannot replace pending next-input draft; automatic debounce tests retain exact preview provenance. |
| CTX-08 | Controlled tool-definition await permits status traffic but rejects a committed replay append; queue/steering delivery tests pass. |
| CTX-09 | Successful compaction increments replay once, clears current observation and labels reset; native lower compacted preview is accepted. |
| CTX-10 | Failed/invalid summaries keep replay revision/generation unchanged. Existing stop-before-commit and durable-after-commit tests pass. |
| CTX-11 | Native baseline clears fallback; old-epoch state rejected after restart. Existing host/connection lifecycle tests pass. |
| CTX-12 | Metrics-free helper snapshots carry transitions and omit unchanged envelopes. Native omitted fields retain same-key state. |
| CTX-13 | New-generation null current observation clears the slot; null count clears fallback. Unkeyed envelope null cannot retire live state. |
| CTX-14 | Existing helper session/purpose isolation plus native cross-pane identity tests; compaction observations never own the main generation. |
| CTX-15 | Existing missing/zero/invalid/interim/final parser tests pass; input never adds cached/output/reasoning subsets. |
| CTX-16 | Active request retains original model/capacity while next-preview model differs; existing frozen resource/model preview tests pass. |
| CTX-17 | Actual loopback request held while preview/read/clear repeats three times: serialized request bytes, fingerprint, preflight count, generation and replay revision remain unchanged. Both primary views call the same resolver. |
| CTX-18 | Native startup sharing, changed-input serialization, cancellation ownership and new-epoch join tests pass; helper semantic revision guards reject stale input. |
| CTX-19 | Fake recorder preparation holds before any attempt observation; metrics-free snapshot immediately exposes preparing estimate without a trace read. |
| CTX-20 | Usage-only native test observes zero transcript publications. Optimized helper streaming benchmark remains below its CPU/frame budgets; exact capture tests pass. |

## Local diagnostics

Optional `BELLO_CONTEXT_DIAGNOSTICS=/absolute/path/context.json` enables a local,
rotating snapshot of the last 256 selection changes. It records only IDs, epoch,
replay revision, generation/attempt, scope, reason, method, estimated/reported
status and token count. Unchanged selections are suppressed. Writes are coalesced
and performed off the main actor with restrictive permissions. No prompt bodies,
headers, keys, skill text or serialized configuration are recorded or uploaded.
Normal releases leave this disabled. A boundedness/privacy regression test passes.

## Validation boundaries

[0.1.66 validation](validation/Bello-Agent-0.1.66-2026-09-20.md) records exact runs,
shipping revision and public artifact verification. No live deployed LiteLLM
request, physical GUI reproduction, install or Sparkle update rehearsal was run.
The loopback validates our request/usage/capture contracts, not a guarantee about
all gateway routes. Context heuristics and upstream usage provenance retain the
limitations in [Context accounting](Context-Accounting.md).
