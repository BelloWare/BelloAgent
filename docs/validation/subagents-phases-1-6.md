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
