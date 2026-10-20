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

## Round 3 — navigation ownership and mounted reader preservation

The review of `3a3e7ea5` identified two regressions in runtime rollover. Both are confirmed. The generated native fixture reproduced a superseded Latest/targeted reload replacing a newer, already-loaded Inspector destination, and an attached child reader's native selection shrinking from `{6, 11}` to `{6, 0}` when only its runtime epoch changed.

`ConversationPresentation.Reload` now retains the destination together with the navigation token that requested it. Recovery validates that token before restarting; a superseded target is discarded. Ordinary hydration can still recover a visible reader at its newer held anchor. Hosted navigation retirement drops the obsolete reload, and successful/failed completion releases the saved intent. Deferred main-reader hydration carries its token from task creation through publication and cleanup; side recovery validates the captured token before starting.

Runtime rollover advances a separate `readGeneration`. Initial/history/source/edge/position read publication and cleanup use that fence. The mounted `presentationGeneration` remains stable across a background runtime replacement, so the native document retains its selected text, anchor and disclosures. Deliberate selection/reload still creates a new presentation. Runtime retirement still clears abandoned initial loading state and restarts visible reads under their retained intent.

### Failing-first evidence

All round-3 artifacts use `B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`, with text logs under `$B/logs/round3`. Focus-sensitive runs acquire the shared full-lane lock and release only their own lock on exit.

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests/testSupersededReloadCannotInheritANewerReveal \
  -only-testing:PiAppTests/SubagentReaderTests/testRuntimeReplacementPreservesMountedChildSelection
```

Before production changes, `native-before.log` reports **2 tests failed, 6 assertions**: Latest and an explicit old target overwrite the newer ordinary-reader destination (four assertions), while rollover changes the child presentation identity and clears its native selection (two assertions). The reload regression also exercises hosted readers. The native selection regression holds an actual `MarkdownTextView` selection in the attached child's pane, an open reasoning fold and a saved scroll anchor. An initial test-only compile error used the SwiftUI wrapper's name instead of the native pane type; it was corrected before collecting behavioral evidence (`native-test-compile.log`).

`testRuntimeReplacementRejectsAnUntrackedRevealRead` additionally holds an uncancelled reveal outside the presentation task handles, retires its runtime, then releases the obsolete page. This guards against merely keeping the native identity stable while allowing retired history to publish. The existing replacement regression still covers initial/reload recovery, lower replacement sequence numbers, retired snapshots and retained cursor rebinding.

### Nearby contract sweep

- Reviewed every `presentationGeneration`/`presentation.generation` use in Workspaces, Tabs and the native transcript. History progress, main/side/original-child loads, reloads, history edges and their cleanup, Source/Find/Home reveals, and position reacquisition now use the independent read fence. Viewport-ready callbacks, native binding, reading scopes, row retention and per-page accounting retain the mounted identity. Snapshot application retains its runtime-epoch fence after asynchronous decoding.
- Reviewed every reload destination assignment and recovery call. No recovery reconstructs a retired reload's token from current navigation. Superseded explicit destinations are dropped; still-owned runtime recovery keeps its original token. Held-reader hydration preserves the newer anchor and pending draft initialization rather than replaying the discarded destination.
- Checked hosted hide/close/Back and pane/window movement, main/side recovery, Find and version ownership, position retry/coalescing, and loaded-row reveal fast paths. Existing reader/query/load-ID guards remain in place. Helpers, wire packets, durable history, capture, permission and vault boundaries are unchanged in this round.

### Round-3 wire verification

The helper is unchanged from round 2. The Release helper rebuilt by the native baseline command has SHA-256 `689bf4d91ab569eca26e8dee045591b56fa407a08111d75dcac05180bf1782ee`. These generated-fixture, non-focus helper suites passed while the native lane was occupied and were rerun after the final native checks. The table reports the final run:

```sh
H="$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-host.py "$H"
python3 scripts/test-concurrent-native-host.py "$H"
python3 scripts/test-native-acceptance.py "$H"
```

| Suite / log | Passed | Failed | Skipped | Time |
| --- | ---: | ---: | ---: | ---: |
| Wire / `test-native-host.log` | 39 | 0 | 0 | 35.630 s |
| Concurrent / `test-concurrent-native-host.log` | 4 | 0 | 0 | 29.307 s |
| Acceptance / `test-native-acceptance.log` | 3 | 0 | 0 | 3.498 s |

No helper source or wire format changed in round 3; the full helper suite result remains the round-2 **1033 passed / 7 existing opt-in skips** recorded above.

### Mutation checks

With both fixes applied, the two focused regressions pass (**2/2**, `native-fixed.log`). A combined mutation reassigns a saved reload's token from current navigation and again rotates the mounted presentation on epoch change. The same command then fails **2 tests / 6 assertions** (`native-mutation.log`), reproducing the original destination and native-selection failures.

A separate mutation removes only the runtime read-generation advance:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testRuntimeReplacementRejectsAnUntrackedRevealRead
```

It fails **1 test / 2 assertions** (`native-read-mutation.log`): the uncancelled obsolete reveal returns success and replaces the held row. Both mutation runs compile successfully and fail on behavioral assertions. All mutations were restored before subsequent verification.

### Nearby same-function history rebinding correction

The sweep found an incomplete part of round 2's cursor handoff: `TranscriptReveal.swift` still rejected a helper-to-helper incarnation change in Home/reveal and position reads, even after `session.history` validated the held entry and lineage. A reader browsing an older page could therefore preserve its selection through rollover but fail its next explicit destination with a false “changed outside this window” error. This is a two-condition correction in the same read functions touched by the generation fix; no helper or protocol change is needed.

`testReplacementRuntimeRebindsHeldRevealAndPositionBoundaries` exercises all three paths through the fake wire transport, asserts that the original entry and lineage are sent for validation, and returns the replacement runtime's page. Before the correction it fails **1 test / 9 assertions** (`native-rebind-before.log`): all three paths retain the old page/incarnation and report a source change. The correction matches history paging's existing handoff rule. Different lineages and replacement file incarnations remain rejected.

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testReplacementRuntimeRebindsHeldRevealAndPositionBoundaries
```

The fixed check, uncancelled-read fence and initial/reload recovery together pass **3/3** (`native-rebind-fixed.log`):

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testReplacementRuntimeRebindsHeldRevealAndPositionBoundaries \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testRuntimeReplacementRejectsAnUntrackedRevealRead \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests/testRuntimeReplacementRestartsVisibleInitialAndReloadReads
```

Restoring the old two source checks reproduces **1 failed test / 9 assertions** (`native-rebind-mutation.log`). That mutation was restored before the final run. Existing file-replacement, missing-entry and lineage rejection regressions are included in the affected native classes below.

### Final affected native checks and review

The main focused invocation was:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests \
  -only-testing:PiAppTests/WorkspaceLoadingTests \
  -only-testing:PiAppTests/FreshPresentationTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/HistoryEdgeTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/LongJournalHistoryTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/MessageVersionTranscriptTests \
  -only-testing:PiAppTests/ForkCloneReaderTests \
  -only-testing:PiAppTests/WorkspaceConcurrencyTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/WorkspaceFailureTests \
  -only-testing:PiAppTests/TranscriptQuoteSelectionTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/TranscriptKeptRowsTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests
```

Serial classes each ran alone:

```sh
for C in HistoryEdgeTimingTests HistoryEditTests SubagentReaderTests \
  InheritedSubagentReaderTests SubagentOpeningTests SubagentNavigationTests; do
  PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
    -only-testing:PiAppTests/"$C"
done
TEST_RUNNER_PI_APP_SUB_DISPLAY_GALLERY="$B/gallery-round3/readers" \
  PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentDisplayGalleryTests
```

The first aggregate reports **216 passed / 1 failed test** (`native-final.log`, two assertions). `HistoryExtentTests.testANewGenerationCanRecoverWhileThePreviousRecoveryIsPending` directly assigned `presentationGeneration` to simulate retirement of reads. That fixture encoded the old shared identity. It now invokes `adoptSnapshotEpoch` and also asserts that the mounted identity stays unchanged. Production code did not change for this test correction. The entire class was rerun:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryExtentTests
```

That rerun passes **25/25** (`native-HistoryExtentTests.log`). All other native tests passed their first aggregate run. Final consolidated coverage is **308 distinct tests passed, zero unresolved failures or skips, across 24 classes**. The initial fixture failure remains recorded rather than being hidden by the rerun.

| Class | Final passed |
| --- | ---: |
| ForkCloneReaderTests | 1 |
| FreshPresentationTests | 21 |
| HistoryEdgeTests | 16 |
| HistoryEdgeTimingTests | 2 |
| HistoryEditTests | 3 |
| HistoryExtentTests | 25 |
| InheritedSubagentReaderTests | 7 |
| LaunchSelectionTests | 20 |
| LongJournalHistoryTests | 1 |
| MessageVersionTranscriptTests | 8 |
| SubagentDisplayGalleryTests | 1 |
| SubagentNavigationTests | 7 |
| SubagentOpeningTests | 14 |
| SubagentReaderTests | 57 |
| TranscriptDisclosureTests | 15 |
| TranscriptKeptRowsTests | 10 |
| TranscriptQuoteSelectionTests | 8 |
| TranscriptRevealTests | 10 |
| TranscriptSwitchFirstFrameTests | 1 |
| WorkspaceConcurrencyTests | 8 |
| WorkspaceFailureTests | 6 |
| WorkspaceLoadingTests | 13 |
| WorkspaceRefreshLifecycleTests | 37 |
| WorkspaceTests | 17 |

