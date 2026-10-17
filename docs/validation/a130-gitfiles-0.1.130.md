# Git, Files and Terminal — 0.1.130

Workstream `dev/a130-gitfiles`, based on `141666ca479184d10a9791754d4c91df456599d8`.
Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles`;
the text logs below are in its `evidence/` directory. All repositories, images,
chat state and shell directories are generated fixtures. Native tests use the
scheme's isolated defaults/data home and `ZDOTDIR`, and the workspace fixture
uses `MemoryVaultStorage`. Terminal probe input is intercepted, never sent to
the shell. No installed app, real chats, credentials, Keychain, live capture,
provider requests, release, tags or integration-branch writes are involved.

## Assigned findings

All five findings are **confirmed and fixed**; none rejected.

| Finding | Regression | Failing-first evidence | Fix |
| --- | --- | --- | --- |
| GIT-FILES-1 | `GitPathBoundaryTests.testDiscardPreservesWhitespaceInTheRepositoryRoot` | `failing-first-git-final.log`: selected `repo ` resolved to `repo`; chosen file remained `working`/`staged`, while the sibling's worktree and index became `base`. One test failed with 21 assertions across space, tab, LF, CR and CRLF suffixes. | Remove precisely Git's one terminating LF byte. Preserve path whitespace, including a CR immediately before that LF. Controller discard still uses its existing repository context guards. |
| GIT-FILES-2 | `FilePreviewRefreshTests.testSiblingNotificationsLetTheActivePreviewPublish` | `failing-first-core.log`: `XCTAssertNotNil failed - unchanged image must appear during ongoing folder activity`; loading remained true and decode starts were 0 rather than 1. | Coalesce notifications while a preview read is active; publish that read and drain one pending metadata recheck. Suspension clears the pending check and still cancels obsolete work. PDF and image reads share this path. |
| GIT-FILES-3 | `TerminalInverseTests.testIdenticalNormalAndInverseGlyphsContrastInEitherOrderAndAppearance` | `failing-first-core.log`: the second identical glyph had only 0–1 ink pixels, below the required >5, in both orders under Aqua and Dark Aqua; the first glyph passed. | Include inverse state in the line cache key, distinguishing the default foreground and background roles. Cache size bounds are unchanged. |
| GIT-FILES-4 | `FilePreviewRefreshTests.testSuccessfulPreviewFollowsSameSizeAndMtimeOverwrite` | `failing-first-core.log`: updated blue component was `0.0`, expected >0.9; decode count stayed 1, expected 2. The test proves size, inode and both mtime components stayed equal while ctime changed. | Fingerprint `stat` device, inode, size and nanosecond modification/change times, matching the text reader's identity fields. |
| APP-UI-1 | `TerminalPageFocusTests.testTerminalMenuCannotSendTypingBehindReportOrBackground`, `testDeferredTerminalFocusRechecksPageEnabledAndAttachment`, `testAnAlreadyShownTerminalIsHiddenByTheReportAndRestoredOnReturn` | `failing-first-focus-final.log`: 3 tests failed, 14 assertions. The actual menu action enabled a covered terminal, made it first responder, and the input spy received `echo BELLO_UI_PROBE` plus Return on both pages. Deferred focus also survived page, enabled, hidden and attachment changes. An existing terminal was not natively hidden or restored to focus. | Menu validation and dispatch require Chats. Deferred focus rechecks the current page, enabled state, native visibility, attachment and ownership of the terminal view. Page visibility includes terminal panels and restores their prior responder on return. |

**Needs owner decision:** Show/Hide Terminal is disabled on Usage Report and
Background Requests. This is the conservative option explicitly offered in the
finding; it preserves the current page instead of navigating to Chats. The
terminal continues running when covered, as before.

### Fixture corrections before accepting evidence

The initial native build failed on a missing `@discardableResult` in the new
fixture override; this was corrected before execution. Early Git probes did
not await the controller's queued initial refresh and mixed macOS `/var` and
`/private/var` aliases. The final probe awaits publication and uses `realpath`
for Git's expected root. Early workspace probes omitted `model.selected`, then
lost their manually assigned project when the report loaded the empty memory
vault. The final fixture mounts the selected display and persists its generated
project into that vault before configuration loads. Those preliminary failures
are not used as proof of destructive discard or invisible shell input.

The first broader Git run (`affected-git.log`) had one failing test with two
assertions: the correct repository was selected, but one discard was refused.
Adding an action-notice assertion reproduced `Discard: fatal: Unable to create
'…/.git/index.lock': File exists.` in `git-path-notice-probe.log`. The custom
fixture environment had omitted `GIT_OPTIONAL_LOCKS=0`, which production already
sets in `GitService.gitEnvironment`; background status reads could therefore
contend with restore. The fixture now matches that setting and retains the
notice assertion. No production lock behavior was changed.
The corrected discard regression passed **5/5 repetitions**, covering 25 chosen
repositories plus their siblings (`git-path-repeat-green.log`).

## Nearby pattern sweep

Each accepted case has its own regression; these are not speculative cleanups.

| Case | Test in `GitPathBoundaryTests` | Before fix | Minimal change |
| --- | --- | --- | --- |
| Hunk review truncates a root ending in LF | `testPatchReviewPreservesTheRootsTrailingNewline` | `failing-first-git.log`: `The repository changed. Refresh and review it again.` | Use the same single-path output decoder for `--show-toplevel`. |
| Watcher truncates external Git/common-directory paths | `testWatcherPreservesWhitespaceInExternalGitAndCommonDirectories` | `failing-first-git.log`: `metadata ` became `metadata`; `.git` parsing cut `metadata\ninside` at the embedded LF. Git itself accepted the generated directories. | Read the complete `gitdir: ` path and trim only Git metadata's trailing CR/LF terminators. Test ordinary paths and LF/CRLF files as well. |
| Reword misses active operation markers under newline-containing paths | `testRewordSeesOperationMarkersInsideANewlinePath` | `failing-first-git.log`: `active merge must block reword`; HEAD changed despite `MERGE_HEAD`. | Ask Git for each operation path separately; newline-delimited multiple paths cannot distinguish embedded newlines. This costs six path queries instead of one only during explicit reword validation. |
| Reword skips a configured post-rewrite hook directory ending in LF | `testRewordRunsTheConfiguredHookInATrailingNewlineDirectory` | `failing-first-git.log`: `.git/rewritten` was absent instead of containing `old new`. | Preserve `git config --path` output with the same single-LF decoder. |

The sweep also covers Background Requests, already-open terminal panels, and
detached/disabled/hidden deferred focus under APP-UI-1. Other Git output trims
were inspected: object IDs, branch names and diagnostic text are not directory
paths; the remaining generated `index`, `hooks` and `shallow` paths end in those
fixed names. No unrelated product changes were made.

## Validation

The fixed regressions first passed **8/8** (`green-core.log`) and **3/3**
(`green-focus.log`). Mutation checks then reversed the relevant logic together,
with separate tests identifying each defect; every production file was restored
byte-for-byte afterward. The preview regression additionally checks that a burst
admits exactly one queued metadata recheck.

| Finding / sweep case | Mutation | Result |
| --- | --- | --- |
| GIT-FILES-1 | Restore whitespace trimming in `repositoryRoot` | Discard regression fails again; all five suffix cases target the sibling. |
| GIT-FILES-2 | Replace the active-read guard with `task?.cancel()` | Preview publication/queued-check regression fails again. |
| GIT-FILES-3 | Force cache-key `inverse` to false | Pixel regression fails in both orders and appearances: 4 assertions, `mutation-render.log`. |
| GIT-FILES-4 | Zero device and change-time fingerprint fields | Same-size, same-mtime update keeps the old pixels again. |
| APP-UI-1 | Remove menu page gating, restore unconditional deferred focus, omit terminals from native page visibility | All 3 focus regressions fail again, including probe bytes reaching the spy: 14 assertions, `mutation-focus.log`. |
| Hunk root, watcher paths, operation markers, hook directory | Restore their former trimming/splitting logic | All 4 dedicated Git regressions fail again. |

`mutation-core.log`: **7/7 tests fail**, 41 assertions/errors (the hunk test's
thrown refusal is the one XCTest “unexpected” error). `mutation-render.log`:
**1/1 fails**. `mutation-focus.log`: **3/3 fail**. `mutation-summary.log` names
every failed test and confirms source restoration. These are deliberate mutants,
not unresolved failures of the fixed code.

No helper source or wire behavior changed, so the full helper and
wire/concurrent/acceptance suites are not part of this workstream; the lead owns
the merged full gate.

### Final focused runs

Every row below completed with zero failures. The native rows total **285 passed,
2 opt-in skips** (287 tests); the five discard repetitions above are additional.
The GitView package suite passed **173/173**. Focus/window/gallery runs held the
shared full-lane lock for each run and released it afterward; serial-lane classes
ran alone. No clone directories were left under this build root.

| Suite / focused group | Passed | Skipped | Text log |
| --- | ---: | ---: | --- |
| Files, terminal rendering/sessions and report navigation | 142 | 0 | `affected-files-terminal.log` |
| Git actions, paths, hunks and commit browsing | 38 | 1 | `affected-git-final.log` |
| NativeApplicationTests | 12 | 0 | `native-application.log` |
| TerminalPageFocusTests | 3 | 0 | `terminal-page-focus.log` |
| TerminalTabsPanelTests | 5 | 1 | `terminal-tabs-panel.log` |
| TerminalPanelSerialTests | 18 | 0 | `terminal-panel-serial.log` |
| GitWorkingTreeWatcherTests | 16 | 0 | `git-watcher.log` |
| GitRepositorySwitchTests | 17 | 0 | `git-repository-switch.log` |
| ShellParityTests | 15 | 0 | `shell-parity.log` |
| GitHistoryFilterTests | 14 | 0 | `git-history-filter.log` |
| GitPanelTimingTests | 4 | 0 | `git-panel-timing.log` |
| GitFilesFixGalleryTests | 1 | 0 | `gallery-final.log` |
| GitViewTests (Swift package) | 173 | 0 | `git-package.log` |

The skips were `GitCommitBrowsingTests.testMeasureCommitBrowsingWhenRequested`
(requires `PI_APP_GIT_BENCH_REPO`, a real-repository benchmark) and
`TerminalTabsPanelTests.testSnapshotOfSeveralTerminals` (requires
`PI_APP_TERMINAL_SNAPSHOT`). The dedicated generated-fixture gallery was enabled
and passed. No fixed-code failure remains.

Commands, from the worktree root (the exported build root is common to all):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles
xcodegen generate --quiet
python3 scripts/build-bundle.py
swift test --package-path packages/bello-views --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/views-tests --filter GitViewTests

# affected-files-terminal.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FilePreviewRefreshTests -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/TerminalInverseTests -only-testing:PiAppTests/TerminalHistoryDrawingTests -only-testing:PiAppTests/TerminalCursorAlignmentTests -only-testing:PiAppTests/TerminalEmulatorTests -only-testing:PiAppTests/TerminalPanelAuditTests -only-testing:PiAppTests/TerminalPreciseScrollTests -only-testing:PiAppTests/TerminalSelectionScrollTests -only-testing:PiAppTests/TerminalSoftWrapTests -only-testing:PiAppTests/TerminalViewportTests -only-testing:PiAppTests/TerminalSessionsTests -only-testing:PiAppTests/ReportNavigationTests -only-testing:PiAppTests/ReportPageTests

# affected-git-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/GitHunkReviewTests -only-testing:PiAppTests/GitOperationSafetyTests -only-testing:PiAppTests/GitCommitBrowsingTests -only-testing:PiAppTests/GitToolTests -only-testing:PiAppTests/GitChangelistReadTests -only-testing:PiAppTests/GitDiscardQuestionTests

# native-application.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/NativeApplicationTests

# terminal-page-focus.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPageFocusTests

# terminal-tabs-panel.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalTabsPanelTests

# terminal-panel-serial.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPanelSerialTests

# git-watcher.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitWorkingTreeWatcherTests

# git-repository-switch.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitRepositorySwitchTests

# shell-parity.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ShellParityTests

# git-history-filter.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitHistoryFilterTests

# git-panel-timing.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelTimingTests

# gallery-final.log
TEST_RUNNER_PI_GITFILES_FIX_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitFilesFixGalleryTests

# git-path-repeat-green.log
scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 5 -only-testing:PiAppTests/GitPathBoundaryTests/testDiscardPreservesWhitespaceInTheRepositoryRoot
```

