# 0.1.126: six native parallel-lane flakes

Workstream: `dev/a126-flakes`, based on `2f12977aeb330232a9dec7c6686310d1fc62e41b`. No merge to `dev/next`, lane changes, release packaging, or publication.

## Findings and changes

| Test | Cause and failing-first evidence | Change |
| --- | --- | --- |
| `AppControlAccessibilityTests.testTheCommitScopeIsANamedGroupWithTheChosenScopeSelected` | The initial real Git read used the generic 10-second deadline. CPU/UI stress alone did not reproduce this locally. Delaying the existing Git status-read seam by 12 seconds under load failed at `the first read`. | Explicit 60-second condition deadlines for the completed Git read and accessible scope/selection. Roles, names, children and selected-state assertions remain. An opt-in environment variable repeats the slow-read experiment. |
| `GitCommitBrowsingTests.testALargeCommitListsItsFilesBeforeAnyPatchAndOpensOneFileAtATime` | 400 × 10 ms polling expired under CPU load; the old helper reported failure but returned, so indexing `commits[0]` crashed the test host. The original gate crash and local loaded run both show this path. | Clock-based, throwing 60-second predicates for real history/detail/patch states; release each controller before deleting its generated repository. All lazy-patch/file/count assertions remain. |
| `MCPInvocationRetentionTests.testAFailedSaveReportsLostRetentionAndNeverAcknowledgesSuccess` | 2,000 × 1 ms polling expired before the detached utility-priority failed save delivered its retention boundary. Reproduced with 128 CPU workers; the request/negative-ACK ordering in the app is correct. | Named 60-second predicates for dispatch and retention; cancel requests on teardown. The negative ACK, method, unknown outcome and failure assertions remain. |
| `SidebarSearchSidebarTests.testATypedQueryAnsweredByAColdIndexIsNotHeld` | **App race:** the typed query could answer against the empty index first, consume `answerTyped`, and hold the later indexed answer behind the pointer. Reproduced under CPU load and deterministically with the index worker gated. | Preserve typed ownership through the first reconciliation and always finish it, even when that pass changes nothing. Tests also prove later background matches remain held. |
| `StableToolPresentationTests.testPackagedHelperGatewayAndTwoMountedPanesPreserveCapturesAndTaskTopology` | The fixture exposed preparing/tools only for short sleeps; pausing the native test host for four seconds while its real helper/gateway continued lost both observations. Separately, gateway `records.jsonl` is written after final SSE delivery, so app capture completion does not order that write. | The synthetic gateway and real bash tool wait for per-round markers written by actual app lifecycle publications. Preparation requires the model phase because `preparingCalls` persists during tools. Wait independently for listener readiness, terminal state, final captures and complete gateway records. Every capture/body/topology/history assertion remains; both rounds must be observed. |
| `WorkspaceRefreshLifecycleTests.testRealHelperUpdatesReopenedAndEarlierWindowsWithoutSwitchingTabs` | A fixed settle could finish while the automatic earlier read remained in flight. A duplicate manual load correctly returned false. Gating the real file read reproduced that assertion. The old “new assistant ID” check could also accept an old seed reply newly brought into the window. | Join the owned earlier task, assert it succeeds and expands the real history, wait for viewport readiness, and bind the completed reply and mounted snapshot to the submitted turn. |

The empty-first-pass regression exposed another **app defect**: `SidebarIndex.invalidate()` cleared its “already grouped” project set only when nonempty chat buckets existed. An initially empty sidebar could therefore stay empty after chats arrived, even with correct search hits. The regression failed with hits present, no holds, but an empty sidebar order. Invalidation now also forgets empty grouped projects. This was fixed rather than removing the final visible-snippet assertion.

All fixture roots are unique. No shared-path defect or exclusive-resource requirement was found. All six classes remain in the parallel lane.

## Isolation and harness

All runs used generated state and loopback gateways, the worktree's test bundle and packaged helper. No installed app, real preferences, Keychain, user data, paid provider, or `xctrace --launch` was used. Original gate logs in `build-lead/verify-logs` were read only.

Every `scripts/test-macos.sh` run exported:

```bash
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a126-flakes
export CFFIXED_USER_HOME="$PI_BUILD_ROOT/prefs-home"
export TEST_RUNNER_CFFIXED_USER_HOME="$PI_BUILD_ROOT/prefs-home"
export PI_APP_SCRATCH_ROOT="$PI_BUILD_ROOT/fixtures"
export TEST_RUNNER_PI_APP_SCRATCH_ROOT="$PI_APP_SCRATCH_ROOT"
```