The gallery regenerated **40 PNGs**. Inspected `child-report` in light/dark at 1240×800 and 640×600 under `$B/gallery-round3/readers`; no new clipping or overlap. All native/focus runs held the shared lock, and every owned lock was released. No clone folders remain in this build root; no additional DerivedData root was created.

The final adversarial review checked task creation versus execution, original workspace/hosted navigation tokens, stale completion and cleanup ownership, initial-load recovery, unchanged ready/preparing presentations, native selection/disclosure retention, reload-intent lifetime on completion and close, epoch-fenced snapshot decoding, and validated helper handoff versus changed lineages/files. It found and corrected the nearby Home/reveal/position handoff described above. The held uncancelled reveal and extent-recovery tests independently verify that preserving mounted identity does not admit retired reads. `git diff --check` passes. All mutations are restored. No issue remains unresolved in this scope, and no owner product decision is needed.


## Round 3 hunt

Starting point: `fe734912` on `dev/a130-wire`, already fast-forwarded by the lead after the earlier work was merged. This round uses only `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`; text evidence is in `logs/round3-hunt` there. All inputs are generated or repository fixtures, all services loopback, vaults memory-backed, and native runs that open/focus windows or capture images hold the shared focus lock. Model-only runs use the focused-test exception. No installed app, user preferences, chats, credentials or Keychain are used.

### WIRE-CONTRACT-1 — complete retained conversation copy

Confirmed. `ContractTests/testConversationPagingRetainsReasoningArgumentsAndMessageBoundaries` failed on four assertions before the fix: missing reasoning, tool arguments, assistant heading and tool heading (`helper-before.log`). Conversation paging now has its own formatter matching saved-history copy, while message-text reads retain their previous contract. The formatter handles ordinary blocks, image omission, compaction/edit boundaries and timeline evidence, including full canonical content when timeline retention is partial.

The final adversarial formatter comparison also caught absent arguments being collapsed into explicit JSON null. Disk copy represents an absent field as `{}`, so this mismatch would prevent an otherwise unchanged handoff. The added helper assertion failed once (`helper-arguments-before.log`), and the extended native parity/handoff test failed three assertions/errors (`native-arguments-before.log`, including the rejected handoff). The formatter now distinguishes an absent field from a present null. The helper check passes; reverting this distinction reproduces the failure (`helper-arguments-mutation.log`, 1 test / 1 assertion). The native fixture exercises both present and absent arguments through live copy, the held-selection handoff and a fresh disk selection. Full helper, Release wire and affected native copy checks were repeated after this correction.

### WIRE-CONTRACT-2 — copy selection after idle retirement

Confirmed. `ConversationCopyTests/testIdleHandoffContinuesUnicodePagesAndRejectsChangedContent` failed before the app change with “History changed. Refresh the range before copying” on the first disk continuation (`native-copy-before.log`, 1 test / 1 failure).

Each sheet now owns an opaque selection token, its original source/revision, project/chat/path and helper/runtime identities. The helper supplies a digest of the ordered message IDs and complete copy text; its live revision includes the sequence, and live pages also validate the runtime incarnation. On retirement, the app verifies the journal's chat identity and complete conversation digest, then continues with the filesystem revision and the original UTF-16 cursor. The disk reader caches one verified handoff for an unchanged file stamp. Its hashing runs on the history actor; helper hashing releases each 128-row block. Idle shutdown remains eligible while the sheet is open.

The generated assistant exceeds 70 KiB of UTF-8 text and spans multiple pages, with distinct prose/reasoning/argument markers and emoji. Positive checks cover live/disk byte parity, idle retirement between pages, and both compaction and historical-edit golden journals. Negative checks reject changed content, a different journal identity, and a replacement runtime deliberately reusing the same session ID, row counts and sequence. The original message-text API and rendered transcript Find path are unchanged.

### CONCURRENCY-LIFECYCLE-5 — folder admission during Inspector work

Confirmed. The new `MCPInvocationRetentionTests/testFolderChangesRefuseClosedInspectorExecutionAndPendingRetention` failed before the fix (1 test / 2 assertions, `native-folders-before.log`): folder admission entered the session-unloading preflight (`session.releaseDependents`) while Inspector execution remained outstanding.

The folder admission predicate omitted `resourceInvocations`, although update and idle admission already observed this pin. The existing resource pin spans execution, durable saving, retention acknowledgement and physical settlement after caller timeout/cancellation. Add/remove/relocate/re-trust/remove-project all share this admission predicate. The opposite race is already fenced by `host(for:)` and `startHost(for:)` refusing `workspaceChangesInFlight`.

### HELPER-AGENTS-IO-2 / PERSISTENCE-COMPAT-3 — native handoff replay

Confirmed with generated v1/v2/v3 variants of `fixtures/native/historical-edit-after.jsonl`, testing markers both first and after a harmless custom record. Before the fix the test failed 12 assertions for v2/v3: exported context differed from v1 and omitted the restored original prefix (`helper-before.log`). Both portable-preview native checks now use `JournalRecordKind.isMarker`; the existing `ConversationReplay` supplies restored context and excludes the invalidated summary. The helper's preview remains off the host actor.

The initial test setup was corrected to open a fixture workspace before previewing. A later copy-digest assertion exposed an incomplete synthetic tool exchange: replay correctly inserted an unknown-outcome receipt. The fixture now includes the tool receipt and final response, representing the completed-turn scenario; production interruption handling is unchanged.


### Mutation evidence and nearby checks

| Finding | Mutation | Observed failure |
| --- | --- | --- |
| WIRE-CONTRACT-1 | Return `retainedDisplayText` from conversation paging again | 1 helper test / 5 assertions: the four missing pieces plus the digest/content mismatch |
| WIRE-CONTRACT-2 | Validate the disk handoff but pass the original helper revision to disk paging | 1 native test / 1 failure, the original history-changed error |
| CONCURRENCY-LIFECYCLE-5 | Remove the resource pin from folder admission | 1 native test / 2 assertions, unloading preflight admitted before completion |
| HELPER-AGENTS-IO-2 | Restore both v1-only native checks | 1 helper test / 12 assertions, restored v2/v3 context missing |
| Additional runtime fence | Omit the incarnation from the app's live page request | 1 native test / 1 assertion: new runtime content reached the old selection despite equal sequence/counts |
| Formatter parity edge | Collapse absent arguments into JSON null | 1 helper test / 1 assertion; absent fields must copy as `{}` while explicit null stays `null` |

All mutations compiled, failed behaviorally, and were restored. Evidence: `helper-mutation.log` (2 tests / 17 assertions), `native-copy-mutation.log`, `native-folders-mutation.log`, and `native-epoch-mutation.log`. The runtime test passes with the fence (`native-epoch-fixed.log`). The three model copy tests pass with the handoff (`native-copy-fixed.log`).

Sweep:

- Copy format: ordinary text/string/array bodies, reasoning, tool arguments, image placeholders, compaction summaries, edit boundaries, complete/partial/supported timeline evidence, and user display text versus retained source. Golden before/after historical-edit journals copy identically through both sources. `session.message.read` and `session.tool.input` retain their existing contracts.
- Framing: conversation text pages remain bounded at 16,384 UTF-16 units. The new search fields are one SHA-256 digest and one runtime UUID; the existing bounded-reply/transfer path remains intact. The Release wire suite includes oversized captures and rejection echoes.
- Source ownership: native Copy Range, Copy Conversation and Export share the selection source; the SwiftUI test reference also passes the captured selection. A new search cannot lend a retired selection a new source. Same-ID runtime replacement is fenced independently of sequence. Disk handoff validates chat identity, ordered message identities, formatted content and the file stamp. Changed content/identity remain rejected. No transcript presentation identity or navigation token is modified by these reads.
- Folder changes: add, remove, relocate, re-trust/reconfigure and project removal share `requireIdle` / `workspaceHasActiveWork`. The reverse admission is already guarded in `host(for:)` and `startHost(for:)`. Update and idle checks already use the same resource pin. The regression cancels the sheet's caller, rejects both addition and removal during execution and retention, verifies the result file before ACK, then successfully retries both after ACK.
- Native markers: both portable paths now use the same supported-marker predicate as journal readers. Recovery's v1/v3-only check is intentional: managed children are explicitly refused via `subagentOrigin`. No recovery, import, preview scheduling or TraceStore masking code was changed.

**Needs owner decision — separate source-search coverage:** `packages/swift-host/Sources/PiAgentCore/SessionReads.swift:128` still searches `retainedDisplayText`. A reasoning-only or tool-argument-only query therefore misses the live row, while the disk source formatter contains those blocks. This round preserves query matching and fixes the assigned copy/paging behavior. A generated Release-helper probe confirms both queries return 0 hits while their copy page contains the marker (`source-search-probe.py` / `.log`); it makes **0 provider POSTs**. Whether to expand live source-search matches is a separate visible search change.

### Commands and completed checks

All commands run from this worktree, with:

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire
```

Helper red/green/mutation selection:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'ContractTests/testConversationPagingRetainsReasoningArgumentsAndMessageBoundaries|ReplayParityTests/testPortableHandoffRestoresEditedContextForEveryNativeMarker'
```

