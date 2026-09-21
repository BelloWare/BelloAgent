# Reliable compaction and overflow recovery — 0.1.64

Baseline: `5957bb7` on `BelloWare/BelloAgent/main`, after the verified 0.1.63
release. Followed the owner's uploaded `Compaction-Implementation-Plan.md`.
Also followed `Compaction-Output-Budget-Addendum.md`, except where the owner's
later correction explicitly requires the same reasoning effort, the model's
allowed output cap, no visible-length target, and summary instructions last.
No subagents, live-provider credentials, installation or updater rehearsal used.

Owner correction, released in 0.1.75 on 2026-09-21: recorded unknown tool outcomes and
warning phrases in tool text no longer block compaction or checkpoint restore.
Compaction preserves their source metadata and never invokes historical tools.
The original uncertainty-blocking requirement below is superseded by this change.

Validation for this correction: **28 helper tests pass** in
`CompactionSafetyTests`, `CompactionTaskRegressionTests` and `QueueHandoffTests`.
New regressions exercise manual/threshold compaction with unknown results,
checkpoint restore, successful reads containing warning text, retained outcome
metadata and zero historical tool invocations. Two existing queue assertions
were updated to the automatic post-compaction handoff released in 0.1.74;
pending text still cannot enter the frozen summary, removed text never runs,
and only the intended session receives the queued message. The first wider run
exposed those stale expectations; the final 28-case run passes. Reproduction:
`swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" --filter 'CompactionSafetyTests|CompactionTaskRegressionTests|QueueHandoffTests'`.
Logs are in session scratch `compaction-outcome-{check,regression,regression-final}.log`.
No native UI change or installation/updater rehearsal was needed. Signing and
public verification are recorded in [0.1.75 validation](validation/Bello-Agent-0.1.75-2026-09-21.md).

## Behavior and schema

- One user task can compact between complete assistant/tool batches. A current
  root, delivered steering and their exact expanded skill/user text remain in
  context. Follow-ups establish a new task; steering keeps its original root.
  Legacy inputs with ambiguous ownership are protected conservatively.
- Complete assistant/call/result groups are indivisible, with occurrence-scoped
  call IDs. Missing/malformed call-result pairs block compaction. Recorded unknown
  outcomes remain historical data and do not block it. A giant
  newest group can be summarized; it does not impose an impossible retention floor.
- Sources include bounded tool arguments, recorded outcomes, image metadata,
  prior summaries and explicit omissions. `history_read` accepts only reachable
  references from this context/checkpoint lineage. It returns valid UTF-8 pages
  of at most 8 KiB from existing records or regular app-owned result files.
  It never invokes a tool again or accepts a model-supplied filesystem path.
- Summaries use the selected connection/model with tools disabled. Chunk, merge,
  explicit summary-input rejection and transient retries share eight physical
  attempts. Each actual request gets a capacity check. Non-shrinking merges,
  incomplete output, output containing tool calls or an insufficiently reduced
  candidate fail before adoption. No partial summary becomes active context.
- **Output allowance:** selected model output ceiling, clipped to actual summary
  request headroom. Explicit task/policy cost ceilings remain respected;
  absent a catalog ceiling, use the configured output budget. There is no fixed
  4,096-token cap. A wire-level bound is required; an incompatible gateway that
  omits output limits gets a clear error. A regression inspects a real built
  summary request with `max_output_tokens: 32768`.
- The reasoning effort and model are unchanged. A separate final user message
  describes the intent to summarize for compaction; no token/character target is
  imposed. Historical records precede it, with no leading summary instruction.
  This makes the prefix eligible for caching, not a guarantee of gateway hits.
- Terminal status, incomplete reason and refusal identity survive both JSON and
  SSE parsing. Distinct `compaction_output_exhausted`, `compaction_source_limit`,
  `compaction_empty_summary`, `compaction_unexpected_tool_call`,
  `compaction_refused` and `compaction_incomplete` diagnoses preserve the original
  context. Diagnostics identify the cap, attempts and known input/output/reasoning
  counts without copying prompt/provider text. Missing usage remains unavailable.
  Only a headroom-clipped cap can get one source-reduction retry to increase its
  feasible allowance. A full-model-cap exhaustion has no larger legal retry.
  The retry consumes the same eight-attempt operation budget. Incomplete fragments
  are never concatenated into the checkpoint. Failed attempts remain accounted
  and linked even when no checkpoint is adopted.
