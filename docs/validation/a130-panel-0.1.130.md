# Floating session panel · 0.1.130

Workstream: `dev/a130-panel`. Owner request, 2026-10-20: an always-available
floating card on the main conversation when room permits, with pinned
Agents / Diff / Files tabs. This branch is for lead review and merge; it does
not merge or push `dev/next`, release, tag, or publish.

## Decisions and boundaries

- The Pi elevated card is 288 pt wide, with 14 pt corners, the house soft
  shadow, and 16 pt right/top/bottom spacing. The main conversation must have
  at least **800 pt width** (480 transcript + 16 gap + 288 card + 16 edge)
  and 212 pt transcript-region height (180 card minimum + two 16 pt insets).
  It grows to its content height, capped above the composer, queue, terminal
  and missing-folder bar. Long content scrolls inside.
- Layout first allocates banners and the lower controls. The card and
  transcript receive disjoint frames in the remaining area; the find bar
  stays inside the transcript frame. When a full reading column fits, its
  spare right margin is used first; sufficiently wide windows preserve the
  existing centred column. Width changes use the transcript's existing
  anchor-preserving reflow. Content/status changes never change this width.
- Main chats with no family still get Agents. New Side retains its existing
  eligibility, including scratch/imported-chat restrictions. Only
  `WorkspaceRootView` opts its main conversation into the card. Side conversations
  and managed child readers do not get a floating card. The existing family
  pill/popover remains the fallback, including its established independent
  child-window behavior. Collapse and tab choice belong to the window's
  in-memory state, survive chat switches and resizing, and are not persisted.
  The pill restores the chosen tab. The family shortcut selects/focuses Agents
  when the card is visible; a collapsed or narrow card keeps the existing popover.
- **Needs owner decision:** the task describes popped-out child pills as already
  suppressed, but `SubagentTab.swift:68` and the existing reader/gallery tests
  explicitly retain them in independent windows. This branch preserves that
  navigation and adds no floating card there. Hiding that existing pill would
  be a separate visible behavior change.
- Agents reuses `AgentFamilyPopoverView`, including live family membership,
  status, spend, open/select, Stop, Stop All confirmation and New Side.
  Compact rows show status and spend; complete model/effort/owner details
  remain in tooltips and accessibility labels. Mounting the card does not
  take keyboard focus.
- Diff reuses `GitController` / `GitService` and their watcher and cancellation
  rules. A summary-only controller reads status and batched numstats, without
  history, branches, stashes or patches. It retains its snapshot across tab
  changes and stops reads/watchers when hidden. Clicking uses `showChanges`,
  selecting the same staged/working-tree side whose counts the card displays.
  A staged and unstaged file is listed once, opening its working-tree side.
  Binary files say Binary; unavailable counts show a dash. Untracked regular
  files are counted off the main thread with the existing 4 MiB safe-reader
  limit; symlinks in any path component and special/oversized files receive no invented counts.
- Files reuses `FolderBrowser`, `FolderDirectory`, `FileFolderPanel` and the
  virtualized `FolderTreeView`: lazy levels, 200-entry pages, existing ignored
  and dot-file dimming, and existing symlink/special-file exclusions. Expanded
  levels and snapshots survive tab changes; reopened levels refresh.
  File clicks use `WorkspaceModel.openFile` and retain FileTab trust checks.
  A multi-root project offers the existing house folder menu.
- Only repository discovery is eager while the card is visible. Diff is absent
  for scratch/non-repository projects; Files is absent without a project.
  Readers are cancelled on hiding, switching roots/projects and unmounting.
  No helper, capture, permission, vault, or tool authority is added by browsing.

## Validation

Build root and text logs:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/`.
All data is generated; native tests use the isolated test host and scratch
preferences. No installed app, real chat, real credential, Keychain access,
paid request, named result bundle, or release action was used. Only generated
fixture views/windows were captured.
Focus and gallery runs acquire the shared full-lane lock and remove only their
own owner file/directory on exit.

- Failing first: `panel-red.log`, 1 test, 1 expected failure. A wide main chat
  with an empty family had no floating card.
- First implementation: `panel-first-green.log`, the same test passes.
- Git package: `swift test --package-path packages/bello-views --scratch-path
  /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter GitViewTests`:
  **176 passed, 0 failed** (`views-git.log`). The final repository-state class,
  including four new summary tests, subsequently passed **16/16**
  (`views-summary-final.log`).
- Safe-reader regression: `summary-boundary-red.log` reproduces reading through
  a directory swapped for a symlink (**1 test, 1 expected failure**). Reusing
  `GitPatchFile.read` passes the test. Replacing it with an ordinary URL read
  fails again (`mutation-summary-boundary.log`); restoring it passes
  (`summary-boundary-green.log`). All paths and outside targets are generated.
- Pure geometry mutations: lowering the 800 pt threshold by 1 pt fails the
  799 pt assertion (`mutation-threshold.log`); removing the reserved card width
  fails the disjoint-frame assertions (`mutation-overlap.log`). Bypassing
  summary-only mode fails count/selection/history assertions
  (`mutation-git-summary.log`). Every mutation was restored.
- Existing family/model focused run (`affected-family-models.log`):
  `ConversationFamilyTests` **22/22**, `SideTests` **15/15**,
  `SubagentEffortTests` **5/5**, `SubagentPanelTests` **7 passed, 1 failed**.
  Exact invocation uses `PI_BUILD_ROOT` below, `-parallel-testing-enabled NO`
  and one `-only-testing:PiAppTests/<Class>` argument for each of those four
  windowless classes.
- The unrelated failure is
  `SubagentPanelTests.testTopicCountsOnlyMainChatsAndMatchingTopicDoesNotHideChildSearchHits`
  at `apps/macos/PiAppTests/SubagentPanelTests.swift:31`: matching topic search
  returns `chat-side` as well as the expected parent and child. The test and
  topic/search implementation are unchanged on this branch; relevant routing
  is `SidebarChatRow.swift:236`. Recorded for the lead; not broadened into a
  filtering fix.
- The initial complete native feature run (`panel-focused.log`) found two
  issues (13 tests, 11 passed): the key-window test setup and loss of folder
  expansion on reopening. Production folder comparison now uses the browser's
  normalized URL.
  The repeat (`panel-focused-key-window.log`) passed 16 of 17 tests, with
  three assertions in the shortcut test still blocked by WindowServer key-window
  activation. The fixture now nominates its window for routing and explicitly
  checks that an inactive window ignores the request; AppKit first-responder
  changes and controls are still real. No production focus guard was relaxed.
  The final feature run passes **17/17**, including collapsed-shortcut behavior
  (`panel-focused-final.log`). A separate restored two-test control passes
  **2/2** (`affected-PanelRestore.log`).

### Final focused native results

Each row ran alone with
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/<Class>`.
The log is `affected-<Class>.log`, except the feature class uses
`panel-focused-final.log`. Window/focus runs held the shared full-lane lock.

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| SessionPanelTests | 17 | 0 | 0 |
| SideRowPresentationTests | 1 | 0 | 0 |
| SidebarSideClickTests | 4 | 0 | 0 |
| SubagentReaderTests | 57 | 0 | 0 |
| InheritedSubagentReaderTests | 7 | 0 | 0 |
| SubagentNavigationTests | 7 | 0 | 0 |
| SubagentOpeningTests | 14 | 0 | 0 |
| SubagentPanelGalleryTests | 2 | 0 | 1 |
| ConversationPaneTests | 81 | 0 | 0 |
| ConversationPaneRetentionTests | 6 | 0 | 0 |
| WorkspaceSplitTests | 10 | 0 | 0 |
| WorkspaceRootTests | 7 | 0 | 0 |
| FileFolderTests | 19 | 0 | 0 |
| FileTabTests | 16 | 0 | 0 |
| TabPaneTests | 10 | 0 | 0 |
| TabHostTests | 16 | 0 | 0 |
| ChangesTabTests | 8 | 0 | 0 |
| ChangesTabFrameTests | 7 | 0 | 0 |
| GitPanelShownTests | 13 | 0 | 0 |
| GitWorkingTreeWatcherTests | 16 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitPanelRedrawTests | 4 | 0 | 0 |
| GitPanelAuditTests | 8 | 0 | 0 |
| GitRenameTests | 6 | 0 | 0 |

