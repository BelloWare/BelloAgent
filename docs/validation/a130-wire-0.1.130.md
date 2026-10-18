# 0.1.130 app/helper wire contracts

Branch: `dev/a130-wire`; base `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. All generated data, in-memory credentials, loopback gateways and the isolated test host. Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`; text logs in `logs/`. No installed-app launch, live data, preferences, Keychain, paid calls, release or merge. The lead owns integration into `dev/next`.

## Fixes and decisions

- **WIRE-CONTRACT-1:** `CaptureDelivery` serializes each capture packet, sends small packets unchanged, and transfers larger packets in acknowledged 32 KiB base64 pages. `HostTransport` validates identity, contiguous offsets, page size and final JSON before publishing the complete packet to the archive. Intermediate acknowledgements retain an in-memory prefix; the final acknowledgement still waits for archive acceptance. Rejection or shutdown discards the unfinished transfer. No truncation, plaintext spool, new capture quota or change to credential masking. No `TraceStore` changes; all capture packet kinds use the same delivery boundary.
- **WIRE-CONTRACT-2:** Inspector MCP admission pins workspace activity before helper startup, through display-result assembly, durable result saving and retention acknowledgement, including cancellation of the sheet. A count preserves concurrent invocations. Caller timeouts keep the pin while either the invocation or its retention acknowledgement is still physically outstanding; `HostSupervisor` releases settlement waiters on the reply or host loss. Timeout errors and existing unknown-outcome handling are unchanged. The helper independently checks admitted Inspector execution and the MCP manager's running/setup/awaiting-retention state before acknowledging quiescence.
- **CONCURRENCY-LIFECYCLE-2:** the same pin participates in host busy state and both idle-timer eligibility checks. Finishing a concurrent chat cannot stop a helper carrying an Inspector call. On completion/error the pin is released and ordinary idle scheduling resumes. Existing explicit Quit/Pause confirmation and unknown-outcome recovery remain unchanged.
- **WIRE-CONTRACT-3:** snapshot ordering uses the existing `monitoring.epoch` (the helper's `displayEpoch`), not the session ID alone. A replacement resets sequence, projection, receipt/task/context revisions and queue-edit revision gates; it retires in-flight presentation reads. The first lower-sequence snapshot applies immediately. Retired runtime identities cannot be adopted again, and asynchronous decode is fenced. Navigation changes still win. No helper runtime/recovery rewrite or reader unload/reopen is needed.

**Initial review decision, resolved in round 2:** MCP-specific update wording was deferred for owner approval. The lead approved it in the follow-up request; the current confirmation accurately names Inspector-only calls and other background work while preserving the confirmation flow.

The initial fixes made no view/layout/style changes or production feature-switch changes. Native mounted-reader integration checks cover the changed presentation behavior. `SubagentDisplayGalleryTests` regenerated 40 images under the shared lock; the light/dark `child-report` scenes at 1240×800 and 640×600 were visually inspected. No new layout issue was found; narrow labels use the existing ellipsis/wrapping.

## Fail first and mutation evidence

The original Release helper and original app production sources were tested after adding regressions:

| Finding | Before fix | Mutation |
| --- | --- | --- |
| WIRE-CONTRACT-1 | `baseline-capture-exit.log`: generated successful Responses JSON with 1,100,000 ASCII bytes in `usage.vendor_details`, while another chat runs; helper exits **70**. An initial probe hit the existing display-reply limit, so the final reproduction uses lightweight status reads to isolate capture delivery. | `mutation-helper-capture-quiescence.log`: bypassing chunking fails the helper frame/offset/final-retention regression (4 failures, including its finite wait for the missing next page). |
| WIRE-CONTRACT-2 | `baseline-wire.log`: `workspace.quiesce` incorrectly returns success with `tools/call` held at the fixture barrier. `baseline-native.log`: app update barrier incorrectly acquired. | `mutation-native-pins-sequence.log`: disabling the MCP pin fails the app regression (4 assertions). Removing the helper MCP guard fails both held-execution and unretained-result assertions (2 failures in `mutation-helper-capture-quiescence.log`). |
| CONCURRENCY-LIFECYCLE-2 | `baseline-native.log`: zero-grace deterministic timer stops the helper while the Inspector request is outstanding. | Same pin mutation reproduces the idle-stop failure. The real-helper test separately waits 11 seconds with idle grace 10 seconds and MCP timeout 60 seconds. |
| WIRE-CONTRACT-3 | `baseline-native.log`: sequence stays 500 instead of accepting 1/3, then retired sequence 501 replaces the reader (5 assertions). | Removing the reset fails 5 assertions; independently removing the retired-epoch fence fails 2 assertions (`mutation-native-retired.log`). |

All mutations are temporary and restored before final validation. The helper mutation command was:

```sh
swift test --package-path packages/swift-host --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire/swift-verify --filter 'CaptureDrainTests.*testLargeMetadata|HostServiceTests.*testQuiescence'
```

It ran two tests, both failed (six assertions/errors total), then the original production sources were restored.

Self-review also narrowed activity recomputation to `mcp.invoke`, preserving the prior behavior of ordinary resource discovery. The fake-host discovery guard failed two assertions against the broader first implementation (`review-discovery-before.log`), passed after narrowing (`review-discovery-fixed.log`), and failed the same two assertions when the unconditional recomputation was restored (`mutation-native-discovery.log`). Actual side admission already has a loading pin; this is a behavior-preservation guard, not an additional confirmed side bug. The mutation was restored before the final native rerun.

The activity sweep also covered the native IPC deadline: the caller can time out before a helper command ends. `baseline-native-timeout.log` has two failing tests and six assertions demonstrating premature update/idle eligibility after invocation or retention-ACK timeout. The fixed tests inject a one-second deadline, keep replies held, and cover both late physical reply and helper exit; normal MCP requests retain their existing 315-second deadline. `fixed-native-timeout.log` passes both. Removing the physical-settlement pin fails both tests with six assertions in `mutation-native-timeout.log`; the final rerun follows restoration.

## Final validation

| Suite | Final result | Evidence |
| --- | --- | --- |
| Native focused transport/activity/refresh | **76 passed, 0 failed**: `HardeningTests` 12, `HostFrameTests` 4, `HostSupervisorTests` 10, `HostTransportTests` 8, `MCPInvocationRetentionTests` 9, `WorkspaceRefreshLifecycleTests` 33 | `native-final.log` |
| Native capture (serial) | **7 passed, 0 failed** | `native-capture.log` |
| Native child reader (serial) | **14 passed, 0 failed** | `native-child.log` |
| Native child-reader gallery (serial, enabled) | **1 passed, 0 failed**, 40 PNGs | `native-gallery.log`, `gallery/` |
| Native existing activity/update/capture coverage | **105 passed, 0 failed**: `RunHoldTests` 18, `WorkspaceFailureTests` 6, `SideTests` 15, `WorkspaceTests` 17, `SessionOrganizationTests` 9, `TopicOrganizationTests` 14, `DeferredCreationTests` 4, `TraceArchiveTests` 7, `WorkspaceConcurrencyTests` 8, `UpdatePauseTests` 7 | `native-activity-coverage.log` |
| Native lifecycle helper (serial, alone) | **11 passed, 0 failed** | `native-lifecycle-coverage.log` |
| Native window lifecycle (serial, alone) | **3 passed, 0 failed** | `native-window-coverage.log` |
| Full helper, excluding the separately run timing-sensitive class | **1,025 passed, 7 skipped, 0 failed** (1,032 total) | `helper-final.log` |
| Helper `StreamingCostTests` | **5 passed, 0 failed** | `helper-streaming-final.log` |
| Release wire | **38 passed, 0 failed** | `wire-final.log` |
| Release concurrent wire | **4 passed, 0 failed** | `concurrent-final.log` |
| Release acceptance | **3 passed, 0 failed** | `acceptance-final.log` |

Native total: **217 passed**, no skips or failures. Full helper total: **1,030 passed, 7 skipped, 0 failed** (1,037 total). The seven helper skips are existing opt-in fixture/performance cases (`ForkCloneTests` 1, `ForkPerformanceTests` 1, `HistoryReadCancellationTests` 1, `SessionOpenPerformanceTests` 4); no unrelated test failure was observed. Final native and helper runs follow restoration of every mutation affecting them. There are no clone folders left under this workstream's native build root.

Exact commands (all run from this worktree; `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`):

```sh
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/MCPInvocationRetentionTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/HostFrameTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/HostTransportTests -only-testing:PiAppTests/HostSupervisorTests -only-testing:PiAppTests/HardeningTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -only-testing:PiAppTests/MCPInvocationRetentionTests -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests -only-testing:PiAppTests/HostFrameTests -only-testing:PiAppTests/HostTransportTests -only-testing:PiAppTests/HostSupervisorTests -only-testing:PiAppTests/HardeningTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/CaptureDrainTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests
TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY="$B/gallery" PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentDisplayGalleryTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/RunHoldTests -only-testing:PiAppTests/WorkspaceFailureTests -only-testing:PiAppTests/SideTests -only-testing:PiAppTests/WorkspaceTests -only-testing:PiAppTests/SessionOrganizationTests -only-testing:PiAppTests/TopicOrganizationTests -only-testing:PiAppTests/DeferredCreationTests -only-testing:PiAppTests/TraceArchiveTests -only-testing:PiAppTests/WorkspaceConcurrencyTests -only-testing:PiAppTests/UpdatePauseTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/LifecycleHelperTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WindowLifecycleTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

Focused regression/mutation runs use the same native command with `/testInspectorWorkPinsUpdateAndIdleUntilRetentionAcknowledgement` and `/testReplacementRuntimeAcceptsLowerSequenceAndRejectsRetiredSnapshots` selectors. Wire reproduction uses `NativeIntegration.test_large_capture_metadata_preserves_both_concurrent_chats` and `NativeIntegration.test_quiescence_waits_for_inspector_execution_and_retention` selectors. Serial native classes run separately; runs that can change focus acquire `/Users/admin/Library/Caches/BelloSwiftWork/full-lane.lock` and release only their own lock in `finally`. No named result bundles; text logs are the evidence. The lead runs the full merged native gate.

The additional native guard runs use `-only-testing:PiAppTests/MCPInvocationRetentionTests/testDiscoveryPreservesTheHostsExistingActivityPin`, or the pair `-only-testing:PiAppTests/MCPInvocationRetentionTests/testTimedOutInvocationPinsActivityUntilItsPhysicalReplyOrHostExit -only-testing:PiAppTests/MCPInvocationRetentionTests/testTimedOutRetentionAcknowledgementPinsActivityUntilItsPhysicalReply`, with the same `PI_BUILD_ROOT` and script.

## Initial contract sweep: helper-to-app frames

Inspected every emission in `NativeHostService`, `CaptureDelivery` and `PiHost/Main.swift`, plus app `HostTransport`, `HostFrameDecoder`, `HostInbox`, `HostSupervisor`, `DisplayResultReader` and shared Python `HostPeer`.

| Packet kind | Bound and result |
| --- | --- |
| `ready`, `incompatible` | Fixed schema/capability strings, UUID host epoch; bounded. |
| Accepted command `reply`, cached mutation replies | `boundedReply` measures encoded bytes. Large successful values use existing display transfers when negotiated; failures/unsupported transfers return the bounded error. Display reads remain paged. |
| Rejected command `reply` | **Additional confirmed bug below:** pre-admission rejection bypasses `boundedReply` and can echo an arbitrarily long invalid command ID. |
| `event/session.changed`, `event/session.unloaded` | Fixed envelope, validated session identity, numeric sequence and empty payload. Coalescing is only notification ordering; the app fetches a fresh snapshot. |
| `event/session.cost` | Not passed through `boundedReply`, but reachable producers are managed-child snapshots (fixed six usage fields and counts) or fixed numeric durable mirrors. `notePausedMember` excludes managed children, so the unbounded owner `pausedMembers` list is not a normal cost-event payload. The initial suspected cost-event overflow was narrowed by tracing the producers; no additional legal-input overflow confirmed. |
| `capture/begin`, `capture/metadata`, `capture/finish` | Previously unbounded provider/configuration metadata, including raw usage, headers and provenance. Now every encoded packet uses the acknowledged size boundary. |
| `capture/bytes` | Existing 32 KiB raw-byte pages, about 44 KiB base64; new generic boundary also covers them. |
| `capture/events` | Previously count-paged (128), not byte-bounded; a large SSE event name can exceed a frame. The same generic capture fix covers it without trimming names. |
| `capture/links` | Previously count-paged (512); imported/provider identifiers can be large. Same generic fix covers it. |

The Python wire client now checks the 1 MiB physical-frame limit for **every received kind**, reassembles capture chunks, and calls its existing capture consumer only for complete packets. Native/Swift tests include JSON escaping and Unicode, malformed final JSON, gaps, mixed identities, rejection and final-ack ordering.

## Initial contract sweep: activity and quiescence

Inspected the host command dispatch stages, session run/close/idle predicates, coordinator lifecycle, MCP execution/retention, capture outbox, and the app's update, idle, host startup, Resources, title, webhook, connection-test, context and history callers.

| Work | Existing visibility / conclusion |
| --- | --- |
| Main/side model loops, tools, compaction, retry, queued/steering delivery | Session run task/queue and native loading/run state. Ephemeral sides pin the host; paused durable work can quiesce without resuming. |
| Send/open admission and resource/skill preflight | Normal native callers use loading/open-call guards; helper preflight itself is not a session run. A raw wire quiesce racing non-MCP preflight has no independent admission counter. This broader protocol-only gap was inspected but is not changed by the scoped MCP fix. |
| Managed children, queued starts, family waiting/settlement and budget mirrors | Helper-owned sessions/coordinator plus parent family state. Child metadata/display eviction does not grant update authority. |
| Titles and mini-model background requests | Existing title task table and background session displays/run tasks. |
| Direct Inspector MCP, including a timed-out caller with a still-outstanding wire command | **Fixed:** previously invisible to session idleness and native activity; now counted through retained result acknowledgement on both sides. A caller deadline cannot release a physical invocation or retention-ACK pin. Failed retention preserves the existing unknown-outcome marker and does not keep completed execution alive forever. |
| Capture delivery and archive writes | Not a run pin. Existing graceful shutdown/drain and capture-finalization barrier retain their bounded 3.25-second grace and interrupted-prefix semantics. No change to that owner-approved policy. |
| Resources/skill/MCP discovery, context preview/counting, history/content/debug/display-transfer reads | Not run activity; these can be cancelled/retried. History filling is cancelled by helper quiescence. No external tool execution authority is added. |
| Configuration, recovery/import/rebind, journal slimming and budget repair | Existing workspace-change/runtime/journal gates, not a blanket activity pin. Parallel helper work owns preview/import/recover scheduling; this branch does not edit those functions. |
| Onboarding `connection.test` | Additional audit gap: its private helper is outside `WorkspaceModel.hosts` and its local request is not part of `hasActiveWork`; see follow-up below. |

## Initial contract sweep: session ID versus runtime identity

- `WorkspaceHosts.open`, `opened`, `sessionOpenings`, `helperSessionDidUnload` and host-loss resets: explicit unload/reconnect paths already fence connections. `openAgentChild` is the intentional same-ID replacement without unload; fixed at snapshot adoption so the reader stays attached.
- `WorkspaceRefresh`, `SessionDisplay`: sequence/projection/task/receipt/monitoring/context/queue-edit gates now reset for a replacement epoch; old snapshots cannot settle intents, adopt side state, replace paths or update subagent lists.
- History paging, versions, Find, reveals, source navigation and `ConversationPresentation`: helper cursors carry incarnation+lineage; publication also uses navigation/presentation generations. Replacement retires reads without moving focus or erasing retained rows.
- `WorkspaceCostLimits`/`SessionBudgetState`: read tokens and host connections fence explicit unloads; child costs use durable accounting revisions, not resettable runtime sequences. `SubagentCostCursor` orders turn, revision and progress epoch. Durable costs must not be reset when a child runtime changes.
- Subagent discovery/list registration and `subagentSummaries`: durable origin/turn/revision and live host authority; follow-up identity remains the same child with a later turn.
- Prepared context and footer observations: `ContextInputIdentity`/runtime epoch and revision envelopes qualify counts; cached revisions are invalidated at snapshot adoption. Managed readers cannot send or independently change permissions.
- Completion sound and webhook trackers: already compare monitoring epochs and use a baseline on epoch changes; managed children do not produce independent notifications.
- Capture/Inspector caches: physical attempt ID + host epoch/workspace scope, not the session runtime sequence. MCP retention uses host epoch + unique command ID. Drafts, saved metadata, message accounting and journal ancestry intentionally remain durable session identities.

## Initial additional findings (all addressed in round 2 below)

1. `packages/swift-host/Sources/PiAgentCore/HostService.swift:124` and `:185`: a generated command with a 1,100,000-byte invalid `commandId` fits the inbound command-frame allowance, but its rejection echoes that ID without bounding the reply. The Release helper exits 70. Reproduced in `sweep-overlong-command-id.log`; this is distinct from capture delivery and needs a separate fix.
2. `apps/macos/PiApp/Workspaces/WorkspaceConnectionProbe.swift:31`–`:65`: onboarding creates a private helper and sends `connection.test` without registering it in `hosts` or the workspace activity predicate. An update/idle sweep cannot account for that pending request. Static contract finding only; no live/provider probe performed. Needs owner decision: whether update should await/cancel onboarding connection tests explicitly. Kept outside this branch's assigned Inspector MCP fix.

3. `apps/macos/PiApp/Workspaces/WorkspaceHistory.swift:37` and `packages/swift-host/Sources/PiAgentCore/SessionReads.swift:22`: a reader browsing retained history can still hold an old helper-incarnation cursor after same-ID runtime replacement; paging sends it unchanged and the helper rejects it as stale. The live-tail regression is fixed, but automatic rebinding of a held history cursor is a separate pre-existing navigation case. Static contract finding; no cursor migration added here.
4. `packages/swift-host/Sources/PiAgentCore/HostService.swift:774` and `:410`: non-MCP submission preflight awaits skill/resource preparation after its quiescence check but before the session becomes busy. A raw wire `workspace.quiesce` can cross that interval without an independent admission counter. Native send/open callers already have activity guards. Static protocol finding; the scoped Inspector counter does not change general submission admission.

## Initial adversarial self-review

Reviewed the final diff for chunk rejection/close races, prefix-vs-durable acknowledgement, malformed/changing chunk IDs, Unicode/JSON escaping, retained capture/credential boundaries, pin admission before awaits, concurrent pins, cancelled-sheet result retention, failed saves, caller timeout versus physical command completion, settlement-waiter release on host loss, execution-vs-retention quiescence, navigation winning over awaited snapshots, retired-epoch rollback, same-epoch ordering, and durable cost/notification identities. No TraceStore masking, tool authorization, vault, journal or production rollout change. The assigned fixes have no remaining identified defect in the exercised paths. At that point the separately listed rejection-frame, onboarding-activity, retained-history-cursor and general-preflight gaps remained outside scope. Round 2 below resolves all four. The initial native changes were in activity/transport/snapshot code, with no visual-control changes.


## Round 2: review recovery and authorized follow-ups

Starting commit: `355c900637df12c12cd30155df0bdc3f08944801`. The lead explicitly requested all four recorded follow-ups and approved accurate Inspector-only update wording. The read-only review's loading-state finding is confirmed. No product decision remains pending for these changes.

- Rejections omit an inadmissibly long command identity (empty echo, never a truncated valid identity) and use the same encoded-byte bound as accepted replies. Valid rejected identities still correlate normally.
- Epoch retirement clears the old initial loading state before changing its generation, clears edge-loading flags, and reconciles only still-visible readers. Old tasks cannot publish or clear newer loading flags. Reload recovery retains its explicit destination; ordinary initial loading retains the scroll anchor and draft initialization.
- Native history requests explicitly opt into stable-entry rebinding. The helper validates lineage before and after older-index loading and verifies the boundary message still exists. Strict callers still reject stale incarnations. The native page joins only after lineage, overlap and residency validation; opposite boundaries adopt the replacement incarnation without changing the reader's anchor.
- A host admission count covers changing-session commands across preflight and admission, including submit/steer/edit, Resume's budget check, retry, queue resume and compaction. Inspector execution retains its separate execution/retention count and `mcp_busy` error. Quiescence refuses before crossing an outstanding admission.
- Onboarding probes pin app activity before their first await, register their scoped helpers for the existing confirmed pause/Quit shutdown, and release activity after cleanup/accounting. Barrier/shutdown checks prevent late preflight from starting a new provider request. Raw `connection.test` also pins helper admission through completion. This preserves explicit Pause and Install semantics; Check for Updates remains passive.
- The confirmation distinguishes one/multiple Inspector calls and other background work from running chats. Existing buttons, cancellation and pause/install ordering are unchanged. Existing chat wording is retained.

### Failing-first evidence

All logs below are under `build-a130-wire/logs/round2/` (absolute build root above).

- `helper-baseline.log`: three new regressions failed, eight assertions total. Rejection frames measured **1,100,266** and **1,200,266** bytes; all three held submission methods allowed quiescence; the old cursor threw `history_changed`.
- `native-baseline.log`: four tests failed, sixteen assertions total. Initial and reload reads remained `.loading`; paging refused the replacement incarnation; tool-only confirmation said “Pause the running chat”; the held onboarding probe allowed the update barrier.
- `probe-helper-baseline.log`: the existing real-loopback connection-probe regression, extended with a response barrier, failed because raw helper quiescence acknowledged while the probe was running.
- `helper-focused.log`: after fixes, **22 tests passed**, zero failures/skips, across ReplyEncodingTests, HostServiceTests, HistoryWindowTests and ConnectionProbeTests.

### Round 2 nearby sweep

Rechecked all pre-admission `reply` sites (malformed envelope, invalid ID, stale epoch, mutation tombstones/conflicts and capacity refusal), accepted/cached replies and transfer fallback. Ready/incompatible and session event frames remain fixed-schema/validated-identity output; all capture kinds retain the generic chunk boundary from round 1. No TraceStore edit.

Rechecked changing-session dispatch and each preflight await, scoped connection probes, Inspector execution/retention, helper startup, resource discovery, paused queues, run continuation, compaction, side/fork/session opening and runtime gates. External execution now has a session, Inspector retention, or admission owner. Read-only discovery/history/context work keeps its existing cancellation behavior; session/fork/side opening creates idle runtimes and does not submit provider work. Parallel preview/import/recover scheduling remains untouched.

Rechecked presentation cancellation and generation sites in selection, sides, hosted/inherited readers, reload, pending-project cleanup and shutdown; only epoch retirement changed generation without clearing initial loading. Rechecked both history paging directions, file/helper handoff, position/reveal validation, lineage changes, missing boundary IDs, retired snapshots, delayed page publication and same-epoch ordering. Persistent drafts/accounting stay keyed by durable session identity.

### Round 2 final validation and adversarial review

Mutation evidence:

- `native-mutation.log`: remove initial-load cleanup, restore the old handoff gate, ignore onboarding activity, and force the chat-only prompt. **All 4 tests failed, 17 assertions**. All native mutations were restored.
- `native-recovery-navigation-baseline.log`: the added recovery-token assertion failed because the provisional reload restart advanced navigation. Recovery now passes the current token; explicit user reloads still advance it. `native-recovery-navigation-mutation.log` ignores that supplied token: **1 test failed, 1 assertion**. Restored before final validation; `native-recovery-navigation-fixed.log` passes the regression (1 test, zero failures).

- `helper-mutation.log`: disable the quiescence admission check, disallow cursor rebinding, and echo the full invalid command identity. **All 4 tests failed, 11 assertions**, with the original errors/overflows restored. Restored all sources in a `finally` block.
- `wire-mutation.log`: build the mutated Release helper and run the new invalid-ID wire case. **1 test failed** with `No rejection frame; helper exit=70`. This independently verifies the writer/process failure, not just JSON size. Restored the source and rebuilt the fixed Release helper for native/final wire runs.
- `native-reload-target-baseline.log`: after the loading reset alone, **57 of 58 tests passed**; the recovery regression failed twice because reload resumed at `held`/offset 17 instead of `destination`/offset 0. Preserving the reload target fixed those assertions. The fake transport regression now releases its first snapshot explicitly so automatic recovery's follow-up snapshot does not delay the test on an unanswered fake request.
- `native-fixed.log`: **25 passed**, zero failures/skips (22 OnboardingTests, 2 focused history regressions, 1 tool-only confirmation regression).

Commands (all run from this worktree; `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`, `H=$B/swift-host/arm64-apple-macosx/release/pi-native-host`):

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'ReplyEncodingTests|HostServiceTests|HistoryWindowTests|ConnectionProbeTests'
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$H"
python3 scripts/test-concurrent-native-host.py "$H"
python3 scripts/test-native-acceptance.py "$H"
```

Native focused/galleries use `PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO` with the class filters listed in the final table. Serial-lane classes each run alone. Every final native run and the Release wire lane acquire/release the shared full-lane lock, with owner matching in an EXIT trap; no foreign lock is removed. Gallery variables are `TEST_RUNNER_PI_APP_UPDATE_PAUSE_GALLERY="$B/gallery-round2/update"` and `TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY="$B/gallery-round2/readers"`.

Full helper result: `helper-final.log` **1,028 passed + 7 skipped**, zero failures, 435.604 seconds; `helper-streaming-final.log` **5 passed**, zero failures/skips, 3.599 seconds. Combined **1,033 passed + 7 existing opt-in skips** (1,040 executed). Skips remain the fixture writer, large-fork performance, rapid-supersession measurement and four session-open performance probes.

Release suites: `test-native-host.log` **39 passed**, `test-concurrent-native-host.log` **4 passed**, `test-native-acceptance.log` **3 passed**. Zero failures/skips. The wire suite includes both 1.1 MB ASCII and JSON-expanded invalid identities, then a successful `runtime.info` on the same helper.

The core native command is:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests \
  -only-testing:PiAppTests/OnboardingTests \
  -only-testing:PiAppTests/UpdatePauseTests \
  -only-testing:PiAppTests/HistoryEdgeTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/LongJournalHistoryTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/WorkspaceConcurrencyTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/WorkspaceFailureTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/MCPInvocationRetentionTests \
  -only-testing:PiAppTests/HostFrameTests \
  -only-testing:PiAppTests/HostTransportTests \
  -only-testing:PiAppTests/HostSupervisorTests \
  -only-testing:PiAppTests/HardeningTests
```

Separate invocations of `PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/<Class>` run `HistoryEdgeTimingTests`, `HistoryEditTests`, `SubagentOpeningTests`, `SubagentNavigationTests`, `LifecycleHelperTests`, and `WindowLifecycleTests`. The gallery classes use the same command, each alone, with the runner environment assignments above.

Final native totals: **261 passed**, zero failures/skips, across 24 classes. Native final log breakdown:

| Log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `native-final.log` | 219 | 0 | 0 |
| `native-HistoryEdgeTimingTests.log` | 2 | 0 | 0 |
| `native-HistoryEditTests.log` | 3 | 0 | 0 |
| `native-SubagentOpeningTests.log` | 14 | 0 | 0 |
| `native-SubagentNavigationTests.log` | 7 | 0 | 0 |
| `native-LifecycleHelperTests.log` | 11 | 0 | 0 |
| `native-WindowLifecycleTests.log` | 3 | 0 | 0 |
| `native-update-gallery.log` | 1 | 0 | 0 |
| `native-reader-gallery.log` | 1 | 0 | 0 |

The 219-test core comprises Hardening 12, HistoryEdge 16, HistoryExtent 25, HostFrame 4, HostSupervisor 10, HostTransport 8, LaunchSelection 20, LongJournalHistory 1, MCPInvocationRetention 9, Onboarding 22, RunHold 18, UpdatePause 8, WorkspaceConcurrency 8, WorkspaceFailure 6, WorkspaceRefreshLifecycle 35, and Workspace 17.

Galleries regenerated **16 update-question PNGs** and **40 reader PNGs**. Inspected the single-tool question in light/dark at both 640/920 host widths, plural tools and background work in dark/narrow, and `child-report` in light/dark at 1240×800 and 640×600. Text and actions fit; no new clipping or layout regression. Artifacts remain under `$B/gallery-round2/{update,readers}`. All gallery/focus runs held the shared lock. The lock was released after the final run; no foreign lock was removed. No clone folders remain in this build root.

Final adversarial self-review covered invalid-ID collision/correlation and JSON escaping; every reply/capture writer path; counter entry before awaits and release on failures/stop; helper-owned execution versus retained MCP results; onboarding preflight, barrier races, caller cancellation and physical helper shutdown; epoch changes during initial/reload/edge reads; stable entry and lineage validation; delayed old-task publication; explicit reload destinations; recovery preserving navigation tokens; and confirmation cancel/accept ordering. The extra destination/token assertions caught and corrected two recovery details before the final pass. Permission, capture, vault, tool and durable-data boundaries are unchanged. Preview/import/recover and TraceStore remain untouched. All mutations are restored, no unrelated test failed, and no identified issue remains unresolved in this follow-up scope.
