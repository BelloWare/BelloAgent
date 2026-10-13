# Sub-agents continuation validation — 0.1.126

Worktree `wt-subagents`, branch `dev/subagents`. Build/test artifacts use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents`.
Only generated fixtures and loopback gateways; no installed app, real vault,
preferences, Keychain or paid providers. The production switch remains off.

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
  `WireContractTests`, all parallel lane) were started with a bash array; their
  result will be recorded below when the merged app finishes rebuilding.

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