`helper-before.log`: 2 failed tests / 16 assertions. `helper-fixed.log`: 2 passed. The later class run (`--filter 'ContractTests|ReplayParityTests'`, including matching SubagentContractTests) passes 21 tests.

Full helper checks on the final helper sources:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
```

`helper-final.log`: **1,127 passed, 7 skipped**, 1,134 executed in 399.146 s. `helper-cost-final.log`: **5 passed** in 3.422 s. Total **1,132 passed / 7 existing opt-in skips / 0 failures**. Skips remain the fixture writer and opt-in fork/history/open performance measurements.

Release helper / wire checks:

```sh
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

`bundle-final.log`: pass. `wire-final.log`: **40 passed**, 35.395 s. `concurrent-final.log`: **4 passed**, 21.289 s. `acceptance-final.log`: **3 passed**, 3.476 s.

Focused model regression and mutation:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationCopyTests/testIdleHandoffContinuesUnicodePagesAndRejectsChangedContent
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/MCPInvocationRetentionTests/testFolderChangesRefuseClosedInspectorExecutionAndPendingRetention
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationCopyTests/testAReplacementRuntimeCannotReuseTheSelectionsSequence
```

The model-only invocations open no windows or focus probes and use the focused-test exception. Mounted/window/gallery checks use `native-lane.sh`, which takes the shared `full-lane.lock`, writes its own owner token and removes it only when the token still matches, including failure. No other workstream's lock was removed. The lock owner's label changed through its continuing performance/UI checks; no orphan-lock cleanup was performed.

Final headless native classes:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/HardeningTests -only-testing:PiAppTests/MCPInvocationRetentionTests
```

`native-headless-final.log`: **40 passed / 0 failures** in 25.530 s (ContentSearch 7, Hardening 12, MCPInvocationRetention 10, StorageTruth 11).

Related history and admission classes:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryIndexFilesTests -only-testing:PiAppTests/HistoryReaderCheckpointTests -only-testing:PiAppTests/MCPRemovalTests -only-testing:PiAppTests/SideBudgetIntegrationTests
```

`native-related-final.log`: **42 passed / 1 opt-in performance skip / 0 failures**, 43 executed in 10.696 s (HistoryIndexFiles 3 passed + 1 skip, HistoryReaderCheckpoint 7, MCPRemoval 14, SideBudgetIntegration 18). `scripts/test-lanes.py list` confirms both grouped model runs contain only parallel-lane classes.

Final window and serial classes, each invocation under the shared lock:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceTests -only-testing:PiAppTests/WorkspaceManagerSheetTests -only-testing:PiAppTests/ToolOutputProducerTests -only-testing:PiAppTests/WorkspaceDurabilityTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests
PI_BUILD_ROOT="$B" TEST_RUNNER_PI_APP_CONVERSATION_COPY_GALLERY="$B/gallery-round3-hunt/copy" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationCopyTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/PayloadNativeControlTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/PayloadNativeParityTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationResultsGeometryTests
```

| Text log | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: |
| `native-ui-final.log` | 44 | 0 | 0 |
| `native-transcript-final.log` | 116 | 0 | 0 |
| `native-copy-final.log` | 6 | 0 | 0 |
| `native-payload-controls-final.log` | 22 | 0 | 0 |
| `native-payload-parity-final.log` | 7 | 0 | 0 |
| `native-results-geometry-final.log` | 1 | 0 | 0 |
| All final native runs, including model classes above | **278** | **1** | **0** |

The 44-test group comprises Workspace 17, WorkspaceManagerSheet 10, ToolOutputProducer 8 and WorkspaceDurability 9. Every detected serial class runs alone. The existing mounted sheet successfully copies its held assistant range and exports the full conversation after idle retirement, including retirement while export waits before the chooser.

Gallery: regenerated and visually inspected `gallery-round3-hunt/copy/{light,dark,narrow}.png` (1080 × 700 light/dark, 900 × 700 narrow). All show the three retained rows, correct range and enabled copy/export actions, with no clipped controls. The first capture caught a stale window-server frame despite completed search state; the new gallery fixture now uses the established consecutive-frame stability check and clears field editing before capture. Its full six-test class was rerun successfully, including the final absent-arguments regression (6.583 s); initial images and the first passing functional run remain as `copy-first-pass` / `native-copy-first-pass.log`. No product code changed for the capture-timing correction.

Iteration evidence is retained, not counted as red behavior proof: the initial native fixture needed an explicit Data split type (`native-compile.log`); Swift actor checking required moving hash updates outside the autorelease-pool closure (`native-selection-compile.log`). One Release build detected a source edit during compilation (`bundle-source-edit.log`); it was rebuilt with sources held fixed before the passing wire runs. The first headless class pass hit a new fixture's incomplete successful-unload handshake (`native-headless-fixture-retry.log`, 1 failing test / 2 failures); the fixture now acknowledges `session.releaseDependents` followed by `session.close`, and all 40 pass. No unrelated test failure has been observed in the completed final checks.

**Separate fixture cleanup follow-up:** the unchanged wide-search fixtures remove their temporary directory while their `HistoryReader` can still own its SQLite index (`apps/macos/PiAppTests/TranscriptBugRegressionTests.swift:625`, `:664`, and similar defers). `native-transcript-final.log` contains eight SQLite “vnode unlinked while in use” diagnostics for generated `wide-search-*` indexes. All 116 tests pass. This cleanup issue is outside the assigned product fixes and is recorded rather than changed.


### Adversarial self-review of the implementation

Reviewed the complete diff against `fe734912`, including the generated project entry. The fixes preserve the separate message-text contract, UI navigation/presentation identity, result-retention sequencing, workspace scoping, cancellation and export output-use pins. The handoff requires matching project/chat/path and journal header identity; its digest covers ordered IDs and exact formatted copy bytes, so matching row counts, prefixes or file sizes alone cannot authorize a handoff. Runtime incarnation is independent of sequence, with a deliberate equal-sequence replacement regression and a failing mutation. Failed/current helper reads are not retried as write commands; recovery reads validated saved history only.

Reviewed complete versus partial/unsupported response timelines, compaction replay prefixes, branch markers, Unicode offsets, selection replacement, disk cache invalidation, helper retirement while awaiting IPC, and source disappearance while preparing export. The bounded helper reply path and the 16,384-unit text page limit are retained. The helper emits the optional digest/incarnation only for retained-selection searches, preserving existing wire callers. The original matching semantics of source search are the explicit follow-up above; rendered Find is unchanged.

The Release helper tested by all three Python suites has SHA-256 `bfe18747c58c1db62cfb938dbc2c115779f33fbf5baaba669122aac98a65602f`, rechecked after the final native run. New generated fixture cases use registered teardown. No cloned test-host directories were present in this workstream's `native-tests/Build/Products`; the remaining automatically named result bundle was removed. Text logs and gallery images remain in this workstream's build root. All owned shared locks were released. `git diff --check` passes.

## Round 4 review

Review of `31969162cf5e85ef6cbd7e65f45ec4859a4255eb`, plus the lead's decision to align live source search with Copy Conversation. Work remains on `dev/a130-wire`; no merge or fast-forward. Logs for this round are under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire/logs/round4-review` (`B` below is that build root).

### Findings and failing-first evidence

1. **Empty/uncovered timeline loses canonical content — confirmed.** `ConversationReadTests.testEmptyAndUncoveredTimelinesKeepCanonicalAnswer` feeds the reported Responses event sequence through both `ProviderAccumulator` and `ProviderDisplayEvents`: the collected answer exists while the supported timeline is empty. It also covers nonempty evidence that belongs to another part. `helper-red.log`: both assertions fail because `COLLECTED-ANSWER` is absent.

   `RetainedConversation.swift` is now compiled into both targets, using the project's existing shared-source convention. The JSON adapters supply values; one implementation formats message boundaries, reasoning, tool arguments, image placeholders, timeline evidence, edits and compactions. Timeline coverage is checked against canonical parts, including adjacent/interleaved contributions, corrections and normalized tool JSON. Unproven coverage adds the complete saved response; existing complete evidence keeps its order. Unsupported timelines use canonical content. Separate message-text reads remain unchanged.

   Mutation: short-circuiting the coverage proof to accept any supported, untruncated timeline fails the same test with **2 failures** (`mutation-timeline.log`). Restored code passes. The native timeline corpus verifies live copy, live search and held disk handoff for covered, uncovered, empty, partial/truncated and unsupported timelines.

2. **Inherited compaction produces incompatible handoff identity — confirmed.** `ConversationCopyTests.testKeptCompactedSideRetainsCopyIdentityAfterRetirement` appends a generated checkpoint, opens a real helper side with `side.open`, checks that `keepNow` saved a `message` with `nativeKind: compaction`, and copies through the existing selection after idle retirement. Before the fix it throws “History changed. Refresh the range before copying” (`native-red.log`).

   Both representations now use the shared compaction heading and summary. Only inherited message rows lose their replay prefix; a top-level checkpoint's summary is already the saved summary and is not stripped again. This keeps intentionally repeated prefix text intact.

   Mutation: removing `nativeKind` from the disk adapter recreates the handoff rejection: **1 failing test / 1 failure** (`mutation-compaction.log`). The restored test passes, as do the existing historical edit/compaction corpus and Unicode page/handoff tests.

   **Same-pattern sweep: adopted compaction progress — confirmed and fixed in the same read functions.** A modern checkpoint durably adopts its preceding execution row. Helper replay updates that row's terminal evidence/title, while the disk copy/search adapters ignored the offset index's existing `adopted` flag. The generated `testAdoptedCompactionProgressKeepsTheSameCopyIdentity` reproduces the rejected handoff (`adopted-red.log`: **1 failing test / 1 failure**). The disk adapter now applies the same proven adoption state already used by helper replay and disk transcript projection before calling the shared formatter. `adopted-green.log`: **1 passed**. Copy and source-search call sites each have a mutation that omits the flag; the regression checks both the held copy and a query for the adopted title.

   `mutation-adopted-copy.log` rejects the held handoff; `mutation-adopted-search.log` loses the adopted-title hit. Each is **1 failing test / 1 failure**. Both call sites are restored. This correction changes only the app's interpretation of the existing index metadata; the tested helper source/binary remains unchanged.

