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

### Raw-status compatibility — resolved in the next follow-up

The lead resolved this conflict in the next follow-up: raw `git status` is
now authoritative, including Apple Git’s first-value behavior. The evidence
below records the previous round and its now-reverted policy.

**Historical decision request:** the request's final-value policy and exact parity
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


## Git-owned grouping and counts follow-up 2026-10-20

The lead’s decision resolves the preceding rename-precedence question: Bello
must match the installed Git’s raw status, including Apple Git’s first-value
fallback. This round removes the configuration reader/map and all grouping
`-c` overrides. The same raw status feeds Changes and the session panel.
Explicit similarity remains a status test seam; its reported rows, not a
configuration interpretation, determine each subsequent diff.

### Implementation and boundaries

- Ordinary tracked rows use cached/worktree `git diff --numstat -z` with
  rename detection disabled, so separately reported additions/deletions stay
  separate. A reported R/C row opens its two paths with pair detection; a
  staged rename with later working-tree edits opens only the new path on
  that working-tree side. Copy previews still exclude the source’s own row.
- Rename/copy counts also batch by side, but are accepted only if numstat’s
  source **and** destination match the status pair. Ambiguous or changed
  pairings fall back to the exact two-path request the preview uses. No
  rename or rename-limit config is read or overridden by Bello.
- Untracked contents first pass `GitPatchFile.read`: regular files only,
  no symlinks in any component, no files over 4 MiB. Git sees private copies
  of those bounded bytes, so replacing a live path after validation cannot
  redirect its read. Each snapshot holds at most 32 MiB of contents plus
  32 MiB of relevant attributes; cancellation/error/success remove it.
- `git diff --no-index --numstat` counts the copies against `/dev/null`.
  Files sharing a top-level directory batch against an empty directory,
  which emits the same `/dev/null` pairs. Root-level files use individual
  calls through the existing eight-process gate. Relative names stay intact
  for anchored attributes. The real Git directory/config/info attributes
  and bounded copies of ancestor `.gitattributes` retain Git’s classification.
  For a relative `core.attributesFile`, Git supplies its effective path via
  `git config --path --get`; only that path is anchored to the original root
  before changing the private copy’s cwd. Rename/limit settings are never
  collected or overridden. Unreadable/oversized attributes make affected counts unavailable. No
  working-tree file, index, configuration or repository metadata is written.
- Git owns binary probing, `core.bigFileThreshold`, driver attributes and
  every count. The whole-file NUL/line-count heuristic and dirty-gitlink
  count adjustment are gone. Git itself reports 0/0 for a dirty-only gitlink
  even though its short patch adds a `-dirty` suffix; the summary keeps 0/0.
  Tracked counts remain Git reads even for files larger than the untracked
  safe-reader limit. Untracked replacements clear staged counts first.
- UI layout, navigation, trust checks and family behavior are unchanged.
  Only counts/grouping in the affected configuration/content cases change.

