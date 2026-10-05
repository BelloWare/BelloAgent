import XCTest
import SwiftUI
import AppKit
import FileView
@testable import PiApp
@testable import GitView

/// Changes as a tab: one tab a project, opened (or
/// shown again, wherever it is) by ⇧⌘G and every Changes button, over the
/// report too; moved between the pane and a window with its controller and
/// the reader's place; brought back after a relaunch without reading until
/// it is shown; closed by ⌘W, letting go of what it read; saying so when its
/// project is removed, and reading again when it comes back; and ⌘↩, ⌘F and
/// ⌘. in its commit message never acting on the chat behind it.
final class ChangesTabTests: GitPanelTestCase {
    /// A project over a repository with two changed files, a chat in it, and
    /// the workspace window.
    @MainActor private func workspace() async throws -> (model: WorkspaceModel, window: NSWindow, project: WorkspaceRecord) {
        let folder = try repository("changes-tab")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try start(folder)
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: folder); try git(["commit", "-q", "-m", "Seed"], in: folder)
        try "one!\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two!\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let project = WorkspaceRecord(id: "changes-tab-project", path: folder.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "changes-tab-profile"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "changes-model"
        var configuration = VaultConfiguration()
        configuration.workspaces = [project]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-changes-tab-key")]
        // The app's state apart from the repository, whose changes it would be.
        let state = try repository("changes-tab-state")
        let model = WorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: state)
        model.tabs.showsWindows = false
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "changes-tab-chat", workspaceID: project.id, title: "Chat", path: nil, profileID: profile.id)
        let session = SessionDisplay(id: chat.id)
        session.draft = "The chat's draft"
        model.chats = [chat]; model.selectedID = chat.id; model.selected = session; model.displays = [chat.id: session]
        model.selectedWorkspaceID = project.id; model.focusedSessionID = chat.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in model.tabs.tearDown(); model.report.suspend(); window.contentView = nil; window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        return (model, window, project)
    }
    @MainActor private func changes(_ model: WorkspaceModel, _ project: WorkspaceRecord) -> ChangesTab? {
        model.tabs.tab(kind: ChangesTab.kind, key: project.id) as? ChangesTab
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testShowChangesOpensTheProjectsTabAndShowsItAgain() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        let tab = try XCTUnwrap(changes(model, project), "A Changes tab, in the pane")
        XCTAssertTrue(model.tabs.pane.tabs.contains { $0 === tab })
        XCTAssertEqual(tab.title, "Changes · " + URL(fileURLWithPath: project.path).lastPathComponent)
        XCTAssertEqual(tab.symbol, "arrow.left.arrow.right")
        XCTAssertEqual(tab.preferredWindowSize, NSSize(width: 1040, height: 720))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("its panel, read") { tab.hasController && tab.controller.status.entries.count == 2 && !tab.controller.loading }
        XCTAssertNil(window.attachedSheet, "Changes leaves the workspace available while its tab is open")

        model.showChanges(in: project.id)
        XCTAssertEqual(model.tabs.allTabs.count, 1, "Shown again, not opened twice")

        // Over the report, the chats come back to show it.
        model.openReport()
        XCTAssertEqual(model.page, .report)
        model.showChanges(in: project.id)
        XCTAssertEqual(model.page, .chats)
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === tab)
        XCTAssertNil(window.attachedSheet, "Opening Changes over the report also uses the tab")
    }

    /// Moved to a window and back, the tab keeps its controller and the
    /// reader's place, and its panel is never hidden on the way.
    @MainActor func testAChangesTabMovedToAWindowKeepsItsControllerAndPlace() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        let tab = try XCTUnwrap(changes(model, project))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read") { tab.hasController && tab.controller.status.entries.count == 2 && !tab.controller.diffLoading && !tab.controller.diff.isEmpty }
        let controller = tab.controller
        controller.selection = GitController.Selection(path: "b.txt", staged: false)
        try await eventually("b.txt's diff") { controller.diff.first?.path == "b.txt" && !controller.diffLoading }

        let popped = model.tabs.popOut(tab)
        let other = try XCTUnwrap(model.tabs.window(of: popped))
        other.contentView?.layoutSubtreeIfNeeded()
        try await eventually("shown in its window") { controller.isShown && !controller.suspended }
        XCTAssertTrue(tab.controller === controller, "The same controller")
        XCTAssertEqual(controller.selection?.path, "b.txt", "and the reader's place")
        // ⇧⌘G shows it where it is: in its window, which comes forward, not the pane.
        XCTAssertTrue(model.showChanges(in: project.id) === tab)
        XCTAssertTrue(tab.container === popped && !popped.isPane)
        model.tabs.moveToPane(tab)
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("back in the pane") { controller.isShown && tab.container === model.tabs.pane }
        XCTAssertEqual(controller.selection?.path, "b.txt")
    }

    @MainActor func testADiffLocationOpensTheCurrentFileInATabAtItsLine() async throws {
        let (model, window, project) = try await workspace()
        let url = URL(fileURLWithPath: project.path).appendingPathComponent("a.txt")
        try "one!\ntwo\nthree\n".write(to: url, atomically: true, encoding: .utf8)
        let changes = try XCTUnwrap(model.showChanges(in: project.id))
        try await eventually("the repository root") { changes.controller.repositoryRoot != nil }
        changes.openFile(path: "a.txt", line: 2)
        let file = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
        XCTAssertEqual(file.key, FileTab.key(for: url))
        XCTAssertEqual(file.projectID, project.id)
        try await eventually("the diff's line is shown") {
            window.contentView?.layoutSubtreeIfNeeded()
            return (file.focusView as? FileTextView)?.emphasized == 1...1
        }
        changes.openFile(path: "a.txt", line: 3)
        XCTAssertTrue(model.tabs.pane.activeTab === file, "a second location reuses the file tab")
        try await eventually("the second line is shown") { (file.focusView as? FileTextView)?.emphasized == 2...2 }
    }

    /// Brought back after a relaunch, a Changes tab reads nothing until it is
    /// shown; a tab whose project was removed meanwhile is left out.
    @MainActor func testAChangesTabComesBackAfterARelaunchAndReadsOnlyWhenShown() throws {
        let suite = "changes-tab-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let resolve = ChangesTab.resolveProject
        addTeardownBlock { @MainActor in ChangesTab.resolveProject = resolve }
        ChangesTab.resolveProject = { id in ["kept", "gone"].contains(id) ? (id, ["/tmp/" + id]) : nil }
        let first = TabHost(defaults: defaults)
        first.showsWindows = false
        first.restore()
        first.open(kind: ChangesTab.kind, key: "kept") { ChangesTab(projectID: "kept", name: "kept", roots: ["/tmp/kept"]) }
        first.open(kind: ChangesTab.kind, key: "gone") { ChangesTab(projectID: "gone", name: "gone", roots: ["/tmp/gone"]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("changes-tab-note-" + UUID().uuidString + ".txt")
        try Data("note".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        first.open(kind: FileTab.kind, key: FileTab.key(for: file)) { FileTab(url: file, projectID: nil) }
        first.flush()
        first.tearDown()

        ChangesTab.resolveProject = { id in id == "kept" ? ("kept", ["/tmp/kept"]) : nil }
        let again = TabHost(defaults: defaults)
        again.showsWindows = false
        again.restore()
        defer { again.tearDown() }
        let kept = try XCTUnwrap(again.tab(kind: ChangesTab.kind, key: "kept") as? ChangesTab, "Brought back")
        XCTAssertNil(again.tab(kind: ChangesTab.kind, key: "gone"), "A removed project's tab is left out")
        XCTAssertEqual(kept.title, "Changes · kept")
        XCTAssertFalse(kept.hasContent)
        XCTAssertFalse(kept.hasController, "Nothing read for a tab not shown")
    }

    /// ⌘W closes the Changes tab the pane shows, and it lets go of what it read.
    @MainActor func testCommandWClosesTheChangesTabAndItLetsGo() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        weak var tab = changes(model, project)
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read") { tab?.hasController == true && tab?.controller.statusRead == true && tab?.controller.loading == false }
        weak var controller = tab?.controller
        let commandW = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        let chrome = try XCTUnwrap(descendants(WindowChromeView.self, in: try XCTUnwrap(window.contentView)).first?.controller)
        XCTAssertTrue(autoreleasepool { chrome.closeShownTab(commandW) })
        XCTAssertTrue(model.tabs.pane.tabs.isEmpty)
        try await eventually("its controller let go of") { autoreleasepool { controller == nil || controller?.statusRead == false } }
    }

    /// A project removed while its tab is open: the tab says so and reads nothing.
    @MainActor func testAProjectRemovedWhileItsTabIsOpenSaysSo() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        let tab = try XCTUnwrap(changes(model, project))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read") { tab.hasController && tab.controller.statusRead && !tab.controller.loading }
        model.workspaces = []
        XCTAssertTrue(tab.removed, "The tab says its project was removed")
        XCTAssertFalse(tab.controller.statusRead, "and let go of what it read")
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("its panel gone") { !tab.controller.isShown }
        XCTAssertFalse(tab.controller.isWatching)
    }

    /// A project removed and added back before the tab was drawn again: its
    /// panel never left the screen, and it reads again.
    @MainActor func testAProjectRemovedAndAddedBackInOneTurnReadsAgain() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        let tab = try XCTUnwrap(changes(model, project))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read") { tab.hasController && tab.controller.isShown && tab.controller.statusRead && !tab.controller.loading }
        let projects = model.workspaces
        model.workspaces = []
        model.workspaces = projects
        XCTAssertFalse(tab.removed)
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read again") { tab.controller.statusRead && tab.controller.status.entries.count == 2 && !tab.controller.loading && tab.controller.isWatching }
    }

    /// ⌘↩, ⌘F and ⌘. with the keyboard in the commit message are the
    /// message's: the chat's draft is not sent from behind it, nor its search
    /// opened. In the composer they are the chat's.
    @MainActor func testTheConversationKeysInTheCommitMessageLeaveTheChatAlone() async throws {
        let (model, window, project) = try await workspace()
        model.showChanges(in: project.id)
        let tab = try XCTUnwrap(changes(model, project))
        window.contentView?.layoutSubtreeIfNeeded()
        try await eventually("read") { tab.hasController && tab.controller.statusRead && !tab.controller.loading }
        let content = tab.contentView
        let field = try XCTUnwrap(descendants(NSTextField.self, in: content).first { $0.isEditable && $0.placeholderString == "Commit message" }, "The commit message field")
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(WorkspaceModel.typingInATab(in: window), "Typing in the tab's commit message")
        model.submitFocusedComposer(intent: .steer, in: window)
        XCTAssertEqual(model.displays["changes-tab-chat"]?.draft, "The chat's draft", "Nothing sent from behind the tab")
        model.searchFocusedConversation(in: window)
        XCTAssertFalse(model.showConversationContent, "Nor the chat's search opened over it")
        let chat = try XCTUnwrap(model.displays["changes-tab-chat"])
        chat.state = "running"
        model.stopFocused(in: window)
        XCTAssertEqual(chat.state, "running", "The tab's text must not stop the chat behind it")

        let composer = try XCTUnwrap(descendants(ComposerTextView.self, in: try XCTUnwrap(window.contentView)).first, "The chat's composer")
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertFalse(WorkspaceModel.typingInATab(in: window), "In the composer, ⌘↩ is the chat's")
        model.searchFocusedConversation(in: window)
        XCTAssertTrue(model.showConversationContent, "and ⌘F opens the chat's search")
        model.stopFocused(in: window)
        XCTAssertEqual(chat.runState, .interrupted, "In the composer the stop key reaches the running chat")
        model.showConversationContent = false
    }
}
