# Sub-agents continuation validation — 0.1.126

Worktree `wt-subagents`, branch `dev/subagents`. Build/test artifacts use
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents`.
Generated fixtures and loopback gateways; no installed app, real vault,
Keychain or paid providers. Round 7 uses the isolated test host described below;
the owner's finding that the older host wrote real preferences supersedes the
previous rounds' preference-isolation claims. The production switch stayed off
through phase 11 and is enabled in phase 12. This worktree has not been merged
into `dev/next` or published as a release.

## Round-7 review — 2026-10-14

The **first operation, before any tests**, fetched origin and merged
`origin/dev/next` with `--no-ff`: merge commit `34e695a8`. The merge keeps both
SCROLL-14 `read-cancel` and sub-agent capabilities. `project.pbxproj` took ours
then was regenerated with XcodeGen; `project.yml` retains `PiAppTestHost` and
the shared sub-agent sources. No pre-merge test products were launched.
Implementation commits: `2a2ca3e3` (once-per-connection host loss) and `93408f1d`
(capture accounting, recovery and family cleanup). The tests below cover that
final code/test tree; the validation-record commit changes documentation only.

Every native run rebuilt through `scripts/test-macos.sh`, using
`com.belloware.PiAppTests.Host`, its scratch home, private pasteboards, pre-test
guard, and disabled Keychain/Sparkle integration. No bundle-ID override or
named result bundle was used. The script prunes old automatic result bundles;
text logs under `logs/review7-*` are the evidence.

| Finding | Disposition and reason |
| --- | --- |
| Captured charges cannot repair the parent budget | **Fixed.** `budget.attempts` pages registered unresolved dispatch IDs. Cold parent opening reads retained terminal evidence for those IDs in the same workspace/owner and awaits `budget.reconcile`. Exact saved `RequestScope` and physical identity are validated; `cost-update.v1` is flushed to the owner before the child mirror. Repeated evidence is idempotent, unknown pricing remains unknown, and the repaired total stops the next request at the cost limit. A failed mirror retains the owner charge, blocks admission and is repaired on reopen. |
| Missing executed child does not block recovery | **Fixed.** A dispatched admission or completed owner outcome requires its child journal, including an already-paired call. Missing evidence raises `subagent_recovery`; saved parent history remains inspectable. An admission that never dispatched may still recover as not executed. |
| Family deletion leaves retained tool output | **Fixed for newly written output.** The session supplies ownership before execution: short/failed/crash-left shell logs and oversized tool results use `Sessions/tool-output/<physical-session-id>/`. Durable family cleanup recycles only its members' directories. Traversal and symlink aliases are rejected; other chats' directories remain. Older flat UUID files without ownership evidence cannot safely be attributed, so they are preserved. No released sub-agent data uses the old layout. |
| Listing failures are treated as successful deletion | **Fixed.** Only an absent directory is tolerated. I/O/access errors preserve metadata and deletion intents for retry. Tests cover both ENOTDIR and a directory with search permission but no listing permission. |
| Crash-left checkpoint files escape deletion | **Fixed.** Exact `.<journal>.meta.<UUID>` temporaries are removed under the existing journal writer lock and included in family deletion. A failed competing open cannot remove them; malformed/unrelated names survive. |
| MCP discovery leaks retention entries | **Fixed.** Only `invoke` allocates a retention mapping. `list`/`describe` remain scoped but leave no mappings; throwing invocations retain the existing unknown-outcome semantics. |

No review finding was rejected. The output-ownership compatibility limitation
is recorded in the design's Implementation notes; no ownership is guessed for
legacy flat files. Parent journal markers, capture policy/retention, grants,
active limits, depth and the production switch are unchanged. Steering and
background/follow-up APIs are intentionally deferred to the separate design.
No editing lock or capture cap was added.

Merge verification also pins family/child/Inspector output-speed totals to the
common TTFT-inclusive physical-attempt calculation. Cards do not calculate a
separate rate. Existing containing-version and around-message navigation keep
the cancellable helper pager; `MessageVersionTests`,
`HistoryReadCancellationTests`, `MessageVersionTranscriptTests`, and real-helper
opening/navigation tests pass.

Validation found one additional host lifecycle bug: transport failure and the
later process-exit event notified the workspace twice. `HostSupervisor` now
notifies once per connection and resets the guard on reconnect. This prevents
family interruption/update handling from running twice. The killed-helper test
accepts either existing transport error wording while still requiring an
explicit no-replay notice.

Failing-first evidence:

- `review7-recovery-cleanup-red.log`: missing executed child, locked checkpoint
  cleanup, and MCP discovery retention regressions fail before their fixes.
- `review7-deletion-red.log`: failed directory enumeration loses the intent and
  checkpoint temporaries survive; `review7-output-deletion-red.log` also proves
  owned outputs were left behind.
- `review7-capture-output-red.log`: short shell/oversized output ownership fails;
  its initial cost fixture had the wrong limit shape, corrected before the
  meaningful `review7-capture-red.log` run (unsupported reconciliation and the
  unrepaired $0.90 total).
- `review7-host-loss-red.log`: deterministic transport-failure/exit notifications
  count 2 then 4 instead of 1 then 2 across two connections.

**12 guard mutations killed by behavioral assertions:** owner charge, child
mirror, missing executed journal, shell-output ownership, checkpoint cleanup,
MCP discovery retention, deletion of owned output, listing-error propagation,
deletion of checkpoint temporaries, app cold-open reconciliation, host loss
notification, and reconnect reset. `review7-mutations.py` restores each source;
`logs/review7-mutations.jsonl` records attempts. Compile-only/fixture/runner
failures are not counted. The cold-open fixture now waits for durable capture
before killing its helper. The serial runner was corrected to recognize its
own launchd-parented test host; earlier automatic retries from that runner are
not additional independent evidence.

Restored-source validation:

| Validation | Result | Text evidence under the build root |
| --- | --- | --- |
| Full native parallel lane, 293 classes | **2,307 passed, 35 skipped, 0 failures** (2,342 total) | `logs/review7-native-parallel-restored-final.log`, `logs/review7-native-parallel-restored-summary.json` |
| Helper sub-agent/storage/permission and baseline classes | **129 passed, 1 optional performance test skipped**; 0 failures | `logs/review7-helper-final.log` |
| Actual-helper crash/control matrix | **21 passed**, including Stop/shutdown/update | `logs/review7-crash-final.log`, `logs/review7-crash-build.log` |
| SubagentOpeningTests, serial | **9 passed** | `logs/review7-SubagentOpeningTests-restored-final.log` |
| SubagentNavigationTests, serial | **5 passed** | `logs/review7-SubagentNavigationTests-final.log` |
| SubagentPerformanceTests, serial | **1 passed** | `logs/review7-SubagentPerformanceTests-final.log` |
| Native CaptureDrainTests, serial | **6 passed** | `logs/review7-CaptureDrainTests-restored-final.log` |
| HostSupervisorTests, serial | **10 passed** | `logs/review7-HostSupervisorTests-restored-final.log` |
| TestHostIsolationTests, serial | **3 passed** | `logs/review7-TestHostIsolationTests-restored-final.log` |
| TopicOrganizationTests, serial | **14 passed** | `logs/review7-TopicOrganizationTests-restored-final.log` |
| ModelCatalogEndpointTests, isolated diagnostic | **19 passed** | `logs/review7-ModelCatalogEndpointTests-final.log` |

The helper run includes `SessionSettlementTests`, `CostLimitTests`,
`CaptureDrainTests`, and `HostServiceTests`. The skipped helper test is the
opt-in `PI_SCROLL14_PERF=1` rapid-supersession measurement; its cancellation
correctness tests pass. The first full native lane ran 2,342 tests: 2,306
passed, 35 skipped and one model-picker screenshot fixture failed because
`CGWindowListCreateImage` returned no image (`review7-native-parallel-final2.log`
and its exported text summary). That unchanged 19-test class passes alone.
The final full lane after the host-loss fix passes with no failures and no
outside native-test overlap. It includes all eight parallel sub-agent classes
(62 tests), both cost-limit classes, message versions and session organization.

Serial classes ran one class per invocation, with native activity checked
before and throughout each run. `logs/review7-serial-isolation.jsonl` names the
accepted runs with empty overlap sets; helper tests/crash tests did not run
alongside the serial native checks. Gallery scenes are unchanged because this
round changes storage/recovery, not the view layouts.

## Round-5 review — 2026-10-14

Started from `fab5ee6e`, matching `origin/dev/subagents`. Implementation commit:
`0cbd8aa3`. The restored-source results below cover that executable
and test tree; the subsequent validation-record commit changes documentation
only. Artifacts use the build root above and `logs/review5-*`.

| Finding | Disposition and reason |
| --- | --- |
| Inspector Show in Chat leaves a registered live child detached | **Fixed.** `WorkspaceModel.select` owns managed attachment before history loading, including reselection. `revealMessage` sends an already selected child through the same path. Family Inspector links validate their card target on every open; standalone child Inspectors use the common selection path. |
| Reconciliation replaces live status with interrupted | **Fixed.** `DiscoveredSubagent.hasTerminalRecord` distinguishes actual terminal evidence from the recovery fallback. The fallback retains listed progress; real terminal evidence still wins. Helper loss invalidates nonterminal summaries, and a callback from an obsolete helper connection cannot republish live state. |
| Back to Parent cannot find a later turn hidden by an ancestor edit | **Fixed.** `session.versions(containing:)` locates the retained version containing the exact issuing assistant row and its visible anchor, including nested edits. The existing version pager and tool-call reveal show that exact card. The helper's journal bytes and current branch remain unchanged. |
| Standalone child Inspector Originating tool takes the generic fallback | **Fixed.** It resolves the immutable origin from child metadata or the owner's retained capture group, validates workspace/call identity, and uses `showSubagentParent`, including bringing the main window forward. |

No findings were rejected. The sweep also fixed Parent request → Show in Chat
in both Inspector modes: it now follows the issuing attempt's delegation link
instead of falling back to a current-branch message lookup. A second additional
regression showed that an older discovery callback could overwrite a newer
committed topic move/archive in memory; discovery now uses the existing
`ChatRecord.merged` rules.

The design's Implementation notes describe the shared selection and retained
version lookup. No owner decision, capture policy, budget semantics, journal
format, tool permission or rollout switch changed. No editing lock or capture
cap was added.

Entry-point audit:

| Entry point | Managed route and verification |
| --- | --- |
| Sidebar child row, expanded group, next/previous chat shortcuts | Sidebar opening and direct selection converge on `select` → `attachManagedSubagent`; the real-helper tests attach before streaming updates. Selected children retain the existing transient group expansion. |
| Card title/Open, including retained/copied cards | `openSubagent` checks the original owner and reciprocal child header, then selects through the common path. A cancelled or superseded open returns false so an Inspector follow-up cannot reveal it anyway. |
| Family Inspector Show in Chat, child request/turn/group | Group targets use `openSubagent`; request/turn reveals converge on `revealMessage` and selection. Registered metadata no longer bypasses attachment. |
| Standalone child Inspector Show in Chat, overview/Next Request/request | `revealMessage` uses the same selection/attachment path, including a child already selected. The real-helper fixture checks standalone request navigation; the other pages share this adapter. |
| Originating tool, both Inspector modes | `showOriginatingTool` resolves the immutable link → `showSubagentParent` → `openSubagentParent` → exact issuing-call reveal. Both modes are exercised after an ancestor edit. |
| Parent request, both Inspector modes | Opens/focuses the owner's Inspector; family filters widen through the existing focus adapter. Show in Chat follows the parent attempt's delegation link. The real-helper test presses both Parent request buttons and follows through to the retained card. |
| Search results and find | Sidebar opening first selects/attaches; `SidebarSearchReveal` then reveals the matching row, including the existing queued-task placeholder mapping. Find operates within that selected transcript. Search, transcript reveal and sidebar classes pass. |
| Back to Parent button and ⌘[ | Both use `backToSubagentParent`/`openSubagentParent`. The helper lookup covers direct, ancestor and nested edits. Native navigation tests retain exact tool scrolling, earlier-version/draft behavior and file/Git/terminal/Inspector shortcut ownership. |
| Menu-bar/live activity/report links and notifications | Direct selection and report `revealMessage` now share managed attachment. Children still generate no independent unread marker, sound, title or webhook; ordinary parent navigation/notifications keep their existing behavior. Inspector lineage actions explicitly reveal the issuing call. |
| Launch restoration | `reopenRememberedSelection` → `select`. A warm owner attaches its live child; a cold restore reads saved history without starting a helper or resuming work. Both are exercised. Existing restored-reader recovery tests still cover sidebar Resume, parent preview and Back to Parent. |
| Topic move/removal, reconcile, archive/restore | Reconciliation preserves live status and newer organization without starting execution. Archive replacement uses common selection and restore keeps its existing reveal. Discovery, organization, topic and archive classes verify these paths. |

Failing-first evidence:

- `logs/review5-versions-red.log`: 8 helper tests, 7 assertions failed in the two
  new containing-version tests (ancestor edit, nested edit, and missing target).
- `logs/review5-opening-red.log`: 7 native tests, 21 assertions failed. Six
  opening routes missed attachment; Back and both Inspector modes missed the
  issuing card after an ancestor edit.
- `logs/review5-discovery-red.log`: 9 tests, 4 assertions failed: queued/running
  summaries and child displays became interrupted after a disk scan.
- `logs/review5-live-discovery-red.log`: the real-helper topic-move regression
  failed because reconciliation replaced running with interrupted.
- `logs/review5-parent-request-red.log`: 8 assertions failed in the additional
  Parent request follow-through cases. The intermediate
  `review5-opening-restored.log` also failed those cases; selecting by issuing
  attempt identity fixed them (`review5-opening-green2.log`).
- `logs/review5-metadata-red.log`: 17 tests, 3 assertions failed: discovery
  publication undid a newer topic/archive/revision. The existing Inspector
  classes passed in that invocation.

Eight regression methods were added (two helper, six native), with multiple
entry routes exercised inside the real-helper cases. All 14 behavioral
mutations are caught; `logs/review5-mutations.json` lists each mutation, its
regression and exit status. They remove/break containing-version lookup, nested
anchors, live-row handling, initial/reselected child attachment, already-selected
reveals, parent lookup, standalone Originating tool, Parent request follow-through,
live-status preservation, genuine terminal evidence, helper-loss invalidation,
connection validation and organization rebasing. Production files are restored
in the harness's `finally` block. One initially uncompilable unused-value mutant
is retained in `review5-mutation-discovery-live-status-build-error.log`; it is not
counted as a caught mutation. The corrected mutant compiled and failed the
intended assertions.

Final results:

| Check | Result | Text evidence |
| --- | --- | --- |
| Helper selected suites | **128 passed**, 0 failed | `logs/review5-helper-final.log` |
| Affected native parallel-eligible classes | **294 passed**, 0 failed/skipped, 36 classes | `logs/review5-affected-native-final.log` |
| `SubagentOpeningTests`, serial alone | **8 passed**, 0 failed/skipped | `logs/review5-final-SubagentOpeningTests.log` |
| `SubagentNavigationTests`, serial alone | **5 passed**, 0 failed/skipped | `logs/review5-final-SubagentNavigationTests.log` |
| `TopicOrganizationTests`, serial alone | **14 passed**, 0 failed/skipped | `logs/review5-final-TopicOrganizationTests.log` |
| Native `CaptureDrainTests`, serial alone | **6 passed**, 0 failed/skipped | `logs/review5-final-CaptureDrainTests.log` |
| `HostSupervisorTests`, serial alone | **7 passed**, 0 failed/skipped | `logs/review5-final-HostSupervisorTests.log` |
| Crash matrix | **21 cases passed**, 0 failed | `logs/review5-crash-final.log` |

The helper run includes the requested `SessionSettlementTests` (2),
`CostLimitTests` (11), `CaptureDrainTests` (4), and `HostServiceTests` (6), plus
version, delegation, accounting, admission, permission, journal, recovery,
Resume, compaction and host-contract coverage. Native coverage also includes
cost limits, all affected organization/deletion classes, launch/selection,
Inspector/report navigation, sidebar/search, history reveals and refresh
lifecycle. Exact commands and class arrays are in
`$PI_BUILD_ROOT/review5-validate.sh` and the serial continuation log/script.
Every command uses the required build root. Native invocations use the custom
validation bundle identifier. Validation uses generated data and loopback
providers; no installed app or real preferences, Keychain or user data.

Other workstreams were building/testing on the same Mac. The initial final
Opening pass overlapped that work; the first Navigation invocation was cancelled
during its build and is not counted. Their logs are retained as
`review5-overlap-SubagentOpeningTests.log` and
`review5-overlap-SubagentNavigationTests.log`. The seven native serial mutations
were repeated, followed by each full serial class separately. The continuation
script `$PI_BUILD_ROOT/review5-isolated.py` and
`logs/review5-isolation.jsonl` record retries and external process activity;
later samples distinguish compilation overlap from native test execution.
Accepted final serial runs had no detected external build/test activity while
their native test hosts were running. Earlier overlapping attempts are diagnostic
only. The helper-only crash matrix ran separately while the native queue waited.
No other workstream's processes, files or builds were stopped or modified.

Result retention: removed 79 obsolete task-owned `.xcresult` bundles, reclaiming
2,714,731,067 bytes (about 2.5 GiB); every text log remains. The manifest is
`logs/review5-xcresult-cleanup.json`. A mixed-class bundle remains only when it
is still the newest retained result for at least one of its classes; superseded
single-class and mutation bundles were deleted. Unrelated bundles were left
untouched.

No full native parallel lane or gallery was rerun in this round; their earlier
records remain scoped to the revisions they tested. The existing gallery scenes
are unchanged. No owner decision is outstanding. Work remains on
`dev/subagents`; no merge or push to `dev/next` or `main`.

## Round-4 review — 2026-10-14

Started from `5c88a445`; fetching `origin/dev/subagents` confirmed the same
upstream tip, including the audit merge `f4bf746b`. Implementation commit:
`d94d2592` (`Fix family recovery readers and delegation listing races`). The
restored-source results below cover that executable/test tree; the following
validation-record commit changes documentation only. Artifacts are under the
build root above, in `logs/review4-*` and `review4-*.xcresult`.

| Finding | Disposition and reason |
| --- | --- |
| Restored child readers block parent recovery | **Fixed.** The helper releases every idle reader belonging to the budget owner before cold construction, under its existing runtime gate. This covers sidebar Resume, parent preview, Back to Parent and multiple siblings. Live queued/settling children cannot unload; another family's readers stay attached. The existing `session.unloaded` event invalidates the app's opened set, including an open still finishing after its reply. |
| Plans listed during preparation become interrupted | **Fixed.** Preparation is tracked before durable registration yields, and is listed as queued. Rejected setup retains its actual failure. The parent supplies journal state and sequence together; listing retries if coordinator state changes during that await, including terminal-job consumption. Recovered old-helper results retain their interrupted classification. The Inspector's terminal-state protection remains unchanged. |
| Archive replacement selects an archived child | **Fixed.** The selection reducer removes each owner's newly archived managed family as one action. This also handles archiving the parent while its child is selected. Ordinary ordered archive behavior and independent sides remain intact. |

No findings were rejected. No owner decision, capture policy, budget semantics,
journal format or rollout switch changed. Recovery uses the existing runtime
gate; no editing lock was added. The design's Implementation notes describe the
corrections.

The nearby sweep also fixed four related cases: an unload overtaking app-side
open finalization; a rejected preparation incorrectly listed as interrupted;
consumption pruning a job after an earlier journal snapshot; and live listing
versus disk discovery rejecting equivalent macOS journal paths. The last case
surfaced in the first native opening run and was reproduced deterministically:
`/var` and `/private/var` aliases must compare canonically. A different journal,
workspace or origin still fails validation. The archive regression also covers
starting from the child's selected transcript and preserving navigation on
restore.

Other parent construction paths converge on `makeSession` under the same gate.
The organization sweep covered archive/restore, topic moves/removal and family
deletion. Topic moves already pass selected roots to the expanding transaction;
deletion clears selection for every removed member. Those paths needed no
additional production change and their regression classes passed below.

Failing-first evidence:

- `logs/review4-helper-red.log`: **34 tests, 4 failures**, reproducing both reader
  recovery guards and listing during preparation/rejection.
- `logs/review4-list-consumption-red.log`: **1 test, 1 failure**, using an explicit
  barrier after the parent snapshot and before the consumed job is pruned.
- `logs/review4-organization-red.log`: **13 tests, 4 failures**, from both parent
  and child selection, including navigation after restore.
- `logs/review4-opening-red.log`: **5 tests, 5 failures**, including actual
  fixture-helper SIGKILL, sidebar Resume, parent preview, and invalidation during
  open finalization. Back to Parent is also exercised by the same regression.
- `logs/review4-discovery-red2.log`: **8 tests, 1 failure**, proving the canonical
  path mismatch. The earlier discovery fixture's alias assertion and missing
  capture-store setup were corrected before this behavioral red run.

**15 mutations killed**, all by behavioral failures, not build errors:
release before recovery, all siblings, owner boundary, live-child protection,
unload notification, preparing status, recovered status, rejected status,
snapshot retry, path aliases, different-file rejection, archive candidates,
selected-child replacement, opening-task cancellation and its final cancellation
check. `logs/review4-mutations.json` records each result;
`review4-mutations.py` in the build root is the source-restoring harness. Mutations
ran sequentially, restored sources in `finally`, and were followed by a rebuild
and the final tests with every guard restored.

| Final selection | Result | Log |
| --- | --- | --- |
| Helper recovery, coordinator, accounting and requested baselines | **120 passed**, no failures/skips | `logs/review4-helper-restored.log` |
| Affected native classes, supplied as a bash array | **173 passed**, no failures/skips | `logs/review4-native-restored.log` |
| `SubagentOpeningTests`, alone | **5 passed** | `logs/review4-serial-SubagentOpeningTests.log` |
| `SubagentNavigationTests`, alone | **5 passed** | `logs/review4-serial-SubagentNavigationTests.log` |
| `TopicOrganizationTests`, alone | **14 passed** | `logs/review4-serial-TopicOrganizationTests.log` |
| Native `CaptureDrainTests`, alone | **6 passed** | `logs/review4-serial-CaptureDrainTests.log` |
| Actual-helper crash matrix | **21 cases passed** | `logs/review4-crash-matrix.log` |

The helper selection includes `SessionSettlementTests` **2**, `CostLimitTests`
**11**, `CaptureDrainTests` **4**, `HostServiceTests` **6**,
`SubagentRecoveryTests` **12**, `SubagentCoordinatorTests` **23**,
`SubagentAccountingTests` **8**, `SubagentAdmissionTests` **6**,
`SubagentPermissionTests` **6**, `SubagentJournalTests` **8**,
`SubagentContractTests` **4**, `PausedFamilyCompactionTests` **4**,
`ContinueRunTests` **15**, `ContractTests` **8**, and `HostDispatchTests` **3**.

The native array includes `SubagentOrganizationTests` **13**,
`SubagentDiscoveryTests` **8**, `SubagentDeletionTests` **8**,
`SubagentMetadataTests` **6**, `SubagentCaptureTests` **5**,
`SubagentInspectorTests` **6**, `OrganizationBatchTests` **9**,
`SessionOrganizationTests` **9**, `SidebarFlatTopicsTests` **14**,
`SidebarMultiSelectionTests` **4**, `TopicSidebarPresentationTests` **4**,
`TopicStorageTests` **17**, `TopicSessionDragTests` **3**,
`WorkspaceConcurrencyTests` **8**, `WorkspaceDurabilityTests` **7**,
`WorkspaceLoadingTests` **12**, `WorkspaceRefreshLifecycleTests` **26**,
`CostLimitTests` **13**, and `CostLimitOpeningTests` **1**. Total native tests:
**203 passed**. `python3 scripts/test-lanes.py list` determined the lanes; each
serial class ran in a separate invocation with no other build/test running.

The crash matrix rebuilt its instrumented source copy from this tree and used
the restored production helper for recovery. All creation/accounting/result
barriers, tool-effect barriers, Stop, shutdown and update cases passed. Reopen
sent no requests; Resume sent only a parent request, without replaying child
requests or tool effects. Native recovery tests additionally SIGKILL only their
own fixture helper and open a child preview before all three parent-entry paths.

Reproduction commands (all use the required build root):

```bash
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents
export TMPDIR="$PI_BUILD_ROOT/xcode-tmp/"
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'SubagentRecoveryTests|SubagentCoordinatorTests|SubagentAccountingTests|SubagentAdmissionTests|SubagentPermissionTests|SubagentJournalTests|PausedFamilyCompactionTests|ContinueRunTests|ContractTests|HostDispatchTests|SessionSettlementTests|CostLimitTests|CaptureDrainTests|HostServiceTests'
classes=(SubagentOrganizationTests SubagentDiscoveryTests SubagentDeletionTests SubagentMetadataTests SubagentCaptureTests SubagentInspectorTests OrganizationBatchTests SessionOrganizationTests SidebarFlatTopicsTests SidebarMultiSelectionTests TopicSidebarPresentationTests TopicStorageTests TopicSessionDragTests WorkspaceConcurrencyTests WorkspaceDurabilityTests WorkspaceLoadingTests WorkspaceRefreshLifecycleTests CostLimitTests CostLimitOpeningTests)
args=()
for class in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$class"); done
scripts/test-macos.sh "${args[@]}" \
  'PRODUCT_BUNDLE_IDENTIFIER=com.belloware.SubagentValidation.$(PRODUCT_MODULE_NAME)'
