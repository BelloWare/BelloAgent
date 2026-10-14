# 0.1.126: native parallel-lane flakes, rounds 1 and 2

Workstream: `dev/a126-flakes`, based on `2f12977aeb330232a9dec7c6686310d1fc62e41b`. No merge to `dev/next`, lane changes, release packaging, or publication.

## Round 1 findings and changes

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

## Round 1 isolation limitation and historical harness

The owner subsequently confirmed that the old test host shared `com.belloware.PiApp` and wrote real preferences. The previous claim here that those preferences were isolated was incorrect: manually setting a scratch home did not isolate the defaults domain. Round 1 results below are historical; do not rerun that host or its old harness. Round 2 first merged the separate test host, as described below.

Fixtures and gateways were generated and loopback-only. No installed app, paid provider, or `xctrace --launch` was launched. Original gate logs in `build-lead/verify-logs` were read only. The obsolete manual `CFFIXED_USER_HOME` / `TEST_RUNNER_CFFIXED_USER_HOME` workaround has been removed from the current procedure.

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

The additional empty-first-pass/sidebar-population and blame-bar regressions also each passed 10/10. The scheduler monitor recorded exactly ten stops and ten resumes. No stress worker or test-app process remained. At the end of Round 1, only `targeted.xcresult` remained under this build root; Round 2 removed it after preserving its exported summary/test tree.

The historical `final-cpu128-fixed` invocation selected the six complete classes, not only the originally failing methods. It used the obsolete `run-loaded.sh`, the compiled CPU worker, eight XCTest workers, ten iterations, slow Git and scheduler pauses. The current safe commands are recorded under Round 2 below; the old home-variable workaround must not be reused.

`git diff --check`, Python fixture syntax parsing and the lane listing pass. No class moved to serial. Codex (gpt-6.1-sol, xhigh) reviewed the plan and successive diffs read-only, caught the initial preparing-phase ordinal mistake (also caught by the tests), and completed the whole-change double-check plus the blame-wait follow-up with no remaining code findings. Its advice to distinguish repeated executions from deduplicated methods and to keep the broader gate limitation explicit is reflected here.

The broad exploratory run `baseline-full-parallel` (eight clones plus 12 workers) had 2,233 passing, 16 failing and 35 skipped tests. Besides the requested cold-sidebar target, it exposed failures in FileBlameTests, FileTabTests, ComposerSubmissionTests, PseudoTerminalReapTests, CaptureMacIntegrationTests and WebhookTests. Round 2 addresses those classes below. Neither round claims a complete release gate (serial, packaging and other release checks are separate).

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


## Round 2: merged isolated host and the additional stress failures

Before any Round 2 test, `git fetch origin && git merge --no-ff origin/dev/next` produced merge `eefce14fcc7664d7d07e362e23ef1fdc19b2ceab` (parents `03d94103` and `3114c74c`). There were no conflicts. The old host was never tested again. Every native invocation rebuilt through the merged `scripts/test-macos.sh`; no stale `test-without-building` products were used. A leftover Round 1 `.xctestrun` naming the shipping host was rejected by `check-test-host.py` during a read-only check and deleted; it was never executed.

The separate `com.belloware.PiAppTests.Host` host, scheme-owned scratch home, private pasteboards, pre-test guard and disabled Keychain/Sparkle apply to these runs. Both manually exported home variables and the old opt-in Git delay were unset. `TestHostIsolationTests` ran alone in the serial lane: **3/3 passed**, and its runtime log confirmed the test defaults identity and scratch data home. All other classes below remain parallel. Generated fixtures and loopback services only; no writes to `build-lead`.

### Causes and changes