The failing-first/green regression runs used these commands against the source
states described above; mutations used the second, fourth and fifth commands
with the specific lines reversed, then restored the source:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/FilePreviewRefreshTests -only-testing:PiAppTests/TerminalInverseTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPathBoundaryTests -only-testing:PiAppTests/FilePreviewRefreshTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPathBoundaryTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalInverseTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPageFocusTests
```

### Gallery inspection

Viewed all **12 regenerated PNGs** in `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery`: three scenes
(updated blue image, adjacent normal/inverse terminal glyphs in both orders,
and Usage Report covering the terminal), each at 1240×800 and 920×800 points
under Aqua and Dark Aqua. The image is visible, each terminal glyph contrasts
with its background, and the report covers the native terminal. The fixture
waits for terminal closure before capturing the next preview scene.

Out-of-scope visual observation for separate triage: in the 920-point preview
scenes, the neighboring chat composer clips controls at its left and right
edges. The split assigns that pane about 309 points
(`apps/macos/PiApp/Workspaces/WorkspaceView.swift:417`), while the pane exposes
a composer minimum (`apps/macos/PiApp/Workspaces/ConversationPane.swift:199`).
This work does not change either layout function; no layout fix was attempted.

## Narrow workspace split follow-up

The owner authorized the layout observation above after merging round one.
Baseline: `5c52621c` (the fast-forwarded `dev/a130-gitfiles` worktree). The bug is
**confirmed and fixed**: `WorkspaceChatsLayer` used only the stored fraction,
ignoring `ConversationPaneView.minimumWidth`.

The split now offers the requested width to the composer's existing compact
forms, reserves at least the resulting control minimum (rounded up), and gives
the file pane the remainder. The preferred fraction, sidebar width and
920×628-point window minimum stay unchanged. Widening restores the preferred
split. Existing size-change propagation also reallocates space when Steer/Stop
appear or disappear; no new observation or composer sizing mechanism is needed.
The resize handle's accessibility hint describes the minimum-width constraint.
A new drag starts from the visible divider when the minimum displaced the saved
fraction, so dragging right responds immediately; the preference is still saved
only when the drag ends.

**Needs owner decision:** keep an open file in the remaining width when both
panes cannot retain their preferred shares. This is the conservative implemented
choice: no automatic file closure, sidebar resize or increased window minimum.
With two connection choices, the generated fixture's compact chat minimum is
400 points idle / 469 busy. At 920 points, a 300-point sidebar leaves the file
218 / 149 points; a 420-point sidebar leaves 98 / 29 points. A file in that last
case is too narrow for useful reading until the reader widens the window or
shrinks the sidebar. Automatic pane collapse or sidebar changes need an owner
UX decision. The chat's controls remain inside their bounds in every case.

### Regression and mutation evidence

`WorkspaceSplitTests.testFilePaneYieldsToTheChatMinimumAtNarrowWindowSizes`
mounts the real native workspace at 920×800 and the actual minimum 920×628,
with file open/closed, 300/420-point sidebar, and idle/busy composer. It checks
the exposed minimum, every visible native composer control's bounds, both pane
frames, the unchanged window size/minimum and saved split.

`WorkspaceSplitTests.testDraggingAndChangingComposerControlsPreserveThePreferredSplit`
drives the real split handle to its lower bound, changes idle → busy → idle
without resizing, then widens and closes the file. It checks that the file gets
space back, the stored fraction returns when it fits, and the closed-file chat
fills the column.

`WorkspaceSplitTests.testDraggingRightStartsAtTheVisibleMinimumBoundary` checks
a 12-point rightward drag from the clamped minimum and its committed position.
With only the width reservation applied, it failed twice (`split-drag-red.log`):
`("400.0") is not equal to ("412.0") +/- ("1.0")`, during the drag and on release.
This caught the dead zone introduced by starting a drag from the displaced saved
fraction. The drag now starts from the visible allocation.

Failing first, with production layout unchanged (`split-red.log`): **2 tests
failed, 99 expected assertion failures**. Representative output:

```text
XCTAssertGreaterThanOrEqual failed: ("309.0") is less than ("400.0") - 920×800, sidebar 300.0, file true, busy false
Attach Image… at (-19.5, 53.0, 28.0, 28.0) outside (0.0, 0.0, 309.0, 96.0)
Send at (298.5, 52.0, 30.0, 30.0) outside (0.0, 0.0, 309.0, 96.0)
SPLIT 920×628, sidebar 420.0, file true, busy true: chat=249.0, minimum=469.0, file=249.0
Executed 2 tests, with 99 failures (0 unexpected)
```

After the fix (`split-green.log`): **2 passed, 0 failed**. The same default-sidebar
scene measures `chat=400.0, minimum=400.0, file=218.0` while idle and
`chat=469.0, minimum=469.0, file=149.0` while busy, at both heights.

After the drag-origin correction (`split-drag-green.log`): **3 passed, 0 failed**.
Both mutations were then tested and restored:

- Replace `max(proposedMainWidth, ceil(minimum))` with `proposedMainWidth`:
  **3 tests failed, 104 expected assertion failures** (`split-minimum-mutation.log`).
  The matrix again reports 309 < 400/469 and clipped controls.
- Replace the visible drag-origin calculation with the stored `sideFraction`:
  **2 passed, 1 failed, 2 expected assertion failures** (`split-drag-mutation.log`).
  The 12-point drag again stays at 400 instead of reaching 412.

The first width-mutation attempt (`split-mutation.log`) stopped at compilation:
the strict unused-variable check rejected the now-unused `minimum` binding.
That attempt is not counted as mutation evidence. Removing the unused binding
along with the reservation produced the actual test failures above.

The nearby right-pane/side-pane minimum and proposal handling already exists
and is unchanged; its focused parity class is included below. No helper, wire,
permission, capture, credential or persistence behavior changes in this follow-up.

### Gallery inspection

`WorkspaceSplitGalleryTests`: **1 passed, 0 failed**, with all **16 PNGs viewed**
in `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-split`.
The scenes are Aqua / Dark Aqua × 920×800 / 920×628 × file open / closed ×
idle / busy, using a generated text file, synthetic chat and memory vault.
Every composer control, including Attach at the left and Send/Queue/Stop at the
right, is visible inside the card and chat. Closing the file restores the wider
composer, and opening it selects the existing compact control forms. The file
retains its tab and horizontal scrolling while using the smaller remainder.
The capture run held the shared full-lane lock throughout; viewing the saved
PNGs required no app activation. The gallery command is included below.

### Focused validation commands and results

Text evidence lives under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
All native runs used this workstream's build root and held the shared full-lane
lock for their run, releasing it in `finally`. Serial-lane classes ran alone.
Helper/wire suites were not rerun because this follow-up changes only app layout
and tests.

Final focused runs after restoring both mutations: **153 passed, 0 failed,
0 skipped**. No unrelated test failures.

| Class | Passed | Failed | Text log |
| --- | ---: | ---: | --- |
| WorkspaceSplitTests | 3 | 0 | split-final.log |
| WorkspaceSplitGalleryTests | 1 | 0 | split-gallery.log |
| WorkspaceRootTests | 7 | 0 | split-workspace-root.log |
| SmoothShellTests | 5 | 0 | split-smooth-shell.log |
| ShellComposerTests | 5 | 0 | split-shell-composer.log |
| ConversationPaneTests | 81 | 0 | split-conversation-pane.log |
| ComposerBarLayoutTests | 7 | 0 | split-composer-bar.log |
| GitPanelNarrowParityTests | 8 | 0 | split-right-pane-parity.log |
| TabPaneTests | 10 | 0 | split-tabs-and-files.log |
| FileTabTests | 16 | 0 | split-tabs-and-files.log |
| FileHiddenReadTests | 5 | 0 | split-tabs-and-files.log |
| SmoothPaneAndKeyboardTests | 4 | 0 | split-tabs-and-files.log |
| WorkspaceRedrawTests | 1 | 0 | split-redraw.log |

Unrelated fixture diagnostic, recorded without expanding the fix:
`ConversationPaneTests` passed all 81 tests but printed 210
SQLite `vnode unlinked while in use` diagnostics during generated-store teardown
(`split-conversation-pane.log`). Its unchanged `Pane.close()` immediately removes
the directory after `model.shutdown()` in
`apps/macos/PiAppTests/ConversationPaneFixture.swift:87–88`, without awaiting
store closure. The new split fixture uses `registerWorkspaceFixtureTeardown`;
its regression and gallery logs contain no such diagnostics.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles

# split-red.log, split-green.log, split-drag-green.log,
# split-minimum-mutation.log, split-drag-mutation.log, split-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests

# split-drag-red.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testDraggingRightStartsAtTheVisibleMinimumBoundary

# split-gallery.log
TEST_RUNNER_PI_WORKSPACE_SPLIT_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-split scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitGalleryTests

# split-workspace-root.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRootTests

# split-smooth-shell.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SmoothShellTests

# split-shell-composer.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ShellComposerTests

# split-conversation-pane.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests

# split-composer-bar.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ComposerBarLayoutTests

# split-right-pane-parity.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests

# split-tabs-and-files.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TabPaneTests -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/SmoothPaneAndKeyboardTests

# split-redraw.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRedrawTests
```