- An explicit typed input/context rejection consumes one synchronized recovery
  allowance and retries only that model operation after reduction. Authentication,
  rate limiting, generic 400, byte-size 413 and invalid output caps are separate.
  Completed tools never re-enter their execution loop. Length-only truncated tool
  responses are preserved, marked not executed, and stop without regeneration.
- Version-2 checkpoints retain ordered source/protected/kept IDs, exact summary
  dependencies, root identity, before/after estimates, requested/counting models,
  fingerprints, physical attempts, output allowance and recovery linkage.
  `nativeCompactionVersion: 2` and `nativeCompaction.version: 2` must agree.
  Unknown versions, duplicate/missing/foreign or incorrectly ordered references
  fail recoverably. Legacy checkpoints remain readable with validated ordering.
- `journal.append(..., flush: true)` synchronizes the checkpoint and preceding
  tool writes. Active context is adopted immediately, without suspension, before
  trace-link publication. Write/sync failures do not publish the candidate;
  uncertain writers are poisoned. Reopen never automatically resumes side effects.
- Metadata also survives saved-side message records. Forks retain history and
  reset operation/recovery state. Boundary-only sides can explicitly report
  unavailable ancestors; they never reach into another session's history.
  Editing a task input abandons dependent summaries, preserving unrelated ones.
- Existing native banners show planning/chunk/merge/retry progress. Large source
  reference arrays stay in the journal, outside recurring status snapshots.
  Summary observations do not replace normal-request context observations.
  Baseline and preview caches are invalidated on adoption; main context is recounted.

## CP01–CP33 acceptance dispositions

All rows have deterministic automated coverage unless qualified below. Native
and final publication results are recorded in the release validation file.

| ID | Disposition / evidence |
| --- | --- |
| CP01 | Pass — single-user regression and actual HTTP golden task compact and continue. |
| CP02 | Pass — planner protects only current task/steering (ambiguous legacy inputs remain protected); smaller-model and delivered-steering regressions. |
| CP03 | Pass — golden gateway receives no oversized raw read-result repeat; preflight folds the completed batch first. |
| CP04 | Pass — multi-call group tests and golden two-read batch; actual Responses replay is checked for orphan calls/results. |
| CP05 | Pass — repeated call IDs in distinct assistant groups retain separate owning results. |
| CP06 | Pass — giant final tool group is summarized; excerpt/source references remain explicit. |
| CP07 | Pass — oversized protected instructions produce `input_too_large`, retain exact input and make no summary request. |
| CP08 | Pass — tiny-window chunk tests independently inspect all built bodies, tools and output caps. |
| CP09 | Pass — merges use the same bounded packer/physical budget; growing intermediates fail without adoption. |
| CP10 | Pass — empty, truncated, tool-calling and failed summaries preserve original context. |
| CP11 | Pass — alleged approval/skill selection remains historical replay data; authoritative instructions and structured selection do not change. |
| CP12 | Pass — minimal write acknowledgements still include requested write/edit arguments and recorded outcome in source. |
| CP13 | Pass — HTTP golden gateway imposes its independent 1,500-byte replay limit after routing and observes one reduction/retry. |
| CP14 | Pass — a second explicit rejection stops after one reduction; journal and completed outcomes remain available. |
| CP15 | Pass — structured classification and existing executable gateway error/retry cases; broad error-message guesses cannot invoke compaction. |
| CP16 | Pass — truncated call arguments never invoke a tool or trigger an automatic model request; normal explicit continuation still preflights. |
| CP17 | Pass — actual gateway counter file has exactly `once\n` after rejection and recovery; write/read tools occur once each. |
| CP18 | Pass — cancellation during first chunk and merge preserves old context and queued input. Revision/profile checks also run immediately before append. |
| CP19 | Pass — deterministic cancellation on the post-commit event preserves the new checkpoint and prevents normal continuation. |
| CP20 | Pass for deterministic before-append/after-append-sync failure injection and reopen projections; no physical power-loss test claimed. |
| CP21 | Pass — injected sync failure blocks memory adoption and poisons the writer; fork/replay is refused until explicit recovery. |
| CP22 | Pass — queued steering is added/edited and another item removed while a summary is held; pending text never enters frozen source. |
| CP23 | Pass — actual delivered steering retains original task identity; original objective and constraint survive compaction verbatim. |
| CP24 | Pass — v2 fork, kept side and reopen projections; missing side ancestors return unavailable and fork sources remain readable. |
| CP25 | Pass — helper and native malformed-reference/version checks; edits abandon dependent summary context without deleting history. |
| CP26 | Pass — counts remain explicitly heuristic/route-uncertain; existing missing/conflicting usage and routed-model tests retained. No live router contract claimed. |
| CP27 | Pass — separate compaction observations, physical attempt capture/accounting and existing native observation/accounting suites. |
| CP28 | Pass — adoption clears baseline/preview, stores a new count, checks actual reduction; failure retains prior successful checkpoint identity. |
| CP29 | Pass — huge single-line Unicode retained output reconstructs through advancing bounded pages; other sessions/missing files cannot trigger replay. |
| CP30 | Pass — disabled automatic compaction, single-task manual compaction and ineligible/empty-context cases. |
| CP31 | Pass — injected small budget counts every chunk/retry, including rejected requests; actual HTTP attempts have operation and output links. |
| CP32 | Pass for injected journal-size failure and unchanged independent storage bounds; compaction never deletes history or promises to remove journal/body limits. |
| CP33 | Pass at helper boundary — twenty concurrent compactions keep cancellation, queued input and recovery state independent. Native twenty-session streaming/capture check is separately recorded; simultaneous native-visible compaction stress is not claimed. |

