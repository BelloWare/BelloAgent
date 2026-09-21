# Stable task presentation during tool streaming

Implemented on September 21, 2026 in `BelloWare/BelloAgent`, `main`, starting
from `c846b9f`. This follows the uploaded **Implementation-Plan _1_.md** (reviewed
baseline `1b58c8a`) while preserving the intervening progressive history loading,
inline skills, historical edits and reopened-chat refresh fixes. Implementation
was completed locally before publication; it is now included in
[Bello Agent 0.1.72/build 76](validation/Bello-Agent-0.1.72-2026-09-21.md).
Implementation commits: `1861284` (helper lifecycle and recovery) and `0614e38`
(native presentation, request-aware fixture and regressions).

## Presentation contract

A normal accepted task owns one compact work row. Its source assistant messages
own separate prose rows, created only when non-whitespace prose exists. Empty,
reasoning-only and tool-only replies update work details without creating a prose
placeholder or moving already visible prose into another container. The work row
remains after completion, including for tasks with no tools. Details stay closed
until the reader opens them; their request ordering, arguments, results, warnings,
accounting and inspect/copy actions remain accessible.

Only explicit task-terminal evidence creates a Turn summary. A completed model
reply, `message_end`, `turn_end`, quiet tool, missing usage or a session-wide busy
flag cannot establish that outcome. Automatic compaction, physical HTTP retries,
tool batches and delivered steering retain the task. A queued successor can be
active in the same snapshot that finalizes its predecessor. Manual compaction and
title work have a utility phase, not a fabricated user-turn completion.

The dock has a fixed 40-point content height and keeps current phase, elapsed
time and Stop in stable slots. Long names truncate with the full description
available through help/accessibility. Detailed figures stay in the task/request
disclosures and inspectors. A compact terminal line has one stable identity;
late accounting does not recreate it. Dock retirement and terminal adoption use
the same presentation snapshot, with no independent delayed exit callback.

Failures, cancellation, interruption and output limits retain distinct outcomes.
Retries after a terminal failure create a new execution generation. A partial
answer from a failed physical attempt remains a separate interrupted, non-replayable
source; successful retry text is never concatenated onto it. Retained
`nativeStopReason` is now read back as well as written. An old journal without
terminal evidence says that the outcome is unavailable; it does not infer success.

## Identity, persistence and compatibility

`TaskPresentationRecord` and version-1 `TaskPresentationProjection` are shared
between the helper and native target. Snapshot evidence carries session, runtime
epoch, selected timeline, source sequence/revision, an optional active task and
up to 64 recent terminal records. Each execution records its root input, active
input, stable anchor, assistant, logical operation and physical attempt separately.
Root/execution and assistant/call composite keys are length-prefixed to avoid
ambiguous concatenation. Steering may change the active input without changing
the original root.

`SessionRun` writes `pi-app.task-terminal.v1` at the actual continuation decision,
using the journal's durable flush boundary before advancing to queued work.
Provisional and committed messages carry the same source ID, applicable input/root
and `nativeTaskExecution`; provisional timestamps are stable. Issued-call/reply
counts and model/tool duration accumulate in the helper independently of the
bounded display cards. Preparing arguments are not issued calls.

The existing saved-state record includes the active execution checkpoint. Helper
recovery reconstructs retained counters and reports an interrupted execution if
the previous runtime ended without terminal evidence. It does not replay work.
Read-only cold history without such terminal evidence remains unresolved until
helper reconciliation. No old journal must be rewritten merely to display it.

Both helper history pages and the native indexed reader carry bounded terminal
records. Branch changes prune evidence belonging to abandoned sources. If an
execution is older than the 64-record retained metadata window, its history stays
readable with an unavailable outcome. Visible-suffix usage remains explicitly
partial even when the helper knows the whole-task call count. This is not a new
whole-history billing aggregator. The selected timeline is cached, not rescanned
on every status refresh.

The helper and native reader must eventually ship together. This adds no new
provider API, prompt policy, tool-admission rule, queue-delivery rule or capture
format. Existing full-body capture and retained-detail endpoints remain the
authorities for those data; the renderer never derives lifecycle by parsing raw
HTTP bodies.

## Native adoption and bounded work

`WorkspaceRefresh` decodes/applies rows off MainActor before adopting rows,
lifecycle and structural notices in a single `SessionDisplay` presentation batch.
After the suspension it checks the current host/session generation, requested
projection and viewport again. Lifecycle sequence, source revision, epoch and
timeline must match. Invalid deltas resynchronize rather than combining new
finality with an unapplied row patch. Status-only refreshes preserve held rows.

