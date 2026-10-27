# 0.1.135 release-gate fixes

Worktree `wt-a135-gatefix`, branch `dev/a135-gatefix`, base `1eb7be60`.
All builds, test products, logs and gallery artifacts use
`/Users/admin/Library/Caches/BelloSwiftWork/build-a135-gatefix` (`PI_BUILD_ROOT`).
Generated fixtures, memory vaults and the isolated packaged test host only;
no installed app, real credentials/chats or paid-provider requests.
Only focused classes and the requested whole gallery run; no full lanes,
measurements, wire changes, project.yml changes or release-note edits.

## 1. First context preview — product regression

Confirmed the lead's cause by comparing `27d5498b` with its first parent:
the new task in `subagentModels(for:)` starts `listModels(for:)` while
`turnOverrides` is constructing preview parameters, including during automatic
signature and cached-preview validity reads. The load changes `subagentModels`
(and potentially the catalog-derived image input), so the preview rejects its
own request or the debounce rejects its captured signature. This affects a
connection's first context count after launch, without any user input change:
the footer loses the result, while the Inspector reports “changed, refresh”.

The lead's supplied isolated logs confirm the regression predates AGENTS-1:
on both `1eb7be60` and `b2fb1347`, AutomaticContextTests failed 7 of 11 tests,
and PreparedContextLifecycleTests, PendingChatProjectTests,
MetricsFooterControlTests and BudgetOwnerUnloadTests each failed one test
(class sizes 5, 24, 4 and 7). All 51 tests passed on `6dbaa1d4` in
`build-ab134/logs133/A0-*.log`. A further bisect is unnecessary: the source
change and the focused reproductions identify the side effect directly.

The grant builder is now pure. `loadSubagentModels(for:)` explicitly loads a
never-loaded catalog or joins an existing load. Ordinary session opens start
it in the background, including the already-open path, preserving sends without
a catalog wait. Both explicit and automatic previews await it before taking
the request signature. This reuses ModelCatalog's coalescing, credential and
failure rules and the endpoint's existing 8-second idle / 120-second whole
transfer deadlines; there is no new retry loop or timeout task. A failed first
fetch leaves the existing empty-grants/parent-fallback behavior.

During the automatic debounce and first load, only catalog-derived
`subagentModels` and `input` may change. Draft, attachments, skills, model,
connection, configuration revision and context identity still have to match.
The task then records the complete loaded signature. Completed-result and
cached-preview checks continue comparing the full parameters, so obsolete
model enums are never accepted as current. This is the smallest design that
keeps the existing single shared helper snapshot: resolve the dependency before
preparing it rather than create and replace an already-stale snapshot.

The 0.1.132 cold-catalog tests now exercise actual session opens (new and
already-open after invalidation), then verify subsequent turn grants match
the offered model. Ask's existing coalescing fixture starts the explicit load
operation instead of using the formerly side-effecting getter. The helper's
offered-model resolution and unoffered-model parent fallback/notice are
unchanged.

Failing-first evidence on the unchanged product code:

- `logs/preview-red.log`: all 3 new tests failed. The automatic preview invoked
  its count operation zero times and returned no count instead of 456; the
  Inspector threw the reported “changed, refresh” error after the held catalog
  was released; input reads fulfilled an inverted load expectation and changed
  `fetchedAt`. This first run also had an incidental assertion about the footer
  showing a count while still calculating, which was removed from the purity
  test because visibility during calculation is not its subject.
- `logs/pure-params-red.log`: the corrected purity test alone still failed both
  relevant assertions (1 test, 2 failures), before any product change.
- The Inspector regression uses the packaged helper, reads the complete
  `spawn_agent` schema and checks its model enum is `["offered"]`; it also
  checks that the preview shows a count and dispatched no provider request.

The first focused post-fix run (`logs/preview-green.log`) passed 60 of 61 tests:
AutomaticContext 13, PreparedContextLifecycle 6, ConnectionSettingsFlow 7,
ModelSwitch 24 and SubagentModelGrant 4 all passed; BudgetOwnerUnload passed 6
of 7. Its remaining test had five hidden-display assertions, rather than a
preview-invalidated error. This exposed a second consequence of the newly
loaded grants: `configureSubagentModels` emits `context.inputs-changed`, which
HostService coalesces into `session.changed` after 16 ms. That notification can
arrive after opening an unshown saved side. `refresh` kept budget-only owners
and released displays unloaded, but created a transcript for this directly
opened side. The catalog change exposed this existing refresh assumption.

