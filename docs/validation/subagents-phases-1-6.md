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