Git’s documented [no-index and numstat behavior](https://git-scm.com/docs/git-diff)
and its [binary probe](https://github.com/git/git/blob/v2.39.5/xdiff-interface.c#L181-L187)
were checked against generated fixtures on the installed Git. The independent
oracle invokes Git directly; it does not use Bello’s option builder. Parity
covers raw multi-scope rename/limit precedence, includes, explicit status
options, copies, custom similarity, staged+unstaged entries, switched rename
pairs, attributes, late/early NUL, empty/no-final-newline files, large tracked
files, unsafe untracked replacements and bounded snapshot splitting.

### Failing-first and mutation evidence

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r5/`.

- `parity-red.log`: four tests fail with 43 assertions against the previous
  implementation: raw status differs under conflicting scopes and untracked
  classification differs for late NUL/attributes.
- `attributes-bound-red.log`: one test, one expected failure after replacing
  the heuristic, proving that skipping an oversized attributes file would
  silently change classification. Affected counts are now unavailable.
- `parity-first-green.log`: initial restored class run, 29 passed/1 failed.
  The sole failure expected the removed 1/1 dirty-gitlink heuristic. Its
  oracle now checks Git’s actual 0/0 numstat rather than invented counts.
- `parity-green.log`: 19 summary tests pass. `batch-green.log`: two additional
  tests pass for renamed destinations changing after status and snapshot
  splitting/cleanup. Final full-suite results below supersede these focused
  intermediate runs.

| Mutation | Tests failing / assertions | Log |
| --- | ---: | --- |
| Reintroduce a status rename override | 1 / 6 | `mutation-grouping.log` |
| Collapse separate A/D numstats with rename detection | 1 / 1 | `mutation-ordinary-renames.log` |
| Accept a batched pair by destination alone | 1 / 4 | `mutation-pair-identity.log` |
| Reintroduce the whole-file NUL heuristic | 1 / 2 | `mutation-binary-heuristic.log` |
| Replace the no-follow bounded reader with a URL read | 2 / 3 | `mutation-safe-reader.log` |
| Ignore unavailable attributes | 1 / 1 | `mutation-attribute-bound.log` |

The first six controls failed behavior assertions, not compilation, and were
restored in `finally`. `mutation-summary.json` preserves the results. The
final attributes test also includes a malformed, ignored rule: valid numstat
output is retained despite Git’s warning, just as the opened diff is.

### Adversarial self-review

Reviewed status/numstat/preview arguments, per-side R/C handling, source/destination
validation of batch output, conflicting scopes and includes, literal paths,
untracked replacement precedence, anchored/driver/info attributes, threshold
and binary behavior, snapshot limits, no-follow reads, cancellation and cleanup.
The only config grouping authority is now Git status. Every count comes from
Git numstat; unavailable input never retains the opposite side’s tracked count.
Snapshots keep content reads inside the source project even if live paths are
replaced after validation. External diff and text converters remain disabled.
No panel opener or trust-boundary code changed. Earlier unrelated topic-search
and independent-child-pill findings remain historical/out of scope; no new
product decision is required for this correction.

The first 500-file measurement met the refresh target, but showed 22–27% cold
opening overhead for mixed/untracked fixtures. The final reader starts the
independent untracked work alongside tracked reads; superseded work still uses
the existing cancellation and process limits. The pre-tuning measurements are
retained as `benchmark/before-overlap-{measurements,summary}.json`.

Self-review additionally reproduced a relative `core.attributesFile` resolving
from the private snapshot instead of the original root. The new regression
checks global/local and local/worktree precedence against direct Git numstat:
`relative-attributes-red.log`, one test/two expected assertions; the fix and
existing attribute test pass 2/2 in `relative-attributes-green.log`. Removing
only the path anchoring fails the same two assertions in
`mutation-relative-attributes.log` (the seventh mutation). This control used
a temporary source copy with the existing Swift scratch root, to avoid
mutating sources during queued native builds; the copy was deleted in
`finally`. No extra DerivedData tree was created.

### 500-file measurement

Baseline: the actual `GitController`/`GitService` sources from fetched
`origin/dev/next` at `649ea623291c9417443d61d3bb55314d8a2f5d9a`, compiled with
`xcrun swiftc -O -parse-as-library -swift-version 6` alongside the final panel
reader. Both executables use the same generated repositories and isolated Git
environment. This measures controller refresh through completion, including
its readers/watch setup, not AppKit painting. The shared lane lock covers the
measurements. There are three alternating baseline/panel process pairs per
fixture, each with a first opening and nine refreshes: 27 refresh samples and
three opening samples per implementation/fixture. Every panel sample verifies
500 rows and 500 counts, with no notice/error.

Apple Git 2.39.5 (Git-154), Apple Swift 6.0.2, macOS 14.8, arm64.
The harness, build commands, fixture generator, raw samples and baseline ref
are in `evidence/review-r5/benchmark/`; `build.py`, `Measure.swift`, `run.py`,
`measurements.json`, `summary.json` and `baseline-ref.txt` reproduce the check.
It reuses the existing Swift module cache and creates no DerivedData copy.

| Fixture | Changes refresh | Panel refresh | Change | Changes opening | Panel opening |
| --- | ---: | ---: | ---: | ---: | ---: |
| 500 tracked edits | 730.1 ms | 464.9 ms | -36.3% | 592.1 ms | 443.8 ms |
| 350 edits + 50 renames + 50 staged additions + 50 untracked files | 726.5 ms | 551.4 ms | -24.1% | 597.3 ms | 532.2 ms |
| 500 untracked files in one directory | 725.2 ms | 668.5 ms | -7.8% | 592.4 ms | 658.0 ms |

All measured **refreshes meet the requested ~10% budget**, running 7.8–36.3%
faster than the baseline. First opening is reported separately: the all-untracked
fixture is 65.7 ms / 11.1% slower; the other two are faster. This is a measurement
of the listed layouts, not a guarantee for every repository: root-level
untracked files require individual no-index calls to retain anchored attribute
semantics. No line-count or binary heuristic is substituted to improve timing.

### Restored validation

Final Git package command:

```sh
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter GitViewTests
```

**196 passed, 0 failed, 0 skipped**, 17 classes, 470.156 seconds,
`package-git-final.log`. Earlier complete sweeps passed 195/195 before the
read overlap and before the final relative-attributes regression;
`package-git-before-overlap.log` and
`package-git-before-relative-attributes.log` retain them. Final per-class
counts are in `package-restored-counts.json`:

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
| GitRepositoryStateTests | 35 |
| GitRevealTests | 10 |
| GitReviewFindingsTests | 6 |
| GitSafetyTests | 17 |
| GitStashTests | 18 |
| GitStateWatchTests | 1 |

Native focused runs: **234 passed, 0 failed, 1 existing opt-in skip**, 26
classes. `GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested`
skipped because `PI_APP_GIT_BENCH_REPO` was unset. Every other requested test
ran, including the env-enabled gallery. `native-restored-counts.json` lists
the latest results per class; the panel and reader groups were rerun after
the read-overlap tuning, and the panel was rerun after relative-attribute
anchoring. The full Git package sweep above ran on that final source.

All native invocations reused this workstream's `native-tests` build root,
ran with `-parallel-testing-enabled NO`, and held/released the shared lane
lock in `run-native.py`'s `finally`. Focus/timing/gallery classes ran in
separate invocations. Exact final commands (from each log's `COMMAND` line,
with the gallery environment made explicit):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ChangesTabTests \
  -only-testing:PiAppTests/GitToolTests \
  -only-testing:PiAppTests/GitRenameTests \
  -only-testing:PiAppTests/GitPathBoundaryTests \
  -only-testing:PiAppTests/GitPanelAuditTests \
  -only-testing:PiAppTests/GitPanelShownTests \
  -only-testing:PiAppTests/GitPanelRedrawTests \
  -only-testing:PiAppTests/GitChangelistReadTests \
  -only-testing:PiAppTests/GitPanelLayoutTests \
  -only-testing:PiAppTests/GitPanelWidthTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitBranchesInteractionTests \
  -only-testing:PiAppTests/GitHistoryFilterTests \
  -only-testing:PiAppTests/GitHunkReviewTests \
  -only-testing:PiAppTests/GitIntegratedHistoryTests \
  -only-testing:PiAppTests/GitCommitBrowsingTests \
  -only-testing:PiAppTests/GitOperationSafetyTests \
  -only-testing:PiAppTests/GitConfirmationSheetTests \
  -only-testing:PiAppTests/GitDiscardQuestionTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitRepositorySwitchTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitDiffTableTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ChangesTabFrameTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitPanelTimingTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitPanelNarrowParityTests

TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r5 PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SessionPanelGalleryTests

```

| Native class | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | `changes-frames-final.log` |
| ChangesTabTests | 8 | 0 | `git-readers-restored.log` |
| GitBranchesInteractionTests | 20 | 0 | `git-actions-final.log` |
| GitChangelistReadTests | 2 | 0 | `git-readers-restored.log` |
| GitCommitBrowsingTests | 3 | 1 | `git-actions-final.log` |
| GitConfirmationSheetTests | 7 | 0 | `git-actions-final.log` |
| GitDiffTableTests | 19 | 0 | `diff-table-final.log` |
| GitDiscardQuestionTests | 2 | 0 | `git-actions-final.log` |
| GitHistoryFilterTests | 14 | 0 | `git-actions-final.log` |
| GitHunkReviewTests | 9 | 0 | `git-actions-final.log` |
| GitIntegratedHistoryTests | 10 | 0 | `git-actions-final.log` |
| GitOperationSafetyTests | 12 | 0 | `git-actions-final.log` |
| GitPanelAuditTests | 8 | 0 | `git-readers-restored.log` |
| GitPanelLayoutTests | 4 | 0 | `git-readers-restored.log` |
| GitPanelNarrowParityTests | 8 | 0 | `git-narrow-final.log` |
| GitPanelRedrawTests | 4 | 0 | `git-readers-restored.log` |
| GitPanelShownTests | 13 | 0 | `git-readers-restored.log` |
| GitPanelTimingTests | 4 | 0 | `git-timing-final.log` |
| GitPanelWidthTests | 3 | 0 | `git-readers-restored.log` |
| GitPathBoundaryTests | 5 | 0 | `git-readers-restored.log` |
| GitRenameTests | 6 | 0 | `git-readers-restored.log` |
| GitRepositorySwitchTests | 17 | 0 | `repository-switch-final.log` |
| GitToolTests | 5 | 0 | `git-readers-restored.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | `watcher-final.log` |
| SessionPanelGalleryTests | 1 | 0 | `gallery-final.log` |
| SessionPanelTests | 26 | 0 | `panel-attributes-final.log` |

Helper/wire code was unchanged; those lanes were not required for this round.

### Regenerated screenshots and visual review

Generated **18 PNGs** under:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r5/`.

Every image was opened and inspected. Light/dark Agents, Files, empty,
narrow-pill and side-pane scenes retain readable labels and spacing; the
panel stays beside transcript text and above the composer. The 1180-wide
scene still fits, 960 falls back to the pill, and the 1600-wide side scene
keeps the card on the main conversation. Diff and disabled-renames scenes
retain aligned paths/status/counts. New classification scenes show
`late-nul.txt +4501 −0` and `binary.dat Binary` without clipping or overlap.
All 16 pre-existing scenes are byte-identical to review-r4; the two
classification scenes are new. `screenshot-hashes.json`, `visual-review.json`
and the gallery manifest retain evidence.

```text
agents-1180x800-dark.png
agents-1180x800-light.png
agents-1440x900-dark.png
agents-1440x900-light.png
diff-1440x900-dark.png
diff-1440x900-light.png
diff-classification-1440x900-dark.png
diff-classification-1440x900-light.png
diff-no-renames-1440x900-dark.png
diff-no-renames-1440x900-light.png
empty-1440x900-dark.png
empty-1440x900-light.png
files-1440x900-dark.png
files-1440x900-light.png
pill-960x700-dark.png
pill-960x700-light.png
side-open-1600x900-dark.png
side-open-1600x900-light.png
```

### Cleanup and completion checks

Generated gallery and benchmark fixture directories and the temporary
mutation source copy were removed. No native clone folders remain under
this workstream's build root (`cleanup-check.json`). No extra DerivedData
copy was created. Every owned full-lane lock was released; other workstreams'
locks were left alone. The final diff check passes. The production changes
are confined to the shared Git reader and its selected-diff caller; no
navigation, trust or panel-layout code changed in this round.

## Ordering and repository lifecycle follow-up 2026-10-20

Review base: `18e8d897ea558c238c035158331935a19c4ef682`.
Evidence: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r6/`.
This round also integrates the current `origin/dev/next` into this branch by
merge, as requested by the lead; it does not merge or push into `dev/next`.

### Corrections and path-option audit

All summary numstats use `-O/dev/null`, including ordinary tracked reads,
paired rename/copy batches and their isolated fallback, and untracked private
snapshots. Ordering has no effect on a row's counts. The preview retains its
normal working-tree context. Git documents this flag as the way to cancel
[`diff.orderFile`](https://git-scm.com/docs/git-diff#Documentation/git-diff.txt--Oltorderfilegt),
whose relative paths resolve from the working tree. The regression combines
root/nested untracked files, staged/unstaged rows, global/local and local/worktree
configuration, relative attributes, `diff.relative=true`, and relative external
diff/textconv commands that must remain disabled. Counts are compared with both
an independent Git numstat and the opened preview.

The audit also checked `core.attributesFile` (Git's effective relative path is
already anchored to the original root), ancestor `.gitattributes` (bounded
copies with original relative names), and `info/attributes` (the actual Git
directory). Snapshot commands explicitly supply the original absolute Git
directory and private working tree. Config includes remain Git-owned and are
[relative to their including config file](https://git-scm.com/docs/git-config#_includes),
not the snapshot cwd. `--no-ext-diff` and `--no-textconv` continue to disable
relative helper commands. `diff.relative` is tested from both roots; parser
prefixes remain explicitly controlled. No rename/limit configuration snapshot
or override has returned.

A non-difference Git exit from an untracked count read now propagates failure
instead of becoming an empty dictionary. The summary controller clears stale
counts and publishes a `Counts unavailable` notice on a failed count read;
cancellation retains its existing generation fence. Rows with no count show
`Counts unavailable`, including their tooltip and accessibility label, rather
than an unexplained dash. A subsequent successful refresh clears the notice
and restores counts.

Repository discovery expires on every suspension/reactivation, including a
previously successful discovery; same-project chat changes and folder-browser
publications also invalidate it. A discovery watch is armed before revalidation,
including while the old positive result is still displayed, so a new `.git`
marker cannot fall between the read and starting a stream. A summary controller
that publishes a missing repository notifies the card even when the previous
repository was empty. The card retires that summary, hides Diff, and rearms
discovery. A recreated/initialised repository restores Diff without changing
chats. Files remains available when the project directory still exists; deleting
`.git` does not delete the project files or change file-opening/trust behavior.
The remembered tab is retained while an unavailable tab falls back to Agents.

### Failing first and mutation controls

- `package-red.log`: **2 tests failed, 14 assertions** before the Git fix.
  Relative ordering loses the three untracked paths in each configuration
  scope; a failed count refresh retains old numbers and lacks the explicit
  unavailable notice.
- `package-green.log`: the same **2 tests pass** after the fix.
- `panel-red.log`: **3 tests failed, 14 assertions** before the panel fix.
  Covers positive discovery on collapse/ancestor-hide/disable, the summary's
  missing-repository publication for both empty and nonempty repositories,
  and unavailable-count accessibility. This baseline used the inherited
  40-second eventual timeout; the new removal assertion now uses five seconds.
  Its unusually long 2313.324-second reactivation test duration is retained in
  the text log rather than omitted.
- Mutations run one at a time and restore sources in `finally`. Package
  controls use a temporary GitView source copy with the existing Swift scratch
  root, avoiding interference with native compilation; that copy is deleted.
  Native controls acquire the shared lane before mutating and release it only
  after restoring the source. No extra DerivedData tree is created.
- The first missing-repository mutation was rejected by warnings-as-errors
  because suppressing the callback left its binding unused. That compile-only
  attempt is retained as `mutation-missing-repository-build-rejection.log`
  and is not counted as a detected regression. The corrected control consumes
  the binding while suppressing only the callback.

### Adversarial review

Checked both discovery directions with lazy Agents/Files/Diff selection,
empty status snapshots, stale summary notifications, cancellation tokens,
watch-before-read ordering, hidden/disabled panes and retained per-window tab
selection. Missing-summary notifications are tied to the current view identity;
a retired controller cannot clear a replacement repository. Count errors cannot
retain a previous refresh's values. Attribute, external-command, untracked
bounds and canonical file-opener behavior remain covered by existing regressions.
No new product decision is needed for these corrections.

Self-review reproduced a stale unavailable notice after a successful automatic
refresh (`automatic-recovery-red.log`, one failed assertion). Successful count
publication now clears only its own unavailable notice. The regression awaits
the publication boundary, since an automatic request may be deferred/coalesced
with a watch refresh. The first immediate assertion attempt saw the pending
state (`automatic-recovery-unsettled.log`, two failed assertions); the corrected
wait passes in `automatic-recovery-green.log`. Removing the notice-clear line
fails again in `mutation-automatic-recovery.log`. The earlier full Git sweep
passed 198 tests before this final notice recovery adjustment; its log is
retained as `package-git-before-automatic-recovery.log`.

Six behavioral controls were detected, restored, and followed by validation:

| Mutation | Failed tests | Assertions/errors | Text log |
| --- | ---: | ---: | --- |
| ordering | 1 | 2 | `mutation-ordering.log` |
| failed-counts | 1 | 1 | `mutation-failed-counts.log` |
| automatic-recovery | 1 | 1 | `mutation-automatic-recovery.log` |
| reactivation | 1 | 6 | `mutation-reactivation.log` |
| missing-repository | 1 | 4 | `mutation-missing-repository.log` |
| unavailable-label | 1 | 2 | `mutation-unavailable-label.log` |

### Final pre-merge validation

On the restored final source, the full Git package suite passed **198/198**
(`package-git-premerge.log`, 492.195 seconds). The native panel/Git sweep
passed **237 tests, zero failures**, with one existing opt-in benchmark skip
(`GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested`, no
`PI_APP_GIT_BENCH_REPO`). The panel class was also rerun after the final
notice-recovery adjustment: **29/29** in `panel-green.log`.

| Class | Passed | Failed | Skipped | Text log |
| --- | ---: | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | 0 | `changes-frames-premerge.log` |
| ChangesTabTests | 8 | 0 | 0 | `git-readers-premerge.log` |
| GitBranchesInteractionTests | 20 | 0 | 0 | `git-actions-premerge.log` |
| GitChangelistReadTests | 2 | 0 | 0 | `git-readers-premerge.log` |
| GitCommitBrowsingTests | 3 | 0 | 1 | `git-actions-premerge.log` |
| GitConfirmationSheetTests | 7 | 0 | 0 | `git-actions-premerge.log` |
| GitDiffTableTests | 19 | 0 | 0 | `diff-table-premerge.log` |
| GitDiscardQuestionTests | 2 | 0 | 0 | `git-actions-premerge.log` |
| GitHistoryFilterTests | 14 | 0 | 0 | `git-actions-premerge.log` |
| GitHunkReviewTests | 9 | 0 | 0 | `git-actions-premerge.log` |
| GitIntegratedHistoryTests | 10 | 0 | 0 | `git-actions-premerge.log` |
| GitOperationSafetyTests | 12 | 0 | 0 | `git-actions-premerge.log` |
| GitPanelAuditTests | 8 | 0 | 0 | `git-readers-premerge.log` |
| GitPanelLayoutTests | 4 | 0 | 0 | `git-readers-premerge.log` |
| GitPanelNarrowParityTests | 8 | 0 | 0 | `git-narrow-premerge.log` |
| GitPanelRedrawTests | 4 | 0 | 0 | `git-readers-premerge.log` |
| GitPanelShownTests | 13 | 0 | 0 | `git-readers-premerge.log` |
| GitPanelTimingTests | 4 | 0 | 0 | `git-timing-premerge.log` |
| GitPanelWidthTests | 3 | 0 | 0 | `git-readers-premerge.log` |
| GitPathBoundaryTests | 5 | 0 | 0 | `git-readers-premerge.log` |
| GitRenameTests | 6 | 0 | 0 | `git-readers-premerge.log` |
| GitRepositorySwitchTests | 17 | 0 | 0 | `repository-switch-premerge.log` |
| GitToolTests | 5 | 0 | 0 | `git-readers-premerge.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 | `watcher-premerge.log` |
| SessionPanelGalleryTests | 1 | 0 | 0 | `gallery-premerge.log` |
| SessionPanelTests | 29 | 0 | 0 | `panel-premerge.log` |

Exact final commands (run from this worktree; native runs held the shared
full-lane lock, serial classes in separate invocations):

```sh
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter GitViewTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests -only-testing:PiAppTests/GitToolTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPanelShownTests -only-testing:PiAppTests/GitPanelRedrawTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitPanelLayoutTests -only-testing:PiAppTests/GitPanelWidthTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitHunkReviewTests -only-testing:PiAppTests/GitIntegratedHistoryTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitOperationSafetyTests -only-testing:PiAppTests/GitConfirmationSheetTests -only-testing:PiAppTests/GitDiscardQuestionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r6-premerge PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelGalleryTests
```

The two new package regressions were first run with
`--filter 'GitRepositoryStateTests/(testSummaryIgnoresRelativeOrderingWhilePreservingAttributesAndPreviewCounts|testSummaryCountFailureClearsOldCountsAndReportsUnavailable)'`
using the same package/scratch command. Each package mutation used the
individual test filter; native controls used the corresponding
`-only-testing:PiAppTests/SessionPanelTests/<test method>` with the same native
command and build root. The scripts, exact arguments and text logs are retained
in the evidence folder. One queued wrapper was cancelled before it started any
tests so the remaining native runs could share a continuous lock; see
`queued-run-consolidation.json`. No running test or another workstream's lock
was interrupted.

### Pre-merge screenshots and inspection

Regenerated **22 PNGs** in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r6-premerge/`:

```text
agents-1180x800-dark.png
agents-1180x800-light.png
agents-1440x900-dark.png
agents-1440x900-light.png
diff-1440x900-dark.png
diff-1440x900-light.png
diff-classification-1440x900-dark.png
diff-classification-1440x900-light.png
diff-no-renames-1440x900-dark.png
diff-no-renames-1440x900-light.png
diff-unavailable-1440x900-dark.png
diff-unavailable-1440x900-light.png
empty-1440x900-dark.png
empty-1440x900-light.png
files-1440x900-dark.png
files-1440x900-light.png
pill-960x700-dark.png
pill-960x700-light.png
repository-removed-1440x900-dark.png
repository-removed-1440x900-light.png
side-open-1600x900-dark.png
side-open-1600x900-light.png
```

Opened and visually inspected every image, light and dark. The explicit
unavailable labels fit on the count line without colliding with filenames;
repository removal presents Agents and Files while keeping the expanded tree
usable. The 1180-point panel, narrow pill and side-open panel preserve their
existing transcript/composer clearance. No visual correction was required.
Sixteen existing images are byte-identical to review-r5; the remaining two
existing side-open scenes include live fixture-state variation. Hashes and
inspection results are in `screenshots-premerge-hashes.json` and
`screenshots-premerge-review.json`. Generated fixtures are removed by test
cleanup; no native clone folder remains (`cleanup-premerge.json`).

### Integration with current dev/next

Fix commit `9cf0d848` was committed and pushed before integration. Ran
`git fetch origin`, then merged
`origin/dev/next` at `649ea623291c9417443d61d3bb55314d8a2f5d9a` using
`git -c commit.gpgsign=false merge --no-ff --no-commit origin/dev/next`.
The only conflict was the additions at the top of `NEXT-RELEASE.md`; both
sets of entries were retained. Production and test sources merged without
conflicts. `xcodegen generate --quiet` regenerated the combined project.
The panel and Git sources equal the tested fix commit, and merged helper
sources equal upstream; no helper behavior was authored in this round.
This integration is recorded as a two-parent merge commit, with no rebase
or history rewriting. Only `dev/a130-panel` is pushed.

The expanded merged sweep covers panel, Git/Changes, Files/Quick Open,
sidebar/search and transcript Find regression classes, plus GitView,
FileFinder and FileView package suites. Serial classes have separate native
invocations; all native runs and gallery captures hold the shared lane.

Merged package validation (`package-views-merged.log`, 529.487 seconds):

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| GitViewTests | 198 | 0 | 0 |
| FileViewTests | 100 | 0 | 0 |
| FileFinderTests | 38 | 0 | 3 |

The three skips are the existing `FINDER_PERF=1` benchmarks for 100,000 and
500,000 generated files; no normal file-reader test was skipped.

```sh
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter 'GitViewTests|FileFinderTests|FileViewTests'
```

`merge-audit.json` confirms the tested fix sources are unchanged by the merge,
all completed release-note entries from both parents are present, the helper
matches upstream, and no conflict remains. Review also checked deferred
summary notifications against controller replacement and retained the canonical
file-opening path from the earlier trust-boundary fix.

### Merged-run exception retained

The first mixed Files/search group had **50 passes and one failed test**
(two XCTest reports: the timeout assertion and its propagated error):
`FilePreviewRefreshTests.testSiblingNotificationsLetTheActivePreviewPublish`
at `apps/macos/PiAppTests/FilePreviewRefreshTests.swift:25` timed out waiting
for `queued metadata recheck entered`. Evidence:
`files-sidebar-1-merged-initial-failure.log` and
`native-merged-initial-failures.json`. No source was changed in response.
The isolated class rerun passed **2/2** in 0.454 seconds
(`FilePreviewRefreshTests-merged-isolated.log`); the other seven classes were
then rerun as a group without this class. The test and FilePreview implementation are unchanged
from upstream. The mixed-run timeout's cause is undetermined and remains
recorded rather than being described as an entirely failure-free first pass.

### Merged gallery

`SessionPanelGalleryTests` passed and regenerated **22 PNGs** under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r6/`:

```text
agents-1180x800-dark.png
agents-1180x800-light.png
agents-1440x900-dark.png
agents-1440x900-light.png
diff-1440x900-dark.png
diff-1440x900-light.png
diff-classification-1440x900-dark.png
diff-classification-1440x900-light.png
diff-no-renames-1440x900-dark.png
diff-no-renames-1440x900-light.png
diff-unavailable-1440x900-dark.png
diff-unavailable-1440x900-light.png
empty-1440x900-dark.png
empty-1440x900-light.png
files-1440x900-dark.png
files-1440x900-light.png
pill-960x700-dark.png
pill-960x700-light.png
repository-removed-1440x900-dark.png
repository-removed-1440x900-light.png
side-open-1600x900-dark.png
side-open-1600x900-light.png
```

Opened and visually inspected all 22 final images. Unavailable counts remain
readable in both themes, removal leaves the usable Files tree with Diff hidden,
and the 1180-point, narrow and side-open scenes retain their intended spacing
and clearance. No correction was needed. Twenty-one images are byte-identical
to the pre-merge renders; the dark side-open image now includes the fixture's
saved side-cost label. This is fixture publication timing, not a layout change.
Hashes and individual inspection results are in `screenshots-merged-review.json`.

### Final merged native validation

The final **24 native invocations** passed **719 tests** across **72 classes**,
with **0 failures and 5 optional skips**. These counts use the isolated preview
rerun and the successful regrouped run, excluding duplicate executions from
the initial failed group recorded above. The other seven classes passed **49/49**
in that regrouped run. All native invocations held the shared lane; serial
classes ran alone. Exact per-class counts follow, with text logs in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/review-r6/`.

| Class | Passed | Failed | Skipped | Text log |
| --- | ---: | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | 0 | `changes-frames-merged.log` |
| ChangesTabTests | 8 | 0 | 0 | `git-readers-merged.log` |
| ChatFileLinkTests | 7 | 0 | 0 | `files-sidebar-1-merged.log` |
| ContentSearchTests | 7 | 0 | 0 | `files-sidebar-1-merged.log` |
| ConversationSearchPagingTests | 1 | 0 | 0 | `files-sidebar-1-merged.log` |
| FileBlameTests | 10 | 0 | 0 | `files-sidebar-1-merged.log` |
| FileFindTabTests | 16 | 0 | 0 | `files-sidebar-1-merged.log` |
| FileFolderTests | 19 | 0 | 0 | `FileFolderTests-merged.log` |
| FileHiddenReadTests | 5 | 0 | 0 | `files-sidebar-1-merged.log` |
| FilePageReadTests | 3 | 0 | 0 | `files-sidebar-1-merged.log` |
| FilePreviewRefreshTests | 2 | 0 | 0 | `FilePreviewRefreshTests-merged-isolated.log` |
| FileReviewStateTests | 20 | 0 | 0 | `files-sidebar-2-merged.log` |
| FileSyntaxTests | 13 | 0 | 1 | `FileSyntaxTests-merged.log` |
| FileTabTests | 16 | 0 | 0 | `files-sidebar-2-merged.log` |
| FileTextViewTests | 47 | 0 | 0 | `files-sidebar-2-merged.log` |
| GitBranchesInteractionTests | 20 | 0 | 0 | `git-actions-merged.log` |
| GitChangelistReadTests | 2 | 0 | 0 | `git-readers-merged.log` |
| GitCommitBrowsingTests | 3 | 0 | 1 | `git-actions-merged.log` |
| GitConfirmationSheetTests | 7 | 0 | 0 | `git-actions-merged.log` |
| GitDiffTableTests | 19 | 0 | 0 | `diff-table-merged.log` |
| GitDiscardQuestionTests | 2 | 0 | 0 | `git-actions-merged.log` |
| GitHistoryFilterTests | 14 | 0 | 0 | `git-actions-merged.log` |
| GitHunkReviewTests | 9 | 0 | 0 | `git-actions-merged.log` |
| GitIntegratedHistoryTests | 10 | 0 | 0 | `git-actions-merged.log` |
| GitOperationSafetyTests | 12 | 0 | 0 | `git-actions-merged.log` |
| GitPanelAuditTests | 8 | 0 | 0 | `git-readers-merged.log` |
| GitPanelDiffCaptureTests | 0 | 0 | 1 | `files-sidebar-2-merged.log` |
| GitPanelLayoutTests | 4 | 0 | 0 | `git-readers-merged.log` |
| GitPanelNarrowParityTests | 8 | 0 | 0 | `git-narrow-merged.log` |
| GitPanelRedrawTests | 4 | 0 | 0 | `git-readers-merged.log` |
| GitPanelShownTests | 13 | 0 | 0 | `git-readers-merged.log` |
| GitPanelTimingTests | 4 | 0 | 0 | `git-timing-merged.log` |
| GitPanelWidthTests | 3 | 0 | 0 | `git-readers-merged.log` |
| GitPathBoundaryTests | 5 | 0 | 0 | `git-readers-merged.log` |
| GitRenameTests | 6 | 0 | 0 | `git-readers-merged.log` |
| GitRepositorySwitchTests | 17 | 0 | 0 | `repository-switch-merged.log` |
| GitToolTests | 5 | 0 | 0 | `git-readers-merged.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 | `watcher-merged.log` |
| HistoryIndexFilesTests | 3 | 0 | 1 | `files-sidebar-2-merged.log` |
| PayloadSearchTests | 3 | 0 | 0 | `files-sidebar-2-merged.log` |
| ProjectSidebarTests | 8 | 0 | 0 | `files-sidebar-2-merged.log` |
| QuickOpenPlacementTests | 1 | 0 | 0 | `QuickOpenPlacementTests-merged.log` |
| QuickOpenTests | 17 | 0 | 0 | `QuickOpenTests-merged.log` |
| ReplyFileLinkTests | 4 | 0 | 0 | `files-sidebar-2-merged.log` |
| SessionPanelGalleryTests | 1 | 0 | 0 | `gallery-merged.log` |
| SessionPanelTests | 29 | 0 | 0 | `panel-merged.log` |
| SidebarAppearanceTests | 6 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarBindingActionTests | 3 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarDocumentRegressionTests | 10 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarDropZoneTests | 6 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarFigureGoldenTests | 2 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarFlatTopicsTests | 30 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarInteractionTests | 9 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarListedOrderTests | 5 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarMetricsLayoutTests | 10 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarMultiSelectionTests | 4 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarNativeBindingTests | 4 | 0 | 0 | `SidebarNativeBindingTests-merged.log` |
| SidebarOrderHoldViewTests | 3 | 0 | 0 | `files-sidebar-3-merged.log` |
| SidebarRecencyTests | 4 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarRowDragTests | 4 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarRowStatesTogetherTests | 1 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarScalePerformanceTests | 4 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarSearchIndexTests | 16 | 0 | 0 | `files-sidebar-5-merged.log` |
| SidebarSearchKeyboardTests | 1 | 0 | 0 | `SidebarSearchKeyboardTests-merged.log` |
| SidebarSearchScopeTests | 12 | 0 | 0 | `files-sidebar-4-merged.log` |
| SidebarSearchSidebarTests | 9 | 0 | 0 | `files-sidebar-5-merged.log` |
| SidebarSearchTypingTests | 2 | 0 | 0 | `SidebarSearchTypingTests-merged.log` |
| SidebarSideClickTests | 4 | 0 | 0 | `files-sidebar-5-merged.log` |
| TopicSidebarPresentationTests | 4 | 0 | 0 | `files-sidebar-5-merged.log` |
| TranscriptBugRegressionTests | 116 | 0 | 0 | `files-sidebar-5-merged.log` |
| TranscriptFindProbeTests | 0 | 0 | 1 | `TranscriptFindProbeTests-merged.log` |
| TranscriptFindTests | 11 | 0 | 0 | `files-sidebar-5-merged.log` |

The five native skips are existing opt-in cases:

- `GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested`: `PI_APP_GIT_BENCH_REPO` unset.
- `GitPanelDiffCaptureTests.testCaptureTheDiffPaneWhenRequested`: `PI_APP_UI_SCREENSHOT_ROOT` unset.
- `HistoryIndexFilesTests.testTheIndexOfALongChat`: `PI_PERF_HISTORY_JOURNAL` unset.
- `FileSyntaxTests.testDelayedSyntaxGallery`: `PI_ROUND2_GITFILES_GALLERY` unset.
- `TranscriptFindProbeTests.testProbeFindDeepInHistory`: `PI_LONG_PROBE=1` unset.

Exact final native commands (executed from this worktree):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests -only-testing:PiAppTests/GitToolTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPanelShownTests -only-testing:PiAppTests/GitPanelRedrawTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitPanelLayoutTests -only-testing:PiAppTests/GitPanelWidthTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitHunkReviewTests -only-testing:PiAppTests/GitIntegratedHistoryTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitOperationSafetyTests -only-testing:PiAppTests/GitConfirmationSheetTests -only-testing:PiAppTests/GitDiscardQuestionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
TEST_RUNNER_PI_SESSION_PANEL_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r6 PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelGalleryTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChatFileLinkTests -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/ConversationSearchPagingTests -only-testing:PiAppTests/FileBlameTests -only-testing:PiAppTests/FileFindTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/FilePageReadTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileTextViewTests -only-testing:PiAppTests/GitPanelDiffCaptureTests -only-testing:PiAppTests/HistoryIndexFilesTests -only-testing:PiAppTests/PayloadSearchTests -only-testing:PiAppTests/ProjectSidebarTests -only-testing:PiAppTests/ReplyFileLinkTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarOrderHoldViewTests -only-testing:PiAppTests/SidebarAppearanceTests -only-testing:PiAppTests/SidebarBindingActionTests -only-testing:PiAppTests/SidebarDocumentRegressionTests -only-testing:PiAppTests/SidebarFigureGoldenTests -only-testing:PiAppTests/SidebarFlatTopicsTests -only-testing:PiAppTests/SidebarInteractionTests -only-testing:PiAppTests/SidebarListedOrderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarMetricsLayoutTests -only-testing:PiAppTests/SidebarMultiSelectionTests -only-testing:PiAppTests/SidebarRecencyTests -only-testing:PiAppTests/SidebarRowStatesTogetherTests -only-testing:PiAppTests/SidebarRowDragTests -only-testing:PiAppTests/SidebarDropZoneTests -only-testing:PiAppTests/SidebarScalePerformanceTests -only-testing:PiAppTests/SidebarSearchScopeTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarSearchIndexTests -only-testing:PiAppTests/SidebarSearchSidebarTests -only-testing:PiAppTests/SidebarSideClickTests -only-testing:PiAppTests/TopicSidebarPresentationTests -only-testing:PiAppTests/TranscriptBugRegressionTests -only-testing:PiAppTests/TranscriptFindTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileSyntaxTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenPlacementTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/QuickOpenTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarNativeBindingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarSearchKeyboardTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SidebarSearchTypingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptFindProbeTests
```

Final adversarial review rechecked relative-path Git configuration, explicit
count failure and automatic recovery, stale-controller callbacks, both repository
lifecycle directions, canonical file navigation, and the merged release entries.
The six mutation checks and failing-first evidence above remain applicable because
the merge did not change those production or test sources. No additional issue
was found in the changed paths. The unrelated mixed-run preview timeout remains
recorded with an undetermined cause and a successful isolated rerun.

`git diff --check` and `git diff --cached --check` pass. The owned lane was
released after the native checks. No native clone directory remains; the final
automatic Xcode result bundle was removed after preserving text logs
(`cleanup-merged.json`). All build products and screenshots use this workstream's
build root. No source changed after these final checks; only this validation
record was completed.


## Snapshot name collisions — round 8, 2026-10-20

Review base: `d475cae99bd4644f62dbc4cfc1ed19c3d2dd6901` on `dev/a130-panel`.
Read `/Users/admin/Library/Caches/BelloSwiftWork/r130/rules.md`, `AGENTS.md`,
`NEXT-RELEASE.md`, and the test-lane handoff before changing the snapshot reader.
Evidence and full text logs:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-8/`.

### Minimal correction and conservative cases

Before writing an untracked snapshot, the reader checks whether its destination
already exists or any existing parent has a different byte spelling. At a
collision it ends the batch without consuming that path; the existing loop
retries the path in a fresh private tree. Byte-identical shared directories
remain in the same batch. The 4 MiB per-file and 32 MiB per-batch bounds,
symlink-safe reader, Git options, cancellation, and private-tree cleanup are
unchanged. Ordinary file counts still come from the same Git commands.

Two exactness limits use the review's explicitly permitted unavailable-count
fallback. Canonically equivalent Unicode paths cannot have separate entries
in the existing String-keyed count map, so both spellings are omitted. An
attribute copy that aliases an accepted snapshot is refused; counts dependent
on that attribute scope are unavailable, while unrelated paths retain their
counts. The latter is the same overwrite issue in the same function, covered
by its own regression. No new production test hook or broader path-key refactor
was introduced.

### Honest volume fixture and regression evidence

`hdiutil create -size 64m -fs "Case-sensitive APFS" -volname BelloCountsFixture`
succeeds without administrator rights. Tests create their image under this
workstream's `PI_BUILD_ROOT`, attach it with `-nobrowse` at a unique mount point,
and detach/remove it in XCTest teardown. The probe and test runs confirmed
that `A.txt` and `a.txt` coexist with different bytes. `volume-probe.json`
records the probe commands and successful detach. The first exploratory
invocation used an inapplicable `-format UDRW` option and was corrected before
the successful probe; no image was created by that rejected invocation.

The APFS fixture tests leaf aliases (`A.txt`/`a.txt`), directory aliases
(`Dir/x.txt`/`dir/x.txt`), distinct children under aliased parents with different
`.gitattributes`, file/directory aliases, and ordinary siblings
sharing one directory. Every available row is compared with Git's own numstat
and the opened preview, with distinct expected counts. A separate real-volume
test covers `.GITATTRIBUTES` aliasing a tracked `.gitattributes` while an
unrelated root file keeps its exact count.

The case-sensitive APFS image still aliases composed/decomposed Unicode names;
this was measured in the probe, not treated as a normalization-sensitive volume.
The normalization regression therefore injects the two byte-distinct spellings
through the existing `GitRepositoryStatus` input, asserts that both counts are
unavailable, and verifies an unrelated tracked count. This is the smallest
existing seam and does not pretend to create two physical APFS files.

With the final tests and the original production source, **3 tests failed with
11 assertion/error reports** (`collisions-final-red.log`). An earlier version
of the fixture failed **3 tests / 9 reports** (`collisions-red.log`); the final
fixture additionally checks independent parent attributes. The fixed reader
passed **3/3** (`collisions-green.log`). Mutation controls:

| Removed protection | Failed tests | Assertion/error reports | Text log |
| --- | ---: | ---: | --- |
| Existing leaf destination | 1 | 2 | `mutation-leaf.log` |
| Existing parent spelling | 1 | 5 | `mutation-parent.log` |
| Ambiguous Unicode count keys | 1 | 2 | `mutation-normalization.log` |
| Attribute destination | 1 | 1 | `mutation-attributes.log` |

All four mutations failed executed tests, not compilation. `mutations.py`
restores the source in `finally`; `mutations.json` records exits and counts.
The exact focused command, used for red/green/restored runs, is:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter 'GitRepositoryStateTests/(testSummarySplitsCaseCollisionsOnACaseSensitiveVolume|testSummaryOmitsNormalizationAliasesThatCannotHaveDistinctCountKeys|testSummaryDoesNotOverwriteAnAttributeFileAlias)'
```

Mutation logs include each narrower command. No app layout, styling, gallery
fixture or non-colliding displayed value changed; the 22 inspected round-7
screenshots remain applicable and were not regenerated for this count-reader
correction. There is no pending owner decision for the permitted unavailable
fallback.

After all mutations were restored and preview assertions were strengthened to
compare full added/removed/binary values, the focused tests passed **3/3** again
(`collisions-restored.log`). All fixture images were detached and removed.
Adversarial review checked progress at batch boundaries, exact parent spellings,
file-versus-directory aliases, independent attribute scopes, canonical Unicode
keys, unrelated sibling counts, and cleanup on test failure. The collision
checks never consume the path before retrying it in a fresh batch; invalid
source reads retain the existing bounded-reader behavior.


### Integration and merged validation

Committed the correction as `976c970410c2cad4ee697d77dacb411643f96354`, then ran
`git fetch origin` and
`git -c commit.gpgsign=false merge --no-ff --no-commit origin/dev/next`.
The merged upstream is `688f8751a936cf8982c26b2e5a4dcb4b046578aa`, including
the paste fixes, focus-aware lane classification, and scoped preview-test
resolver. Only `NEXT-RELEASE.md` conflicted; all completed entries from both
sides were retained. Ran `xcodegen generate --quiet`. The production correction
is unchanged by the merge; no helper source or behavior was authored here.
`merge-audit.json` records source and release-entry checks.

The first merged package invocation ran **342 tests: 338 passed, 3 skipped,
1 failed** (`package-merged.log`, 547.408 seconds). This exposed a test-only
assertion added during this round: the shared parity helper compared parsed
patch line counts for a dirty-only gitlink, whose Git numstat is deliberately
0/0 even though its short patch has a `-dirty` suffix. The existing test
explicitly documents that Git behavior. Self-review identified the mistake
while the already-built suite was running; the failure confirms it. The new
full preview-count assertion is now limited to untracked entries, retaining
the existing Git-count and binary assertions for every row. Production code
was not changed in response. The full `GitRepositoryStateTests` class was
rerun on that correction; its result is recorded below. Initial failures and
logs are retained, not folded into an entirely failure-free first run.

The package command and focused correction rerun are:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter 'GitViewTests|FileViewTests|FileFinderTests'
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views --filter GitRepositoryStateTests
```

The merged `scripts/test-lanes.py list` output is retained in
`native-lanes.txt`. The focused native plan covers **30 classes** in **19
invocations**: each of the **18 serial classes runs alone**, and the **12
parallel classes** run together. This includes `FilePreviewRefreshTests` with
other file/search/Git fixtures so upstream's expired-resolver regression is
also checked in a mixed host. The lock wrapper uses only this build root and
releases only its own shared lane on success or failure.


The corrected repository-state class passed **40/40** in **136.138 seconds**
(`repository-state-merged-restored.log`), including all three new regressions,
the original dirty-submodule expectation, and the earlier grouping/count tests.
Final package coverage uses that class rerun plus the unchanged classes from
the full merged run, without counting duplicate executions:

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| GitViewTests | 201 | 0 | 0 |
| FileViewTests | 100 | 0 | 0 |
| FileFinderTests | 38 | 0 | 3 |

The three skips are the existing opt-in `FINDER_PERF=1` scale benchmarks.
`package-final-classes.json` maps each count to its actual log;
`package-final-modules.json` aggregates the suites. The test-only correction
leaves all four mutation controls applicable: their untracked-row assertions
and the production protection under test are unchanged.


The initial native wrapper was still waiting for another workstream's lock
when it was interrupted; no test had started (`focused-run-split.json`).
Applied the shared rules' focused-run exception to the 12 classes classified
parallel by the merged lane detector. Their single invocation ran without
the lock and passed **62 tests**, with **1 optional skip** and **0 failures**
(`native-parallel-merged.log`). The 18 serial classes remain separate
invocations under the shared lane. No other workstream's lock was removed.

`FilePreviewRefreshTests` passed **3/3** in the mixed group, including
`testSiblingNotificationsAfterAWorkspaceFixtureIsReleased`. This validates
the upstream scoped-resolver fix for the round-7 preview timeout. The new
explicit expired-workspace fixture and the original notification-burst test
both passed in 0.331 seconds; the overwrite test passed in 0.086 seconds.
The native skip is the existing real-repository commit-browsing benchmark
(`PI_APP_GIT_BENCH_REPO` unset).


### Native watcher exception retained

The first serial `GitWorkingTreeWatcherTests` invocation passed **16 tests**
and failed **1** (`GitWorkingTreeWatcherTests-merged-first-failure.log`,
52.080 seconds). At
`apps/macos/PiAppTests/GitWorkingTreeWatcherTests.swift:277`,
`testWritesIntoAnIgnoredFolderCauseNoRefresh` observed **2** automatic
refreshes after creating a new ignored directory, against a limit of **1**.
Its already-known ignored-path and subsequent steady-state assertions passed.
The class ran alone under the owned shared lane. The wrapper released the lane
on failure and the failed log was copied before any rerun.

The test, watcher and controller are byte-identical to round-7 commit
`d475cae9` (`native-initial-failure.json`). This test creates the regular
Changes controller (`summaryOnly` defaults to false); the untracked count
reader changed in this round is invoked only in the summary-only branch.
No source or test assertion was changed in response. The class was rerun
unchanged before the remaining floating-panel class. The cause of the extra
refresh is undetermined; the observation is retained rather than ignored or
attributed to the collision correction.


The unchanged watcher rerun passed **17/17** in **50.034 seconds**
(`GitWorkingTreeWatcherTests-merged.log`). `SessionPanelTests` then passed
**29/29** in **31.045 seconds**. Both ran alone under the shared lane, which
was released afterward. No source or assertion was changed to obtain the
watcher pass. Its initial extra refresh remains an undetermined intermittent
observation for the lead's merged gate, not a failure hidden by these totals.

### Final merged native counts and commands

Final native coverage passed **255 tests** across **30 classes**, with
**0 failures and 1 optional skip**. These counts use the successful watcher
class rerun and exclude its duplicate initial executions. The initial failure
and the unrelated package test-only correction are preserved above. Per-class
results and exact commands follow; every log is under this round's evidence
folder.

| Class | Passed | Failed | Skipped | Text log |
| --- | ---: | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | 0 | `ChangesTabFrameTests-merged.log` |
| ChangesTabTests | 8 | 0 | 0 | `ChangesTabTests-merged.log` |
| ContentSearchTests | 7 | 0 | 0 | `native-parallel-merged.log` |
| ConversationSearchPagingTests | 1 | 0 | 0 | `native-parallel-merged.log` |
| FileHiddenReadTests | 5 | 0 | 0 | `native-parallel-merged.log` |
| FilePageReadTests | 3 | 0 | 0 | `native-parallel-merged.log` |
| FilePreviewRefreshTests | 3 | 0 | 0 | `native-parallel-merged.log` |
| GitBranchesInteractionTests | 20 | 0 | 0 | `GitBranchesInteractionTests-merged.log` |
| GitChangelistReadTests | 2 | 0 | 0 | `native-parallel-merged.log` |
| GitCommitBrowsingTests | 3 | 0 | 1 | `native-parallel-merged.log` |
| GitConfirmationSheetTests | 7 | 0 | 0 | `GitConfirmationSheetTests-merged.log` |
| GitDiffTableTests | 19 | 0 | 0 | `GitDiffTableTests-merged.log` |
| GitDiscardQuestionTests | 2 | 0 | 0 | `GitDiscardQuestionTests-merged.log` |
| GitHistoryFilterTests | 14 | 0 | 0 | `native-parallel-merged.log` |
| GitHunkReviewTests | 9 | 0 | 0 | `GitHunkReviewTests-merged.log` |
| GitIntegratedHistoryTests | 10 | 0 | 0 | `GitIntegratedHistoryTests-merged.log` |
| GitOperationSafetyTests | 12 | 0 | 0 | `GitOperationSafetyTests-merged.log` |
| GitPanelAuditTests | 8 | 0 | 0 | `native-parallel-merged.log` |
| GitPanelLayoutTests | 4 | 0 | 0 | `GitPanelLayoutTests-merged.log` |
| GitPanelNarrowParityTests | 8 | 0 | 0 | `GitPanelNarrowParityTests-merged.log` |
| GitPanelRedrawTests | 4 | 0 | 0 | `GitPanelRedrawTests-merged.log` |
| GitPanelShownTests | 13 | 0 | 0 | `GitPanelShownTests-merged.log` |
| GitPanelTimingTests | 4 | 0 | 0 | `GitPanelTimingTests-merged.log` |
| GitPanelWidthTests | 3 | 0 | 0 | `GitPanelWidthTests-merged.log` |
| GitPathBoundaryTests | 5 | 0 | 0 | `native-parallel-merged.log` |
| GitRenameTests | 6 | 0 | 0 | `native-parallel-merged.log` |
| GitRepositorySwitchTests | 17 | 0 | 0 | `GitRepositorySwitchTests-merged.log` |
| GitToolTests | 5 | 0 | 0 | `native-parallel-merged.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 | `GitWorkingTreeWatcherTests-merged.log` |
| SessionPanelTests | 29 | 0 | 0 | `SessionPanelTests-merged.log` |

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/ConversationSearchPagingTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/FilePageReadTests -only-testing:PiAppTests/FilePreviewRefreshTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitHistoryFilterTests -only-testing:PiAppTests/GitPanelAuditTests -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitRenameTests -only-testing:PiAppTests/GitToolTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabFrameTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ChangesTabTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitBranchesInteractionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitConfirmationSheetTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiffTableTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitDiscardQuestionTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHunkReviewTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitIntegratedHistoryTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitOperationSafetyTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelLayoutTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelRedrawTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelShownTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelWidthTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel /Users/admin/Library/Caches/BelloSwiftWork/wt-a130-panel/scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SessionPanelTests
```

Final adversarial review checked fresh-batch progress, byte-exact parent reuse,
leaf/directory and attribute aliases, Unicode-key ambiguity, unrelated counts,
source/read boundaries, and all release-note entries from both merge parents.
The production fix is byte-identical to `976c9704`; the only test-code follow-up
scopes preview counts to untracked rows as recorded above. No additional issue
was found in the changed production paths. The observed watcher timing failure
is outside this round's count-reader path and remains recorded for follow-up.

`git diff --check` and `git diff --cached --check` pass, with no unresolved
merge conflicts. No native clone directory or fixture disk image remains.
The final automatic Xcode result bundle was removed after preserving text logs
(`cleanup-final.json`); no named result bundle was requested. The owned shared
lane is released. `tested-source-hashes.json` identifies the tested production,
test and generated-project bytes. Only this record was completed after the
final checks. The integration is a two-parent merge commit, with no rebase or
history rewriting, pushed only to `dev/a130-panel`.

## Paired count batching — round 9, 2026-10-20

Review base: `2cb7d04fc92d070c0fbc2d09cd3a42b6e1241c1c`.
Read the shared round rules, `AGENTS.md`, `NEXT-RELEASE.md`, and
`docs/Swift-Test-Handoff.md`. Evidence and text logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/`.

### Correction and regressions

Reported rename/copy pairs now enter a dedicated `pairedBatches` helper
together. It budgets the additional unique paths before adding a complete
pair, using the existing 512-path and 128 KiB UTF-8 limits (including command
prefix bytes). A shared copy source occurs once per batch, and is included
again when needed by the next batch. A pair exceeding the byte budget remains
whole in its own batch and makes progress. The existing flat-path batcher used
by writes is unchanged.

The two ordinary index/worktree reads, exact source/destination match check,
isolated fallback for ambiguous matches, Git arguments, and untracked snapshot
reader are unchanged. This corrects process amplification without changing the
row counts or interpreting Git's grouping.

Generated repository regressions cover:

- A staged directory rename of 512 files, with all sources and destinations
  separated by the old flattened-path sort.
- 653 mixed rows: 260 renames, 260 copies sharing 130 modified sources, and
  ordinary staged, working-tree, and staged-plus-working-tree modifications.
  The pairs cross batch boundaries.
- Path count, UTF-8 byte count, shared-source deduplication, and oversized-pair
  progress through the helper seam, without inventing impossible on-disk paths.

Every row in both repositories is checked against a separate Git numstat
request for the exact diff that row opens, as well as distinct generated
expected counts. Git's `GIT_TRACE2_EVENT` output, passed through the existing
`GitService(environment:)` seam, counts actual summary invocations and checks
that no request repeats a path. Oracle commands use a separate environment
and do not contribute to that count. No production tracing hook was added.

The original implementation failed both repository regressions, with **516**
calls for the 512-file rename and **402** calls for the mixed fixture; every
count parity assertion passed (`pairs-red.log`, 2 tests / 2 failures).
The fixed batcher used **4 calls for each fixture**, passing all three new
tests (`pairs-green.log`). The first native build exposed an overload ambiguity
at the existing `GitPanelAuditTests` empty-path call; the helper was given its
own name rather than changing that existing caller. The failed build remains
in `native-parallel-before-namefix.log`.

Mutation checks were repeated after that naming correction:

| Mutation | Failed tests | Assertion failures | Text log |
| --- | ---: | ---: | --- |
| Flatten, deduplicate, and sort paths before batching again | 3 | 5 | `mutation-flatten.log` |
| Stop deduplicating paths already present in a batch | 1 | 2 | `mutation-duplicate.log` |
| Budget characters instead of UTF-8 bytes | 1 | 2 | `mutation-characters.log` |

The first mutation restored the original **516 / 402** invocation counts.
The other mutations failed the shared-source and byte/oversized-pair
assertions. All mutations were restored byte-for-byte before final validation.
`mutate.py`, `mutations.json`, and `fixed-GitService.swift` retain the exact
controls; earlier checks before the helper rename are also retained with
`-before-namefix` log suffixes.

Failing-first and initial green command (the green run additionally selects
`GitRepositoryStateTests.testPairedCountBatchesKeepGroupsAcrossCountAndByteLimits`):

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel \
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter 'GitRepositoryStateTests.testSummaryKeepsDirectoryRenamePairsInBoundedRequests|GitRepositoryStateTests.testSummaryBatchesMixedRenamesCopiesAndModifications'
```

The flatten mutation runs those two tests plus the helper-budget test. The
duplicate and character mutations each select only the helper-budget test.
Each mutation log starts with its exact command.

### Final package validation

The restored source passed **342 tests, 0 failures, 3 skips**:

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| GitViewTests | 204 | 0 | 0 |
| FileViewTests | 100 | 0 | 0 |
| FileFinderTests | 38 | 0 | 3 |

`GitRepositoryStateTests` passed all **43** tests, including the three new
regressions and existing rename ambiguity, configuration, binary, attribute,
untracked snapshot, and repository lifecycle cases. FileFinder's three skips
are the existing `FINDER_PERF=1` measurements. The completed earlier pass,
before the helper naming correction, also passed 342 / 0 / 3 and is retained
in `packages-before-namefix.log`; it is not substituted for the final pass.

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel \
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/views \
  --filter 'GitViewTests|FileViewTests|FileFinderTests'
```

Full output: `packages-final.log`. Per-class and per-module totals:
`package-final-classes.json`, `package-final-modules.json`; command and exit:
`package-exit.json`. The existing workstream scratch path was reused.

### Refresh measurement

Measured the real `GitController(summaryOnly: true)` refresh, including status,
counts and ignored-path reads, against the same generated repositories for
before and after. AppKit drawing is outside this measurement. The baseline is
the round-8 merge `2cb7d04f`; only `GitService.swift` differs among the GitView
sources. Both harnesses use `swiftc -O`, Apple Git 2.39.5 (Apple Git-154),
Swift 6.0.2, macOS 14.8, and isolated Git configuration.

The shared full-lane lock was held during measurement, with no concurrent
builds or tests from this workstream. Three launches per version, alternating
before/after order, each measured three steady refreshes after the initial
load: **nine samples per cell**. All launches reported the expected
512 / 653 rows, a count for every row, and no notice.

| Fixture | Before median | After median | Reduction | Count-reader Git calls, before → after |
| --- | ---: | ---: | ---: | ---: |
| 512 staged directory renames | 7,526.22 ms | 715.55 ms | 90.49% | 516 → 4 |
| 653 mixed rename/copy/modification rows | 6,165.96 ms | 803.54 ms | 86.97% | 402 → 4 |

The invocation column comes from the traced regression tests and counts only
`changeStats`; the timed controller refresh also includes its other Git reads.
The two paired batches plus the two ordinary index/worktree reads account for
the four calls in each fixture.

Exact commands (under the round-9 evidence folder):

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/benchmark/build.py before
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/benchmark/build.py after
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/benchmark/run.py
```

`benchmark/Measure.swift` and `benchmark/run.py` retain the harness and generated
fixtures' recipe; `benchmark/metadata.json`, `timings.json`, and `summary.json`
record versions, every cold/steady sample and aggregates. Build logs include
the complete compiler arguments. Both generated repositories were removed and
the benchmark's lock was released in `finally`.

### Native commands and lane discipline

The requested round-8 selection is unchanged: **30 classes in 19 invocations**.
`scripts/test-lanes.py list` was regenerated and checked against every selected
class. The twelve focus-independent classes share one focused invocation;
each of the eighteen serial classes runs alone, under the shared full-lane
lock. All invocations use:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/<Class>
```

For the focused group, the same command includes twelve `-only-testing`
arguments: `ContentSearchTests`, `ConversationSearchPagingTests`,
`FileHiddenReadTests`, `FilePageReadTests`, `FilePreviewRefreshTests`,
`GitChangelistReadTests`, `GitCommitBrowsingTests`, `GitHistoryFilterTests`,
`GitPanelAuditTests`, `GitPathBoundaryTests`, `GitRenameTests`, `GitToolTests`.
It passed **62 tests, 0 failures, 1 skip**. The skip is the existing opt-in
commit-browsing measurement requiring `PI_APP_GIT_BENCH_REPO`.

The exact group selection and driver commands are retained in
`native-groups.json`, `native-lanes.txt`, and the first line of each native log.
The driver invocations are:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/run-focused.py
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/run-lane.py final /Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-9/native-groups.json
```

The serial driver releases only its own lock, including on failure. No
installed app, live project data, credentials, or provider calls are used.

Final native result: **255 passed, 0 failed, 1 skipped**, across all 30 classes.
All 19 invocations exited successfully. `native-final-classes.json` and
`native-totals.json` retain the totals; `native-commands.sh` contains all 19
expanded commands. The watcher class passed all 17 tests on its first run this
round, including the ignored-directory assertion that had failed once in
round 8. No unrelated test failures occurred this round.

| Class | Passed | Failed | Skipped | Text log |
| --- | ---: | ---: | ---: | --- |
| ChangesTabFrameTests | 7 | 0 | 0 | `ChangesTabFrameTests-final.log` |
| ChangesTabTests | 8 | 0 | 0 | `ChangesTabTests-final.log` |
| ContentSearchTests | 7 | 0 | 0 | `native-parallel-final.log` |
| ConversationSearchPagingTests | 1 | 0 | 0 | `native-parallel-final.log` |
| FileHiddenReadTests | 5 | 0 | 0 | `native-parallel-final.log` |
| FilePageReadTests | 3 | 0 | 0 | `native-parallel-final.log` |
| FilePreviewRefreshTests | 3 | 0 | 0 | `native-parallel-final.log` |
| GitBranchesInteractionTests | 20 | 0 | 0 | `GitBranchesInteractionTests-final.log` |
| GitChangelistReadTests | 2 | 0 | 0 | `native-parallel-final.log` |
| GitCommitBrowsingTests | 3 | 0 | 1 | `native-parallel-final.log` |
| GitConfirmationSheetTests | 7 | 0 | 0 | `GitConfirmationSheetTests-final.log` |
| GitDiffTableTests | 19 | 0 | 0 | `GitDiffTableTests-final.log` |
| GitDiscardQuestionTests | 2 | 0 | 0 | `GitDiscardQuestionTests-final.log` |
| GitHistoryFilterTests | 14 | 0 | 0 | `native-parallel-final.log` |
| GitHunkReviewTests | 9 | 0 | 0 | `GitHunkReviewTests-final.log` |
| GitIntegratedHistoryTests | 10 | 0 | 0 | `GitIntegratedHistoryTests-final.log` |
| GitOperationSafetyTests | 12 | 0 | 0 | `GitOperationSafetyTests-final.log` |
| GitPanelAuditTests | 8 | 0 | 0 | `native-parallel-final.log` |
| GitPanelLayoutTests | 4 | 0 | 0 | `GitPanelLayoutTests-final.log` |
| GitPanelNarrowParityTests | 8 | 0 | 0 | `GitPanelNarrowParityTests-final.log` |
| GitPanelRedrawTests | 4 | 0 | 0 | `GitPanelRedrawTests-final.log` |
| GitPanelShownTests | 13 | 0 | 0 | `GitPanelShownTests-final.log` |
| GitPanelTimingTests | 4 | 0 | 0 | `GitPanelTimingTests-final.log` |
| GitPanelWidthTests | 3 | 0 | 0 | `GitPanelWidthTests-final.log` |
| GitPathBoundaryTests | 5 | 0 | 0 | `native-parallel-final.log` |
| GitRenameTests | 6 | 0 | 0 | `native-parallel-final.log` |
| GitRepositorySwitchTests | 17 | 0 | 0 | `GitRepositorySwitchTests-final.log` |
| GitToolTests | 5 | 0 | 0 | `native-parallel-final.log` |
| GitWorkingTreeWatcherTests | 17 | 0 | 0 | `GitWorkingTreeWatcherTests-final.log` |
| SessionPanelTests | 29 | 0 | 0 | `SessionPanelTests-final.log` |

### Adversarial self-review and cleanup

Reviewed the complete production diff after restoring mutations. At a batch
boundary, the whole group is reintroduced after resetting the deduplication
set; a shared source cannot disappear merely because it was present in the
previous batch. UTF-8 bytes and prefix bytes count toward the byte budget,
and an oversized pair is admitted intact into an empty batch. Both the helper
boundary test and actual Git traces check shared-source behavior. Exact
source/destination matching and the existing ambiguous-rename fallback remain
intact; the swapped-destination regression passed in the full Git suite.
The ordinary write batcher is unchanged and its existing native audit passed.
No further issue was found in the changed paths; no owner decision is needed.

No UI code or gallery fixture changed, and per-row counts remain identical.
Screenshots were therefore not regenerated; the previously reviewed light,
dark and narrow images remain at
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/screenshots/review-r6/`.
No helper or wire code changed. No source files were added or removed, so
project regeneration was unnecessary.

`git diff --check` and the staged diff check pass. `cleanup-final.json` records
removal of the final automatically named Xcode result bundle after retaining
text logs; no named result bundle was requested. There are no remaining
fixture disk images, benchmark repositories or native clone directories.
`tested-source-hashes.json` matches the final production, test and generated
project bytes. The shared lane was released. Only the release note and this
validation record were completed after the source checks. The change is
committed and pushed only to `dev/a130-panel`, without merging or rewriting
history.
