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
/// The side takes the cursor, and the chat opened beside it never does.
final class SidebarSideClickTests: XCTestCase {
    @MainActor private final class Fixture {
        let model: WorkspaceModel, window: RecordingWindow, project: WorkspaceRecord
        init(model: WorkspaceModel, window: RecordingWindow, project: WorkspaceRecord) { self.model = model; self.window = window; self.project = project }
    }

    /// Records the chat of every composer it gives the keyboard to, however
    /// briefly: a composer that held it for a moment is as wrong as one that
    /// kept it, and a check of the window at one instant can miss either.
    @MainActor final class RecordingWindow: NSWindow {
        var composers: [String] = []
        @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let made = super.makeFirstResponder(responder)
            if made, let editor = responder as? ComposerTextView { composers.append(editor.sessionID) }
            return made
        }
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
        let window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
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

    /// The shared clock-timed wait. Three hundred sleeps of 10 ms gave a
    /// loaded machine well under three seconds, and failed there.
    @MainActor private func waitUntil(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually(what, file: file, line: line, condition)
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

    /// The composer that has the keyboard, by its chat.
    @MainActor private func keyboard(_ fixture: Fixture) -> String? {
        (fixture.window.firstResponder as? ComposerTextView)?.sessionID
    }

    /// The side is open beside its chat with its page read, and it has the
    /// cursor: the model says so and its composer has the keyboard. It still
    /// holds once the window has drawn what was pending. The chat opened on
    /// the way used to take the cursor back a moment after the side had it,
    /// and a check that caught that moment passed.
    @MainActor private func sideHasTheCursor(_ id: String, beside parent: String, in fixture: Fixture,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let model = fixture.model
        func holds() -> Bool {
            model.selectedID == parent && model.sides[parent]?.id == id && model.displays[id].map { [.ready, .empty].contains($0.historyState) } == true
                && model.focusedSessionID == id && keyboard(fixture) == id
        }
        func state() -> String {
            "selected \(model.selectedID ?? "none"), side \(model.sides[parent]?.id ?? "none"), page \(String(describing: model.displays[id]?.historyState)), "
                + "focus \(model.focusedSessionID ?? "none"), keyboard \(keyboard(fixture) ?? "none"), composers given it \(fixture.window.composers)"
        }
        do { try await waitUntil("The side opened beside its chat, with the cursor in its composer", { holds() }, file: file, line: line) }
        catch { XCTFail(state(), file: file, line: line); throw error }
        try await draw(fixture)
        XCTAssertTrue(holds(), "The side keeps the cursor: \(state())", file: file, line: line)
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
        fixture.window.composers.removeAll()

        try await click("S1", in: fixture)
        try await sideHasTheCursor("S1", beside: "P", in: fixture)
        XCTAssertEqual(fixture.window.composers, ["S1"], "Only the side's composer took the keyboard, never its chat's")
        XCTAssertEqual(model.displays["P"]?.composerFocusRequest, 0, "Nothing asked the chat's composer for the cursor")
        XCTAssertEqual(arrangement(fixture), before, "Clicking the side changes nothing in the sidebar")

        // Opened from anywhere else, where its row may be hidden, it is revealed.
        await model.select("Q")
        try await draw(fixture)
        await model.showSide("S1")
        try await draw(fixture)
        XCTAssertTrue(model.topics.first { $0.id == first.id }?.expanded == true, "Opened from elsewhere, the chat's topic opens")
        XCTAssertFalse(model.collapsedSidebarSides.contains("P"), "Opened from elsewhere, the chat's side list unfolds")
    }

    /// The chat had the cursor on an earlier visit. Opened again for its
    /// side, its composer, made anew for it, acted on that visit's request
    /// and took the keyboard as the side opened.
    @MainActor func testClickingASideOfAChatVisitedBeforeGivesTheCursorToTheSide() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        await model.select("P")
        try await waitUntil("The chat's composer has the cursor") { keyboard(fixture) == "P" }
        await model.select("Q")
        try await waitUntil("The other chat's composer has the cursor") { keyboard(fixture) == "Q" }
        try await draw(fixture)
        fixture.window.composers.removeAll()

        try await click("S1", in: fixture)
        try await sideHasTheCursor("S1", beside: "P", in: fixture)
        XCTAssertEqual(fixture.window.composers, ["S1"], "Only the side's composer took the keyboard, never its chat's")

        // Opened on its own again, the chat's composer takes the cursor as
        // before, and the side's, made anew beside it, does not.
        await model.select("Q")
        try await waitUntil("The other chat's composer has the cursor") { keyboard(fixture) == "Q" }
        fixture.window.composers.removeAll()
        await model.select("P")
        try await waitUntil("The chat's composer has the cursor again") { keyboard(fixture) == "P" && model.focusedSessionID == "P" }
        try await draw(fixture)
        XCTAssertEqual(keyboard(fixture), "P")
        XCTAssertFalse(fixture.window.composers.contains("S1"), "The side's composer never took the keyboard from its chat: \(fixture.window.composers)")
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
        try await sideHasTheCursor("S1", beside: "P", in: fixture)
        XCTAssertEqual(arrangement(fixture), before, "Clicking the side leaves the archive switch off")
    }

    /// The reader folded the side list of the chat they are working in and
    /// put the cursor in its side pane. The side list unfolded again.
    @MainActor func testPuttingTheCursorInTheSidePaneLeavesItsChatsSidesFolded() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        try await click("S1", in: fixture)
        try await sideHasTheCursor("S1", beside: "P", in: fixture)
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