3. **Whole-history work occupies the session actor and repeats — confirmed.** The generated 130-row fixture holds the first formatting row at a semaphore. Before the fix, Stop cannot execute within 500 ms; Next Results increases formatted-row observations from 130 to 260 (`helper-red.log`). No wall-clock race or large real journal is needed to establish actor occupancy.

   The session captures its retained arrays/index and a generation/revision key, then uses `BlockingWorkExecutor` to decode, format and hash away from the actor. Completed results are published only after checking cancellation, closure and the captured key. One immutable cache per snapshot stores formatted text in an immediately unlinked, mode-0600 file with a close-on-exec descriptor; only row offsets/IDs remain in memory. Search and copy use positional reads on workers and validate again before publication. Next Results and copy pages reuse the formatted rows and digest. Cache generation follows retained row changes, independently of unsaved streaming/display generations. The existing shared-load primitive coalesces readers and cancels work after its last reader departs; close cancels the load and releases the cache.

   Mutations: moving the build back onto the actor fails the Stop barrier (**1 failure**, `mutation-actor.log`); bypassing the cache fails the format-count assertion (**1 failure**, `mutation-cache.log`). Additional tests reject equal-count row changes while formatting, invalidate a completed cache after changed content, retain it across unsaved streaming, cancel/close without publishing a partial result, and let one concurrent reader finish when the other cancels. All seven `ConversationReadTests` pass after restoration.

4. **Live search misses reasoning/tool-only queries — confirmed; lead decision applied.** The two marker-only queries return no live hits but one saved hit each (`helper-red.log`, `native-red.log`). Search now reads the same cached shared-formatter text as copy, using the disk reader's case-insensitive matching semantics. The previous Round 3 “needs owner decision” search item is resolved by this lead instruction. Rendered Find and the separate message-text API retain their existing contracts.

   Mutation: building the source snapshot with `retainedDisplayText` instead of conversation text loses both marker hits (**2 failures**, `mutation-search.log`). `ConversationCopyTests.testLiveAndDiskSearchFindReasoningAndToolArguments` checks matching live/disk row IDs after idle retirement.

The combined initial helper run was **4 failing tests / 6 failures**. The initial native run was **2 failing tests / 5 failures** (including the expected thrown handoff rejection). These are runtime failures, not compile failures. The focused restored helper run is **31 passed / 1 opt-in skip / 0 failures** (`helper-restored.log`); the restored native regression run is **3 passed / 0 failures** (`native-green.log`).

### Nearby sweep and adversarial self-review

- Traced live search and paging, disk source search, disk copy pages and handoff digest computation. They now reach the same formatter, including both disk branch shortcuts. Checked ordinary string/array content, covered/uncovered/empty/partial/unsupported timelines, correction and continuation parts, exposed reasoning, tool arguments (absent `{}` versus explicit `null`, sorted keys and unescaped slashes), image omission, top-level checkpoints, inherited summaries and historical edit markers. The native corpus additionally exercises both sides of helper retirement; the existing contract test independently computes the ordered ID/text digest.
- Checked retained row changes in append, presentation updates, branch edits, compaction, full-history adoption, checkpoint replay and side preservation. Array mutation advances the retained generation, including equal-count replacement. Loading older rows completes before capture; unreadable offsets use the existing off-actor full-history recovery. No whole-history formatting or hashing remains in `SessionReads` or its actor closures.
- Reviewed cache ownership, cancellation before/after publication, last-reader retirement, joined-reader cancellation, same-ID runtime replacement and stale load cleanup. The runtime incarnation gate, strong revision check, app selection ownership and navigation/presentation identities remain intact. A stale worker cannot clear a newer load or publish its obsolete cache.
- Reviewed storage and wire bounds: no persistent extra journal, no named temporary capture path, no inherited cache descriptor, and no extra DerivedData root. Text still uses 16,384-unit UTF-16 pages without splitting surrogates; search retains 100 hits and 240-byte previews. Captures, tools, permissions, vaults and provider replay are unchanged.
- The final source audit rechecked worker publication guards, independent reader cancellation, cache descriptor lifetime, and generated project membership. SHA-256 verification matches the production sources used by the final helper/wire runs and restored native tests (`source-hashes.txt`). `xcodegen generate --quiet` regenerated the project after adding the shared formatter.
- Diff review is local and read-only; no other workstream's HostService/TraceStore functions were edited. All fixtures are generated/loopback with test homes and in-memory credentials. No installed application, real preferences, chats, Keychain or paid provider was used.

**Separate pre-existing follow-up — needs owner decision:** `SessionReplay.swift:323` (`endWithoutReceipt`) changes unfinished execution/request-ledger rows to an interrupted/partial presentation in memory. `HistoryReader.swift:778` and `ConversationContent.swift:257` still copy the original saved missing-receipt evidence. A generated unfinished request-ledger probe confirms that a held live copy then rejects its disk handoff without any source-row edit (`unfinished-progress-probe.log`: **1 failing probe / 1 failure**, “History changed”). The probe and reproduction script are retained as `unfinished-progress-probe.swift` / `.py` in the round's logs; the temporary diagnostic test is removed from the suite.

Unlike a durably adopted checkpoint, a missing terminal receipt does not by itself prove interruption: a disk reader can also encounter a still-running child that has no attached helper reader. Applying interruption to all such disk rows would misstate live work. Making helper source copies exclude recovery annotations would instead change their existing copy/search text. The conservative choice is to preserve both existing evidence policies and flag the decision: should source copy/search show raw retained evidence or normalized recovery annotations, with an explicit source policy carried through handoff? This follow-up is not silently normalized or presented as a terminal receipt. The assigned ordinary-answer, inherited-summary and durable-compaction cases are fixed.

### Validation commands and results

Failing-first and focused restored helper runs:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter 'ConversationReadTests|ContractTests|OlderRowsTests|HistoryReadCancellationTests'
```

Each helper mutation uses the first command with `--filter ConversationReadTests/<test name>` as recorded in `helper-mutations.py`; the source is restored in `finally`. The compaction mutation uses the native command below with only `testKeptCompactedSideRetainsCopyIdentityAfterRetirement` and also restores in `finally`.

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationCopyTests/testKeptCompactedSideRetainsCopyIdentityAfterRetirement \
  -only-testing:PiAppTests/ConversationCopyTests/testLiveAndDiskSearchFindReasoningAndToolArguments \
  -only-testing:PiAppTests/ConversationCopyTests/testTimelineCorpusCopiesAndHandsOffIdentically
```

The initial native red run selected the first two methods. These model-only methods do not open windows or change focus and use the focused-run lock exception.

Full helper and Release wire commands:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

`bundle-final.log`: pass. `wire-final.log`: **40 passed**, 35.637 s. `concurrent-final.log`: **4 passed**, 21.823 s. `acceptance-final.log`: **3 passed**, 3.483 s.

`helper-final.log`: **1,134 passed / 7 opt-in skips / 0 failures**, 1,141 executed in 417.359 s. `helper-cost-final.log`: **5 passed / 0 failures**, 3.403 s. Combined helper total: **1,139 passed / 7 skips / 0 failures**. Release helper SHA-256: `2a9bfff4236ea5c3f0b59871fd610846896a8b634dd9a1183be6cb3e576590ee`.

Affected native classes:

```sh
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/StorageTruthTests
TEST_RUNNER_PI_APP_CONVERSATION_COPY_GALLERY="$B/gallery-round4-review/copy" \
  "$B/logs/round4-review/native-lane.sh" native-copy-final -only-testing:PiAppTests/ConversationCopyTests
"$B/logs/round4-review/native-lane.sh" native-workspace-final -only-testing:PiAppTests/WorkspaceTests
"$B/logs/round4-review/native-lane.sh" native-transcript-final -only-testing:PiAppTests/TranscriptBugRegressionTests
```

`native-headless-final.log`: **40 passed / 1 opt-in performance skip / 0 failures**, 41 executed in 4.498 s after the adopted-progress correction (ContentSearch 7, Hardening 12, HistoryReaderCheckpoint 7, HistoryIndexFiles 3 + 1 skip, StorageTruth 11). Each serial class runs alone; window/gallery checks use `native-lane.sh`, which takes the shared lock and releases only its own owner token on exit, including failure.

**Retained validation failure:** an initial headless run failed `HardeningTests.testNativeSupervisorStartsTheBundledSwiftHostAndExitsOnEOF` because its test app lacked both the helper and manifest. A separately invoked bundle stage overlapped the embedding step: `build-bundle.py` removes and recreates the staging directories, and the test app had copied empty directories. `native-headless-staging-race.log` records **39 passed / 1 skip / 1 failure**; `staging-race-evidence.log` records the populated staging files and missing embedded files. Staging was serialized and the complete 41-test group rerun successfully above. This was validation orchestration, not an ignored test failure or product change.

