import XCTest
import SwiftUI
import FileView
@testable import PiApp

/// The pane beside the chat with tabs in it (`RightPane`), in the app's own
/// window: the chat's side stays mounted where it is while tabs come and go
/// over it, the report covers the tabs as it covers the chats, ⌘W closes the
/// tab shown and ⌥← and ⌥→ move through a file's words, and a tab moved
/// between the pane and a window keeps everything it had.
final class TabPaneTests: XCTestCase {
    @MainActor private func model() async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tab-pane-" + UUID().uuidString)
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
        let main = SessionDisplay(id: chat.id), side = SessionDisplay(id: "side")
        main.draft = "main draft"; side.draft = "side draft"
        main.messages = [TranscriptMessage(id: "u1", role: "user", text: "The chat")]
        side.messages = [TranscriptMessage(id: "u2", role: "user", text: "The side")]
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main, side.id: side]
        model.sides[chat.id] = SideRecord(id: side.id, parentID: chat.id, workspaceID: "w", profileID: profile.id, title: "Side")
        return (model, root)
    }
    @MainActor private func window(_ model: WorkspaceModel) -> (NSWindow, NSHostingView<WorkspaceView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.report.suspend(); window.contentView = nil; window.close() }
        hosted.layoutSubtreeIfNeeded()
        return (window, hosted)
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func file(_ root: URL, _ name: String, lines: Int = 400) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((0..<lines).map { "line \($0) with some words in it" }.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    /// The side stays mounted where it is while tabs come and go over it:
    /// the same composer and transcript throughout, hidden while covered,
    /// and its draft as it was.
    @MainActor func testTheSideStaysMountedWhileTabsComeAndGo() async throws {
        let (model, root) = try await model()
        let (_, hosted) = window(model)
        try await eventually("the side shown") { self.descendants(ComposerTextView.self, in: hosted).count == 2 }
        let side = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first { $0.sessionID == "side" })
        let tab = model.openFile(try file(root, "a.swift"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the side covered") { side.isHidden }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).contains { $0 === side }, "the same composer, still mounted")
        model.tabs.showSide()
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the side shown again") { !side.isHidden }
        model.tabs.activate(tab)
        model.tabs.close(tab)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the side shown once the tab closed") { !side.isHidden }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).contains { $0 === side }, "never mounted again")
        XCTAssertEqual(model.displays["side"]?.draft, "side draft")
    }

    /// The report covers the tabs as it covers the chats, and they are as
    /// they were when it goes.
    @MainActor func testTheReportCoversTheTabs() async throws {
        let (model, root) = try await model()
        let (_, hosted) = window(model)
        let tab = model.openFile(try file(root, "b.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the tab shown") { tab.hasContent && tab.contentView.window != nil }
        let container = try XCTUnwrap(descendants(TabContentContainer.self, in: hosted).first)
        model.openReport()
        try await eventually("covered by the report") { container.isHidden }
        // Something else changing under the report does not show it again.
        model.chats[0].title = "Renamed under the report"
        _ = model.openFile(try file(root, "b2.txt")); model.tabs.activate(tab)
        hosted.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(container.isHidden, "still covered")
        model.closeReport()
        try await eventually("shown again") { !container.isHidden }
        XCTAssertTrue(tab.contentView.superview === container)
    }

    /// ⌘W closes the tab the pane shows, and does nothing to the window;
    /// with the side shown instead it is not taken, and goes on to the menu.
    @MainActor func testCommandWClosesTheTabThePaneShows() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "c.txt"))
        hosted.layoutSubtreeIfNeeded()
        let commandW = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        let controller = try XCTUnwrap(descendants(WindowChromeView.self, in: hosted).first?.controller)
        XCTAssertTrue(controller.closeShownTab(commandW))
        XCTAssertTrue(model.tabs.pane.tabs.isEmpty)
        XCTAssertEqual(tab.hasContent, false, "closed, its content let go of")
        XCTAssertTrue(window.isVisible)
        _ = model.openFile(try file(root, "d.txt"))
        model.tabs.showSide()
        XCTAssertFalse(controller.closeShownTab(commandW), "the side is shown: not taken")
        model.page = .report
        _ = model.tabs.pane.tabs.first.map { model.tabs.activate($0) }
        XCTAssertFalse(controller.closeShownTab(commandW), "not over the report")
    }

    /// ⌥← and ⌥→ in a file's text move through its words; outside it they
    /// still step through a message's versions.
    @MainActor func testOptionArrowsInAFileAreTheFiles() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "e.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown") { tab.focusView?.window === window }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertTrue(WindowPresentationController.inTabContent(window.firstResponder))
        XCTAssertFalse(WindowPresentationController.inTabContent(descendants(ComposerTextView.self, in: hosted).first))
    }

    /// Opening, switching and closing tabs, and the side in their place,
    /// change nothing from inside a SwiftUI update.
    @MainActor func testTabsPublishNothingDuringAViewUpdate() async throws {
        let (model, root) = try await model()
        let (_, hosted) = window(model)
        let start = Date()
        let a = model.openFile(try file(root, "g.swift")), b = model.openFile(try file(root, "h.md"))
        for _ in 0..<3 {
            hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60))
            model.tabs.activate(a); hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60))
            model.tabs.showSide(); hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60))
            model.tabs.activate(b)
        }
        model.tabs.close(a); model.tabs.close(b)
        hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200))
        let issues = try SwiftUIRuntimeIssues.since(start)
        XCTAssertEqual(issues, [], "Side effects inside SwiftUI updates as tabs came and went")
    }

    /// A tab moved into the pane while the report is up, never shown in the
    /// pane before, is covered by it too.
    @MainActor func testATabMovedInUnderTheReportIsCovered() async throws {
        let (model, root) = try await model()
        let (_, hosted) = window(model)
        let first = model.openFile(try file(root, "i0.txt"))
        let popped = model.tabs.popOut(first)
        let tab = try XCTUnwrap(model.tabs.open(kind: FileTab.kind, key: FileTab.key(for: try file(root, "i.txt")), in: popped) {
            FileTab(url: root.appendingPathComponent("i.txt"), projectID: nil)
        } as? FileTab)
        model.tabs.window(of: popped)?.contentView?.layoutSubtreeIfNeeded()
        try await eventually("shown in its window") { tab.hasContent && tab.contentView.window != nil }
        model.openReport()
        hosted.layoutSubtreeIfNeeded()
        // The report has covered everything there was, and looked again.
        try await eventually("the chats covered") { self.descendants(ComposerTextView.self, in: hosted).allSatisfy(\.isHidden) }
        try await Task.sleep(for: .milliseconds(300))
        model.tabs.moveToPane(tab)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("its content under the report, hidden") {
            tab.contentView.window != nil && (tab.contentView.superview?.isHidden ?? false)
        }
        model.closeReport()
        try await eventually("shown once the report goes") { !(tab.contentView.superview?.isHidden ?? true) }
    }

    /// Focus moved to a file from the side stays wherever the reader puts it
    /// next: closing the file does not take it back to the side.
    @MainActor func testClosingATabDoesNotTakeFocusBackFromWhereTheReaderPutIt() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        try await eventually("both composers") { self.descendants(ComposerTextView.self, in: hosted).count == 2 }
        let composers = descendants(ComposerTextView.self, in: hosted)
        let side = try XCTUnwrap(composers.first { $0.sessionID == "side" }), main = try XCTUnwrap(composers.first { $0.sessionID == "main" })
        XCTAssertTrue(window.makeFirstResponder(side))
        let tab = model.openFile(try file(root, "j.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("focus went to the file") { tab.focusView != nil && window.firstResponder === tab.focusView }
        XCTAssertTrue(window.makeFirstResponder(main))
        model.tabs.close(tab)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the side shown again") { !side.isHidden }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === main, "the chat's composer keeps it")
    }

    /// A file with focus moved into the pane under the report does not take
    /// focus there: it is covered.
    @MainActor func testFocusDoesNotGoIntoATabCoveredByTheReport() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let first = model.openFile(try file(root, "l0.txt"))
        let popped = model.tabs.popOut(first)
        let other = try XCTUnwrap(model.tabs.window(of: popped))
        other.contentView?.layoutSubtreeIfNeeded()
        try await eventually("shown in its window") { first.focusView?.window === other }
        let text = try XCTUnwrap(first.focusView)
        XCTAssertTrue(other.makeFirstResponder(text))
        // The report comes and the tab moves in at once: the report may cover
        // the tab's content before the focus meant for it arrives.
        model.openReport()
        model.tabs.moveToPane(first)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("under the report") { text.window === window && text.isHiddenOrHasHiddenAncestor }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(window.firstResponder === text, "no focus in covered content")
    }

    /// A file's text with focus, moved to a window and back, has focus
    /// where it goes.
    @MainActor func testFocusGoesWithATabThatMoves() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "k.txt"))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown") { tab.focusView?.window === window }
        let text = try XCTUnwrap(tab.focusView)
        XCTAssertTrue(window.makeFirstResponder(text))
        let popped = model.tabs.popOut(tab)
        let other = try XCTUnwrap(model.tabs.window(of: popped))
        other.contentView?.layoutSubtreeIfNeeded()
        try await eventually("focused in the window") { text.window === other && other.firstResponder === text }
        model.tabs.moveToPane(tab)
        hosted.layoutSubtreeIfNeeded()
        try await eventually("focused back in the pane") { text.window === window && window.firstResponder === text }
    }

    /// A tab moved between the pane and a window, again and again, keeps
    /// what it had: its view, its selection and place, and its content's own
    /// state; and its text knows which window it is in.
    @MainActor func testATabMovedBetweenThePaneAndAWindowKeepsWhatItHad() async throws {
        let (model, root) = try await model()
        let (window, hosted) = window(model)
        let tab = model.openFile(try file(root, "f.txt", lines: 3_000))
        hosted.layoutSubtreeIfNeeded()
        try await eventually("the text shown") { tab.focusView?.window === window }
        let text = try XCTUnwrap(tab.focusView as? FileTextView)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        try await eventually("read") { (text.source as? FileView.FileDocument)?.status == .ready }
        text.select(from: FileTextPosition(line: 1_500, column: 5), to: FileTextPosition(line: 1_500, column: 9))
        text.scrollTo(line: 1_500)
        let place = scroll.contentView.bounds.origin
        let content = tab.contentView
        for round in 0..<3 {
            let popped = model.tabs.popOut(tab)
            let other = try XCTUnwrap(model.tabs.window(of: popped))
            other.contentView?.layoutSubtreeIfNeeded()
            try await eventually("in the window, round \(round)") { text.window === other }
            XCTAssertTrue(tab.contentView === content, "the same content")
            XCTAssertTrue(text.enclosingScrollView === scroll, "the same view")
            model.tabs.moveToPane(tab)
            hosted.layoutSubtreeIfNeeded()
            try await eventually("back in the pane, round \(round)") { text.window === window }
        }
        XCTAssertEqual(text.selectedRange.start, FileTextPosition(line: 1_500, column: 5))
        XCTAssertEqual(text.selectedRange.end, FileTextPosition(line: 1_500, column: 9))
        XCTAssertEqual(scroll.contentView.bounds.origin, place, "where it was")
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertTrue(text.isAccessibilityFocused(), "focused in the window it is in")
        XCTAssertTrue(model.tabs.windows.isEmpty)
    }
}