Including the four family/model classes above, the existing native classes
total **385 passed, 1 unrelated failure, 1 skipped**. The skipped original-fork
gallery requires its separate `PI_APP_ORIGINAL_GALLERY` environment variable;
the two affected family/nested galleries were enabled and passed.
The new feature class adds **17 passed**. Repeated positive controls are not
included in those totals.

Exact additional commands (run from the worktree root, with the same
`PI_BUILD_ROOT`; gallery commands also hold the shared lock):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationFamilyTests \
  -only-testing:PiAppTests/SideTests \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/SubagentPanelTests

TEST_RUNNER_PI_APP_SUB_PANEL_GALLERY="$PI_BUILD_ROOT/screenshots/legacy-family" \
TEST_RUNNER_PI_APP_SUB_NESTED_GALLERY="$PI_BUILD_ROOT/screenshots/legacy-family" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentPanelGalleryTests

TEST_RUNNER_PI_SESSION_PANEL_GALLERY="$PI_BUILD_ROOT/screenshots" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelGalleryTests

swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter GitViewTests
swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter GitRepositoryStateTests

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelTests/testCollapseReopenAndTabChoiceAreWindowSessionState \
  -only-testing:PiAppTests/SessionPanelTests/testFilesAreLazyVirtualizedAndKeepUntrustedContentUnreadable
```

The initial red/green invocation selects
`PiAppTests/SessionPanelTests/testWideMainChatShowsFloatingPanelEvenWithoutAgents`
with the same native command prefix. The safe-reader red/green invocation uses
the package command prefix with
`--filter GitRepositoryStateTests/testSummaryNeverFollowsAReplacedDirectoryOutsideTheRepository`.

### Mutation controls

All **7/7 mutations were detected**, then restored. Native filters below use
`scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests/<method>`;
package filters use the `swift test` command above with
`--filter GitRepositoryStateTests/<method>`.

| Mutation | Target method | Result / text log |
| --- | --- | --- |
| Accept 799 pt instead of 800 pt | `testLayoutContractWithoutWindows` | Expected failure, `mutation-threshold.log` |
| Remove transcript's reserved width | `testLayoutContractWithoutWindows` | Expected failure, `mutation-overlap.log` |
| Bypass summary-only reading | `testSummaryReadsCountsWithoutPatchesHistoryOrSelection` | Expected failure, `mutation-git-summary.log` |
| Replace bounded no-symlink reader with URL read | `testSummaryNeverFollowsAReplacedDirectoryOutsideTheRepository` | Expected failure, `mutation-summary-boundary.log` |
| Reopen collapsed card through family shortcut | `testFamilyShortcutFocusesAgentsAndMountNeverStealsComposer` | Expected failure, `mutation-shortcut-collapsed.log` |
| Force Agents when reopening the pill | `testCollapseReopenAndTabChoiceAreWindowSessionState` | Expected failure, `mutation-tab-restore.log` |
| Compare unnormalized browser root | `testFilesAreLazyVirtualizedAndKeepUntrustedContentUnreadable` | Expected failure, `mutation-folder-cache.log` |

No `packages/swift-host` or wire behavior changed, so helper/wire/concurrent/
acceptance suites were not rerun. The lead runs the merged full gate.
`xcodegen generate --quiet` regenerated the project after adding the three
Swift files. No extra DerivedData root was created. No test clone directories
remain under this build root; completed generated gallery fixture directories
were removed while retaining screenshots and text evidence.

## Screenshots

Directory: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/`.
The env-gated `SessionPanelGalleryTests` uses
`TEST_RUNNER_PI_SESSION_PANEL_GALLERY=<directory>`. Every scene is generated
in light and dark at the stated window-content size. The first gallery passed
1/1 and produced all 14 images. All were visually inspected. Inspection caught
an asynchronous fixture configuration reload in the final dark side scene:
the in-memory vault still named the fixture parent instead of the generated
repository. The fixture now saves its project path in that memory-only vault,
seeds side costs, and opens the idle checklist beside the running review side.
A second inspection caught the history fixture returning its one message again
for a follow-up cursor. It now returns an empty terminal page and asserts that
both history boundaries are error-free.
The final regeneration passes **1/1** (`panel-gallery-final.log`), and all
14 final PNGs were opened and visually checked, including both side-pane
scenes after that correction. The existing family/nested galleries produced
72 PNGs in `screenshots/legacy-family/`; all were reviewed in nine contact sheets
(`evidence/legacy-review-1.jpg` through `legacy-review-9.jpg`).

- `agents-1440x900-{light,dark}.png`: two sides (one running), three agents
  (running/completed/failed).
- `diff-1440x900-{light,dark}.png`: six changed files, including add/delete/rename.
- `files-1440x900-{light,dark}.png`: folders expanded two levels.
- `agents-1180x800-{light,dark}.png`: card fits with the 264 pt sidebar.
- `pill-960x700-{light,dark}.png`: falls back to the family pill.
- `empty-1440x900-{light,dark}.png`: empty Agents state and New Side.
- `side-open-1600x900-{light,dark}.png`: a side conversation beside the main
  chat, using a 65% main split so the main area fits the card. At the default
  more even split the narrower main chat uses the pill.

## Review

Adversarial self-review covers lifecycle/cancellation, context-bound Git
navigation, trust-preserving file opens, retained tab choice, keyboard focus,
empty-family collapse, and disjoint geometry. It caught and corrected restoring
the wrong tab on reopen, truncated spend at the compact width, stale Git
row contexts after a repository reading changes, expansion loss from URL
normalization, the untracked-file ancestor-symlink boundary, and shortcut
behavior while collapsed. Suspended Diff callbacks also retain the existing
repository-context acceptance check. No remaining feature regression was found.
The unrelated topic-search failure and independent-child-pill decision above
remain open. The lead's separate review and owner screenshot judgment remain
outside this workstream's sign-off.