`TaskTranscriptPlan` is the same reducer for initial history and incremental
updates. Render ownership is `work:<root/execution>`, `block:<assistant source>`
and `summary:<root/execution>`. Inspect/scroll links still resolve from original
message IDs. An explicit retry with no new user row anchors after the previous
retained source, including when dispatch fails before any output.

Prose-only hosts omit work/accounting fields from their equality input. Closed
work rows retain their fixed measurement through hidden argument/result changes;
their stored detail data still update. The existing leading/trailing coalescer
now accepts cosmetic tool fragments, keeping at most one pending presentation
per pane at approximately 30 Hz. Identity, first content, call membership/state,
phase, failure and terminal changes flush promptly. Capture is upstream of this
display scheduling and loses no fragments.

Tool disclosure and full-argument fetch caches are scoped by assistant plus call
ID. Fetch ownership also includes a generation, so a forgotten then reissued
fetch cannot accept the retired callback. A legacy raw call-ID lookup works only
when unambiguous. The opening question remains the logical reading anchor while
offscreen row estimates settle; actual user scroll or Jump to Latest releases it.
This fixes a measured 17-point opening drift that the old preceding-row anchor
could introduce.

## Evidence and limits

The before-change mounted native probe reproduced one false terminal footer,
a 24-point work-header insertion and placeholder reclassification:

```text
TOOL_PRESENTATION_BASELINE falseTerminal=1 headerHeightDelta=24.0 placeholderReclassified=1
```

After the change, the mounted native phase fixture reports:

```text
TOOL_PRESENTATION_NATIVE falseTerminal=0 hiddenArgumentProseRemeasures=0 closedHeaderHeightDelta=0
TOOL_GATEWAY_NATIVE panes=2 requests=3 issuedCalls=2 falseTerminal=0 publications=39 checkedBodies=6
```

The second fixture mounts main and narrow panes and uses the staged production
helper with `fixtures/native/tool_phases.py`. This loopback Responses gateway
validates the model, authentication, streaming flag, tool schema, arguments and
replayed call/result pairing before deciding the next response. It fragments SSE
at arbitrary byte boundaries, includes Unicode, streams tool arguments, executes
two safe fixture commands and ends with prose/usage/cost. Its explicitly portable
replay profile exercises the supported portable route. All three request and
three response bodies are compared byte-for-byte with actual captured bodies;
these are not normalized-event comparisons. A separate mounted two-session test
reuses assistant IDs to check pane isolation and completion announcements.

Debug native selection/draw sample: **30 iterations, median 0.573 ms, p95 0.744
ms, maximum 2.244 ms**, no prose-origin change, no prose remeasurement and retained
native text selection. Each iteration applies a cosmetic fragment or late
accounting update and gives the mounted window a `displayIfNeeded` opportunity.
Environment: Apple M3 Max (Virtual), macOS 14.8, Xcode 16.1/16B40, arm64 Debug with
actor data-race checks, visible native windows, synthetic 16-ms cadence. This is
not display-link FPS, physical 120-Hz latency or a guarantee for arbitrary tools.
The before probe establishes the topology defect, not a comparable frame-time
baseline. Structural assertions are deterministic; machine timing is reported,
not made into a new universal timing gate.

Passing evidence across focused runs: **82 distinct helper cases** and **107
distinct Debug native cases**. The broad native pass executed 91 tests, with two
explicit pointer-environment skips and no failures (89 passed). The final focused
run passed 34 cases after the retained-stop-reason and scoped full-argument checks.
Helper final-source selection passed 33 cases; the earlier 69-case run also covers
five automatic retries/six attempts and compaction safety. These totals deduplicate
overlapping runs, rather than adding repeated cases together.

Optimized native validation passed **49 distinct cases**: the main run executed
47 with two explicit pointer skips (45 passed), followed by three focused
`ConversationPaneTests` input/paste/placeholder cases and the packaged-helper
historical-edit/inline-skill integration case. The last check preserves the
preceding plan's compacted-fork rollback and exact request/capture assertions. The same 30-iteration native
draw fixture reported **median 0.306 ms, p95 0.430 ms, maximum 1.744 ms**, with zero
prose movement/remeasurement and selection retained. Release also enabled actor
data-race checks; the request-aware gateway again matched all six bodies (40
presentation publications). No timing assertions were relaxed to obtain these results.

Logs and xcresults are scratch artifacts under the remote session's
`tmp/fresh-transcript` (`stable-tools-before`, `stable-tools-native6`,
`stable-tools-native-final2`, `stable-tools-release`, `stable-tools-input`, `stable-tools-historical`); helper logs are its sibling
`stable-tools-helper5.log` and `stable-tools-helper-final.log`.

