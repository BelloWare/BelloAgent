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
