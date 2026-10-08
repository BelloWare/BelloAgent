import XCTest
import AppKit
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
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
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
        // What a draggable row's surface hands the drag when the press travels
        // (the row is kept, as the list keeps it while it is on screen).
        var rows: [NSView] = []
        defer { _ = rows }
        func source(_ id: String) throws -> TopicSessionRowActions {
            let row = SidebarChatRowView(model: model, chat: try XCTUnwrap(model.record(id)), state: SidebarChatRowState(draggable: true),
                                         projectID: "project", glide: PiKit.SelectionGlide())
            rows.append(row)
            let surface = try XCTUnwrap(row.subviews.compactMap { $0 as? TopicSessionDragSurfaceView }.first, "A draggable row carries a drag surface")
            return surface.actions
        }
        let alone = try XCTUnwrap(try source("chat2").item())
        XCTAssertEqual(alone.types, [NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)],
                       "A chat drag is not also a text or file drop")
        XCTAssertEqual(try payload(alone).sessionIDs, ["chat2"], "An unmarked row drags only itself")

        model.selectedID = "chat1"
        model.extendSessionMarks(to: "chat3")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2", "chat3"])
        XCTAssertEqual(try payload(try XCTUnwrap(try source("chat2").item())).sessionIDs, ["chat1", "chat2", "chat3"],
                       "A marked row drags every marked chat of its project")
        model.toggleSessionMark("chat2")
        XCTAssertEqual(try payload(try XCTUnwrap(try source("chat2").item())).sessionIDs, ["chat2"],
                       "Unmarking a row takes it out of the marked drag again")
        // Nothing may reach the pasteboard that a drop would refuse.
        XCTAssertNil(TopicSessionDrag(sessionID: "", workspaceID: "project").pasteboardItem())
        let image = try XCTUnwrap(try source("chat2").image(), "A drag with no image is the bug the owner reported")
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

        let marked = dragPasteboard([TopicSessionDrag(sessionIDs: ["first", "second"], workspaceID: "project").pasteboardItem()])
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(marked, model: model, projectID: "project", topicID: topic.id))
        try await settle { model.record("first")?.topicID == topic.id && model.record("second")?.topicID == topic.id }

        // The project's own area is the way back out of a topic.
        let one = dragPasteboard([TopicSessionDrag(sessionID: "first", workspaceID: "project").pasteboardItem()])
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(one, model: model, projectID: "project", topicID: nil))
        try await settle { model.record("first")?.topicID == nil }
        XCTAssertEqual(model.record("second")?.topicID, topic.id, "Only what was dropped moves")

        let foreign = dragPasteboard([TopicSessionDrag(sessionID: "second", workspaceID: "other").pasteboardItem()])
        XCTAssertTrue(TopicSessionDrag.acceptSidebarDrop(foreign, model: model, projectID: "project", topicID: topic.id))
        try await settle { model.error != nil }
        XCTAssertEqual(model.record("second")?.topicID, topic.id, "A chat from another project cannot be dropped here")
        await model.store?.close()
    }
}


/// A drop target, written out.
private struct DropTargetCase {
    let projectID: String
    let topicID: String?
    @MainActor var target: SidebarListDocument.DropTarget { .group(projectID: projectID, topicID: topicID) }
}