`BudgetOwnerUnloadTests.testCatalogGrantNotificationDoesNotCreateAnUnshownSideDisplay`
reads the packaged helper's events to prove the grants emitted that change,
then delivers the same refresh after opening, independent of notification
timing. Before the refresh fix it failed both the no-display and accounting-read
assertions (`logs/mutation-and-budget-red.log`). Unshown saved sides now use the
existing numeric-only refresh path alongside budget-only owners and released
displays. Existing displayed chats still use the snapshot path.

Mutation: temporarily restored `Task { [weak self] in await
self?.loadSubagentModels(for: chat) }` inside the pure grant getter. The purity
test caught both the load and the resulting `fetchedAt` change. The same log
contains that one failed test (2 assertions) and the one failing-first budget
regression (2 assertions): 2 tests, 4 failures. The mutation was removed before
the final focused runs.

A second mutation removed `|| sideBudgetParent(item) != nil` from the new
refresh guard. The budget notification regression caught both the hidden
transcript and the missing numeric-only read (`logs/budget-mutation.log`:
1 test, 2 failures). That mutation was also restored.

## 2. Delegation preview — helper test premise

The default Codex contract exposes `spawn_agent`, whose model enum carries the
picker selection. The test still searched for the v3 `subagent_start` name.
Only that lookup changes; grant immutability, journal immutability, duplicate
grant rejection and old-snapshot expiry assertions remain unchanged.

`logs/helper-red.log`: 8 tests, 7 passed and 1 failed, with the expected nil enum
versus `["selected"]` assertion. `logs/helper-green.log`: all 8 passed.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-gatefix
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-verify" \
  --filter ContextPreviewTests
```

## 3. Inspector gallery — test premise

Compared the supplied light 11i images in `build-lead/rerun-135/gallery` and
`build-ab134/gallery`. The v4 `/root` team instructions expand the system prompt
from about 1K to 2.3K characters, pushing the tools expansion below the viewport.
Both texts load, but the offscreen tools text view has no window yet. Requiring
both views to be attached was an invalid visibility premise, not an app defect.

The 11i wait now requires both expansions to reach their shown phase and the
system prompt's view to be attached. The existing whole-system-text assertion
and selection stay. After scrolling, 11j explicitly waits for the tools view
and its final Show less row to be visible, and checks the whole tools text.

Visually inspected all four regenerated files in
`$PI_BUILD_ROOT/gallery/screenshots`:

- `11i-inspector-expanded-light.png` and `11i-inspector-expanded-dark.png` show
  the expanded 2.3K-character prompt, its selected opening paragraph and the
  `/root` team text filling the viewport. The tools need not be on that page.
- `11j-inspector-expanded-end-light.png` and
  `11j-inspector-expanded-end-dark.png` show the schema's closing lines,
  **Show less**, the 17.5K-character label, and Settings, Earlier context and
  the read-tool call/result below. Both appearances are legible and laid out.

## Validation commands and results

All commands run from the worktree. Before each build the shared lock is
checked, waiting while its owner contains `perf` or `soak`. Window-dependent
classes run individually with the lock; no full test lane is invoked.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-gatefix
L=/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock
while [ -f "$L/owner" ] && rg -qi 'perf|soak' "$L/owner"; do sleep 60; done

# logs/preview-red.log (3 tests failed; see fixture correction above)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/AutomaticContextTests/testPreviewParameterAndSignatureReadsDoNotLoadCatalog \
  -only-testing:PiAppTests/AutomaticContextTests/testFirstAutomaticPreviewUsesLoadedCatalogWithoutAnotherActivation \
  -only-testing:PiAppTests/PreparedContextLifecycleTests/testFirstInspectorPreviewWaitsForCatalogAndShowsLoadedModelEnum

# logs/pure-params-red.log (1 test, 2 failures)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/AutomaticContextTests/testPreviewParameterAndSignatureReadsDoNotLoadCatalog

# logs/preview-green.log (intermediate: 60 passed, 1 failed)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/AutomaticContextTests \
  -only-testing:PiAppTests/PreparedContextLifecycleTests \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests \
  -only-testing:PiAppTests/SubagentModelGrantTests \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests \
  -only-testing:PiAppTests/ModelSwitchTests

# logs/mutation-and-budget-red.log (2 tests, 4 failures)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/AutomaticContextTests/testPreviewParameterAndSignatureReadsDoNotLoadCatalog \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests/testCatalogGrantNotificationDoesNotCreateAnUnshownSideDisplay

# logs/focused-final.log (90 passed, 0 failed)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/AutomaticContextTests \
  -only-testing:PiAppTests/PreparedContextLifecycleTests \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests \
  -only-testing:PiAppTests/SubagentModelGrantTests \
  -only-testing:PiAppTests/ConnectionSettingsFlowTests \
  -only-testing:PiAppTests/ModelSwitchTests \
  -only-testing:PiAppTests/SidebarAskConnectionTests \
  -only-testing:PiAppTests/SideBudgetIntegrationTests

# logs/budget-mutation.log (1 test, 2 failures)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests/testCatalogGrantNotificationDoesNotCreateAnUnshownSideDisplay

# logs/budget-restored.log (8 passed, 0 failed after restoring the mutation)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/BudgetOwnerUnloadTests
```