Not verified here: an actual deployed LiteLLM route; a physical pointer/keyboard
session on the owner's Mac; display-link frame latency; a 30-second wall-clock
silent tool; a new 20-session interactive UI benchmark; simultaneous inspector,
report and popup operation during the new phase fixture. Native key/IME entry
points, real text selection and scroll geometry are tested, but that does not
turn the two opt-in physical pointer skips into passes. Install/update/release
rehearsals were not run. No app-wide performance or compatibility claim follows
from these focused checks.

## Acceptance dispositions

**Pass** means the described deterministic/source boundary was exercised in the
named passing suites; it is not a claim of physical UI or deployed-server testing.
**Partial** identifies a remaining environment/workload gate. `ST` below is native
`StableToolPresentationTests`; `TP` is helper `TaskPresentationTests`.

| ID | Result | Evidence / remaining boundary |
|---|---|---|
| L01 | Pass | ST phase/gateway and TP held tools: assistant completion never finalizes pending tools. |
| L02 | Partial | TP uses an explicitly gated quiet tool; there is no cosmetic completion timer. A 30-second wall-clock UI hold was not run. |
| L03 | Pass | TP and ST run/reduce 15 sequential rounds with one work identity and one true terminal. |
| L04 | Pass | ST mounts prose first, then 1,000 argument changes; its existing body measurement/origin does not change. |
| L05 | Pass | Preparing fragments, validation and issued count are separate in ST gateway and TP counts. |
| L06 | Partial | Success and state/disclosure regressions pass; every failed/skipped tool type was not replayed through the new mounted gateway. |
| L07 | Pass | TP crash checkpoint reports interrupted/unknown effects; native safety and retained warning checks preserve uncertainty. |
| L08 | Pass | TP no-output retries and helper Retry/RetryRecovery tests cover distinct executions and retained non-replayed partial answers. |
| L09 | Pass | CompactionGateway/CompactionReceipt tests preserve task scope through automatic/recovery compaction; manual utility creates no task. |
| L10 | Partial | TP stops a held request and checks cancelled outcome; coalescer flushes terminal immediately. Physical Stop in every preparation/tool phase was not exercised. |
| L11 | Pass | TP and ST adopt a terminal predecessor plus active queued successor together. |
| L12 | Pass | TP steering uses its own input within the original root; SteeringTests and ST scope assertions pass. |
| L13 | Pass | TP crash recovery, ST epoch rebinding and WorkspaceRefreshLifecycleTests reject stale owners and leave no phantom active task. |
| L14 | Pass | TP abandoned-evidence pruning, HistoricalEdit/EditRecovery tests and native generation/refresh guards preserve selected branches. |
| G01 | Pass | ST empty/thinking/tool-only phases create no prose body. |
| G02 | Pass | Three-request mounted gateway finishes with two independently owned prose bodies. |
| G03 | Pass | ST metadata/selection draw fixture retains body host, measurement count and origin. |
| G04 | Pass | Closed work header stays the same height across all argument fragments and new calls. |
| G05 | Pass | TranscriptDisclosureTests and selected streaming-card tests preserve reader-owned disclosure through refresh and pane changes. |
| G06 | Pass | Scoped full-document fetch tests, NativeWorkListViewportTests and disclosure geometry tests retain occurrence ownership. |
| G07 | Pass | ST holds actual native text selection while arguments and late accounting arrive; copy/source assertions remain. |
| G08 | Pass | NativeTranscriptScroll/Document tests preserve detached reading anchors and scrolling geometry. |
| G09 | Pass | NativeTranscriptTests and scroll tests preserve actual growth/follow policy; new work chrome does not reparent prose. |
| G10 | Partial | One immutable snapshot owns footer/dock transition and the delayed exit is removed. Actual dock-release anchor-correction count was not separately instrumented. |
| G11 | Pass | ST rebind/retired-presentation checks plus refresh lifecycle tests prevent outgoing work entering a replacement pane. |
| G12 | Pass | ST mounts two independent streaming sessions with colliding source IDs and different execution outcomes. |
| G13 | Partial | 280-point dock and 320-point gateway pane pass with long names/metadata; the entire accessibility text-size matrix was not rerun. |
| G14 | Pass | ST historical window derives the live dock from lifecycle, independently of its mounted suffix. |
| G15 | Pass | HistoryWindow, native history/document and reopened-chat lifecycle tests retain source windows, paging and one reducer key per task. |
| M01 | Pass | ToolCallSummary/native safety tests preserve absent usage; native gateway covers reported values. |
| M02 | Pass | ST late-accounting selection/draw and duplicate-terminal tests patch metadata without moving prose or repeating a footer. |
| M03 | Pass | ST reused call IDs and scoped full-document caches; preparing fragments do not count as issued. |
| M04 | Pass | TP counters survive bounded projection; ToolCallSummary tests retain full counts and partial usage coverage. |
| M05 | Pass | SessionDisplay batch test publishes once; WorkspaceRefreshLifecycleTests cover asynchronous owner changes. |
| M06 | Pass | Status-only SnapshotProjection and refresh lifecycle tests preserve rows and adopt scoped state. |
| M07 | Pass | Refresh verifies host/generation/projection/viewport after decode; branch and retired-owner tests pass. |
| M08 | Pass | 1,000-fragment coalescer has one pending value, final fragment flushes; mounted gateway compares six exact HTTP bodies. |
| M09 | Pass | ST trailing flush plus failed-terminal and session-switch checks do not wait for cosmetic delay. |
| M10 | Pass | ST direct skipped-phase/terminal adoption works without observing every intermediate event. |
| M11 | Pass | ST repeated terminal/late metadata and TP new explicit retry generation keep one summary per execution. |
| M12 | Pass | ST announces completion once, not per tool round or old history; existing sound receipt ownership is unchanged. |
| P01 | Partial | Mounted normal phase/fragment sequence has zero false footers and zero metadata-origin changes. All error/retry phases were not individually measured as physical frames. |
| P02 | Partial | ComposerSubmission and focused ConversationPane input cases plus real native selection checks pass. Physical IME typing during concurrent gateway streams remains unmeasured. |
| P03 | Pass | Native document, disclosure, viewport and selected streaming-card checks cover open/closed resize, selection and stacked geometry. |
| P04 | Partial | Exact capture regression passes and raw parsing stays out of the reducer; simultaneous inspector/report/popup UI replay remains unverified. |
| P05 | Pass | Native safety, retained-stop-reason, partial diff/fetch and helper output-limit tests retain warnings. |
| P06 | Pass | TP hidden status builds zero display projections; native document budgets and helper snapshot tests preserve bounded work. |
| P07 | Pass | TP/helper restart and native cold indexed history use the same task grouping/evidence policy; full retained argument access passes. |
| P08 | Pass | Request-aware real-helper fixture verifies exact bytes and both call/result round trips; crash and retry tests preserve no-replay safety. |

