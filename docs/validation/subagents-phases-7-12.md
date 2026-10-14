# Sub-agents continuation validation — 0.1.126

Worktree `wt-subagents`, branch `dev/subagents`. Build/test artifacts use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents`.
Only generated fixtures and loopback gateways; no installed app, real vault,
preferences, Keychain or paid providers. The production switch stayed off
through phase 11 and is enabled in phase 12. This worktree has not been merged
into `dev/next` or published as a release.

## Review after the 0.1.126 audit merge

Started from `f4bf746b`, which includes `dev/next` audit fixes `2f12977a`;
`git pull --ff-only origin dev/subagents` was already up to date. Rebuilt before
testing. Artifacts for this review use `logs/review2-*` and `review2-*.xcresult`.
Implementation commit: `744566bb` (`Fix sub-agent opening, settlement and review UI regressions`).

The canonical response-order notice is **pre-existing**, not introduced by
sub-agents: `v0.1.125:apps/macos/PiApp/Transcript/TaskTranscriptPlan.swift:183`
already displays it for ordinary canonical tool timelines. It remains unchanged.

The new opening tests use the packaged helper, MemoryVault and
`fixtures/native/ui-gateway.py`, with an explicit child-stream barrier in the
test's temporary directory. No real credentials, data or provider traffic.

Findings:

| Review item | Disposition |
| --- | --- |
| Card money | Fixed: uses `compactGatewayUSD`, the existing footer/Inspector formatter. Regression checks `$0.04` across the card, footer, Inspector group and sidebar. |
| Duplicate card status | Fixed: status remains in the header; the body begins with the model and keeps the other progress lines. |
| Open child missing from sidebar | Fixed: the selected child transiently reveals its group and is highlighted in both Topics and Flat. The saved fold is unchanged. |
| Canonical response-order notice | No change: pre-existing ordinary tool-timeline behavior, confirmed in `v0.1.125`. |
| Child capture-mode write | Fixed: managed opening reads the inherited mode from `session.open` and sends no `debug.mode`. The helper's policy guard remains intact. |
| Parent topic move | Fixed: only independently chosen roots enter the transaction; it traverses managed descendants. Direct child moves still fail. |
| Cancelled delegation preflight | Fixed: every issued call gets a not-executed result before cancellation escapes. Parent Resume works immediately without replay. |
| Sidebar live navigation | Fixed: a valid managed selection uses `openSubagent`, including its header validation and runtime attachment. |
| Terminal runtime retention | Fixed: settlement evicts unseen children from both host registries. Explicit readers stay pinned; close, forget and eviction serialize with open and check runtime identity. Stop cleanup runs in an awaited uncancelled task. |
| Inspector parent link | Fixed: an excluded target widens to Family through the normal filter setter, including usage scope and out-of-window request lookup. |

Regression evidence:

- Merged-tree native baseline: **22 passed** (`review2-baseline-native.log`).
- UI failing-first run: **25 executed, 13 failures**, covering the four changed
  UI behaviors (`review2-ui-red.log`); the restored set passed all **25**.
- Real-helper opening failing-first run: all **3 cases failed** for the reported
  capture write, stale sidebar snapshot and retained terminal runtime
  (`review2-opening-red4.log`). Earlier fixture setup/build failures are not
  counted as behavioral evidence.
- Preflight guard restored to its old behavior: missing result rows and
  `nothing_to_continue` (**3 failures**, `review2-mutation-preflight.log`).
- The Stop cleanup regression first failed its cancellation assertion
  (`review2-cleanup-cancellation-red.log`); the real four-child wire fixture
  independently caught retained stopped children (`review2-streaming-stop-red.log`).
- **12 guard mutations killed**: card money, duplicate status, selection reveal,
  topic roots, Inspector filter, Inspector usage, child capture write, sidebar
  live opening, preflight settlement, terminal eviction, viewer pin, and
  uncancelled cleanup. See `review2-native-mutations.json`,
  `review2-helper-mutations.json`, and `review2-mutation-preflight.log`.
  Runtime mutations use a generated helper copy outside the repository.
- Final helper selection: **90 passed** (`review2-helper-restored.log`), including
  `SessionSettlementTests` **2**, `CostLimitTests` **11**, `CaptureDrainTests` **4**,
  `HostServiceTests` **6**, and `SubagentCoordinatorTests` **20**.
- Affected native parallel classes: **101 passed** (`review2-affected-native.log`),
  run through `scripts/test-macos.sh` using a bash array after lane inspection.
- Native serial classes, each alone: `SubagentNavigationTests` **5**,
  `SubagentOpeningTests` **3**, `TopicOrganizationTests` **14**,
  `CaptureDrainTests` **6**, and `HostSupervisorTests` **7**: **35 passed**.
- One earlier opening run reported a transient discovery/metadata warning.
  Retained an assertion with generated-path diagnostics; **75 repeated cases**
  then passed (`review2-opening-repeat.log`, `review2-opening-stability.log`),
  as did the final serial run. Its cause was not established; no speculative
  weakening of identity/path validation was made.
- Real gateway streams: **4 scenarios passed**, each with four concurrent
  children: complete, open viewer, Stop and shutdown (`review2-streaming-final.log`).
  Unseen completed/stopped runtimes are absent; reopened journals retain local
  costs; an open viewer survives settlement; parent costs and captured bytes
  remain complete and unduplicated.
- Crash/relaunch: **21 barriers passed** against the final helper, including
  Stop, shutdown, update, terminal persistence and external-effect boundaries
  (`review2-crashes.log`). Resume sent only the parent continuation.
- Gallery: regenerated all **92 §13.5 scenes**, both appearances and sizes, in
  `review2-gallery/subagents/` (`review2-gallery-final.log`). Visually checked
  the expanded running card and child viewer: `$0.04`, no repeated body status,
  expanded child group and highlighted child. The first gallery invocation
  skipped because Xcode needed `TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT`; the
  final invocation supplies it and runs the test.
- The first full native parallel lane finished **2,299 passed, 1 failed,
  35 skipped**. `TranscriptFocusTests` compares window-server pixels across
  keyboard focus changes and had been classified as parallel. Its changed-pixel
  assertion failed with other test hosts active. Added the explicit serial-lane
  marker; both tests pass alone (`review2-serial-TranscriptFocusTests.log`).
  No production rendering code changed for this test-lane correction.
- The next full lane finished **2,297 passed, 1 failed, 35 skipped**: the existing
  `FileSyntaxTests.testLinesAskedTogetherShareOnePass` read 4,807 bytes against
  a 4,766-byte bound. Concurrent request batching makes that count depend on
  scheduling, which the test handoff assigns to the serial lane. Marked the
  class serial without relaxing its assertions; **55 cases passed** over five
  repetitions (`review2-serial-FileSyntaxTests.log`). No syntax-reader production
  code changed. Both classification corrections are independent of sub-agents.
- Final full native parallel lane, eight workers: **2,287 passed, 35 opt-in
  skips, 0 failures** (`review2-full-parallel-restored.log` and
  `review2-full-parallel-restored.xcresult`). The serial classes above ran alone;
  the final lane uses `scripts/test-lanes.py parallel` without hand-picked skips.

## Review fixes after phases 1–6

Started from `ea952f1e` (merged `dev/next`); `git pull --ff-only origin dev/subagents`
was already up to date. No changes to `dev/next` or `main`.

- Baseline: `SessionSettlementTests|CostLimitTests|CaptureDrainTests|HostServiceTests`:
  **23 passed** (`subagents-review-baseline.log`).
- Failing-first: new ordinary-accounting, queued-child pin, runtime replacement,
  durable-side, copy-fork and throwing-MCP regressions: **10 assertion failures**
  across 28 tests (`subagents-review-red.log`). An earlier compile error was fixed
  before recording that behavioral red run.
- Focused implementation run: **104 passed** (`subagents-review-green.log`).
- Eight guard mutations killed: eager ordinary-chat activation, missing seed
  reset, ignored child Stop generation, idle child unpinning, cross-runtime
  cancellation, retained consumed jobs, retained throwing MCP token, copied
  fork admissions/corrections (`subagents-review-mutation-*.log`). The first
  runtime mutation exposed an assertion that observed too early; the regression
  now checks the replacement child's durable completed result and kills it.
- Owner-key consistency is structural: the current depth-one identity contract
  requires owner == parent, so an unequal-owner runtime fixture is invalid.

The ordinary physical-attempt replay test now calls the durable accounting entry
point explicitly. Ordinary chats intentionally keep the pre-feature bounded
in-memory guard and best-effort cost writes; family attempts retain durable dedup.

- Restored broader run: **126 passed, 1 skipped**, 127 executed
  (`subagents-review-restored.log`), including the four requested classes.
  The skip is the opt-in shared-fork-fixture writer. The committed version-1
  checkpoint fixture remains unchanged; its test now verifies intentional
  fallback and compares the rebuilt checkpoint without the new derived indexes.
- Native smoke checks (`SubagentMetadataTests`, `SubagentModelGrantTests`,
  `WireContractTests`, all parallel lane) ran with a bash array after rebuilding
  the merged app.

- Native review smoke result: **13 passed, 1 skipped**, 14 executed
  (`subagents-review-native.log`). The skip is the opt-in per-token performance
  fixture. All three classes ran using a bash array after lane inspection.

## Phase 7 — Stop and recovery

- Failing-first recovery suite: **19 failures** across 6 tests, including the
  expected JSON-envelope parse failure on the old generic interrupted text
  (`phase7-red.log`). Marker-only child creation then failed independently
  (`phase7-creation-red.log`); restored-child reader unload failed as busy before
  distinguishing it from a coordinator-owned job (`phase7-child-viewer-red.log`).
- Restored helper run: **153 passed**, no skips (`phase7-restored.log`). Includes
  sub-agent suites, SessionSettlementTests, CostLimitTests, CaptureDrainTests,
  HostServiceTests, ContinueRunTests, parallel tools, tool outcome/persistence,
  MCP retention, checkpoint/slimming, retries, capture, compaction shapes and
  host dispatch.
- `scripts/test-subagent-crashes.py`: **21 passed** (18 crash barriers and
  Stop/shutdown/update), `phase7-crashes-final.log`. Each crash reopen sent no
  requests; Resume sent exactly one parent request; child request counts and
  external-effect bytes did not increase. Completed terminal results were
  adopted exactly once. Control cases had 16 active slots plus 2 queued, with
  6 child HTTP requests overlapping under the existing transport connection
  pool; all 18 child outcomes settled before journals closed.
- Seven unit guard mutations killed: exact terminal adoption, reciprocal
  origin, result identity, registered cost evidence, unknown cost, immediate
  queued cancellation, terminal synchronization (`phase7-mutation-*.log`).
- Real-helper shutdown mutation killed: omitting coordinator drain produced
  failed child outcomes from closed journals (`phase7-mutation-shutdown.log`).
  The generated fixture delays terminal persistence and fixes the valid
  dictionary traversal order to child-first to make that race deterministic.
  The restored generated helper then passed all 21 cases.
- Native lifecycle validation runs `LifecycleHelperTests` in its serial lane
  alone, then `RunHoldTests` and `SubagentMetadataTests` as a bash array.

The journal marker remains v1 for parents and v2 only for children. Recovery is
available independently of the disabled rollout switch. No production capture
policy, installed app, or real preferences/vault data were changed.

- Native phase 7 results: `LifecycleHelperTests` **10 passed**, serial lane
  alone (`phase7-native-serial.log`); `RunHoldTests|SubagentMetadataTests`
  **18 passed** using a bash array (`phase7-native-parallel.log`).
- Final record-validation review: mismatched terminal/metadata status and
  nonexistent result references failed first (2 assertions,
  `phase7-result-validation-red.log`). Both individual mutations were killed.
  The affected helper run passed **50 tests** (`phase7-final-guards.log`),
  and the three completed-result crash barriers passed again
  (`phase7-final-terminal-crashes.log`). The final restored recovery suite
  is recorded in `phase7-recovery-restored.log`.

## Phase 8 — capture lineage

- Failing-first: the three new archive regressions and hidden-parent update
  produced 12 assertion failures (`phase8-red.log`); inherited policy produced
  two helper failures (`phase8-helper-red.log`).
- Restored native suite: **83 passed**: `SubagentCaptureTests`,
  `LiveAccountingTests`, `GatewayAccountingTests`, `PayloadArchiveTests`,
  `CaptureMacIntegrationTests`, `SessionReferenceTests`. All are parallel-lane
  classes, run via a bash array and `scripts/test-macos.sh` (`phase8-restored.log`).
- Restored helper suite: **54 passed**: `SubagentCoordinatorTests`,
  `SubagentRecoveryTests`, `CaptureTraceTests`, `CaptureDrainTests`,
  `CredentialCaptureTests`, `HostServiceTests` (`phase8-helper-restored.log`).
- Eight guards mutated and caught: live inherited mode, independent child mode,
  physical capture identity, immutable lineage, workspace isolation, hidden-parent
  invalidation, parent aggregation, and all-session rollup. The six native
  mutations ran in two batches; distinct assertions caught each guard. Logs:
  `phase8-mutation-{inherited-mode,child-mode-guard,identity-routing,family-rollup}.log`.
  An unused-variable compile rejection in the first mutation harness was repaired
  before recording the behavioral failures.
- Existing tests caught two implementation regressions: invalid capture modes
  must be rejected before a session is opened, and an ordinary capture must not
  incur an extra SQL projection for null lineage. Both are fixed; the original
  guards and archive performance assertions pass unchanged.
- Schema 6 retains raw metadata and physical session/body ownership, and adds
  nullable indexed lineage. Parent totals roll up child attempts; global totals
  remain physical. No capture quota, retention, byte or event limits changed.
- The single production switch remains false.

## Phase 9 — family Inspector

- Failing-first: **six assertion failures** for family listings, cross-child
  comparison, body routing and explicit out-of-window navigation
  (`phase9-red.log`).
- Restored native suite: **40 passed**: `SubagentInspectorTests`,
  `InspectorIndexTests`, `InspectorRequestModelTests`,
  `InspectorSummaryRequestTests`, `SubagentCaptureTests`,
  `InspectorFollowTests`, `InspectorEntryPointTests`, all parallel-lane classes
  via a bash array and `scripts/test-macos.sh` (`phase9-restored.log`).
- Helper: **23 passed**, `SubagentCoordinatorTests|HostServiceTests`
  (`phase9-helper-restored.log`). A dedicated revision changes for task status
  while unrelated token events leave it unchanged.
- Twelve guards mutated and caught: discovery revision; physical comparison
  baseline and body route; direct-request family and workspace scope; immutable
  group identity and terminal state; family listing and explicit older lookup;
  predecessor validation, selected-child membership and group workspace scope.
  Native guards ran in three batches, with distinct assertions for each. Logs:
  `phase9-mutation-{discovery-revision,identity-routing,family-links,selection-guards}.log`.
- A 5,001-request fixture opens an older linked request and then reads a child
  omitted from the family window through its own filter. Caching request-kind
  labels reduced the complete fixture/UI check from 10.5 s to 0.79 s locally.
  This is fixture evidence, not a release-wide performance claim.
- Queued/no-request groups survive archive reopen, foreign workspace and family
  lookups are refused, and late updates cannot revive terminal groups. Existing
  capture limits/settings and the Inspector's window size are unchanged.
- Serial `InspectorFrameTests` ran alone: **2 passed** (`phase9-inspector-frame.log`), including 301 requests, a 5 MB request body and idle/scroll/navigation measurements.
- Production remains hidden. Gallery coverage is completed in phase 12.

## Phase 10 — parent card and child transcript

- Failing-first logs: `phase10-red.log` (projection/card/child actions),
  `phase10-helper-red.log` (live progress and durable card),
  `phase10-navigation-red.log` (child composer/continuation/breadcrumb),
  `phase10-progress-discovery-red.log`, `phase10-child-status-red.log`,
  `phase10-exact-card-red.log`, `phase10-child-cost-red.log`, and
  `phase10-version-target-red.log`. Compile-only failures were repaired before
  recording behavioral failures. The independent child cost test seeds durable
  metadata so a missing store row cannot accidentally satisfy its refusal check.
- Guard mutations caught offline and fast metadata loss, a dropped action relay,
  copied-card Stop authority, child draft writes and independent cost changes,
  foreign project/owner/ordinary-journal discovery, child fork, focus/window/
  sheet/picker routing, reusing the wrong old-version page, progress coalescing,
  discovery revision isolation, terminal viewer notification and targeted helper
  version paging. Logs: `phase10-mutation-*.log`.
- Exact-card scrolling was checked separately from keyboard mutations, with the
  viewport first scrolled to the top. Omitting the card focus then fails the
  visibility assertion (`phase10-mutation-exact-card-isolated.log`). Merely
  changing the focus representation did not fail the earlier fixture; that is
  not counted as a killed mutation.
- The keyboard fixture uses actual AppKit responders in a generated test window:
  file text, Git table, terminal emulator without a PTY, Inspector, sheet, picker,
  conversation and a missing parent. No installed app or real user state.
- The helper's existing version-page protocol gained an optional, version-scoped
  `around` message identity. Back to Parent can open a card past the first
  byte-bounded page without loading the whole earlier version. Ordinary version
  paging, live context, drafts and other manual folds retain their behavior.
- Final restored helper suite: **65 passed**, including the four lead-requested
  classes (`phase10-helper-restored-final.log`).
- Native final: `SubagentNavigationTests` **5 passed** and
  `TranscriptWirePageTests` **4 passed**, each serial class alone. Parallel-lane
  bash-array run **69 passed** across SubagentTranscriptTests,
  TranscriptActionsForwardingTests, TranscriptRevealTests,
  NativeWorkListViewportTests, SubagentInspectorTests,
  MessageVersionTranscriptTests, TranscriptNativeWorkBehaviourTests and
  CostLimitTests. Logs: `phase10-native-{navigation,wire,parallel}-final.log`.
- `git diff --check` passes. The sole rollout constant remains false. No owner
  decisions changed; sidebar/discovery/family organization and final gallery/
  release validation remain phases 11–12.

## Phase 11 — sidebar, discovery and organization

- Failing-first checks covered folded grouping, silent children, family archive,
  shared run holds, unregistered child discovery/deletion, full-task search and
  deletion restart. Logs: `phase11-organization-red.log`,
  `phase11-discovery-red.log`, `phase11-deletion-red.log`,
  `phase11-family-hold-red.log`, `phase11-task-search-red.log`.
- Expanded-group persistence initially failed (five assertions); the sidebar
  preference writer now compares the new disclosure field. A restart fixture
  now explicitly closes its first capture archive before reopening it.
- Later boundary checks failed first for a delegation accepted while the delete
  sheet was open, a foreign terminal record and stale quarantine parentage
  (`phase11-recovery-boundaries-red.log`). Existing launch-selection checks also
  caught URL directory-hint equality rejecting deletion of an empty chat; the
  containment guard now compares canonical paths.
- Seventeen guard mutations caught: collapsed group, persisted expansion,
  completion sound, draft mark, webhook, title job, unread observation, family
  archive expansion, independent child organization, family run-hold counts,
  independent child hold, terminal identity, reciprocal origin, full queued-task
  search, metadata tombstone, capture tombstone and durable deletion intents.
  Logs: `phase11-mutation-*.log`. An unused-variable compiler rejection in the
  archive mutation was repaired before recording its behavioral failure.
- Final parallel-lane bash-array run: **144 passed**, no skips
  (`phase11-native-restored-final.log`). Classes: CompletionSoundTests,
  SessionOrganizationTests, SessionReadStateTests, SidebarFlatTopicsTests,
  SubagentDeletionTests, SubagentDiscoveryTests, SubagentMetadataTests,
  SubagentOrganizationTests, TopicSessionDragTests, TopicStorageTests,
  SidebarSearchIndexTests, RunHoldTests, LaunchSelectionTests,
  SubagentTranscriptTests.
- Serial classes each ran alone: TopicOrganizationTests **14 passed**,
  SubagentNavigationTests **5 passed**, CaptureDrainTests **6 passed**
  (`phase11-serial-<Class>.log`).
- Helper: **51 passed** (`phase11-helper-restored.log`), covering coordinator,
  recovery and all four lead-requested classes.
- Fixtures include 520 managed children, a queued task beyond the metadata
  preview, copied-parent provenance, a foreign symlink, archive restore,
  unregistered children, interrupted deletion across a fresh model/archive,
  late callbacks and workspace-scoped capture cleanup. Production remains off.

## Phase 12 — enabled feature, compatibility and gallery

- The final compatibility review found and fixed four presentation edges:
  generic cut-off results displayed as queued; an older helper's already-saved
  result lacked a local child navigation target; a missing child journal blocked
  later healthy siblings from app registration; and an unsaved side split an
  expanded sub-agent group. Model-visible older results remain unchanged.
- Failing-first logs: `phase12-compatibility-helper-red.log` and
  `phase12-compatibility-native-red.log`. The restored focused runs pass **10
  helper** and **21 native** tests. The four corresponding mutations each
  produced behavioral failures (`phase12-mutation-compatibility-and-groups.log`,
  `phase12-mutation-old-helper-navigation.log`). Missing-file failure is an
  unexpected thrown error; the other three guards fail explicit assertions.
- Enablement failed first with the switch off (two assertions), then **55 helper
  tests passed** with it on, including SessionSettlementTests, CostLimitTests,
  CaptureDrainTests and HostServiceTests (`phase12-enable-{red,green}.log`).
  Turning the switch off again fails both availability assertions
  (`phase12-enable-mutation.log`); the enabled source was restored afterward.
- `SubagentGalleryTests.swift` extends UIScreenshotTests with every §13.5 scene:
  21 main-window states and family/child-filter Inspector states, in light/dark
  at 920×600 and 1240×800 (**92 images**). It uses actual native Pi views,
  generated metadata, memory credentials and local synthetic capture records.
  Card presence, child composer suppression, Back focus and filter scope are
  asserted. The gallery fixture and images remain under the build root; search
  closes asynchronously, so fixture directories are not unlinked while its
  SQLite connections are closing.
- Gallery fixture corrections: canonical tool timelines and exact-card reveal
  replaced legacy folded work rows; activating its window made keyboard focus
  meaningful; child capture metadata now has matching turn lineage and seconds
  timestamps. The failed logs are retained, including a cancellation during the
  first expanded capture fixture. The corrected 92-image run passed
  (`phase12-gallery-capture.log`); the final gate regenerated the gallery after
  the switch was enabled.
- Native measurement: 20 updates of four cards among 400 settled history rows
  measured **52 rows / 16 Markdown blocks**, with **zero sidebar recomputations**.
  The fixture's recorded p50/maximum update intervals were **63.34/118.08 ms**
  (the earlier log mislabeled that 20-sample maximum as p95);
  these include scheduled waits and drawing, not physical display frame cadence.
  Cached child/parent switching plus two fixture settles took **1,213 ms** and
  restored the issuing card. This is a native fixture measurement, not a disk
  load or production-latency bound (`phase12-native-performance-final.log`).
  The final gate repeated this class alone through `scripts/test-macos.sh`.
- `scripts/test-subagent-streaming.py` runs four concurrent real child streams
  through a loopback gateway. It verifies six physical attempts on completion,
  complete response-byte capture for all four children, immutable lineage,
  durable parent results, unchanged discovery revision during token progress,
  and Stop/shutdown settlement. The generated enabled helper fixture passed
  all three scenarios: peak concurrency four, Stop **31.59 ms**, graceful
  shutdown **20.86 ms** (`phase12-streaming-fixture.log`). The final gate reran
  it against the actual enabled bundled helper; results are below.
- The broader gate runs in this worktree and the required build root.
  `check-next.sh` would choose `dev/next` and another root; `verify-release.sh`
  also batches serial classes and expects a committed generated project. Their
  underlying checks are instead run with each serial class alone, native
  parallel tests in eight clones, isolated helper cost measurements, remaining
  helper/views/wire/script tests and the full screenshot gallery. Native test
  hosts use `com.belloware.SubagentValidation.$(PRODUCT_MODULE_NAME)` so standard
  defaults do not read or write the real app's domain. Logs are in
  `logs/phase12-gate/`; completed gate results are below.
- The combined review also reproduced a large-family storage defect: the
  generic 10,000-row listing hid the parent among 10,001 children and omitted
  two deletion intents (five failing assertions in
  `phase12-large-family-red.log`). Managed rows now sit outside the unchanged
  ordinary-chat window, and recovery reads the complete strict deletion
  manifest. Four mutations catch reintroducing either family limit, removing
  the ordinary-chat window, or silently skipping a damaged intent
  (`phase12-mutation-{child-window,deletion-window,ordinary-window,damaged-intent}.log`).
- The storage checks exposed an existing reflection-based round-trip fixture
  which did not populate the three new optional managed fields. The fixture now
  supplies them; all existing round-trip assertions are retained. The corrected
  six-class run passed **44 tests** (`phase12-large-family-final.log`).
- Gate isolation correction: while stopping the broad runner for this review
  fix, its in-flight InspectorNativeParityTests overlapped the next test build.
  Its test methods passed but the result bundle reported an import error. That
  invocation is excluded as validation. Isolated replacement runs passed:
  InspectorNativeParityTests **7**, ChatLoadStabilityTests **1**, and
  ChatOpenPlacementTests **5** (`phase12-post-review-<Class>.log`), before the
  broad runner continued. Pausing the runner inflated its recorded wall times;
  those times are not performance measurements.
- Re-upgrade metadata regression: saving a child through an older desktop shape
  erased its managed identity, and discovery refused to reconstruct it (three
  failing assertions in `phase12-desktop-downgrade-red.log`). The validated
  reciprocal journals now restore an absent identity while preserving the old
  title. Different paths/workspaces and conflicting identities remain refused.
  The expanded six-class run passed **45 tests**
  (`phase12-desktop-downgrade-green.log`).
- Three desktop identity mutations each fail behaviorally: refusing a legacy
  record with absent identity, omitting reconstruction, and allowing a
  conflicting identity (`phase12-mutation-{legacy-identity,identity-rebuild,identity-conflict}.log`).
- The first full native parallel run executed **2,310 tests**: **2,272 passed,
  35 skipped, 3 failed**. The strict loopback gateway still required the old tool
  list; it now requires `subagent` too, retaining exact-set validation. The
  native fork fixture now asserts deliberate full replay when its unchanged v1
  derived checkpoint is rejected, retaining all row/version comparisons.
- The third failure reproduced alone in ContextReadingTests: a saved **44-token**
  reading became a **19-token** estimate after reopening. The idle sub-agent
  schema incorrectly used the previous turn's (initially empty) model grants.
  Idle previews now use current picker grants; active turns keep frozen grants.
  Preview-only picker selections are validated without changing execution
  grants or journal bytes, and idle grant changes expire old previews.
- Failing-first helper regressions recorded **six assertion failures** across
  `phase12-grant-preview-red.log` and `phase12-grant-selection-red.log` (an initial
  async-autoclosure compile error was corrected before the behavioral run).
  The focused eight-class helper run then passed **71 tests**
  (`phase12-grant-preview-green.log`), including all four lead-requested classes.
- Six preview/grant mutations failed behaviorally: stale idle grants, widened
  active grants, ignored preview selection, preview granting execution access,
  missing selection validation and stale preview retention. The restored helper
  run passed **71 tests** (`phase12-grant-preview-restored.log`). The six affected
  native classes passed **23 tests** (`phase12-native-failures-restored.log`),
  then the complete parallel lane passed **2,275 tests, 35 skipped, zero failed**
  (`phase12-native-parallel-restored.log`).
- Gallery review found a long running/queued label pushing the centered Pi
  button's chevron outside a narrow sidebar. The group now chooses a fitting
  count label, with complete counts in its tooltip and accessibility label.
  The regression failed first with **14 assertions**
  (`phase12-sidebar-fit-red.log`). Its nine-test green run reported an Xcode
  result-bundle import error despite passing assertions; that invocation is
  excluded from final validation and repeated with a dedicated scratch temporary
  directory and explicit result bundle.
- The sidebar mutation then produced **12 assertion failures** (after correcting
  an unused-variable compile rejection in the mutation). The restored class
  passed **9 tests** with a readable result bundle
  (`phase12-sidebar-fit-final.log`, `phase12-sidebar-fit-final-summary.json`).
  This brought phase 12 to **19 behavioral guard mutations**, before the final
  Inspector overview correction recorded below.
- Final native performance repetition, alone: **1 passed** with a readable
  result bundle. Across 20 four-card updates: **52 measured rows, 16 Markdown
  measurements, zero sidebar computations**; fixture p50/maximum intervals
  **62.93/120.97 ms**, cached switch/reveal plus fixture settles **1,369 ms**.
  The same fixture-only limits above apply
  (`phase12-native-performance-current.log`,
  `phase12-native-performance-current-summary.json`).

### Completed broad validation

The original broad runner retains its nonzero result: it found three native
failures and one helper fixture failure. The fixes and valid reruns are recorded
above and below; the original logs have not been overwritten or counted as clean.

| Check | Final result | Evidence under the build root |
|---|---|---|
| Native parallel lane, eight test hosts | 2,275 passed, 35 opt-in skips, zero failures | `logs/phase12-native-parallel-restored.log` |
| Native serial lane, each class alone, including the separate sub-agent performance class | 100 classes; 682 passed, 33 opt-in skips, zero failures | `logs/phase12-gate/serial-*.log`, isolated replacements described above, `logs/phase12-native-performance-current.log` |
| Helper cost measurement class, alone | 5 passed | `logs/phase12-gate/helper-cost.log` |
| Remaining helper suite | 748 executed: 741 passed, 6 skipped, one stale expected-tool-list failure; corrected class then 5/5 passed | `logs/phase12-gate/helper.log`, `logs/phase12-side-cache-final.log` |
| Swift views | 188 passed, 3 skipped | `logs/phase12-gate/views.log` |
| Wire / concurrent / acceptance loopback suites | 34 / 4 / 3 passed | `logs/phase12-gate/{wire,concurrent,acceptance}.log` |
| Script unit tests | 72 passed | `logs/phase12-gate/python.log` |
| Full UI gallery | Both methods passed; 311 PNGs, including 92 sub-agent scenes | `logs/phase12-gate/gallery.log`, `phase12-gallery/` |
| Real-helper crash and control matrix | All 21 scenarios passed | `logs/phase12-crashes-final.log` |
| Actual v0.1.125 helper downgrade | All 5 compatibility assertions passed | `logs/phase12-downgrade-final.log` |

The full helper suite's sole failure was `SideCacheTests` expecting eight tools
from a production HostService session. It now expects the enabled ninth tool;
the other direct-session fixtures still require eight. No helper implementation
changed after that suite. All four lead-requested baseline classes also passed
in the final 71-test focused helper run.

The enabled release helper passed all three four-child streaming scenarios
(`logs/phase12-gate/subagent-streaming.log`, `logs/subagent-streaming.json`):
completion produced six unique physical attempts, exact $0.06 family spend,
$0.01 per child, and complete byte-for-byte response captures. Peak simultaneous
child streams was four. Stop settled in **32.96 ms** and graceful shutdown in
**10.88 ms** in this local loopback fixture; these are not provider or production
latency guarantees.

The crash matrix used generated fault-injected helper copies at 18 persistence
barriers, followed by the actual helper for reopening. Resume issued exactly
one parent request, with no child replay or repeated external-effect bytes.
Stop, shutdown and update scenarios settled 16 active plus 2 queued children
before journals closed. Downgrade accepted the v1 parent, preserved its existing
cut-off result without replay, refused the v2 child, left its bytes unchanged,
and enforced the marker-type gate.

Final visual review covered representative small/light and dark scenes: queued
parallel cards, child transcript/navigation, cost limit, Topics/search, long
labels/reduced motion, and family/child Inspector. It caught the family overview
query inconsistency below. Automated coverage renders every §13.5 scene at both
sizes and appearances; this is not a claim of manual inspection of all 311 PNGs.

### Final Inspector overview correction

The final gallery showed three family requests in the navigator but one in the
overview/model summary. Two failing-first regressions produced **14 assertion
failures** (`logs/phase12-inspector-usage-red.log`). The additive scope argument
was initially present but inert so the recorded red run exercised behavior,
rather than failing to compile.

Overview usage and its model-page cache now carry the family filter. Family
queries include owner and child physical attempts within the same workspace;
parent-only and child-only pages exclude the parent's rolled-up live footer and
budget-spend figure. An empty loaded footer uses captured family totals. The
snapshot subscription consumes the published value directly, avoiding Combine's
will-set delivery reading the old snapshot. Global/project aggregates and capture
policy are unchanged.

The expanded six-class baseline passed **74 tests**. Eight mutations each failed
behaviorally: omitting children, mixing cached scopes, losing workspace
isolation, routing a child filter to the parent, using the family footer in a
physical view, reading the old published snapshot, starting with a parent-only
scope, and overriding a child's cost with parent budget spend
(`logs/phase12-mutation-family-usage-*.log`). Phase 12 has **27 behavioral guard
mutations** in total, with every mutated source restored before final testing.

With all guards restored, the same six classes passed **74 tests**, with a
readable result bundle (`logs/phase12-inspector-usage-restored.log` and
`logs/phase12-inspector-usage-restored-summary.json`).
`InspectorFrameTests` then passed **2 tests** alone, followed by
`InspectorOverviewDocumentGeometryTests` **1 test** alone. The final contained
query/display correction did not change helper or capture ingestion code; its
focused suites and gallery were rerun after the broad gate rather than claiming
that the earlier full gate tested these final lines.

The final sub-agent-only gallery repetition passed **1 test**, regenerated all
**92 images**, and asserted matching family/child overview request totals
(`logs/phase12-subagent-gallery-final.log` and its `-summary.json`). The corrected
family screenshot now shows **3 requests** in both navigator and overview;
the child filter shows **1**. The small/light family Inspector, small/dark child
Inspector, wide long-label child viewer and dark recovery-error view were
visually rechecked after this run. All §13.5 scenes remain in the gallery.

No owner decision changed and no implementation questions remain open. The
feature is enabled on `dev/subagents` for lead review and the 0.1.126 integration;
release signing, notarization, publication and merging into `dev/next` are not
performed by this worktree task.