Loaded native runs configured eight XCTest workers (`-parallel-testing-enabled YES -parallel-testing-worker-count 8`). Early experiments used `/usr/bin/yes`; stronger experiments used compiled integer arithmetic loops at `QOS_CLASS_USER_INTERACTIVE`. Workers were terminated after each run. The result-bundle summaries and test trees were exported before replacing bundles; only the latest combined `.xcresult` is retained.

The slow Git read is opt-in, affects only the named generated accessibility fixture, and restores the prior seam in `defer`:

```bash
export PI_APP_FLAKE_GIT_READ_SECONDS=12
export TEST_RUNNER_PI_APP_FLAKE_GIT_READ_SECONDS=12
```

The scheduler experiment watches `round-0-started` in each generated `stable-tool-gateway-*` root. Its monitor identifies that Python gateway's parent by the exact test-bundle executable path under this build root, sends that test host `SIGSTOP`, and sends `SIGCONT` four seconds later. It never pauses another worktree or an installed app, and its termination handler resumes any held host. The index and history gates suspend actual reads, then delegate to their normal implementations.

Local reproducibility artifacts are in `$PI_BUILD_ROOT`: `run-loaded.sh`, `burn.c`, `burn`, `stall-fixtures.py`, and `flake-logs/` (commands, timing metadata, XCTest summaries/test trees, and stop/resume evidence). These cache artifacts are not shipped with the app.

## Validation

Before fixes:

- `baseline-12`: all six classes, 12 workers, three iterations. The cold sidebar target failed twice; the Git cache test in the same class also expired and crashed after reading an empty commits array.
- `baseline-cpu128`: five non-sidebar targets, 128 workers, three requested iterations. The large Git target failed and crashed in its first iteration; MCP failed in iteration three. The other three targets passed.
- `baseline-cpu256`: the remaining accessibility/tool/history targets passed ten iterations under CPU stress alone. `baseline-ui-load` also passed with expensive mounted transcript tests. Their local fail-before evidence therefore uses controlled scheduling/read overlap, not a claim of an uncontrolled reproduction.
- `controlled-before`: 12 workers, slow Git read, four-second test-host stall and gated actual index/history reads. All five selected checks failed: the three remaining original targets and both cold-index regressions.
- The new empty-sidebar assertion then failed with the typed-query fix in place, separately exposing the empty-project cache bug.

After fixes, `fixed-corrected-classes` passed all 58 executable tests in the six classes under 12 CPU workers, with the 12-second Git read and four-second test-app-host pause active. The opt-in real-repository benchmark was skipped.

`semantic-mutations` independently broke six contracts in one isolated build (12 CPU workers). All seven selected methods failed, then every mutated file was restored to its saved SHA-256:

| Mutation | Observed failure |
| --- | --- |
| Rename `Commit scope` to `Mutation scope` | Accessible named group was not found. |
| Clear large-commit patch deferral | “a big patch waits to be asked for” assertion failed. |
| Acknowledge a failed MCP save with `retained: true` | Exact `true` versus `false` ACK assertion failed. |
| Restore early typed-answer consumption and omit the unchanged first-pass requery | Original cold-result assertion and new unchanged-pass completion assertion both failed. |
| Omit the terminal task footer | Exact terminal count was 0 instead of 1 in both mounted panes and restored history. |
| Ignore submitted turns while browsing earlier history | The required completed reply for the submitted turn never appeared. |

`empty-cache-mutation` reverted only the grouped-project invalidation fix. The new empty-pass test failed at its final visible-snippet assertion; the file was restored. The first 128-worker ten-iteration full-class soak (`final-cpu128`) passed **all six requested methods 10/10**, but uncovered an additional flake in the same accessibility class: `testTheBlameBarReadsAsWordsAndOffersTheWholeCommit` failed its `blamed` predicate in repetitions 5 and 7. Its generic 10-second deadline expired before the real Git read completed. The run had 578 passed executions, 2 failed executions and 1 skipped opt-in benchmark (XCTest did not repeat the skipped case). That test now also uses explicit 60-second file/Git and accessible-bar/caret condition deadlines; its spoken author/summary, full-hash help, action buttons, caret and ruler assertions are unchanged. The immediate hide wait is unchanged.

`blame-summary-mutation` changed the real accessibility summary while retaining the `Line 1, commit ` prefix. The exact spoken-content assertion failed with `…: Mutation summary` instead of `…: Greek letters`; the app source was then restored. This verifies the more generous wait still rejects incorrect content.