## Follow-up review 2026-10-20

The three requested review corrections are scoped to the floating panel and
its summary reader:

- Tab accessibility metadata is assigned through `tabs.tab(identity)`.
  The regression mounts Agents and Files first, inserts Diff, keeps the
  original Files control, and verifies each title, label, identifier and
  action while the retained subviews remain ordered Agents / Files / Diff.
- A negative repository result is invalidated on collapse/reopen, inherited
  hiding or disabling, same-project chat switches, Git state events and
  folder-browser changes. Ordinary panel refreshes keep the negative snapshot;
  there is no polling on layout or scroll. A single existing `GitStateWatch`
  starts before discovery, coalesces events at 0.5 seconds, and stops on
  suspension or successful discovery. Status/counts and Files remain lazy.
  Superseded discovery tasks are cancelled and their publication token retired.
- Untracked paths remove any tracked counts before the bounded read.
  Symlink, oversized and disappeared replacements now have unavailable counts;
  a readable replacement still reports its own three additions and zero deletions.

Adversarial review of the new retry path also checked the pre-discovery watch:
it must not resolve a `.git` file or external `commondir` before Git confirms
the repository. The watcher now has an opt-in discovery mode that watches only
the project folder and recognizes the `.git` marker itself as well as the
existing HEAD/index/ref events. Ordinary Git/linked-worktree watches keep their
existing behavior. A generated invalid marker pointing at another generated
folder tests that no external metadata is resolved, that ordinary saves and
object writes are ignored, and that the marker event triggers discovery.

Text evidence for this follow-up is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r1/`.
The first native compilation caught a test-only `NSControl.title` cast error;
`panel-test-compile.log` records it. It was corrected before the genuine red run.

### Failing-first evidence

| Log | Tests | Expected failed assertions |
| --- | ---: | ---: |
| `panel-red.log` | 5 | 13 |
| `git-red.log` | 1 | 3 |
| `discovery-watch-red.log` | 1 | 3 |

The first row covers retained-tab accessibility and all four negative-discovery
invalidation paths; reactivation covers collapse, hidden ancestor and disabled
state. The live event regression runs `git init` after the panel has published
a negative discovery, without changing chat or tab. The count regression
covers staged deletion plus symlink, over-4-MiB and removed-after-status
replacements, with a readable positive control. The watcher red run used the
new optional initializer argument without its behavior, demonstrating the
metadata-resolution and missing-marker failures before implementing that mode.

### Mutation controls

All **8/8 independent mutations were detected**, then restored. The native
mutation runner stopped once before changing a file because its search string
also matched the folder callback; the selector was narrowed and the remaining
checks resumed. This was a harness assertion, not a test or product failure.

| Removed or broken behavior | Target test | Text log |
| --- | --- | --- |
| Identity-based tab metadata | `SessionPanelTests/testTabAccessibilityFollowsIdentityWhenDiffIsInsertedAfterFiles` | `mutation-tab-identity.log` |
| Negative invalidation on suspension | `SessionPanelTests/testNegativeRepositoryDiscoveryRetriesOnReactivation` | `mutation-reactivation.log` |
| Same-project chat invalidation | `SessionPanelTests/testNegativeRepositoryDiscoveryRetriesOnSameProjectChatSwitch` | `mutation-chat-switch.log` |
| Git event invalidation | `SessionPanelTests/testNegativeRepositoryDiscoveryObservesGitInitWhilePanelIsOpen` | `mutation-git-event.log` |
| Folder event invalidation | `SessionPanelTests/testNegativeRepositoryDiscoveryRetriesOnFolderBrowserChanges` | `mutation-folder-event.log` |
| Skip unverified external metadata | `GitWorkingTreeWatcherTests/testDiscoveryWatchUsesOnlyTheProjectAndNoticesTheGitMarker` | `mutation-discovery-metadata.log` |
| Recognize the `.git` marker | `GitWorkingTreeWatcherTests/testDiscoveryWatchUsesOnlyTheProjectAndNoticesTheGitMarker` | `mutation-discovery-marker.log` |
| Clear tracked counts before untracked reads | `GitRepositoryStateTests/testSummaryNeverKeepsDeletionCountsForUnreadableUntrackedReplacements` | `mutation-untracked-counts.log` |

### Commands

Commands run from this worktree, using only its build root:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel

swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter GitViewTests
swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter GitRepositoryStateTests
swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" \
  --filter GitRepositoryStateTests/testSummaryNeverKeepsDeletionCountsForUnreadableUntrackedReplacements

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ChangesTabTests \
  -only-testing:PiAppTests/GitPanelShownTests \
  -only-testing:PiAppTests/GitPanelRedrawTests \
  -only-testing:PiAppTests/GitPanelAuditTests \
  -only-testing:PiAppTests/GitRenameTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ChangesTabFrameTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitRepositorySwitchTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileFolderTests

TEST_RUNNER_PI_SESSION_PANEL_GALLERY="$PI_BUILD_ROOT/screenshots/review-r1" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelGalleryTests
```

Each native mutation and the discovery-watch red run use the same native
command prefix with `-only-testing:PiAppTests/<target test>` from the table.
The initial `panel-red.log` selects all five `SessionPanelTests` targets in
that table, with one `-only-testing` argument each. The count red and mutation
use the last package command. Each native invocation holds the shared UI
lane lock, releasing only its own lock on success or failure. Serial-lane
classes run alone. Native command lines are also recorded at the start of
each text log.

### Restored validation

Every row below uses the restored fixes. All have **0 failures and 0 skips**;
repeated positive controls are excluded from the totals.

| Suite / class | Passed | Text log |
| --- | ---: | --- |
| `SessionPanelTests` | 22 | `panel-final.log` |
| `GitWorkingTreeWatcherTests` | 17 | `watcher-final.log` |
| `ChangesTabTests` | 8 | `git-app-final.log` |
| `GitPanelShownTests` | 13 | `git-app-final.log` |
| `GitPanelRedrawTests` | 4 | `git-app-final.log` |
| `GitPanelAuditTests` | 8 | `git-app-final.log` |
| `GitRenameTests` | 6 | `git-app-final.log` |
| `ChangesTabFrameTests` | 7 | `changes-frames-final.log` |
| `GitRepositorySwitchTests` | 17 | `repository-switch-final.log` |
| `FileFolderTests` | 19 | `files-final.log` |
| `SessionPanelGalleryTests` | 1 | `gallery-final.log` |
| `GitViewTests` package suite | 178 | `git-final.log` |