`native-copy-final.log`: **10 passed / 0 skips / 0 failures**, 8.100 s, including the complete class and opt-in gallery. Inspected all three generated images under `gallery-round4-review/copy`: light/dark at 1080 × 700 points and narrow at 900 × 700 points. The source previews, message counts, range fields and action buttons remain legible and correctly placed; long preview text uses the existing ellipsis without covering controls.

`native-workspace-final.log`: **17 passed / 0 skips / 0 failures**, 0.533 s. `native-transcript-final.log`: **116 passed / 0 skips / 0 failures**, 146.506 s. **Final native total: 183 passed / 1 opt-in performance skip / 0 failures** (184 executed). The copy, workspace and transcript classes each ran alone with the shared full-lane lock. Acquisition uses atomic `mkdir`; a directory-removal notification avoids missing brief gaps between other lanes. The owner-token guard released only this workstream's lock after every run.

The final native logs also retain **15** SQLite “vnode unlinked while in use” diagnostics for generated `native-fixture-*` request databases in the unchanged `WorkspaceTests` cleanup (for example, `apps/macos/PiAppTests/WorkspaceTests.swift:238` and `:274`), and **8** for the already-recorded `wide-search-*` history indexes (`TranscriptBugRegressionTests.swift:625`, `:664`, and similar defers). These fixtures delete their temporary roots before every database handle has closed. All tests pass; these unrelated fixture cleanup warnings are recorded, not suppressed or repaired in this branch.

All seven mutations were caught and restored. Final read-only adversarial review and `git diff --check` pass; the tested production source hashes still match after all native runs. Only this build root's generated result bundle was removed; no cloned test-host directories remained. Text logs and the three inspected PNGs are retained. No installed app was launched, no real preferences/chats/Keychain or paid provider was accessed, and no other workstream's lock or build root was modified.

## Round 5 review

Review of `9298a94d3d370c8ee9dc1fa0b88adaca1f3792e2`, including the lead's decision to apply recovery presentation to disk source copy/search. Work continues on `dev/a130-wire`. Evidence is under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire/logs/round5-review`; `B` below is the existing build root.

### Findings and failing-first evidence

1. **`session_closed` interrupts an unchanged held selection — confirmed.** `ConversationCopyTests.testClosedRuntimePageRebindsBeforeUnloadAcknowledgement` takes a real retained selection and uses the existing supervisor command-sender seam to hold page replies. It replies `session_closed` while the same host epoch is ready and the session remains in `opened`. Before the fix, copying throws that rejection (`native-red.log`). The retirement classification now includes `session_closed`; the existing source/path, cancellation, full digest and saved revision checks still own the handoff. The same test also changes the saved bytes and requires rejection.

2. **Paged export rereads a large row quadratically — confirmed.** `ConversationReadTests.testSixteenMiBRowExportReadsItsBytesOnce` generates one 16 MiB assistant body, counts actual positional-read bytes, exports through ordinary 16,384-unit pages, and checks the exported length and SHA-256. Before the fix, only three pages read **50,331,696 bytes** from a **16,777,232-byte** formatted row (`helper-red.log`, **1 failure**). The regression stops a broken implementation at that point rather than reading roughly 16 GiB.

   The snapshot now caches exactly one decoded `NSString`, under a per-snapshot lock. This matches the disk reader and avoids repeating either full-row I/O or Swift-to-Foundation conversion. The existing text-page boundary logic has a shared `NSString` entry point. Search still uses positional reads independently; paging, decoding and cache replacement remain on blocking workers. The byte observer is nil in production and reports actual successful reads in tests. The eviction/Unicode regression checks that only one row remains cached, that switching rows reloads the evicted one, that a page never splits a surrogate pair, and that cached reads still honor cancellation.

   `helper-green.log`: the full **1,025-page** export reads **16,777,232 bytes once**, produces exactly those bytes, and takes **0.029 s** after snapshot creation. All **9 ConversationReadTests pass**. This is a deterministic I/O bound; the elapsed time is a measurement, not a machine-sensitive threshold.

3. **Recovery-only annotations disagree across held handoff — lead decision implemented.** The previous round's owner-decision item is resolved. `testRecoveredOperationsCopyAndSearchIdenticallyAfterRetirement` adds unfinished request-ledger and compaction-execution rows, plus completed/failed controls, to the generated parity corpus. The original copy throws “History changed” despite an unchanged journal (`native-red.log`). Saved source copy/search now applies the same no-terminal-receipt presentation as helper replay through `RetainedConversation.endWithoutReceipt`. The helper's existing recovery function delegates to that shared implementation; its behavior is unchanged. Durably adopted checkpoints retain their explicit completed presentation, and existing terminal receipts are preserved. No synthetic terminal record is written to the journal.

The initial native run has **2 failing tests / 2 failures**; the focused restored native run has **3 passed / 0 failures**, including adopted-compaction parity (`native-green.log`). The helper's initial test-authoring interpolation typo was corrected before the runtime failing-first run; its compiler log is retained separately as `helper-test-compile.log`.

### Commands and nearby sweep

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests/testSixteenMiBRowExportReadsItsBytesOnce
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationCopyTests/testClosedRuntimePageRebindsBeforeUnloadAcknowledgement \
  -only-testing:PiAppTests/ConversationCopyTests/testRecoveredOperationsCopyAndSearchIdenticallyAfterRetirement \
  -only-testing:PiAppTests/ConversationCopyTests/testAdoptedCompactionProgressKeepsTheSameCopyIdentity
python3 "$B/logs/round5-review/mutations.py"
```

The red native run selects the first two tests. These focused model tests do not create windows or change focus. Mutation commands and their exact filters are also saved in `mutations.py`, which restores original source bytes in `finally`.

Checked the held-copy source/epoch/error classification, the disk digest/revision rebind cache, the separate initial source-search and rendered Find routes, helper snapshot cancellation/publication guards, UTF-16 paging, row eviction and immutable snapshot lifetime, and both source-copy/search disk adapters. The only held-copy retirement-code list is in `WorkspaceContent`; ordinary errors continue to propagate. The disk reader already caches one decoded `NSString`; the helper now has the same bounded-row strategy. Separate message-text and tool-input APIs keep their prior contracts. Recovery normalization is shared by replay and disk formatting, with adoption applied first; the prior completed and inherited-compaction corpus remains covered.

### Mutation checks and adversarial self-review

All three mutations fail at runtime and were restored in `finally`:

- Disable the decoded-row cache hit: `mutation-cache.log`, **1 test / 1 failure**, with **50,331,696 bytes read after three pages**, reproducing the original bound violation.
- Remove `session_closed` from retirement classification: `mutation-closed.log`, **1 test / 1 failure**, throwing that rejection before handoff.
- Remove disk recovery normalization: `mutation-recovery.log`, **1 test / 1 failure**, throwing “History changed” on the unchanged parity corpus.

Read-only adversarial review checked that the additional retirement result does not bypass digest validation (the regression also edits equal-length saved bytes), row caching retains only one immutable decoded row and serializes concurrent page access, cache hits still check cancellation, and the same UTF-16 boundary checks serve both string entry points. The cache cannot outlive its snapshot or publish a different revision; it does not change the existing actor-side validation. Copy allocation and I/O are proportional to the exported text, with at most one decoded full row retained between pages. Recovery changes only the shared presentation; explicit terminal receipts and durable checkpoint adoption take precedence. No journal evidence, permissions or capture/tool/vault boundaries are changed.

### Integration with dev/next

Committed the fixes as `bb3ebe8d`, then ran `git fetch origin` and `git merge --no-ff --no-commit origin/dev/next`. The incoming tip is `649ea623291c9417443d61d3bb55314d8a2f5d9a`. The sole conflict is concurrent additions to `NEXT-RELEASE.md`; all entries from both sides are retained. Source files merge cleanly. The automatic `Sessions.swift` merge retains both the conversation snapshot cache and upstream's saved task-time recovery. Upstream's response-timeline indexing/canonicalization, compaction timing and sidebar metadata eligibility changes are preserved without modification. The merge is a two-parent commit on `dev/a130-wire`, with no rebase, fast-forward, history rewrite or change to `dev/next`.

### Merged-result validation

The tested merge is `0255fcb494c77f2861832be40d7eec5e7b1e54e9`. Commands use the same build root and fixture-only inputs:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/StorageTruthTests -only-testing:PiAppTests/SidebarSearchScopeTests
TEST_RUNNER_PI_APP_CONVERSATION_COPY_GALLERY="$B/gallery-round5-review/copy" \
  "$B/logs/round5-review/native-lane.sh" native-copy-merged -only-testing:PiAppTests/ConversationCopyTests
"$B/logs/round5-review/native-lane.sh" native-workspace-merged -only-testing:PiAppTests/WorkspaceTests
"$B/logs/round5-review/native-lane.sh" native-transcript-merged -only-testing:PiAppTests/TranscriptBugRegressionTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

Each `test-macos.sh` run invokes `PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py` and `xcodegen generate` before the native checks. Staging is serialized. The headless run builds the merged Release helper before the wire suites; subsequent native runs reuse that same unchanged helper. Window/gallery classes run alone under the shared full-lane lock, released with an owner-token check after each run.

`native-headless-merged.log`: **52 passed / 1 opt-in performance skip / 0 failures**, 53 executed in 5.742 s (ContentSearch 7, Hardening 12, HistoryIndexFiles 3 + 1 skip, HistoryReaderCheckpoint 7, StorageTruth 11, incoming SidebarSearchScope 12).

`wire-merged.log`: **40 passed**, 39.644 s. `concurrent-merged.log`: **4 passed**, 23.924 s. `acceptance-merged.log`: **3 passed**, 3.500 s. Release helper SHA-256: `2d7d73aa94abfcef1d027e9927a8064f60efa9ce7436c973551eb19865adcb3f`.

`helper-merged.log`: **1,148 passed / 7 opt-in skips / 0 failures**, 1,155 executed in 425.347 s. The merged 16 MiB regression again exports **1,025 pages / 16,777,232 bytes**, reads exactly **16,777,232 bytes**, and measures **0.030 s** after snapshot construction.

`native-copy-merged.log`: **12 passed / 0 skips / 0 failures**, 9.203 s. Inspected all three regenerated images in `gallery-round5-review/copy`: light and dark at 1080 × 700 points, narrow at 900 × 700 points. Source previews, message counts, range fields and copy/export controls are legible, correctly placed and unobscured; long row previews use the existing ellipsis. `native-workspace-merged.log`: **17 passed / 0 skips / 0 failures**, 0.520 s.

`native-transcript-merged.log`: **116 passed / 0 skips / 0 failures**, 141.625 s. **Final native total: 197 passed / 1 opt-in performance skip / 0 failures**, 198 executed.

`helper-cost-merged.log`: **5 passed / 0 failures**, 3.393 s, in its own process after the other helper and native runs finished. **Final helper total: 1,153 passed / 7 opt-in skips / 0 failures**, 1,160 executed. All wire/concurrent/acceptance suites pass as listed above.

The merged native runs retain the previously observed SQLite “vnode unlinked while in use” fixture-cleanup diagnostics: **18** in the incoming SidebarSearchScope fixtures (`native-headless-merged.log`), **15** in WorkspaceTests, and **8** in TranscriptBugRegressionTests. These concern generated search-scope, native-fixture and wide-search databases removed before every database handle closes (for example, `SidebarSearchScopeTests.swift:10`, `WorkspaceTests.swift:238`, and `TranscriptBugRegressionTests.swift:625`). All associated tests pass. This unrelated test-cleanup follow-up is recorded without changing another workstream's fixtures.

Final read-only adversarial review rechecked the merged adapters, runtime-retirement classification, cache locking/lifetime/cancellation, unchanged shared page boundaries, recovery/adoption precedence, and upstream timeline serialization. No further assigned defect remains. `git diff --check` passes, the generated project matches, and `source-hashes.txt` / `release-helper-sha256.txt` still match the exact production files and Release binary used by the merged tests. All three mutations are restored. The shared lock was released after every window/gallery run; no foreign lock was removed. Removed only this build root's final autogenerated result bundle; no test clone directories remained (`cleanup.txt`). Text logs and the three inspected PNGs are retained. No installed app, real preferences/chats, Keychain, live capture or paid provider was used.

## Round 6 review

Review of `f519e27c1d538cecaf7ea7cc91e5e51c2389da88`. Work remains on `dev/a130-wire`; there is no merge or fast-forward in this round. Evidence is under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire/logs/round6-review`; `B` below is the existing build root.

