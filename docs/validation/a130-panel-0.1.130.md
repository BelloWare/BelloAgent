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
