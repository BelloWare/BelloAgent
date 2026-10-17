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
