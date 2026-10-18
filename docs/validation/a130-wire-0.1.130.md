# 0.1.130 app/helper wire contracts

Branch: `dev/a130-wire`; base `6fc551e1941a7e53a71d5e6e04408ba1ae7d49c1`. All generated data, in-memory credentials, loopback gateways and the isolated test host. Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-wire`; text logs in `logs/`. No installed-app launch, live data, preferences, Keychain, paid calls, release or merge. The lead owns integration into `dev/next`.

## Fixes and decisions

- **WIRE-CONTRACT-1:** `CaptureDelivery` serializes each capture packet, sends small packets unchanged, and transfers larger packets in acknowledged 32 KiB base64 pages. `HostTransport` validates identity, contiguous offsets, page size and final JSON before publishing the complete packet to the archive. Intermediate acknowledgements retain an in-memory prefix; the final acknowledgement still waits for archive acceptance. Rejection or shutdown discards the unfinished transfer. No truncation, plaintext spool, new capture quota or change to credential masking. No `TraceStore` changes; all capture packet kinds use the same delivery boundary.
- **WIRE-CONTRACT-2:** Inspector MCP admission pins workspace activity before helper startup, through display-result assembly, durable result saving and retention acknowledgement, including cancellation of the sheet. A count preserves concurrent invocations. Caller timeouts keep the pin while either the invocation or its retention acknowledgement is still physically outstanding; `HostSupervisor` releases settlement waiters on the reply or host loss. Timeout errors and existing unknown-outcome handling are unchanged. The helper independently checks admitted Inspector execution and the MCP manager's running/setup/awaiting-retention state before acknowledging quiescence.
- **CONCURRENCY-LIFECYCLE-2:** the same pin participates in host busy state and both idle-timer eligibility checks. Finishing a concurrent chat cannot stop a helper carrying an Inspector call. On completion/error the pin is released and ordinary idle scheduling resumes. Existing explicit Quit/Pause confirmation and unknown-outcome recovery remain unchanged.
- **WIRE-CONTRACT-3:** snapshot ordering uses the existing `monitoring.epoch` (the helper's `displayEpoch`), not the session ID alone. A replacement resets sequence, projection, receipt/task/context revisions and queue-edit revision gates; it retires in-flight presentation reads. The first lower-sequence snapshot applies immediately. Retired runtime identities cannot be adopted again, and asynchronous decode is fenced. Navigation changes still win. No helper runtime/recovery rewrite or reader unload/reopen is needed.

**Needs owner decision:** `apps/macos/PiApp/Application/UpdateController.swift:85` still describes MCP-only activity as a running chat in the existing Pause and Install confirmation. This branch preserves that copy and the explicitly confirmed pause policy; it prevents unconfirmed installation and idle shutdown. Any MCP-specific confirmation wording is a separate visible-UX decision.

No view/layout/style changes or production feature switches. Native mounted-reader integration checks cover the changed presentation behavior. `SubagentDisplayGalleryTests` regenerated 40 images under the shared lock; the light/dark `child-report` scenes at 1240×800 and 640×600 were visually inspected. No new layout issue was found; narrow labels use the existing ellipsis/wrapping.

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

## Contract sweep: helper-to-app frames

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

## Contract sweep: activity and quiescence

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

## Contract sweep: session ID versus runtime identity

- `WorkspaceHosts.open`, `opened`, `sessionOpenings`, `helperSessionDidUnload` and host-loss resets: explicit unload/reconnect paths already fence connections. `openAgentChild` is the intentional same-ID replacement without unload; fixed at snapshot adoption so the reader stays attached.
- `WorkspaceRefresh`, `SessionDisplay`: sequence/projection/task/receipt/monitoring/context/queue-edit gates now reset for a replacement epoch; old snapshots cannot settle intents, adopt side state, replace paths or update subagent lists.
- History paging, versions, Find, reveals, source navigation and `ConversationPresentation`: helper cursors carry incarnation+lineage; publication also uses navigation/presentation generations. Replacement retires reads without moving focus or erasing retained rows.
- `WorkspaceCostLimits`/`SessionBudgetState`: read tokens and host connections fence explicit unloads; child costs use durable accounting revisions, not resettable runtime sequences. `SubagentCostCursor` orders turn, revision and progress epoch. Durable costs must not be reset when a child runtime changes.
- Subagent discovery/list registration and `subagentSummaries`: durable origin/turn/revision and live host authority; follow-up identity remains the same child with a later turn.
- Prepared context and footer observations: `ContextInputIdentity`/runtime epoch and revision envelopes qualify counts; cached revisions are invalidated at snapshot adoption. Managed readers cannot send or independently change permissions.
- Completion sound and webhook trackers: already compare monitoring epochs and use a baseline on epoch changes; managed children do not produce independent notifications.
- Capture/Inspector caches: physical attempt ID + host epoch/workspace scope, not the session runtime sequence. MCP retention uses host epoch + unique command ID. Drafts, saved metadata, message accounting and journal ancestry intentionally remain durable session identities.

## Additional findings, not fixed in this scope

1. `packages/swift-host/Sources/PiAgentCore/HostService.swift:124` and `:185`: a generated command with a 1,100,000-byte invalid `commandId` fits the inbound command-frame allowance, but its rejection echoes that ID without bounding the reply. The Release helper exits 70. Reproduced in `sweep-overlong-command-id.log`; this is distinct from capture delivery and needs a separate fix.
2. `apps/macos/PiApp/Workspaces/WorkspaceConnectionProbe.swift:31`–`:65`: onboarding creates a private helper and sends `connection.test` without registering it in `hosts` or the workspace activity predicate. An update/idle sweep cannot account for that pending request. Static contract finding only; no live/provider probe performed. Needs owner decision: whether update should await/cancel onboarding connection tests explicitly. Kept outside this branch's assigned Inspector MCP fix.

3. `apps/macos/PiApp/Workspaces/WorkspaceHistory.swift:37` and `packages/swift-host/Sources/PiAgentCore/SessionReads.swift:22`: a reader browsing retained history can still hold an old helper-incarnation cursor after same-ID runtime replacement; paging sends it unchanged and the helper rejects it as stale. The live-tail regression is fixed, but automatic rebinding of a held history cursor is a separate pre-existing navigation case. Static contract finding; no cursor migration added here.
4. `packages/swift-host/Sources/PiAgentCore/HostService.swift:774` and `:410`: non-MCP submission preflight awaits skill/resource preparation after its quiescence check but before the session becomes busy. A raw wire `workspace.quiesce` can cross that interval without an independent admission counter. Native send/open callers already have activity guards. Static protocol finding; the scoped Inspector counter does not change general submission admission.

## Adversarial self-review

Reviewed the final diff for chunk rejection/close races, prefix-vs-durable acknowledgement, malformed/changing chunk IDs, Unicode/JSON escaping, retained capture/credential boundaries, pin admission before awaits, concurrent pins, cancelled-sheet result retention, failed saves, caller timeout versus physical command completion, settlement-waiter release on host loss, execution-vs-retention quiescence, navigation winning over awaited snapshots, retired-epoch rollback, same-epoch ordering, and durable cost/notification identities. No TraceStore masking, tool authorization, vault, journal or production rollout change. The assigned fixes have no remaining identified defect in the exercised paths. The separately listed rejection-frame, onboarding-activity, retained-history-cursor and general-preflight gaps remain outside this workstream. All native changes are in activity/transport/snapshot code; no visual-control code changed.