### Finding and failing-first evidence

**Streaming invalidates unchanged retained selections — confirmed.** The two helper regressions submit a real turn with a generated streaming client and deliver a `.text` delta through the provider callback into `AgentSession.delta`. One delta arrives between search and the first copy page; the other arrives between copy pages. Both assert that event sequence advanced while retained content generation did not. Before the fix, both throw `history_changed`: `helper-red.log`, **2 tests / 2 failures**.

The native regressions use a loopback Responses gateway with three explicit barriers. They wait until each actual delta appears in the helper snapshot, search while the response is running, and copy an earlier completed multi-page Unicode answer. One covers deltas before the first page and between pages, then hands the remaining pages to disk. The other hands the entire selection to disk immediately while the physical response remains running, with its active ledger outside the selected range. Before the fix, both throw “History changed”: `native-red.log`, **2 tests / 2 failures**. Removing the session from the model's `opened` set retires only this reader's live source, allowing the test to prove disk handoff while the physical response is still held at its barrier.

Initial test setup used a synthetic historical tool name, so the helper rejected submission before the fixture could stream (`native-fixture-setup.log`, **1 test / 2 timeout assertions**). It was corrected to a supported historical `read` call before the runtime red runs above. A subsequent native build exposed the frozen SwiftUI test reference's direct call to the changed copy method; `native-reference-adapter-build.log` records that compile error. Its adapter now computes the same selected digest once before paging. Neither authoring/build issue is counted as failing-first product evidence.

### Fix and nearby sweep

The shared retained formatter now supplies a length-delimited SHA-256 fingerprint of each row's ID and complete copy text. Search captures ordered fixed-size fingerprints, and the reader derives its digest from **only the selected first/last range**. The live strong snapshot revision uses retained content generation; range-aware pages validate the selected digest and runtime incarnation. Event sequence is not part of that identity. A different unselected row, append or active request ledger does not invalidate it; changed selected IDs/text still do.

Fingerprint creation, base64 preparation, selected-range hashing and text paging run off the helper session actor. The immutable snapshot caches the fingerprint manifest, and its page lock caches one selected-range digest alongside the existing one-row decoded text cache. The app computes its selected digest on the history reader and caches it for later pages. Next Results continues to reuse the formatted snapshot. The old whole-history digest remains in the wire search response for existing clients; the new app copy path does not use it for selection validation or disk handoff.

Disk source searches also retain row fingerprints. The disk handoff checks the selected rows with the same shared fingerprint/digest functions, caches the validated range for its stamped file snapshot, and retries if a writer changes the stamp between validation and paging. It validates both selections originally captured live and selections originally captured on disk. It does not compare or normalize an unselected active ledger. Existing shared recovery presentation still applies when a ledger itself is copied.

`testSavedSelectionsValidateOnlyTheirRange` changes rows before/after the selected range, appends between pages, then changes selected bytes and requires rejection. The helper's corresponding test changes an unselected retained row (including generation), then selected text. A generated 25,000-row manifest exceeds one wire frame; `testLargeRangeIdentityUsesBoundedDisplayTransfer` verifies bounded acknowledged transfer frames and exact reassembly. No new unbounded helper packet is introduced.

**Same-function race found by adversarial review — confirmed and fixed.** A second search could supersede the snapshot build awaited by a range copy after an unrelated row changed. The old build's internal cancellation escaped even though the copy task remained active. A deterministic worker barrier reproduces it: `superseded-load-red.log`, **1 test / 1 failure**, `CancellationError()`. The copy now retries this cancellation only when its captured snapshot key changed and its caller is not cancelled. Closure and caller cancellation still propagate; selected content is validated against the replacement snapshot before publication. `helper-restored.log`: **14 ConversationReadTests passed / 0 failures**.

The sweep covered live source search/page, both original live and disk selections, held-source retirement (`session_closed`, `session_missing`, changed runtime/epoch), equal-count selected/unselected changes, saved append/rewrite races, selection-token changes across awaits, shared-load retirement, cache cancellation/closure, UTF-16 page boundaries and large transfer framing. Separate rendered Find, message-text and tool-input APIs retain their existing contracts. The selected-range digest is cached, so it is not recomputed on every export page. The existing counted 16 MiB export regression remains in the full helper run.

### Commands and mutation checks

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests/testStreamingDelta
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationCopyTests/testCompletedRangeSurvivesStreamingAndDiskHandoffDuringTheResponse \
  -only-testing:PiAppTests/ConversationCopyTests/testCompletedRangeHandsOffWithAnActiveUnselectedLedger
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests/testSupersededSnapshotLoadRetriesAnUnchangedSelectedRange
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests
python3 "$B/logs/round6-review/mutations.py"
```

The restored focused native run additionally selects `testSavedSelectionsValidateOnlyTheirRange` and the existing `testClosedRuntimePageRebindsBeforeUnloadAcknowledgement`: **4 passed / 0 failures** (`native-green.log`). These methods create no windows or focus changes.

All five mutations fail at runtime, and each source is restored in `finally`:

- Reintroduce sequence-based selection validation: `mutation-sequence.log`, **2 tests / 2 failures**, both real delta placements rejected.
- Include all disk rows in handoff validation: `mutation-whole-history.log`, **1 test / 1 failure**, the unselected live ledger breaks handoff.
- Bypass selected live digest comparison: `mutation-selected-live.log`, **1 test / 1 failure**, changed selected text is incorrectly accepted.
- Bypass selected disk digest comparison: `mutation-selected-disk.log`, **1 test / 2 failures**, both changed selected ranges are incorrectly accepted.
- Remove the obsolete-build cancellation retry: `mutation-superseded-load.log`, **1 test / 1 failure**, the unchanged copy receives the internal cancellation again.

The first four commands/edits are in `mutations.py`. The fifth removes the `catch is CancellationError ... key != contentKey` clause and runs the single superseded-load helper method shown above. The original source bytes were restored before final validation. A final source-hash manifest records all ten modified source/fixture files.

### Final validation

Commands use the same build root and generated or loopback fixtures:

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/StorageTruthTests
TEST_RUNNER_PI_APP_CONVERSATION_COPY_GALLERY="$B/gallery-round6-review/copy" \
  bash "$B/logs/round6-review/native-lane.sh" native-copy-final -only-testing:PiAppTests/ConversationCopyTests
bash "$B/logs/round6-review/native-lane.sh" native-workspace-final -only-testing:PiAppTests/WorkspaceTests
bash "$B/logs/round6-review/native-lane.sh" native-transcript-final -only-testing:PiAppTests/TranscriptBugRegressionTests
TEST_RUNNER_PI_COMPONENT_GALLERY="$B/gallery-round6-review/components" \
  bash "$B/logs/round6-review/native-lane.sh" native-parity-final -only-testing:PiAppTests/PayloadNativeParityTests
TEST_RUNNER_PI_COMPONENT_GALLERY="$B/gallery-round6-review/components" \
  bash "$B/logs/round6-review/native-lane.sh" native-geometry-final -only-testing:PiAppTests/ConversationResultsGeometryTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
PYTHONPYCACHEPREFIX="$B/python-cache" python3 -m py_compile fixtures/native/ui-gateway.py
```

