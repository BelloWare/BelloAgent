import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Hands an AppKit value to a main-queue block the compiler cannot prove is
/// isolated; every use below runs back on the main actor.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The sidebar as a pointer meets it: a real window, real rows, real presses.
/// `SidebarRowDragTests` covers what a press decides; this covers whether the
/// press, the hover and the cursor reach the row at all once an AppKit drag
/// surface sits on top of it.
final class SidebarInteractionTests: XCTestCase {
    // MARK: Fixture

    @MainActor private struct Fixture {
        let model: WorkspaceModel
        let window: NSWindow
        let hosted: NSView
        let root: URL
        func teardown() {
            window.contentView = nil
            window.close()
            model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-interaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor private func fixture(chats: [ChatRecord], topics: [TopicRecord] = [], width: CGFloat = 280,
                                   height: CGFloat = 900) throws -> Fixture {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]
        model.selectedWorkspaceID = project.id
        model.topics = topics
        model.chats = chats
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectSidebarGroup(model: model, project: project, available: true, name: "Project")
            .frame(width: width, alignment: .leading)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        let hosted = try XCTUnwrap(window.contentView)
        hosted.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return Fixture(model: model, window: window, hosted: hosted, root: root)
    }

    private func chat(_ id: String, order: Int64, title: String? = nil, archived: Bool = false,
                      topic: String? = nil, parent: String? = nil) -> ChatRecord {
        var record = ChatRecord(id: id, workspaceID: "project", title: title ?? id.capitalized, path: nil,
                                profileID: "fixture", sidebarOrder: 1_000 - order)
        record.topicID = topic
        record.parentSessionID = parent
        if archived { record.archivedAt = Date() }
        return record
    }

    /// SwiftUI defers its invalidation to a run-loop pass a test never reaches,
    /// so the frame is asked for directly.
    @MainActor private func settle(_ fixture: Fixture) {
        fixture.hosted.needsLayout = true
        fixture.hosted.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
    }

    /// Anything a previous press left behind would arrive inside the next one.
    @MainActor private func drain() {
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil { }
    }

    @MainActor private func surfaces(_ view: NSView) -> [TopicSessionDragSurfaceView] {
        (view as? TopicSessionDragSurfaceView).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
    }

    // MARK: The press surface

    /// A press with no motion is a click. Nothing in the suite ever drove the
    /// tracking loop with a real mouse-up, only the double-click shortcut.
    @MainActor func testAPlainPressAndReleaseSelectsTheRowThroughTheTrackingLoop() throws {
        drain()
        let view = TopicSessionDragSurfaceView()
        var clicks: [NSEvent.ModifierFlags] = [], renames = 0
        view.actions = TopicSessionRowActions(click: { clicks.append($0) }, doubleClick: { renames += 1 })
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        view.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertEqual(clicks, [[]], "A press that never moves is the click the row has always handled")
        XCTAssertEqual(renames, 0)

        // The modifiers of the press, not of the release, decide what it means.
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        view.mouseDown(with: try mouse(.leftMouseDown, modifiers: .shift))
        XCTAssertEqual(clicks.last, .shift, "Shift-press must still extend the marked range")
    }

