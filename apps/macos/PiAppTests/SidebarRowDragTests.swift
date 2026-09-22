import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Dragging a sidebar chat row. A SwiftUI `Button` claims mouse-down on macOS,
/// so the press is handled in AppKit; these cover what a press decides and what
/// it carries. The pull itself cannot be synthesized here — no test process can
/// run AppKit's blocking drag loop — so the pointer is left to a real one.
final class SidebarRowDragTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// The sidebar lists the largest order first, so chat1 leads the list.
    private func chat(_ id: String, order: Int64 = 1, project: String = "project") -> ChatRecord {
        ChatRecord(id: id, workspaceID: project, title: id.capitalized, path: nil, profileID: "fixture", sidebarOrder: 100 - order)
    }
    @MainActor private func makeModel(_ root: URL, chats: [ChatRecord]) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true),
                            WorkspaceRecord(id: "other", path: root.appendingPathComponent("other").path, trusted: true)]
        model.chats = chats
        model.selectedWorkspaceID = "project"
        for item in chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        return model
    }
    @MainActor private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The drop never finished", file: file, line: line)
    }
    private func press(_ type: NSEvent.EventType, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }
    private func payload(_ item: NSPasteboardItem) throws -> TopicSessionDrag {
        let type = NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)
        return try XCTUnwrap(TopicSessionDrag.decode(try XCTUnwrap(item.data(forType: type)), in: "project"))
    }

    @MainActor func testTheRowPutsItsMarkedChatsOnTheDragPasteboardWithAPreviewImage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(root, chats: (1...3).map { chat("chat\($0)", order: Int64($0)) })
        defer { model.shutdown() }
        func source(_ id: String) -> TopicSessionDragSource {
            TopicSessionDragSource(model: model, sessionID: id, projectID: "project", enabled: true, click: { _ in }, doubleClick: { })
        }
        let alone = try XCTUnwrap(source("chat2").dragItem())
        XCTAssertEqual(alone.types, [NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)],
                       "A chat drag is not also a text or file drop")
        XCTAssertEqual(try payload(alone).sessionIDs, ["chat2"], "An unmarked row drags only itself")

        model.selectedID = "chat1"
        model.extendSessionMarks(to: "chat3")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2", "chat3"])
        XCTAssertEqual(try payload(try XCTUnwrap(source("chat2").dragItem())).sessionIDs, ["chat1", "chat2", "chat3"],
                       "A marked row drags every marked chat of its project")
        model.toggleSessionMark("chat2")
        XCTAssertEqual(try payload(try XCTUnwrap(source("chat2").dragItem())).sessionIDs, ["chat2"],
                       "Unmarking a row takes it out of the marked drag again")
        // Nothing may reach the pasteboard that a drop would refuse.
        XCTAssertNil(TopicSessionDrag(sessionID: "", workspaceID: "project").pasteboardItem())
        let image = try XCTUnwrap(source("chat2").dragImage(), "A drag with no image is the bug the owner reported")
        XCTAssertGreaterThan(image.size.width, 0); XCTAssertGreaterThan(image.size.height, 0)
        await model.store?.close()
    }

    @MainActor func testTheSurfaceTakesThePlainPressAndLeavesEveryOtherOneToTheRow() throws {
        XCTAssertTrue(TopicSessionDragSurfaceView.claims(try press(.leftMouseDown)))
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try press(.leftMouseDown, modifiers: .control)),
                       "Control-click must reach the row so its context menu opens")
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try press(.rightMouseDown)), "Right-click belongs to the context menu")
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try press(.otherMouseDown)))
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try press(.leftMouseDragged)),
                       "Hover, tooltips, scrolling and a drag in flight carry no press of ours")

        // The row's own buttons keep their presses: the surface cuts them out.
        let chevron = CGRect(x: 180, y: 6, width: 18, height: 18)
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(CGPoint(x: 185, y: 12), controls: [chevron]),
                       "Folding a row's side chats is still a button press")
        XCTAssertTrue(TopicSessionDragSurfaceView.claims(CGPoint(x: 60, y: 12), controls: [chevron]))
        XCTAssertTrue(TopicSessionDragSurfaceView.claims(CGPoint(x: 185, y: 12), controls: []))

        XCTAssertFalse(TopicSessionDragSurfaceView.startsDrag(from: .zero, to: CGPoint(x: 3, y: 3)), "A shaky click still selects")
        XCTAssertTrue(TopicSessionDragSurfaceView.startsDrag(from: .zero, to: CGPoint(x: 0, y: -4)), "A deliberate pull drags at once")

        // The second press renames; the first one already selected the row.
        let view = TopicSessionDragSurfaceView()
        var renames = 0, clicks: [NSEvent.ModifierFlags] = []
        view.actions = TopicSessionRowActions(click: { clicks.append($0) }, doubleClick: { renames += 1 })
        view.mouseDown(with: try press(.leftMouseDown, clickCount: 2))
        XCTAssertEqual(renames, 1); XCTAssertTrue(clicks.isEmpty, "A rename must not also re-select through the click path")

        XCTAssertEqual(TopicSessionDragSurfaceView.operationMask(for: .withinApplication), [.move, .copy, .generic])
        XCTAssertEqual(TopicSessionDragSurfaceView.operationMask(for: .outsideApplication), [],
                       "A chat is never offered to another application")
    }

    @MainActor func testClickRoutingKeepsShiftRangesCommandMarksAndPlainOpening() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(root, chats: (1...3).map { chat("chat\($0)", order: Int64($0)) })
        defer { model.shutdown() }
        XCTAssertEqual(SidebarRowClick(modifiers: [.shift, .command]), .extendMarks, "Shift wins, as a file list does")
        XCTAssertEqual(SidebarRowClick(modifiers: .command), .toggleMark)
        XCTAssertEqual(SidebarRowClick(modifiers: .option), .open, "Only Shift and Command mean marking")

        var opened = 0
        func click(_ modifiers: NSEvent.ModifierFlags, on id: String) {
            SidebarRowClick(modifiers: modifiers).apply(to: model, sessionID: id) { opened += 1 }
        }
        model.selectedID = "chat1"
        click(.shift, on: "chat3")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2", "chat3"]); XCTAssertEqual(opened, 0)
        click(.command, on: "chat3")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2"]); XCTAssertEqual(opened, 0)
        click([], on: "chat3")
        XCTAssertTrue(model.markedChats.isEmpty, "An ordinary click drops the marks")
        XCTAssertEqual(opened, 1, "An ordinary click still opens the chat")
        await model.store?.close()
    }

    @MainActor func testAWholeGroupAcceptsTheDropIntoItsTopicAndBackToTheProjectRoot() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await makeModel(root, chats: [chat("first", order: 1), chat("second", order: 2)])
        defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Destination")

        let marked = [TopicSessionDrag(sessionIDs: ["first", "second"], workspaceID: "project").provider()]
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(marked, model: model, projectID: "project", topicID: topic.id))
        try await settle { model.record("first")?.topicID == topic.id && model.record("second")?.topicID == topic.id }

        // The project's own area is the way back out of a topic.
        let one = [TopicSessionDrag(sessionID: "first", workspaceID: "project").provider()]
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(one, model: model, projectID: "project", topicID: nil))
        try await settle { model.record("first")?.topicID == nil }
        XCTAssertEqual(model.record("second")?.topicID, topic.id, "Only what was dropped moves")

        let foreign = [TopicSessionDrag(sessionID: "second", workspaceID: "other").provider()]
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(foreign, model: model, projectID: "project", topicID: topic.id))
        try await settle { model.error != nil }
        XCTAssertEqual(model.record("second")?.topicID, topic.id, "A chat from another project cannot be dropped here")
        await model.store?.close()
    }
}


