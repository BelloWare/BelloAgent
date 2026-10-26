# Sub-agent model fallback hotfix — 2026-10-27

Branch: `dev/a132-subagent-model`, based on released 0.1.131.
Build and text-log root: `$PI_BUILD_ROOT` =
`/Users/admin/Library/Caches/BelloSwiftWork/build-a132-subagent`.

## Cause and change

The app supplied only descriptors already loaded into the connection's catalog.
Before a picker or another catalog consumer loaded it, this list was empty.
The helper rejected an explicitly named model absent from that list, including
the parent's own model.

An absent grant now resolves to `inherited(parent)` and the unchanged parent
profile, just as an omitted model does. Offered models still use their grants;
`validateSubagentModels` is unchanged. Route, headers, credentials, connection
identity, permissions and tool boundaries keep their existing inheritance.
Fallback effort capabilities follow the same path as an omitted model.

The v3 start receipt and legacy synchronous tool result name the actual `model`.
When a different requested model was unavailable, `model_notice` says:

> Requested model 'not-offered' is not offered for this connection; using the parent's model 'fixture-model' instead.

The v3 receipt is saved with the accepted operation, so a duplicate returns the
same explanation. Send receipts also name the child's model. The existing send
contract has no model override; follow-ups retain the child's accepted model.
Both start schemas describe the fallback while retaining their offered-model
lists. No grant validation or journal version changed.

The app's shared grant builder starts `listModels(for:)` for an empty catalog
that has never loaded. Session opens and turn submissions return the current
grants immediately; later turns use the completed list. Existing in-flight loads
are coalesced by `ModelCatalog`.

## Validation

Only generated fixtures and in-memory vaults were used. No installed app,
real chats, real Keychain, live provider or paid requests were used.

Failing-first helper command:

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --filter 'SubagentPermissionTests|SubagentCoordinatorTests/testUnlistedModelFallsBackWhileInvalidToolsCreateNoChild|AgentSteeringCommandTests/testUnlistedModelStartReportsFallbackAndFollowUpKeepsIt'
```

`logs/helper-red.log`: 11 tests, 7 passed and 4 failed, with 13 assertion/error
failures. Both direct resolver cases throw the original `subagent_model` error;
the legacy and v3 cases fail to create children or return fallback receipts.

Focused app command:

```sh
scripts/test-macos.sh -only-testing:PiAppTests/SubagentModelGrantTests
```

`logs/app-red.log`: 4 tests, 2 passed and 2 failed. Both new tests time out
because grant preparation never loads the catalog. That first run also reported
two fixture teardown errors from deleting a root already owned by the shared
workspace fixture; the redundant deletion was removed before the final run.

Final helper command:

```sh
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --filter 'Subagent|AgentSteering|ContextPreviewTests'
```

`logs/helper-green.log`: **157 passed, 0 failed**, including all classes matching
`Subagent` or `AgentSteering` and all 8 `ContextPreviewTests`. The changed helper
classes passed 9 permission tests, 23 coordinator tests and 6 steering-command
tests. An initial helper check was interrupted when the shared lock changed to a
performance-sensitive run; its partial output is retained in
`logs/helper-interrupted.log` and is not counted as a completed pass.

`logs/app-green.log`: **4 passed, 0 failed** in `SubagentModelGrantTests`.
Both cold-catalog paths return immediately with empty grants, initiate the
catalog load without a picker, and supply the real offered model on later turns.

`ContextPreviewTests`' duplicate-grant refusal remains intact: it validates the
app's list, not a child's requested model. The final helper filter includes it.

Per the owner's hotfix override: no full native lanes, gallery, mutation runs or
measurements. `NEXT-RELEASE.md`, `project.yml` and release notes are unchanged.