    /// A press whose mouse-up never arrives — the window deactivates, a sheet
    /// takes over, the row is torn down under the pointer — used to wait on
    /// `.distantFuture` with the main thread held.
    @MainActor func testAPressWhoseReleaseNeverArrivesCannotWedgeTheMainThread() throws {
        drain()
        let view = TopicSessionDragSurfaceView()
        var clicks = 0
        view.actions = TopicSessionRowActions(click: { _ in clicks += 1 })
        // One drag below the threshold and then nothing at all: no release, no
        // pressed button. The loop has to give the main thread back. A rescue
        // release a second later keeps a wedged loop from hanging the suite —
        // reaching it at all is the failure.
        NSApp.postEvent(try mouse(.leftMouseDragged, at: CGPoint(x: 1, y: 1)), atStart: false)
        let rescue = Unchecked(try mouse(.leftMouseUp))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { NSApp.postEvent(rescue.value, atStart: false) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        view.mouseDown(with: try mouse(.leftMouseDown))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF sidebar abandoned press released the main thread after %.1f ms", elapsed * 1_000))
        XCTAssertLessThan(elapsed, 0.6, "An abandoned press must not hold the main thread until a release that never comes")
        XCTAssertEqual(clicks, 0, "A press that was never released must not select anything")
        drain()
    }

    /// The row can be rebuilt or removed while the button is held: a chat
    /// deleted from elsewhere, the archive filter flipping, a topic collapsing.
    /// Nothing may act on it afterwards.
    @MainActor func testAPressOnARowThatLeavesItsWindowDoesNotSelectOnRelease() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TopicSessionDragSurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(view)
        var clicks = 0
        view.actions = TopicSessionRowActions(click: { _ in clicks += 1 })
        // The loop consumes this one, then waits — which is when the main queue
        // drains, the row goes away and the button finally comes up.
        NSApp.postEvent(try mouse(.leftMouseDragged, at: CGPoint(x: 1, y: 1)), atStart: false)
        let torn = Unchecked((view: view, release: try mouse(.leftMouseUp)))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { torn.value.view.removeFromSuperview(); NSApp.postEvent(torn.value.release, atStart: false) }
        }
        view.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertEqual(clicks, 0, "A row torn down under the pointer must not open a chat when the button comes up")
        drain()
        window.close()
    }

    // MARK: Cursor