Every native script run stages the Release helper with `PI_BUILD_ROOT="$B" python3 scripts/build-bundle.py` and regenerates the project. Staging is serialized; no separate bundle build overlaps it. Window/gallery classes run separately under the shared full-lane lock. The wrapper releases only its matching owner token, including on failure. The frozen visual-reference adapter has no layout changes; its two caller classes are included above.

`helper-final.log`: **1,153 passed / 7 opt-in skips / 0 failures**, 1,160 executed in 418.697 s. `helper-cost-final.log`: **5 passed / 0 failures**, 3.564 s in its separate process. **Final helper total: 1,158 passed / 7 skips / 0 failures**. The counted 16 MiB export again emits **1,025 pages / 16,777,232 bytes**, reads exactly **16,777,232 bytes**, and measures **0.029 s** after snapshot creation.

`wire-final.log`: **40 passed**, 35.532 s. `concurrent-final.log`: **4 passed**, 24.770 s. `acceptance-final.log`: **3 passed**, 3.462 s. The Release helper SHA-256 is `3b12c0390733d1167191403310d4cad48fa781ea8bdbee3b6223961ee71e18ea`. Fixture Python compilation and `git diff --check` pass.

`native-headless-final.log`: **40 passed / 1 opt-in performance skip / 0 failures**, 41 executed in 4.662 s (ContentSearch 7, Hardening 12, HistoryReaderCheckpoint 7, HistoryIndexFiles 3 + 1 skip, StorageTruth 11). `native-copy-final.log`: **15 passed / 0 failures**, 11.716 s. `native-workspace-final.log`: **17 passed / 0 failures**, 0.558 s. `native-transcript-final.log`: **116 passed / 0 failures**, 142.041 s.

Inspected all three regenerated copy-sheet PNGs in `gallery-round6-review/copy`: light/dark at 1080 × 700 points and narrow at 900 × 700 points. The retained previews, message count, range fields and copy/export actions are legible and unobscured; long previews use the existing ellipsis. All three retain the existing layout.

The native logs retain the previously recorded SQLite “vnode unlinked while in use” diagnostics: **15** in WorkspaceTests and **8** in TranscriptBugRegressionTests. These are generated fixture databases removed before all handles close (`WorkspaceTests.swift:238`, `:274`; `TranscriptBugRegressionTests.swift:625`, `:664`, and similar defers). All associated tests pass; this unrelated cleanup follow-up remains recorded without changing its fixtures.

`native-parity-final.log`: **7 passed / 0 failures**, 198.636 s. `native-geometry-final.log`: **1 passed / 0 failures**, 5.005 s. **Final native total: 196 passed / 1 opt-in performance skip / 0 failures**, 197 executed. Also inspected the generated light/dark no-data conversation-sheet captures; the frozen-reference parity and full results-height checks pass.

Final adversarial self-review rechecked selected-range boundaries and ID/text framing, snapshot generation versus event sequence, runtime-incarnation and source/path fences, app selection-token ownership across awaits, cancellation versus superseded worker retirement, disk stamp revalidation/retry, cache locking and eviction, and bounded transfer framing. Changed selected bytes are rejected on both live and disk paths; unrelated rows are not part of the selected digest. All whole-history helper work still runs on blocking workers, and repeated pages reuse the selected digest and decoded row. No further assigned defect remains.

`source-hashes.txt` and `release-helper-sha256.txt` match the final tested sources and Release binary. The generated project is unchanged, Python syntax and final diff checks pass, and all mutations are restored. The shared lock was released after every window/gallery run; the final check observes another workstream's owner and leaves it untouched. Removed only this build root's final autogenerated result bundle; no clone folders remained (`cleanup.txt`). Text logs and inspected PNGs are retained. No installed app, real preferences/chats, Keychain, live capture or paid provider was used. No permissions, capture, tool, vault or data boundary changed.

## Round 8

Review of `fbb66e3bdf8aef4a59c57ca7d7ae64838b090c72`, on `dev/a130-wire`. No merge, rebase, or fast-forward in this round. Evidence lives in `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire/logs/round8`; `B` below is that workstream's existing build root. All fixtures are generated, imported from generated temporary files, or served over loopback.

### Findings, regressions, and decisions

1. **Imported conversation identity — confirmed.** `testImportedSelectionUsesTheJournalIdentity` performs the real desktop import, obtains its new UUID, searches the unchanged external journal, and copies its retained range. Before the fix it throws `unreadableRecord` (`copy-red.log`). The search snapshot now carries `journalID` independently of the desktop source record ID, workspace, and path. Disk pages validate the captured journal ID. `testImportedJournalCopiesRangesConversationAndExportWithItsOwnIdentity` exercises the sheet's Copy Range, Copy Conversation, and Export against a multi-page Unicode imported answer, then replaces the journal's header identity at the same path and requires the held copy to leave the clipboard untouched.

2. **Saved fingerprint scan monopolizes HistoryReader — confirmed.** Two generated fixtures contain 5,000 tool calls with their results (10,000 rows, 12,646,710 bytes) and 22,000 assistant rows (27,312,706 bytes). After warming only the offset index, each starts a cold retained search, requests a concurrent transcript page at the fingerprint boundary, and atomically measures that page's decode count. Before the fix the page runs only after all row fingerprints: **10,220 / 22,220 decodes**, **0.893 / 1.389 seconds** latency (`content-red.log`). The tests assert that the page precedes the end of the scan, with an additional generous one-second bound. After bounded yielding, the first restored run reports **248 / 248 decodes**, **0.00984 / 0.00681 seconds** page latency (`content-green.log`). Total search durations were 1.026 / 1.583 seconds; yielding improves admission, not the amount of retained text to fingerprint. Fingerprinting shares search's 32-record / 16 MiB decode budget; one oversized record runs alone. The captured file, offset index, and journal ID survive yields, and the original stamp is validated before publishing or caching hashes. Selected-range rebinding also yields in bounded batches.

3. **Repeated fingerprint manifests — confirmed.** A 26,000-row live search initially returns 1,121,101 bytes; before the fix its next page returns 1,121,539 bytes and fails the missing-manifest and 64 KiB reply assertions (`helper-red.log`). The caller now acknowledges `knownRevision` and `knownIncarnation` only when it holds that source's manifest. Matching live pages omit the manifest; independent readers and changed revisions/incarnations receive it. The restored reply is **12,207 bytes**, versus **1,121,120** for the initial reply with its added journal identity (`helper-green.log`). Disk search accepts the same revision acknowledgement and skips manifest work/return when it matches. `ConversationCopyReader` keeps fingerprints only for an exact source/revision/incarnation/journal identity match. Its regression first fails when a matching page omits hashes (`copy-red.log`), and also checks changed revision, runtime, and host source cannot borrow stale hashes. Existing bounded-transfer coverage remains for the first large manifest.

4. **Retries after a validated page — confirmed.** A helper worker barrier changes an unselected retained row after the immutable page has passed digest validation. Before the fix it pages twice; the regression requires one pass (`helper-red.log`). The helper now returns that validated immutable page while retaining closure, cancellation, and runtime fences. A disk writer appends at every validation/publication boundary (three times, so the regression is finite); before the fix the disk reader rebinds/pages four times (`content-red.log`). Disk paging now captures a bounded journal prefix, validates only the selected row identities/text, and retains the cursor's decoded text from that same pass. It returns that page without a stamp-retry loop. A changed journal header is still rejected, including replacement at the same pathname; replacing a file with the same journal preserves the validated selection. A later page captures and validates its own current selected range. Exact-stamp range and decoded-row caches remain bounded. Legacy strict `copyContentPage` behavior is unchanged.

Failing-first runtime totals: **7 tests / 9 assertions or thrown failures** across `helper-red.log` (2 tests / 3 failures), `content-red.log` (3 tests / 4 failures), and `copy-red.log` (2 tests / 2 failures). An initial native compilation needed the required description argument on the test's `eventually` calls (`fingerprint-red.log`); it is not product-failure evidence. A queued window run was cancelled before acquiring another workstream's lock; the import and manifest red tests above perform no focus changes.

