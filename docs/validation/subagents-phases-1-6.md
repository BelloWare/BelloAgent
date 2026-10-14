# Sub-agents implementation checkpoint

Branch: `dev/subagents`, base `e15798ed`. Build root for every invocation:
`/Users/admin/Library/Caches/BelloSwiftWork/build-subagents`.
Only generated fixtures, in-memory vaults and loopback providers are used.
The production feature switch remains off through this checkpoint.

## Phase 1 — types, identity and hidden protocol

- Shared owner/call identity, model grants, status and summary types; a single
  `SubagentPolicy.enabled = false` switch controls production capabilities.
- Optional managed-child metadata survives decoding and stale metadata updates.
- Updated the design's old scheduling table to the owner's 16-per-owner rule.
- Failing first: `SubagentMetadataTests` failed both tests before implementation.
- Green: `scripts/test-macos.sh -only-testing:PiAppTests/SubagentMetadataTests`:
  2 passed. This class is in the parallel lane.
- Green: `swift test --scratch-path "$PI_BUILD_ROOT/swift-tests" --filter SubagentContractTests`
  from `packages/swift-host`: 3 passed.
- Mutation: removed the budget-owner equality guard; the owner-boundary test
  failed. Restored it and reran the helper class successfully.
- Logs: `$PI_BUILD_ROOT/logs/phase1-{red-app,green-app,helper-final,mutation-helper}.log`.

No UI was exposed. Later phases add execution and read-only child controls.

## Phase 2 — child journals

- Child-only native v2 marker, immutable origin and planned-call records,
  terminal/state replay, checkpoint and slimming preservation; local result
  metadata round-trips separately from model text. Parents remain v1.
- Failing first: opening a v2 journal failed with `legacy_session`.
- Helper: `SubagentJournalTests`, `JournalCheckpointTests`,
  `JournalSlimmingTests`: 20 passed after correcting the checkpoint fixture
  to include a context boundary. App: `HistoryReaderCheckpointTests` and
  `SubagentMetadataTests`, invoked with a bash array: 8 passed, parallel lane.
- Mutation: accepting copied foreign plans as live ownership fails the fork
  boundary test. Restored; all 20 helper checks pass again.
- Built the actual `v0.1.125` helper from `git archive` into the build root.
  `scripts/test-subagent-downgrade.py` passes five checks with generated data:
  writable v1 parent; interrupted result without a request or replay; v2 child
  refusal; unchanged child bytes; rejection keyed by marker type, not version data.
- Logs: `$PI_BUILD_ROOT/logs/phase2-{helper-final,app,mutation-helper,downgrade}.log`.

## Phase 3 — permissions and grants

- Restricted definitions, capabilities and invocation; inherited read-only
  policy, frozen MCP server ceiling and separate invocation retention identities.
- Exact existing picker grants, saved with submissions; managed children reject
  independent submit/configure, fork, Resume, queue, manual compaction and MCP
  invocation commands. Viewing and Stop remain available.
- Failing first: the managed child accepted both independent submit and configure.
- Helper: `SubagentPermissionTests`, `ContinueRunTests`, `MCPResultRetentionTests`:
  29 passed. Mutations removing either the read-only ceiling or managed-session
  command guard failed the new behavioral tests; restored and all 29 passed.
- App: `SubagentModelGrantTests`, `ModelSwitchTests`, bash array, parallel lane:
  23 passed. The focused grant class passed again after aligning input kinds
  with the picker's connection-plus-descriptor rule (`phase3-app-final.log`).
- Logs: `$PI_BUILD_ROOT/logs/phase3-{red-helper,helper-final,app}.log` and
  `phase3-mutation-*.log`. The feature remains hidden.

## Phase 4 — parent journal accounting

- Replaced the 512-entry memory-only dedup guard with a durable attempt index.
  Existing cost records remain readable; registered corrections replace charges;
  admission-only records count unknown; fork reset clears authority and spend.
- Added cached usage rollups and accounting revision, checkpoint/replay and
  slimming equivalence. Accounting write failures block new requests.
- Failing first: redelivery after reopening charged $1.50 instead of $0.75.
- Helper classes: `SubagentAccountingTests`, `CostLimitTests`,
  `JournalCheckpointTests`, `JournalSlimmingTests`: 31 passed after restoration.
- Mutations: dropping the checkpoint index doubles a charge; bypassing the
  accounting-failure guard admits after a failed write. Both failed behaviorally,
  then were restored. An earlier mutation run hit a fixture compilation error;
  it is not counted as mutation evidence.
- App classes: `CostLimitTests`, `SessionAccountingCacheTests`, parallel lane:
  18 passed, invoked with a bash array. Logs: `$PI_BUILD_ROOT/logs/phase4-{red-helper,helper-final,app}.log`
  and `phase4-mutation-*.log`.

## Phase 5 — request admission and family cancellation

- Throwing admission/dispatch/settlement hooks on the provider path, with typed
  immutable scope before capture, physical attempt IDs and cancellation permits.
