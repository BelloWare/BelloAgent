import XCTest
import Combine
import SwiftUI
import FileView
@testable import GitView
@testable import PiApp

/// Blame in a file tab (`FileBlame`), against a real repository in a trusted
/// project: shown beside the numbers and in its bar; read again on a save, a
/// commit made elsewhere, and showing again; let go of when hidden or no
/// longer trusted; a click in its column selects nothing; and Show Change
/// opens the commit's own diff in Changes at the line, from where Back
/// returns to the file as it was.
final class FileBlameTests: XCTestCase {
    @MainActor private func model() async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("file-blame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key")]
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        addTeardownBlock { @MainActor in for window in model.tabs.windows { model.tabs.window(of: window)?.close() } }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "main", workspaceID: "w", title: "Main", path: nil, profileID: profile.id)
        let main = SessionDisplay(id: chat.id)
        main.messages = [TranscriptMessage(id: "u1", role: "user", text: "The chat")]
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main]
        return (model, root)
    }
    @MainActor private func window(_ model: WorkspaceModel) -> (NSWindow, WorkspaceRootView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = WorkspaceRootView(model: model)
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        hosted.layoutSubtreeIfNeeded()
        return (window, hosted)
    }
    @discardableResult
    private func git(_ arguments: [String], in root: URL, author: String = "Fixture") throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A repository: "alpha.txt" written by Ada, renamed to "file.txt" by
    /// Grace with two lines put above; then one line changed on disk.
    private func repository(_ root: URL) throws -> (first: String, second: String) {
        try git(["init", "-q", "-b", "main"], in: root)
        let letters = (0..<20).map { "greek letter number \($0)" }
        try (letters.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try git(["add", "alpha.txt"], in: root); try git(["commit", "-q", "-m", "Greek letters"], in: root, author: "Ada")
        let first = try git(["rev-parse", "HEAD"], in: root)
        try git(["mv", "alpha.txt", "file.txt"], in: root)
        try ((["inserted one", "inserted two"] + letters).joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: root); try git(["commit", "-q", "-m", "Rename and insert"], in: root, author: "Grace")
        let second = try git(["rev-parse", "HEAD"], in: root)
        return (first, second)
    }
    @MainActor private func blamed(_ model: WorkspaceModel, _ root: URL, window: NSWindow, hosted: NSView) async throws -> (FileTab, FileTextView) {
        let tab = model.openFile(root.appendingPathComponent("file.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown and read") { tab.focusView?.window === window && tab.status == .ready }
        tab.blame.toggle()
        try await eventually("blamed") { tab.blame.blame != nil }
        return (tab, try XCTUnwrap(tab.focusView as? FileTextView))
    }

    @MainActor func testBlameShowsEachLinesCommitAndFollowsCommitsAndSaves() async throws {
        let (model, root) = try await model()
        let (first, second) = try repository(root)
        let (window, hosted) = window(model)
        let (tab, text) = try await blamed(model, root, window: window, hosted: hosted)
        let scroll = try XCTUnwrap(text.enclosingScrollView as? FileTextScrollView)
        XCTAssertEqual(tab.blame.annotation(ofLine: 0)?.text, String(second.prefix(7)) + " Grace")
        XCTAssertEqual(tab.blame.annotation(ofLine: 3)?.text, String(first.prefix(7)) + " Ada")
        XCTAssertEqual(tab.blame.entry(ofLine: 3)?.line.path, "alpha.txt", "its name in that commit")
        XCTAssertEqual(tab.blame.entry(ofLine: 3)?.line.line, 2, "its line there")
        XCTAssertNil(tab.blame.annotation(ofLine: 22), "the empty line after the last newline is not Git's")
        XCTAssertNotNil(scroll.numbers.annotations, "the column is shown")

        // Keys move the selection; the bar follows.
        text.select(from: FileTextPosition(line: 3, column: 0), to: FileTextPosition(line: 3, column: 0))
        XCTAssertEqual(tab.blame.line, 3)

        // A save: read again, the new line not committed.
        let old = tab.document
        var lines = try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8).components(separatedBy: "\n")
        lines[5] = "changed on disk"
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await eventually("read again after the save") { tab.document !== old && tab.blame.blame != nil && tab.blame.entry(ofLine: 5)?.commit == nil }
        XCTAssertEqual(tab.blame.annotation(ofLine: 5)?.text, "Not committed")

        // Committed elsewhere, the file itself unchanged: read again.
        try git(["commit", "-q", "-am", "Change line six"], in: root, author: "Linus")
        try await eventually("the commit is seen") { tab.blame.entry(ofLine: 5)?.commit?.author == "Linus" }

        // Hidden: nothing read; shown again: read again.
        tab.didHide()
        try git(["commit", "-q", "--allow-empty", "-m", "Nothing"], in: root)
        tab.didShow()
        try await eventually("blamed again") { tab.blame.blame != nil }

        // No longer trusted: off, the column and what was read gone.
        let saved = FileTab.resolveProject
        defer { FileTab.resolveProject = saved }
        FileTab.resolveProject = { _ in .untrusted(name: "w") }
        tab.projectsChanged()
        XCTAssertFalse(tab.blame.isOn)
        XCTAssertNil(tab.blame.blame)
        XCTAssertNil(scroll.numbers.annotations)
    }

    /// A click in the annotation column opens the change and selects
    /// nothing; one on a number still selects its line.
    @MainActor func testAClickInTheColumnIsTheBlamesNotASelection() async throws {
        let (model, root) = try await model()
        _ = try repository(root)
        let (window, hosted) = window(model)
        let (tab, text) = try await blamed(model, root, window: window, hosted: hosted)
        let scroll = try XCTUnwrap(text.enclosingScrollView as? FileTextScrollView)
        var clicked: [Int] = []
        scroll.numbers.annotationClicked = { clicked.append($0) }
        text.select(from: FileTextPosition(line: 10, column: 2), to: FileTextPosition(line: 10, column: 2))
        hosted.layoutSubtreeIfNeeded()
        let y = scroll.numbers.convert(NSPoint(x: 0, y: text.convert(NSPoint(x: 0, y: 16 + 3.5 * 17), to: nil).y), from: nil).y
        let inColumn = scroll.numbers.convert(NSPoint(x: 20, y: y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: inColumn, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        scroll.numbers.mouseDown(with: event)
        XCTAssertEqual(clicked.count, 1, "the click is the blame's")
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 10, column: 2), "and selects nothing")
        _ = tab
    }

    /// Show Change: Changes opens on History at the commit that wrote the
    /// line, its file under the name it had then, the line selected in the
    /// commit's diff, unified and split; Back returns to the file tab with its
    /// find bar, query and selection as they were.
    @MainActor func testShowChangeOpensTheCommitAtTheLineAndBackReturns() async throws {
        let (model, root) = try await model()
        let (first, _) = try repository(root)
        let (window, hosted) = window(model)
        let (tab, text) = try await blamed(model, root, window: window, hosted: hosted)
        tab.openFind(); tab.findQuery = "letter"
        text.select(from: FileTextPosition(line: 3, column: 0), to: FileTextPosition(line: 3, column: 5))
        let selection = text.selectedRange
        tab.blame.openChange(ofLine: 3)
        let changes = try XCTUnwrap(model.tabs.tab(kind: ChangesTab.kind, key: "w") as? ChangesTab)
        let controller = changes.controller
        try await eventually("the change opened") { controller.selectedCommit?.hash == first && controller.detailFile == "alpha.txt" && !controller.commitLoading }
        XCTAssertEqual(controller.panel, .history)
        XCTAssertEqual(controller.revealTarget?.target.line, 2)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the line selected in the diff") {
            hosted.layoutSubtreeIfNeeded()
            return self.selectedDiffText(in: hosted) == "greek letter number 1"
        }
        XCTAssertNil(controller.revealNote)
        controller.presentation.split = true
        try await eventually("still the line, split") { hosted.layoutSubtreeIfNeeded(); return self.diffSplit(in: hosted) == true && self.selectedDiffText(in: hosted) == "greek letter number 1" }

        XCTAssertTrue(changes.canGoBack)
        changes.goBack()
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the file in front again") { tab.focusView?.window === window }
        XCTAssertEqual(tab.bar, .find); XCTAssertEqual(tab.findQuery, "letter")
        XCTAssertEqual(text.selectedRange.start, selection.start); XCTAssertEqual(text.selectedRange.end, selection.end)
        model.tabs.close(tab)
        XCTAssertFalse(changes.canGoBack, "a closed file is not offered to go back to")
    }

    /// A merge asked for at a line its diff against its first parent did not
    /// add: the panel says so rather than selecting a context line or
    /// showing the top as if it were the line.
    @MainActor func testALineAMergeBroughtInIsSaidNotFound() async throws {
        let (model, root) = try await model()
        try git(["init", "-q", "-b", "main"], in: root)
        try "base\n".write(to: root.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Base"], in: root)
        try git(["checkout", "-q", "-b", "side"], in: root)
        try "base\nfrom side\n".write(to: root.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Side"], in: root)
        try git(["checkout", "-q", "main"], in: root)
        try "other\n".write(to: root.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Main"], in: root)
        try git(["merge", "-q", "--no-ff", "-m", "Merge side", "side"], in: root)
        let merge = try git(["rev-parse", "HEAD"], in: root)
        let (_, hosted) = window(model)
        let changes = try XCTUnwrap(model.showChanges(in: "w"))
        hosted.layoutSubtreeIfNeeded()
        let controller = changes.controller
        try await eventually("read") { controller.statusRead && !controller.loading }
        let top = try XCTUnwrap(controller.repositoryRoot)
        // The merge commit asked for at a line its first-parent diff did not
        // add: "base" is only context there.
        let shown = await controller.revealHistory(GitHistoryTarget(commit: merge, path: "m.txt", line: 1), in: top)
        XCTAssertTrue(shown)
        try await eventually("said") { hosted.layoutSubtreeIfNeeded(); return controller.revealNote?.contains("first parent") == true }
    }

    /// A line a commit replaced: two rows unified (removed, added), one row
    /// split. The line stays the one selected across the switch, and back.
    @MainActor func testTheLineStaysSelectedAcrossUnifiedAndSplit() async throws {
        let (model, root) = try await model()
        try git(["init", "-q", "-b", "main"], in: root)
        try "one\ntwo\nthree\nfour\nfive\n".write(to: root.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Five"], in: root)
        try "one\nTWO\nthree\nFOUR\nfive\n".write(to: root.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Shout"], in: root)
        let commit = try git(["rev-parse", "HEAD"], in: root)
        let (_, hosted) = window(model)
        let changes = try XCTUnwrap(model.showChanges(in: "w"))
        hosted.layoutSubtreeIfNeeded()
        let controller = changes.controller
        try await eventually("read") { controller.statusRead && !controller.loading }
        let top = try XCTUnwrap(controller.repositoryRoot)
        _ = await controller.revealHistory(GitHistoryTarget(commit: commit, path: "r.txt", line: 4), in: top)
        try await eventually("FOUR selected") { hosted.layoutSubtreeIfNeeded(); return self.selectedDiffText(in: hosted) == "FOUR" }
        controller.presentation.split = true
        try await eventually("FOUR still, split") { hosted.layoutSubtreeIfNeeded(); return self.diffSplit(in: hosted) == true && self.selectedDiffText(in: hosted) == "FOUR" }
        controller.presentation.split = false
        try await eventually("FOUR still, unified") { hosted.layoutSubtreeIfNeeded(); return self.diffSplit(in: hosted) == false && self.selectedDiffText(in: hosted) == "FOUR" }
    }

    /// Whether the diff table on screen has laid its rows out side by side.
    @MainActor private func diffSplit(in view: NSView) -> Bool? {
        func tables(_ view: NSView) -> [GitDiffTableView] { ((view as? GitDiffTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables($0) } }
        return tables(view).compactMap { $0.coordinator?.split }.first
    }
    /// A reload drops what was said of the old text before the new answer:
    /// a line put above the rest never shows, or opens, the old first line's
    /// commit. Deleted and recreated, the file is blamed again.
    @MainActor func testAReloadForgetsTheOldTextsBlameAndARecreatedFileIsBlamedAgain() async throws {
        let (model, root) = try await model()
        _ = try repository(root)
        let (window, hosted) = window(model)
        let (tab, _) = try await blamed(model, root, window: window, hosted: hosted)
        var states: [Bool] = []
        let watching = tab.blame.$state.sink { states.append($0 == .reading) }
        defer { watching.cancel() }
        let url = root.appendingPathComponent("file.txt")
        let old = tab.document
        try ("put above\n" + (try String(contentsOf: url, encoding: .utf8))).write(to: url, atomically: true, encoding: .utf8)
        try await eventually("blamed again") { tab.document !== old && tab.blame.blame != nil && tab.blame.entry(ofLine: 0)?.commit == nil }
        XCTAssertTrue(states.contains(true), "nothing of the old text's blame shown meanwhile")
        // Written back by hand, not by git: the index and HEAD stay as they
        // are, so only the file's coming back can start the read.
        let saved = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try await eventually("missing") { tab.missingReason != nil }
        try saved.write(to: url)
        try await eventually("back, and blamed again") { tab.missingReason == nil && tab.blame.blame != nil && tab.blame.entry(ofLine: 1)?.commit != nil }
    }

    /// Not committed yet when blame is shown; committed elsewhere, the bytes
    /// the same: blamed then.
    @MainActor func testAFileCommittedAfterBlameIsShownIsBlamed() async throws {
        let (model, root) = try await model()
        _ = try repository(root)
        try "new\nfile\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let (window, hosted) = window(model)
        let tab = model.openFile(root.appendingPathComponent("new.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("read") { tab.focusView?.window === window && tab.status == .ready }
        tab.blame.show()
        try await eventually("said to have no history") { if case .unavailable = tab.blame.state { return true }; return false }
        try git(["add", "new.txt"], in: root); try git(["commit", "-q", "-m", "Add new"], in: root, author: "Ada")
        try await eventually("blamed once committed") { tab.blame.entry(ofLine: 0)?.commit?.author == "Ada" }
    }

    /// A target past the lines the diff parser reads: said so, not "not in
    /// this commit".
    @MainActor func testATargetPastTheReadLinesIsSaid() async throws {
        let (model, root) = try await model()
        try git(["init", "-q", "-b", "main"], in: root)
        try (0..<20_100).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Big"], in: root)
        let commit = try git(["rev-parse", "HEAD"], in: root)
        let (_, hosted) = window(model)
        let changes = try XCTUnwrap(model.showChanges(in: "w"))
        hosted.layoutSubtreeIfNeeded()
        let controller = changes.controller
        try await eventually("read") { controller.statusRead && !controller.loading }
        _ = await controller.revealHistory(GitHistoryTarget(commit: commit, path: "big.txt", line: 20_050), in: try XCTUnwrap(controller.repositoryRoot))
        try await eventually("said") { hosted.layoutSubtreeIfNeeded(); return controller.revealNote?.contains("past the part") == true }
    }

    /// Changes already open but hidden behind the file: Show Change brings
    /// it forward and lands; a blame changed before it lands drops it.
    @MainActor func testShowChangeReachesAHiddenChangesTabAndAChangedBlameDropsIt() async throws {
        let (model, root) = try await model()
        let (first, second) = try repository(root)
        let (window, hosted) = window(model)
        let changes = try XCTUnwrap(model.showChanges(in: "w"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("Changes shown") { changes.controller.isShown && !changes.controller.loading }
        let (tab, _) = try await blamed(model, root, window: window, hosted: hosted)
        try await eventually("Changes hidden behind the file") { hosted.layoutSubtreeIfNeeded(); return changes.controller.suspended }
        tab.blame.openChange(ofLine: 3)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("landed") { hosted.layoutSubtreeIfNeeded(); return changes.controller.selectedCommit?.hash == first }

        model.tabs.activate(tab)
        try await eventually("hidden again") { hosted.layoutSubtreeIfNeeded(); return changes.controller.suspended }
        try await eventually("blamed again, shown again") { tab.blame.blame != nil }
        tab.blame.openChange(ofLine: 0)
        tab.blame.hide()   // the blame it was asked from is gone
        // Long enough for it to land had it been let: Changes shown again
        // and read, the reveal's own wait for it over.
        let until = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < until { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(changes.controller.suspended, "Changes was brought forward")
        XCTAssertNotEqual(changes.controller.selectedCommit?.hash, second, "an ask whose blame is gone does not land")
    }

    /// The file replaced, or its tab closed, right after Show Change: the
    /// ask does not land, and a closed tab opens nothing to find out.
    @MainActor func testAReplacedOrClosedSourceDropsTheAsk() async throws {
        let (model, root) = try await model()
        let (first, _) = try repository(root)
        let (window, hosted) = window(model)
        let (tab, _) = try await blamed(model, root, window: window, hosted: hosted)
        let url = root.appendingPathComponent("file.txt")
        tab.blame.openChange(ofLine: 3)
        try ("replaced\n" + (try String(contentsOf: url, encoding: .utf8))).write(to: url, atomically: true, encoding: .utf8)
        let changes = try XCTUnwrap(model.tabs.tab(kind: ChangesTab.kind, key: "w") as? ChangesTab)
        var until = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < until { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(changes.controller.selectedCommit?.hash, first, "replaced: not landed")

        model.tabs.activate(tab)
        try await eventually("blamed again") { hosted.layoutSubtreeIfNeeded(); return tab.blame.blame != nil }
        tab.blame.openChange(ofLine: 4)
        model.tabs.close(tab)
        until = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < until { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(changes.controller.selectedCommit?.hash, first, "closed: not landed")
        XCTAssertFalse(tab.hasDocument, "and nothing reopened")
    }

    /// The text the diff table has selected, if any.
    @MainActor private func selectedDiffText(in view: NSView) -> String? {
        func tables(_ view: NSView) -> [GitDiffTableView] { ((view as? GitDiffTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables($0) } }
        return tables(view).compactMap { $0.coordinator?.selectedText }.first { !$0.isEmpty }
    }
}