    /// Every `NSCursor.push` needs exactly one `pop`. A window that closes under
    /// the pointer used to leave the open hand on screen for the whole app.
    @MainActor func testTheRowCursorIsBalancedWhenTheWindowClosesUnderThePointer() throws {
        let sentinel = NSCursor.crosshair
        sentinel.push()
        defer { NSCursor.pop() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TopicSessionDragSurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        view.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertTrue(SidebarRowCursor.shared.isPushed, "A hovered draggable row shows the open hand")
        window.close()
        XCTAssertFalse(SidebarRowCursor.shared.isPushed,
                       "Closing the window under a hovered row must not strand the open hand on every other surface")
        XCTAssertFalse(NSCursor.current === NSCursor.openHand, "The open hand is gone with the window it belonged to")
    }

    /// A row removed from the sidebar while the pointer sits on it: deleting a
    /// chat, scrolling it out of a lazy stack, switching the archive filter.
    @MainActor func testTheRowCursorIsBalancedWhenTheRowIsRemovedUnderThePointer() throws {
        let sentinel = NSCursor.crosshair
        sentinel.push()
        defer { NSCursor.pop() }
        _ = sentinel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TopicSessionDragSurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(view)
        view.mouseEntered(with: try crossing(.mouseEntered))
        view.removeFromSuperview()
        XCTAssertFalse(SidebarRowCursor.shared.isPushed, "A deleted row takes its cursor with it")
        XCTAssertFalse(NSCursor.current === NSCursor.openHand)
        // A late exit for a row that is already gone must not pop somebody else's.
        view.mouseExited(with: try crossing(.mouseExited))
        XCTAssertEqual(NSCursor.current, sentinel, "A late exit must not pop a cursor this row no longer owns")
        window.close()
    }

    // MARK: Hosted rows

    /// The archive button, the confirm/cancel pair and the side chevron are cut
    /// out of the drag surface by measured bounds. They have to stay cut out
    /// after the row re-renders with different controls and after a resize.
    @MainActor func testRowControlCutOutsFollowTheRowThroughRerendersAndResizes() throws {
        var chats = (0..<4).map { chat("chat\($0)", order: Int64($0)) }
        chats.append(chat("child", order: 9, parent: "chat0"))
        let fixture = try fixture(chats: chats)
        defer { fixture.teardown() }

        func cutOuts() -> [(view: TopicSessionDragSurfaceView, controls: [CGRect])] {
            surfaces(fixture.hosted).map { ($0, $0.controls) }
        }
        let initial = cutOuts()
        XCTAssertEqual(initial.count, 5, "Every listed chat row carries a drag surface")
        for row in initial {
            XCTAssertFalse(row.controls.isEmpty, "A row publishes where its own buttons are")
            for control in row.controls {
                XCTAssertTrue(row.view.bounds.insetBy(dx: -1, dy: -1).contains(control),
                              "\(control) escaped the row it belongs to \(row.view.bounds)")
            }
        }

        // A child row is indented; its cut-outs must be measured in its own
        // coordinates, not the parent's.
        let indented = try XCTUnwrap(initial.min { $0.view.bounds.width < $1.view.bounds.width })
        let widest = try XCTUnwrap(initial.max { $0.view.bounds.width < $1.view.bounds.width })
        XCTAssertLessThan(indented.view.bounds.width, widest.view.bounds.width, "A child row is narrower than its parent")
        for control in indented.controls {
            XCTAssertTrue(indented.view.bounds.insetBy(dx: -1, dy: -1).contains(control),
                          "An indented row's cut-out \(control) must stay inside \(indented.view.bounds)")
        }

        // Narrowing the sidebar moves every trailing control. The surfaces must
        // follow, or the buttons stop responding at the new width.
        fixture.window.setContentSize(NSSize(width: 200, height: 900))
        settle(fixture)
        for row in cutOuts() {
            XCTAssertFalse(row.controls.isEmpty, "A resized row still publishes its buttons")
            for control in row.controls {
                XCTAssertTrue(row.view.bounds.insetBy(dx: -1, dy: -1).contains(control),
                              "After the resize \(control) is outside \(row.view.bounds)")
                XCTAssertGreaterThan(control.midX, row.view.bounds.midX, "The row's buttons stay at its trailing edge")
            }
        }
    }

    /// The press surface end to end, driven through the application's event
    /// queue: a press on the body of a row is that row's press, and a press on
    /// the row's own buttons is declined so the button SwiftUI drew underneath
    /// gets it. Command marks rather than opens, which routes the same press to
    /// a synchronous answer; the surface passes the press's own modifiers on,
    /// so a mark appearing is proof the surface claimed the press.
    @MainActor func testARealPressMarksFromTheRowBodyAndNeverFromItsOwnButtons() async throws {
        let chats = [chat("parent", order: 1), chat("child", order: 2, parent: "parent"), chat("other", order: 3)]
        let fixture = try fixture(chats: chats)
        defer { fixture.teardown() }
        fixture.model.selectedID = "other"
        XCTAssertEqual(surfaces(fixture.hosted).count, 3, "The parent, its child and the loose chat are listed")

        // The body of an indented child row belongs to that row.
        let indented = try XCTUnwrap(surfaces(fixture.hosted).min { $0.bounds.width < $1.bounds.width })
        try press(at: CGPoint(x: 30, y: indented.bounds.midY), in: indented, fixture: fixture, modifiers: .command)
        XCTAssertEqual(fixture.model.markedSessionIDs, ["other", "child"],
                       "A press on the body of an indented row still reaches the row")

        // Its own buttons do not: pressing them must leave the marks alone.
        let parent = try XCTUnwrap(surfaces(fixture.hosted).max { ($0.controls.first?.width ?? 0) < ($1.controls.first?.width ?? 0) })
        let controls = try XCTUnwrap(parent.controls.first)
        fixture.model.clearSessionMarks()
        try press(at: CGPoint(x: controls.maxX - 8, y: controls.midY), in: parent, fixture: fixture, modifiers: .command)
        XCTAssertTrue(fixture.model.markedSessionIDs.isEmpty, "The chevron is the row's own button, not a press on the row")

        // The body of that same row, a few points to the left of its buttons, is.
        let folded = try XCTUnwrap(surfaces(fixture.hosted).max { ($0.controls.first?.width ?? 0) < ($1.controls.first?.width ?? 0) })
        let after = try XCTUnwrap(folded.controls.first)
        try press(at: CGPoint(x: after.minX - 12, y: after.midY), in: folded, fixture: fixture, modifiers: .command)
        XCTAssertEqual(fixture.model.markedSessionIDs, ["other", "parent"], "The body of a row is the row's press")

        // The cut-outs of a narrowed sidebar are checked in
        // testRowControlCutOutsFollowTheRowThroughRerendersAndResizes; a press
        // after a programmatic resize is not something a test window delivers
        // reliably.

        // A second press in place renames rather than marking again.
        var renames = 0
        folded.actions = TopicSessionRowActions(click: { _ in }, doubleClick: { renames += 1 })
        try press(at: CGPoint(x: 24, y: folded.bounds.midY), in: folded, fixture: fixture, clickCount: 2)
        XCTAssertEqual(renames, 1, "The second press of a double-click renames the row")
        await fixture.model.store?.close()
    }

    /// Control-click and right-click are the context menu, not a press.
    @MainActor func testControlClickReachesTheRowsContextMenuRatherThanTheDragSurface() throws {
        let fixture = try fixture(chats: [chat("only", order: 1)])
        defer { fixture.teardown() }
        let surface = try XCTUnwrap(surfaces(fixture.hosted).first)
        let middle = CGPoint(x: surface.bounds.width / 3, y: surface.bounds.midY)
        let inWindow = surface.convert(middle, to: nil)

        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try mouse(.leftMouseDown, at: inWindow, modifiers: .control)))
        XCTAssertFalse(TopicSessionDragSurfaceView.claims(try mouse(.rightMouseDown, at: inWindow)))
        // With no press of ours in flight the row is what the window would
        // deliver to, and it carries the menu.
        let hit = try XCTUnwrap(viewUnder(middle, in: surface, fixture: fixture))
        XCTAssertFalse(hit === surface)
        XCTAssertNotNil(hit.menu(for: try mouse(.rightMouseDown, at: inWindow, window: fixture.window)),
                        "A right-click on a chat row offers its context menu")
    }

    // MARK: Helpers

    /// A real press and release at a point inside a row, put on the
    /// application's own event queue and pumped from it: dequeueing is what
    /// publishes an event as the current one, which is what a hit test reads.
    /// A surface that claims the press takes the release out of the queue
    /// itself, exactly as it does for a real click.
    @MainActor private func press(at point: CGPoint, in row: NSView, fixture: Fixture,
                                  modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws {
        // A press the surface declines leaves its release for SwiftUI, and a
        // release SwiftUI never took would arrive inside the next press.
        while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil { }
        let inWindow = row.convert(point, to: nil)
        NSApp.postEvent(try mouse(.leftMouseDown, at: inWindow, window: fixture.window,
                                  clickCount: clickCount, modifiers: modifiers), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseUp, at: inWindow, window: fixture.window,
                                  clickCount: clickCount, modifiers: modifiers), atStart: false)
        while let event = NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        settle(fixture)
    }

    @MainActor private func settle(until condition: () -> Bool, fixture: Fixture,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            settle(fixture)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The sidebar never reached the expected state", file: file, line: line)
    }

    /// What the window would deliver a press at this point to.
    @MainActor private func viewUnder(_ point: CGPoint, in row: NSView, fixture: Fixture) -> NSView? {
        fixture.window.contentView?.superview?.hitTest(row.convert(point, to: nil))
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
    @MainActor private func mouse(_ type: NSEvent.EventType, at location: CGPoint = .zero, window: NSWindow? = nil,
                                  clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let number = window?.windowNumber ?? 0
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: number, context: nil, eventNumber: 0,
                                                clickCount: clickCount, pressure: 1))
    }
}