### Commands

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" \
  --filter 'ConversationReadTests/(testSearchSendsFingerprintsOnlyWhenTheReaderNeedsTheSnapshot|testValidatedCopyPageReturnsWhileUnselectedRowsChange)'
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests/testRetainedFingerprintsYieldDuringFiveThousandToolCalls \
  -only-testing:PiAppTests/ContentSearchTests/testRetainedFingerprintsYieldDuringTwentyTwoThousandRows \
  -only-testing:PiAppTests/ContentSearchTests/testValidatedDiskPageDoesNotRetryWhileOutsideRowsAppend
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationCopyTests/testImportedSelectionUsesTheJournalIdentity \
  -only-testing:PiAppTests/ConversationCopyTests/testNextResultsKeepsOnlyTheMatchingFingerprintManifest
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --filter ConversationReadTests
python3 "$B/logs/round8/helper-mutations.py"
python3 "$B/logs/round8/native-mutations.py"
```

### Adversarial self-review and nearby sweep

The sweep checked source identity at search and page admission; imported desktop IDs versus retained header IDs; same-path replacement before and during copying; missing legacy IDs; source/revision/runtime changes during Next Results; independent readers entering at nonzero `start`; per-snapshot cache publication after yields; cancellation/closure after worker return; source offsets and presentation-update target IDs; adopted compaction/unfinished-ledger parity; bounded wire transfer of the first manifest; selected edits versus unselected updates/appends; UTF-16 boundaries; and the counted large-row export. The shared formatter, message-text API, rendered Find, navigation ownership, mounted presentation identity, permission/capture/tool/vault boundaries, HostService, and TraceStore were not changed.

Two edge cases in the first draft were caught and covered before final validation:

- Legacy rows with no explicit ID use the index's existing `record-<offset>` identity. The draft's new source-ID check rejected these; `legacy-red.log` has **1 test / 1 failure**. Identity validation now uses exactly the same fallback as indexing. Headerless legacy snapshots keep their optional journal identity rather than borrowing a desktop ID.
- A validated copy must survive an atomic replacement with the **same** journal identity and selected text. The draft additionally fenced inode identity; `path-replacement-red.log` has **1 test / 1 failure**. The final check validates the current journal header instead. The same test also replaces the header ID and requires rejection. Header validation retains the reader's existing 32 MiB record bound; it does not introduce a smaller header-size limit.

The new saved Next Results test needed `@MainActor` for its existing `LongChatScroll` fixture builder (`copy-green-build-error.log`). An initial yield-removal mutation captured a non-Sendable search pass inside an autorelease-pool closure and failed compilation (`mutation-fingerprint-yields.log`); that is not mutation evidence. The corrected mutation removes only the yield/decode budget and fails at runtime: **2 tests / 3 assertions**, page latencies **0.954 / 1.371 seconds**, and **10,220 / 22,220** decodes before the competing read (`mutation-fingerprint-yields-runtime.log`).

### Final validation commands

```sh
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip StreamingCostTests
swift test --package-path packages/swift-host --scratch-path "$B/swift-verify" --skip-build --filter StreamingCostTests
PI_BUILD_ROOT="$B" scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/StorageTruthTests
python3 "$B/logs/round8/fingerprint-mutation.py"
python3 "$B/logs/round8/compatibility-mutations.py"
TEST_RUNNER_PI_APP_CONVERSATION_COPY_GALLERY="$B/gallery-round8/copy" \
  bash "$B/logs/round8/native-lane.sh" native-copy-final -only-testing:PiAppTests/ConversationCopyTests
bash "$B/logs/round8/native-lane.sh" native-workspace-final -only-testing:PiAppTests/WorkspaceTests
bash "$B/logs/round8/native-lane.sh" native-transcript-final -only-testing:PiAppTests/TranscriptBugRegressionTests
TEST_RUNNER_PI_COMPONENT_GALLERY="$B/gallery-round8/components" \
  bash "$B/logs/round8/native-lane.sh" native-parity-final -only-testing:PiAppTests/PayloadNativeParityTests
TEST_RUNNER_PI_COMPONENT_GALLERY="$B/gallery-round8/components" \
  bash "$B/logs/round8/native-lane.sh" native-geometry-final -only-testing:PiAppTests/ConversationResultsGeometryTests
python3 scripts/test-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-concurrent-native-host.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
python3 scripts/test-native-acceptance.py "$B/swift-host/arm64-apple-macosx/release/pi-native-host"
```

`helper-full.log`: **1,155 passed / 7 opt-in skips / 0 failures**, 1,162 executed in 452.838 seconds. The 16 MiB counted export still reads exactly **16,777,232 bytes** for **1,025 pages / 16,777,232 exported bytes**, measured at 0.0267 seconds after snapshot construction. `wire-final.log`: **40 passed** (36.240 s); `concurrent-final.log`: **4 passed** (27.995 s); `acceptance-final.log`: **3 passed** (3.469 s).

`native-headless-final.log`: ContentSearchTests **13 passed**, HardeningTests **12 passed**, HistoryReaderCheckpointTests **7 passed**, HistoryIndexFilesTests **3 passed / 1 opt-in skip**, StorageTruthTests **11 passed**. Total **46 passed / 1 skip / 0 failures**, 47 executed in 10.085 seconds. The final fairness measurements are **0.01089 / 0.00686 seconds**, both **248 decodes** before the competing page.

All ten mutation checks fail at runtime, with exact original source bytes restored in `finally`:

| Mutation log (`logs/round8/`) | Regression outcome |
| --- | --- |
| `mutation-helper-manifest.log` — always resend hashes | 1 test / 1 failure |
| `mutation-helper-page-retry.log` — retry a validated page | 1 test / 1 failure (two page passes) |
| `mutation-desktop-identity.log` — use desktop ID for rebinding | 1 test / 1 thrown rejection |
| `mutation-reader-manifest.log` — discard matching held hashes | 1 test / 1 thrown rejection |
| `mutation-fingerprint-yields-runtime.log` — synchronous fingerprint loop | 2 tests / 3 assertions |
| `mutation-disk-page-stamp.log` — require unchanged file stamp after validation | 1 test / 1 thrown rejection |
| `mutation-legacy-id.log` — omit the index's synthetic-ID fallback | 1 test / 1 thrown rejection |
| `mutation-journal-replacement.log` — skip final journal identity validation | 1 test / 1 assertion |
| `mutation-selected-digest.log` — skip selected-row digest comparison | 1 test / 2 assertions (both selected text changes accepted) |
| `mutation-disk-manifest.log` — ignore the acknowledged disk revision | 1 test / 1 assertion |

The original four findings have direct red/green and mutation coverage. No owner decision is needed. `source-hashes.txt` captures the restored source/test files; the Release helper used by wire validation has SHA-256 `0fffd7541475f3752fb0890e2be8d08b2dec974cc8727574bc41b07b0e914cc0` (`release-helper-sha256.txt`).

`native-copy-final.log`: **18 passed / 0 skips / 0 failures**, 12.175 s, including the real imported sheet's range, whole-conversation and export actions and the previous streaming/disk-handoff cases. Inspected all three regenerated `gallery-round8/copy` PNGs: light and dark at 1080 × 700 points, narrow at 900 × 700 points. Headers, retained previews, range fields, status and footer actions are legible, correctly placed and unobscured; the existing long-preview ellipsis is preserved. `native-workspace-final.log`: **17 passed / 0 failures**, 0.657 s. `native-transcript-final.log`: **116 passed / 0 failures**, 144.695 s.

The recorded performance comparison isolates fingerprint generation with a warm offset index. Existing cold journal index construction remains synchronous and unchanged (`HistoryReader.buildIndex`); this round adds yielding to the fingerprint and selected-range formatting passes, not a new journal-indexing architecture.

The unchanged generated-fixture cleanup diagnostics recur: **15** SQLite “vnode unlinked while in use” messages in WorkspaceTests and **8** in TranscriptBugRegressionTests, at the existing temporary database cleanup sites (`WorkspaceTests.swift:238`, `:274`; `TranscriptBugRegressionTests.swift:625`, `:664`). Those tests all pass. No such diagnostic appears in the headless storage/search or copy/export runs. This pre-existing cleanup follow-up is recorded without changing unrelated fixtures.

Identity sweep also verified that `WorkspaceHosts.open` still rejects imported originals, and `SessionJournal` verifies a native runtime's header ID against its runtime ID. Thus live snapshots can publish that validated runtime/journal ID, while imported disk snapshots carry the original external header ID. No writable-helper path was opened for imported originals.

`native-parity-final.log`: **7 passed / 0 failures**, 201.690 s. `native-geometry-final.log`: **1 passed / 0 failures**, 5.042 s. **Final native total: 205 passed / 1 opt-in skip / 0 failures**, 206 executed. `helper-cost-final.log`: **5 passed / 0 failures**, 3.560 s in its own process after the other runs. **Final helper total: 1,160 passed / 7 opt-in skips / 0 failures**, 1,167 executed. Release wire/concurrent/acceptance totals remain **40 / 4 / 3 passed**, with no failures.

The final adversarial review checked the exact restored, tested diff and found no remaining assigned defect. Source/test hashes and the Release helper hash were rechecked after all runs and still match. All window/gallery runs held the shared full-lane lock; every owned lock was released, including failed runs, and no foreign lock was deleted. Removed this build root's last automatically named result bundle; no clone folders remained (`cleanup.txt`). Text logs and gallery PNGs are retained. No installed Bello Agent app, real preferences/chats, Keychain, live capture, or paid provider was used. `git diff --check` passes, and the generated project is unchanged.