/// A drag in flight, as a drop target sees one. AppKit's own session cannot
/// run in a test process, so the target is asked what it would do with the
/// very pasteboard item a dragged row writes.
@MainActor final class DragInFlight: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .drag)
    var draggingLocation: NSPoint = .zero
    init(_ item: NSPasteboardItem) {
        draggingPasteboard.clearContents(); draggingPasteboard.writeObjects([item])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    /// Where the drag began, for a target that only takes its own drags.
    var source: AnyObject?
    var draggingSource: Any? { source }
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
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
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
        window.contentView = makeSidebar(model)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.layoutSubtreeIfNeeded()
        return (model, hosted, project, root)
    }

    @MainActor func testATopicAndItsProjectTakeADropAcrossTheirRowsNotJustTheirHeaders() throws {
        let (model, hosted, project, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        // One view takes every drop over the list and decides by where it is.
        let list = try XCTUnwrap((hosted as? WorkspaceSidebarView)?.list)
        XCTAssertFalse(list.registeredDraggedTypes.isEmpty, "The list takes chats dropped on it")
        func frame(_ id: String) throws -> CGRect { try XCTUnwrap(list.frame(of: id), id) }
        let topic = DropTargetCase(projectID: project.id, topicID: "topic")
        let loose = DropTargetCase(projectID: project.id, topicID: nil)
        // A topic's header strip and the gaps between its chat rows: into the topic.
        let topicHeader = CGPoint(x: 40, y: try frame("topic|topic").midY)
        let topicGap = CGPoint(x: 40, y: try frame("chat|in3").maxY + 1)
        XCTAssertGreaterThan(topicGap.y - topicHeader.y, 100, "A topic's drop area reaches well past its header strip, down its rows")
        XCTAssertEqual(list.dropTarget(at: topicHeader), topic.target)
        XCTAssertEqual(list.dropTarget(at: topicGap), topic.target)
        // The project's own rows, and the room under the last: out of any topic.
        let projectGap = CGPoint(x: 40, y: try frame("chat|out2").maxY + 1)
        let underEverything = CGPoint(x: 40, y: list.bounds.maxY - 2)
        XCTAssertEqual(list.dropTarget(at: projectGap), loose.target)
        XCTAssertEqual(list.dropTarget(at: underEverything), loose.target, "The project's whole group takes a drop, not only its header strip")
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: 40, y: try frame("project|" + project.id).midY)), loose.target)
        // Over a row itself: its group. There is no place between two rows
        // to drop on: the sidebar keeps its own order (0.1.122).
        let out1 = try frame("chat|out1"), inside = try frame("chat|in1")
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: 40, y: out1.minY + 2)), loose.target)
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: 40, y: out1.maxY - 2)), loose.target)
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: 40, y: inside.midY)), topic.target)
        // Beside a row, in its indent: the group it sits in, not the row.
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: out1.minX + 2, y: out1.midY)), loose.target)
        let in1 = try frame("chat|in1")
        XCTAssertEqual(list.dropTarget(at: CGPoint(x: in1.minX + 2, y: in1.midY)), topic.target)

        // The sidebar accepts the payload a dragged row writes, over a topic's
        // own rows and over the project's rows below every topic.
        let drag = DragInFlight(try XCTUnwrap(TopicSessionDrag(sessionIDs: ["out0", "out1"], workspaceID: project.id).pasteboardItem()))
        for point in [topicGap, projectGap, underEverything] {
            drag.draggingLocation = list.convert(point, to: nil)
            let answer = list.draggingEntered(drag)
            XCTAssertEqual(answer, .copy, "A group must light up for chats of its own project")
            XCTAssertTrue(TopicSessionDragSurfaceView.operationMask(for: .withinApplication).contains(answer),
                          "A dragged row must allow the operation its destination answers with")
            list.draggingExited(drag)
        }
        drag.draggingLocation = list.convert(CGPoint(x: 40, y: out1.minY + 2), to: nil)
        XCTAssertEqual(list.draggingEntered(drag), .copy, "Over a row, the chats go to its group: there is no place between rows (0.1.122)")
        list.draggingExited(drag)
        // Nothing else on the pasteboard is a chat move.
        let text = NSPasteboardItem(); text.setString("chat", forType: .string)
        let plain = DragInFlight(text)
        plain.draggingLocation = list.convert(topicGap, to: nil)
        XCTAssertEqual(list.draggingEntered(plain), [], "Dropped text is not a chat")
        list.draggingExited(plain)
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

    /// Archive's confirmation is wider than the button it replaces; the drag
    /// surface must leave the whole of it to the row, or pressing Archive
    /// would select the row instead.
    @MainActor func testTheArchiveConfirmationIsCutOutOfTheDragSurfaceAtOnce() throws {
        let (model, hosted, _, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let list = try XCTUnwrap((hosted as? WorkspaceSidebarView)?.list)
        let row = try XCTUnwrap(list.views["chat|out1"] as? SidebarChatRowView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let surface = try XCTUnwrap(descendants(row).compactMap { $0 as? TopicSessionDragSurfaceView }.first)
        let archive = try XCTUnwrap(descendants(row).compactMap { $0 as? PiKit.IconButton }.first { $0.label == "Archive chat" })
        // The press itself, with no display pass after it to tidy up.
        archive.onPress?()
        let confirm = try XCTUnwrap(descendants(row).first { $0.accessibilityIdentifier() == "confirmArchive" && !$0.isHidden })
        let place = confirm.convert(confirm.bounds, to: surface)
        XCTAssertTrue(surface.controls.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(place) },
                      "The confirmation \(place) is not cut out of the surface: \(surface.controls)")
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(CGPoint(x: place.midX, y: place.midY), controls: surface.controls))
        // The row takes the height the confirmation needs, and the rows after it move.
        func placed() throws -> (row: CGRect, next: CGRect) { (try XCTUnwrap(list.frame(of: "chat|out1")), try XCTUnwrap(list.frame(of: "chat|out2"))) }
        let asked = row.entryHeight(width: row.bounds.width)
        XCTAssertEqual(row.frame.height, asked, accuracy: 0.01)
        let open = try placed()
        XCTAssertEqual(open.row.height, asked, accuracy: 0.01)
        XCTAssertEqual(open.next.minY, open.row.maxY + SidebarListContents.rowSpacing, accuracy: 0.01)
        // Leaving the row puts the question away, and the row its height.
        row.body.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertEqual(row.frame.height, row.entryHeight(width: row.bounds.width), accuracy: 0.01)
        let closed = try placed()
        XCTAssertEqual(closed.next.minY, closed.row.maxY + SidebarListContents.rowSpacing, accuracy: 0.01)
    }

    /// While the window is disabled (an install being prepared) the sidebar
    /// takes no press, no drop and offers no enabled control.
    @MainActor func testADisabledWindowLeavesTheSidebarInert() throws {
        let (model, hosted, project, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sidebar = try XCTUnwrap(hosted as? WorkspaceSidebarView)
        let row = try XCTUnwrap(sidebar.list.frame(of: "chat|out1"))
        let point = sidebar.list.convert(CGPoint(x: row.midX, y: row.midY), to: sidebar)
        XCTAssertNotNil(sidebar.hitTest(sidebar.convert(point, to: sidebar.superview)))
        XCTAssertTrue(sidebar.newChat.isEnabled)
        sidebar.inheritedEnabled = false
        XCTAssertNil(sidebar.hitTest(sidebar.convert(point, to: sidebar.superview)), "No press reaches a row")
        XCTAssertFalse(sidebar.newChat.isEnabled); XCTAssertFalse(sidebar.settings.isEnabled); XCTAssertFalse(sidebar.filterField.field.isEnabled)
        let drag = DragInFlight(try XCTUnwrap(TopicSessionDrag(sessionIDs: ["out0"], workspaceID: project.id).pasteboardItem()))
        drag.draggingLocation = sidebar.list.convert(CGPoint(x: row.midX, y: row.midY), to: nil)
        XCTAssertEqual(sidebar.list.draggingEntered(drag), [], "No drop is taken")
        XCTAssertFalse(sidebar.list.performDragOperation(drag))
        // Changes while disabled leave every control in the list disabled.
        func enabledControls() -> [String] {
            func walk(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + walk($0) } }
            return walk(sidebar.list).compactMap { $0 as? NSControl }.filter(\.isEnabled).map { String(describing: type(of: $0)) }
        }
        XCTAssertEqual(enabledControls(), [])
        model.topics[0].title = "Renamed while disabled"
        model.chats[0].title = "Renamed chat while disabled"
        sidebar.settle()
        XCTAssertEqual(enabledControls(), [], "An update re-enabled a control while the window is disabled")
        sidebar.inheritedEnabled = true
        XCTAssertNotNil(sidebar.hitTest(sidebar.convert(point, to: sidebar.superview)))
        XCTAssertTrue(sidebar.newChat.isEnabled)
        XCTAssertEqual(sidebar.list.draggingEntered(drag), .copy, "Enabled again, the list takes the drop into the row's group")
        sidebar.list.draggingExited(drag)
        NSPasteboard(name: .drag).clearContents()
    }

    /// A legacy scroller that comes and goes changes the room the rows have:
    /// they follow the clip view's width both ways.
    @MainActor func testRowsFollowALegacyScrollerComingAndGoing() throws {
        let (model, hosted, _, root) = try sidebar()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sidebar = try XCTUnwrap(hosted as? WorkspaceSidebarView)
        sidebar.scroll.scrollerStyle = .legacy
        // Short enough that the ten chats overflow.
        sidebar.frame.size.height = 300
        sidebar.settle()
        func widths() throws -> (clip: CGFloat, row: CGFloat) {
            sidebar.settle(); sidebar.scroll.layoutSubtreeIfNeeded(); sidebar.settle()
            let row = try XCTUnwrap(sidebar.list.views.first { $0.key.hasPrefix("chat|") }?.value)
            return (sidebar.scroll.contentSize.width, row.frame.width)
        }
        let overflowing = try widths()
        XCTAssertLessThan(overflowing.clip, sidebar.bounds.width, "The legacy scroller takes room")
        XCTAssertEqual(overflowing.row, overflowing.clip - 16, accuracy: 0.01)
        sidebar.setFilter("Loose 1")
        let short = try widths()
        XCTAssertEqual(short.clip, sidebar.bounds.width, accuracy: 0.01, "With nothing to scroll the scroller goes")
        XCTAssertEqual(short.row, short.clip - 16, accuracy: 0.01, "and the rows take its room back")
        sidebar.setFilter("")
        let again = try widths()
        XCTAssertEqual(again.row, again.clip - 16, accuracy: 0.01)
    }

    /// A row whose height changed on screen (its rate arrived and stacked
    /// under the cost) keeps that height once it scrolls out of the list's
    /// range and an unrelated change lays the list out again.
    @MainActor func testAHeightThatChangedOnScreenSurvivesTheRowScrollingAway() throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sidebar-heights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]; model.selectedWorkspaceID = project.id
        model.chats = (0..<80).map { ChatRecord(id: "c\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: "fixture", sidebarOrder: Int64(1_000 - $0)) }
        model.setSidebarShownRoots(project.id, to: 80, in: project.id)
        // Live from the start, nothing billed yet.
        let display = SessionDisplay(id: "c0")
        model.displays["c0"] = display
        let sidebar = makeSidebar(model, width: 200, height: 400)
        let list = sidebar.list
        let before = try XCTUnwrap(list.frame(of: "chat|c0")).height
        // A paused run's cost and rate arrive: the row's entry is the same, its height is not.
        display.state = "paused"
        display.footer.gateway = GatewayTotals(requests: 1, costSamples: 1, costUSD: 12.34)
        display.footer.timing = SessionTimingHistory(samples: [SessionTimingSample(id: "r", wall: Date(), ttftMilliseconds: 200,
                                                                                   streamingMilliseconds: 800, outputTokens: 100, requestMilliseconds: 1_000)])
        sidebar.settle(); list.layoutSubtreeIfNeeded(); sidebar.settle()
        let grown = try XCTUnwrap(list.frame(of: "chat|c0")).height
        XCTAssertGreaterThan(grown, before, "The rate stacks under the cost in a narrow sidebar")
        // Far away, so the row loses its view.
        sidebar.scroll.contentView.scroll(to: CGPoint(x: 0, y: list.bounds.height - sidebar.scroll.contentSize.height))
        sidebar.scroll.reflectScrolledClipView(sidebar.scroll.contentView)
        list.materialize()
        XCTAssertNil(list.views["chat|c0"], "The row is out of the list's range")
        model.chats[60].title = "Renamed far below"
        sidebar.settle()
        let kept = try XCTUnwrap(list.frame(of: "chat|c0")), next = try XCTUnwrap(list.frame(of: "chat|c1"))
        XCTAssertEqual(kept.height, grown, accuracy: 0.01, "The list remembers the height the row had on screen")
        XCTAssertEqual(next.minY, kept.maxY + SidebarListContents.rowSpacing, accuracy: 0.01)
    }
}