`blame-restored` passed all six accessibility-class tests under 12 CPU workers with the real spoken summary restored. The final complete six-class repeated run follows this restored build.

**Final `final-cpu128-fixed`: PASS.** All six classes ran ten iterations with 128 CPU workers, eight configured XCTest workers, the 12-second real Git read, and four-second pauses of the test-app host. On arm64 macOS 14.8 / Xcode 16.1, device-level results and repetition nodes both report **580 passed executions, 0 failures, 1 skipped opt-in benchmark**. The top-level summary deduplicates these to 58 passed methods and one skipped method. The run completed 2026-10-14 05:09:43 UTC.

| Class | Passed executions | Requested target |
| --- | ---: | ---: |
| `AppControlAccessibilityTests` | 60 | 10/10 |
| `GitCommitBrowsingTests` | 30 | 10/10 |
| `MCPInvocationRetentionTests` | 40 | 10/10 |
| `SidebarSearchSidebarTests` | 90 | 10/10 |
| `StableToolPresentationTests` | 100 | 10/10 |
| `WorkspaceRefreshLifecycleTests` | 260 | 10/10 |

The additional empty-first-pass/sidebar-population and blame-bar regressions also each passed 10/10. The scheduler monitor recorded exactly ten stops and ten resumes. No stress worker or test-app process remained. Only `targeted.xcresult` remains under this build root; older bundles were removed after exporting their summaries/test trees.

The final harness invocation selected the six complete classes, not only the originally failing methods:

```bash
classes=(AppControlAccessibilityTests GitCommitBrowsingTests MCPInvocationRetentionTests
         SidebarSearchSidebarTests StableToolPresentationTests WorkspaceRefreshLifecycleTests)
args=()
for c in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$c"); done
bash "$PI_BUILD_ROOT/run-loaded.sh" final-cpu128-fixed 128 10 "${args[@]}"
```

The harness calls `scripts/test-macos.sh`, exports both isolated-home variables, configures eight XCTest workers, passes `-test-iterations 10`, and saves the current bundle and exported records. This invocation used `PI_FLAKE_BURNER="$PI_BUILD_ROOT/burn"`, `PI_FLAKE_RESULT=targeted`, the Git-delay variables above, and the described scheduler monitor with `STALL_LOG=final-cpu128-fixed-stalls`.

`git diff --check`, Python fixture syntax parsing and the lane listing pass. No class moved to serial. Codex (gpt-6.1-sol, xhigh) reviewed the plan and successive diffs read-only, caught the initial preparing-phase ordinal mistake (also caught by the tests), and completed the whole-change double-check plus the blame-wait follow-up with no remaining code findings. Its advice to distinguish repeated executions from deduplicated methods and to keep the broader gate limitation explicit is reflected here.

The broad exploratory run `baseline-full-parallel` (eight clones plus 12 workers) had 2,233 passing, 16 failing and 35 skipped tests. Besides the requested cold-sidebar target, it exposed failures in FileBlameTests, FileTabTests, ComposerSubmissionTests, PseudoTerminalReapTests, CaptureMacIntegrationTests and WebhookTests. Those additional stress failures were not changed in this workstream. This record does **not** claim a green full release gate.

## Changed files

- `apps/macos/PiApp/Workspaces/SidebarSearch.swift`: first-pass query ownership and an index-read gate for regression coverage.
- `apps/macos/PiApp/Workspaces/WorkspaceSessionOrganization.swift`: invalidate cached empty project groups.
- `apps/macos/PiAppTests/AppControlAccessibilityTests.swift`: condition deadlines for commit-scope and blame-bar checks, plus an opt-in slow Git fixture.
- `apps/macos/PiAppTests/GitCommitBrowsingTests.swift`: throwing Git predicates and controller cleanup.
- `apps/macos/PiAppTests/MCPInvocationRetentionTests.swift`: retention predicates and request cleanup.
- `apps/macos/PiAppTests/SidebarSearchTests.swift`: forced cold-read ordering, empty-pass/background ownership, and visible empty-to-populated sidebar regression.
- `apps/macos/PiAppTests/StableToolPresentationTests.swift`: observed phase handshakes and independent completion predicates.
- `apps/macos/PiAppTests/TestSeams.swift`: asynchronous predicate overload, preserving existing synchronous callers.
- `apps/macos/PiAppTests/WorkspaceRefreshLifecycleTests.swift`: actual read ownership, viewport readiness and submitted-turn reply checks.
- `fixtures/native/tool_phases.py`: bounded per-round observation handshakes and scheduler experiment marker.
- `NEXT-RELEASE.md` and this record: workstream status and evidence.
