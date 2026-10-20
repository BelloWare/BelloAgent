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
