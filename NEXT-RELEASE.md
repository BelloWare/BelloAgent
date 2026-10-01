# Next release: 0.1.117

**All work for the next release goes on one branch: `dev/next`.** Other `dev/*` and `wip/*` branches are history; everything from them that belongs to 0.1.117 is merged here. `main` holds released versions only and is updated by the release process (docs/Release.md).

## How work flows
Current owner instruction (2026-10-01): keep new development commits local until release. The earlier Quick Open findings 1–4 were already pushed; preserve them. The owner has delegated the remaining choices and authorized continuing through release. This workspace is on the owner's Mac with Xcode 16.1 and XcodeGen 2.44.1; native validation is now running here.

1. A coding agent works directly on `dev/next`: small local commits until release, with a final `Check:` paragraph in each commit message naming the tests and helper/gallery needs.
2. The owner's Mac checks these local commits with `PI_NEXT_REF=dev/next scripts/check-next.sh` (build), `PI_NEXT_REF=dev/next scripts/check-next.sh test <Class> …` (named test classes), `PI_NEXT_REF=dev/next scripts/check-next.sh helper` (helper and package suites, wire scripts) or `PI_NEXT_REF=dev/next scripts/check-next.sh gate` (the full release gate). The script fixes the chosen commit for the whole run in its separate check worktree. Without `PI_NEXT_REF`, it still fetches and checks `origin/dev/next`.
3. When everything below is done and the gate and an hour-long soak pass, `dev/next` is released.

## Rules for code on this branch
- Native only (AppKit/SwiftUI), the app's Pi components, no stock controls.
- The helper follows pi 0.85.1 exactly; wire format changes must be optional fields.
- Tests for every fix and feature; no timing waits that count polls (use `eventually` in PiAppTests/TestSeams.swift).
- Keep the `packages/bello-views` package (FileView, FileFinder, GitView) free of app types; macOS 13.
- Update this file's checklist when an item is done.

## Baseline at takeover (2026-10-01)
- Fork speed-up: a fork of a 300 MB chat is ready to type in about 0.3 s (was 10–37 s); history loads in the background. Done.
- File viewer: engine, tabs beside the chat and in their own windows, find and go to line, file links from tool rows. Done.
- Changes as a tab beside the chat or in its own window, replacing the sheet. Done.
- Quick Open (⌘P): merged from `wip/viewer-stop`, **unfinished** (see below).
- Changes narrow-pane layout: merged from `wip/git-stop`, **unfinished** (see below).
- The build and test target compile at this commit; the unfinished items' tests are not yet all passing.

The implementation work below is committed locally. The first focused helper run passed 47 tests (one skipped), including edit/history/versions and copied-fork compatibility. Native compilation exposed an ambiguous SwiftUI/FileView type and an unavailable preview palette name; both are corrected. Quick Open now uses an explicit nonisolated async refresh function to make the finder actor hops clear to the compiler. Native build/tests are being rerun. [Mac validation handoff](docs/Next-Release-Validation.md) lists the local-ref checks, gallery, Release testability, soak, and publication steps.

## Left for 0.1.117
- [x] **Quick Open app side** — fix Codex's 8 findings, each with a test (Files/QuickOpen.swift, QuickOpenPanel.swift, Workspaces/WorkspaceQuickOpen.swift, Application/PiApp.swift, WindowPresentation.swift). Implementation complete; Mac build, QuickOpenTests, WindowPresentationTests, TabHostTests and gallery validation pending:
  1. [x] a symlink in a trusted project pointing into an untrusted one opens as trusted: open without `project:` so the resolved path decides;
  2. [x] Return before the new query's results opens the previous choice: keep a pending open until results for the current query arrive;
  3. [x] a file and its symlink alias share a row id: dedupe by id;
  4. [x] ⌘P in a pop-out tab window shows the list in the main window: use the window it was pressed in;
  5. [x] opening from a text field saves the field editor, not the field: save the delegate control and its selection;
  6. [x] the delayed focus task can steal focus later: tie it to a token bumped by each show/open; wait for the active pane to become visible within the deadline. Setting its visible window's responder works before key-window activation and does not bring that window forward;
  7. [x] a failed refresh still reads as ready: surface `finder.failure` and say the list is as last read;
  8. [x] a truncated listing says only "no match": say how many files were searched. The file-limit fixture now uses flat files so the separate folder-queue bound does not end the walk first.
- [ ] **Changes narrow-pane layout** — GitPanelWidthTests: the list offset check is too strict (moves 12.5 pt as rows re-measure; compare the first visible row), and the Commit button isn't found in the accessibility tree (assert with the commit field instead). Then run ChangesTabFrameTests at 1280×820, 580×800 and 820×640, add a gallery scene for a narrow window, and review.
  - [x] Compare the first visible file row and assert the full commit field; add `10c-changes-window-narrow` in both gallery themes. Layout waits use `eventually` with measured geometry, without counting redraw polls. An optional test observer reads actual row geometry because SwiftUI's virtual rows are absent from this Mac's in-process accessibility tree. The observer is inactive in normal app views.
  - [ ] Mac validation: GitPanelWidthTests, ChangesTabFrameTests at all three sizes, and review the narrow-window gallery scene.