# Each of the four serial classes above gets its own test-macos invocation.
python3 scripts/test-subagent-crashes.py "$PI_BUILD_ROOT/bundle/Helpers/pi-native-host"
```

No full native lane or gallery was rerun in this round; earlier results remain
evidence for their recorded revisions. No open owner questions remain from this
review. Work stays on `dev/subagents`; no merge or push to `dev/next` or `main`.

## Round-3 review — 2026-10-14

Started from `9e20f62b`; fetching `origin/dev/subagents` confirmed the same
upstream tip. This includes the audit merge `f4bf746b`. Platform: macOS 14.8
(23J21), arm64, Xcode 16.1 (16B40), Swift 6.0.2. Artifacts use
`logs/review3-*`, `review3-*.xcresult` and `review3-gallery/subagents/` under the
build root above.

Implementation commit: `340ba34b` (`Fix family deletion and paused compaction
regressions`). The restored-source results below cover that executable/test tree;
the subsequent validation-record commit changes documentation only.

| Finding | Disposition and reason |
| --- | --- |
| Saved fork/kept side deletion | **Fixed.** The helper already writes `fork_<id>.jsonl` and `side_<id>.jsonl`. Owner validation now accepts those exact names alongside `<id>.jsonl`, inside the same project directory, before detaching the runtime or writing deletion intent. Durable retries use the same validation. Managed children still require their UUID filename; the aliases do not apply to them. |
| Manual compaction of a paused family | **Fixed.** Admission and dispatch now carry an allowance only for the independent owner's explicit manual summary, including its retries. Queued follow-ups stay paused. A later Stop still invalidates the captured generation and permit, and both accounting gates retain cost-limit checks. Ordinary requests and automatic summaries remain blocked by the pause. |
| Group-header indentation | **Fixed.** The Pi button previously centered its label in all remaining row space. The running scene's longer label and the child scene's shorter label therefore had different leading edges despite equal row indentation. Sizing the button to its face keeps the chevron at a fixed leading edge while retaining narrow-width fallback labels, tooltip and accessibility counts. |

No findings were rejected. No owner decision, capture policy or protocol/journal
format changed. The design's Implementation notes record these corrections.

Failing-first and mutation evidence:

- `review3-native-red2.log`: **20 tests, 26 failures** before production fixes.
  The deletion failures included an `invalidRecord` when a tombstoned parent
  was written again, proving it remained blocked. The sidebar test measured
  the Pi face's leading edge across full and shortened labels.
- `review3-helper-red2.log`: **4 tests, 11 failures** before production fixes.
  Both Stop and provider-failure scenarios failed to send a manual summary;
  the admitted-permit test also exposed the paused admission failure. Earlier
  fixture setup and test-compilation errors were corrected before these red
  runs and are not counted as behavioral evidence.
- **10 mutations killed**, all by behavioral test failures: owner filename
  compatibility, owner validation before intent, strict child filenames,
  disclosure alignment, paused admission, paused dispatch, later Stop
  generation, cancelled permit, manual-only allowance, and preservation of
  paused follow-ups. `logs/review3-mutations.json` records each result;
  `review3-mutations.py` is the source-restoring harness in the build root.
  Sources were mutated and built sequentially, restored in `finally`, and
  rebuilt with all guards restored before final testing.

Final restored-source results:

| Selection | Result | Log |
| --- | --- | --- |
| Helper accounting, delegation, compaction and requested baselines | **97 passed**, no failures/skips | `logs/review3-helper-restored.log` |
| Affected native classes, passed as a bash array | **84 passed**, no failures/skips | `logs/review3-native-restored.log` |
| `TopicOrganizationTests`, alone | **14 passed** | `logs/review3-serial-TopicOrganizationTests.log` |
| Native `CaptureDrainTests`, alone | **6 passed** | `logs/review3-serial-CaptureDrainTests.log` |
| Sub-agent gallery, alone | **1 passed**, **92 PNGs** regenerated | `logs/review3-gallery.log` |

The helper selection includes `SessionSettlementTests` **2**, `CostLimitTests`
**11**, `CaptureDrainTests` **4**, and `HostServiceTests` **6**, plus
`PausedFamilyCompactionTests` **4**, `SubagentAdmissionTests` **6**,
`SubagentAccountingTests` **8**, `SubagentCoordinatorTests` **20**,
`SubagentPermissionTests` **6**, `CompactionQueueTests` **2**,
`CompactionReceiptTests` **1**, `CompactionSnapshotTests` **3**, and
`CompactionSafetyTests` **24**. The new compaction regression verifies two
summary attempts are charged, the queue remains paused after success, and a
later Stop or cancelled permit prevents dispatch/adoption.

The native selection includes `SubagentDeletionTests` **8**,
`SubagentOrganizationTests` **12**, `SubagentDiscoveryTests` **7**,
`SubagentMetadataTests` **6**, `OrganizationBatchTests` **9**,
`SessionOrganizationTests` **9**, `SidebarFlatTopicsTests` **14**,
`TopicSidebarPresentationTests` **4**, `ManualCompactionTests` **1**,
`CostLimitTests` **13**, and `CostLimitOpeningTests` **1**.
`python3 scripts/test-lanes.py list` determined the lanes; each serial class
ran in its own invocation, with no other test/build running.

All §13.5 gallery scenes remain present at both sizes and appearances, with a
manifest in `review3-gallery/subagents/manifest.txt`. Visually compared the
parent `running-expanded` and `child` scenes at 1240×800/light and
920×600/dark: their disclosure chevrons and labels now share the same leading
edge; the open child remains expanded and highlighted. This is a targeted
visual review of the changed scenes, not a claim to inspect all 92 images.

Commands follow this pattern (the exact selections are listed above):

```bash
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-subagents
export TMPDIR="$PI_BUILD_ROOT/xcode-tmp/"
swift test --package-path packages/swift-host --scratch-path "$PI_BUILD_ROOT/swift-tests" \
  --filter 'PausedFamilyCompactionTests|SubagentAdmissionTests|SubagentAccountingTests|SubagentCoordinatorTests|SubagentPermissionTests|CompactionQueueTests|CompactionReceiptTests|CompactionSnapshotTests|CompactionSafetyTests|SessionSettlementTests|CostLimitTests|CaptureDrainTests|HostServiceTests'
classes=(SubagentDeletionTests SubagentOrganizationTests SubagentDiscoveryTests SubagentMetadataTests OrganizationBatchTests SessionOrganizationTests SidebarFlatTopicsTests TopicSidebarPresentationTests ManualCompactionTests CostLimitTests CostLimitOpeningTests)
args=()
for class in "${classes[@]}"; do args+=("-only-testing:PiAppTests/$class"); done
scripts/test-macos.sh "${args[@]}" \
  'PRODUCT_BUNDLE_IDENTIFIER=com.belloware.SubagentValidation.$(PRODUCT_MODULE_NAME)' \
  -resultBundlePath "$PI_BUILD_ROOT/review3-native-restored.xcresult"
PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/review3-gallery" \
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$PI_BUILD_ROOT/review3-gallery" \
scripts/test-macos.sh -only-testing:PiAppTests/UIScreenshotTests/testRenderSubagentGallery \
  'PRODUCT_BUNDLE_IDENTIFIER=com.belloware.SubagentValidation.$(PRODUCT_MODULE_NAME)' \
  -resultBundlePath "$PI_BUILD_ROOT/review3-gallery.xcresult"
```

This review reran the affected suites. The full native lane, crash and streaming
results in the previous review below remain evidence for their recorded revision.

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