The native behavioral classes total **121 passed**: panel 22, Git/Changes 80,
Files 19. The package total includes `GitRepositoryStateTests` **17/17** and
`GitStateWatchTests` **1/1** (including ordinary saves and linked-worktree
notifications). The earlier full package run also passed 178/178
(`git-full.log`); its final repeat covers the discovery-mode addition.
There are no helper or wire changes, so those suites were not rerun.

### Screenshots and final review

The gallery passes **1/1**, adding one to the native total (**122/122**).
All 14 regenerated PNGs were opened and visually inspected: both themes of
Agents at 1440 and 1180, narrow pill fallback, Diff, Files, empty Agents and
the main chat beside an open side. Text, controls, tree indentation, status
counts and composer separation remain intact. All 14 PNGs are byte-identical
to the prior gallery (`screenshot-hashes.json` records SHA-256 comparisons);
there is no layout or styling change in this follow-up. The original images
under owner review were preserved.

Directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r1/`.

```text
agents-1440x900-light.png
agents-1440x900-dark.png
agents-1180x800-light.png
agents-1180x800-dark.png
pill-960x700-light.png
pill-960x700-dark.png
diff-1440x900-light.png
diff-1440x900-dark.png
files-1440x900-light.png
files-1440x900-dark.png
empty-1440x900-light.png
empty-1440x900-dark.png
side-open-1600x900-light.png
side-open-1600x900-dark.png
```

Final adversarial self-review checked retained control identity, independent
invalidation triggers, cancellation/publication races, stale folder callbacks,
watcher lifecycle and project boundaries, lazy readers, linked-worktree
compatibility, and count ownership for unreadable replacements. No further
in-scope regression was found. The earlier unrelated topic-search failure and
independent-child-pill owner decision remain recorded above; neither was changed
or treated as resolved. Owner visual approval remains separate.
Generated gallery fixture directories were cleaned by teardown; no additional
DerivedData root or test clone folders were created.


## Destination trust follow-up 2026-10-20

Addresses the P1 review of `09f5d8afb3b9787278851eab3d73b41f39201764`.
The Files callback now calls `WorkspaceModel.openFile(url)` without assigning
the source project's ID. The existing opener canonicalizes the path and resolves
the closest configured destination project, just as Quick Open does. A link in
a trusted project into an untrusted project therefore opens the existing denied
file state and never creates a document reader. The panel's active/root guards
and focus handling remain in place. This is the only production-code change.

### Navigation audit

| Route | Ownership / boundary |
| --- | --- |
| Files pointer, Return and accessibility press | `FolderTreeView` → `FolderBrowser.activate` → the panel's `browser.openFile` → canonical `WorkspaceModel.openFile`, with no project override. All three paths are exercised by the regression. |
| Diff row pointer, Return and accessibility press | `SessionPanelChanges` checks the repository context, then opens/selects the existing `ChangesTab` through `showChanges(in:)`. The tab represents the source Git repository; it does not open the destination as a file. |
| Changes “Open File at Line” menu after a panel Diff row | `GitDiffPiMenu` → `ChangesTab.openFile` → `WorkspaceModel.openChangesFile` → canonical `openFile(url, lines:)`. A second regression exercises the actual menu action against the untrusted symlink. |
| Panel folder selector and Files folder rows | Select an existing project root or lazily navigate folders. Neither creates a `FileTab`. The panel adds no file context menu or Finder-reveal action. |
| Subsequent FileTab folder/menu opens | Existing `FileFolderNavigation` delegates to `openNearbyFile`, configured by `WorkspaceModel.configureFileNavigation` to call canonical `openFile(url, in:)`. Existing Show in Folder Tree and Finder reveal actions do not assign a file's project identity. |

The audit included `SessionFloatingPanel.swift`, `FolderTreeView.swift`,
`FolderBrowser.swift`, `FileFolderNavigation.swift`, `FileFolderMenu.swift`,
`ChangesTab.swift`, `GitDiffTable+Pi.swift`, `GitChangesList.swift`,
`WorkspaceChanges.swift` and `WorkspaceTabs.swift`. No additional override was
found in the panel's file-opening routes. Existing Git repository identity and
read-only behavior are preserved; no Finder action was invoked by the tests.

### Failing first and mutation

Text logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r2/`.
All fixtures are generated temporary files/repositories with isolated native
settings and the in-memory vault. No real credentials, user files or installed
app were used.

- `failing-first.log`: two new tests against the pre-fix production source.
  `testFilesSymlinkUsesTheSameDestinationTrustAsQuickOpen` failed with **15
  assertion failures**: pointer, Return and accessibility each assigned the
  trusted source project, lost the denial reason and created a readable
  `FileDocument`. `testDiffFileMenuResolvesSymlinkDestinationTrust` passed,
  confirming the existing Diff menu already follows the canonical opener.
- The Quick Open baseline really opens the same symlink, then closes its tab.
  Each panel route creates and closes a fresh tab, preventing tab deduplication
  from hiding an incorrect project assignment. URL, project ID/state, denial
  reason, readability and document creation are checked. Trust stays unchanged
  and no helper starts.
- `regression-green.log`: **2/2 passed**, zero failures after removing the
  project override.
- `mutation-source-project.log`: restoring only the source-project override
  made the Files regression fail again with **15 assertion failures**, including
  document creation through all three routes. **1/1 mutation detected**. The
  mutation runner restored the production file in `finally` before final runs.

### Commands

Commands run from this worktree, with the shared full-lane lock held for every
native invocation and released on success or failure. Final serial-lane class
runs are isolated. No new source files were added; the native script regenerates the project.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel

# Failing first and fixed positive control:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelTests/testFilesSymlinkUsesTheSameDestinationTrustAsQuickOpen \
  -only-testing:PiAppTests/SessionPanelTests/testDiffFileMenuResolvesSymlinkDestinationTrust
# Source-project override mutation:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelTests/testFilesSymlinkUsesTheSameDestinationTrustAsQuickOpen

for TEST_CLASS in SessionPanelTests FileFolderTests FileTabTests \
  QuickOpenTests QuickOpenPlacementTests FileReviewStateTests \
  GitWorkingTreeWatcherTests ChangesTabFrameTests GitRepositorySwitchTests \
  GitDiffTableTests; do
  scripts/test-macos.sh -parallel-testing-enabled NO \
    -only-testing:PiAppTests/$TEST_CLASS
done
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ChangesTabTests \
  -only-testing:PiAppTests/GitPanelShownTests \
  -only-testing:PiAppTests/GitPanelRedrawTests \
  -only-testing:PiAppTests/GitPanelAuditTests \
  -only-testing:PiAppTests/GitRenameTests \
  -only-testing:PiAppTests/GitOperationSafetyTests \
  -only-testing:PiAppTests/GitPathBoundaryTests

TEST_RUNNER_PI_SESSION_PANEL_GALLERY="$PI_BUILD_ROOT/screenshots/review-r2" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelGalleryTests

swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter GitViewTests
swift test --package-path packages/bello-views \
  --scratch-path "$PI_BUILD_ROOT/views" --filter FileFinderTests
