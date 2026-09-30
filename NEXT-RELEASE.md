# Next release: 0.1.117

**All work for the next release goes on one branch: `dev/next`.** Other `dev/*` and `wip/*` branches are history; everything from them that belongs to 0.1.117 is merged here. `main` holds released versions only and is updated by the release process (docs/Release.md).

## How work flows
Current owner instruction (2026-10-01): keep new development commits local until release. The earlier Quick Open findings 1–4 were already pushed; preserve them. Code execution remains on the owner's Mac.

1. A coding agent works directly on `dev/next`: small commits, pushed as it goes. It may not be able to run code, so it says in each commit message what should be checked.
2. The owner then asks the agent on their Mac to pull and check. It runs `scripts/check-next.sh` (build), `scripts/check-next.sh test <Class> …` (named test classes), `scripts/check-next.sh helper` (helper and package suites, wire scripts) or `scripts/check-next.sh gate` (the full release gate), and reports or fixes what fails.
3. When everything below is done and the gate and an hour-long soak pass, `dev/next` is released.

## Rules for code on this branch
- Native only (AppKit/SwiftUI), the app's Pi components, no stock controls.
- The helper follows pi 0.85.1 exactly; wire format changes must be optional fields.
- Tests for every fix and feature; no timing waits that count polls (use `eventually` in PiAppTests/TestSeams.swift).
- Keep the `packages/bello-views` package (FileView, FileFinder, GitView) free of app types; macOS 13.
- Update this file's checklist when an item is done.

## State at 2026-10-01 (on this branch)
- Fork speed-up: a fork of a 300 MB chat is ready to type in about 0.3 s (was 10–37 s); history loads in the background. Done.
- File viewer: engine, tabs beside the chat and in their own windows, find and go to line, file links from tool rows. Done.
- Changes as a tab beside the chat or in its own window, replacing the sheet. Done.
- Quick Open (⌘P): merged from `wip/viewer-stop`, **unfinished** (see below).
- Changes narrow-pane layout: merged from `wip/git-stop`, **unfinished** (see below).
- The build and test target compile at this commit; the unfinished items' tests are not yet all passing.

## Left for 0.1.117
- [x] **Quick Open app side** — fix Codex's 8 findings, each with a test (Files/QuickOpen.swift, QuickOpenPanel.swift, Workspaces/WorkspaceQuickOpen.swift, Application/PiApp.swift, WindowPresentation.swift). Implementation complete; Mac build, QuickOpenTests, WindowPresentationTests, TabHostTests and gallery validation pending:
  1. [x] a symlink in a trusted project pointing into an untrusted one opens as trusted: open without `project:` so the resolved path decides;
  2. [x] Return before the new query's results opens the previous choice: keep a pending open until results for the current query arrive;
  3. [x] a file and its symlink alias share a row id: dedupe by id;
  4. [x] ⌘P in a pop-out tab window shows the list in the main window: use the window it was pressed in;
  5. [x] opening from a text field saves the field editor, not the field: save the delegate control and its selection;
  6. [x] the delayed focus task can steal focus later: tie it to a token bumped by each show/open;
  7. [x] a failed refresh still reads as ready: surface `finder.failure` and say the list is as last read;
  8. [x] a truncated listing says only "no match": say how many files were searched.
- [ ] **Changes narrow-pane layout** — GitPanelWidthTests: the list offset check is too strict (moves 12.5 pt as rows re-measure; compare the first visible row), and the Commit button isn't found in the accessibility tree (assert with the commit field instead). Then run ChangesTabFrameTests at 1280×820, 580×800 and 820×640, add a gallery scene for a narrow window, and review.
  - [x] Compare the first visible file row and assert the full commit field; add `10c-changes-window-narrow` in both gallery themes.
  - [ ] Mac validation: GitPanelWidthTests, ChangesTabFrameTests at all three sizes, and review the narrow-window gallery scene.
- [x] **Diff line → file**: a diff line's Pi context menu opens its current file in a tab at that line; split rows use the side under the pointer and empty sides have no action. Mac validation pending: GitDiffTableTests, ChangesTabTests and Changes gallery.
- [x] **Tab speed fix**: `TabContentHost.sizeThatFits` returns `proposal.replacingUnspecifiedDimensions()` (Tabs/TabWindows.swift); a SwiftUI layout probe covers full and partial proposals. Mac validation pending: TabHostTests, ChangesTabFrameTests and tab gallery.
- [x] **Links in reply text**: visible code-formatted paths resolve through a bounded actor cache and open existing files in trusted projects (at `:N`); clicks recheck trust, symlink targets respect the closest project, and plain prose has no marker. Mac validation pending: ReplyFileLinkTests, ChatFileLinkTests, TranscriptActionsForwardingTests and reply gallery.
- [x] **Syntax colours** in the viewer: SyntaxHighlighter exposes resumable comment/string/declaration states; a reader actor shares 128-line checkpoints, and the app supplies colour ranges only for drawn pieces. Mac validation pending: FileSyntaxTests, FileTextViewTests, FileTabTests and file-view gallery.
- [x] **Live follow and previews**: vnode watches follow writes, atomic replacements, deletion and recreation; a background replacement reading swaps into the kept text view with scroll/selection preserved. PDFKit keeps its PDF view and images decode to a maximum 2048-pixel thumbnail off the UI actor. Hidden/untrusted/closed tabs stop watching. Mac validation pending: FileTabTests, FileTextViewTests, FileFindTabTests and preview gallery.
- [x] **Non-blocking edit/versions** in the helper: `prepareEdit`, `edit(fromMessageID:)`, `messageVersions`, and `versionPage` await a shared off-actor replay/preparation, reusing a fork's existing load. Changed snapshots are rebuilt and edits recheck the journal after waiting. Mac validation pending: HistoryFillTests, HistoricalEditTests, MessageVersionTests, OlderRowsTests and the helper suite.
- [ ] Remove what's left of the old Changes sheet (comments, test names); `showGit`, `gitWorkspaceID`, `ChangesSheet` must be gone.

## Before release
- [ ] `scripts/check-next.sh gate` passes; an hour-long soak of a Release build passes.
- [ ] A Release build-for-testing with testability compiles `@testable import FileView` and `GitView`.
- [ ] Forks made by 0.1.116 and earlier open exactly as before.
- [ ] The owner turns VoiceOver on in the file viewer for a minute.
- [ ] Release notes name the fork behaviour changes (a fork opens partly loaded and fills in; an older app would show the parent's cost in new forks).

## Open decisions for the owner
- ⌘↩, ⌘. and ⌘F ignored while typing in a tab's text box (e.g. a commit message)?
- A separate icon for the Changes tab (it shares the side's branch icon)?
- Below 900 pt the Changes list stacks above the diff, and new pop-out windows open at 820 pt: widen them or lower the threshold?
- Sides: may Next/Previous Chat step onto a saved side; what happens to open sides when their chat is deleted or switched?