/// A drag in flight, as the sidebar sees one. AppKit's own session cannot run
/// in a test process, so the hosted sidebar is asked what it would do with the
/// very pasteboard item a dragged row writes.
@MainActor private final class DragInFlight: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .drag)
    var draggingLocation: NSPoint = .zero
    init(_ item: NSPasteboardItem) {
        draggingPasteboard.clearContents(); draggingPasteboard.writeObjects([item])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { return }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() { }
}

/// What the hosted sidebar really offers a pointer: how much of it takes a
/// drop, and which part of a row starts a drag. Whether a drop then moves the
/// chats is covered at the model level in SidebarRowDragTests — a synthetic
/// drag has no session for SwiftUI to complete against.
final class SidebarDropZoneTests: XCTestCase {
    /// A project with one topic of five chats and five more at its root, hosted
    /// the way the sidebar hosts it.
    @MainActor private func sidebar() throws -> (model: WorkspaceModel, hosted: NSView, project: WorkspaceRecord, root: URL) {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]; model.selectedWorkspaceID = project.id
        model.topics = [TopicRecord(id: "topic", workspaceID: project.id, title: "Destination")]
        var chats: [ChatRecord] = []
        for index in 0..<5 {
            var grouped = ChatRecord(id: "in\(index)", workspaceID: project.id, title: "Grouped \(index)", path: nil,
                                     profileID: "fixture", sidebarOrder: Int64(100 - index))
            grouped.topicID = "topic"
            chats.append(grouped)
            chats.append(ChatRecord(id: "out\(index)", workspaceID: project.id, title: "Loose \(index)", path: nil,
                                    profileID: "fixture", sidebarOrder: Int64(50 - index)))
        }
        model.chats = chats
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ProjectSidebarGroup(model: model, project: project, available: true, name: "Project")
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        let hosted = try XCTUnwrap(window.contentView)
        hosted.layoutSubtreeIfNeeded()
        return (model, hosted, project, root)
    }

    @MainActor func testATopicAndItsProjectTakeADropAcrossTheirRowsNotJustTheirHeaders() throws {
        let (model, hosted, project, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        // Every view the sidebar registered for a drop, front to back, which is
        // the order AppKit itself offers a drag to them.
        func zones(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { zones($0) } + (view.registeredDraggedTypes.isEmpty ? [] : [view])
        }
        let dropZones = zones(hosted).map { (view: $0, frame: $0.convert($0.bounds, to: hosted)) }
        XCTAssertEqual(dropZones.count, model.chats.count + 2, "Session reorder targets coexist with project and topic targets")
        let groupZones = dropZones.filter { $0.frame.height > 100 }
        XCTAssertEqual(groupZones.count, 2, "Both group drop targets must extend beyond a single session row")
        let topic = try XCTUnwrap(groupZones.min { $0.frame.height < $1.frame.height })
        let wholeProject = try XCTUnwrap(groupZones.max { $0.frame.height < $1.frame.height })
        XCTAssertGreaterThan(topic.frame.height, 150,
                             "A topic's header strip is about thirty points tall: its drop zone must reach its chat rows")
        XCTAssertEqual(wholeProject.frame.height, hosted.bounds.height, accuracy: 1,
                       "The project's whole group takes a drop, not only its header strip")

        // The sidebar accepts the payload a dragged row writes, over a topic's
        // own rows and over the project's rows below every topic.
        let drag = DragInFlight(try XCTUnwrap(TopicSessionDrag(sessionIDs: ["out0", "out1"], workspaceID: project.id).pasteboardItem()))
        for zone in [topic, wholeProject] {
            drag.draggingLocation = hosted.convert(CGPoint(x: zone.frame.midX, y: zone.frame.maxY - 8), to: nil)
            let answer = zone.view.draggingEntered(drag)
            XCTAssertEqual(answer, .copy, "A group must light up for chats of its own project")
            XCTAssertTrue(TopicSessionDragSurfaceView.operationMask(for: .withinApplication).contains(answer),
                          "A dragged row must allow the operation its destination answers with")
            zone.view.draggingExited(drag)
        }
        // Nothing else on the pasteboard is a chat move.
        let text = NSPasteboardItem(); text.setString("chat", forType: .string)
        let plain = DragInFlight(text)
        plain.draggingLocation = drag.draggingLocation
        XCTAssertEqual(topic.view.draggingEntered(plain), [], "Dropped text is not a chat")
        topic.view.draggingExited(plain)
        NSPasteboard(name: .drag).clearContents()
    }

    @MainActor func testEveryChatRowCarriesADragSurfaceThatCutsOutItsOwnButtons() throws {
        let (model, hosted, _, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        func surfaces(_ view: NSView) -> [TopicSessionDragSurfaceView] {
            (view as? TopicSessionDragSurfaceView).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
        }
        let rows = surfaces(hosted)
        XCTAssertGreaterThanOrEqual(rows.count, 10, "Every listed chat row is draggable")
        for row in rows {
            XCTAssertGreaterThan(row.bounds.width, 100, "The surface covers the row it drags")
            let controls = try XCTUnwrap(row.controls.isEmpty ? nil : row.controls,
                                         "A row publishes where its own buttons are, or the surface would swallow them")
            for control in controls {
                XCTAssertTrue(row.bounds.contains(control), "\(control) is not inside \(row.bounds)")
                XCTAssertGreaterThan(control.midX, row.bounds.midX, "The row's buttons sit at its trailing edge")
            }
            let button = try XCTUnwrap(controls.first)
            XCTAssertFalse(TopicSessionDragSurfaceView.claims(CGPoint(x: button.midX, y: button.midY), controls: controls))
            XCTAssertTrue(TopicSessionDragSurfaceView.claims(CGPoint(x: row.bounds.midX / 2, y: row.bounds.midY), controls: controls))
        }
    }
}