- [x] **Diff line → file**: a diff line's Pi context menu opens its current file in a tab at that line; split rows use the side under the pointer and empty sides have no action. Mac validation pending: GitDiffTableTests, ChangesTabTests and Changes gallery.
- [x] **Tab speed fix**: `TabContentHost.sizeThatFits` returns `proposal.replacingUnspecifiedDimensions()` (Tabs/TabWindows.swift); a SwiftUI layout probe covers full and partial proposals. Mac validation pending: TabHostTests, ChangesTabFrameTests and tab gallery.
- [x] **Links in reply text**: visible code-formatted paths resolve through a bounded actor cache and open existing files in trusted projects (at `:N`); clicks recheck trust, symlink targets respect the closest project, and plain prose has no marker. Opening explicitly runs on the UI actor; view equality tracks whether that action exists. Mac validation pending: ReplyFileLinkTests, ChatFileLinkTests, TranscriptActionsForwardingTests and reply gallery.
- [x] **Syntax colours** in the viewer: SyntaxHighlighter exposes resumable comment/string/declaration states; a reader actor shares 128-line checkpoints, and the app supplies colour ranges only for drawn pieces. Mac validation pending: FileSyntaxTests, FileTextViewTests, FileTabTests and file-view gallery.
- [x] **Live follow and previews**: vnode watches follow writes, atomic replacements, deletion and recreation; a background replacement reading swaps into the kept text view with scroll/selection preserved. PDFKit keeps its PDF view and images decode to a maximum 2048-pixel thumbnail off the UI actor. Replacement symlinks are refused so their target needs a fresh open and trust check. Hidden/untrusted/closed tabs stop watching. Mac validation pending: FileTabTests, FileDocumentTests, FileTextViewTests, FileFindTabTests and preview gallery.
- [x] **Non-blocking edit/versions** in the helper: `prepareEdit`, `edit(fromMessageID:)`, `messageVersions`, and `versionPage` await a shared off-actor replay/preparation, reusing a fork's existing load. Changed snapshots are rebuilt and edits recheck the journal after waiting. Mac validation pending: HistoryFillTests, HistoricalEditTests, MessageVersionTests, OlderRowsTests and the helper suite.
- [x] Remove what's left of the old Changes sheet from current code and tests: panel/tab comments and frame-test names now describe tabs; opening checks assert that the workspace has no attached sheet. `showGit`, `gitWorkspaceID`, and `ChangesSheet` are absent from current code. Historical release validation records keep their original test names. Mac validation pending: ChangesTabTests, ChangesTabFrameTests; helper and gallery not needed for this cleanup.

## Before release
- [x] Prepare `docs/Next-Release-Validation.md` with local-commit checks and the remaining release gates; execution and results are pending.
- [x] Gallery scenes cover PDF/image previews (`24f`, `24g`) and an actual reply path link (`24h`), including opening its file. Rendering and visual review pending on the Mac.
- [x] The Mac check script can check a local committed ref without fetching or publishing; CheckNextTests covers local/default ref selection and refusal of a dirty check worktree. Test execution pending.
- [x] Bring the published 0.1.116 metadata and validation record into `dev/next`; its build is 120. Prepare 0.1.117/build 121 and regenerate with XcodeGen 2.44.1. The public feed was checked before choosing build 121.
- [ ] `scripts/check-next.sh gate` passes; an hour-long soak of a Release build passes.
- [ ] A Release build-for-testing with testability compiles `@testable import FileView` and `GitView`.
- [ ] Forks made by 0.1.116 and earlier open exactly as before. ForkCloneTests now covers the published copied-journal format across open/reopen; Mac execution and a retained old-fork check remain pending.
- [ ] The owner turns VoiceOver on in the file viewer for a minute.
- [x] `releases/0.1.117.html` names the fork behaviour changes (a fork opens partly loaded and fills in; an older app can show the parent's cost in new forks), alongside the file and Changes features. Owner review pending before publication.

## Decisions delegated by the owner (2026-10-01)
- [x] Keep ⌘↩, ⌘. and chat ⌘F inactive while typing in editable tab text. Tab-specific shortcuts take precedence. ChangesTabTests covers send, search and stop in the commit field and the composer.
- [x] Owner delegated the choices on 2026-10-01: Changes uses the comparison arrows icon; new Changes windows open at 1040×720. Keep the 900 pt stacking threshold, ordinary file windows at 820×640 and restored window frames. TabHostTests and ChangesTabTests cover the choice; gallery validation pending.
- [x] Owner delegated the choice: Next/Previous Chat includes saved sides in sidebar order and focuses them beside their parent. Switching chats retains open sides and their work/drafts. Deleting a parent still requires closing its side first; saved children survive independently. SessionOrganizationTests covers navigation, retained work and the deletion guard.
