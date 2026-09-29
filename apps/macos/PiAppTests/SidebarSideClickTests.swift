import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Clicking a side in the left bar, or putting the cursor in the side pane,
/// opens the side beside its chat and leaves the sidebar exactly as the
/// reader arranged it. Before, the click expanded the collapsed topic of the
/// chat the side belongs to and unfolded that chat's side list, a side of an
/// archived chat turned the archive switch on, and a click into the side
/// pane unfolded the side list the reader had folded. Opening a side from
/// anywhere else (the menu bar, the Usage Report, search) still reveals it.
final class SidebarSideClickTests: XCTestCase {
    @MainActor private final class Fixture {
        let model: WorkspaceModel, window: NSWindow, project: WorkspaceRecord
        init(model: WorkspaceModel, window: NSWindow, project: WorkspaceRecord) { self.model = model; self.window = window; self.project = project }
    }

    @MainActor private func fixture(parentArchived: Bool = false) async throws -> Fixture {
        let root = scratchRoot("sidebar-side-click")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "side-click-project", path: folder.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "side-click-profile"; profile.name = "Sides"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "side-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-side-click-key")]; $0.automaticUpdateChecks = false }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        func chat(_ id: String, _ order: Int64, parent: String? = nil, archived: Bool = false) -> ChatRecord {
            var record = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: profile.id, sidebarOrder: 1_000 - order)
            record.parentSessionID = parent
            if archived { record.archivedAt = Date() }
            return record
        }
        // "P" has two saved sides, "S1" and "S2"; "Q" is another chat.
        let chats = [chat("P", 1, archived: parentArchived), chat("Q", 2), chat("S1", 3, parent: "P"), chat("S2", 4, parent: "P")]
        for item in chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.chats = chats
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model).transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close(); model.report.suspend(); model.shutdown(); try? await model.traces.close(); await model.store?.close()
        }
        let fixture = Fixture(model: model, window: window, project: workspace)
        try await draw(fixture)
        return fixture
    }

    /// SwiftUI takes a change on its next pass; the sidebar's own reveal runs
    /// in the pass after that.
    @MainActor private func draw(_ fixture: Fixture) async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(30))
            fixture.window.contentView?.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
        }
    }

    @MainActor private func waitUntil(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The row's own press, as the sidebar's press surface delivers a plain click.
    @MainActor private func click(_ id: String, in fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try XCTUnwrap(fixture.window.contentView)
        let type = NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)
        let surface = views(TopicSessionDragSurfaceView.self, in: root).first { surface in
            guard let data = surface.actions.item()?.data(forType: type),
                  let drag = TopicSessionDrag.decode(data, in: fixture.project.id) else { return false }
            return drag.sessionIDs == [id]
        }
        try XCTUnwrap(surface, "The row of \(id) is on screen", file: file, line: line).actions.click([])
    }

    /// Everything the reader arranges in the sidebar.
    @MainActor private func arrangement(_ fixture: Fixture) -> String {
        let model = fixture.model
        let topics = model.topics.sorted { $0.title < $1.title }.map { "\($0.title) \($0.expanded ? "open" : "collapsed")" }
        return "project \(model.projectIsExpanded(fixture.project.id) ? "open" : "collapsed"); topics \(topics); folded \(model.collapsedSidebarSides.sorted()); archive \(model.sidebarShowsArchived ? "shown" : "hidden"); pages \(model.sidebarPageSizes)"
    }

    /// A side moved into another topic is listed there on its own. Clicking
    /// it opened it beside its chat, and also expanded that chat's collapsed
    /// topic and unfolded the chat's side list.
    @MainActor func testClickingASideListedInAnotherTopicLeavesTheSidebarAsItWas() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let first = try await model.createTopic(in: fixture.project.id, title: "Chats")
        let second = try await model.createTopic(in: fixture.project.id, title: "Sides")
        try await model.moveSessions(["P"], in: fixture.project.id, toTopic: first.id)
        try await model.moveSessions(["S1"], in: fixture.project.id, toTopic: second.id)
        await model.select("Q")
        model.setTopicExpanded(first.id, expanded: false)
        model.setSidebarSideFolded("P", folded: true)
        try await draw(fixture)
        let before = arrangement(fixture)

        try await click("S1", in: fixture)
        try await waitUntil("The side opened beside its chat") { model.selectedID == "P" && model.sides["P"]?.id == "S1" && model.focusedSessionID == "S1" }
        try await draw(fixture)
        XCTAssertEqual(arrangement(fixture), before, "Clicking the side changes nothing in the sidebar")

        // Opened from anywhere else, where its row may be hidden, it is revealed.
        await model.select("Q")
        try await draw(fixture)
        await model.showSide("S1")
        try await draw(fixture)
        XCTAssertTrue(model.topics.first { $0.id == first.id }?.expanded == true, "Opened from elsewhere, the chat's topic opens")
        XCTAssertFalse(model.collapsedSidebarSides.contains("P"), "Opened from elsewhere, the chat's side list unfolds")
    }

    /// A side of an archived chat is listed on its own while the archive is
    /// hidden. Clicking it turned the archive switch on for every project.
    @MainActor func testClickingASideOfAnArchivedChatLeavesTheArchiveHidden() async throws {
        let fixture = try await fixture(parentArchived: true)
        let model = fixture.model
        await model.select("Q")
        try await draw(fixture)
        let before = arrangement(fixture)

        try await click("S1", in: fixture)
        try await waitUntil("The side opened beside its chat") { model.selectedID == "P" && model.sides["P"]?.id == "S1" }
        try await draw(fixture)
        XCTAssertEqual(arrangement(fixture), before, "Clicking the side leaves the archive switch off")
    }

    /// The reader folded the side list of the chat they are working in and
    /// put the cursor in its side pane. The side list unfolded again.
    @MainActor func testPuttingTheCursorInTheSidePaneLeavesItsChatsSidesFolded() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        try await click("S1", in: fixture)
        try await waitUntil("The side opened beside its chat") { model.sides["P"]?.id == "S1" && model.focusedSessionID == "S1" }
        try await draw(fixture)
        let root = try XCTUnwrap(fixture.window.contentView)
        func composer(_ id: String) throws -> ComposerTextView {
            try XCTUnwrap(views(ComposerTextView.self, in: root).first { $0.sessionID == id }, "The composer of \(id) is on screen")
        }
        fixture.window.makeFirstResponder(try composer("P"))
        try await waitUntil("The chat's own composer took the cursor") { model.focusedSessionID == "P" }
        model.setSidebarSideFolded("P", folded: true)
        try await draw(fixture)
        let before = arrangement(fixture)

        fixture.window.makeFirstResponder(try composer("S1"))
        try await waitUntil("The side's composer took the cursor") { model.focusedSessionID == "S1" }
        try await draw(fixture)
        XCTAssertEqual(arrangement(fixture), before, "The cursor in the side pane leaves the side list folded")

        // Opened from anywhere else, such as the menu bar or a search result,
        // the side still unfolds the list that hides it.
        fixture.window.makeFirstResponder(try composer("P"))
        try await waitUntil("The chat's own composer took the cursor") { model.focusedSessionID == "P" }
        await model.selectSide("S1")
        try await draw(fixture)
        XCTAssertFalse(model.collapsedSidebarSides.contains("P"), "Opened from elsewhere, the side list unfolds")
    }
}