## Reproduction

Use the existing external build cache and put logs/xcresults in a fresh scratch
directory. Stage the changed helper before Xcode testing; the native embed step
does not rebuild it. For example, from the repository root, after setting
`PI_BUILD_ROOT`, `PI_APP_SCRATCH_ROOT` and `TMPDIR` to task scratch directories:

```sh
python3 scripts/build-bundle.py
swift test --package-path packages/swift-host \
  --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'TaskPresentationTests|RetryTests|RetryRecoveryTests|HistoricalEditTests|EditRecoveryTests|Compaction|HistoryWindowTests|SnapshotProjectionTests|SteeringTests'
xcodebuild test -project PiApp.xcodeproj -scheme PiApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-crash-debug" \
  -resultBundlePath "$PI_APP_SCRATCH_ROOT/stable-tools.xcresult" \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptUpdateIsolationTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptScrollTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ToolCallSummaryTests \
  -only-testing:PiAppTests/WorkspaceRefreshLifecycleTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  ENABLE_TESTABILITY=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-actor-data-race-checks'
```

The final focused Debug run additionally selected `TranscriptWirePageTests`,
`TranscriptRowUpdateTests`, `NativeWorkListViewportTests` and these
`TranscriptStreamingStressTests` cases: `testOpeningACutCardFetchesTheRestAndGrowsIntoIt`,
`testACardWhoseFetchFailsKeepsWhatItHasAndAsksOnce`,
`testATwentyKilobyteEditReadFromAJournalShowsAPartialDiff`, and
`testOpenToolCardsSurviveWidthAppearanceScrollingAndChatSwitches`. They explicitly
open the work disclosure and use source-scoped call IDs; full-fetch, selection,
failure and sizing assertions remain. The broad Debug run also selected
`TranscriptPerformanceRegressionTests` and Markdown regressions. The input checks
in `ComposerInputTests.swift` extend `ConversationPaneTests`;
select that class with the three method names
`testFindingTheComposerForStrayTypingDoesNotWalkTheWindowPerKeystroke`,
`testPastingALargeScreenshotDoesNotBlockTheMainThread` and
`testThePlaceholderSitsWhereTheTypedTextWill`. A filter named `ComposerInputTests`
would select no tests. The final compatibility check selected
`HistoricalEditingTests/testNativeCompactedForkEditSelectsInlineSkillAndSubmitsThroughPackagedHelper`.
Serialize native window suites. Repeat changed native cases in Release with a
separate cached DerivedData path and a new result bundle; avoid recompiling
unrelated checks.

The two interactive pointer probes remain opt-in through
`PI_APP_INTERACTIVE_POINTER_TESTS=1` on a desktop that can receive physical input.
Do not substitute another batch of reducer assertions for that environment gate.
