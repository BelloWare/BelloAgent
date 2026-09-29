import XCTest
import SwiftUI
import AppKit
import Combine
@testable import PiApp

/// The sides panel at the window's right edge (`SidesPanel.swift`). It comes
/// when the pointer rests on the edge, never with a mouse button down; it
/// stays while the pointer is on it and goes a moment after the pointer has
/// left. A side chosen in it opens beside its chat without unfolding the
/// sidebar. Pinned, it is a column of the window and is remembered. A chat
/// without sides still offers a new one. Its coming and going neither moves
/// nor redraws the conversation under it.
final class SidesPanelTests: XCTestCase {
    @MainActor private func eventually(_ what: String, seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                                       _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    // MARK: Coming and going

    /// Where the pointer is, as the test says; the panel asks the same
    /// questions of its views in the app.
    @MainActor private final class Pointer {
        var atEdge = false, onPanel = false, buttonDown = false
        func attach(_ reveal: SidesPanelReveal) {
            reveal.pointerAtEdge = { [unowned self] in self.atEdge }
            reveal.pointerOnPanel = { [unowned self] in self.onPanel }
            reveal.buttonsDown = { [unowned self] in self.buttonDown }
            reveal.poll = .milliseconds(20)
        }
    }

    @MainActor func testTheEdgeBringsThePanelAfterARestAndItGoesAfterAGrace() async throws {
        let reveal = SidesPanelReveal(), pointer = Pointer()
        pointer.attach(reveal)

        // Resting at the edge brings it, and not before the pointer has rested.
        reveal.dwell = .seconds(1); pointer.atEdge = true
        reveal.edge(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(reveal.shown, "The panel waits for the pointer to rest on the edge")
        try await eventually("The pointer resting on the edge brings the panel") { reveal.shown }

        // It stays while the pointer is on it, however long.
        reveal.grace = .milliseconds(150)
        pointer.atEdge = false; pointer.onPanel = true
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(reveal.shown, "The panel stays while the pointer is on it")

        // Off it for the grace, it goes; not the moment the pointer leaves.
        pointer.onPanel = false
        XCTAssertTrue(reveal.shown, "The panel does not vanish the moment the pointer leaves it")
        try await eventually("The panel goes once the pointer has left it") { !reveal.shown }

        // Crossing out and back within the grace keeps it.
        reveal.grace = .seconds(2)
        reveal.show()
        try await Task.sleep(for: .milliseconds(60))
        pointer.onPanel = true
        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertTrue(reveal.shown, "Coming back within the grace keeps the panel")
        reveal.hide(); pointer.onPanel = false

        // Passing over the edge without resting brings nothing.
        reveal.dwell = .milliseconds(300)
        pointer.atEdge = true; reveal.edge(true)
        pointer.atEdge = false; reveal.edge(false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(reveal.shown, "A pointer passing over the edge brings nothing")

        // Where the handle meets the edge, leaving the one for the other
        // keeps the rest the pointer began.
        pointer.atEdge = true; reveal.edge(true)
        reveal.edge(false)
        try await eventually("Moving from the handle onto the edge still brings the panel") { reveal.shown }
        reveal.hide(); pointer.atEdge = false

        // Nothing comes with a mouse button down: a scroll bar dragged to the edge.
        pointer.buttonDown = true; pointer.atEdge = true
        reveal.edge(true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(reveal.shown, "Nothing comes while a mouse button is down")
        pointer.buttonDown = false
        reveal.edge(true)
        pointer.buttonDown = true
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(reveal.shown, "A button pressed while the pointer rests stops the panel coming")
        pointer.buttonDown = false; pointer.atEdge = false; reveal.edge(false)

        // Out until told otherwise, as the gallery and a pinned panel's unpin need.
        reveal.show(untilHidden: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(reveal.shown, "Shown until hidden, it stays with the pointer elsewhere")
        reveal.hide()
        XCTAssertFalse(reveal.shown)
    }

    // MARK: The window

    @MainActor private final class Fixture {
        let model: WorkspaceModel, window: NSWindow, root: URL
        init(model: WorkspaceModel, window: NSWindow, root: URL) { self.model = model; self.window = window; self.root = root }
    }

    /// A conversation file of eight messages the history reader pages as it
    /// pages any chat.
    private func journal(_ id: String, in root: URL) throws -> String {
        let file = root.appendingPathComponent("\(id).jsonl"), encoder = JSONEncoder()
        var bytes = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string(id)]); bytes.append(10)
        for i in 0..<8 {
            bytes.append(try encoder.encode(["type": WireValue.string("message"), "id": .string("\(id)-m\(i)"),
                "parentId": i == 0 ? .null : .string("\(id)-m\(i - 1)"),
                "message": .object(["role": .string(i % 2 == 0 ? "user" : "assistant"),
                                    "content": .string("Message \(i) of \(id). " + String(repeating: "A line of the conversation. ", count: 6))])]))
            bytes.append(10)
        }
        try bytes.write(to: file)
        return file.path
    }

    /// Chat "P" open in a window, with its saved sides "S1" and "S2" (the
    /// first beside it), and chat "Q"; or "P" with no sides at all.
    @MainActor private func fixture(sides: Bool = true) async throws -> Fixture {
        let root = scratchRoot("sides-panel")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "sides-panel-project", path: folder.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "sides-panel-profile"; profile.name = "Sides"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "sides-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-sides-panel-key")]; $0.automaticUpdateChecks = false }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        func chat(_ id: String, _ order: Int64, parent: String? = nil) throws -> ChatRecord {
            var record = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: try journal(id, in: folder), profileID: profile.id, sidebarOrder: 1_000 - order)
            record.parentSessionID = parent
            return record
        }
        var chats = [try chat("P", 1), try chat("Q", 2)]
        if sides { chats += [try chat("S1", 3, parent: "P"), try chat("S2", 4, parent: "P")] }
        for item in chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        model.chats = chats
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model).transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            RedrawCounter.recording = false; RedrawCounter.reset()
            model.sidesPanelReveal.hide()
            window.contentView = nil; window.close(); model.report.suspend(); model.shutdown(); try? await model.traces.close(); await model.store?.close()
        }
        let fixture = Fixture(model: model, window: window, root: root)
        await model.select("P")
        if sides { await model.showSide("S1") }
        try await eventually("The chat and its side are on screen") {
            model.displays["P"]?.historyState == .ready && (!sides || model.displays["S1"]?.historyState == .ready)
        }
        try await draw(fixture)
        try await Task.sleep(for: .milliseconds(300))
        try await draw(fixture)
        return fixture
    }

    /// SwiftUI takes a change on its next pass.
    @MainActor private func draw(_ fixture: Fixture) async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(30))
            fixture.window.contentView?.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
        }
    }

    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The chat's pane and its side's, left to right, in the window's space.
    @MainActor private func panes(_ fixture: Fixture) throws -> [CGRect] {
        let root = try XCTUnwrap(fixture.window.contentView)
        return views(TranscriptNativeScrollView.self, in: root).map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
    }

    /// Where each row on the page stands, in the window's space.
    @MainActor private func rowFrames(_ fixture: Fixture) throws -> [String: CGRect] {
        let root = try XCTUnwrap(fixture.window.contentView)
        var frames: [String: CGRect] = [:]
        for scroll in views(TranscriptNativeScrollView.self, in: root) {
            guard let document = scroll.documentView as? TranscriptNativeDocument else { continue }
            for row in document.retainedRows where row.superview === document && row.isHosted { frames[row.itemID] = row.convert(row.bounds, to: nil) }
        }
        return frames
    }

    @MainActor private func pointerAreas(_ fixture: Fixture) throws -> Int {
        views(SidesPanelPointerView.self, in: try XCTUnwrap(fixture.window.contentView)).count
    }

    /// A side chosen in the panel opens in the side pane beside its chat, and
    /// nothing in the sidebar unfolds for it: the reader chose it on the right.
    @MainActor func testASideChosenInThePanelOpensBesideItsChatAndUnfoldsNothing() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        XCTAssertEqual(model.sidesPanelEntries(of: "P").map(\.id), ["S1", "S2"], "The panel lists the chat's sides in the sidebar's order")
        XCTAssertEqual(model.sidesPanelEntries(of: "P").filter(\.open).map(\.id), ["S1"], "and marks the one beside it")
        model.setSidebarSideFolded("P", folded: true)
        model.sidesPanelReveal.show(untilHidden: true)
        try await draw(fixture)

        await model.openFromSidesPanel("S2")
        try await eventually("The side chosen opens beside its chat") {
            model.sides["P"]?.id == "S2" && model.displays["S2"]?.historyState == .ready
        }
        XCTAssertEqual(model.selectedID, "P", "Its chat stays in the main pane")
        XCTAssertEqual(model.focusedSessionID, "S2", "and the side takes the keyboard")
        XCTAssertEqual(model.sidesPanelEntries(of: "P").filter(\.open).map(\.id), ["S2"], "The panel marks the side now beside the chat")
        XCTAssertTrue(model.collapsedSidebarSides.contains("P"), "The sidebar's fold is left as the reader left it")
        XCTAssertTrue(model.sidesPanelReveal.shown, "The panel stays out while the reader is choosing")

        // With no side open, a side chosen in the panel opens the side pane.
        model.closeSide("S2")
        try await eventually("The side closes") { model.sides["P"] == nil }
        try await draw(fixture)
        XCTAssertEqual(try panes(fixture).count, 1, "Only the chat is on screen")
        XCTAssertTrue(model.sidesPanelEntries(of: "P").allSatisfy { !$0.open }, "and the panel marks no side")
        await model.openFromSidesPanel("S1")
        try await eventually("The side chosen opens the side pane") {
            model.sides["P"]?.id == "S1" && model.displays["S1"]?.historyState == .ready
        }
        try await draw(fixture)
        XCTAssertEqual(try panes(fixture).count, 2, "The side pane is back, beside the chat")
        XCTAssertTrue(model.collapsedSidebarSides.contains("P"), "and the sidebar's fold is still as the reader left it")
    }

    /// The handle carries what the sides other than the one on screen are
    /// doing: the ring of one working, the dot of a new reply or a failure.
    @MainActor func testTheHandleCarriesWhatTheOtherSidesAreDoing() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        XCTAssertEqual(model.sidesPanelActivity(of: "P"), SidesPanelActivity(sides: 2), "Two quiet sides")
        model.unreadStates["S1"] = SessionReadState(id: "S1", observedAssistantCount: 1, unreadOutputs: 1)
        XCTAssertFalse(model.sidesPanelActivity(of: "P").unread, "The side on screen is no news")
        model.unreadStates["S2"] = SessionReadState(id: "S2", observedAssistantCount: 1, unreadOutputs: 1)
        XCTAssertTrue(model.sidesPanelActivity(of: "P").unread, "A new reply in the other side is")
        model.unreadStates["S2"]?.unreadFailure = true
        XCTAssertTrue(model.sidesPanelActivity(of: "P").failed, "and so is its failure")
        let working = SessionDisplay(id: "S2"); working.state = "running"; model.displays["S2"] = working
        XCTAssertTrue(model.sidesPanelActivity(of: "P").working, "and its run")
        working.state = "idle"; model.unreadStates["S2"] = nil
        XCTAssertEqual(model.sidesPanelActivity(of: "P"), SidesPanelActivity(sides: 2), "Quiet again, the handle is plain")
    }

    /// Pinned, the panel is a column at the window's right: the panes give it
    /// their room, once, and get it back when it is unpinned. The pin is
    /// written with the selection, and a launch reads it back.
    @MainActor func testPinnedThePanelIsAColumnOfTheWindowAndIsRemembered() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let before = try panes(fixture)
        XCTAssertEqual(before.count, 2, "The chat and its side are both on screen")

        model.setSidesPanelPinned(true)
        try await draw(fixture)
        let pinned = try panes(fixture)
        XCTAssertLessThanOrEqual(pinned.last?.maxX ?? .infinity, (before.last?.maxX ?? 0) - SidesPanelMetrics.width, "Pinned, the panes give the panel its column")
        XCTAssertLessThan(pinned.last?.width ?? .infinity, before.last?.width ?? 0, "The side pane narrows")
        XCTAssertFalse(model.sidesPanelReveal.shown, "A pinned panel is not also laid over the conversation")

        await model.flushSelection()
        let store = try XCTUnwrap(model.store)
        let remembered = try await store.get(RememberedSelection.self, kind: RememberedSelection.recordKind, id: RememberedSelection.recordID)
        XCTAssertEqual(remembered?.sidesPanelPinned, true, "The pin is written with the selection")
        let relaunched = WorkspaceModel(stateRoot: fixture.root.appendingPathComponent("relaunch-state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in relaunched.shutdown(); try? await relaunched.traces.close(); await relaunched.store?.close() }
        relaunched.adoptRememberedSelection(remembered)
        XCTAssertTrue(relaunched.sidesPanelPinned, "and a launch that reads it has the panel pinned")

        model.setSidesPanelPinned(false)
        XCTAssertTrue(model.sidesPanelReveal.shown, "Unpinned under the pointer, the panel stays out over the conversation")
        try await draw(fixture)
        XCTAssertEqual(try panes(fixture), before, "Unpinned, the panes are as they were")
        await model.flushSelection()
        let unpinned = try await store.get(RememberedSelection.self, kind: RememberedSelection.recordKind, id: RememberedSelection.recordID)
        XCTAssertNil(unpinned?.sidesPanelPinned, "and the pin is forgotten")
    }

    /// A chat without sides has no handle at the edge, but the edge still
    /// brings the panel, whose New side starts one as the menu's does.
    @MainActor func testAChatWithoutSidesStillOffersANewSideAtTheEdge() async throws {
        let fixture = try await fixture(sides: false)
        let model = fixture.model
        XCTAssertTrue(model.sidesPanelEntries(of: "P").isEmpty)
        XCTAssertTrue(model.sidesPanelAvailable(for: "P"), "A chat that can open a side offers the panel")
        XCTAssertEqual(model.sidesPanelActivity(of: "P").sides, 0)
        XCTAssertEqual(try pointerAreas(fixture), 1, "The edge that brings the panel, and no handle")

        model.sidesPanelReveal.show(untilHidden: true)
        try await draw(fixture)
        XCTAssertEqual(try pointerAreas(fixture), 2, "The edge and the panel")

        model.openSide(parentID: "P")
        try await eventually("New side opens a side beside the chat") { model.sides["P"]?.pending == true }
        XCTAssertEqual(model.sidesPanelEntries(of: "P").map(\.title), ["New side"], "The panel lists the new side, open")
        model.sidesPanelReveal.hide()
        try await draw(fixture)
        XCTAssertEqual(try pointerAreas(fixture), 2, "With a side, the handle comes back beside the edge")
    }

    /// Pinned, the panel stays beside the Usage Report and Background
    /// Requests. New side there opens the side on the chats page, where it
    /// can be seen, as a side chosen in the panel does.
    @MainActor func testNewSideFromAPinnedPanelBesideAnotherPageShowsTheChats() async throws {
        let fixture = try await fixture(sides: false)
        let model = fixture.model
        model.setSidesPanelPinned(true)
        for page in [WorkspacePage.report, .background] {
            model.page = page
            try await draw(fixture)
            model.openSideFromSidesPanel(parentID: "P")
            XCTAssertEqual(model.page, .chats, "New side beside the \(page) page shows the chats")
            try await eventually("New side opens a side beside the chat") { model.sides["P"]?.pending == true }
            XCTAssertEqual(model.focusedSessionID, model.sides["P"]?.id, "and the side has the cursor")
        }
    }

    /// The panel lies over the conversation: its coming and going neither
    /// moves a row nor draws the transcript again.
    @MainActor func testThePanelComingAndGoingMovesAndRedrawsNothingUnderIt() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let rows = try rowFrames(fixture), panes = try panes(fixture)
        XCTAssertFalse(rows.isEmpty, "The chat and its side have rows on screen")
        // Whatever the chats themselves change meanwhile is counted, and
        // allowed for: it would draw their transcripts, rightly.
        var changes = 0
        var watching: Set<AnyCancellable> = []
        for id in ["P", "S1"] { model.displays[id]?.objectWillChange.sink { _ in changes += 1 }.store(in: &watching) }
        RedrawCounter.reset(); RedrawCounter.recording = true

        model.sidesPanelReveal.show(untilHidden: true)
        try await draw(fixture)
        XCTAssertEqual(try pointerAreas(fixture), 2, "The panel is out")
        XCTAssertEqual(try rowFrames(fixture), rows, "No row moves when the panel comes")
        XCTAssertEqual(try self.panes(fixture), panes, "and no pane changes size")

        model.sidesPanelReveal.hide()
        try await draw(fixture)
        XCTAssertEqual(try rowFrames(fixture), rows, "No row moves when it goes")
        XCTAssertLessThanOrEqual(RedrawCounter.counts["transcript", default: 0], changes,
                                 "The panel's coming and going draws no transcript again (the chats changed \(changes) times)")
        RedrawCounter.recording = false
        withExtendedLifetime(watching) {}
    }
}