/// What the sidebar lists and what the model thinks it lists have to be the
/// same thing: a Shift range, the marked count and the keyboard step all read
/// the model's order, while the filter and the fold live on screen.
final class SidebarListedOrderTests: XCTestCase {
    @MainActor private struct Fixture {
        let model: WorkspaceModel
        let window: NSWindow
        let hosted: NSView
        let root: URL
        func settle() { hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func teardown() { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func fixture(_ chats: [ChatRecord], topics: [TopicRecord] = [], filter: String = "") throws -> Fixture {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]; model.selectedWorkspaceID = project.id
        model.topics = topics; model.chats = chats
        // The sidebar tells the model what its filter field holds.
        model.sidebarFilter = filter
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectSidebarGroup(model: model, project: project, available: true,
                                                                         name: "Project", filter: filter)
            .frame(width: 280, alignment: .leading)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return Fixture(model: model, window: window, hosted: hosted, root: root)
    }

    private func chat(_ id: String, title: String, order: Int64, topic: String? = nil, parent: String? = nil) -> ChatRecord {
        var record = ChatRecord(id: id, workspaceID: "project", title: title, path: nil, profileID: "fixture",
                                sidebarOrder: 1_000 - order)
        record.topicID = topic; record.parentSessionID = parent
        return record
    }

    @MainActor private func rows(_ view: NSView) -> [TopicSessionDragSurfaceView] {
        (view as? TopicSessionDragSurfaceView).map { [$0] } ?? view.subviews.flatMap { rows($0) }
    }

    /// Filtering, then Shift-clicking the first and last row on screen, used to
    /// mark — and then archive — every chat the filter had hidden in between.
    @MainActor func testAShiftRangeUnderAFilterCoversOnlyTheRowsTheFilterLeftListed() throws {
        let chats = [chat("a1", title: "Alpha one", order: 1), chat("b1", title: "Beta two", order: 2),
                     chat("g1", title: "Gamma three", order: 3), chat("a2", title: "Alpha four", order: 4)]
        let fixture = try fixture(chats, filter: "alpha")
        defer { fixture.teardown() }
        XCTAssertEqual(rows(fixture.hosted).count, 2, "The filter leaves two rows on screen")
        XCTAssertEqual(fixture.model.sidebarChatOrder, ["a1", "a2"], "The listed order is what the filter left")

        fixture.model.selectedID = "a1"
        SidebarRowClick(modifiers: .shift).apply(to: fixture.model, sessionID: "a2") { }
        XCTAssertEqual(fixture.model.markedChats.map(\.id), ["a1", "a2"],
                       "A range drawn over the rows on screen must not reach the chats the filter hid")

        // Clearing the filter brings the whole list back.
        fixture.model.sidebarFilter = ""
        XCTAssertEqual(fixture.model.sidebarChatOrder, ["a1", "b1", "g1", "a2"])
    }

    /// A filter opens every topic on screen. A range drawn across them has to
    /// cover the rows that opening revealed, and nothing else.
    @MainActor func testAFilterOpensTopicsForTheRangeTheSameWayItOpensThemOnScreen() throws {
        let topic = TopicRecord(id: "topic", workspaceID: "project", title: "Billing")
        var folded = topic; folded.expanded = false
        let chats = [chat("t1", title: "Alpha invoice", order: 1, topic: "topic"),
                     chat("t2", title: "Beta invoice", order: 2, topic: "topic"),
                     chat("r1", title: "Alpha receipt", order: 3)]
        let open = try fixture(chats, topics: [folded])
        XCTAssertEqual(open.model.sidebarChatOrder, ["r1"], "A collapsed topic lists nothing")
        open.teardown()

        let filtered = try fixture(chats, topics: [folded], filter: "alpha")
        defer { filtered.teardown() }
        XCTAssertEqual(rows(filtered.hosted).count, 2, "The filter opens the topic and lists both matches")
        XCTAssertEqual(filtered.model.sidebarChatOrder, ["t1", "r1"],
                       "The range covers the rows the filter revealed, in the order they are listed")

        // A topic whose own title matches lists every chat it holds.
        filtered.model.sidebarFilter = "billing"
        XCTAssertEqual(filtered.model.sidebarChatOrder, ["t1", "t2"], "A matching topic lists all of its chats")
    }

    /// "Show 10 more" is a decision about the sidebar too: collapsing the
    /// project and opening it again used to drop back to the first five.
    @MainActor func testTheShownPageSurvivesTheGroupBeingRebuilt() throws {
        let chats = (1...9).map { chat("chat\($0)", title: "Chat \($0)", order: Int64($0)) }
        let fixture = try fixture(chats)
        defer { fixture.teardown() }
        XCTAssertEqual(rows(fixture.hosted).count, SidebarSessionPresentation.pageSize, "The group starts on its first page")

        fixture.model.setSidebarShownRoots("project", to: 15, in: "project")
        fixture.settle()
        XCTAssertEqual(rows(fixture.hosted).count, 9, "Showing more lists the rest")

        fixture.model.setProjectExpanded("project", expanded: false)
        fixture.settle()
        XCTAssertTrue(rows(fixture.hosted).isEmpty)
        fixture.model.setProjectExpanded("project", expanded: true)
        fixture.settle()
        XCTAssertEqual(rows(fixture.hosted).count, 9, "The page is still open when the project comes back")

        // Switching to the archive and back starts at the first page again:
        // it is a different list.
        fixture.model.setProjectArchiveFilter("project", archived: true)
        fixture.model.setProjectArchiveFilter("project", archived: false)
        fixture.settle()
        XCTAssertEqual(rows(fixture.hosted).count, SidebarSessionPresentation.pageSize)
    }

    /// A project reads from the start of its name unless a sibling shares it.
    @MainActor func testAProjectNameTruncatesAtItsTailUnlessASiblingSharesItsOpening() throws {
        XCTAssertFalse(SidebarProject.truncatesInTheMiddle("bello-agent", among: ["bello-agent", "notes", "pi-app"]),
                       "bello-agent has to read as bello-ag…, not be…ent")
        XCTAssertFalse(SidebarProject.truncatesInTheMiddle("api", among: ["api", "apidocs"]),
                       "A name shorter than the shared opening is never ambiguous")
        XCTAssertTrue(SidebarProject.truncatesInTheMiddle("bello-agent", among: ["bello-agent", "bello-agent-old"]),
                      "Two projects that differ only at the end keep their middle truncation")
        XCTAssertFalse(SidebarProject.truncatesInTheMiddle("bello-agent", among: ["bello-agent"]),
                       "A project is not its own ambiguous sibling")

        // Below the threshold the header gives its buttons' room to the name.
        XCTAssertTrue(ProjectSidebarGroup.showsHeaderButtons(at: WindowChrome.sidebarWidth))
        XCTAssertTrue(ProjectSidebarGroup.showsHeaderButtons(at: ProjectSidebarGroup.compactHeaderWidth))
        XCTAssertFalse(ProjectSidebarGroup.showsHeaderButtons(at: WindowChrome.minimumSidebarWidth))
    }

    /// Folding a chat's side chats is a decision about the sidebar, not about
    /// one instance of a group view: collapsing the project and opening it
    /// again used to unfold everything.
    @MainActor func testFoldingAChatsSideChatsSurvivesTheGroupBeingRebuilt() throws {
        let chats = [chat("parent", title: "Parent", order: 1), chat("child", title: "Child", order: 2, parent: "parent"),
                     chat("loose", title: "Loose", order: 3)]
        let fixture = try fixture(chats)
        defer { fixture.teardown() }
        XCTAssertEqual(rows(fixture.hosted).count, 3)

        fixture.model.collapsedSidebarSides.insert("parent")
        fixture.settle()
        XCTAssertEqual(rows(fixture.hosted).count, 2, "The child row folds away")

        // Collapsing the project throws the group away and builds a new one.
        fixture.model.setProjectExpanded("project", expanded: false)
        fixture.settle()
        XCTAssertTrue(rows(fixture.hosted).isEmpty)
        fixture.model.setProjectExpanded("project", expanded: true)
        fixture.settle()
        XCTAssertEqual(rows(fixture.hosted).count, 2, "The fold is still there when the project comes back")

        // Selecting the folded child reveals it again, as it always did.
        fixture.model.selectedID = "child"
        fixture.settle()
        XCTAssertFalse(fixture.model.collapsedSidebarSides.contains("parent"),
                       "Opening a folded child unfolds the branch that hides it")
        XCTAssertEqual(rows(fixture.hosted).count, 3)
    }
}
