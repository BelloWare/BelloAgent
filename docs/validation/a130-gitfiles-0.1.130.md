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

## Side-conversation split review follow-up

The review finding is **confirmed and fixed**. The preceding layout fix applied
the file-only yielding policy to `RightPaneView` even when it held a saved side
conversation. At 920×628/800 with a 300-point sidebar and two connections, the
main chat took 400 points and left 218 for the side's 336-point body. Send ended
at x=652 and Close side at x=662 in a region ending at x=619. The independent
proportional reference placed them at x=606.5 and x=616.5 respectively, both
visible. All measurements below use points relative to that content region.

The split now distinguishes these cases:

- No side conversation: retain the file-only fix, including compact composer
  forms, saved fraction, window minimum and drag behavior.
- A side conversation, including one covered by a file: measure both composers
  against the original proportional proposals. When their rounded minima fit,
  main width is `mainMinimum + floor(spareWidth * savedFraction)` and the side
  gets its minimum plus the remaining spare width. Proposals stay independent
  of the resulting allocations, avoiding feedback between form selection and
  minimum reservation.
- If both minima cannot fit: use the original `SplitPane.mainWidth` result
  exactly, as explicitly requested by the owner. At width 920 the allocation
  is 309/309 with sidebar 300, or 249/249 with sidebar 420, for idle and busy
  sessions alike. The saved fraction and 920×628 window minimum are unchanged.

Nearby cases covered by the same change: a side's Stop/Steer controls changing
its minimum without a window resize; creating/removing a side under an open
file; and a drag crossing a composer-form threshold. `RightPaneView` propagates
size changes to the split. Side drags divide their movement by spare width and
retain the starting scale until mouse-up, so a changed form cannot make release
jump to another split. Standalone right panes retain their allocated-width
proposals and their released body layout.

### Failing-first evidence and regression coverage

Evidence prefix: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/`.
Production code was unchanged for `side-split-before.log`: **7 tests, 4 failed
test methods, 112 assertion failures**; the three existing file-only methods
passed. New methods:

| Test in WorkspaceSplitTests | Coverage |
| --- | --- |
| testSideConversationKeepsTheReleasedSplitWhenBothMinimaCannotFit | 920×800 and 920×628; sidebar 300/420; independent main/side idle and busy states; exact old widths and Send/Queue/Stop/Close positions |
| testSideConversationReservesBothMinimaAndSharesSlackByTheSavedFraction | Both minima and saved-fraction slack allocation; 1240 and 1800 points; fractions 0.3/0.5/0.7; independent busy states |
| testSideSplitDragAndBusyChangesUseTheSpaceBeyondBothMinima | Drag movement at stable forms, release after a form change, side-only busy transitions at 1800 and 2400 points |
| testCoveredSideKeepsItsMinimumUntilRemovedFromTheFilePane | Opening a side under a file invokes the side policy; removing it restores file-only reservation |

The visibility oracle mounts a separate `RightPaneView` with the same synthetic
saved side and controls, manually allocating the released proportional widths.
It bypasses `WorkspaceChatsLayer`. If both minima cannot fit, every action's
horizontal bounds must equal the reference; every previously visible action
must remain visible. When minima fit, both allocations must satisfy them and
all tested side actions must lie within the region. The original file-only
matrix still checks every composer control against its composer and chat bounds.

Representative failing-first assertions (`side-split-before.log`):

```text
XCTAssertEqualWithAccuracy failed: ("400.0") is not equal to ("309.0")
XCTAssertEqualWithAccuracy failed: ("218.0") is not equal to ("309.0")
XCTAssertLessThanOrEqual failed: ("652.0") is greater than ("619.0") - ... Send must remain visible
XCTAssertLessThanOrEqual failed: ("662.0") is greater than ("619.0") - ... Close side must remain visible
```

An intermediate run (`side-split-after.log`) passed the allocation/visibility
cases but failed three drag assertions. Two were fixture assumptions: busy
controls can select a smaller form, and a 12-point movement at 1800 can cross a
form threshold. The corrected test checks minimum changes in either direction,
uses 2400 for stable-form movement, and retains 1800 for the threshold case.
Its fresh failing-first run (`side-split-drag-before.log`, **1 test, 1 failure**)
isolated the real mouse-up jump before fixing the drag scale:

```text
XCTAssertEqualWithAccuracy failed: ("783.0") is not equal to ("972.0") +/- ("1.0") - Ending the drag keeps the divider in place, even if a control form changed
```

After the fix, `side-split-green.log`: **7 passed, 0 failed**.

Four isolated mutations were caught, then restored in `finally`:

| Mutation | Regression | Result | Log |
| --- | --- | --- | --- |
| In the insufficient-space branch, restore main-only reservation | testSideConversationKeepsTheReleasedSplitWhenBothMinimaCannotFit | 1 test, 1 failure: 400 != 309 | side-split-mutation-fallback-first-failure.log |
| Replace the both-minima allocation with the proportional width even when both fit | testSideConversationReservesBothMinimaAndSharesSlackByTheSavedFraction | 1 test, 32 failures: e.g. 469 != 461 | side-split-mutation-reserve.log |
| Stop RightPaneView from forwarding size changes to its parent | testSideSplitDragAndBusyChangesUseTheSpaceBeyondBothMinima | 1 test, 6 failures: side-only busy leaves main at 972 instead of 925 | side-split-mutation-side-size.log |
| Stop retaining the drag's initial spare-width scale | testSideSplitDragAndBusyChangesUseTheSpaceBeyondBothMinima | 1 test, 1 failure: mouse-up jumps from 972 to 783 | side-split-mutation-drag.log |

The full fallback-mutant matrix first reported the expected geometry/visibility
assertions, then hit AppKit's repeated-layout-pass guard after resizing the
reference window (`side-split-mutation-fallback.log` and `-fallback-repeat.log`;
neither has a completed XCTest count). The completed mutation run above set
XCTest's `continueAfterFailure = false` temporarily, keeping the assertions
unchanged and stopping at the first failed width assertion. Both the mutation
and this fail-fast setting were restored before final validation. No such
layout exception occurred in `side-split-green.log`.

### Narrow fallback limitation retained by owner request

Both control minima exceed the available width in every 920-point side-chat
fixture. Idle minima are 400/336; busy minima are 469/405. The fallback preserves
0.1.129 geometry, including its existing clipping; it does not claim that both
composers fit. For example, with sidebar 300, a busy side's Stop ends at x=641
and Close side at x=651 beyond the x=619 region edge. With sidebar 420, even
idle Send ends at x=516.5 and Close side at x=526.5 beyond the x=499 edge. Those
bounds exactly match the proportional reference, while idle Send/Close at
sidebar 300 remain visible. This is the owner's explicit conservative fallback;
changing that existing narrow UX would require a separate owner decision.

### Follow-up gallery inspection

`WorkspaceSplitGalleryTests`: **2 passed, 0 failed, 0 skipped**. Captured with
the shared full-lane lock held throughout, using only generated files, memory
vaults and synthetic chat states. All **28 PNGs were opened and visually
inspected**, without activating another app:

- `build-a130-gitfiles/gallery-side-split/sides`: 12 images, Aqua/Dark Aqua ×
  idle/busy × 920×628/sidebar 300, 920×628/sidebar 420, 1800×800/sidebar 300.
  At sidebar 300, idle Send and Close side are visible. The narrow busy/420
  scenes show the documented released overflow. The 1800-point scenes keep
  both composers and Send/Queue/Stop/Close side fully visible in both themes.
- `build-a130-gitfiles/gallery-side-split/files`: 16 images, Aqua/Dark Aqua ×
  920×800/920×628 × file open/closed × idle/busy. The file-only fix still keeps
  all main composer controls inside the chat; the file uses the remainder and
  retains horizontal scrolling.

These folders are under `/Users/admin/Library/Caches/BelloSwiftWork/`. The
gallery assertions also compare every side scene to its independent reference
or verify both minima, as appropriate. Text evidence: `side-split-gallery.log`.

### Follow-up focused validation

Final restored-source runs: **197 passed, 0 failed, 0 skipped** across the 15
classes below. Every native run held the shared full-lane lock and released
only its own lock in `finally`; serial-lane classes ran alone. All builds used
this workstream's existing build root. No extra DerivedData root or clone
folder was created. No helper/wire behavior changed, so those suites were not
rerun for this app-layout follow-up.

| Class | Passed | Failed | Text log |
| --- | ---: | ---: | --- |
| WorkspaceSplitTests | 7 | 0 | side-split-final.log |
| WorkspaceSplitGalleryTests | 2 | 0 | side-split-gallery.log |
| WorkspaceRootTests | 7 | 0 | side-split-workspace-root.log |
| SmoothShellTests | 5 | 0 | side-split-smooth-shell.log |
| ShellComposerTests | 5 | 0 | side-split-shell-composer.log |
| ConversationPaneTests | 81 | 0 | side-split-conversation-pane.log |
| ComposerBarLayoutTests | 7 | 0 | side-split-composer-bar.log |
| GitPanelNarrowParityTests | 8 | 0 | side-split-right-pane-parity.log |
| WorkspaceRedrawTests | 1 | 0 | side-split-redraw.log |
| FileHiddenReadTests | 5 | 0 | side-split-tabs-and-files.log |
| FileTabTests | 16 | 0 | side-split-tabs-and-files.log |
| SmoothPaneAndKeyboardTests | 4 | 0 | side-split-tabs-and-files.log |
| TabPaneTests | 10 | 0 | side-split-tabs-and-files.log |
| FileFolderTests | 19 | 0 | side-split-file-folder.log |
| FileReviewStateTests | 20 | 0 | side-split-file-review.log |

No unrelated test failures. The existing generated-store teardown diagnostic
from `ConversationPaneFixture.swift:87–88` appeared 213 times in
`side-split-conversation-pane.log` (`vnode unlinked while in use`), with all 81
asserting tests passing. As in the earlier follow-up, this is recorded without
changing that unrelated fixture. None of the final restored-source runs hit
AppKit's layout-pass guard. The new split regression/gallery fixtures use
`registerWorkspaceFixtureTeardown`.

Exact commands below were run from this worktree under the lock wrapper
`build-a130-gitfiles/evidence/run-split-check.py`. The galleries used both opt-in
variables; no gallery tests were skipped. Logs and the command ledger remain
under the evidence directory named above.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles

# side-split-before.log, side-split-after.log, side-split-green.log, side-split-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests

# side-split-drag-before.log, side-split-mutation-side-size.log, side-split-mutation-drag.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragAndBusyChangesUseTheSpaceBeyondBothMinima

# side-split-mutation-fallback.log, -fallback-repeat.log, -fallback-first-failure.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideConversationKeepsTheReleasedSplitWhenBothMinimaCannotFit

# side-split-mutation-reserve.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideConversationReservesBothMinimaAndSharesSlackByTheSavedFraction

# side-split-gallery.log
TEST_RUNNER_PI_WORKSPACE_SPLIT_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-side-split/files \
TEST_RUNNER_PI_WORKSPACE_SPLIT_SIDE_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-side-split/sides \
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitGalleryTests

# side-split-workspace-root.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRootTests

# side-split-smooth-shell.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SmoothShellTests

# side-split-shell-composer.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ShellComposerTests

# side-split-conversation-pane.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests

# side-split-composer-bar.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ComposerBarLayoutTests

# side-split-right-pane-parity.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests

# side-split-redraw.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRedrawTests

# side-split-tabs-and-files.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TabPaneTests -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/SmoothPaneAndKeyboardTests

# side-split-file-folder.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests

# side-split-file-review.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests
```

## Proportional split review correction

The lead's review of `577ab0a3` supersedes the preceding section's instruction
to divide spare room by the saved fraction. That formula changed valid wide
splits and made dragging depend on control widths. This follow-up restores the
released fraction's meaning.

For a side conversation, compute the original `SplitPane.mainWidth` proposal.
If both control minima fit, clamp that proposal between the main minimum and
usable width minus the side minimum. If they cannot fit, return the proposal
exactly. Minima retain the existing whole-point rounding; neither this fix nor
a busy-state change rewrites the preference. File-only allocation is unchanged.
The saved fraction remains a fraction of the whole region during a drag. A new
drag starts from the visible divider when either minimum has moved it; an
unclamped divider keeps the exact saved fraction, avoiding a rounding jump.
`dragWidth` and the cached slack denominator are removed.

### Failing-first evidence and coverage

Production was still at `577ab0a3` for both independent baseline runs below.
The native fixtures use two generated connections, saved side records and
synthetic idle/busy states, without starting a provider or helper request.

- `testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit`:
  4000/4600-point windows, fractions 0.3/0.5/0.7, independent main/side busy
  states (24 scenes). The independent proportional reference first verifies
  that both original allocations already fit, then compares both `CGRect`s
  exactly. `proportional-frames-before.log`: **1 test failed, 96 expected
  assertion failures, 0 unexpected**. No fixture-premise assertion failed.
- `testSideSplitDragKeepsTheWholeRegionFraction`: 1800/2400-point windows,
  12-point motion, fraction before/after mouse-up, and a side-only busy change
  whose new minimum still fits. `proportional-drag-before.log`: **1 test
  failed, 23 expected assertion failures, 0 unexpected**.

```text
XCTAssertEqual failed: ("(0.0, 0.0, 1427.0, 800.0)") is not equal to ("(0.0, 0.0, 1109.0, 800.0)") - unchanged at 4000.0, fraction 0.3, main busy false, side busy false: unchanged proportional main frame
XCTAssertEqualWithAccuracy failed: ("0.6714285714285715") is not equal to ("0.5080053368912608") +/- ("1e-06") - A drag is a fraction of the whole region
```

An earlier combined probe (`proportional-split-before.log`, 2 tests/2 failures)
used XCTest's `continueAfterFailure = false`; its async matrix continued after
teardown and attributed another frame failure to the next test. That setting
was removed, the wide fixtures were enlarged so every form's minimum fits,
and the independent runs above supply the clean baseline evidence.

The first fixed-source run, `proportional-split-after.log`, passed **10/10**.
The existing narrow matrix remains: 920×800/920×628, sidebar 300/420,
independent main/side idle/busy, original fallback frames and every previously
visible Send/Queue/Stop/Close side action. File-only tests still check all main
composer controls inside their bounds with the file open/closed, at both
heights and both sidebar widths. The updated clamp matrix covers 1240/1800
windows and fractions 0.3/0.5/0.7.

Two additional tests challenge clamp transitions:

- `testSideSplitDragStartsAtEitherVisibleClampBoundary`: main minimum clamps
  449 to 469 at fraction 0.3; the side minimum clamps 726 to 702 at fraction
  0.7. Motion inwards from either visible divider updates the whole-region
  fraction and does not jump at mouse-up.
- `testSideMinimumChangesRecheckTheClampAndProportionalFallback`: at 1340,
  main busy and fraction 0.7, changing only the side from idle to busy to idle
  produces main/side widths 702/336 → 726/312 → 702/336. The middle state cannot
  fit both minima, so it uses the exact proportional fallback. Fraction 0.7
  remains stored throughout.

The prior narrow fallback limitation remains explicitly owner-directed:
existing 0.1.129 clipping at 920/sidebar 420 or a busy side is retained, while
controls that were visible in 0.1.129 keep their original positions. No new
product decision is needed for this correction.

### Correction mutation checks

Each mutation changed only production allocation/drag code and was restored in
`finally`. All three valid mutation runs exited 65 because the targeted test
assertions failed; none had an unexpected failure.

| Deliberate regression | Test | Expected failures | Text log |
| --- | --- | ---: | --- |
| Replace the clamp with `mainMinimum + floor(slack * fraction)` | `testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit` | 96 (1 test) | proportional-mutation-slack.log |
| Divide both drag callbacks by slack instead of region width | `testSideSplitDragKeepsTheWholeRegionFraction` | 7 (1 test) | proportional-mutation-drag.log |
| Start a side drag at the stored fraction even when clamped | `testSideSplitDragStartsAtEitherVisibleClampBoundary` | 6 (1 test) | proportional-mutation-visible-origin.log |

The slack mutation reproduces the baseline 1427-versus-1109 frame failure.
The drag mutation reports 0.6714285714 instead of 0.5080053369 and a mouse-up
jump. The visible-origin mutation leaves the lower clamp at 469 instead of
481 and the upper clamp at 702 instead of 690. A first visible-origin mutation
left an unused local and failed compilation (`proportional-mutation-visible-start.log`);
that attempt is excluded from the assertion evidence. The corrected mutation
removes the unused local and reaches the native test.

### Regenerated galleries and adversarial self-review

`WorkspaceSplitGalleryTests`: **2 passed, 0 failed, 0 skipped**, with both
opt-in variables set. The full-lane lock was held for the entire native capture
and released afterwards. All **28 PNGs were opened and visually inspected**
from disk, without activating another app:

- `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-proportional-split/sides`:
  12 images, light/dark × idle/busy × 920×628/sidebar 300,
  920×628/sidebar 420, and 1800×800/sidebar 300. At 1800, the main and side
  remain exactly 749/749 with all composer actions and Close side visible.
  At 920/sidebar 300, idle side Send and Close side remain visible. The busy
  and sidebar-420 scenes show the documented original overflow; the native
  reference assertions confirm unchanged action coordinates.
- `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-proportional-split/files`:
  16 images, light/dark × idle/busy × 920×800/920×628 × file open/closed.
  All main composer controls remain inside the main pane. The file pane yields
  room and retains its horizontal scrollbar.

Adversarial self-review covered the **entire branch diff from `5c52621c`**, not
only the correction to `577ab0a3`: the two preceding layout commits, this fix,
all new tests, the generated project entries and the validation/release notes.
The review specifically checked:

- The original proportional helper, fraction bounds, divider rounding and
  drag denominator are unchanged. Valid proposals are returned exactly;
  lower/upper clamps and the impossible-minima fallback are separate cases.
  File-only allocation and visible drag start remain the first fix's policy.
- Main and side composer forms use their original proportional proposals,
  preventing allocation/minimum feedback. A file covering a mounted side
  retains that side's minimum, while removing the side restores the file-only
  policy. Standalone right panes keep the actual-width proposal.
- Side control-size notifications reach the ancestor split. A side-only busy
  change can move from clamp to fallback and back without changing the stored
  fraction; it does not move an already valid split. Mouse-up uses the same
  captured start as drag motion, including both visible clamp boundaries.
- The reference allocates native panes independently of `WorkspaceChatsLayer`;
  the exact-frame test checks its fit premises before comparing frames. The
  fallback tests compare the actual Send/Queue/Stop/Close side geometry with
  the original proportional reference, not just a duplicate width formula.
- The diff adds no provider, helper, permission, capture, tool, vault, data,
  focus or page-visibility behavior. The generated project diff only registers
  `WorkspaceSplitTests.swift`. Fixtures restore isolated test preferences and
  use the workspace teardown helper.

No additional regression was found in this review. The retained narrow
fallback limitation is documented above rather than silently changing the
owner's requested 0.1.129 behavior.

### Correction focused validation

Final restored-source runs: **200 passed, 0 failed, 0 skipped** across 15
classes. All focus-changing native runs held the shared full-lane lock and
released only their own lock in `finally`; serial classes ran alone. Reused
this workstream's build root. No extra DerivedData root or clone directory was
created. No helper or wire code changed, so those suites were not rerun.

| Class | Passed | Failed | Text log |
| --- | ---: | ---: | --- |
| WorkspaceSplitTests | 10 | 0 | proportional-split-final.log |
| WorkspaceSplitGalleryTests | 2 | 0 | proportional-split-gallery.log |
| WorkspaceRootTests | 7 | 0 | proportional-split-workspace-root.log |
| SmoothShellTests | 5 | 0 | proportional-split-smooth-shell.log |
| ShellComposerTests | 5 | 0 | proportional-split-shell-composer.log |
| ConversationPaneTests | 81 | 0 | proportional-split-conversation-pane.log |
| ComposerBarLayoutTests | 7 | 0 | proportional-split-composer-bar.log |
| GitPanelNarrowParityTests | 8 | 0 | proportional-split-right-pane-parity.log |
| WorkspaceRedrawTests | 1 | 0 | proportional-split-redraw.log |
| FileFolderTests | 19 | 0 | proportional-split-file-folder.log |
| FileReviewStateTests | 20 | 0 | proportional-split-file-review.log |
| TabPaneTests | 10 | 0 | proportional-split-tabs-and-files.log |
| FileTabTests | 16 | 0 | proportional-split-tabs-and-files.log |
| FileHiddenReadTests | 5 | 0 | proportional-split-tabs-and-files.log |
| SmoothPaneAndKeyboardTests | 4 | 0 | proportional-split-tabs-and-files.log |

No unrelated test failed. Existing generated-store teardown diagnostics remain:
`vnode unlinked while in use` appeared 210 times in the ConversationPane log
and 9 times in the GitPanelNarrowParity log (also 9 in the preceding follow-up's
parity log). `ConversationPaneFixture.swift:87–88` and
`GitPanelNarrowParityTests.swift:77,284` remove their generated stores without
awaiting shutdown. Those unrelated fixtures are unchanged. No final run hit
AppKit's layout-pass guard; the split regression/gallery logs contain none of
these SQLite diagnostics.

Exact commands follow, run from the assigned worktree under
`build-a130-gitfiles/evidence/run-split-check.py`. The text logs, command ledger
and mutation runner are in that evidence folder. No named result bundle was
requested. The gallery opt-ins were both set; all images were inspected as
recorded above.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles

# proportional-split-before.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragKeepsTheWholeRegionFraction

# proportional-frames-before.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit

# proportional-drag-before.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragKeepsTheWholeRegionFraction

# proportional-split-after.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests

# proportional-mutation-slack.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit

# proportional-mutation-drag.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragKeepsTheWholeRegionFraction

# proportional-mutation-visible-start.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragStartsAtEitherVisibleClampBoundary

# proportional-mutation-visible-origin.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests/testSideSplitDragStartsAtEitherVisibleClampBoundary

# proportional-split-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitTests

# proportional-split-gallery.log
TEST_RUNNER_PI_WORKSPACE_SPLIT_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-proportional-split/files \
TEST_RUNNER_PI_WORKSPACE_SPLIT_SIDE_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/gallery-proportional-split/sides \
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceSplitGalleryTests

# proportional-split-workspace-root.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRootTests

# proportional-split-smooth-shell.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SmoothShellTests

# proportional-split-shell-composer.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ShellComposerTests

# proportional-split-conversation-pane.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationPaneTests

# proportional-split-composer-bar.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ComposerBarLayoutTests

# proportional-split-right-pane-parity.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/GitPanelNarrowParityTests

# proportional-split-redraw.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/WorkspaceRedrawTests

# proportional-split-file-folder.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileFolderTests

# proportional-split-file-review.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileReviewStateTests

# proportional-split-tabs-and-files.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TabPaneTests -only-testing:PiAppTests/FileTabTests -only-testing:PiAppTests/FileHiddenReadTests -only-testing:PiAppTests/SmoothPaneAndKeyboardTests
```

## Round 2 hunt

Work starts from merged `6fc551e1` on `dev/a130-gitfiles`, in the same
worktree and build root. The earlier split fixes are already in that base.
All six assigned findings are confirmed. No helper implementation, wire
contract, project trust, permission, capture, vault, or production path changes.

Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/round2-*`.
Native runs use the isolated test host and this workstream's existing
`native-tests` directory, with text logs. Each native run, including the
galleries, acquires the shared full-lane lock and releases only its own lock
in `finally`. Serial-lane classes run alone. The installed app was never opened.

### Findings and failing-first evidence

**GIT-FILES-5 — confirmed and fixed.**
`testResizingTheAlternateScreenPreservesTheHiddenShellAndCursor` feeds the
reported 10×4 sequence and shrinks to two rows while mode 1049 is active.
Before the fix (`round2-terminal-before.log`):

```text
XCTAssertEqual failed: (["one", "two"]) is not equal to (["three", "four"])
XCTAssertEqual failed: ([]) is not equal to (["one", "two"])
```

The hidden normal screen now uses the same row-resize routine as the visible
normal screen: discard blank rows below the cursor first, archive displaced
top rows, and restore history when growing. Wrap boundaries and history
accounting travel with the cells. Its active and saved cursors move with the
rows before clamping to the new bounds. Alternate-screen rows never enter
normal scrollback.

Nearby sweep: `testHiddenNormalResizeMatchesVisibleResizeIncludingHistoryAndWraps`
compares visible and hidden resizing across modes 47/1047/1049, shrink/grow
sequences, blank tails, existing history, styled text, wide characters and
soft wraps. The old code failed the comparison; together with the mode-47
save test, `round2-terminal-sweep-before.log` records 2 failing tests and
61 failed assertions. This covers the hidden growth path as well as shrinking.

**GIT-FILES-6 — confirmed and fixed.**
`testAlternateCursorSavesDoNotOverwriteTheNormalCursor` runs the exact
reported sequence, plus the equivalent CSI `s` and DEC mode 1048 saves.
`testAlternateCursorSavesDoNotOverwriteTheNormalAttributes` checks normal
foreground/bold attributes and autowrap after an alternate save. Before fixing:

```text
XCTAssertEqual failed: (["maiX", "", ""]) is not equal to (["main", "X", ""])
XCTAssertEqual failed: (TerminalCursor(x: 4, y: 0)) is not equal to (TerminalCursor(x: 1, y: 1))
XCTAssertFalse failed                 # normal autowrap was overwritten
```