```

The loop lists the individual native commands; the evidence runner acquires
and releases the shared lock around each one. `run-native.py`,
`run-native-final.py` and `mutate-trust.py` are retained in the evidence folder.
Quick Open initially ran together with its placement class (both passed);
they were rerun separately after checking the lane classifier. Only the
separate final runs count below. All native logs record their exact command.

### Restored validation

All **214 native tests passed**, with **0 failures and 0 skips**. Behavioral
coverage is panel **24**, Files/Quick Open **73**, Git/Changes **116**, plus the
one gallery test. Repeated positive controls and the initial combined Quick
Open invocation are excluded.

| Suite / class | Passed | Text log |
| --- | ---: | --- |
| `SessionPanelTests` | 24 | `panel-final.log` |
| `FileFolderTests` | 19 | `files-final.log` |
| `FileTabTests` | 16 | `file-tab-final.log` |
| `QuickOpenTests` | 17 | `quick-open-isolated-final.log` |
| `QuickOpenPlacementTests` | 1 | `quick-open-isolated-final.log` |
| `FileReviewStateTests` | 20 | `file-review-final.log` |
| `GitWorkingTreeWatcherTests` | 17 | `watcher-final.log` |
| `ChangesTabTests` | 8 | `git-app-final.log` |
| `GitPanelShownTests` | 13 | `git-app-final.log` |
| `GitPanelRedrawTests` | 4 | `git-app-final.log` |
| `GitPanelAuditTests` | 8 | `git-app-final.log` |
| `GitRenameTests` | 6 | `git-app-final.log` |
| `GitOperationSafetyTests` | 12 | `git-app-final.log` |
| `GitPathBoundaryTests` | 5 | `git-app-final.log` |
| `ChangesTabFrameTests` | 7 | `changes-frames-final.log` |
| `GitRepositorySwitchTests` | 17 | `repository-switch-final.log` |
| `GitDiffTableTests` | 19 | `diff-table-final.log` |
| `SessionPanelGalleryTests` | 1 | `gallery-final.log` |
| `GitViewTests` package suite | 178 | `git-final.log` |
| `FileFinderTests` package suite | 38 | `finder-final.log` |

Package totals: **216 passed, 0 failures, 3 skips**. The three skipped cases
are the existing opt-in `FileFinderPerformanceTests` (100,000 / 500,000-file
benchmarks requiring `FINDER_PERF=1`). The Git total includes all **17/17**
`GitRepositoryStateTests` and **1/1** `GitStateWatchTests`, retaining the prior
round's regression coverage. No helper or wire behavior changed, so their
suites were not rerun. No unrelated test failure occurred in these final runs.

### Screenshots and adversarial self-review

The gallery passed **1/1**. All **14/14 PNGs are byte-identical** to the prior
`review-r1` gallery, verified by SHA-256 in `screenshot-hashes.json`. Every image
was opened and visually inspected: both themes of Agents at 1440 and 1180,
Diff, Files with expanded folders, the narrow pill, empty Agents and the main
chat beside the open side. Panel/transcript/composer separation, text wrapping,
tab labels, rows and contrast are intact. The screenshots already under owner
review are preserved. This fix changes destination trust handling, with no
panel layout or styling change.

Directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r2/`.

```text
agents-1440x900-light.png
agents-1440x900-dark.png
agents-1180x800-light.png
agents-1180x800-dark.png
diff-1440x900-light.png
diff-1440x900-dark.png
files-1440x900-light.png
files-1440x900-dark.png
pill-960x700-light.png
pill-960x700-dark.png
empty-1440x900-light.png
empty-1440x900-dark.png
side-open-1600x900-light.png
side-open-1600x900-dark.png
```

Adversarial self-review checked the canonical ownership lookup, closest-root
selection, absence of source-project overrides, fresh tabs in each regression
route, the denied document getter, the Diff menu's end-to-end model callback,
existing root/active guards, and subsequent folder/menu navigation. No new
in-scope issue was found. The production diff is one removed argument; neither
the shared opener nor trust policy was changed. Previous unrelated topic-search
failure and independent-child-pill owner decision remain recorded above and
are not treated as resolved. Owner visual feedback remains pending.

Gallery fixture directories were removed by teardown. No native clone folders
or extra DerivedData roots remain. All evidence and builds use this workstream's
build root; the shared lane lock was released after each run.

## Change-count options follow-up 2026-10-20

The round-4 review found that summary numstats forced rename detection while
status respected `status.renames=false`. A moved file therefore appeared as
separate added/deleted rows but inherited counts from a grouped rename.

`GitChangeOptions` now belongs to the status snapshot. One bounded configuration
read per status refresh resolves `status.renames` / `diff.renames` and the
corresponding rename limits, preserving status's first-diff-fallback behavior.
The configuration-scope follow-up below changes this to the requested final
value per key. Both batched
numstats and the selected-file preview use that snapshot and the same diff
argument builder. Configuration is reread on refresh; no repository-options
cache or per-row configuration process is added. The default rename limit is
Git's 1,000 candidates. Explicit similarity travels with the snapshot; tests
exercise 60% and 90%, including copies at 90%. This is an internal read option,
not a new preference or UI control.

The shared reader uses short gitlink patches, fixed parser prefixes, invisible
intent-to-add index entries and no external diff/text-conversion commands.
Submodule ignores follow status: worktree defaults include dirty/untracked
submodules, per-submodule ignores still apply, and manually staged gitlinks
remain visible even when their worktree is ignored. Numstat's zero-count dirty
gitlink record is corrected from porcelain's dirty-submodule metadata to the
short patch's one removed/one added gitlink line; this adds no patch read.
The generated submodule fixture covers an untracked-only dirty module, its
configured ignore, and an advance staged while `diff.ignoreSubmodules=all`
and `diff.submodule=log` are configured.