Final focused counts from `logs/focused-final.log`:

| Class | Passed | Failed |
| --- | ---: | ---: |
| AutomaticContextTests | 13 | 0 |
| PreparedContextLifecycleTests | 6 | 0 |
| BudgetOwnerUnloadTests | 8 | 0 |
| SubagentModelGrantTests | 4 | 0 |
| ConnectionSettingsFlowTests | 7 | 0 |
| ModelSwitchTests | 24 | 0 |
| SidebarAskConnectionTests | 10 | 0 |
| SideBudgetIntegrationTests | 18 | 0 |
| **Total** | **90** | **0** |

The remaining classes run alone, sequentially under the full-lane lock, followed
by the complete gallery test. Exact invocation (each class's output goes to
`logs/<Class>.log`; gallery output goes to `logs/gallery.log`):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a135-gatefix
L=/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock
until mkdir "$L" 2>/dev/null; do sleep 60; done
lock_owner="a135-gatefix focused UI and gallery $$"
printf '%s\n' "$lock_owner" > "$L/owner"
trap 'if [ "$(cat "$L/owner")" = "$lock_owner" ]; then unlink "$L/owner"; rmdir "$L"; fi' EXIT
gate_status=0
for suite in MetricsFooterControlTests PendingChatProjectTests ModelCatalogEndpointTests WorkspaceRefreshLifecycleTests; do
  xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
    -parallel-testing-enabled NO "-only-testing:PiAppTests/$suite" \
    > "$PI_BUILD_ROOT/logs/$suite.log" 2>&1 || gate_status=1
done
mkdir -p "$PI_BUILD_ROOT/gallery"
PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/gallery" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/gallery" \
  xcodebuild test-without-building -project PiApp.xcodeproj -scheme PiApp \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
    -parallel-testing-enabled NO -only-testing:PiAppTests/UIScreenshotTests/testRenderRedesignGallery \
    > "$PI_BUILD_ROOT/logs/gallery.log" 2>&1 || gate_status=1
exit "$gate_status"
```

| Class | Passed | Failed |
| --- | ---: | ---: |
| MetricsFooterControlTests | 4 | 0 |
| PendingChatProjectTests | 24 | 0 |
| ModelCatalogEndpointTests | 23 | 0 |
| WorkspaceRefreshLifecycleTests | 40 | 0 |
| **Total** | **91** | **0** |

Thus all five affected classes pass **55 tests**, and the four requested
0.1.132 classes pass **58 tests**. The additional Ask, side-budget and refresh
coverage passes **68 tests**: **181 distinct native tests**, zero failures.
The separately repeated BudgetOwnerUnload class passes all 8 after its mutation
is removed. ContextPreviewTests adds **8 helper tests**, zero failures.

`UIScreenshotTests.testRenderRedesignGallery` passed: **1 test, zero failures,
238 PNG captures**, with both screenshot-root environment variables set and
the full-lane lock held for the entire test. The four requested 11i/11j light
and dark captures were inspected as described above. The lock was released.

Final total: **190 distinct passing tests** (181 focused native, 8 helper,
1 whole-gallery test). Both mutations were caught and removed. No assigned
item remains unresolved. The machine-condition classes in the handoff were
not run or changed; the merged release gate remains with the lead.