| Class | Evidence and cause | Round 2 change |
| --- | --- | --- |
| `FileTabTests` | **Two app bugs.** FileWatch cancelled/restarted its trailing timer for every parent/grandparent event, so continuous sibling saves starved deletion. The new regression failed in the full eight-clone lane at “deletion is shown while sibling saves continue.” Once notifications were bounded, a held replacement exposed another race: `followChange` restarted the same in-flight file read on each observation (**3 reads instead of 1** under eight clones). | Coalesce notifications from their first event; keep one file identity check/indexing pass alive and queue a recheck. Retry a read whose contents actually changed. Tests cover deletion/recreation amid continuous sibling writes, one held read despite repeated notifications, and a second real save yielding exactly two reads and the newest bytes. Existing selection, scroll, symlink and trust checks remain. |
| `ComposerSubmissionTests` | **Helper bug plus fixture timing.** `runTask` survives while final request links flush even after state becomes idle/paused/error. Steering admitted in that window was acknowledged and could clear the draft. This can explain the exploratory stale-draft failure; controlled regressions reproduce this acceptance defect, but the historical native log does not prove that exact overlap. Three held-finalization regressions failed before the guard. The keyboard fixture also relied on a two-second model reply and short/non-throwing poll loops. | Direct and queued steering require an actual running state as well as task ownership. A normal message still queues and runs after successful finalization, or remains held after Stop/error. The loopback keyboard request stays active until real `turn.stop`; admission, paused queue and snapshot drainage have throwing condition waits. |
| `FileBlameTests` | The ten exploratory failures exhausted 10-second predicates while real file/Git reads or Changes activation were incomplete. GitStateWatch already bounds notifications and filters sibling activity; no analogous Git watcher debounce bug was found. Its file tabs also benefit from the product fixes above. | Explicit 60-second readiness predicates retain all commit/author/path/line/selection checks. The two negative reveal tests now join their owned navigation instead of sleeping four seconds and possibly asserting before slow Git finished. |
| `PseudoTerminalReapTests` | The exploratory fallback test stopped after ten seconds with eight reap calls, before its ninth/final call and exit delivery. A further fixed 100 ms did not establish completion. | Wait for the actual drained exit with a 60-second bound; an overfulfill expectation enforces once-only reporting. Exact exit code, retry count and stopped state remain asserted, and failure teardown ends the owned child. |
| `CaptureMacIntegrationTests` | The exploratory strict portable/pinned integration exhausted its 500-poll window while the real helper still reported running. Chat settlement and eventual capture/link persistence are separate completion boundaries. | Throwing 60-second predicates wait for terminal helper state and for both completed captures plus all message links. Idle state, record counts, plaintext durability, exact request/response bytes and headers remain asserted. |
| `WebhookTests` | The old 172-second failure only recorded native state “running”; it did not record helper state, queue or gateway completion. The source already had a 60-second wait. **No confirmed product root cause has been established for that historical failure.** | Keep the 60-second deadline, make failure throw and capture helper/app/gateway diagnostics. Replace the two-second “no second webhook” sleep with final snapshot and tracked-delivery drainage, retaining the exact request count and payload assertions. Passing merged-tree runs are non-reproduction, not proof of a specific webhook product fix. |

No shared fixture path or exclusive-resource requirement was found. No class was moved to the serial lane.

### Round 2 evidence

Logs, timing metadata, exported test trees and summaries live under `$PI_BUILD_ROOT/flake-logs/`. Only the latest combined `round2-latest.xcresult` is retained. Old results are deleted only after exporting their summaries. The default gate load is **eight XCTest clones with no CPU burners**; the extra twelve `/usr/bin/yes` processes are diagnostic load, never the acceptance bar.

- `r2-baseline-eight`: all twelve complete classes, three iterations, **315 passing executions, zero failures, two pre-existing skips (optional Git benchmark and the test host’s absent Conversation menu)**.
- `r2-baseline-stress`: the same selection, three iterations with eight clones plus twelve CPU burners, **315 passes, zero failures, two skips**.
- `r2-full-eight-before`: the full parallel lane and the new sibling regression, **2,257 passes, one expected failing-first test, 35 skips**. Failure: continuous sibling writes kept deletion invisible.
- `r2-follow-read-before` / `r2-follow-read-red`: the held real replacement demonstrated repeated reads; the precise assertion in the second run was **3 vs 1**. Other selected classes passed. Both runs used eight clones without burners.
- `r2-core-before`: three held-finalization regressions failed against the old steering admission (18 assertions). With the guard restored, **20 helper tests passed ten repetitions (200 executions)** while native load was active; the related queue/retry/resume/compaction selection passed **192/192**.
- `r2-core-steering-mutation`: removing only the state check made all three terminal-state regressions fail again (17 assertions). The correct source was restored and the 20 helper tests passed again.

`r2-full-stress-after`: full parallel lane, eight clones plus twelve diagnostic CPU workers, **2,260 passed, zero failures, 35 skipped**. All three file-follow regressions and the webhook integration passed.

The following independent semantic mutations were also detected under eight clones; all source files were restored byte-for-byte before final validation:

| Mutation | Regression that rejected it |
| --- | --- |
| Restore endlessly restarted FileWatch timer | Sibling-activity deletion still failed with the generous **60-second** deadline. |
| Remove FileTab read coalescing | Both held replacement tests rejected duplicate reads. |
| Abandon a replacement whose reader reports `.changed` | The second-save test could not finish the held replacement. |
| Ignore the source-blame validity predicate | Both owned-navigation negative tests rejected the incorrectly selected commits. |
| Report a terminal exit one greater than the child's code | The retry/fallback tests rejected 4 instead of 3; the exit-127 distinction also failed. |
| Append bytes only to the loopback gateway's recorded response | Portable/pinned capture checks rejected all four exact-body mismatches. |
| Ignore only the per-chat webhook-off switch | The integration rejected **two requests instead of one**, after actual snapshot/delivery drainage. |

Native mutation logs: `r2-native-semantic-mutations`, `r2-follow-coalescing-mutation`, `r2-changed-webhook-mutations`. An initial broader webhook eligibility mutation was also detected but caused many synthetic background notifications; the final narrow mutation above preserved utility-chat eligibility and isolated the off switch.

