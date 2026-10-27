# AGENTS-1 helper validation — 0.1.135

Worktree `wt-a135-agents`, branch `dev/a135-agents`, based on `dev/next` b2fb1347.
All builds, generated fixtures and text logs use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-agents`.
No installed app, real chats, preferences, Keychain or credentials are used.
No app source or app tests are part of this helper workstream.

## Contract checkpoint

The first commit provides v4 schemas/strict validation, names/addressing, fixed
prompts, the indented envelope renderer, typed delivery events, inherited-row
markers, additive origin/turn/summary fields, and the v4 receipt serializer.
The existing coordinator still advertises v3 until the runtime work is complete.
The design appendix **Wire contract for the app (v4)** is the UI integration
contract, including exact call/result, delivery, inheritance and pending-mail
examples. Three conservative choices are flagged there as **needs owner decision**:
list cursor, read-only detail modes, and locally derived spawn descriptions.

Commands (from the worktree, with the build root exported):

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter SubagentCodexContractTests
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" --filter 'SubagentCodexContractTests|SubagentSteeringContractTests'
xcodegen generate --quiet
```

`logs/contract-red.log` records the initial absent-v4-API compilation failure.
The first green attempt caught two fixture typing errors (`JSON` construction
and array indexing); these were fixed. `contract-green-2.log` was invalidated
because an additional test was saved while SwiftPM was building. Neither is
counted as a behavioral failure or passing validation. Runtime failing-first
and guard mutation evidence follows with the runtime implementation.

`logs/contract-green-3.log`: **10 tests passed, zero failures** (6 new v4
contract tests and 4 existing v3 contract tests). XcodeGen produced no project
change. Contract guards will receive mutation checks with the final selection.