The three original terminal regressions produced 11 failed assertions.
Saved cursor position, style, origin, autowrap, pending wrap and character
sets now belong to each screen. Mode 1049 saves before entering and restores
after leaving the alternate screen, so its normal save cannot be overwritten
there. CSI `s`/`u` retain their existing position-only semantics.
This matches the per-screen save/restore storage in
[xterm's cursor implementation](https://raw.githubusercontent.com/ThomasDickey/xterm-snapshots/master/cursor.c).

Nearby sweep: `testEachScreenKeepsItsSavedCursorAcrossMode47Switches` failed
both position and foreground assertions before the fix. It now checks that
both screens retain their own saves across repeated mode-47 entries.
The resize matrix also checks that the normal saved row follows history
restoration, rather than jumping back to its pre-growth coordinate.

Separate, trivial same-function sweep fix: `reset()` used to clear saved
position/style while retaining saved origin, autowrap, pending wrap and
character sets. `testResetClearsSavedCursorModesAndCharsetsOnBothScreens`
saves nondefault modes and DEC graphics on both screens, feeds RIS (`ESC c`),
then restores each save. `round2-terminal-reset-before.log` has 1 failing test
and 6 failed assertions: autowrap stayed off, origin stayed on, and `q` drew
as `─` in each screen. Reset now creates fresh saved states for both screens.

Separate same-function sweep fix: `switchScreen` unconditionally cleared
pending wrap after restoring it. `testLeavingTheAlternateScreenRestoresTheNormalsPendingWrap`
fills a four-column normal line with `main`, enters/leaves 1049, then prints
`X`, with no alternate save and with each supported save form. It failed all
8 assertions: `maiX` instead of `main` / `X`. The before log is
`round2-terminal-wrap-before.log` (the other 68 tests in that run passed).
1049 now preserves pending wrap when the grid was not resized. A companion
comparison, `testAlternateResizeKeepsTheNormalScreensExistingWrapBehavior`,
caught 8 assertions where simply preserving wrap would change existing resize
behavior. The hidden grid records whether a real resize occurred; actual
resizes still clear pending wrap exactly as a visible normal resize does,
including resizing away and back. A no-op resize preserves the saved wrap.
Evidence: `round2-terminal-resized-wrap-before.log`.

**GIT-FILES-7 — confirmed and fixed.**
`testPaintingBeforeOpenDoesNotCacheAnEmptyFirstLine` holds `Options.beforeOpen`,
mounts and paints the actual `FileTab`, verifies its syntax callback was
invoked, and lets the initial syntax task settle before releasing the reader.
After `.ready`, it checks keyword and number ranges and colours for
`let value = 1\n`. The nearby growing-line case uses four-byte chunks and
holds the second chunk in `testPaintingAGrowingLineDoesNotCacheItsPartialTokens`.
Both failed before fixing (`round2-syntax-before.log`, 2 tests, 6 assertions):

```text
XCTAssertTrue failed - syntax fixture did not finish
XCTAssertEqual failed: ([]) is not equal to ([{0, 3}, {12, 1}])
```

Syntax work now starts only for `isLineFinal` lines. Completed lines remain
cached across indexing arrivals; provisional lines cannot install stale
tokens even though indexing leaves the document generation unchanged.
The bounded reader, checkpoints, suspension and generation checks are unchanged.

**TOOLING-CONFIG-1 — confirmed and fixed, tested only with fakes.**
`SpendingFailureTests` exercises the real scenario loop, polling and report
writer in process with fake sessions, histories and corpus. `Helper` and
`socket.socket` are patched to fail if reached; no live CLI, real helper,
credential, user data or provider call runs in these tests.
The fake polling sequence observes a billed $0.80 response and then loses the
helper. All three scenario entry points are covered. Before fixing
(`round2-spending-before.log`, 4 tests, 9 failing subtests):

```text
AssertionError: Lists differ: ['compact-now', 'mid-run', 'too-large'] != ['compact-now']
AssertionError: None != 0.8             # failed scenario had no cost record
AssertionError: 3 != 1                 # later scenarios still dispatched
```

Each scenario keeps ownership through exception accounting and closes in
`finally`. A settled, numeric, finite, non-negative cost is counted once before
disposal. If request collection failed, its whole recovered spend supplies a
conservative request-size reserve. Missing, invalid or still-running accounting
sets a sticky unknown-spend flag: the budget becomes zero, further live
scenarios stop, and the JSON total is `null` with a separately labelled known
subtotal. Text reports say `unknown`, including the cost-check detail.
Recovered helper unreported-request counts also stop further dispatch, even
when request collection never completed; their total is also unknown while
the reported subtotal is retained. Successful accounting keeps the
previous whole-run budget and largest-request reserve.

Nearby sweep covers all three early-close paths, failure during final status
accounting, unknown/invalid costs, and a broken pipe during session disposal.
The broken-pipe test failed with `BrokenPipeError: fake closed pipe` before
adding `OSError` to that close handler. Two review regressions caught Python's
`False` being accepted as a numeric zero and a cost-check detail printing a zero
run total for unknown spend; both were fixed before final validation. A third
report check rejects treating the recovered reported subtotal as the whole
total when other requests have no price.
Malformed status/cost objects, overflowed numbers and invalid/missing request
counters also fail closed. The expanded regression initially failed 8 subtests
(`round2-spending-malformed-before.log`); these accounting failures now mark
spending unknown rather than escaping accounting and leaving the budget intact.

**TOOLING-CONFIG-2 — confirmed and fixed.**
`PerformanceWrapperTests.test_an_earlier_failed_invocation_is_not_masked_by_later_success`
uses a fake `xcodebuild` that returns 65 once, then zero. Before fixing:

```text
AssertionError: 0 == 0
exit 65 Executed 1 tests
exit 0 Executed 1 tests
done
```

The wrapper retains the first nonzero status while still running later rounds,
and exits with it. The same check covers a failing soak followed by successful
`soakdraw`, including its temporary `ROUNDS=1` override. Successful runs still
return zero. Generated `.xctestrun` products pass the real test-host isolation
validator; the fake command never launches a native test or app.

**TOOLING-CONFIG-3 — confirmed and fixed.**
`test_relative_output_runs_tests_and_writes_logs_directly_in_that_folder`
invokes the wrapper from a temporary working directory with `results`.
Before fixing, the fake command was never invoked:

```text
AssertionError: False is not true
results/baseline-1.log: No such file or directory
```

Both derived-data and output paths are resolved before changing directory;
creation and navigation failures terminate immediately. Nearby regressions
also reproduced relative derived-data failure and a non-directory output
returning zero. The original wrapper suite had 4 failures out of 5 tests;
the sixth test adds soak status coverage. Spaces in generated paths are covered.
Self-review added a seventh regression for an output directory ending in a
newline, with a separate sibling log containing a sentinel. The initial
`$(pwd)` normalization trimmed that newline and overwrote the sibling's
generated log (`round2-perf-whitespace-before.log`). Prefixing relative paths
with the shell's absolute working directory preserves their bytes and avoids
that regression; the target log now appears in the requested directory only.

### Round 2 mutation checks and focused validation

All mutations are temporary and restored in `finally`; failures must contain
the named XCTest assertion failures or unittest failure summary, not merely a
build failure. The final focused runs use the restored fixes.

| Finding | Mutation | Result / text log |
| --- | --- | --- |
| GIT-FILES-5 | Replace hidden row resizing with the old prefix fit | Both regressions fail, 59 assertions; `round2-terminal-resize-mutation.log` |
| GIT-FILES-5 sweep | Remove the hidden normal saved-cursor row adjustment | Resize matrix fails 3 cursor assertions; `round2-terminal-cursor-resize-mutation.log` |
| GIT-FILES-6 | Make both screens use saved-cursor slot zero | All 3 cursor/attribute/mode-47 tests fail, 13 assertions; `round2-terminal-cursor-save-mutation.log` |
| GIT-FILES-6 Reset sweep | Restore position/style-only Reset | Test fails 6 assertions; `round2-terminal-reset-mutation.log` |
| GIT-FILES-6 pending-wrap sweep | Restore the unconditional pending-wrap clear | Test fails 8 assertions; `round2-terminal-wrap-mutation.log` |
| GIT-FILES-6 resize preservation | Forget that the hidden grid was resized | Test fails 8 assertions; `round2-terminal-resized-wrap-mutation.log` |
| GIT-FILES-7 | Remove the final-line guard | Both opening/growing tests fail, 6 assertions; `round2-syntax-mutation.log` |
| TOOLING-CONFIG-1 | Remove exception accounting, unknown-spend blocking, status/counter validation, settled-state requirement, fallback reserve, pipe handling or unknown-total reporting | All 13 final mutations rejected; `round2-spending-final-*-mutation.log` |
| TOOLING-CONFIG-2 | Force final exit zero | Baseline and soak regressions both fail; `round2-perf-final-exit-mutation.log` |
| TOOLING-CONFIG-3 | Remove output/product path normalization; reintroduce newline-trimming normalization | Each targeted regression fails; `round2-perf-final-{output,products,whitespace}-mutation.log` |

The native failing-first selectors were:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles

# round2-terminal-before.log: 3 tests fail, 11 assertions
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests/testResizingTheAlternateScreenPreservesTheHiddenShellAndCursor \
  -only-testing:PiAppTests/TerminalEmulatorTests/testAlternateCursorSavesDoNotOverwriteTheNormalCursor \
  -only-testing:PiAppTests/TerminalEmulatorTests/testAlternateCursorSavesDoNotOverwriteTheNormalAttributes

# round2-terminal-sweep-before.log: 2 tests fail, 61 assertions
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests/testHiddenNormalResizeMatchesVisibleResizeIncludingHistoryAndWraps \
  -only-testing:PiAppTests/TerminalEmulatorTests/testEachScreenKeepsItsSavedCursorAcrossMode47Switches

# round2-syntax-before.log: 2 tests fail, 6 assertions
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileSyntaxTests/testPaintingBeforeOpenDoesNotCacheAnEmptyFirstLine \
  -only-testing:PiAppTests/FileSyntaxTests/testPaintingAGrowingLineDoesNotCacheItsPartialTokens

# round2-terminal-reset-before.log: 1 test fails, 6 assertions
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests/testResetClearsSavedCursorModesAndCharsetsOnBothScreens

# round2-terminal-resized-wrap-before.log: 1 test fails, 8 assertions
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests/testAlternateResizeKeepsTheNormalScreensExistingWrapBehavior
```

The pending-wrap regression first failed in the full terminal command below:
`round2-terminal-wrap-before.log` has 69 tests, 68 passed and that one failed
with 8 assertions. Its mutation runs only
`TerminalEmulatorTests/testLeavingTheAlternateScreenRestoresTheNormalsPendingWrap`.

Mutation commands use the same selectors named in the table; the full exact
invocations are also retained in `evidence/split-commands.txt` and
`evidence/round2-final-commands.txt`. Each Python mutation log starts with its
exact unittest command. The original tooling failures used:

```sh
python3 -m unittest scripts.tests.test_live_compaction_e2e.SpendingFailureTests -v
python3 -m unittest scripts.tests.test_perf_transcript -v
```

Final focused commands (same worktree/build root, lock held per native run):

```sh
# round2-terminal-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests \
  -only-testing:PiAppTests/TerminalSoftWrapTests \
  -only-testing:PiAppTests/TerminalViewportTests \
  -only-testing:PiAppTests/TerminalSelectionScrollTests \
  -only-testing:PiAppTests/TerminalHistoryDrawingTests \
  -only-testing:PiAppTests/TerminalCursorAlignmentTests \
  -only-testing:PiAppTests/TerminalPreciseScrollTests \
  -only-testing:PiAppTests/TerminalInverseTests

# round2-terminal-panel.log (serial lane, alone)
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPanelSerialTests

# round2-terminal-audit.log (existing normal-resize/history coverage)
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPanelAuditTests

# round2-file-views.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileTabTests \
  -only-testing:PiAppTests/FileHiddenReadTests \
  -only-testing:PiAppTests/FileTextViewTests

# round2-syntax-gallery-final.log (serial lane, alone)
TEST_RUNNER_PI_ROUND2_GITFILES_GALLERY="$PI_BUILD_ROOT/evidence/round2-gallery" \
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileSyntaxTests

# round2-terminal-gallery-final.log
TEST_RUNNER_PI_ROUND2_GITFILES_GALLERY="$PI_BUILD_ROOT/evidence/round2-gallery" \
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalCaptureTests

# round2-tooling-final.log: 18 tests pass, no skips
python3 -m unittest \
  scripts.tests.test_live_compaction_e2e.SpendingFailureTests \
  scripts.tests.test_live_compaction_e2e.SummaryPromptTests \
  scripts.tests.test_live_compaction_e2e.ConfigurationTests \
  scripts.tests.test_perf_transcript -v

bash -n scripts/perf-transcript.sh
xcodegen generate --quiet
git diff --check
```

Final counts (all restored fixes, no unexpected failures):

| Suite / class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| TerminalEmulatorTests | 25 | 0 | 0 |
| TerminalSoftWrapTests | 11 | 0 | 0 |
| TerminalViewportTests | 7 | 0 | 0 |
| TerminalSelectionScrollTests | 4 | 0 | 0 |
| TerminalHistoryDrawingTests | 4 | 0 | 0 |
| TerminalCursorAlignmentTests | 14 | 0 | 0 |
| TerminalPreciseScrollTests | 4 | 0 | 0 |
| TerminalInverseTests | 1 | 0 | 0 |
| TerminalPanelSerialTests | 18 | 0 | 0 |
| TerminalPanelAuditTests | 8 | 0 | 0 |
| FileHiddenReadTests | 5 | 0 | 0 |
| FileTabTests | 16 | 0 | 0 |
| FileTextViewTests | 45 | 0 | 0 |
| FileSyntaxTests, gallery enabled | 14 | 0 | 0 |
| TerminalCaptureTests, Round 2 gallery enabled | 1 | 1 | 0 |
| SpendingFailureTests, fakes only | 7 | 0 | 0 |
| SummaryPromptTests | 2 | 0 | 0 |
| ConfigurationTests | 2 | 0 | 0 |
| PerformanceWrapperTests, fake xcodebuild | 7 | 0 | 0 |

Native aggregate: **177 passed, 1 skipped, 0 failed**. The skipped test is the
separate legacy terminal capture, whose `PI_APP_UI_SCREENSHOT_ROOT` opt-in is
unset; the new generated-byte gallery passed. Tooling aggregate: **18 passed,
0 skipped, 0 failed**. All 24 final targeted mutation runs failed their
regression assertions as intended; none was accepted on a build failure.

The harness's real-helper fixture class and live CLI were not run: this
finding was explicitly restricted to fakes/stubs. The helper and wire
implementation did not change, so full helper and wire/concurrent/acceptance
lanes are not required for this diff. Python compile checks and Bash syntax
checks pass. Xcodegen leaves the project unchanged. No extra DerivedData or
clone folders were created; the existing build root is reused.

### Round 2 galleries and adversarial self-review

Generated and visually inspected all eight PNGs in
`$PI_BUILD_ROOT/evidence/round2-gallery`, holding the shared full-lane lock
through each capture run:

- `syntax-{light,dark}-{800,420}.png`: the initially held file now shows the
  first-line keyword and number colours after loading, in both appearances
  and at the narrow width. The file controls remain visible.
- `terminal-restored-{light,dark}-{760,360}.png`: after alternate-screen
  resizing, `three` and green `four!` are visible with the cursor after `!`.
  Normal attributes survive the alternate red save. The assertions also
  verify `one` and `two` remain in scrollback.

One unassigned renderer issue is recorded, not changed: in all syntax captures,
the plain `value =` following `let` inherits the keyword's purple, although
the regression verifies that colour runs cover only `let` and `1`.
`packages/bello-views/Sources/FileView/FileTextView.swift:248–251` leaves plain
runs using foreground-from-context while assigning explicit token colours;
`:777–791` sets the context foreground once before drawing the mixed line.
This is the likely cause of the colour bleed. That renderer and the completed
line's colour runs are unchanged by this fix. No separate baseline native
experiment was run for this out-of-scope observation.

Adversarial self-review covers the new diff from `6fc551e1`, including every
changed production condition:

| Condition / state change | States now handled differently; intended result |
| --- | --- |
| Saved-cursor screen index | Alternate saves/restores use their own slot. Normal saves, position-only CSI saves, and mode-47 live-style behavior retain their existing semantics. Mode 1049 switches back to normal before restoring. |
| Hidden-screen resize branch | A saved normal grid now runs the existing cursor-aware row algorithm. The active grid's shrink/grow/blank-tail conditions are unchanged; only the hidden normal grid newly accesses normal history. |
| `normal` history checks | The active screen gets the same `!alternateScreen` value as before. Hidden normal rows archive/restore; alternate rows still cannot enter scrollback. Limits and byte/cell accounting use the existing history routines. |
| Cursor bounds after hidden row movement | A displaced saved row can now become negative; it is clamped to zero, and the saved 1049 row shifts with restored history. Ordinary nonnegative active saves keep their prior bounds. |
| Reset of saved states | Previously saved nondefault modes/character sets now return to initial defaults on RIS, in both screens. This is the separately tested trivial same-function sweep fix. |
| Pending wrap after screen restoration | Only a cursor-restoring exit with no actual grid resize retains the saved pending wrap. Entry, non-restoring exit and any real resize keep the old clearing behavior; no-op resizing does not change it. The resize flag resets on entry and RIS, and survives a resize away and back. |
| Syntax final-line guard | Initial empty and growing provisional lines defer syntax work. Finished lines, empty final lines, suspension, generation changes and completed-line cache reuse retain their existing paths. |
| Accounting recovery and validation | Missing/dead/malformed replies, running snapshots, invalid prices or missing/invalid unreported counters mark spend unknown. Settled numeric zero and positive costs with valid counters remain accepted. Ordinary recovery exceptions cannot escape without closing the budget. |
| Failed-scenario ownership | Every constructed scenario session is counted before exceptional disposal. Constructors do not dispatch model requests. Successful scenarios still account in `run_scenario`, once. |
| Request reserve fallback | Collected requests retain the previous largest-request calculation. A failed collection with recovered spending reserves the whole scenario amount conservatively. |
| Unreported aggregation and budget/loop checks | Missing request collection can no longer conceal the helper's unreported counter. Unknown or unreported spending blocks dispatch; fully reported spending keeps the prior budget calculation. |
| Cost-check and report conditions | Unknown/unpriced totals cannot pass the cost check or print zero; JSON totals are null and reported subtotals remain labelled separately. Successful fully priced reports remain numeric. |
| Session-close exception handling | A broken helper pipe no longer prevents process disposal. Other session and helper ownership remains unchanged. |
| Absolute-path checks | Only relative arguments gain the current-directory prefix. Absolute paths and all path whitespace retain their bytes; mkdir/cd failures stop the wrapper. The real test-host guard still runs before any test command. |
| Performance failure accumulation | The first nonzero invocation status survives later successes, across rounds and soak functions. All-success runs still exit zero and later rounds still execute after failure. |

The review added regressions for Reset state, pending wrap and its resize
interaction, malformed accounting, explicit unknown totals and output-path
newline preservation, and checked each fix with mutation. No unresolved
assigned finding or owner product decision remains. The separate renderer
colour-bleed observation above remains unassigned.

## Round 2 review — selection coordinates and plain syntax ink

Base: `8cb055b9`, still on `dev/a130-gitfiles`. No merge or fast-forward to
`dev/next`. Build root and evidence remain this workstream's own. Only generated
VT bytes and file fixtures are used; no installed app, real preferences,
Keychain, live capture, real credentials or provider calls. All native and
package UI test runs, including captures, hold the shared full-lane lock and
release only their own lock. The helper and wire are unchanged.

### Confirmations, fixes and nearby sweep

**Review finding — confirmed and fixed.**
`TerminalSelectionScrollTests.testAlternateSelectionsFollowHiddenHistoryThroughShrinkAndGrowth`
selects two alternate rows (`ALT` / `NEXT`) above a full four-row hidden normal
screen, then shrinks to two and grows back. It checks all three screen modes
47/1047/1049, both view-driven resizing and direct emulator resizing followed by
refresh, and a one-line history limit that forces eviction. Before the fix,
`round2-review-before.log` records 36 failed selection assertions:

```text
XCTAssertEqual failed: (Optional("")) is not equal to (Optional("ALT\nNEXT"))
# after growing with capped history:
XCTAssertEqual failed: (Optional("ALT")) is not equal to (Optional("ALT\nNEXT"))
```

Selection endpoints now move by the change in the alternate screen's absolute
origin: `trimmedLines + scrollback.count`. Both `fitGrid()` and `refresh()`
apply that shift before adopting the new origin, so a subsequent refresh does
not apply it twice. Normal-screen selections retain their absolute history
coordinates. Screen switches and history clearing retain their existing
selection invalidation.

Nearby sweep found the same coordinate issue in the active drag anchor.
`testAnAlternateDragAnchorFollowsHiddenHistory` begins at column 3 of `ALTword`,
resizes while dragging, then extends and shortens the selection. The focused
before run (`round2-review-anchor-before.log`, one failure) returned `ALTwor`
instead of `wor`. The anchor now moves with both endpoints. The history-cap
variant also proves that checking only `scrollback.count` misses movement
when old history is evicted. `testNormalSelectionsKeepTheirAbsoluteHistoryCoordinatesWhenResizing`
is an unchanged-behaviour control and passed before fixing.

**Syntax colour bleed — confirmed and fixed.** This resolves the previously
unassigned renderer observation in the Round 2 hunt section.
`FileTextViewTests.testPlainTextAfterSyntaxTokensKeepsItsOwnInkInBothAppearances`
paints `let value = 1` in light, dark, then light again using the same view.
Before fixing, all three captures had zero pixels matching the plain text
colour in `value =` (`round2-review-before.log`):

```text
XCTAssertGreaterThan failed: (0) is not greater than (5)
- plain value = must use plain ink in NSAppearanceNameAqua
- plain value = must use plain ink in NSAppearanceNameDarkAqua
```

`testSyntaxPiecesGivePlainRunsExplicitInkIncludingTheGrid` also found plain
CoreText runs still using foreground-from-context. It covers short lines,
multiple pieces and the long-line grid (13, 3,000 and 70,000 UTF-16 units),
including pieces with no coloured tokens. Mixed syntax lines now assign the
host's plain text colour to the whole piece before applying token colours.
Files without a syntax callback keep the existing context-colour path and
appearance-independent layout reuse. Existing syntax appearance invalidation
rebuilds mixed lines when the theme changes.

Nearby sweep: the gutter's context-colour runs have one colour per draw and
no mixed syntax tokens, so they do not have this bug. The shared piece builder
handles ordinary and grid pieces; the regression checks both. Style changes
already replace metrics and layouts, so the new plain colour follows the
host's style without a new invalidation rule.

### Mutation and focused evidence

The before run selected the three new terminal tests and the two new file
rendering tests: 5 tests, 3 failed, 67 assertion failures; the normal-selection
control and the initial zero-column drag variant passed. The strengthened
nonzero-column drag test then failed alone before any production fix.
Test setup also corrected a CoreFoundation cast rejected by the compiler and
then read the AppKit foreground attribute key from CoreText's retained
attributes (the wrong key produced 14 test-assertion failures). Those setup
logs are retained as `round2-review-test-build-error.log` and
`round2-review-attribute-key-error.log`; the pixel oracle was unchanged.

The immediate fixed run passed all 9 selected tests. Six temporary mutations
were then rejected by the named regression assertions, not by build failures;
each source was restored in `finally` before the final runs:

| Mutation | Failed tests / assertions | Log under `evidence/` |
| --- | --- | --- |
| Remove the post-resize rebase | 1 / 18 | `round2-review-mutation-fit.log` |
| Remove the refresh rebase | 1 / 18 | `round2-review-mutation-refresh.log` |
| Do not rebase the drag anchor | 1 / 1 | `round2-review-mutation-anchor.log` |
| Ignore trimmed history in the origin | 1 / 24 | `round2-review-mutation-trimmed.log` |
| Rebase normal selections as well | 1 / 2 | `round2-review-mutation-normal.log` |
| Restore context ink for plain runs, with explicit token ink only | 2 / 31 | `round2-review-mutation-ink.log` |

Every native invocation below uses:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles
# Each invocation acquires/releases the shared full-lane lock.
```

Before / immediate-after selectors and exact mutation commands are in
`evidence/split-commands.txt`; final commands, including gallery variables and
the package scratch directory, are in `evidence/round2-review-commands.txt`.
The initial failing command was:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalSelectionScrollTests/testAlternateSelectionsFollowHiddenHistoryThroughShrinkAndGrowth \
  -only-testing:PiAppTests/TerminalSelectionScrollTests/testAnAlternateDragAnchorFollowsHiddenHistory \
  -only-testing:PiAppTests/TerminalSelectionScrollTests/testNormalSelectionsKeepTheirAbsoluteHistoryCoordinatesWhenResizing \
  -only-testing:PiAppTests/FileTextViewTests/testPlainTextAfterSyntaxTokensKeepsItsOwnInkInBothAppearances \
  -only-testing:PiAppTests/FileTextViewTests/testSyntaxPiecesGivePlainRunsExplicitInkIncludingTheGrid

# Nonzero-column drag, before fixing:
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalSelectionScrollTests/testAnAlternateDragAnchorFollowsHiddenHistory
```

Final commands (serial-lane classes are separate):

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TerminalEmulatorTests \
  -only-testing:PiAppTests/TerminalSelectionScrollTests \
  -only-testing:PiAppTests/TerminalViewportTests \
  -only-testing:PiAppTests/TerminalSoftWrapTests \
  -only-testing:PiAppTests/TerminalHistoryDrawingTests \
  -only-testing:PiAppTests/TerminalCursorAlignmentTests \
  -only-testing:PiAppTests/TerminalPreciseScrollTests \
  -only-testing:PiAppTests/TerminalInverseTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPanelSerialTests
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalPanelAuditTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FileTextViewTests \
  -only-testing:PiAppTests/FileTabTests \
  -only-testing:PiAppTests/FileHiddenReadTests \
  -only-testing:PiAppTests/FileFindTabTests \
  -only-testing:PiAppTests/FilePageReadTests
TEST_RUNNER_PI_ROUND2_GITFILES_GALLERY="$PI_BUILD_ROOT/evidence/round2-review-gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/FileSyntaxTests
TEST_RUNNER_PI_ROUND2_GITFILES_GALLERY="$PI_BUILD_ROOT/evidence/round2-review-gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TerminalCaptureTests
swift build --package-path packages/bello-views --scratch-path "$PI_BUILD_ROOT/views-verify" --build-tests
CFFIXED_USER_HOME="$PI_BUILD_ROOT/views-test-home" swift test \
  --package-path packages/bello-views --scratch-path "$PI_BUILD_ROOT/views-verify" \
  --filter 'FileTextStyleTests|FileFindTests|FileDocumentTests'
xcodegen generate --quiet
git diff --check
```

Final restored-source counts:

| Run / class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| TerminalEmulatorTests | 25 | 0 | 0 |
| TerminalSelectionScrollTests | 7 | 0 | 0 |
| TerminalViewportTests | 7 | 0 | 0 |
| TerminalSoftWrapTests | 11 | 0 | 0 |
| TerminalHistoryDrawingTests | 4 | 0 | 0 |
| TerminalCursorAlignmentTests | 14 | 0 | 0 |
| TerminalPreciseScrollTests | 4 | 0 | 0 |
| TerminalInverseTests | 1 | 0 | 0 |
| TerminalPanelSerialTests | 18 | 0 | 0 |
| TerminalPanelAuditTests | 8 | 0 | 0 |
| FileTextViewTests | 47 | 0 | 0 |
| FileTabTests | 16 | 0 | 0 |
| FileHiddenReadTests | 5 | 0 | 0 |
| FileFindTabTests | 16 | 0 | 0 |
| FilePageReadTests | 3 | 0 | 0 |
| FileSyntaxTests, gallery enabled | 14 | 0 | 0 |
| TerminalCaptureTests, generated-byte gallery enabled | 1 | 1 | 0 |
| Package FileDocumentTests | 35 | 0 | 0 |
| Package FileFindTests | 14 | 0 | 0 |
| Package FileTextStyleTests | 3 | 0 | 0 |

Native: **201 passed, 1 skipped, 0 failed**. BelloViews package: **52 passed,
0 skipped, 0 failed**. The skip is the separate legacy terminal-capture opt-in;
the new captures all ran. Text logs are `round2-review-{terminal,panel,audit,files}-final.log`,
`round2-review-{syntax,terminal}-gallery.log` and `round2-review-views-final.log`.
No final unrelated test failures. Package build, `xcodegen generate --quiet`
and `git diff --check` pass; the generated project is unchanged. No clone
folders remain and no extra DerivedData copy was created. The package uses
`views-verify` under this build root. No helper or wire code changed, so the
full helper/wire/concurrent/acceptance lanes were not needed.

### Galleries and adversarial self-review

Regenerated and visually inspected all 12 images under
`$PI_BUILD_ROOT/evidence/round2-review-gallery`, with the lock held for captures:

- `syntax-{light,dark}-{800,420}.png`: `let` stays purple, `1` stays blue, and
  `value =` now draws in the host's plain text colour at both widths. The old
  purple bleed is gone in both appearances.
- `terminal-selected-{light,dark}-{760,360}.png`: both selected alternate rows
  remain highlighted after shrinking, matching the asserted `ALT\nNEXT` copy
  text. Text contrasts with the selection background at both widths.
- `terminal-restored-{light,dark}-{760,360}.png`: the earlier restoration
  scene still shows `three`, green `four!`, and the cursor after `!`.

Image hashes are retained in `evidence/round2-review-gallery-inspected-hashes.json`.

Every changed production condition and coordinate update was reviewed:

| Change | States affected and preservation check |
| --- | --- |
| Alternate-screen guard in selection rebasing | Only alternate selections move with hidden history; normal selections keep absolute coordinates, covered by the normal control and guard mutation. |
| Origin delta includes trimmed history | Growing gives a negative shift; shrinking gives a positive shift even at a full history cap. No movement gives zero. Both endpoints and the active anchor receive the same shift. |
| Rebase after resize, before updating `producedLines` | View-driven resizing applies the change immediately; refresh sees the adopted origin and cannot double-shift. |
| Rebase in refresh after clear/switch handling | Direct emulator resizing is covered. Clear/switch handling first removes old selections and anchors, so they cannot migrate between screens. |
| `syntax != nil` piece branch | Mixed pieces receive explicit default ink, even when a piece has no tokens. Syntax-free files retain context-colour reuse. Empty pieces remain valid zero-length attributed strings. |
| Existing token range guard | Unchanged: only valid ranges override the default ink. Glyph metrics, source reads, selection, paging and line-piece bounds are unchanged. |
| Existing style/appearance invalidation | Host style changes rebuild metrics/layouts. Theme changes rebuild syntax layouts; the light→dark→light pixel test covers reuse across appearances. |

The complete new diff from `8cb055b9` was reviewed adversarially, including the
test oracles and the six mutations above. Both assigned items are confirmed
and fixed. No unresolved finding or owner decision remains in this follow-up.

## Round 3 hunt

Base: `28dbfb30`, on `dev/a130-gitfiles` after the lead's fast-forward. Only
the live-compaction harness, its Python tests and the two release records
changed. Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
The Release helper was rebuilt after the laptop restart. No live harness
invocation or paid provider call was made: real helper processes used only
`--fixture`, generated homes/workspaces and the loopback reasoning gateway.
The live-policy tests use a fake helper, with helper construction and socket
creation explicitly blocked. No installed app, real preferences, chats,
credentials or Keychain were accessed. These checks do not change focus and
need neither a gallery nor the full-lane lock.

### TOOLING-CONFIG-4 — confirmed and fixed

`FixtureRunTests.test_inherited_home_skills_never_reach_the_fixture_gateway`
creates an inherited synthetic home with a valid implicit skill at
`.agents/skills/private/SKILL.md`. It runs both `compact-now` and `mid-run`
against the actual fixture gateway and inspects its decoded outgoing request
bodies, along with both helper launch environments. Before changing the
harness, `round3-before.log` showed four failed assertions:

```text
AssertionError: True is not false : gateway received inherited skill metadata: SYNTHETIC_PRIVATE_SKILL_DESCRIPTION_74AC
AssertionError: True is not false : gateway received inherited skill metadata: .../inherited-home/.agents/skills/private/SKILL.md
AssertionError: False is not true : helper inherited HOME
AssertionError: False is not true : helper inherited CFFIXED_USER_HOME
```

Each scenario now creates `home` alongside its existing temporary `codex`,
workspace and sessions directories. `Helper` requires that home and sets both
child environment variables before process launch. This covers Foundation's
independent `.agents/skills` scan while retaining the explicit `codexHome`
override. The parent environment and the existing `PI_LIVE_*` filtering are
unchanged. The directories follow the existing temporary-run cleanup/`--keep`
policy. The passing test checks that neither metadata sentinel nor inherited
skill path reaches any accepted fixture request, and that the two helpers have
distinct homes with matching HOME/CFFIXED_USER_HOME values.

Nearby sweep: this harness has one helper construction site and one launch
implementation, shared by all three scenarios; there is no alternate launch
that bypasses the new home requirement. Session reopening reuses the same
isolated helper. The separate `codexHome` override remains in place.

### TOOLING-CONFIG-5 — confirmed and fixed

`PollingAccountingTests.test_unpriced_summary_between_polls_blocks_follow_up`
drives the real `Session.wait`, `compaction_scenario`, `Session.submit` and final
accounting. The fake helper first returns a running summary and then idle with
`spentUSD: 0.10, unreportedRequests: 1`. It also checks a summary that is already
idle on the first poll. Both cases failed before the fix:

```text
AssertionError: Lists differ: [call('turn.submit', ... 'text': 'E2E follow-up. ...', 'fake-session')] != []
... : an unpriced summary must not authorize FOLLOW_UP
```

Live polling now validates settled accounting before returning success.
Unreported requests produce a cost stop, so the existing scenario guard sends
no follow-up. The tests also assert that final `runTotalUSD` stays null,
`spendKnown` is false, and the next-scenario budget is zero. Reported zero-cost
and positive-cost summaries still submit exactly one follow-up. Fixture-mode
dispatch remains unchanged.

Nearby instance, fixed in the same polling branch: missing or malformed
settled accounting also allowed the follow-up before final accounting rejected
it. `test_missing_or_malformed_settled_accounting_blocks_follow_up` reproduced
this with missing fields, invalid types, negative counters and non-finite
spending. The initial eight cases each failed on the unexpected `turn.submit`;
coverage also includes a nonempty invalid cost list and integer-to-float
overflow. The existing final-accounting validation is shared through
`settled_spend`, retaining its exact validity predicate and exception handling.
Polling now uses that same criterion and returns a cost stop when validation
fails. Unpriced paused/error statuses are also explicitly reported as cost
stops, rather than successful completion; their existing no-follow-up behavior
is preserved.

The running-attempt polling, loop limits, timeout/Stop path, final accounting,
once-only spend aggregation, request reserve and outer scenario budget gate
were reviewed. Only the settled-success return previously bypassed the cost
check. No helper or wire implementation changed.

### Commands, results and mutations

All commands ran from this worktree. `PI_BUILD_ROOT` below is
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles`.

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles python3 scripts/build-bundle.py

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles python3 -m unittest \
  scripts.tests.test_live_compaction_e2e.FixtureRunTests.test_inherited_home_skills_never_reach_the_fixture_gateway \
  scripts.tests.test_live_compaction_e2e.PollingAccountingTests -v

python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/round3-mutations.py

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles python3 -m unittest \
  scripts.tests.test_live_compaction_e2e -v

python3 -m py_compile scripts/live-compaction-e2e.py scripts/tests/test_live_compaction_e2e.py
git diff --check
```

| Check | Result and evidence |
| --- | --- |
| Release helper rebuild | Pass, 75.49 s; `round3-helper-build.log`. Existing Swift 6 isolation warnings remain in unrelated helper initialization. |
| Failing-first focused run | 6 tests: 2 pass, 4 failing test methods / 16 subtest assertion failures; `round3-before.log`. |
| Fixed focused run | 6 pass, 0 fail; `round3-after.log`. |
| Entire affected harness module | 24 pass, 0 fail, 0 skip in 5.443 s; `round3-harness-tests.log`. |
| Syntax / whitespace | Both Python files compile; `git diff --check` passes. |

The full module comprises FixtureRunTests **3**, PollingAccountingTests **5**,
SpendingFailureTests **7**, ReasoningGatewayTests **5**, SummaryPromptTests **2**
and ConfigurationTests **2**. The fixture tests include all three scenarios and
the intentionally capped-summary negative control. No native app class or
helper source changed, so full native/helper/wire/concurrent/acceptance suites
are outside this change's affected tests. No new DerivedData or test-host clones
were created.

The external mutation driver restores the original source after each run and
in `finally`. It runs `python3 -m unittest <selector> -v` with this build root;
the home mutants select the inherited-home test, and the accounting mutants
select PollingAccountingTests. Every failure was a test assertion, not a
syntax error or process failure:

| Mutation | Result (`round3-mutation-<name>.log`) |
| --- | --- |
| `home`: remove the HOME override, retain CFFIXED_USER_HOME | Killed: 2 assertions fail. |
| `cfhome`: remove CFFIXED_USER_HOME, retain HOME | Killed: 4 assertions fail, including leaked sentinel/path. |
| `unreported`: bypass the settled unreported-request guard | Killed: 4 assertions fail. |
| `unknown`: bypass the unknown-accounting guard | Killed: 9 assertions fail. |
| `fixture`: apply the new live guard to fixture dispatch too | Killed: 1 assertion fails. |

`round3-mutations.log` records all five results. The final full-module run above
ran after restoration and includes the additional malformed-accounting and
zero-cost controls.

### Adversarial self-review and separate observation

Reviewed the complete new diff from `28dbfb30`, including every changed
production condition and its changed states:

| Change | States affected and preservation check |
| --- | --- |
| Required `home` argument / child environment override | All harness helper launches now resolve home resources inside the generated scenario. All callers were checked. The parent environment, supplied key, explicit codex directory and resource permission policy stay unchanged. |
| New home directory in the existing creation loop | The directory exists before launch and is owned by the existing temporary-run lifecycle. No real directory is created or removed. |
| Settled-state branch | Running polls still take the original path. Idle, paused and error snapshots are checked before they can be returned as successful live completion. |
| `mode == "live"` guard | Only live-policy completion requires this new admission check. The fixture dispatch control and its mutation pin the existing fixture behavior. |
| Accounting exception / `not known` | Missing, malformed, negative, non-finite and overflowing accounting now stops live completion. Valid numeric zero remains known; booleans remain invalid. No exception grants follow-up admission. |
| `if unreported` | A valid positive count now blocks live completion. Zero retains the prior priced-success path. The mutation reproduces the extra follow-up. |
| Shared settled accounting predicate | The final-accounting predicate, tuple values and exception fallback are unchanged. All seven prior spending-failure tests pass, including failure before disposal, unknown totals, reserve and exactly-once aggregation. |
| Existing follow-up guard | Unchanged: it requires idle and no stop reason. It now receives the cost stop before dispatch, rather than learning of unknown spending during final reporting. |

Separate source-level observation, not changed under this harness assignment:
`scripts/test-native-host.py:419` and
`scripts/test-concurrent-native-host.py:46` still launch their loopback fixture
helpers without an explicit environment; acceptance reuses the former at
`scripts/test-native-acceptance.py:37`. Direct callers without an isolated home
can therefore expose inherited skills to their local fixtures through the same
Resources discovery path. These are loopback clients, not live provider paths;
this observation was not runtime-reproduced or changed here and is recorded for
the lead's scope decision.

Both assigned Round 3 findings are confirmed and fixed. No assigned finding or
owner product decision remains unresolved.

## Fixture helper homes — Round 3 follow-up

Base `fa18c41e`, still `dev/a130-gitfiles`. The lead merged the prior work and
fast-forwarded this worktree. Evidence remains under this workstream's
`build-a130-gitfiles/evidence`; no other workstream's products are used.
All helper calls here use synthetic resources and loopback gateways, or process
stubs that only report selected environment variables. No live provider,
installed app, real user resource or Keychain access is used; live-policy
accounting tests retain their fake helper and blocked network boundaries.

### Confirmed script leaks and shared fix

`HelperHomeFixtureTests.test_every_peer_excludes_inherited_skills_and_codex_instructions`
uses the actual wire, concurrent, acceptance and raw shared peer constructors
against the Release helper. Its synthetic inherited home contains an implicit
skill with description `SYNTHETIC_INHERITED_SKILL_47CF`, and a separate inherited
CODEX_HOME contains `AGENTS.md` with `SYNTHETIC_INHERITED_CODEX_47CF`. Each peer is
tested both with an explicit generated `resources.codexHome` and with the
helper's default Codex discovery. Every case sends a real loopback request and
checks the request bytes for inherited descriptions, instructions and paths.

Before the fix, all four peers sent the home skill in both configurations;
all four also sent inherited Codex instructions when no resource override was
specified. The launch-boundary probe additionally confirmed that default and
custom environments inherited all three roots. `home-isolation-before.log`
records 2 failing test methods / 33 assertion failures, including:

```text
AssertionError: True is not false : fixture received inherited resource: SYNTHETIC_INHERITED_SKILL_47CF
AssertionError: True is not false : fixture received inherited resource: SYNTHETIC_INHERITED_CODEX_47CF
... HOME was inherited
... CFFIXED_USER_HOME was inherited
... CODEX_HOME was inherited
```

The common `native_host_client.HostPeer` now creates a fresh generated home for
each peer, including restarts and calls supplying a custom environment. Shared
`isolated_environment` sets HOME and CFFIXED_USER_HOME to that home and
CODEX_HOME to its generated `.codex` directory. The rest of a supplied
environment, including PATH and synthetic fault-injection flags, remains intact;
the caller's dictionary is copied, not mutated. Explicit `resources.codexHome`
values in these scripts already name generated workspace directories and remain
unchanged. `Resources.swift` reads precisely these home inputs; tool/MCP process
environments derive HOME from the now-isolated helper environment.

Default homes are removed after the helper exits, and also if process launch
fails. The live compaction harness passes its already-owned generated home into
the same implementation, retaining its existing cleanup/`--keep` ownership and
PI_LIVE credential filtering. Its private root is never deleted by HostPeer.

The sweep found `smoke-native-bundle.py` launching a helper directly. Its new
stub-package regression failed first with 4 assertions in
`home-isolation-smoke-before.log`: each root remained inherited, and CODEX_HOME
was outside the helper's HOME. That launcher now uses the same environment
builder under its existing temporary directory. The test stubs `lipo` and the
helper and never launches an app.

### Script mutation evidence and completed helper suites

`home-isolation-mutations.py` lives in the evidence folder, changes one source
expression at a time, and restores every source in `finally`. It runs
`python3 -m unittest scripts.tests.test_helper_home -v` for the three root
mutations, the custom-environment test for the explicit-env mutation, and the
smoke test for the smoke mutation. All failures below were assertions, not
compiler or launch errors:

| Mutation | Result (`home-isolation-mutation-<name>.log`) |
| --- | --- |
| `home`: omit HOME from the shared override | Killed, 7 assertion failures. |
| `cfhome`: omit CFFIXED_USER_HOME | Killed, 23 assertion failures, including fixture skill leakage. |
| `codex`: omit CODEX_HOME | Killed, 15 assertion failures, including fixture Codex instruction leakage. |
| `explicit-env`: bypass isolation when a custom environment is supplied | Killed, 5 assertion failures. |
| `smoke`: restore the direct launch's inherited environment | Killed, 4 assertion failures. |

The initial focused run of the new fixture/environment tests and the entire
live-compaction test module passed **27/27** (`home-isolation-focused.log`).
Subsequent coverage adds failed-launch cleanup and asserts successful, validated
fixture responses, so suppressing all requests or failing preflight cannot
satisfy the leak regression.

Commands from this worktree, with
`PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles`:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles python3 scripts/build-bundle.py
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
```

| Suite | Result | Text evidence |
| --- | --- | --- |
| Release helper rebuild | Pass | `home-isolation-build.log` |
| Wire | 39 pass, 0 fail, 36.381 s | `home-isolation-wire.log` |
| Concurrent | 4 pass, 0 fail, 25.441 s | `home-isolation-concurrent.log` |
| Acceptance | 3 pass, 0 fail, 3.546 s | `home-isolation-acceptance.log` |

### Launch-path sweep

| Launch path | Finding / disposition |
| --- | --- |
| Wire Peer, ConcurrentPeer, acceptance setup and restart | Shared HostPeer default now isolates all roots. The actual constructors are covered by the loopback regression. |
| `test-subagent-{cache,crashes,downgrade,streaming,steering-crashes,steering-streaming}.py` | All use HostPeer and are covered by its unconditional isolation, including explicit environments containing fixture fault flags. No six-script rewrite is needed. |
| `live-compaction-e2e.py` | Now shares the same implementation, with retained-home ownership and credential filtering preserved. All existing harness tests cover it. |
| `smoke-native-bundle.py` | Direct helper launch fixed and independently mutation-tested. |
| `test-macos.sh`, `verify-release.sh`, `check-next.sh`, `perf-transcript.sh` | Native tests use the dedicated test-host target and its guard. Stored performance products are already checked for the dedicated host and fixed home. |
| `apps/macos/TestSupport/TestIsolationGuard.m` | Found a further child-environment hole, documented below. |
| Build, signing, signature verification and measurement utilities | No additional Bello helper/app launch; no signing, release, real capture or process measurement was invoked here. |
| `test-keychain-identity.py` | Separate opt-in signing/Keychain probe; not invoked and not part of unittest discovery. |
| `perf-launch.sh` | Separate opt-in launch benchmark; not invoked. It supplies a generated HOME/CFFIXED_USER_HOME to its copied fixture app; descendant handling is noted below. |

### Native test-host child environments — sweep finding fixed

The existing guard verified Foundation's fixed home, but left the parent HOME
and CODEX_HOME environment variables inherited. An explicit `Process.environment`
could also discard the fixed home. In particular, the app's helper launcher
supplies HOME without CFFIXED_USER_HOME. A Foundation-only process probe, which
opened no resource files, confirmed that HOME alone does **not** control
NSHomeDirectory on this Mac (`home-isolation-foundation-probe.json`).

`TestHostIsolationTests.testChildProcessesCannotRestoreInheritedHomeRoots`
first failed in the actual native test host, using only `/usr/bin/env` and
synthetic explicit paths. `home-isolation-native-before-fixed-probe.log`
contains 1 failed test / 4 assertions: supplied child roots remained
`/synthetic/inherited`, an empty child environment had none of the three roots,
the parent HOME still named the account home, and parent CODEX_HOME was nil.
No helper or resource discovery ran in this failing-first native test. An
earlier prototype used macOS `printenv`, which returns only one named variable;
the probe was corrected to parse the explicit environment before recording this
final failing-first run.

After the existing host/home safety validation, TestIsolationGuard now installs
the three roots in the parent process and protects NSTask's environment setter.
Explicit, empty and nil environments retain the same verified generated home;
unrelated supplied variables remain intact. Children launched without an
explicit environment inherit the protected parent roots. The host and test
bundle can both install the guard: a runtime marker prevents installing the
setter twice. Failure to install the boundary stops before application services.
This file is still compiled only into PiAppTestHost/PiAppTests, never the
shipping application; the existing project-configuration test verifies that.

`TestIsolationGuardTests.test_child_environments_keep_fixed_home_and_codex_root`
also compiles a Foundation-only probe from this same guard, installs it twice,
and starts a generated child for explicit/empty/nil/inherited cases. It checks
all three environment roots, the child's actual NSHomeDirectory, and preservation
of an unrelated fixture flag. Paths are resolved before comparison because
Foundation and Python spell `/var` / `/private/var` aliases differently. No
preferences, skill contents, Keychain or UI are read by this probe.

| Guard mutation | Result |
| --- | --- |
| Omit the root override in the NSTask setter | Killed: 2 Foundation probe assertions fail (`home-isolation-mutation-guard-child.log`). |
| Omit the parent `setenv` updates | Killed: the inherited-child case fails (`home-isolation-mutation-guard-parent.log`). |
| Omit guard installation from the real test-host constructor | Killed: the native regression again fails all 4 assertions (`home-isolation-native-mutation.log`). |

`home-isolation-guard-mutations.py` restores the source in `finally`, then runs
the complete affected native class. Both the first fixed class run and the final
restored run pass **5/5**; final evidence is
`home-isolation-native-final.log`. All native invocations acquired the shared
full-lane lock and released only their own lock in `finally`, including failures.
No lock was held while editing or waiting for another owner. No gallery was
needed because no UI changed.

### Final checks and adversarial self-review

In addition to the three passing Release-helper suites above, the final complete
Python discovery passed **111 tests, 0 failures, 0 skips** in 51.267 s
(`home-isolation-python.log`). It includes the four new helper-home tests, the
entire 24-test live harness module and the expanded test-guard probes. An initial
discovery before adding the Foundation child probe passed 110/110; its log is
retained as `home-isolation-python-initial.log`. Signing-retry messages in these
logs come from stubbed signing tests; no signing or Keychain operation ran.

The exact final commands were:

```sh
# Held the shared full-lane lock for each native invocation:
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles scripts/test-macos.sh \
  -parallel-testing-enabled NO -only-testing:PiAppTests/TestHostIsolationTests

python3 -m unittest discover -s scripts/tests
xcodegen generate --quiet
git diff --check
```

Python discovery ran with PI_BUILD_ROOT and PI_NATIVE_HOST naming this build
root/Release helper, and HOME/CFFIXED_USER_HOME/CODEX_HOME pointing into a fresh
`TemporaryDirectory(prefix="python-home-", dir=build_root / "evidence")`, with
CODEX_HOME its `.codex` child. That also isolates nested script probes such as
the stubbed release gate's diagnostic-report lookup. The directory is removed
after discovery. The focused native regression and its mutation use the same
native command with the selector extended by
`/testChildProcessesCannotRestoreInheritedHomeRoots`.

Project generation produced no project diff. No extra DerivedData root or
parallel test-host clones were created; an explicit scan found no clone folders
to remove under this workstream's native-tests root. All eight mutations failed
their intended assertions, and all sources were restored before final checks.
No packages/swift-host source or wire implementation changed, so no separate
Swift helper-unit run was required. The three requested Release wire suites
were run in full as recorded above.

Reviewed the complete new diff from `fa18c41e` adversarially:

| Changed condition / boundary | States now handled and preservation evidence |
| --- | --- |
| `home is None` | Default peers receive distinct generated homes. The live harness's explicit generated home remains owned by its run, preserving retained artifacts. |
| `env is None` | Both inherited and explicit dictionaries pass through the same three-root override. Empty dictionaries remain otherwise empty; fixture fault flags and PATH survive. The supplied dictionary is copied. |
| Launch exception / owned-home cleanup | A new temporary home is removed if launch fails and after successful disposal. Caller-owned homes are not removed. Failed-launch and two-peer cleanup probes pass. |
| Live harness forwarding | The same explicit generated home now reaches shared HostPeer; PI_LIVE filtering, private-IPC credentials and workspace codexHome remain unchanged. All 24 harness tests pass. |
| Smoke launch | Only the child roots change; bundle checks and handshake assertions remain intact. Its independent stub test and mutation exercise the actual script entry point. |
| Guard installation after isolation validation | Unsafe host identities, real-home aliases and unsafe storage paths still refuse before mutation or data access. Existing guard tests remain green. |
| Parent environment updates | Inherited or missing HOME/CODEX_HOME now point into the already-verified home. A failed `setenv` refuses the test host. The native parent assertions and inherited-child mutation cover this boundary. |
| Explicit versus nil NSTask environment | Explicit dictionaries retain non-home fields; nil uses the protected parent environment. Empty dictionaries also receive the three roots. All four process modes verify effective Foundation home. |
| Runtime installation marker | First installation records the original setter; subsequent installation does not wrap it again. Double-installation probes and the two native Mach-O guards pass without recursion. A missing setter refuses the test host. |
| Build scope | TestSupport remains absent from PiApp. Shipping app permissions, vault, capture, tool and data behavior are unchanged. |

Separate observation, outside the requested fixture-client/test-host fix:
`scripts/perf-launch.sh:54` isolates its copied `PI_LAUNCH_FIXTURE` app, but that
app is not PiAppTestHost and does not include TestIsolationGuard.
`apps/macos/PiApp/Host/HostSupervisor.swift:119` supplies only HOME to its helper;
the Foundation probe above shows why reopening a fixture chat can still discover
account-home resources in that descendant. The benchmark also stats the account's
preferences file at `scripts/perf-launch.sh:37`/`:71`. This opt-in benchmark was
not run; its production-source descendant path and metadata probe are recorded
for separate follow-up, not silently changed here.

The assigned script isolation issue and the native test-host sweep finding are
fixed. There are no failing checks or unresolved owner product decisions in
these changes; the separate opt-in benchmark observation remains as noted.

## Fixture isolation review — relative paths and launch benchmarks

**Preference-reset correction:** the file-only reset and the prohibition on
fixture-domain `defaults` calls recorded below were incorrect. The owner's
clarification and the real UserDefaults regression in
[the follow-up](#fixture-preferences-review--effective-per-trial-reset)
supersede that conclusion and its `preferences-reset` mutation expectation.

Base `14cc0893`, on `dev/a130-gitfiles`; no merge, fast-forward or history rewrite.
This resolves both the relative-path review and the opt-in benchmark observation
above. Evidence is under this workstream's
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`,
prefixed `home-review-`. No live or paid requests, installed app launch,
Keychain access, real preferences/resource reads or metadata probes were used.

### Relative helper paths — confirmed and fixed

`HelperPathTests.test_relative_helper_and_build_root_launch_all_fixture_peers`
creates a generated build-tree symlink to this workstream's Release helper. It
runs the actual home-isolation fixture class in a subprocess twice: once with
relative `PI_NATIVE_HOST`, then with relative `PI_BUILD_ROOT` and no
`PI_NATIVE_HOST`. Each child exercises all four peers, both with and without an
explicit generated `codexHome`, and must finish without skipping.

Failing first (`home-review-relative-before.log`): both subprocesses failed;
each had eight `FileNotFoundError`s, because the validated relative executable
was then interpreted under the peer's temporary workspace:

```text
(variable='PI_NATIVE_HOST') ... FAIL
(variable='PI_BUILD_ROOT') ... FAIL
FileNotFoundError: [Errno 2] No such file or directory:
  '../../../../../../var/folders/.../pi-relative-helper-.../swift-host/arm64-apple-macosx/release/pi-native-host'
Ran 1 test in 0.505s
FAILED (errors=8)
```

The selected path now calls `.resolve()` before either existence check or peer
override. Precedence and missing-helper skip behavior remain unchanged.
Removing this call reproduces both failures (`home-review-mutation-relative.log`).
The restored regression passes as part of the focused and full Python runs.

Nearby sweep: both standalone wire runners already resolve their executable;
acceptance reuses the wire runner. `test_live_compaction_e2e.release_helper`
can return a relative path, but its callers pass it to the harness in the same
working directory, and `load_config` resolves it before helper construction.
It does not have this directory-change bug; no change there.

### Launch benchmark isolation — confirmed and fixed

`PerfLaunchTests.test_launch_and_preference_checks_stay_in_the_fixture` executes
the real shell entry point over a generated fixture and fake bundle, using a
fake `belloperf` that never executes the app. `stat`, `defaults` and `sysctl`
are spies; no preference query, purge, window, capture or actual benchmark runs.
Its inherited HOME/CFFIXED_USER_HOME/CODEX_HOME and scratch paths are synthetic.
The test observes one prime and one warm trial, the harness environment, app
arguments, copied preference removal and the original fixture's unchanged plist.

`LaunchHelperEnvironmentTests` compiles the actual helper environment builder
three ways: shipping, `PI_LAUNCH_FIXTURE`, and `PI_TEST_HOST`. The original
six-key dictionary was extracted unchanged from `HostSupervisor` to the small
Foundation-only `HostEnvironment.swift` before adding the fix. This lets the
regression exercise the fixture compilation condition without a GUI app or the
native test-host guard masking the bug. Its generated child only returns
environment/home path strings; it never opens or stats the returned paths.

The final failing-first probe (`home-review-perf-before-normalized.log`) recorded
**2 failing methods / 10 assertions**:

```text
(variable='CFFIXED_USER_HOME', condition='PI_LAUNCH_FIXTURE') ... FAIL
AssertionError: None != '/var/folders/.../pi-launch-helper-.../home'
(variable='CODEX_HOME', condition='PI_LAUNCH_FIXTURE') ... FAIL
AssertionError: None != '/var/folders/.../pi-launch-helper-.../home/.codex'
... foundationHome and fileManagerHome did not name the generated home
(preferences='metadata') ... FAIL
... inherited/Library/Preferences/com.belloware.PiApp.plist
    != fixture/home/Library/Preferences/com.belloware.PiApp.launchperf.plist
(preferences='defaults') ... FAIL
AssertionError: True is not false : do not contact the invoking account preferences service
```

The shipping allowlist control passed before and after the fix. An earlier
prototype compared `/private/var` and Foundation's `/var` spelling literally;
the probe was corrected and rerun before the fix. The normalization is a string
operation, not a filesystem lookup on any unexpected returned home.

Changes:

- `perf-launch.sh` supplies generated HOME, CFFIXED_USER_HOME, CODEX_HOME,
  TMPDIR and PI_APP_SCRATCH_ROOT to both the harness and its app arguments,
  creating the Codex and scratch directories before launch.
- Only `PI_LAUNCH_FIXTURE` and `PI_TEST_HOST` builds add CFFIXED_USER_HOME and
  CODEX_HOME to the helper environment. Both derive from the app's effective
  generated Foundation home, including an inherited CODEX_HOME override case.
  Shipping builds retain exactly the prior six-key environment.
- The preferences timestamp check names the original fixture's launchperf
  plist. Per-trial reset removes only the copied fixture plist. Neither reset
  nor final cleanup calls the account's `defaults` service.

The sweep also found that `WorkspaceModel` can use an inherited
`PI_APP_BENCHMARK_STATE_ROOT` when benchmark output enables instrumentation;
inherited `PI_APP_BENCHMARK_OUTPUT` and `BELLO_CONTEXT_DIAGNOSTICS` can likewise
direct writes outside the generated run. Extending the shell regression with
these synthetic paths first failed both trial assertions
(`home-review-override-before.log`). The same launcher now unsets these three
inherited overrides before calling the harness. The default application-support
and resource paths derive from the fixed home; any harness-created diagnostic
output remains owned by that harness.

App/resource sweep: `WorkspaceResources` defaults `codexHome` to the effective
Foundation home's `.codex`; the generated LaunchFixtureWriter vault has no
external resource overrides. `Resources.swift` uses `NSHomeDirectory`,
CODEX_HOME or explicit `codexHome`; these are covered by the fixture boundary.
`LaunchFixtureVault` still supplies only the generated configuration and does
not use Keychain. No production permission, capture, tool, vault, resource
discovery or wire implementation changed.

### Mutation checks

`home-review-mutations.py` (evidence folder) mutates one boundary at a time and
restores all files in `finally`. It runs the relevant relative-path, compiled
environment or stub benchmark test for each mutation. All **11/11** were caught:

| Mutation | Failing assertions / evidence suffix |
| --- | --- |
| Remove helper-path `.resolve()` | 2; `relative` (each child reports 8 launch errors) |
| Omit helper CFFIXED_USER_HOME | 4; `helper-cfhome` |
| Omit helper CODEX_HOME | 2; `helper-codex` |
| Enable the override in shipping builds | 2; `shipping-gate` |
| Drop PI_TEST_HOST from the compilation condition | 3; `test-host-gate` |
| Omit launcher/harness CODEX_HOME | 2; `launch-codex` |
| Omit launcher/harness CFFIXED_USER_HOME | 2; `launch-cfhome` |
| Restore the invoking account's preferences path | 1; `preferences-stat` (stat spy only) |
| Restore account defaults reset | 3; `preferences-reset` (defaults spy only) |
| Retain inherited benchmark/diagnostic paths | 2; `optional-roots` |
| Drop generated scratch roots | 2; `scratch` |

Logs are `home-review-mutation-<suffix>.log`, with the aggregate in
`home-review-mutations.log`. The executable-path mutant intentionally reproduces
the reported launch failure; all other mutations fail assertions after their
probes compile and run. No mutation is accepted merely for a build/syntax error.
All sources were restored before the full validation runs.

### Validation commands and adversarial review

Commands from this worktree:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles python3 scripts/build-bundle.py
python3 -m unittest scripts.tests.test_helper_home scripts.tests.test_perf_launch -v
python3 -m unittest discover -s scripts/tests
python3 scripts/test-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-concurrent-native-host.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
python3 scripts/test-native-acceptance.py /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/swift-host/arm64-apple-macosx/release/pi-native-host
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles scripts/test-macos.sh \
  -parallel-testing-enabled NO -only-testing:PiAppTests/HostSupervisorTests \
  -only-testing:PiAppTests/HostTransportTests -only-testing:PiAppTests/TestHostIsolationTests
xcodegen generate --quiet
bash -n scripts/perf-launch.sh
git diff --check
```

Python commands run through the evidence driver `run-home-review.py`, with
PI_BUILD_ROOT/PI_NATIVE_HOST naming this build root and its Release helper, and
HOME/CFFIXED_USER_HOME/CODEX_HOME in a generated `review-home-*` temporary
directory removed after each command. The benchmark script test uses only its
stubs, and all model requests elsewhere use loopback fixtures.

| Suite | Result | Text evidence |
| --- | --- | --- |
| Release helper rebuild/staging | Pass | `home-review-build.log` |
| Focused helper-home and benchmark probes | 8 pass | `home-review-focused.log` |
| Full Python discovery, including the subsequent override regression | 115 pass, 0 skips, 55.250 s | `home-review-python.log` |
| Wire | 39 pass, 35.351 s | `home-review-wire.log` |
| Concurrent | 4 pass, 25.827 s | `home-review-concurrent.log` |
| Acceptance | 3 pass, 3.476 s | `home-review-acceptance.log` |
| HostSupervisorTests | 10 pass, 0 fail | `home-review-native.log` |
| HostTransportTests | 8 pass, 0 fail | `home-review-native.log` |
| TestHostIsolationTests | 5 pass, 0 fail | `home-review-native.log` |

The native run rebuilt this worktree's test host/products and passed **23/23**,
with no compiler warnings. It waited for the shared full-lane lock, held it
only for the run and released its own lock in `finally`. No focus-changing
probe ran outside that lock. The benchmark unit probes never launched an app
and needed no gallery. There are no test-runner clones to remove under this
build root, and no extra DerivedData root was created.

The Python log's signing retry messages are from stubbed signing tests, not
actual signing or Keychain calls. No `packages/swift-host` or wire source
changed, so the Swift helper unit suite was not required; all three requested
Release-helper black-box suites ran in full.

Adversarial review of every changed behavior/condition:

| Boundary | States that change; preservation check |
| --- | --- |
| Relative versus absolute selected helper | Relative paths now bind in the invoking directory before peers switch cwd. Absolute paths retain their destination; native-host override, build-root fallback and missing-helper skip precedence are unchanged. Both relative selectors execute all eight actual fixture cases. |
| `PI_LAUNCH_FIXTURE || PI_TEST_HOST` | Only these two compiled environments gain fixed Foundation/Codex roots. The shipping configuration, including benchmark enabled/disabled, exactly matches the old six-key allowlist. Dropping the test-host condition and making the condition unconditional are independently caught. |
| Fixture helper home construction | The child's fixed home and Codex root derive from the parent's effective Foundation home, rather than forwarding a potentially unrelated inherited CODEX_HOME. PATH, language, app version, benchmark flag and existing scratch selection retain their values. The child probe checks both Foundation home APIs. |
| Benchmark harness/app inheritance | Missing, inherited or conflicting home/scratch roots now name the generated run. Both the harness's own environment and its explicit app overrides are asserted; directory creation precedes launch. Trial scheduling, labels and timing arguments are unchanged. |
| Optional state/diagnostic overrides | Previously inherited external paths are now absent at harness startup, so app defaults remain under the fixed home and inherited diagnostics cannot write elsewhere. The synthetic poison-path regression and mutation cover this state. |
| Preference reset and timestamp check | Present copied launchperf preferences are removed; absent files remain harmless. The original generated fixture plist is only checked, and remains byte-equivalent in the test. The account plist is never inspected, and no account defaults service is invoked. Both boundaries have independent mutants. |
| Source extraction / generated project | Only the existing environment dictionary moved into a Foundation-only builder, allowing direct tests of fixture and shipping compilation without an app launch. The supervisor uses that builder; XcodeGen adds it to the same app/test-host source sets. |

No product decision or production behavior change is needed for these fixes.

## Fixture preferences review — effective per-trial reset

Base `88137210`, on `dev/a130-gitfiles`. The review finding is **confirmed and
fixed**. The benchmark's `com.belloware.PiApp.launchperf` domain is generated
fixture state, even when cfprefsd stores it in the account Preferences directory.
The owner explicitly permits resetting this exact domain. The real app's domain
and every other non-fixture domain remain outside the test boundary.

### Failing first and fix

`PerfLaunchTests.test_each_trial_resets_the_effective_fixture_defaults` runs
the actual shell entry point with a generated bundle and fake `belloperf`.
For each of two labels' prime and warm trials, the harness starts a separate
Foundation-only executable. It reads the fixture's persistent domain through
`UserDefaults`, writes a distinct marker and synchronizes it. No app executes.
The regression requires every trial's initial marker to be absent.

Before changing the script, `defaults-review-before.log` showed:

```text
FAIL: test_each_trial_resets_the_effective_fixture_defaults
AssertionError: Lists differ:
[None, 'fixture-prime-0', 'second-prime-0', 'fixture-warm-1']
!= [None, None, None, None]
UserDefaults retained a previous trial
Ran 4 tests in 4.587s
FAILED (failures=9)
```

The other eight failures were the five non-fixture target cases, the two
reset-error cases, and the missing reset calls in the existing launch-boundary
test. Those cases use spies exclusively; they never query a non-fixture domain.

`perf-launch.sh` now checks the exact fixture domain before any paths or
preferences are accessed, then makes it readonly. Before each trial it invokes
`defaults` under the trial's generated HOME, CFFIXED_USER_HOME and CODEX_HOME.
It writes one fixture marker before deleting the domain, so an initially absent
domain is handled without suppressing a genuine write/delete failure. Either
failure stops the script before the harness launches. Normal completion also
clears the domain before removing the run directory.

The copied fixture plist is still removed, and the original fixture plist's
metadata check remains confined to the fixture. Home/scratch isolation, helper
environments, trial ordering and timing arguments are unchanged.

For the real preference probe, the defaults proxy permits only the exact
fixture marker write and fixture-domain delete, then calls `/usr/bin/defaults`.
The Foundation probe hardcodes that same suite and uses `persistentDomain`,
never `UserDefaults.standard` or a merged preference search. Cleanup clears the
fixture domain in `finally`. Unsafe-domain cases include the real app ID, an
unrelated ID, a fixture-prefix lookalike, `-g`, and the empty string; all are
refused before any spy observes a preference operation or launch.

Nearby sweep: `rg` over `scripts/` and `apps/macos/TestSupport` for defaults
writes/deletes, preference plist resets and persistent-domain removal found no
additional file-only reset to fix. No Swift app/helper or wire source changed.

### Mutation checks

The evidence driver `defaults-review-validation.py` changes one line at a time,
runs the indicated method and restores the script in `finally`. All **5/5**
mutations fail assertions after their probes run successfully:

| Mutation | Test / failure | Log suffix |
| --- | --- | --- |
| Remove per-trial reset | Effective-defaults regression sees prior trial markers; 1 failure | `per-trial` |
| Bypass exact-domain guard | Non-fixture-domain regression; 5 failures | `domain-guard` |
| Ignore failed marker write | Reset-error regression observes a launch; 1 failure | `failed-write` |
| Ignore failed domain delete | Reset-error regression observes a launch; 1 failure | `failed-delete` |
| Remove final reset | Effective-defaults regression reads `second-warm-1` after the run; 1 failure | `cleanup` |

An initial final-cleanup mutation survived because the inspection used a home
directory already removed by the launcher. The probe now recreates that same
generated home before inspection, matching a subsequent trial. The final
mutation then failed with:

```text
AssertionError: 'second-warm-1' is not None :
  the fixture domain is cleared after the run
Ran 1 test in 3.554s
FAILED (failures=1)
```

The initial result is retained as
`defaults-review-mutation-cleanup-initial.log`; it is not counted as a caught
mutation. Final logs use `defaults-review-mutation-<suffix>.log`.

### Validation and adversarial review

Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
Commands from this worktree:

```sh
python3 -m unittest scripts.tests.test_perf_launch.PerfLaunchTests -v
python3 -m unittest scripts.tests.test_perf_launch -v
python3 -m unittest discover -s scripts/tests
bash -n scripts/perf-launch.sh
python3 -m py_compile scripts/tests/test_perf_launch.py
git diff --check
```

Python commands use the existing evidence wrapper `run-home-review.py`, which
sets generated HOME/CFFIXED_USER_HOME/CODEX_HOME and this workstream's
PI_BUILD_ROOT/Release PI_NATIVE_HOST. The complete fixed/mutation/final run was:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  defaults-review-validation python3 \
  /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/defaults-review-validation.py
```

| Suite | Result | Text evidence |
| --- | --- | --- |
| Focused launch/environment probes | 6 pass, 0 fail, 9.938 s | `defaults-review-focused.log` |
| Full Python discovery | 118 pass, 0 fail, 0 skips, 58.779 s | `defaults-review-python.log` |
| Mutations | 5/5 caught | `defaults-review-validation.log` |
| Shell/Python syntax and diff checks | Pass | `defaults-review-static.log` |

These Foundation-only and stub tests do not launch a GUI app or change focus;
they ran independently of the native lane and did not alter another workstream's
lock. No opt-in benchmark, paid/live request, installed app, real app preferences,
other non-fixture domain, real journal or Keychain access was used. The full
Python suite's signing retry messages come from its signing stubs. No new
DerivedData root, test clone or named xcresult was created.

Adversarial review of the whole new diff:

| Changed condition/step | States that now differ and intended result |
| --- | --- |
| Exact-domain guard | Only the fixed fixture ID proceeds; other IDs, aliases and empty values fail before any preference access or launch. The readonly assignment prevents a later target change. Wrong-target tests always use spies. |
| Seed then delete | An absent domain is created and deleted successfully; an existing domain loses all prior trial values through cfprefsd. Failed writes or deletes abort instead of allowing contaminated timings. Both error branches have independent mutations. |
| Per-trial reset | Prime, warm and cold trials share the same reset path. Values from any previous label/trial are removed; launch ordering and arguments are unchanged. Separate UserDefaults processes demonstrate persistence before and absence after the fix. |
| Final reset and probe cleanup | Successful runs clear the last trial's values while the home still exists. The probe recreates its generated home before final inspection and clears the exact fixture domain even after assertion failure. |
| Test dispatch/real defaults boundary | Real calls require an explicit per-test flag plus an exact argument allowlist. Inherited probe/failure flags are removed. Non-fixture cases cannot reach real defaults even with the production guard mutated away. The fake app is not executable. |
| Existing boundaries | The original fixture plist stays unchanged; metadata checks stay fixture-local; all app/helper home and scratch overrides remain as before. No shipping path or helper behavior changes. |

No unresolved failure or owner decision remains in this change.


## Native focus lane audit

Base `fe734912`, fast-forwarded by the lead before this work, on
`dev/a130-gitfiles`. No merge or further fast-forward was performed here.

### Findings and scope

The audit covered **all 461 native test classes**, their bases/extensions and
helpers across **520 Swift files**, including 79 nested reference files, plus
`apps/macos/TestSupport`. An independent test-case declaration scan found no
omitted declaration and no duplicate top-level class name. The before/after
class sets are identical. Evidence is in this workstream's
`build-a130-gitfiles/evidence/lanes-*` text/JSON/TSV files; `lanes-audit.tsv`
records every class's old/new Debug and Release lane and its final reasons.

- Confirmed: `TranscriptGeometryCacheTests` and `TranscriptTurnFoldTests`
  were parallel despite `makeKeyAndOrderFront` in their fixtures.
- `TranscriptBugRegressionTests` was already serial for pasteboard/timing
  reasons on this base. Its `findFixture` still opens a key window, and now
  independently gets a `focus` reason. No existing serial class was demoted.
- The nearby sweep found direct, inherited and same-file focus use throughout
  the suite, plus shared fixtures such as `LongChatScroll`, `PiKitParity`,
  `ReviewConcurrentInteractionLoad`, `WireChat`, and nested fixtures such as
  `ConversationPaneTests.Pane`. Cross-file helpers and nested source folders
  were previously outside the detector's reach.
- Indirect app entry points also raise windows. `WorkspaceInspector.swift:18`
  calls the Inspector window manager, whose `SessionInspectorWindow.swift:47`
  makes the window key and activates the app. `TabHost.swift:304` creates a
  controller and can call `showWindow`; `TabWindows.swift:37` brings it forward.
  Inspector/Details and pop-out/bring-forward calls now count as focus use,
  including tests that dispatch through a row action or a button.

The detector recognizes app activation/state, key/main window changes/state,
first-responder interaction, window/application event dispatch, key equivalents,
modal/sheet presentation, Core Graphics event posting and pointer movement.
Whitespace-separated calls are covered. Event construction and direct local
view handlers alone remain parallel; notification posting is not mistaken for
posting input. Responder interaction is deliberately conservative: a class is
serial even if its current fixture uses an offscreen/non-key window.

Shared test types are considered as whole fixtures, including their methods and
file-local helpers. Thus some calls to a currently non-focusing member of a
fixture that also uses focus are conservatively serialized. Private names do
not spread to unrelated files. Transitive traversal terminates on cycles and
includes fixtures nested in other test classes. Classes with only inherited
test methods are also classified. Shared traversal contributes focus checks;
it does not promote a class merely because a shared file defines
`releaseBudget` or an unrelated timing assertion. Cached identifier extraction
keeps the audit bounded; all 461 classifications were identical before/after
that cache (measured cached source scan: 7.946 s).

This is a source heuristic, not a Swift runtime call-graph proof. Dynamic or
external focus operations still need `SerialTestLane`; the handoff documents
that boundary. No native test or production Swift behavior was changed.

### Failing-first and mutation evidence

New `scripts/tests/test_test_lanes.py` executes only Python source checks and
synthetic Swift source fixtures; it never compiles/runs these native fixtures.
The repository guard checks actual `serial`/`parallel` CLI selections in both
Debug and Release against an independently declared focus API audit. Separate
one-API cases and transitive-fixture cases prevent weakening the detector from
silently weakening the repository check.

Before the fix (`lanes-before.log`):

```text
test_known_native_fixture_users_have_a_focus_reason ...
  (name='TranscriptGeometryCacheTests') ... FAIL
  (name='TranscriptTurnFoldTests') ... FAIL
AssertionError: 'focus' not found in []
test_no_parallel_native_class_uses_focus_apis ...
  (configuration='Debug') ... FAIL
  (configuration='Release') ... FAIL
Ran 8 tests in 2.815s
FAILED (failures=66)
```

A separate extension-helper regression first failed once
(`lanes-extension-before.log`). During the audit, tests also caught an initial
implementation that propagated unrelated timing/budget helpers and the old
omission of inherited-only test classes: **2 methods / 3 failures**
(`lanes-audit-before.log`). They were fixed before final validation.
The additional cross-test-class fixture and app-window entry-point regressions
failed first with **3 methods / 14 failures** (`lanes-indirect-before.log`).

The restored focused suite passes **13/13**. The mutation driver restores the
script in `finally`; all **8/8** changes are caught by assertion failures:

| Mutation | Failing assertions | Log suffix |
| --- | ---: | --- |
| Restore the old focus pattern | 58 | `apis` |
| Stop following shared helpers | 1 | `shared` |
| Scan only the top-level directory | 1 | `recursive` |
| Omit shared extension builders | 1 | `extension` |
| Omit inherited-only test classes | 1 | `inherited` |
| Propagate unrelated timing/budget helpers | 2 | `scope` |
| Omit fixtures nested in other test classes | 1 | `test-fixture` |
| Treat private helpers as cross-file exports | 1 | `private` |

Logs are `lanes-mutation-<suffix>.log`, aggregated in `lanes-validation.log`.

### Reclassified classes

| Configuration | Before serial / parallel | After serial / parallel | Newly serial |
| --- | --- | --- | ---: |
| Debug (normal gate) | 132 / 329 | 320 / 141 | 188 |
| Release | 147 / 314 | 321 / 140 | 174 |

All newly serial classes have a focus reason. No class is removed from either
configuration's combined selection. The following is the complete Debug list.
Direct, inherited, same-file or app-window entry-point detection (**117**):

```text
AppShellPerformanceTests  ArchiveSwitchTests
BackgroundRequestsTests  BlockingAlertTests
CancelDefaultQuestionTests  CapturedBodyTests
ChangesTabTests  ChatFileLinkTests
CompactTurnReportTests  ComposerSubmissionTests
ConnectionSwitchJournalTests  ContextReadingTests
ConversationPaneRetentionTests  CostLimitTests
FileBlameTests  FileReviewGalleryTests
FileReviewStateTests  FileTabTests
FiveSessionWorkspacePerformanceTests  GitChangelistReadTests
GitConfirmationSheetTests  GitDiscardQuestionTests
GitHistoryFilterTests  GitHunkReviewTests
GitIntegratedHistoryGalleryTests  GitIntegratedHistoryTests
GitOperationSafetyTests  GitPanelAuditTests
GitPanelDiffCaptureTests  GitPanelLayoutTests
GitPanelRedrawTests  GitPanelShownTests
GitPanelWidthTests  GitPathBoundaryTests
GitRenameTests  GitSafetyGalleryTests
HistoricalEditingTests  HistoryEdgeTests
InlineSkillPillTests  InlineSkillTests
InspectorEntryPointTests  InspectorExpandInPlaceTests
InspectorFollowTests  InspectorWindowControlTests
LaunchSelectionTests  LazyListAppKitControlTests
LiveWorkingIndicatorTests  MarkdownSourceReconciliationTests
MessageDetailTests  MessageVersionTranscriptTests
MiniModelSettingsTests  ModelCatalogEndpointTests
NativeCodeTextTests  NativeMarkdownSurfaceStreamingTests
NativeMarkdownViewportTests  NativeTranscriptDocumentTests
NativeTranscriptScrollTests  NativeTranscriptScrollingPerformanceTests
NativeWorkListViewportTests  PendingChatProjectTests
PerformanceBaselineTests  PiKitControlTests
PiQuestionSheetTests  PiSheetCancelTests
PiSheetWindowTests  ReportNavigationTests
ReportPageTests  ResponseChronologyTests
SendImmediacyTests  SendLatencyTests
SessionStatsPopoverTests  SessionTimingTests
SessionUsageTests  ShellSheetTests
SideKeepRecoveryTests  SideRelaunchTests
SidebarAppearanceTests  SidebarListedOrderTests
SidebarScalePerformanceTests  SidebarSideClickTests
SmoothHoverAndMotionTests  SmoothPaneAndKeyboardTests
SmoothReadingPositionTests  StableToolPresentationTests
StreamingMarkdownStabilityTests  TabHostTests
TabPaneTests  TerminalCaptureTests
TerminalCursorAlignmentTests  TerminalPanelAuditTests
TranscriptBugGalleryTests  TranscriptDisclosureTests
TranscriptFindTests  TranscriptFrameBudgetTests
TranscriptGeometryCacheTests  TranscriptKeptRowsTests
TranscriptNativeMessageKindBehaviourTests  TranscriptNativeWorkBehaviourTests
TranscriptPageStressTests  TranscriptQuoteSelectionTests
TranscriptRealAppStreamingTests  TranscriptRowGalleryTests
TranscriptScrollBudgetTests  TranscriptStreamingStressTests
TranscriptSwitchBudgetTests  TranscriptSwitchFirstFrameTests
TranscriptTurnFoldTests  TranscriptUpdateIsolationTests
TranscriptVisibilityTests  TranscriptWidthChangeTests
TurnAccountingTests  UpdatePauseTests
WireContractTests  WorkspaceManagerSheetTests
WorkspaceMotionTests  WorkspaceRedrawTests
WorkspaceTests
```

Shared fixture detection (**71**, including conservative whole-type ownership):

```text
AccountingScaleTests  AppControlAccessibilityTests
BudgetOwnerUnloadTests  CaptureMacIntegrationTests
ComposerImportSubmissionTests  ContentSearchTests
ConversationFamilyTests  CostPausePresentationTests
FamilyDeletionTests  ForkFromReplyTests
FreshPresentationTests  GitHunkGalleryTests
HardeningTests  HistoryExtentTests
InspectorRequestModelTests  InspectorSummaryRequestTests
MarkdownStreamingCorrectnessTests  MarkdownStreamingTests
MarkdownTextSurfaceTests  NativeTranscriptSafetyTests
NestedFenceIdentityTests  PastedAttachmentTests
PayloadArchiveTests  PayloadSearchTests
PendingChatProjectGalleryTests  PiMenuTests
QueuePanelGalleryTests  ReleaseConfigurationTests
ReplyFileLinkTests  ReplySourceTests
ReportMessageNavigationTests  ResponseTimelinePresentationTests
SideBudgetIntegrationTests  SideKeepOrderingTests
SidebarMetricsLayoutTests  SidebarSearchIndexTests
SidebarSearchScopeTests  SidebarSearchSidebarTests
SubagentCostTests  SubagentDeletionTests
SubagentDiscoveryTests  SubagentDisplayTests
SubagentEffortTests  SubagentInspectorTests
SubagentOrganizationTests  SubagentPanelTests
SubagentSteeringInspectorTests  SubagentSteeringPresentationTests
SubagentSteeringWorkspaceTests  SubagentTranscriptTests
TimelineStreamingFastPathTests  ToolOutputProducerTests
TranscriptActionsForwardingTests  TranscriptFollowOwnershipTests
TranscriptHeightSamplingTests  TranscriptMarkdownTests
TranscriptNativeEverywhereTests  TranscriptNativePaneBehaviourTests
TranscriptNativeRowBehaviourTests  TranscriptNativeRowParityTests
TranscriptNativeTurnParityTests  TranscriptNativeWorkParityTests
TranscriptRevealTests  TranscriptStreamingScrollTests
TranscriptTextCalibrationTests  TranscriptViewEqualityTests
TranscriptWorkRowTests  TurnInfoTests
WebhookTests  WorkspaceDurabilityTests
WorkspaceRefreshLifecycleTests
```

Release moves the same classes except these **14**, already serial for other
reasons in Release:

```text
FreshPresentationTests  GitPanelLayoutTests
NativeMarkdownSurfaceStreamingTests  SessionStatsPopoverTests
SmoothHoverAndMotionTests  TranscriptFrameBudgetTests
TranscriptPageStressTests  TranscriptRealAppStreamingTests
TranscriptScrollBudgetTests  TranscriptStreamingScrollTests
TranscriptStreamingStressTests  TranscriptSwitchBudgetTests
TranscriptWidthChangeTests  TranscriptWorkRowTests
```

### Expected gate duration

The normal gate gains 188 serial classes (1,719 statically counted zero-argument
test methods) and removes them from the eight-clone lane. The class selections
are exact; the method count is a source count, not fresh XCTest discovery.
If their total standalone duration is `S`, an ideally balanced eight-worker
lane previously paid `S/8`, while the serial lane pays `S`: nominal net increase
is **7S/8**, plus two source scans (about 16 s at the measured load).
Actual scheduling, overlap and contention can change that estimate.

This workstream's existing passing native text logs cover only **153 methods
in 15 moved classes**. Excluding mutation, failing-first and gallery logs, the
sum of per-method medians is **233.906 s**; their nominal contribution to the
increase is **204.668 s (about 3.4 minutes)**. This is a partial estimate, not a
whole-gate prediction or a measured speed comparison. The remaining 173 classes
lack timings in this build root, and the subset is not representative enough
to extrapolate responsibly. Expect a materially longer serial lane; the lead's
next merged gate is needed for a defensible total. No full native timing run
was added to this script-only task. `lanes-timing-coverage.json` lists the
covered classes, method counts and median sums.

### Commands, results and adversarial review

Commands from this worktree:

```sh
python3 -m unittest scripts.tests.test_test_lanes -v
python3 -m unittest discover -s scripts/tests
python3 scripts/test-lanes.py serial --configuration Debug
python3 scripts/test-lanes.py parallel --configuration Debug
python3 scripts/test-lanes.py serial --configuration Release
python3 scripts/test-lanes.py parallel --configuration Release
xcodegen generate --quiet
python3 -m py_compile scripts/test-lanes.py scripts/tests/test_test_lanes.py
git diff --check
```

Python test commands ran through the existing `run-home-review.py` evidence
wrapper with generated HOME/CFFIXED_USER_HOME/CODEX_HOME and this workstream's
PI_BUILD_ROOT/Release PI_NATIVE_HOST. The mutation/final run was:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  lanes-validation python3 \
  /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/lanes-validation.py
```

| Check | Result | Evidence |
| --- | --- | --- |
| Focused lane tests | 13 pass, 0 fail, 52.845 s | `lanes-focused.log` |
| Full script tests | 131 pass, 0 fail, 0 skips, 108.066 s | `lanes-python.log` |
| Mutations | 8/8 caught | `lanes-validation.log` |
| Both configurations' native-class audit | 461 classes, no flagged parallel class | `lanes-audit.tsv`, focused/full tests |
| Project generation, syntax and diff | Pass | `lanes-static.log` |

The full script suite uses generated data/loopback fixtures, including its
previously authorized launchperf-only UserDefaults probe. No native app, live
benchmark, gallery, capture, paid/live provider request or Keychain operation
ran. No focus changed and no shared full-lane lock was acquired or removed.
Signing retry messages in the Python log are from stubs. No helper/wire source
changed, so no helper or wire gate was required for this change.

Adversarial review:

- Each new API alternative moves only its source owners/users to serial.
  Direct event construction, view-local delivery, ordinary tab activation and
  notification posting remain outside the focus patterns. Conservatively
  serializing responder and whole-fixture use is an explicit scheduling choice.
- Recursive scanning keeps relative paths, avoiding collisions between nested
  files with the same basename. Current test-class names have no collisions.
- Exports preserve file-private scope. Public fixtures carry their own private
  helpers; unrelated private fixtures cannot taint another file. Shared
  extension methods and cross-test-class fixtures have separate regressions.
- The traversal tracks visited names and included chunks, so recursive fixtures
  terminate without losing downstream focus use. Caching only reuses immutable
  identifier sets within one scan; before/after classifications match exactly.
- The inherited-test filter runs after collecting bases. Existing 461-class
  coverage is unchanged, while a synthetic inherited-only subclass is no longer
  silently left in the default parallel selection.
- Focus-free shared helpers do not change the defaults/pasteboard/timing rules.
  In both configurations every previous serial class stays serial, and every
  newly serial class has a focus reason. Serial inclusions equal parallel skips.

No failing check remains. Whole-gate elapsed time remains unmeasured as above.


## Focus lane cost review

Base `0cb23387`, on `dev/a130-gitfiles`; no merge or fast-forward here. This
supersedes the preceding audit's broad focus rule and partial timing estimate.
The lead supplied the complete parallel log for a comparable measurement.

### Confirmed over-classification and revised rule

The earlier detector treated offscreen first-responder operations and local
window/view event delivery as cross-process contention. Its shared-helper
traversal also imported unrelated declarations from a fixture's file, entire
test classes when only a static data builder was used, and unused base-class
window builders. These are confirmed by failing-first generated Swift fixtures.

The new rule serializes window visibility/key/main operations (`orderFront*`
included), app activation/hiding and focus state, application/global input,
modal runs, and window-opening Inspector/tab entry points. Offscreen responder
assignment/inspection, direct view/window handlers and key equivalents stay
parallel. A sheet attached to an offscreen parent alone does not contend; a
fixture that also shows its parent is serial through that visibility operation.

Focus traversal starts at test/lifecycle methods and fixture properties and
follows referenced declarations, including private helpers, extensions, nested
types, qualified static members and inherited members. A data builder does not
pull in the same type's unrelated UI tests. Comments and string contents are
masked, preserving executable Swift interpolation expressions. Constructed
fixture types are inspected as whole types; runtime-only paths still need
`SerialTestLane`. This is a source heuristic, not a general Swift interpreter.

The existing `TabHost.showsWindows = false` seam is recognized for local hosts
and factories returning a proven offscreen host. Unknown hosts, conditional
assignments, computed settings, reassignment and re-enabling do not exempt a
pop-out. This keeps `FileTabTests` and `TabHostTests` offscreen without weakening
real pop-out coverage. The existing defaults/pasteboard/timing rules retain
their original source scope. No production Swift or native fixture changed.

### Failing-first and mutation evidence

`lanes-narrow-before.log`, before changing the implementation:

```text
test_offscreen_responders_and_local_delivery_remain_parallel ... FAIL
test_visible_nonkey_windows_require_serial (api='orderFront') ... FAIL
test_visible_nonkey_windows_require_serial (api='orderFrontStandardWindow') ... FAIL
test_unrelated_shared_helpers_do_not_open_windows ... FAIL
test_shared_type_members_do_not_pull_in_other_members_or_tests ... FAIL
test_comments_and_string_contents_are_not_focus_calls_or_dependencies ... FAIL
Ran 5 tests in 0.005s
FAILED (failures=6)
```

Additional failing-first cases:

- Explicit offscreen pop-out hosts/factories: 1 failure,
  `lanes-narrow-popouts-before.log`.
- Unused base fixture versus called fixture/lifecycle hook: 1 failure,
  `lanes-narrow-base-before.log`.
- Qualified inherited data builder versus visible fixture: 1 failure,
  `lanes-narrow-qualified-before.log`.
- Self-review found that a computed `showsWindows` reset could retain a prior
  false exemption, and `false || flag` could be mistaken for literal false:
  2 failures in `lanes-narrow-settings-before.log`, then fixed. The exemption
  now requires a literal statement and invalidates unknown resets.

All 12 final mutations are caught by assertion failures, restoring the source
in `finally` (`lanes-narrow-validation.log`; individual
`lanes-narrow-mutation-*.log` files):

| Mutation | Regression |
| --- | --- |
| Serialize offscreen `makeFirstResponder` again | Offscreen responder fixture |
| Omit ordinary `orderFront*` | Visible non-key windows |
| Keep comment/string contents | Nonexecuting examples |
| Drop interpolation code | Executing string interpolation |
| Import unrelated shared declarations | Data-only shared helper |
| Import an entire unused base | Called versus unused base fixture |
| Drop qualified inherited-member resolution | Inherited data builder |
| Exempt every pop-out | Default/re-enabled/conditional/computed hosts |
| Remove the offscreen pop-out exemption | Explicit offscreen hosts/factories |
| Keep stale state after conditional re-enabling | Conditional reset |
| Export unrelated private helpers | Private-name collision |
| Omit extension members | Shared XCTestCase fixture builder |

### Comparable measurement and complete class lists

Source: `/Users/admin/Library/Caches/BelloSwiftWork/build-lead/verify-logs/suite-parallel.log`.
This log was read only. The measurement sums each matching non-skipped test's
reported duration, without medians or extrapolation. It reproduces the lead's
original 1,627 tests / 1,926.895 s (32.115 min). The baseline is `fe734912`'s
classification, before the broad audit. All 461 class names remain covered.

| Debug measurement | Broad audit | Revised |
| --- | ---: | ---: |
| Newly serial classes | 188 | 133 |
| Non-skipped tests moved | 1,627 | 1,163 |
| Sum added to serial lane | 1926.895 s / 32.115 min | 1214.656 s / 20.244 min |
| Total serial / parallel classes | 320 / 141 | 265 / 196 |

The reduction is **11.871 minutes** of serial test time. **65** broad-audit classes return to parallel; **10** newly detected
ordinary `orderFront` users join serial. No pre-audit serial class is demoted.
Release selects 267 serial / 194 parallel classes (120 newly serial);
its comparable moved-test subtotal is 1,057 tests / 1103.221 s.
The release gate itself runs the native lanes in Debug, so the Debug figures
above are the requested gate comparison. Full per-class reasons and both
configurations are in `lanes-narrow-audit.tsv`; measurements and selections
are in `lanes-narrow-measurements.json` and `lanes-narrow-*.args`.

Newly serial relative to the original gate (complete list):

```text
AppControlAccessibilityTests
AppShellPerformanceTests
ArchiveSwitchTests
BackgroundRequestsTests
BlockingAlertTests
CancelDefaultQuestionTests
CaptureMacIntegrationTests
CapturedBodyTests
ChangesTabTests
ChatFileLinkTests
CompactTurnReportTests
ConnectionSwitchJournalTests
ContextReadingTests
ConversationPaneRetentionTests
CostLimitTests
FileBlameTests
FileReviewStateTests
FiveSessionWorkspacePerformanceTests
ForkFromReplyTests
FreshPresentationTests
GitBranchesGalleryTests
GitBranchesInteractionTests
GitConfirmationSheetTests
GitDiscardQuestionTests
GitHunkGalleryTests
GitHunkReviewTests
GitIntegratedHistoryGalleryTests
GitIntegratedHistoryTests
GitOperationSafetyTests
GitPanelDiffCaptureTests
GitPanelLayoutTests
GitPanelRedrawTests
GitPanelShownTests
GitPanelWidthTests
GitSafetyGalleryTests
HistoricalEditingTests
HistoryEdgeTests
HistoryExtentTests
InlineSkillPillTests
InlineSkillTests
InspectorEntryPointTests
InspectorExpandInPlaceTests
InspectorFollowTests
InspectorSummaryRequestTests
InspectorWindowControlTests
LaunchSelectionTests
LazyListAppKitControlTests
LiveMonitorTests
LivePopupTests
LiveWorkingIndicatorTests
MarkdownSourceReconciliationTests
MarkdownTextSurfaceTests
MenuBarPresentationTests
MessageDetailTests
MessageVersionTranscriptTests
MiniModelSettingsTests
ModelCatalogEndpointTests
NativeCodeTextTests
NativeMarkdownSurfaceStreamingTests
NativeMarkdownViewportTests
NativeTranscriptDocumentTests
NativeTranscriptScrollTests
NativeTranscriptScrollingPerformanceTests
NativeWorkListViewportTests
PendingChatProjectGalleryTests
PendingChatProjectTests
PerformanceBaselineTests
PiControlAccessibilityTests
PiKitControlTests
PiMenuTests
PiQuestionSheetTests
PiSheetCancelTests
PiSheetWindowTests
QueuePanelGalleryTests
QuickOpenPlacementTests
ReplySourceTests
ReportPageTests
ResponseChronologyTests
SendImmediacyTests
SendLatencyTests
SessionStatsPopoverTests
SessionTimingTests
SessionUsageTests
SettingsUnsavedTests
ShellSheetTests
SideRelaunchTests
SidebarAppearanceTests
SidebarListedOrderTests
SidebarScalePerformanceTests
SidebarSideClickTests
SmoothHoverAndMotionTests
SmoothPaneAndKeyboardTests
SmoothReadingPositionTests
StableToolPresentationTests
StreamingMarkdownStabilityTests
TabPaneTests
TerminalCaptureTests
TerminalPanelAuditTests
TerminalSessionsTests
TimelineStreamingFastPathTests
TranscriptBugGalleryTests
TranscriptDisclosureTests
TranscriptFindTests
TranscriptFollowOwnershipTests
TranscriptFrameBudgetTests
TranscriptGeometryCacheTests
TranscriptHeightSamplingTests
TranscriptKeptRowsTests
TranscriptNativeMessageKindBehaviourTests
TranscriptNativeWorkBehaviourTests
TranscriptPageStressTests
TranscriptQuoteSelectionTests
TranscriptRealAppStreamingTests
TranscriptRevealTests
TranscriptScrollBudgetTests
TranscriptStreamingStressTests
TranscriptSwitchBudgetTests
TranscriptSwitchFirstFrameTests
TranscriptTurnFoldTests
TranscriptUpdateIsolationTests
TranscriptVisibilityTests
TranscriptWidthChangeTests
TranscriptWorkRowTests
TurnAccountingTests
TurnInfoTests
UpdatePauseTests
WebhookTests
WireContractTests
WorkspaceFollowupTests
WorkspaceManagerSheetTests
WorkspaceMotionTests
WorkspaceRedrawTests
WorkspaceRefreshLifecycleTests
```

Returned to parallel relative to the broad audit (complete list):

```text
AccountingScaleTests
BudgetOwnerUnloadTests
ComposerImportSubmissionTests
ComposerSubmissionTests
ContentSearchTests
ConversationFamilyTests
CostPausePresentationTests
FamilyDeletionTests
FileReviewGalleryTests
FileTabTests
GitChangelistReadTests
GitHistoryFilterTests
GitPanelAuditTests
GitPathBoundaryTests
GitRenameTests
HardeningTests
InspectorRequestModelTests
MarkdownStreamingCorrectnessTests
MarkdownStreamingTests
NativeTranscriptSafetyTests
NestedFenceIdentityTests
PastedAttachmentTests
PayloadArchiveTests
PayloadSearchTests
ReleaseConfigurationTests
ReplyFileLinkTests
ReportMessageNavigationTests
ReportNavigationTests
ResponseTimelinePresentationTests
SideBudgetIntegrationTests
SideKeepOrderingTests
SideKeepRecoveryTests
SidebarMetricsLayoutTests
SidebarSearchIndexTests
SidebarSearchScopeTests
SidebarSearchSidebarTests
SubagentCostTests
SubagentDeletionTests
SubagentDiscoveryTests
SubagentDisplayTests
SubagentEffortTests
SubagentInspectorTests
SubagentOrganizationTests
SubagentPanelTests
SubagentSteeringInspectorTests
SubagentSteeringPresentationTests
SubagentSteeringWorkspaceTests
SubagentTranscriptTests
TabHostTests
TerminalCursorAlignmentTests
ToolOutputProducerTests
TranscriptActionsForwardingTests
TranscriptMarkdownTests
TranscriptNativeEverywhereTests
TranscriptNativePaneBehaviourTests
TranscriptNativeRowBehaviourTests
TranscriptNativeRowParityTests
TranscriptNativeTurnParityTests
TranscriptNativeWorkParityTests
TranscriptRowGalleryTests
TranscriptStreamingScrollTests
TranscriptTextCalibrationTests
TranscriptViewEqualityTests
WorkspaceDurabilityTests
WorkspaceTests
```

The ten additions beyond the broad audit are: `GitBranchesGalleryTests`, `GitBranchesInteractionTests`, `LiveMonitorTests`, `LivePopupTests`, `MenuBarPresentationTests`, `PiControlAccessibilityTests`, `QuickOpenPlacementTests`, `SettingsUnsavedTests`, `TerminalSessionsTests`, `WorkspaceFollowupTests`.

### Validation and adversarial review

All evidence is under this workstream's
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/`.
Python commands use the existing generated-home `run-home-review.py` wrapper:

```sh
python3 -m unittest scripts.tests.test_test_lanes -v
python3 -m unittest discover -s scripts/tests
python3 -m py_compile scripts/test-lanes.py scripts/tests/test_test_lanes.py
git diff --check
```

The two requested native runs use `lanes-narrow-native.py`, generated
HOME/CFFIXED_USER_HOME/CODEX_HOME, and the existing own `native-tests` build
folder. It takes the shared full-lane lock, rebuilds the bundle helper and
Debug test host, runs only the newly serial selection once with parallelism
OFF, then runs the remaining parallel selection once with eight workers.
There is no full-gate invocation or retry. Commands, exit codes and elapsed
times are in `lanes-narrow-native-results.json`; text logs are the evidence.
Two lock-waiting processes were canceled before any build/test started, first
to shorten polling and then to wake on directory deletion. Their
`KeyboardInterrupt` logs (`lanes-narrow-queued*.log`) are queue cancellations,
not test failures; the other workstream retained its lock throughout. The
notification adapter also needed an explicit `kqueue.close()` because the
installed Python does not provide its context-manager protocol
(`lanes-narrow-queued-notify.log`); that correction preceded all builds/tests.
No installed app or paid/live provider path is launched. New result bundles
and own parallel clone folders are removed after the runs; the owned lock is
released in `finally`.

| Check | Result | Text evidence |
| --- | --- | --- |
| Final lane unit cases (included in script discovery) | 21 pass, 0 fail | `lanes-narrow-python.log` |
| Full script suite, final source | 139 pass, 0 fail, 0 skips (117.547 s) | `lanes-narrow-python.log` |
| Mutations | 12/12 caught | `lanes-narrow-validation.log` |
| Project / Release helper / Debug test build | All exit 0; generated project unchanged | `lanes-narrow-project.log`, `lanes-narrow-bundle.log`, `lanes-narrow-build.log` |
| Native serial, 133 classes | 1,169 passed, 23 skipped, 1 failed test (2 assertion failures); exit 65; 1185.957 s wall time | `lanes-narrow-serial.log` |
| Native parallel, 196 classes | 1,578 passed, 23 skipped, 2 failed tests; exit 65; 341.776 s wall time | `lanes-narrow-parallel.log` |

The serial run executed 1,193 unique tests; the eight-worker run executed 1,603.
There are no duplicate result rows. The fresh serial selection has seven more
non-skipped tests than the supplied historical log; the historical duration
sum is not extrapolated to those tests. `lanes-narrow-native-counts.json`
contains the counts and failed identifiers. Both lanes ran once. Newly created
automatic result bundles were removed, and the final scan found no own clone
folders. The runner released its lock before another workstream acquired it.

Exact native command structure (under the generated-home wrapper and lock):

```sh
lane_build=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles
lane_evidence="$lane_build/evidence"
PI_BUILD_ROOT="$lane_build" python3 scripts/build-bundle.py
lane_xcode=(-project PiApp.xcodeproj -scheme PiApp -destination 'platform=macOS,arch=arm64'
            -derivedDataPath "$lane_build/native-tests" CODE_SIGNING_ALLOWED=NO)
xcodebuild "${lane_xcode[@]}" build-for-testing COMPILER_INDEX_STORE_ENABLE=NO
xcodebuild "${lane_xcode[@]}" test-without-building -parallel-testing-enabled NO \
  $(cat "$lane_evidence/lanes-narrow-serial.args")
xcodebuild "${lane_xcode[@]}" test-without-building -parallel-testing-enabled YES \
  -parallel-testing-worker-count 8 $(cat "$lane_evidence/lanes-narrow-parallel.args")
```


The requested zero-failure native result was **not achieved**. The unchanged
`PiSheetWindowTests.testEveryWorkspaceSheetIsAWindowOfTheAppsOwn` failed its
final release wait at `apps/macos/PiAppTests/PiSheetWindowTests.swift:384` and
`:388`:

```text
failed - Never every closed sheet's views to be let go of
failed - Closed sheets' views still alive:
["NSTextInsertionIndicator window=none superview=none": 1]
... failed (41.014 seconds).
```

`lanes-narrow-sheet-failure.log` preserves the complete case excerpt. The test
already exempts `_NSText*` survivors but does not exempt this class; the retained
owner of the detached indicator has not been established. The same test's final
view-release wait failed in the earlier
[0.1.127 validation](git-safety-final-integration-0.1.127.md), which also left its
cause unresolved. No sheet implementation/assertion or timeout was changed,
and the failed test was not retried. It remains a separate existing test issue,
not a passing gate or a reason to put visible sheets back in parallel.

The parallel run also failed two unchanged tests:

| Test | Source / scenario | Evidence and limit |
| --- | --- | --- |
| `SubagentPanelTests.testTopicCountsOnlyMainChatsAndMatchingTopicDoesNotHideChildSearchHits` | `apps/macos/PiAppTests/SubagentPanelTests.swift:23`; generated model, topic counts and filtered child rows | Failed after 0.043 s. This uses a data builder and creates no key/visible window. It was parallel before the broad audit, over-classified by importing all of `ConversationPaneTests`, and is parallel again. |
| `FilePreviewRefreshTests.testSiblingNotificationsLetTheActivePreviewPublish` | `apps/macos/PiAppTests/FilePreviewRefreshTests.swift:7`; generated BMP, held preview reads and repeated notifications | Failed after 10.254 s. This class stayed parallel before, during and after the audit; it does not contend for window focus. |

The console preserves both failed identifiers and durations, but not their
assertion messages. The runner's temporary-result cleanup completed before an
attempted text export of those details. The export supervisor detected that
another workstream already owned the lock and aborted before signaling any
process (`lanes-narrow-failure-details.log`); no other owner's lock/process was
touched. The exact causes of these two failures therefore remain unresolved,
and neither was rerun or reclassified to conceal the failure. All three failed
test files and their production paths are unchanged by this work.

Adversarial self-review of every changed condition:

- Visibility, activation, global input and focus-state checks still select
  serial; dropping offscreen responder/local-handler alternatives only affects
  process-local work. Both sides have generated fixtures and mutations.
- Removing comments/literal contents avoids accidental API/dependency matches;
  keeping interpolation code prevents actual operations from being hidden.
- Test/lifecycle/property roots keep setup and inherited tests reachable.
  Resolving called base and qualified inherited members avoids both unused
  builder imports and omitted real window builders. Cycles terminate.
- File-private declarations stay private, local names do not resolve to
  unrelated globals, and extension helpers are followed only when referenced.
- The offscreen pop-out exemption requires positive fixture evidence; conditional
  or unknown resets invalidate it. Real pop-outs still classify serial.
- Existing defaults/pasteboard/timing scope is independent of narrowed focus
  traversal. No original serial class is demoted in either configuration.
- The CLI's serial inclusions equal its parallel exclusions. Both configurations
  pass the independent focus-API guard and the known fixture-user checks.

## Round 13 review — declarations and intermittent native tests

Scope: review of `ce511cde`; no merge or fast-forward. All changes are in the
lane detector, test fixtures and documentation. Production app/helper behavior,
permission checks and preview deadlines are unchanged. Evidence below is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence` (`E`);
`B` is that workstream's build root, without `/evidence`.

### Complete Swift declarations — confirmed and fixed

`blocks()` previously stopped at the first signature line unless that line
already opened a body. This dropped `TranscriptStreamingScrollTests.stream`
and `TranscriptRowGalleryTests.capture` from their callers' focus graph.
The replacement reads balanced attribute/argument groups and the complete
signature/body before creating nodes, including multiline generic and `where`
clauses, default closures, bodyless protocol requirements, and property bodies
or initializer continuations. Graph nodes receive the parsed body separately;
a parameter's default closure cannot be mistaken for the declaration's body.

Failing first (`lanes-r13-parser-before.log`): four test methods, eight failed
subcases, including multiline signatures, attributes, generics/where, nested
default arguments and the two real transcript classes:

```text
AssertionError: 'focus' not found in []
... (name='TranscriptStreamingScrollTests')
... (name='TranscriptRowGalleryTests')
Ran 4 tests in 8.859s
FAILED (failures=8)
```

Permanent coverage is in `scripts/tests/test_test_lanes.py`:

- `test_complete_helper_signatures_keep_their_bodies`
- `test_signature_closures_are_not_the_declaration_body`
- `test_declaration_boundaries_include_attributes_generics_and_defaults`
- `test_multiline_inheritance_and_attributes_keep_test_declarations`
- `test_string_properties_and_protocol_requirements_do_not_eat_neighbors`
- `test_multiline_property_bodies_and_initializers_keep_focus_calls`
- The existing real-class audit now explicitly requires both reported classes
  to have a `focus` reason in Debug.

Nearby sweep: string initializers must not consume a following declaration;
multiline computed properties and trailing initializer closures must retain
executable bodies too. Each got a failing fixture before correction
(`r13-parser-neighbor-before.log`, `r13-parser-property-before.log`). Offscreen
neighboring helpers remain parallel. Six mutations all fail their targeted
fixtures: truncate multiline signatures; stop balancing attribute arguments;
misread parameter default braces as the body; omit generic delimiter handling;
consume a neighboring declaration; drop multiline property continuations.
`r13-parser-check.py`, `r13-parser-mutations.log` and the six
`r13-parser-mutation-*.log` files preserve the mutations and results.

The repository inventory retains all 461 native test classes. Relative to
`ce511cde`, the signature fix adds precisely `TranscriptStreamingScrollTests`
and `TranscriptRowGalleryTests` to Debug's serial lane; only the latter is newly
serial in Release, where streaming already had a budget reason. No formerly
serial class becomes parallel. The focus rule itself has not broadened.

### Preview timeout — test isolation, confirmed and fixed

The failure was order-dependent, rather than a slow image decode. In the prior
parallel log, worker **66725** ran `SessionReferenceTests` immediately before
`FilePreviewRefreshTests`. That fixture constructs a `WorkspaceModel`, whose
initializer installs `FileTab.resolveProject = { [weak self] ... ?? .removed }`.
After the model dies, even a standalone (`projectID == nil`) tab constructed
through that inherited resolver is unreadable. Its direct `preview.load()` can
complete, but `FileTab.followChange()` correctly refuses notifications for the
unreadable tab. The test then waits forever for the queued metadata recheck.

A clean-process stress run did **128/128** executions successfully, with eight
workers and eight CPU burners. Adding continuous generated sibling-directory
creation/removal (1 ms cadence) and 64 iterations gave **1,024/1,024** passes.
Neither run needed a longer deadline. Logs: `r13-preview-load-before.log` and
`r13-preview-churn-before.log`.

The new regression creates a real generated `WorkspaceModel` with an in-memory
vault, shuts it down, closes its stores, drops the last reference, confirms its
weak reference is nil and the inherited resolver is unavailable, then invokes
the original preview scenario. Before fixing the fixture this fails at:

```text
FilePreviewRefreshTests.swift:25: ... failed - queued metadata recheck entered
```

The first isolated reproduction failed one test (`r13-preview-owner-before.log`).
Its initial diagnostic fixture omitted creating its unused state directory;
cleanup also produced a misleading Cocoa error while propagating the expected
timeout. The directory is now explicitly generated. With that correction and
**no resolver fix**, eight workers under the same CPU/directory load failed
**8/8**, all with `queued metadata recheck entered`
(`r13-preview-expired-load-before-summary.json`). This reproduces the original
failure under load while identifying the missing precondition.

The original test now saves, installs and restores its own standalone-file
resolver, following `FileReviewFixture`'s existing pattern. The permanent
`testSiblingNotificationsAfterAWorkspaceFixtureIsReleased` proves that setup
survives an expired predecessor and restores the unavailable resolver afterward.
It also restores all other global callbacks/policy installed by its temporary
workspace. No production trust fallback or watcher/preview condition changed.

With the fix, eight temporary subclasses ran all three class methods 64 times:
**1,536/1,536 passes, zero skips/failures**, with eight workers, eight CPU burners
and continuing sibling churn (`r13-preview-fixed-load.log`). The temporary
subclasses were removed and the original class remains `final`.

Nearby sweep: `FileReviewFixture` already saves/restores and installs its own
resolver. `FileTabTests.setUp` currently resets that resolver in teardown only
(`FileTabTests.swift:221`); a first test after an expired workspace is a similar
setup risk, recorded for follow-up rather than widening this assigned fix.
The earlier unrelated `SubagentPanelTests` failure is outside this request.

### Sheet survivor — AppKit ownership, confirmed and precisely exempted

Three isolated repetitions of the old check passed: their only weak survivors
were `_NSTextSelectionView`, `_NSTextContentView` and `_NSTextViewportElementView`,
which the check already exempts (`r13-sheet-probe.log`,
`r13-sheet-objects-{1,2,3}.log`). Requesting activation of the generated test
host also exercised the macOS 14 system cursor accessory and reproduced the
reported survivor. After the sheet roots were cleared and two run-loop seconds
elapsed, the tracked objects consisted of those same three framework views
plus a detached `NSTextInsertionIndicator`; no tracked sheet-owned view survived.

Ownership evidence, **only in our generated test host**, while holding the
full-lane lock:

- `r13-sheet-active-objects-1.log`: test-host PID 59689, indicator `0x130895eb0`.
- `/usr/bin/leaks --noContent --traceTree=0x130895eb0 59689`:
  `r13-sheet-active-owner-1.log`. A direct **strong block capture** retains the
  indicator. That block is registered in a notification center rooted through
  AppKit `NSRemoteView`, ViewBridge and an XPC connection. The graph also shows
  the system `TextInputUIMacHelper`/`TUINSCursorUIController` machinery and a
  framework autorelease-pool reference.
- A read-only LLDB inspection of the capturing block's invoke pointer
  (`0x600002f14930 + 16`) resolved it to
  **AppKit’s `__22-[NSView _commonAwake]_block_invoke`**
  (`r13-sheet-block-symbol.log`). The debugger detached immediately afterward.
  Arbitrary interior-pointer/Swift-metadata paths in the conservative heap
  graph are not used as ownership evidence.
- App production sources do not instantiate, retain or name this indicator.
  All tracked app/text views are gone; the remaining cursor's `window` and
  `superview` are nil.

Apple documents this system cursor and its accessory behavior in
[Adopting the system text cursor](https://developer.apple.com/documentation/appkit/adopting-the-system-text-cursor-in-custom-text-views).
The ownership conclusion above comes from the fixture's reference trace and
resolved AppKit block, rather than assuming every view with a text-related name
is a framework survivor.

The diagnostic retained the old filter and failed:

```text
failed - Never every closed sheet's views to be let go of
failed - Closed sheets' views still alive:
  ["NSTextInsertionIndicator window=none superview=none": 1]
```

`r13-sheet-active-before.log` also contains a separate failed *diagnostic*
`NSApp.isActive` wait: the activation request exercised the accessory without
that property settling. That extra wait and the ownership-probe delay are not
part of the final fixture. The activation request remains, in this already
serial window test; no new focus deadline is asserted.

`isFrameworkTextSurvivor` preserves the existing `_NSText*` exception and adds
only the exact AppKit `NSTextInsertionIndicator` class **with no window and no
superview**. It does not exempt its app subclasses, attached indicators,
`NSTextView`, ordinary views, or all `NSText*` names. All original per-sheet
window/descendant checks and the requirement that the app's content deallocate
remain intact. A new unit case exercises each side of this boundary.
The survivor poll still returns type names from its autorelease pool, avoiding
retaining views across an asynchronous wait.

### Commands, final checks and adversarial review

Every native invocation used the existing own build root and
`scripts/test-macos.sh`; it rebuilt the Release bundle helper and generated the
project before the focused app build. All native runs, diagnostics, activation
and gallery captures held `full-lane.lock`, released only by their owner, even
on a failed test. The parent command also received generated `HOME`,
`CFFIXED_USER_HOME` and `CODEX_HOME` through `E/run-home-review.py`; the scheme's
test-host guard verified its separate data home and fixture defaults domain.
No installed app, live provider, real account resource or real app preferences
were used. No named result bundle or additional DerivedData tree was created.
Automatic result summaries were exported to text/JSON before bundle cleanup.

Exact focused command pattern (the wrapper acquires/releases the lock):

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles
E="$B/evidence"
python3 "$E/run-home-review.py" r13-streaming-driver \
  python3 "$E/r13-locked.py" r13-streaming scripts/test-macos.sh \
  -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptStreamingScrollTests
TEST_RUNNER_PI_APP_UI_SCREENSHOT_ROOT="$E/r13-transcript-gallery" \
  python3 "$E/run-home-review.py" r13-gallery-driver \
  python3 "$E/r13-locked.py" r13-gallery scripts/test-macos.sh \
  -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptRowGalleryTests
python3 "$E/run-home-review.py" r13-sheet-fixed-driver \
  python3 "$E/r13-locked.py" r13-sheet-fixed scripts/test-macos.sh \
  -parallel-testing-enabled NO -test-iterations 3 -only-testing:PiAppTests/PiSheetWindowTests
python3 "$E/run-home-review.py" r13-python-final \
  python3 -m unittest discover -s scripts/tests
```

Stress commands used the same wrapper with `--load`,
`TEST_RUNNER_PI_APP_SCRATCH_ROOT="$E/r13-preview-scratch"`,
`-parallel-testing-enabled YES -parallel-testing-worker-count 8`, and
`-only-testing:PiAppTests/PreviewLoad0Tests` through `PreviewLoad7Tests`.
The first run used `-test-iterations 8`, the churn and fixed runs used 64.
The expired-owner red run selected only
`testSiblingNotificationsAfterAWorkspaceFixtureIsReleased` in each of the eight
classes, once. Exact argument arrays, exits and elapsed times are in their
`r13-*-driver.log` files. The synthetic loads and scratch churn are implemented
in `r13-locked.py`; all child load processes are terminated in its `finally`.

Final validation, with no skips or unexpected failures in the fixed runs:

| Suite / run | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `python3 -m unittest discover -s scripts/tests` | 145 | 0 | 0 |
| `PiSheetWindowTests`, 12 methods × 3 iterations | 36 | 0 | 0 |
| `FilePreviewRefreshTests`, permanent class after stress scaffolding removal | 3 | 0 | 0 |
| `TranscriptStreamingScrollTests` | 3 | 0 | 0 |
| `TranscriptRowGalleryTests`, capture environment enabled | 2 | 0 | 0 |
| Sheet exemption unit after all mutations were restored | 1 | 0 | 0 |
| Preview stress, eight workers × three methods × 64 iterations | 1,536 | 0 | 0 |

The streaming class has three methods; the fourth test method in its source
file belongs to the separate `TranscriptStreamingCadenceTests`. The gallery
produced 12 PNGs (six scenes, light/dark), all opened and visually inspected:
folded/open work, folded/open turns, stopped reply, saved response details.
Visible text and disclosure layouts were intact. Images are in
`E/r13-transcript-gallery/screenshots`; no UI implementation changed.

Six parser mutations and four native mutations were all caught (**10/10**).
The native mutations, run alone under the shared lock, were:

1. Remove the fixture resolver override: the expired-workspace regression
   again times out at `queued metadata recheck entered`.
2. Remove the exact indicator exemption: the detached-indicator positive checks
   fail.
3. Broaden exact-class membership to `isKind(of:)`: the app-subclass negative
   check fails.
4. Remove the detached-state restriction: the attached-indicator negative
   check fails.

Each mutated invocation exited 65 with the intended assertion, never a compile
failure. `r13-native-mutations.py`, `r13-native-mutations.log`, and the four
`r13-mutation-*.log` files preserve exact source substitutions and commands.
The script restores source in `finally`, then runs the permanent preview class
and sheet boundary unit separately with:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/FilePreviewRefreshTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PiSheetWindowTests/testTextSurvivorExemptionRequiresTheExactDetachedAppKitIndicator
```

`r13-counts.json` contains the text-log counts; `r13-python-final.log` records
145 passes in 143.007 seconds. Native commands used this workstream's generated
home wrapper and build root as above. Final Python compilation and `git diff
--check` pass. No clone folders remained in the own products tree. The final
lane inventory (`r13-parser-lanes-final.json`) is Debug **267 serial / 194
parallel**, Release **268 / 193**, with no missing classes or serial demotions.
No helper/wire behavior changed, so their full suites were not rerun.

Three initially queued diagnostic commands exited before any build/test because
the scratch lock wrapper tried to read `owner` during another owner's lock
publication/removal gap. It now tolerates that race; those queue-only logs are
retained as `r13-*-driver-queue-race.log`. No other owner's lock was removed or
process interrupted. All actual runs and their expected failing-first/mutation
outcomes remain separately recorded.

Adversarial review of changed conditions:

- A newline inside a signature now continues to the actual body; balanced
  attribute/default groups keep their nested braces in the header. Actual body
  delimiters and following declarations still stop traversal at the right
  scope. Positive focus fixtures and offscreen neighbors cover both directions.
- Generic delimiters/where constraints no longer become inheritance names or
  cut property types short. Bodyless requirements and string properties cannot
  consume the next member. Nested/private/extension resolution and the existing
  offscreen-popout proof remain unchanged.
- The fixture's explicit resolver affects only its generated standalone file;
  non-nil project IDs still resolve to removed, and the predecessor's resolver
  is restored even on failure. The regression restores every workspace-installed
  global it changes; no production guard now admits a different state.
- The sheet filter's only newly accepted state is an exact, detached framework
  indicator. An app subclass, attached cursor, parent text view, or ordinary
  retained content still fails. Framework references are checked inside the
  same autorelease-pool boundaries as before; no deadline was extended.
- The activation request exercises an existing serial UI path. It introduces
  no `isActive` assertion or dependency on activation completing within a fixed
  interval. Diagnostics and generated stress subclasses are not shipped.

The test-lane parser remains a source-based named-declaration traversal, not a
full Swift type checker; dynamic-only dispatch still needs the documented
`SerialTestLane` marker. No scope expansion into production code was needed.

## Round 14 — native fixture hook ownership

Base: `688f8751` on `dev/a130-gitfiles`, after the lead's merge and fast-forward.
Scope is native test fixtures only. No shipping code, helper behavior, wire
behavior, user preferences, real credentials, or provider calls changed.

### Audit and regression method

The declaration graph covers all 465 native classes; its hook-consumer
index is `r14-class-hook-audit.csv` under the evidence root below.
Audited stored static variables and singleton members in `PiApp`, shared native
views, test support, and native test sources, including test-only extensions
such as `TranscriptRowRenderer.native`. Followed the setters and the callers
that actually invoke a callback; a callback merely captured by an unpressed
button is not an invocation. Instance-owned seams (workspace history loaders,
question objects, read/decode gates, storage clocks) belong to each freshly
constructed fixture and cannot inherit another test's injected callback.

The permanent `testFixtureOwnsInheritedHooks` checks seed hostile state, call
that class's actual `setUp`, exercise the expected fixture path, and register
an assertion between the inner and outer teardowns. This checks both entry
isolation and restoration of the previous value. The file probe writes and
reads a generated standalone file; the question probe drives a real native
sheet; the reveal and hover probes check their bypass/timing hooks directly.
This needs neither a particular test ordering nor a particular clone worker.

The first setup scaffold needed actor-isolated setup closures (rather than
calling the nonisolated XCTest base API through an erased `XCTestCase`) and
had a duplicated closure corrected before runtime checks. Compiler failures
are not counted as failing-first evidence.

### Findings

Confirmed and fixed five fixture-ownership patterns:

1. Standalone-file classes inherited an expired workspace resolver. The six
   classes now install the nil-project fixture resolver in `setUp`, before
   constructing any view, and restore the captured resolver in a teardown
   block. Existing tests can still override it with their own trusted or
   removed-project scenarios.
2. Four shared-question consumers inherited another fixture's answer or
   presenter. Their setup now installs the hooks of a fresh `PiQuestion`,
   and restores all seven previous injectable members. Body-local recording
   answers and presenters still take precedence.
3. Three real sidebar-reveal consumers inherited a spy that bypassed the
   adapter. Their setup now clears the override and restores the actual prior
   closure. Tests that need a spy install one after setup.
4. The shared base of the two inline-skill classes only reset its hooks at
   teardown. It now owns the hover delay and file actions from setup through
   teardown. Unconfigured file actions fail the test instead of opening a
   real application; action tests already install their recording callbacks.
5. Nearby sweep: `FileReviewFixture.init` installed its resolver before
   throwing filesystem operations. A failed constructor had no `close()` to
   restore it. Installation now happens after those operations. The regression
   passes a generated regular file as an ancestor of the requested directory,
   so failure is deterministic and does not depend on filesystem permissions.

Every affected class has a failing-first probe; the class-by-class results
are below. Except for `FileReviewStateTests`, the method is
`testFixtureOwnsInheritedHooks`. That class uses
`testAFileFixtureThatFailsToOpenPreservesItsCallersResolver`.

| Class | Hook | Before fix | Focused pass / fail / skip | Mutation failures caught |
| --- | --- | --- | --- | --- |
| `FileTabTests` | File resolver | 1 failed | 17 / 0 / 0 | 2: install + restore |
| `FileSyntaxTests` | File resolver | 1 failed | 14 / 0 / 1 | 2: install + restore |
| `FileFolderTests` | File resolver | 1 failed | 20 / 0 / 0 | 2: install + restore |
| `TabHostTests` | File resolver | 1 failed | 17 / 0 / 0 | 2: install + restore |
| `ChangesTabFrameTests` | File resolver | 1 failed | 8 / 0 / 0 | 2: install + restore |
| `ChangesTabTests` | File resolver | 1 failed | 9 / 0 / 0 | 2: install + restore |
| `BlockingAlertTests` | Shared question | 1 failed | 8 / 0 / 0 | 2: install + restore |
| `SettingsUnsavedTests` | Shared question | 1 failed | 25 / 0 / 0 | 2: install + restore |
| `TerminalSessionsTests` | Shared question | 1 failed | 14 / 0 / 0 | 2: install + restore |
| `PayloadNativeControlTests` | Shared question | 1 failed | 23 / 0 / 0 | 2: install + restore |
| `SidebarSearchSidebarTests` | Reveal override | 1 failed | 10 / 0 / 0 | 2: install + restore |
| `TranscriptRevealTests` | Reveal override | 1 failed | 11 / 0 / 0 | 2: install + restore |
| `SubagentOpeningTests` | Reveal override | 1 failed | 15 / 0 / 0 | 2: install + restore |
| `InlineSkillPillTests` | Shared hover/actions | 1 failed | 15 / 0 / 1 | 2: install + restore |
| `InlineSkillPillTimingTests` | Shared hover/actions | 1 failed | 2 / 0 / 0 | 2: install + restore |
| `FileReviewStateTests` | Resolver on init failure | 1 failed | 21 / 0 / 0 | 1: install before throwing work |
| `FileHiddenReadTests` | Shared `FileReviewFixture` coverage | Unchanged class | 5 / 0 / 0 | Covered by constructor regression |

All 16 affected classes are confirmed/fixed; the unchanged seventeenth class
covers the shared file-review fixture. Skips are the existing opt-in
`FileSyntaxTests.testDelayedSyntaxGallery` and
`InlineSkillPillTests.testCaptureSkillPillLooks` capture tests.

Failing-first output excerpts (each selected probe exited 65):

```text
File: XCTAssertNil failed: "Its project was removed from Bello Agent."
      A previous workspace cannot remove this standalone fixture
      XCTUnwrap failed: expected non-nil value of type "FileDocument"
Question: XCTAssertNil failed: "NSModalResponse(rawValue: 1001)"
          An inherited answer must not bypass the fixture's sheet
Reveal: XCTAssertNil failed: "(Function)" - This class exercises the real sidebar reveal
Skill: XCTAssertEqual failed: ("20.0 seconds") is not equal to ("0.45 seconds")
       The hover fixture owns its timing
Constructor: XCTAssertEqual failed: ("none") is not equal to
             ("untrusted(name: "outer fixture")")
             A failed fixture has no close() to restore its caller's resolver
```

The old teardown-only behavior also failed the restoration mutations:
hard-coded defaults lost the inherited `.removed` resolver, reveal spy,
question answer or 20-second delay. These are teardown assertions, not
timeouts or compiler failures.

### Sweep dispositions

- `FileTab.resolveProject`: standalone consumers need a class-owned nil-project
  resolver; a dead workspace closure returns `.removed` even for nil. The
  six affected classes are listed in the result table. Workspace-backed file,
  find, blame, pane and Changes fixtures construct their own `WorkspaceModel`,
  which installs its own file/Changes callbacks before their use.
- `FilePreviewRefreshTests` already scopes its standalone resolver, including
  its expired-workspace regression. `FileReviewFixture` scopes the standalone
  resolver for `FileReviewStateTests` and `FileHiddenReadTests`; its constructor
  failure gap is fixed above, and both consuming classes are covered.
- `FileTab.activate/openHistory`, `FileBlame.openChange`, and
  `ChangesTab.resolveProject/openLocation/activate`: navigation tests install
  their own workspace; the standalone Changes restoration test supplies its
  own Changes resolver. History-only label fixtures construct a file tab as
  an identity/return label, never read its file or invoke its navigation hooks.
- `PiQuestion.shared`: real-sheet consumers must clear inherited answer hooks,
  while preserving every previous injectable member. Tests using private
  `PiQuestion` instances or `model.questions` own those instances. Other shared
  asker callers explicitly install their answer/file/text spies before invoking
  that path (`MCPRemovalTests`, settings-close, update, lifecycle, inspector,
  workspace-folder, and terminal-tab tests).
- `SidebarSearchReveal.override`: the real-reveal tests need a class-owned nil
  override. The subagent-opening search route also invokes this adapter. Scope-only
  tests install their reveal spy before invoking it.
- `SkillPopovers.shared`: the inline-pill fixture owns the hover delay and
  Open/Reveal callbacks. Action tests install recording callbacks before a
  press. Screenshot fixtures set their own shortened hover delay.
- `PiMenus.intercept`: actual `popUp` callers in menu/control/composer/inspector
  tests install their spy first. Other menu tests call `menu`/`perform`, which
  do not consult the interceptor.
- `TranscriptRowRenderer.reference`: its two writers are parity renderers,
  which install their chosen renderer and defer restoring the previous mode.
  `TranscriptKeptRowsTests` explicitly installs its no-workspace policy; pane
  fixtures with a workspace install that workspace's policy. Resident limits
  and the idle-scheduler interval are scoped by their existing callers.
- Clocks: `TranscriptIdleScheduler`, archive, session-usage and turn-duration
  clocks are injected into individual instances. `PerformanceProbe.now` and
  `TranscriptLayoutClock.now` are computed monotonic readings, not replaceable
  closures. Counters, layout constants and caches are not callback ownership.
- `FileBlame.service` and `FileTextStyle.standard` have no test writers.
  Singleton storage/workers, inspector-window registries, cursor/popover
  managers and the geometry cache expose no additional writable global
  resolver/clock callback used by these tests. No production restore path was
  needed.

### Validation and adversarial review

Evidence root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
All commands ran in this worktree with the same build root. The evidence
wrapper supplied generated `HOME`, `CFFIXED_USER_HOME` and `CODEX_HOME`;
the native scheme also applied its existing test-host isolation.

Focused command, once for each class in the table:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/<Class>
```

For failing-first and mutation runs, the final argument selected
`PiAppTests/<Class>/<Method>` instead. The two parallel file classes shared
one invocation for their initial mutation checks; serial-lane classes were
always selected alone. Real-sheet probes and every focus-changing full class
held the shared full-lane lock. Offscreen setup probes did not acquire focus.
No eight-worker lane or full gate was run.

Logs: `r14-red-<Class>.log`, `r14-green-<Class>.log`,
`r14-mutation-<pattern>-<Class>.log`; the initial parallel-class mutations
are `r14-mutation-<pattern>.log`. JSON summaries beside them retain selected
methods and statuses. Lock-wait cancellations and initial compile errors
are excluded from the runtime pass/fail counts.

Full focused totals: **234 passed, 0 failed, 2 skipped across 17 classes**.
All 16 failing-first probes failed before their fixes. Nine source mutations
(remove an install or replace restoration with a default for each hook family,
plus move resolver installation before the throwing constructor work) caused
**31 expected failing test cases** across those classes. All mutations were
restored. The initial three parallel-class probes passed again after their
mutations; the remaining offscreen classes passed their full focused runs
with the source restored. The four question probes also passed again after
restoration (`r14-restored-<Class>.log`).

All completed full-class runs passed. `xcodegen generate --quiet`
registered the new test helper; the ordinary test script regenerated the
project for every build. `git diff --check` passed. No clone folders or extra
DerivedData copies were created; automatic result bundles were removed after
recording text evidence.

Adversarial review:

- A nil-project file now takes the standalone readable path after a prior
  workspace expires. An unknown non-nil project still takes `.removed`.
  Tests of trust/removal continue to install their own resolvers after setup.
  No production permission or capture boundary changes.
- Inherited question answers and presenters no longer bypass or stall a
  fixture's native sheet. Explicit answers installed by the test still win.
  All seven previous members are captured, including the custom-sheet and
  file/text chooser seams. Teardown is registered before views are created,
  so their later cleanup runs before restoration.
- An inherited reveal spy no longer replaces the real reveal adapter.
  Local spies still work; the teardown probe calls the captured prior spy
  once, detecting a hard-coded nil reset.
- An inherited hover delay no longer controls the inline-skill fixture.
  File-action tests install spies before invoking Open/Reveal. Setup never
  installs real Finder or application-opening actions. Teardown closes the
  fixture's popovers and restores the caller's delay/actions.
- File-review construction failures now precede any resolver mutation.
  Successful construction and `close()` retain the same ownership interval.
  The test's new `root` argument defaults to the existing generated root.
- Probe failure paths clean up their generated files/windows. The question
  probe's early return follows an assertion failure; it only avoids waiting
  for a sheet that the hostile answer has already bypassed. Nested setup
  checks restoration in LIFO teardown order without relying on test order.
- No affected superclass had setup work displaced by these overrides.
  The shared inline-skill base owns both concrete classes' hook scope.

`python3 scripts/test-lanes.py list` still reports the same 465 classes with
identical lanes; the parser and its rules were not edited. No production or
helper source changed, so helper/wire suites and UI gallery regeneration are
outside this round's affected scope.

## Round 15 — ignored Git events queued during refresh

Base: `7e7927a6`, on `dev/a130-gitfiles`. No merge or fast-forward performed.
Only the Git watcher/controller and their native regression class change.
The helper, wire protocol, permissions, captures and file operations are unchanged.

### Root cause and failing-first evidence

Confirmed product defect, not an overly strict two-second test wait. The panel
workstream's original log is
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-panel/evidence/round-8/GitWorkingTreeWatcherTests-merged-first-failure.log`
(copied to this workstream's evidence as `r15-original-panel-failure.log`).
It records 17 tests with one failed test, specifically:

```text
XCTAssertLessThanOrEqual failed: ("2") is greater than ("1")
a new ignored folder costs at most one refresh
```

The ignored list contains existing ignored paths, not the `.gitignore` patterns.
A newly created `build/` therefore correctly triggers one refresh to learn it.
The bug is losing the paths of a second batch before that refresh finishes:

1. The FSEvents bridge accepts a batch using the old ignored list.
2. The watcher's throttle stores only a work item; its trailing callback used
   to call `onChange` unconditionally, even if the first refresh had learned
   `build/` in the meantime.
3. If the throttle fires while the read is still running, the controller
   stores only `automaticChangePending = true`. Finishing the read used to
   start another refresh unconditionally. A reader-requested refresh has the
   same problem through `missedChange`.

Both deferral points can independently cause the observed second refresh.
The saved incident log lacks event-batch timestamps, so it cannot distinguish
which queue delivered that incident's second refresh. Both orderings are
reproduced directly, without waiting for the kernel to choose a batch split.
No throttle interval, FSEvents latency or original test deadline was changed.

`r15-red-final.log` is the decisive pre-fix run: **5 tests, 3 failed, 2 passed**.
Each of the three ignored-event regressions failed (3/3); both tracked-file
controls passed. The status-read seam holds a completed snapshot before the
ignored list is read, and the existing bridge supplies separate batches.
Read-only pending-state accessors prove delivery while the read is held.

| Test in `GitWorkingTreeWatcherTests` | Before fix | Purpose |
| --- | --- | --- |
| `testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores` | 2 callbacks, expected 1 | The ignored list changes while a callback waits in the throttle |
| `testIgnoredEventsDuringAnAutomaticRefreshAreRechecked` | 2 refreshes, expected 1 | The second batch reaches the controller while its first refresh is held |
| `testIgnoredEventsDuringAReaderRefreshAreRechecked` | 2 automatic refreshes, expected 0 | Nearby sweep: the reader's refresh learns the folder before deferred events drain |
| `testTrackedEventsDuringAnAutomaticRefreshStillRefresh` | Passed | Mixed ignored/source batches must retain a real follow-up |
| `testTrackedEventsDuringAReaderRefreshStillRefresh` | Passed | Deferred source changes must reach the status after a reader refresh |

An initial probe draft additionally assumed an exact count for source events,
which can arrive through both the injected bridge and real FSEvents, and used
an absolute count for the source-control callback after the intended failure.
Those control assertions were corrected before the decisive red run. The
ignored-event assertions and the original reported test were not relaxed.
Afterward the throttle fixture was made independent of a short timer window:
it queues with a long interval and explicitly performs the already-queued
work item. The final mutation check exercises that exact callback path.

### Stress-fixture ordering diagnosed

The first repeated run (`r15-stress.log`) completed 30/30 throttle cases and
30/30 automatic-refresh cases, then exposed a setup race in the new reader
probe: **3 failures in 24 completed reader repetitions**. It was interrupted
after those failures (exit 75), before the original filesystem test ran.
The failure was `Never deliver the batch during the reader's refresh`,
followed by a 2-versus-0 counter assertion.

The probe wrote the ignored file before calling `startRefresh()`. A real file
event could already be queued on the main actor, and could replace the reader
task before that task entered `refresh()` and incremented `readerRefreshes`.
The probe then held an **automatic** status snapshot while waiting for the
reader's `missedChange` queue. That queue was the wrong one for the held read.

`r15-reader-order-probe.log` confirms this deterministically. A temporary
bridge delivery immediately before `startRefresh()` reproduced the phase
mismatch **10/10 times**, with this diagnostic at the held snapshot:

```text
R15 reader setup: loading=false automatic=true automaticDelta=2 reads=1
The held snapshot belongs to an automatic refresh; the reader task was displaced before entering
```

The final fixture starts and holds the reader first, verifies the kind of
refresh held, and only then creates the ignored file and delivers the event.
It still pauses before the ignored-list read and tests the same deferred-event
condition. The product guards, original filesystem test and timeouts are
unchanged by this fixture correction. Both filtering mutations are rerun
against the final fixture.

Nearby observation, outside the assigned in-flight ignored-event race:
`GitController.swift:360` (`startRefresh`) schedules a reader task before that
task establishes its priority; `GitController.swift:508` can cancel it when an
already-queued watch callback starts an automatic task. The diagnostic proves
that pre-entry ordering, not a visible-UX consequence. It remains unchanged
here; the fixture now establishes the in-flight reader state it intends to test.

### Fix and nearby sweep

`GitWatchChanges` retains the accepted paths through the watcher throttle and
both controller queues. Delivery checks those paths against the latest
`GitIgnoredPaths` before scheduling another read. Empty/all-ignored batches
stop there; a batch with any unignored path still refreshes. In-flight reads
finish rather than being cancelled by incoming events.

The sweep covered all three deferral sites, generation replacement, stream
stop/root movement, linked-worktree metadata and the `GitStateWatch` adapter.
The reader/busy-action queue was a second instance of the same lost-path bug
and is fixed with the same representation. Root changes remain unconditional.
The adapter's public no-argument callback and its state-only filtering remain
unchanged.

Each pending set retains at most 4,096 paths. If it overflows, or the cause is
otherwise unknown, it conservatively retains the old unconditional-refresh
behavior. This bounds memory during a stalled read without losing real
changes. `testQueuedPathsStayBoundedWithoutHidingUncertainChanges` covers
both accumulation and a single oversized batch, empty batches and root moves.
This bound may permit an extra refresh for an exceptionally large unknown
batch; it never suppresses a change that the old implementation reported.

### Validation

Evidence root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
Every command uses this worktree and build root, with generated `HOME`,
`CFFIXED_USER_HOME` and `CODEX_HOME`. The native host verifies its fixture
identity and data home. No installed app, real user data or paid/live service
was used.

After the fix the six focused probes passed (`r15-green-probes.log`).
Mutation checks (`r15-mutation-*.log`, `r15-mutations.json`):

- Watcher: replace the current-ignored-list check with a nonempty-batch check;
  the throttle regression fails with 2 callbacks instead of 1.
- Controller: make that same replacement; the automatic and reader-refresh
  regressions both fail again.
- Bound: increase the limit so the test's overflow fits; the bounded-memory
  and conservative-refresh assertions fail.

Full affected native classes, each alone with parallel testing disabled:

| Class | Passed | Failed |
| --- | ---: | ---: |
| `GitWorkingTreeWatcherTests` | 22 | 0 |
| `GitPathBoundaryTests` | 5 | 0 |
| `GitRepositorySwitchTests` | 17 | 0 |
| `GitPanelShownTests` | 13 | 0 |
| `GitBranchesInteractionTests` | 20 | 0 |
| `ChangesTabFrameTests` | 8 | 0 |
| `ChangesTabTests` | 9 | 0 |
| `GitPanelTimingTests` | 4 | 0 |
| `GitIntegratedHistoryTests` | 10 | 0 |
| `FileBlameTests` | 10 | 0 |
| **Total** | **118** | **0** |

The package `GitViewTests` suite passed **173/173**, zero failures
(`r15-gitview-package.log`). It includes the public `GitStateWatch` adapter,
repository-state, history/reveal, Git operation and safety coverage.
No focused native or package tests were skipped.

The final timer-independent watcher mutation fails **1/1** at 2 callbacks
versus 1 (`r15-mutation-watcher-filter-final.log`); restoring the guard passes
**1/1** (`r15-green-callback-final.log`). With the corrected reader setup, the
controller mutation fails **2/2**, at 2 versus 1 and 1 versus 0 respectively
(`r15-mutation-controller-filter-final.log`). These are the intended count
assertions, not setup/phase failures. After restoring the guard, the full
watcher class again passes **22/22** (`r15-final-GitWorkingTreeWatcherTests.log`);
the table above uses that final result.

Final stress (`r15-stress-final.log`, `r15-final-native-results.json`):
**120 passed, 0 failed, 0 skipped**, in 487.44 seconds of test time.
Each method ran 30 times with retries disabled and the shared lock held:

| Repeated method | Passed | Failed |
| --- | ---: | ---: |
| `testWritesIntoAnIgnoredFolderCauseNoRefresh` (original, unchanged) | 30 | 0 |
| `testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores` | 30 | 0 |
| `testIgnoredEventsDuringAnAutomaticRefreshAreRechecked` | 30 | 0 |
| `testIgnoredEventsDuringAReaderRefreshAreRechecked` | 30 | 0 |

The observed post-fix failure rate is **0/30** for the original real-FSEvents
test, and **0/90** for the deterministic deferral probes. The interrupted
earlier fixture run and its 10/10 diagnostic are accounted for above, not
counted as successful validation.

The focused native commands are the following loop (each class launches alone):

```sh
for cls in GitWorkingTreeWatcherTests GitPathBoundaryTests GitRepositorySwitchTests \
  GitPanelShownTests GitBranchesInteractionTests ChangesTabFrameTests ChangesTabTests \
  GitPanelTimingTests GitIntegratedHistoryTests FileBlameTests; do
  PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
    scripts/test-macos.sh -parallel-testing-enabled NO \
    "-only-testing:PiAppTests/$cls" || exit
done
```

The decisive red run selects the five methods listed above. The initial green
probe run also selects the bounded-queue test. Offscreen deterministic probes
ran as focused selections of this one class; full native classes and the
repeated run hold the shared full-lane lock, one class at a time.
The recorded driver invocation was:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r15-validation-driver \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r15-validate.py
```

That wrapper creates the generated homes; `r15-validate.py` runs the package
command and takes/releases the shared lock around `r15-native.py`. The latter
records every command, result and count in `r15-native-results.json`.
The final mutations, corrected watcher class and repeated run use:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r15-final-validation-driver \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r15-locked.py \
  r15-final-validation-locked \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r15-final-validation.py
```

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/views-verify \
  --filter GitViewTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 30 \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testWritesIntoAnIgnoredFolderCauseNoRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderRefreshAreRechecked
```

### Adversarial review

Reviewed every changed condition against its previous behavior:

- Bridge eligibility is unchanged: the same Git-state and ignored-path
  predicates now retain the accepted paths instead of only an `any` result.
  A root-change flag still bypasses path filtering and stops the old stream.
- A queued callback or refresh now stops only for an empty batch or one whose
  paths are all covered by the current ignored list. Mixed batches retain a
  follow-up; both tracked-file controls check the resulting status. If an
  ignored-list read fails, the last known list remains in use.
- Busy actions and reader refreshes keep priority over watcher refreshes.
  Events accumulate instead of replacing one another. Draining the reader
  queue clears it before rechecking, avoiding recursive reuse. A public
  automatic read blocked before entering still requests an unconditional
  retry, preserving the existing conservative behavior when no paths are
  available at that entry point.
- Completing an automatic refresh drains its own pending batch only if its
  token is still current and its task is not cancelled. Start, stop and quiet
  refresh retain their previous replacement/reset behavior. The stream's
  generation and running checks still reject stale bridge deliveries.
- An immediately due callback cancels the obsolete trailing work item before
  draining the same pending set. Discarding an all-ignored batch does not move
  the last-delivery timestamp, so it cannot delay the next real change.
- Empty batches do nothing; root moves and overflow remain unconditional.
  The 4,096-path bound affects storage, not whether uncertain work is kept.
  The ignored-path matcher and linked-worktree/state-only rules are unchanged.
- New observation seams are instance-owned. The throttle fixture performs
  the actual queued work item and cancels its timer afterward; it does not
  race a half-second deadline. The held-read fixture releases its continuation
  on failure and stops its controller before deleting the generated repository.
  Its phase guard fails immediately if the wrong kind of read is held. Moving
  file creation after the reader enters changes only the probe's setup; the
  automatic-refresh probe still begins with the directory creation.

No helper/wire behavior or rendering changed, so helper/wire suites and gallery
regeneration are outside this round's affected scope. No source files were
added or removed. The separate pre-entry scheduling observation is recorded
above rather than broadening this fix.

`git diff --check` passes. All mutations are restored. The owned shared lock
was released on the interrupted run, the diagnostic run and the successful
final run. Generated homes were removed by their wrappers. Automatic result
bundles were removed after retaining text/JSON evidence; no clone directories
remain in this workstream's native products. No extra DerivedData copy was
created.

## Round 16 — displayed Git paths survive newer ignores

Base: `a9f9f946`, on `dev/a130-gitfiles`; no merge, rebase or fast-forward.
The review finding is **confirmed and fixed**. A directory-only `cache/`
ignore does not hide an untracked regular file named `cache`. Replacing that
file with a directory between the status and ignored-list reads leaves a
displayed row from the older snapshot. Round 15's refiltering discarded the
replacement events against the newer ignored list, so no follow-up removed
the stale row.

`GitIgnoredPaths` now retains the current snapshot's paths and their parent
paths. An otherwise ignored event remains interesting when it equals, contains
or is contained by a displayed path. Both destination and original names of a
rename participate. Publication replaces this protection together with the
status snapshot; after the stale row disappears, writes under that ignored
directory become quiet again. The sets are indexed by path components, so
unrelated siblings and names such as `cache-other` do not get protection.

The nearby sweep covered all three consumers of the shared ignore predicate:
the background FSEvents bridge, `deliverPending`, and `workingTreeChanged`
(including its automatic and reader/busy queues). They all use the same
protection. A restarted watcher also seeds it from the matching published
snapshot before starting: an unchanged next read returns early from
`publishRepository`, so publication alone would miss this case. No other
production paths were changed.

### Failing-first and mutations

All fixtures use generated repositories and generated
`HOME`/`CFFIXED_USER_HOME`/`CODEX_HOME` under this workstream's build root.
Evidence is under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.

New tests in `GitWorkingTreeWatcherTests`:

- `testAnIgnoredReplacementOfADisplayedFileStillRefreshes`: hold the completed
  status read, replace `cache` with ignored `cache/first.o`, and deliver the
  replacement batch to the controller while that read is held.
- `testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes`: hold the
  same snapshot, but leave the replacement batch in the watcher until the
  first refresh has finished learning ignores.
- `testIgnoredFilteringPreservesBothRenamePathsAndTheirRelatives`: use a real
  staged rename, install a newer ignored list, and check equal, ancestor,
  descendant and trailing-slash event paths for both names. Repeat after
  restarting the watcher with the unchanged snapshot. Unrelated siblings
  and prefix collisions must remain ignored.

The first two assert exactly **one follow-up** (two automatic reads including
the initial read), disappearance of the stale row, and restored ignore
filtering afterward. Their instance-owned throttle interval is held at 3,600
seconds and the actual pending work item is manually delivered through the
round-15 seam. The shipping one-second default is unchanged. Continuations
are released on failure and controllers stop before their repositories are
removed; the tests do not depend on sleeping until a timer happens to fire.

Before the filtering fix, `r16-red.log` recorded **3/3 failed tests**, ten
assertion failures. Both replacement variants reported:

```text
XCTAssertEqual failed: ("1") is not equal to ("2") - The stale status needs exactly one follow-up
XCTAssertTrue failed - The untracked file was replaced by an ignored directory
```

The expanded rename test, still before the fix, failed **1/1** with sixteen
assertion failures (`r16-red-rename-restart.log`), including:

```text
XCTAssertFalse failed - A displayed rename still owns cache/item/child, restarted: true
```

After the fix, the three new tests and three existing deterministic ignored
batch tests passed **6/6**, zero failures or skips
(`r16-green-probes.log`).

The initial five mutations and the final seven separately rebuilt mutations
all failed at the intended assertions. Final evidence:
`r16-final-mutations.json`, `r16-final-mutations-driver.log` and
`r16-final-mutation-<name>.log`.

| Mutation | Expected failing test cases | Evidence |
| --- | ---: | --- |
| Remove snapshot protection at publication | 3 | Both replacement tests again see one read and a stale row; rename protection fails |
| Omit `originalPath` | 1 | Rename source, its parent and descendants are dropped |
| Omit the event-ancestor check | 1 | Events on `cache`, `cache/` and `renamed` are dropped |
| Stop walking event ancestors | 1 | `cache/item/child` and `renamed/item/child` are dropped |
| Omit watcher restart initialization | 1 | Protection fails only in the restarted-watcher half |
| Use Character separators when indexing shown parents | 1 | Four parent-path assertions fail for filenames beginning with combining marks |
| Use Character separators when walking event ancestors | 1 | Two descendant-path assertions fail for exactly ignored children beginning with combining marks |

All seven final invocations returned 65 with the named XCTest failures
(nine failed test cases total); none was a build failure. Every mutation was
restored before broader validation.

### Self-review follow-up — filesystem separators

Before committing, adversarial review found that the new ancestor traversal's
`String.lastIndex(of: "/")` searches Characters, not filesystem separators.
A slash followed by a leading combining mark forms one Character with it:
for `/repo/cache/item/\u{301}child`, that search finds the slash before `item`.
The generated Swift probe in `r16-unicode-path-probe.log` prints:

```text
Character parent: /repo/cache
UTF8 parent: /repo/cache/item
```

`testIgnoredFilteringUsesFilesystemSeparatorsBeforeCombiningCharacters`
checks parents of displayed filenames beginning with a combining mark, then
checks an exactly ignored child beginning with a combining mark under a
displayed filename. It covers both rename names and unrelated exact ignored
siblings. Before the correction it failed **1/1**, six assertions
(`r16-unicode-red-scoped.log`); after changing both separator searches to
UTF-8 slash bytes it passed **1/1** (`r16-unicode-green.log`). This keeps
String equality/canonical equivalence for the indexed paths.

The initial broad validation had already passed 173 package tests and 121
native tests. Its first stress run was intentionally interrupted with SIGINT
to our own `xcodebuild` after **20 passes, zero failed test cases** (exit 75,
`r16-stress.log`). The lock wrapper released its owned lock. That partial run
does not count as completed stress validation; final rebuilt validation uses
the `r16-final-*` logs.

Separate pre-existing observation, outside the displayed-snapshot fix:
`packages/bello-views/Sources/GitView/GitWatcher.swift:363` uses
`directory.hasPrefix` for ignored directories. With ignore `cache/`, an
otherwise ignored child `cache/\u{301}sibling` is not covered because the
trailing slash in the prefix is only part of a Character in the event path.
The initial Unicode probe's two unrelated-sibling assertions exposed this
(`r16-unicode-red.log`); `r16-unicode-prefix-probe.log` confirms that both
String prefix matching and Foundation's default anchored matching return
false. This matcher is unchanged from the base commit and may cause extra
refreshes for those ignored names; it does not suppress displayed-path events.
A fix must preserve canonical equivalence as well as filesystem boundaries,
rather than simply replacing the existing matcher with byte-prefix equality.
It is recorded for a separate follow-up. The final scoped regression uses
exact ignored files for its descendant checks to test the new traversal
independently of that older directory-prefix behavior.

### Adversarial review

Reviewed the complete new diff and each changed branch:

- Only paths already covered by the ignored list can take a different result.
  They now survive when related to a displayed row. Previously unignored paths,
  unrelated ignored siblings and component-prefix collisions keep their old
  result. The existing `/private` alias handling and path whitespace are
  unchanged.
- An event naming a parent of a displayed entry is found in `shownParents`.
  Equal and descendant events are checked by walking their path components
  against `shown`. Trailing directory slashes are normalized; empty original
  names are skipped. Both rename names are included. Stopping parent-set
  construction at an existing parent is safe because its ancestors were
  already inserted with the earlier entry. Both traversals locate the slash
  byte rather than a Character, so a leading combining mark cannot swallow
  a component boundary; ASCII traversal is identical.
- The protected sets replace the old sets, rather than accumulating. Publishing
  an empty status removes all protection. Construction is outside the lock;
  replacing both sets and checking them use the same lock as the ignore list,
  including background bridge calls. No per-event scan of all status entries
  is introduced.
- Publication uses its existing generation, cancellation, closed and suspended
  guards, and updates only a watcher for the matching resolved repository.
  Restart seeding requires the same published root and occurs before the stream
  starts. This preserves unchanged-snapshot optimization without carrying rows
  across repositories.
- Round 15's queue bounds, unknown/root-change handling, throttle defaults,
  reader/action priority and cancellation behavior are unchanged. New ignored
  directories absent from the status receive no protection. The original
  ignored-directory test and the three held-batch controls are retained.
- The only new scheduling seam is an internal, main-actor, per-watcher interval
  setter. No global fixture callback or shipping interval value changes.

No helper/wire behavior or UI rendering changed; helper/wire suites and
galleries are outside this round's affected scope. No source file was added
or removed. Round 15's separately recorded pre-entry reader scheduling
observation remains outside this fix.

### Validation commands and results

The initial and final rebuilt package `GitViewTests` suites each passed
**173/173**, zero failures or skips (`r16-gitview-package.log`,
`r16-final-gitview-package.log`).

All commands run from this worktree with a generated home via
`evidence/run-home-review.py`. The final driver runs the Unicode green test,
seven mutations and the package suite, then acquires the shared full-lane lock
for the native classes and stress run. Each native class runs alone with
parallel testing disabled. The driver invocation is:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r16-finish-driver \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r16-finish.py
```

Its underlying commands are:

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/views-verify \
  --filter GitViewTests

for cls in GitWorkingTreeWatcherTests GitPathBoundaryTests GitRepositorySwitchTests \
  GitPanelShownTests GitBranchesInteractionTests ChangesTabFrameTests ChangesTabTests \
  GitPanelTimingTests GitIntegratedHistoryTests FileBlameTests; do
  PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
    scripts/test-macos.sh -parallel-testing-enabled NO \
    "-only-testing:PiAppTests/$cls" || exit
done

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 30 \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testWritesIntoAnIgnoredFolderCauseNoRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderRefreshAreRechecked
```

The red and publication-mutation runs use:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredFilteringPreservesBothRenamePathsAndTheirRelatives
```

The expanded rename red run and other four initial mutations select only
`testIgnoredFilteringPreservesBothRenamePathsAndTheirRelatives` with the same
command prefix. The six-test green probe adds the three deterministic
round-15 methods from the stress command. These focused methods do not open
windows or change app focus. The Unicode red/green runs and its two additional
mutations select
`testIgnoredFilteringUsesFilesystemSeparatorsBeforeCombiningCharacters`
with the same command prefix. The final mutation driver reruns the original
five mutations and separately reverts each UTF-8 separator search:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r16-final-mutations-driver \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r16-final-mutations.py
```

Final rebuilt native results, each class alone under the shared lock:

| Class | Passed | Failed |
| --- | ---: | ---: |
| `GitWorkingTreeWatcherTests` | 26 | 0 |
| `GitPathBoundaryTests` | 5 | 0 |
| `GitRepositorySwitchTests` | 17 | 0 |
| `GitPanelShownTests` | 13 | 0 |
| `GitBranchesInteractionTests` | 20 | 0 |
| `ChangesTabFrameTests` | 8 | 0 |
| `ChangesTabTests` | 9 | 0 |
| `GitPanelTimingTests` | 4 | 0 |
| `GitIntegratedHistoryTests` | 10 | 0 |
| `FileBlameTests` | 10 | 0 |
| **Total** | **122** | **0** |

No native case was skipped. Evidence: `r16-final-green-<Class>.log` and
`r16-final-native-results.json`.

The final stress run completed **180/180**, zero failures or skips, under
the same owned lock (`r16-final-stress.log`):

| Method | Passed repetitions | Failed |
| --- | ---: | ---: |
| `testAnIgnoredReplacementOfADisplayedFileStillRefreshes` | 30 | 0 |
| `testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes` | 30 | 0 |
| `testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores` | 30 | 0 |
| `testIgnoredEventsDuringAnAutomaticRefreshAreRechecked` | 30 | 0 |
| `testIgnoredEventsDuringAReaderRefreshAreRechecked` | 30 | 0 |
| `testWritesIntoAnIgnoredFolderCauseNoRefresh` | 30 | 0 |

The original real-FSEvents test's observed failure rate is **0/30**; both
stale-snapshot regressions together are **0/60**. This preserves the original
new-ignored-directory limit while requiring exactly one follow-up to remove
the stale displayed file.

Final driver exit: 0. `git diff --check` passes, every mutation is restored,
and the owned shared lock was released. The wrappers removed their generated
homes and automatic result bundles after retaining text/JSON evidence.
No clone folders remain in this build root, and no extra DerivedData copy
was created. The separate Unicode ignore-prefix observation above is the
only newly recorded follow-up outside this fix.

## Round 17 — clean tracked-file replacement review

2026-10-21, branch `dev/a130-gitfiles`, base `9df33e88`.

**Disposition: rejected with evidence; no production change.** The reported
ordering was exercised against the existing code before changing any product
line. Both new native tests passed. The premise that `ignoredPaths` returns
`cache/` while the regular file `cache` remains in the index is false for the
command the app uses:

```sh
/usr/bin/git ls-files --others --ignored --exclude-standard --directory -z
```

With `/usr/bin/git` version `2.39.5 (Apple Git-154)`, replacing the clean,
committed regular file with `cache/first.o` gives:

```text
status before replacement: no entries
ignored paths after replacement: []
status after replacement: cache, indexState ".", worktreeState "D"
```

The file remains indexed after it is removed from the working tree. Git's
`show_other_files` calls `index_name_is_other`, which strips a directory's
trailing slash and rejects an exact index match. Thus `cache/` is excluded
from this query's results even though the directory matches `.gitignore`.
This agrees with the fixture observations. Primary source:
[Git 2.39.5 ls-files.c](https://github.com/git/git/blob/v2.39.5/builtin/ls-files.c#L145-L155),
[index_name_is_other](https://github.com/git/git/blob/v2.39.5/read-cache.c#L3226-L3252).

There is consequently no newly learned covering ignore to drop either queued
batch in the reported case. Adding a tracked-path query would add product work
without a reproduced defect. No per-refresh index scan, additional Git process,
or asynchronous product path was added.

### Attempted failing-first reproduction

Extended the existing held-status fixture, preserving its untracked-file
cases, with:

- `testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes`: the replacement
  batch reaches the controller while its automatic refresh is held.
- `testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes`: the batch
  stays in the watcher throttle until the held refresh finishes.

Each new case commits `cache`, verifies the initial status is empty, holds the
next completed status read, replaces the file with a directory, and queues a
child-only event (`cache/first.o`). It requires exactly one follow-up refresh
and a displayed tracked deletion. The helper now also verifies the actual
`GitService.ignoredPaths` result while status is held: `[]` for a tracked file,
`["cache/"]` for the existing untracked case. This checks the disputed premise
directly instead of injecting an ignored result Git does not produce.

Initial output, with unchanged product code (`r17-clean-replacement-red.log`;
the label names the attempted red run, not a failure):

```text
testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes passed (2.482 seconds).
testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes passed (2.491 seconds).
Executed 2 tests, with 0 failures
```

After adding the direct ignore-result assertions, the two new and two existing
replacement cases passed **4/4**, zero failures, before any mutation
(`r17-baseline-four.log`). No genuine failing-first product result was obtained;
the counterfactual mutation below is explicitly not represented as one.

### Nearby sweep

Generated repositories and generated home directories only. The seven-case
probe (`r17-git-matrix.json`) used the same real Git command:

| Variant | Tracked path removed | Ignored list after replacement |
| --- | --- | --- |
| Exact reported case, `cache/` rule | `cache` | empty |
| Nested tracked file under `cache/` | `cache/tracked` | empty |
| Nested directory-only rule | `cache/build` | empty |
| Wildcard `cache*` rule, force-added file | `cache` | empty |
| Ignored parent, force-added file | `parent/cache` | empty |
| Tracked symlink replaced by a directory | `cache` | empty |
| Tracked child removed, ignored sibling created | `cache/file` | `cache/first.o` only |

All seven initial statuses were clean; all seven final statuses showed the
tracked deletion. In the last case Git lists the untracked sibling, not the
directory containing the tracked deletion. No second production bug was found.
The earlier Unicode ignore-prefix observation remains outside this assignment.

Also inspected every `ignoredPaths`, `ignored.update`, `covers`, and queued
`isInteresting(ignoring:)` call in GitView. Production ignore publication has
one source, `GitService.ignoredPaths`; tests that manually seed `cache/` cannot
establish that Git returns it for an indexed `cache`.

### Mutation checks

All mutations are temporary, restored in `finally`, and absent from the final
diff. They check the sensitivity of the added regressions, not a claimed fix:

1. **Counterfactual ignored list:** make `ignoredPaths` return `["cache/"]`
   only after the fixture's `cache` becomes a directory. Both new tests fail,
   reproducing exactly the review's predicted stale status under that
   deliberately false result:

   ```text
   XCTAssertEqual failed: ("[\"cache/\"]") is not equal to ("[]")
   XCTAssertEqual failed: ("1") is not equal to ("2") - The stale status needs exactly one follow-up
   XCTAssertEqual failed: ("[]") is not equal to ("[\"cache\"]") - The tracked deletion must appear
   XCTAssertEqual failed: ("nil") is not equal to ("Optional(\"D\")")
   ```

   Evidence: `r17-mutation-counterfactual-ignore.log`, exit 65, two failed
   test cases / ten assertions.
2. **Drop the controller's nonempty pending batch:** the unthrottled new test
   fails its follow-up count and deletion assertions. Exit 65, one failed
   test case / three assertions (`r17-mutation-drop-controller-pending.log`).
3. **Drop subsequent throttle deliveries:** the throttled new test fails
   the same follow-up/deletion assertions. Exit 65, one failed test case /
   three assertions (`r17-mutation-drop-throttle-pending.log`).

All **3/3 mutations were caught**, with the exact selected test cases failing.
The production files match the base commit byte for byte after restoration
(`git diff --exit-code -- packages/bello-views/Sources/GitView/{GitService,GitController,GitWatcher}.swift`).

### Adversarial self-review

There are no changed production conditions. In the fixture:

- `committed == false` retains the existing untracked setup, parent-and-child
  event batch, one follow-up, empty final status and quiet ignored writes.
- `committed == true` adds a commit before controller construction, expects an
  initially empty status and a final tracked deletion, and deliberately delivers
  only a child event so ancestor handling is exercised.
- `throttled == false` still drains the actual throttle callback while status
  is held and asserts the controller retained it; `true` still waits for that
  read to finish before releasing the throttle.
- The added Git read is test-only, runs while the completed status snapshot is
  held, and asserts actual ignore semantics. It cannot change the index.
- Both fixture branches still clear the seam, resume any held continuation,
  stop the controller and remove the generated repository on every exit.

### Validation commands and evidence

Evidence directory:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence`.
All native invocations use the existing `run-home-review.py` wrapper to set
generated `HOME`, `CFFIXED_USER_HOME`, `CODEX_HOME` and this workstream's
`PI_BUILD_ROOT`. Native products use the isolated test host. The four focused
replacement methods do not open windows or change app focus. The full watcher
class and stress run hold the shared `full-lane.lock` as
`a130-gitfiles r17 pid=…`, released in `finally`.

The exact driver invocation, including baseline, mutations, lock acquisition,
class run and stress:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r17-finish \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r17-finish.py
```

Baseline and mutation commands use this prefix and select the methods named
above with `-only-testing:PiAppTests/GitWorkingTreeWatcherTests/<method>`:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO
```

Final class and stress commands:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 30 \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testWritesIntoAnIgnoredFolderCauseNoRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderRefreshAreRechecked
```

Only the watcher test class and documentation change. No helper, wire, layout
or UI drawing behavior changes, so helper/wire suites and galleries do not apply.

Final rebuilt `GitWorkingTreeWatcherTests`: **28 passed, 0 failed, 0 skipped**
(`r17-green-GitWorkingTreeWatcherTests.log`, exit 0).

Final stress: **240 passed, 0 failed, 0 skipped**, exit 0, 793.139 seconds of
test execution (`r17-stress.log`; counts recovered from the native driver's text
log into `r17-native-counts.json`, per-method counts in `r17-stress-counts.json`):

| Method | Passed repetitions | Failed |
| --- | ---: | ---: |
| `testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes` | 30 | 0 |
| `testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes` | 30 | 0 |
| `testAnIgnoredReplacementOfADisplayedFileStillRefreshes` | 30 | 0 |
| `testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes` | 30 | 0 |
| `testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores` | 30 | 0 |
| `testIgnoredEventsDuringAnAutomaticRefreshAreRechecked` | 30 | 0 |
| `testIgnoredEventsDuringAReaderRefreshAreRechecked` | 30 | 0 |
| `testWritesIntoAnIgnoredFolderCauseNoRefresh` | 30 | 0 |

The original real-FSEvents ignored-folder test's observed failure rate is
**0/30**, with its at-most-one-refresh assertion unchanged. The two new tracked
replacement tests have **0/60** stress failures on unchanged production code.
This is evidence for rejecting the review's specific trace, not a claim that
an unreproduced product bug was fixed.

Final driver exit 0; shared lock released. Generated homes, automatic result
bundles and clone directories are absent after cleanup; text/JSON evidence
remains in this workstream's build root. No extra DerivedData copy was created.
`git diff --check` passes, and the final product-file diff against `9df33e88` is
empty. No new unresolved issue or owner decision arose in this round.

## Round 18 — integrate floating-panel Git watchers

2026-10-21. Integrate `origin/dev/next` **f80e83cbb61866b6d222cc45e9b111aa96037d45**
into `dev/a130-gitfiles` at **537306ad30757bbf8d4dd860a1dae4759e92263b**
with an ordinary merge commit. The owner explicitly authorized this merge into
the workstream branch; `dev/next` is not merged into or pushed by this workstream.
No rebase, force-push, release, tag or history rewrite.

```sh
git fetch origin dev/next
git merge --no-ff --no-commit origin/dev/next
xcodegen generate --quiet
```

### Resolution and summary-only audit

The two conflicts were `GitWatcher.swift` and
`GitWorkingTreeWatcherTests.swift`. Kept both branches' tests and behaviors:

- `GitStateWatch(root:discoveringRepository:onChange:)` keeps the public void
  callback, forwarding through the internal `GitWatchChanges` callback.
- Discovery retains the panel's `.git` marker recognition and watches only the
  project root. It does not resolve the marker's external Git directory or
  `commondir` before Git verifies the repository.
- Accepted discovery batches bypass cached working-tree ignores and become
  `.unknown` (unconditional). They therefore survive both the initial filter
  and the later throttle recheck. Ordinary-file/object-store filtering, stream
  generations, stop behavior and root-move handling remain intact.
- Ordinary repository watchers retain their bounded path batches, throttle,
  automatic/reader refresh queues, new-ignore recheck, and displayed-path
  protection, including both rename names and filesystem ancestors.

`GitController.swift` auto-merged. Its `summaryOnly` branch runs **after**
`publishRepository(top, status:…, generation:…)`. That common publisher calls
`watcher.ignored.preserve(root:entries:)` before assigning a changed snapshot.
The summary branch then reads counts and updates ignores. An unchanged snapshot
keeps the existing protection; a replacement watcher is seeded from the current
snapshot by `updateWatch` before reading status. Thus an additional summary-only
`preserve` call would duplicate the common path and is not needed.

The summary branch's early return still unwinds the outer automatic-refresh task,
which rechecks its pending batch, or the reader-refresh defer, which drains
missed events. Root/generation/cancellation guards still precede ignore
publication. The integration does not change counts, patches, history selection,
or panel layout. Other incoming files are retained from `f80e83cb`, including its
already reviewed helper changes; the conflict resolution adds no helper or wire
behavior changes.

### Failing first and mutation checks

First combined the declarations/callback signatures and retained ordinary path
filtering, before making discovery unconditional. Added two deterministic bridge
tests and four summary-mode variants of the existing held-status fixtures:

| Test | Purpose |
| --- | --- |
| `testDiscoveryEventsBypassCachedIgnores` | `.git` discovery survives an already cached covering ignore |
| `testThrottledDiscoveryEventsSurviveNewIgnores` | queued discovery survives ignores learned after acceptance |
| `testASummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile` | summary automatic queue reconciles a displayed file replaced by an ignored directory |
| `testAThrottledSummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile` | same replacement retained in the watcher throttle |
| `testIgnoredEventsDuringAnAutomaticSummaryRefreshAreRechecked` | summary automatic queue drops a genuinely ignored batch after its read |
| `testIgnoredEventsDuringAReaderSummaryRefreshAreRechecked` | same guarantee after an explicit summary read |

The initial native run had **4 passing / 2 failing tests**, with four failed
assertions and exit 65 (`r18-discovery-red.log`):

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r18-discovery-red scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testDiscoveryEventsBypassCachedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testThrottledDiscoveryEventsSurviveNewIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testASummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledSummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticSummaryRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderSummaryRefreshAreRechecked
```

```text
testDiscoveryEventsBypassCachedIgnores:
  Never deliver discovery regardless of a cached ignore
  XCTAssertTrue failed - Discovery is unconditional
testThrottledDiscoveryEventsSurviveNewIgnores:
  XCTAssertEqual failed: ("1") is not equal to ("2") - A newly learned ignore must not discard discovery
  XCTAssertTrue failed - Discovery batches stay unconditional
```

All four summary-mode variants passed before the discovery correction. This
confirms that the common `preserve` call already reaches the summary path;
there is no claimed summary-only failing-first fix. After correcting discovery,
these six tests plus the panel's existing
`testDiscoveryWatchUsesOnlyTheProjectAndNoticesTheGitMarker` passed **7/7**
(`r18-merged-green.log`).

Mutation driver: `r18-mutations.py`; each edit is restored in `finally`:

- Restore ignore filtering at discovery acceptance:
  `testDiscoveryEventsBypassCachedIgnores` fails (exit 65).
- Queue discovery as ordinary paths:
  `testThrottledDiscoveryEventsSurviveNewIgnores` fails (exit 65).
- Remove `.git` marker recognition:
  `testDiscoveryWatchUsesOnlyTheProjectAndNoticesTheGitMarker` fails (exit 65).
- Suppress the common publisher's `preserve` call only for `summaryOnly`:
  both summary replacement tests fail, seeing one automatic refresh instead
  of two and retaining the stale displayed file (exit 65, four assertions).
- Remove the controller's whole queued-change filter, including its empty-batch
  guard: both summary ignored-event tests fail (exit 65), detecting extra
  refreshes instead of the expected one automatic refresh or no reader follow-up.
  This deliberately broader mutation also permits repeated empty follow-ups;
  it is not represented as an isolated mutation of the ignore subcondition.

All five mutations were caught. Restored the unmutated sources before the full
package, native-class and stress validation.

### Adversarial merge review

Checked each resolution condition and which states cross it:

- `discoveringRepository || !ignored.covers(path)` changes acceptance only for
  discovery events that match the existing interesting-path predicate and would
  otherwise be suppressed by a cached ignore. Working-tree paths are unchanged.
  `.git/objects` and ordinary files remain excluded in the public state watcher.
- Only a nonempty accepted discovery batch becomes unconditional. An irrelevant
  batch still returns before dispatch; a root-move flag still stops the stream
  and emits its existing unconditional callback.
- Only discovery skips external metadata resolution, exactly as on the panel
  branch. Normal linked-worktree HEAD/index/refs watching remains unchanged.
- The added initializer parameter defaults to false; existing consumers retain
  their prior behavior. The public void callback still runs on the main actor.
- No condition in the summary publisher was changed. Its initial/unchanged
  status, count read, ignore update, pending automatic work and deferred reader
  work are exercised by the new tests. Existing repository-switch, hidden-panel
  and blame tests cover lifecycle behavior.
- New fixture parameters default to false. Existing full-panel tests keep their
  old setup and assertions; summary variants use the same held read and actual
  queued callback, not sleeps estimating read completion.

### Validation commands

Build root:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles`.
Text/JSON evidence is under its `evidence/` directory. Runs use generated homes,
the isolated native test host, generated repositories and this workstream's
existing build products. No installed app, real user data/preferences/credentials,
Keychain, live provider or paid call is used.

Exact final driver:

```sh
python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/run-home-review.py \
  r18-finish \
  python3 /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/evidence/r18-finish.py
```

The seven-test green run and individual mutations use:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/<method>
```

The driver runs the complete views package, then acquires the shared lane lock
as `a130-gitfiles r18 pid=…` for the native classes and stress run. Each native
class runs alone, with parallel testing disabled:

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/views-verify

for cls in GitWorkingTreeWatcherTests SessionPanelTests SubagentPanelTests \
  GitPathBoundaryTests GitRepositorySwitchTests GitPanelShownTests \
  GitBranchesInteractionTests ChangesTabFrameTests ChangesTabTests \
  GitPanelTimingTests GitIntegratedHistoryTests FileBlameTests; do
  PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
    scripts/test-macos.sh -parallel-testing-enabled NO \
    "-only-testing:PiAppTests/$cls"
done

PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 30 \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testWritesIntoAnIgnoredFolderCauseNoRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testASummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledSummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticSummaryRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderSummaryRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testDiscoveryEventsBypassCachedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testThrottledDiscoveryEventsSurviveNewIgnores
```

### Validation results

Complete `bello-views` package (`r18-views.log`, exit 0):

| Target | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| FileViewTests | 100 | 0 | 0 |
| FileFinderTests | 38 | 0 | 3 |
| GitViewTests | 204 | 0 | 0 |
| **Total** | **342** | **0** | **3** |

The three skips are the existing opt-in `FileFinderPerformanceTests`, which
require `FINDER_PERF=1`; all ordinary tests ran. XCTest reported 574.538 seconds,
584.098 seconds including the incremental package build. The generated Xcode
project and imported `packages/swift-host` files match `f80e83cb` exactly.
The merged watcher class contains all 28 tests from the workstream parent,
all 17 from the incoming parent (most overlap), and the six added merge
regressions: 35 distinct methods, none dropped.

Focused native classes (`r18-green-<Class>.log`, each run alone with parallel
testing disabled and the shared lane lock held):

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| GitWorkingTreeWatcherTests | 35 | 0 | 0 |
| SessionPanelTests | 29 | 0 | 0 |
| SubagentPanelTests | 8 | 0 | 0 |
| GitPathBoundaryTests | 5 | 0 | 0 |
| GitRepositorySwitchTests | 17 | 0 | 0 |
| GitPanelShownTests | 13 | 0 | 0 |
| GitBranchesInteractionTests | 20 | 0 | 0 |
| ChangesTabFrameTests | 8 | 0 | 0 |
| ChangesTabTests | 9 | 0 | 0 |
| GitPanelTimingTests | 4 | 0 | 0 |
| GitIntegratedHistoryTests | 10 | 0 | 0 |
| FileBlameTests | 10 | 0 | 0 |
| **Total** | **168** | **0** | **0** |

All twelve invocations exited 0. Their combined elapsed time, including
incremental builds and test-host startup, was 560.34 seconds.

The locked stress run passed **420/420**, with **0 failures / 0 skips**:
each of the fourteen methods in the command above passed exactly thirty times
(`r18-stress.log`, per-method counts in `r18-stress-counts.json`). This includes
the eight round-17 scenarios, four summary-mode scenarios and two unconditional
discovery scenarios. The original real-FSEvents ignored-folder regression,
`testWritesIntoAnIgnoredFolderCauseNoRefresh`, retains its at-most-one-refresh
assertion and had an observed failure rate of **0/30**. The stress invocation
exited 0 in 1,023.50 seconds; XCTest reported 1,019.550 seconds.

The full native lock was held only for these class/stress runs, 1,583.871 seconds,
and released by the owning wrapper. Final driver exit 0. Generated homes,
automatic result bundles and clone directories are absent after cleanup;
text/JSON evidence remains under this workstream's build root. No extra
DerivedData copy was created.

Final review compared the resolved watcher against both parents, checked the
summary publisher and queue-drain conditions, verified all mutations were
restored, and found no dropped tests or conflict markers. `git diff --check`
and `git diff --cached --check` pass. No new unresolved issue or owner decision.


## Round 19 — ignore scan age and staged deletions

2026-10-21. Both review findings against `54d1df34` are **confirmed and fixed**.
Work stays on `dev/a130-gitfiles`; no merge, rebase, history rewrite or changes
to the helper/wire. The lead's explicit rule governs the tradeoff: a queued
batch may be discarded only if the ignore scan can vouch for it; otherwise a
follow-up refresh is retained.

### 1. Events newer than the ignore scan

Added an instance-scoped `ignoredDidRead` seam after the completed read and
before publication, alongside the existing held-status seam. Four generated-repo
tests create ignored `cache/`, hold the completed scan, replace it with a
non-ignored regular file `cache`, and deliver its event against the old cache:

- `testEventsAfterTheIgnoreScanStillRefresh`
- `testThrottledEventsAfterTheIgnoreScanStillRefresh`
- `testSummaryEventsAfterTheIgnoreScanStillRefresh`
- `testThrottledSummaryEventsAfterTheIgnoreScanStillRefresh`

Before the fix, all four fail: the controller does one refresh, the queued event
is discarded, and the displayed status remains empty. The throttle and controller
queue fail independently, in full and summary-only controllers. Excerpt from
`r19-red.log`:

```text
XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2") - The older scan cannot vouch for the newer event
XCTAssertEqual failed: ("[]") is not equal to ("["cache"]") - The replacement file must become visible
```

Fix: timestamp an accepted batch using monotonic uptime **at receipt, before
its main-actor hop**. A union keeps the maximum timestamp, even if an older
batch arrives later; empty batches do not change it. Each controller read records
a cutoff immediately before dispatching `ignoredPaths`, in both refresh paths.
This is a conservative lower bound on the actual scan start: delayed dispatch
can retain an extra batch, but cannot let a later event be suppressed.

The cutoff and ignored paths are published under the same lock. Both the
watcher's throttle recheck and the controller's automatic/reader recheck use
the batch's newest timestamp. A batch can be dropped only if **every** path is
covered and its newest event is **strictly older** than the cutoff. Equal times,
root moves, discovery and path-budget overflow retain the conservative refresh.
A missing or failed scan supplies no new authority to discard a batch. A
mixed-age batch is kept in its entirety.

`testQueuedRechecksUseTheNewestEventAndScanStart` covers equality, no snapshot,
newer/older/empty unions, a later covering scan, and a mixed covered/uncovered
batch. No full tracked-file enumeration or additional Git command was added.

### 2. Ignored working copies of staged deletions

Two generated-repo tests force-add and commit `run.log`, ignore `*.log`, then
`git rm --cached run.log`. They hold the initial staged-deletion status before
the ignore scan and queue a log write during that read:

- `testIgnoredWritesAfterAStagedDeletionStayQuiet`
- `testSummaryIgnoredWritesAfterAStagedDeletionStayQuiet`

Both fail before the fix. The published status is `D.` but the ignored log
remains protected, so the queued write causes an unnecessary follow-up (one
in the full controller and two in the summary repeat, including a live batch):

```text
XCTAssertTrue failed - The ignored working copy cannot change the staged-deletion row
XCTAssertEqual failed: ("1") is not equal to ("0") - A reconciled staged deletion must not keep refreshing for ignored writes
```

Fix: omit only non-untracked `D.` entries from displayed-path preservation.
The row records an index removal, so an ignored working copy cannot change that
row. Suppression still requires coverage by the ignored snapshot; an uncovered
path or newer queued event still refreshes. The state-matrix test
`testIgnoredProtectionExcludesOnlyReconciledStagedDeletions` retains protection
for modified/added/renamed entries, worktree deletions, untracked entries, and
`DD`/`DU` conflicts. This is deliberately narrower than omitting all staged rows.

### Failing first, fixture ordering and mutations

The six new regression methods failed before either fix (**0 passed / 6 failed,
16 assertions, exit 65**). The initial locked run and a focused repeat both
caught all six; `r19-red.log` records the repeat. The focused methods do not
create windows or use focus. After the fixes, these six methods, both new
boundary/state tests, the four settled-ignore controller cases and two displayed
replacement cases passed **14/14** (`r19-green.log`, exit 0).

The held-read fixtures now take an isolated copy of the bridge callback and
silence delivery from the live stream. They still read actual Git repositories,
but the two synthetic batches are the complete input to the race. This removes
uncontrolled duplicate FSEvents batches from exact refresh-count assertions.
The copied callback retains the same weak owner and stream-generation checks;
production does not call `isolatedCopy`.

The round-15 deterministic assertions are **not weakened**: an automatic scan
whose ignored-folder batches are settled before its start still costs exactly
one refresh; an explicit reader scan needs no automatic follow-up. The same
assertions apply to summary-only readers and the throttle case. Displayed-path
replacement tests still require exactly one follow-up, and tracked/unignored
changes still refresh.

The separate real-FSEvents `testWritesIntoAnIgnoredFolderCauseNoRefresh` now
waits for the new folder to be learned and accepted batches to drain instead of
assuming a two-second sleep proves they preceded the scan. Its new-folder count
may include conservative follow-ups for late batches, as the lead explicitly
requires. The test still proves the watcher learns the folder, then checks that
ongoing ignored writes cause **zero** further refreshes and an unignored change
still appears. Exact at-most-one coverage stays in the deterministic fixtures.
This expectation change is intentional; retaining the old unconditional bound
would conflict with the new safety rule when FSEvents delivers a later batch.

Five mutations, each restored in `finally`, were caught:

| Mutation | Failing tests | Result |
| --- | --- | --- |
| Remove the event-age guard | Four newer-event cases + timestamp boundary test | 5 failures, exit 65 |
| Timestamp publication instead of scan dispatch, in both controllers | Four newer-event cases | 4 failures, exit 65 |
| Replace max timestamp with the last merged batch's timestamp | Timestamp union/boundary test | 1 failure, exit 65 |
| Preserve `D.` rows again | Both staged-deletion cases + state matrix | 3 failures, exit 65 |
| Skip both ignore rechecks, retaining only the empty-batch guard | Four settled-ignore controller cases + throttle case | 5 failures, exit 65 |

The fifth mutation verifies that the deterministic round-15 tests still reject
unnecessary follow-ups for settled pre-scan events. It ran under the full-lane
lock and caught all five cases in 24.40 seconds. Retaining the empty-batch guard
avoids introducing an unrelated infinite refresh loop.

Evidence: `r19-mutation-*.log`, `r19-mutation-counts.json`, and
`r19-settled-mutation-counts.json`. The unmutated sources are restored before
each complete package/native/stress run.

### Sweep and adversarial review

- Checked every ignore publication: full and summary-only refreshes both capture
  the cutoff before dispatch, and retain their cancellation/generation/root
  guards after the held-read seam. A failed read does not publish a newer cutoff.
- Checked every queue: watcher throttle, automatic pending batch and reader/busy
  missed batch all retain their timestamp through unions and use the common
  recheck. Only newly provable batches cross from refresh to discard; newer and
  equal-time batches cross from discard to refresh, as intended.
- The index-state condition changes only `D.` preservation. It does not change
  rename-source/destination, ancestor/descendant, untracked or conflict handling.
  Uncovered paths and all other index/worktree state pairs stay conservative.
- No new global callback or clock was introduced. Test callbacks belong to the
  controller and are cleared on teardown, with held continuations resumed.
- Discovery, root moves, overflow, empty-batch handling and stream stop/generation
  guards remain intact. A mixed-age batch may cause an extra refresh; this is
  the owner-approved conservative tradeoff, not an attempt to infer event age.

Separate pre-existing observation, outside the two assigned queued-recheck cases:
`GitWatcher.swift:116`'s **initial acceptance filter** uses the already-published
ignore cache. If `cache/` has been learned and is then replaced by a regular file
`cache`, it can discard the event before any queued recheck sees it. A generated
Git probe (`r19-acceptance-sweep.json`) confirms old ignores `["cache/"]`, new
status `? cache`, and new ignores `[]`; the existing initial filter still uses
the old covering path. This predates the recheck changes and is recorded for a
separate fix under the scope rule. No claim is made that this round fixes all
staleness in the initial ignore cache.

### Validation commands

Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles`;
evidence under its `evidence/` directory. All runs use generated homes and
repositories, the isolated native test host, and the existing workstream build
products. No real preferences/chats/credentials/Keychain, installed app, live or
paid provider calls. No UI changed, so no gallery run is needed.

Exact drivers (run from the worktree):

```sh
BUILD_A130_GITFILES=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles
python3 "$BUILD_A130_GITFILES/evidence/run-home-review.py" r19-red \
  python3 "$BUILD_A130_GITFILES/evidence/r19-red.py"
python3 "$BUILD_A130_GITFILES/evidence/run-home-review.py" r19-green \
  python3 "$BUILD_A130_GITFILES/evidence/r19-green.py"
python3 "$BUILD_A130_GITFILES/evidence/run-home-review.py" r19-finish \
  python3 "$BUILD_A130_GITFILES/evidence/r19-finish.py"
```

The final driver runs the first four mutations, then:

```sh
swift test --package-path packages/bello-views \
  --scratch-path /Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles/views-verify
```

It acquires the shared full-lane lock as `a130-gitfiles r19 pid=…` for the fifth
mutation, native classes and stress, releasing only its own lock in `finally`.
Each native class runs alone:

```sh
for cls in GitWorkingTreeWatcherTests SessionPanelTests SubagentPanelTests \
  GitPathBoundaryTests GitRepositorySwitchTests GitPanelShownTests \
  GitBranchesInteractionTests ChangesTabFrameTests ChangesTabTests \
  GitPanelTimingTests GitIntegratedHistoryTests FileBlameTests; do
  PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
    scripts/test-macos.sh -parallel-testing-enabled NO \
    "-only-testing:PiAppTests/$cls"
done
```

Stress repeats the fourteen round-18 methods plus the six new regression
methods (twenty total), still inside the generated-home and lock wrappers:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-gitfiles \
  scripts/test-macos.sh -parallel-testing-enabled NO -test-iterations 30 \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testEventsAfterTheIgnoreScanStillRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testThrottledEventsAfterTheIgnoreScanStillRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testSummaryEventsAfterTheIgnoreScanStillRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testThrottledSummaryEventsAfterTheIgnoreScanStillRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredWritesAfterAStagedDeletionStayQuiet \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testSummaryIgnoredWritesAfterAStagedDeletionStayQuiet \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testWritesIntoAnIgnoredFolderCauseNoRefresh \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testASummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testAThrottledSummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAnAutomaticSummaryRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testIgnoredEventsDuringAReaderSummaryRefreshAreRechecked \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testDiscoveryEventsBypassCachedIgnores \
  -only-testing:PiAppTests/GitWorkingTreeWatcherTests/testThrottledDiscoveryEventsSurviveNewIgnores
```

Exact expanded argv and per-invocation results are also recorded by
`r19-native.py` in `r19-native-counts.json`.


### Validation results

Complete `bello-views` package (`r19-views.log`, exit 0):

| Target | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| FileViewTests | 100 | 0 | 0 |
| FileFinderTests | 38 | 0 | 3 |
| GitViewTests | 204 | 0 | 0 |
| **Total** | **342** | **0** | **3** |

The three skips are existing opt-in `FileFinderPerformanceTests` requiring
`FINDER_PERF=1`. XCTest reported 565.636 seconds; the package invocation,
including its incremental build, took 571.782 seconds.

Focused native classes, each alone with parallel testing disabled and the
full-lane lock held (`r19-green-<Class>.log`, every invocation exit 0):

| Class | Passed | Failed | Invocation seconds |
| --- | ---: | ---: | ---: |
| GitWorkingTreeWatcherTests | 43 | 0 | 103.14 |
| SessionPanelTests | 29 | 0 | 58.13 |
| SubagentPanelTests | 8 | 0 | 5.73 |
| GitPathBoundaryTests | 5 | 0 | 26.12 |
| GitRepositorySwitchTests | 17 | 0 | 102.23 |
| GitPanelShownTests | 13 | 0 | 33.92 |
| GitBranchesInteractionTests | 20 | 0 | 106.68 |
| ChangesTabFrameTests | 8 | 0 | 73.03 |
| ChangesTabTests | 9 | 0 | 15.36 |
| GitPanelTimingTests | 4 | 0 | 11.80 |
| GitIntegratedHistoryTests | 10 | 0 | 45.78 |
| FileBlameTests | 10 | 0 | 26.37 |
| **Total** | **176** | **0** | **608.29** |

No native skips or unrelated failures. Invocation times include each
incremental build and test-host startup.

Stress (`r19-stress.log`, exit 0): **600 passed / 0 failed / 0 skipped**, exactly
**20 methods × 30 repetitions**. All six new regressions passed 30/30, as did
the fourteen existing stress cases, including the real-FSEvents ignored-folder
test. The failure rate was **0/600** overall and **0/30** for that original
intermittent case. The invocation took 1,291.42 seconds (21.52 minutes).
`r19-stress-counts.json` records and verifies every method's 30 passes.

The locked fifth mutation, native classes and stress completed with exit 0 in
1,924.18 seconds; the lock was released in `finally`. Final cleanup verified no
automatic `.xcresult` bundle, clone directory or generated review home remains
in this build root. Text/JSON evidence is retained; no extra DerivedData copy
was created (`r19-final-checks.json`).

Final adversarial review re-read the complete production diff and the changed
test assertions. The new branches retain uncertain batches and exclude only
the reconciled `D.` state from displayed-path protection; empty batches and
all other protected states retain their intended behavior. All three source
hashes match the validated post-fix versions, so none of the five mutations
remains. `git diff --check` passes. Both assigned findings are resolved; the
separate initial acceptance-filter observation above remains recorded for
another workstream decision.