The status precedence and side-specific submodule rules were checked against
[Git 2.39.5's status configuration reader](https://github.com/git/git/blob/v2.39.5/builtin/commit.c#L1372-L1389)
and [status collection](https://github.com/git/git/blob/v2.39.5/wt-status.c#L557-L621).
The Mac runs Apple Git 2.39.5. Similarity uses Git's percentage option documented
in [git diff](https://git-scm.com/docs/git-diff#Documentation/git-diff.txt---find-renamesn).

Copy detection passes the source and destination to Git, then the controller
publishes only the selected file. The source has its own status row and must
not appear as a second preview under the copy's counts. Files/Changes canonical
opening and trust checks from round 3 remain intact. Existing untracked safe
reads, the 4 MiB bound, cancellation, and the choice of working-tree versus
staged counts are preserved. There is still one status read and two batched
numstats for a nonempty summary, plus the single configuration read; no history
or per-file patch is loaded by the compact panel.

### Failing first and mutation evidence

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r3/`.

Before the production change, the three requested rename/copy/similarity
regressions failed: **3 tests, 10 assertion failures**, `counts-red.log`.
The custom-similarity red test obtained its status directly from
`git status --porcelain=v2 -z --find-renames=90%`; after adding the shared read
option, it uses the real `GitService.status` entry point with the same threshold
and assertions. Status-specific overrides and the `diff.renames` fallback both
have coverage. Every row is compared with the parsed patch it opens and with
independent expected counts, so agreement between two incorrect readers cannot
pass the test.

The initial submodule regression failed too (**1 test, 1 assertion failure**,
`submodule-red.log`). After sharing options, the three rename cases passed but
the submodule test exposed numstat's zero-count dirty gitlink
(`counts-first-green.log`: **3 passed, 1 failed**). The status-metadata correction
passes it. The focused summary run then passed **9/9** (`counts-green.log`),
and the expanded copy-preview check passed **1/1** (`copy-preview-green.log`).
Two test-authoring compile issues (an omitted `binary` argument and a Swift
actor-isolation annotation) were corrected before these behavioral results.

All nine independent mutations were restored. Each fails an XCTest assertion
or unwrap, not compilation:

| Mutation | Targeted tests / assertion failures | Log |
| --- | ---: | --- |
| Restore forced renames in numstat | 3 / 10 | `mutation-summary-renames.log` |
| Preview ignores the status options | 1 / 2 | `mutation-preview-options.log` |
| Counts reread config instead of using the status snapshot | 1 / 2 | `mutation-snapshot.log` |
| Drop status's worktree submodule-ignore default | 1 / 1 | `mutation-submodule-ignore.log` |
| Hide staged gitlinks using worktree ignores | 1 / 1 | `mutation-staged-submodule.log` |
| Use submodule logs instead of the shared short patch | 1 / 1 | `mutation-submodule-format.log` |
| Drop dirty-gitlink count correction | 1 / 1 | `mutation-dirty-submodule.log` |
| Include the copy source in the selected preview | 1 / 2 | `mutation-copy-preview.log` |
| Allow text conversion in the shared reader | 1 / 1 | `mutation-text-converter.log` |

`run-mutations.py` records the exact commands and restores each source file in
`finally`; `mutation-summary.json` records exits/counts. The initial log checker
mistook an `XCTUnwrap` failure for missing evidence; it was corrected to accept
both XCTest failure kinds and resumed after the six already-completed mutations.

The package regression commands use this form (the exact filters are in the
logs and mutation runner):

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter 'GitRepositoryStateTests/testSummaryMatchesOpenedRows'
```

### Restored validation

The full Git package suite passed **184 tests, 0 failures, 0 skips**, including
all **23 GitRepositoryStateTests**, in 461.310 seconds (`git-package-final.log`):

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter GitViewTests
```

Native validation passed **233 tests, 0 failures, 1 skip** across the focused
classes below. `SessionPanelTests` clicks every disabled-rename and copy row,
checks its accessibility count label, opens the real Changes tab, and compares
that tab's selected patch and counts. Across the package and native runs, the
prior accessibility, repository-discovery, safe-untracked, canonical file-trust
and panel regressions pass.
The skip is the existing `GitCommitBrowsingTests` real-repository benchmark;
`PI_APP_GIT_BENCH_REPO` was intentionally unset. No unrelated test failed.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `changes-frames-final.log` |
| ChangesTabTests | 8 | 0 | `git-readers-final.log` |
| GitBranchesInteractionTests | 20 | 0 | `git-actions-final.log` |
| GitChangelistReadTests | 2 | 0 | `git-readers-final.log` |
| GitCommitBrowsingTests | 3 | 1 | `git-actions-final.log` |
| GitConfirmationSheetTests | 7 | 0 | `git-actions-final.log` |
| GitDiffTableTests | 19 | 0 | `diff-table-final.log` |
| GitDiscardQuestionTests | 2 | 0 | `git-actions-final.log` |
| GitHistoryFilterTests | 14 | 0 | `git-actions-final.log` |
| GitHunkReviewTests | 9 | 0 | `git-actions-final.log` |
| GitIntegratedHistoryTests | 10 | 0 | `git-actions-final.log` |
| GitOperationSafetyTests | 12 | 0 | `git-actions-final.log` |
| GitPanelAuditTests | 8 | 0 | `git-readers-final.log` |
| GitPanelLayoutTests | 4 | 0 | `git-readers-final.log` |
| GitPanelNarrowParityTests | 8 | 0 | `git-narrow-final.log` |
| GitPanelRedrawTests | 4 | 0 | `git-readers-final.log` |
| GitPanelShownTests | 13 | 0 | `git-readers-final.log` |
| GitPanelTimingTests | 4 | 0 | `git-timing-final.log` |
| GitPanelWidthTests | 3 | 0 | `git-readers-final.log` |
| GitPathBoundaryTests | 5 | 0 | `git-readers-final.log` |
| GitRenameTests | 6 | 0 | `git-readers-final.log` |
| GitRepositorySwitchTests | 17 | 0 | `repository-switch-final.log` |
| GitToolTests | 5 | 0 | `git-readers-final.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | `watcher-final.log` |
| SessionPanelGalleryTests | 1 | 0 | `gallery-final.log` |
| SessionPanelTests | 25 | 0 | `panel-final.log` |

Exact native runner command:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r3/run-native-final.py
```

The runner invoked these class groups, in order. Each corresponding log starts
with the complete expanded `PI_BUILD_ROOT=... scripts/test-macos.sh
-parallel-testing-enabled NO -only-testing:PiAppTests/<Class> ...` command.
`run-native.py` takes/releases the shared full-lane lock for each invocation,
including the gallery. Serial classes run alone.

```text
python3 run-native.py panel-final.log SessionPanelTests
python3 run-native.py git-readers-final.log ChangesTabTests GitToolTests GitRenameTests GitPathBoundaryTests GitPanelAuditTests GitPanelShownTests GitPanelRedrawTests GitChangelistReadTests GitPanelLayoutTests GitPanelWidthTests
python3 run-native.py git-actions-final.log GitBranchesInteractionTests GitHistoryFilterTests GitHunkReviewTests GitIntegratedHistoryTests GitCommitBrowsingTests GitOperationSafetyTests GitConfirmationSheetTests GitDiscardQuestionTests
python3 run-native.py watcher-final.log GitWorkingTreeWatcherTests
python3 run-native.py repository-switch-final.log GitRepositorySwitchTests
python3 run-native.py diff-table-final.log GitDiffTableTests
python3 run-native.py changes-frames-final.log ChangesTabFrameTests
python3 run-native.py git-timing-final.log GitPanelTimingTests
python3 run-native.py git-narrow-final.log GitPanelNarrowParityTests
python3 run-native.py gallery-final.log SessionPanelGalleryTests
```

The gallery additionally sets
`TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r3`.
All native tests use the isolated test host and generated data. No installed
app, real preferences/chats/Keychain, paid call, named result bundle, or release
operation was used. Helper and wire code did not change, so those suites were
not rerun. The lead still runs the full merged gate.

### Screenshots and final review

All **16 PNGs** were opened and visually inspected. The original 14 scenes are
byte-identical to `review-r2`, verified by `screenshot-hashes.json`. Two new
light/dark scenes show `status.renames=false`: `docs/guide.md` is an addition
with `+3 −0`, and `docs/old-guide.md` is a deletion with `+0 −3`. Row labels,
counts, card bounds, transcript wrapping and composer separation are intact.
The existing shots under owner review are preserved; no layout or styling
change was needed.

Directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r3/`.

```text
agents-1440x900-light.png
agents-1180x800-light.png
pill-960x700-light.png
diff-1440x900-light.png
diff-no-renames-1440x900-light.png
files-1440x900-light.png
empty-1440x900-light.png
side-open-1600x900-light.png
agents-1440x900-dark.png
agents-1180x800-dark.png
pill-960x700-dark.png
diff-1440x900-dark.png
diff-no-renames-1440x900-dark.png
files-1440x900-dark.png
empty-1440x900-dark.png
side-open-1600x900-dark.png
```

Adversarial self-review traced status → summary and status → selected preview
for both index/worktree sides; checked configuration precedence, copy source
context, custom similarity, submodule ignores and text conversion; verified
that no command uses shell-interpolated paths; and rechecked cancellation,
bounded reads, prior trust routing and cleanup. The shared options do not freeze
repository contents against external writers; normal refresh still supplies
new status and counts. No new in-scope issue remained. Earlier unrelated
Topic-search failure and the independent-child-pill **needs owner decision**
remain recorded above. Owner visual feedback is pending.

All gallery fixture directories were removed by teardown. No native clone
folders or extra DerivedData roots remain under this build root. Every owned
lane lock was released after its run; other workstreams' locks were untouched.
`git diff --check` passes. `NEXT-RELEASE.md` has the concise follow-up entry.

## Configuration-scope follow-up 2026-10-20

The round-5 request explicitly requires retaining the final configured value
for each key before applying the `status.*`-over-`diff.*` fallback. The snapshot
now does that. Its existing, single `git config -z --get-regexp` call has no
scope restriction: Git evaluates scopes, includes and conditional includes and
emits the values in its configuration order. The snapshot only retains the
last record per key, then resolves the status-specific fallback once for both
rename detection and rename limits. Status, the panel's batched counts and
selected Changes previews still share those options. No additional process,
cache, per-file read, permission path or UI layout was added.

### Raw-status compatibility — needs owner decision

**Needs owner decision:** the request's final-value policy and exact parity
with unmodified `git status` conflict on this Mac. The branch implements the
explicit final-value policy. With no `status.*` override, Apple Git 2.39.5
(Apple Git-154) takes the **first** `diff.renames` / `diff.renameLimit` value
in `status`, although `git config --get` returns the final configured value.
This is also explicit in the
[upstream 2.39.5 status reader](https://github.com/git/git/blob/v2.39.5/builtin/commit.c#L1372-L1389).
Git's configuration documentation describes the
[last-value result and configuration order](https://git-scm.com/docs/git-config#_files).

Generated CLI probes (`config-probe.log`) observed:

| Generated configuration | `git config --get` | Unmodified `git status` |
| --- | --- | --- |
| Global `diff.renames=true`, local `false` | `false` | One rename |
| Local `diff.renames=true`, worktree `false` | `false` | One rename |
| Global `diff.renameLimit=1`, local `1000` | `1000` | Three additions and three deletions |

Before changing production code, comparisons against unmodified status passed
in **2 package tests** (six scope/limit combinations) and **1 native panel
test** (two worktree combinations). Evidence: `raw-status-baseline.log` and
`raw-status-native-baseline.log`. Thus the review's claimed raw-status
regression was not reproduced on the required system Git. The final tests
instead ask `git config --get` for the effective value and pass it explicitly
to `git -c status.renames=… status` or
`git -c status.renameLimit=… status`. They do not reuse the production snapshot
or argument builder as their oracle. Tests with explicit `status.*` overrides
also compare directly with unmodified status.

Accepting this policy makes both app views respect the final diff fallback,
but intentionally differs from the raw command in the conflicting cases
above. Preserving raw-status parity would require keeping Git's first-fallback
behavior instead. A clarification was raised during implementation; no owner
answer has been assumed. This choice remains flagged for review.

### Failing-first and mutation evidence

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r4/`.

The tests cover global true/local false, local true/worktree false, rename
limits 1→1000 and 1000→1 in both scope pairs, a conditional include selecting
copy detection, and repeated `status.*` overrides across all three scopes.
The rename-limit fixture uses three inexact moves with different basenames;
the oracle asserts three renames versus six separate rows so the limit really
changes grouping. Both the summary-only controller and regular Changes
controller must match Git's requested grouping, and each panel row's counts
must equal its selected preview. The native regression clicks the actual
panel rows and checks the existing Changes tab.

Before the production fix:

- `effective-config-red.log`: **4 package tests executed, 3 failed, 1 passed;
  13 assertion failures**. Rename, rename-limit and included-copy grouping
  failed. Explicit status overrides already passed.
- `panel-effective-red.log`: **1 native test failed, 5 assertion failures**,
  including the absent deleted-file row.

After the fix, the same four package tests passed (`effective-config-green.log`).
The full panel class subsequently passed all 26 tests (`panel-final.log`).

| Deliberate mutation | Failed tests / assertions | Text log |
| --- | --- | --- |
| Restore the first `diff.renames` fallback | 1 / 6 | `mutation-renames-first.log` |
| Restore the first `diff.renameLimit` fallback | 1 / 5 | `mutation-renamelimit-first.log` |
| Prefer `diff.*` over explicit `status.*` | 1 / 4 | `mutation-diff-before-status.log` |

All three mutations failed by assertions, not compilation errors. The runner
restored the production file in `finally` after every mutation, then the
complete focused suites ran against the restored fix.

Exact regression commands, run from the worktree:

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter 'GitRepositoryStateTests/testSummaryAndChanges'
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r4/run-native.py \
  panel-effective-red.log SessionPanelTests/testPanelAndChangesUseEffectiveWorktreeOverrides
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r4/run-mutations.py
```

The mutation runner invokes the same `swift test` command, selecting respectively
`GitRepositoryStateTests/testSummaryAndChangesUseEffectiveRenameConfigurationAcrossScopes`,
`GitRepositoryStateTests/testSummaryAndChangesUseEffectiveRenameLimitAcrossScopes`,
and `GitRepositoryStateTests/testSummaryAndChangesKeepStatusOverridesAcrossScopes`.

The initial raw-status comparisons used these commands before the test methods
were updated to exercise the explicitly effective values:

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter 'GitRepositoryStateTests/testSummaryAndChangesMatchGitStatusAcross'
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r4/run-native.py \
  raw-status-native-baseline.log SessionPanelTests/testPanelAndChangesMatchGitStatusWithWorktreeOverrides
```

### Adversarial self-review

Self-review checked both directions of rename-limit precedence, repeated
status-specific values, a higher-scope diff option that must not replace an
explicit status option, and conditional includes. The oracle uses separate
`git config --get` / `git status` commands and asserts concrete A/D/R/C badges;
it does not compare two copies of the snapshot parser. The raw-status
discrepancy above was verified before choosing the requested final-value
policy, rather than hidden by the normalized oracle.

The final-value map still feeds the same status/numstat/preview snapshot.
Default options, explicit similarity, submodule ignores, bounded reads,
cancellation and canonical file opening were reviewed without further changes.
No additional code issue was found. All new configuration writes are confined
to generated repository fixtures; the global-file override points inside the
fixture's `.git` directory. Existing unrelated findings and pending owner
visual feedback remain recorded in the earlier sections.

### Restored suite results

The full Git package suite passed **188 tests, 0 failures, 0 skips** in
506.387 seconds (`git-package-final.log`):

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter GitViewTests
```

| Package class | Passed |
| --- | ---: |
| GitBlameTests | 13 |
| GitBranchesTests | 21 |
| GitCardShapeTests | 3 |
| GitCommitScopeTests | 18 |
| GitDiffParserTests | 3 |
| GitDiffPrefixTests | 3 |
| GitHistoryQueryTests | 17 |
| GitHistoryWiringTests | 3 |
| GitIndexTransactionTests | 17 |
| GitLiteralPathTests | 8 |
| GitPatchTests | 3 |
| GitRepositoryStateTests | 27 |
| GitRevealTests | 10 |
| GitReviewFindingsTests | 6 |
| GitSafetyTests | 17 |
| GitStashTests | 18 |
| GitStateWatchTests | 1 |

The focused native runs passed **234 tests, 0 failures, 1 skip** across
26 classes. The skip is the existing
`GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested` benchmark,
whose `PI_APP_GIT_BENCH_REPO` opt-in remains unset. Combined restored results:
**422 passed, 0 failed, 1 skipped**.

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `changes-frames-final.log` |
| ChangesTabTests | 8 | 0 | `git-readers-final.log` |
| GitBranchesInteractionTests | 20 | 0 | `git-actions-final.log` |
| GitChangelistReadTests | 2 | 0 | `git-readers-final.log` |
| GitCommitBrowsingTests | 3 | 1 | `git-actions-final.log` |
| GitConfirmationSheetTests | 7 | 0 | `git-actions-final.log` |
| GitDiffTableTests | 19 | 0 | `diff-table-final.log` |
| GitDiscardQuestionTests | 2 | 0 | `git-actions-final.log` |
| GitHistoryFilterTests | 14 | 0 | `git-actions-final.log` |
| GitHunkReviewTests | 9 | 0 | `git-actions-final.log` |
| GitIntegratedHistoryTests | 10 | 0 | `git-actions-final.log` |
| GitOperationSafetyTests | 12 | 0 | `git-actions-final.log` |
| GitPanelAuditTests | 8 | 0 | `git-readers-final.log` |
| GitPanelLayoutTests | 4 | 0 | `git-readers-final.log` |
| GitPanelNarrowParityTests | 8 | 0 | `git-narrow-final.log` |
| GitPanelRedrawTests | 4 | 0 | `git-readers-final.log` |
| GitPanelShownTests | 13 | 0 | `git-readers-final.log` |
| GitPanelTimingTests | 4 | 0 | `git-timing-final.log` |
| GitPanelWidthTests | 3 | 0 | `git-readers-final.log` |
| GitPathBoundaryTests | 5 | 0 | `git-readers-final.log` |
| GitRenameTests | 6 | 0 | `git-readers-final.log` |
| GitRepositorySwitchTests | 17 | 0 | `repository-switch-final.log` |
| GitToolTests | 5 | 0 | `git-readers-final.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | `watcher-final.log` |
| SessionPanelGalleryTests | 1 | 0 | `gallery-final.log` |
| SessionPanelTests | 26 | 0 | `panel-final.log` |

Exact native runner command:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r4/run-native-final.py
```

The individual invocations below are equivalent when launched from the
evidence directory. The runner uses absolute script paths and keeps the
worktree as its working directory, taking and releasing the shared full-lane
lock separately for each run:

```sh
python3 run-native.py panel-final.log SessionPanelTests
python3 run-native.py git-readers-final.log ChangesTabTests GitToolTests GitRenameTests GitPathBoundaryTests GitPanelAuditTests GitPanelShownTests GitPanelRedrawTests GitChangelistReadTests GitPanelLayoutTests GitPanelWidthTests
python3 run-native.py git-actions-final.log GitBranchesInteractionTests GitHistoryFilterTests GitHunkReviewTests GitIntegratedHistoryTests GitCommitBrowsingTests GitOperationSafetyTests GitConfirmationSheetTests GitDiscardQuestionTests
python3 run-native.py watcher-final.log GitWorkingTreeWatcherTests
python3 run-native.py repository-switch-final.log GitRepositorySwitchTests
python3 run-native.py diff-table-final.log GitDiffTableTests
python3 run-native.py changes-frames-final.log ChangesTabFrameTests
python3 run-native.py git-timing-final.log GitPanelTimingTests
python3 run-native.py git-narrow-final.log GitPanelNarrowParityTests
python3 run-native.py gallery-final.log SessionPanelGalleryTests
```

The runner executes `scripts/test-macos.sh -parallel-testing-enabled NO`,
appending `-only-testing:PiAppTests/<Class>` for every named class, with
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel`.
The gallery also sets
`TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r4`.
`native-restored-counts.json`, `package-restored-counts.json` and
`native-final-summary.json` contain the per-class and per-invocation totals.
There were no unrelated test failures in these restored runs.

### Regenerated screenshots and cleanup

All **16 PNGs** were regenerated under the shared lane lock and individually
opened and inspected. All are byte-for-byte identical to the preceding
`review-r3` set (`screenshot-hashes.json`). The panel's spacing, text wrapping,
tabs, rows, empty state, narrow fallback and adjacent side conversation remain
unchanged in both themes; no visual correction was needed.

Directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r4/`

```text
agents-1440x900-light.png
agents-1440x900-dark.png
agents-1180x800-light.png
agents-1180x800-dark.png
diff-1440x900-light.png
diff-1440x900-dark.png
diff-no-renames-1440x900-light.png
diff-no-renames-1440x900-dark.png
files-1440x900-light.png
files-1440x900-dark.png
empty-1440x900-light.png
empty-1440x900-dark.png
pill-960x700-light.png
pill-960x700-dark.png
side-open-1600x900-light.png
side-open-1600x900-dark.png
```

Gallery fixture directories were removed by teardown; no native clone
directories remain (`cleanup-check.json`). Builds reused this workstream's
existing `views` and `native-tests` roots. Every owned lane lock was released;
the wait behind another workstream's full package run did not touch its lock.
The isolated native test host and generated fixtures were used throughout.
Helper and wire code were unchanged. `git diff --check` passes.