- Owner settlement precedes child mirroring. A family limit cancels permits and
  pauses the owner, while late final charges remain durable. Raising the limit
  does not revive old child work. Turns, retries and summaries share this path.
- Failing first: the provider did not invoke the new admission callback.
- `SubagentAdmissionTests`, `CostLimitTests`, `ContinueRunTests`, `RetryTests`:
  41 passed. A real loopback gateway verifies three durable dispatch admissions
  before three HTTP attempts. The summary fixture verifies retry accounting.
- Mutations: capture before admission, live permits after family Stop, and a
  summary bypassing admission each fail the respective behavioral test.
- Additional `CaptureTraceTests`, `CredentialCaptureTests`,
  `CompactionRequestShapeTests`: 24 passed. App classes `CostLimitOpeningTests`,
  `RequestContextObservationTests`, `WireContractTests`: 15 passed, one existing
  environment-dependent WireContract test skipped (parallel lane, bash array).
- Logs: `$PI_BUILD_ROOT/logs/phase5-{red-helper,helper-final,capture-helper,app}.log`
  and `phase5-mutation-*.log`.

## Phase 6 — coordinator and synchronous tool, still hidden

- Durable helper-created children, fresh frozen resources, inherited effective
  tools and saved-connection model grants. No `side.open` or second provider loop.
- Independent per-owner FIFO queues: 16 active children, including retry/tool/
  summary time. Eighteen-call coverage proves queuing and original result order;
  two owners run 32 children together. Discovery pages have stable call order.
- Parent-owned settlement, family Stop at the limit, individual child Stop,
  queued cancellation, depth one and no automatic delegation replay on live
  parent Resume. Terminal persistence precedes synchronous result resolution.
- UTF-8-safe 64 KiB result text stays inline after JSON escaping; local identities
  and full-result references stay in `nativeSubagent`, outside model text.
- Frozen MCP policy is persisted, immutable and checked at invocation; completed
  jobs release the parent/connection/runtime graph. A closed child journal fails
  closed rather than publishing an in-memory outcome as durable. Late corrections
  reaching the budget cancel live permits; null token fields stay unknown.
- Failing first: explicit fixture activation did not advertise the tool;
  completed jobs retained the parent; a closed journal appeared to save a
  terminal; null usage looked known; discovery was cached as a mutation; and
  replay dropped the frozen MCP policy. Each regression was demonstrated before
  its fix. Logs: `phase6-red-helper.log`, `phase6-lifetime-red.log`,
  `phase6-closed-child-red.log`, `phase6-projection-red.log`,
  `phase6-mcp-origin-red.log` under `$PI_BUILD_ROOT/logs`.
- Helper: **143 passed**, zero failures (`phase6-helper-final.log`). Filter:
  `Subagent|CostLimitTests|ContinueRunTests|ParallelToolCallTests|ToolRecordingFailureTests|ToolOutcomeTests|MCPResultRetentionTests|MCPConnectionTests|JournalCheckpointTests|JournalSlimmingTests|RetryTests|CaptureTraceTests|CredentialCaptureTests|CompactionRequestShapeTests|ResourceCatalogTests|HostDispatchTests`.
- Eleven deliberate mutations fail behaviorally: active-slot limit, nesting,
  result byte bound, inline result handling, MCP invocation policy, correction
  cancellation, hidden rollout, unknown token usage, discovery refresh, terminal
  durability and immutable origin policy. Every source was restored. The final
  affected-class run passes **40 tests** (`phase6-restored.log`); individual
  mutation evidence is `phase6-mutation-*.log`.
- The actual `v0.1.125` helper again passes all five downgrade fixture checks
  (`phase6-downgrade.log`): v1 parent open, interrupted call repaired without a
  request, child refused for writable open, unchanged child bytes, marker-type
  gate. No installed application, Keychain or provider account was used.
- Native app: `SubagentMetadataTests`, `SubagentModelGrantTests`,
  `WireContractTests`, passed as a bash array to `scripts/test-macos.sh`.
  `scripts/test-lanes.py list` classifies all three parallel: **13 passed**, one
  existing opt-in performance test skipped, zero failures (`phase6-app.log`).
  The skipped WireContract case requires `PI_PERF_WIRE=1`; it is not counted as
  passing. No serial-lane class was included.

Implementation differences and the reasons are recorded in the design's
**Implementation notes**: flush each parent plan before child creation; keep
queued tasks in the durable parent plan until their slot starts; conservatively
reject child MCP calls after any configuration change. These do not change the
owner's tool, concurrency, depth or budget decisions.

This is the requested phase 6 checkpoint. The production switch is still false.
Real-helper crash/relaunch recovery and shutdown barriers, capture archive work,
Inspector, AppKit navigation/sidebar/organization and final enablement remain
phases 7–12. The checks above are focused implementation evidence, not the release
gate, gallery review or final whole-change review. No new owner decision is needed.