## Verification and revised oracles

The output-budget addendum's proposed low reasoning effort, 16,384/32,768 caps
and visible-summary target were explicitly superseded by the owner. The shipping
policy preserves the original effort, uses the model allowance subject to actual
headroom/explicit cost ceilings, and places intent-only instructions at the bottom.
`CompactionBudgetTests` covers that policy, full-cap exhaustion, partial output,
missing reasons/usage, refusal/filter/empty/tool outcomes, one headroom-reduction
retry, cancellation, actual reserve/wire agreement and the shared attempt budget.
The streaming HTTP fixture independently rejects oversized requests and checks
effort, instruction position and exact bytes for every failed/successful attempt.
No live gateway caching rate or actual route ceiling is asserted by these tests.

Baseline focused Release tests: **32 passed**. The new one-user regression failed
all three target assertions before implementation, then passed after the fix.
`CompactionSafetyTests`, `CompactionTaskRegressionTests` and
`CompactionGatewayTests` add bounded summaries, branch/queue/storage faults,
recovery and the independent HTTP contract. Existing receipt tests now contain
enough old evidence to make a smaller checkpoint; accepting a larger summary is
no longer the oracle. The old oversized-source test now requires a bounded,
explicitly excerpted summary request and successful continuation. It does not
permit sending an oversized summary request. Tool-schema fixture expectations
explicitly include the new scoped `history_read` capability. Existing exact-body,
performance, queue, permission and accounting assertions remain intact.

The golden fixture validates model, headers, tool set, argument values, complete
call/result pairs and summary envelopes from actual submitted requests. It checks
two checkpoints, one consumed recovery, final continuation, unchanged sibling,
exact captured request/response bytes and identical reopened context. It does
not return success for malformed requests or use Bello's count as its oracle.

See [0.1.64 validation](validation/Bello-Agent-0.1.64-2026-09-20.md) for final
test counts, commands, signing, artifact hash and public verification. Scratch
logs are under the session `tmp/compaction-064` directory, not published as raw
attachments. Linux, live LiteLLM acceptance, physical power loss and installation/
actual updater execution were not tested in this change.

## Remaining explicit bounds

Context is still estimated, not exact tokenization or a guarantee for every
auto-router candidate. Summary source/intermediate material is limited to 2 MiB,
retained full tool results to 16 MiB, individual journal records to 32 MiB and
the journal to 128 MiB. Normal capture retention remains independent. A missing
retained file or a boundary-only side cannot reconstruct unavailable source.
Unknown tool effects need human inspection; no new approval or tool-replay
mechanism was added. These failures retain the conversation and explain the
limit rather than claiming arbitrary-size automatic compaction.