**Final `r2-final-ten-eight`: PASS.** Eight clones, no CPU burners or artificial Git delay, ten iterations of all twelve classes on the merged isolated host: **1,080 passed executions, zero failures, two pre-existing skips**, completed 2026-10-14 05:54:51 UTC. Every one of the 108 passing methods has exactly ten passing repetition nodes in the exported test tree, including every original target and all three new file-follow regressions.

| Class | Passing methods | Passed executions |
| --- | ---: | ---: |
| `FileBlameTests` | 10 | 100 |
| `FileTabTests` | 16 | 160 |
| `ComposerSubmissionTests` | 6 | 60 |
| `PseudoTerminalReapTests` | 5 | 50 |
| `CaptureMacIntegrationTests` | 2 | 20 |
| `WebhookTests` | 11 | 110 |
| `AppControlAccessibilityTests` | 6 | 60 |
| `GitCommitBrowsingTests` | 3 | 30 |
| `MCPInvocationRetentionTests` | 4 | 40 |
| `SidebarSearchSidebarTests` | 9 | 90 |
| `StableToolPresentationTests` | 10 | 100 |
| `WorkspaceRefreshLifecycleTests` | 26 | 260 |

The skips are `GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested` (optional benchmark) and `ComposerSubmissionTests.testTheMenuBarGivesCommandReturnToSendOrSteer` (the test host has no Conversation menu). Neither skip was added by these changes. Each of the six originally reported methods passed **10/10** on this merged tree, independently verified by full method identifier rather than inferred from class totals.

**Final `r2-full-eight-final`: PASS.** The complete native parallel lane, eight clones and no CPU burners, passed **2,260 tests with zero failures and 35 skips**, completed 2026-10-14 06:01:08 UTC. The log identifies exactly eight native worker processes. This is the gate's native parallel load; the serial lane (apart from the isolated host check), packaging and other complete-release checks were not rerun here. The heavier eight-plus-twelve diagnostic run also passed, but is not the acceptance bar.

`git diff --check`, Python fixture syntax parsing and lane listing pass. The read-only Codex (gpt-6.1-sol, xhigh) plan/diff reviews and final whole-change double-check report no findings; the final review independently verified every repeat count and advised the historical-attribution qualifications recorded above. All mutations were restored before the acceptance runs. No build-root test or helper executable remained after the final lane, and only `round2-latest.xcresult` remains; earlier results survive as exported summaries/test trees and logs.

### Current safe reproduction

The scheme owns test isolation. Do not set a replacement home manually. From this worktree, with `PI_BUILD_ROOT` set to its dedicated build directory:

```bash
unset CFFIXED_USER_HOME TEST_RUNNER_CFFIXED_USER_HOME
unset PI_APP_FLAKE_GIT_READ_SECONDS TEST_RUNNER_PI_APP_FLAKE_GIT_READ_SECONDS
export PI_APP_SCRATCH_ROOT="$PI_BUILD_ROOT/fixtures-r2"
export TEST_RUNNER_PI_APP_SCRATCH_ROOT="$PI_APP_SCRATCH_ROOT"
classes=(FileBlameTests FileTabTests ComposerSubmissionTests PseudoTerminalReapTests
         CaptureMacIntegrationTests WebhookTests AppControlAccessibilityTests
         GitCommitBrowsingTests MCPInvocationRetentionTests SidebarSearchSidebarTests
         StableToolPresentationTests WorkspaceRefreshLifecycleTests)
args=()
for c in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$c"); done
scripts/test-macos.sh "${args[@]}" -parallel-testing-enabled YES \
  -parallel-testing-worker-count 8 -test-iterations 10
```

The local `run-round2.sh` wrapper uses these same options, replaces its explicit result bundle, exports result summaries, and cleans up any optional diagnostic CPU workers. It never uses the obsolete Round 1 manifest or home workaround. Full parallel runs use the selector from `python3 scripts/test-lanes.py parallel`. Serial isolation checks run alone.

The focused helper regressions use generated temporary state:

```bash
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'SessionSettlementTests|QueueEditingTests|QueueHandoffTests'
```

### Round 2 files

- App: `Files/FileWatch.swift`, `Files/FileTab.swift`, `Git/ChangesTab.swift` (read-only navigation task access for owned completion).
- Helper: `packages/swift-host/Sources/PiAgentCore/SessionQueue.swift`.
- Native tests: `FileBlameTests.swift`, `FileTabTests.swift`, `ComposerSubmissionTests.swift`, `PseudoTerminalReapTests.swift`, `CaptureMacIntegrationTests.swift`, `WebhookTests.swift`.
- Helper regressions: `packages/swift-host/Tests/PiAgentCoreTests/SessionSettlementTests.swift`.
- Loopback fixture: `scripts/test-native-host.py`.
- `NEXT-RELEASE.md` and this validation record.
