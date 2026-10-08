import XCTest
@testable import PiApp

/// The sidebar's order since 0.1.122: every group newest activity first
/// (the last message, reply or run change), pinned chats on top, a family
/// ranked by its newest member. The reader's own drag order is gone; records
/// saved with one still load, and the rank they carry is ignored.
final class SessionOrderingTests: XCTestCase {
    private func stamp(_ seconds: Double) -> Int64 { Int64(seconds * 1_000_000) }

    func testActivityOrderSurvivesReopenAndStaleWritesAndKeepsFamilies() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("metadata.sqlite"), store=MetadataStore(url:url)
        var rows=(0..<5).map { ChatRecord(id:"s\($0)",workspaceID:"project",title:"Chat \($0)",path:nil,profileID:"p",sidebarOrder:Int64(5-$0)) }
        rows.append(ChatRecord(id:"child",workspaceID:"project",title:"Child",path:nil,profileID:"p",parentSessionID:"s0"))
        rows[rows.count-1].sidebarOrder = 0
        for row in rows { try await store.put(row,kind:"chat",id:row.id) }
        try await store.put(WireValue.object(["id":.string("unreadable"),"workspaceID":.string("project")]),kind:"chat",id:"unreadable")
        // Activity in s3, then s1: s1 is newest, s3 next, then by creation.
        try await store.noteChatActivity(id:"s3",at:stamp(100))
        try await store.noteChatActivity(id:"s1",at:stamp(200))
        try await store.noteChatActivity(id:"s1",at:stamp(150))
        // A copy read before the activity (a path or model write) cannot move it back.
        var stale=rows[1]; stale.model="new-model"; stale.path="/retained/conversation.jsonl"
        try await store.put(stale,kind:"chat",id:stale.id)
        let after=try await store.get(ChatRecord.self,kind:"chat",id:stale.id)
        XCTAssertEqual(after?.lastActivityAt,stamp(200),"activity only moves forward"); XCTAssertEqual(after?.model,"new-model")
        await store.close()
        let reopened=MetadataStore(url:url), saved=try await reopened.loadChats()
        XCTAssertEqual(saved.filter { $0.parentSessionID == nil }.map(\.id),["s1","s3","s0","s2","s4"],"newest activity first, across a reopen")
        XCTAssertEqual(saved.first { $0.id == "child" }?.parentSessionID,"s0")
        await reopened.close()
    }

    /// Records written while the reader could drag chats into an order of
    /// their own carry `manualSidebarOrder`. They load, and the rank is not read.
    func testRecordsWithAManualOrderStillLoadAndTheOrderIsIgnored() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MetadataStore(url:root.appendingPathComponent("metadata.sqlite"))
        // "old" was dragged to the top (rank 0) but is the oldest; "new" has no rank.
        for (id,order,rank) in [("old",Int64(10),Optional(0)),("mid",Int64(20),Optional(1)),("new",Int64(30),nil)] {
            var json = #"{"id":"\#(id)","workspaceID":"p","title":"\#(id)","profileID":"x","toolMode":"editing","imported":false,"sidebarOrder":\#(order)"#
            if let rank { json += #","manualSidebarOrder":\#(rank)"# }
            json += "}"
            try await store.put(try JSONDecoder().decode(WireValue.self,from:Data(json.utf8)),kind:"chat",id:id)
        }
        let loaded=try await store.loadChats()
        XCTAssertEqual(loaded.map(\.id),["new","mid","old"],"the manual rank is ignored")
        let legacy=Data(#"{"id":"old","workspaceID":"p","title":"Old","profileID":"x","toolMode":"editing","imported":false,"manualSidebarOrder":4}"#.utf8)
        let decoded=try JSONDecoder().decode(ChatRecord.self,from:legacy)
        XCTAssertNil(decoded.lastActivityAt); XCTAssertNil(decoded.sidebarOrder)
        let encoded=String(decoding:try JSONEncoder().encode(decoded),as:UTF8.self)
        XCTAssertFalse(encoded.contains("manualSidebarOrder"),"nothing writes the rank again")
        await store.close()
    }

    @MainActor private func model(_ count: Int) async throws -> WorkspaceModel {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        let model=WorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        model.workspaces=[WorkspaceRecord(id:"project",path:root.path,trusted:true)]
        model.chats=(0..<count).map { ChatRecord(id:"s\($0)",workspaceID:"project",title:"Chat \($0)",path:nil,profileID:"p",sidebarOrder:Int64(count-$0)) }
        for row in model.chats { try await model.store?.put(row,kind:"chat",id:row.id) }
        return model
    }
    private func order(_ model: WorkspaceModel) -> [String] {
        MainActor.assumeIsolated { model.sidebarEntries(in:"project",topicID:nil,archived:false,collapsed:[]).map(\.chat.id) }
    }

    /// Activity moves a chat to the top of its group, pinned chats stay on
    /// top, and it touches nothing of a running chat (its run, its draft).
    @MainActor func testActivityMovesAChatUpItsGroupAndPinnedStayOnTop() async throws {
        let model=try await model(4)
        XCTAssertEqual(order(model),["s0","s1","s2","s3"])
        let running=SessionDisplay(id:"s2"); running.state="running"; running.draft="Keep typing"; model.displays[running.id]=running
        model.noteChatActivity("s2",at:Date(timeIntervalSince1970:100))
        XCTAssertEqual(order(model),["s2","s0","s1","s3"])
        XCTAssertEqual(running.state,"running"); XCTAssertEqual(running.draft,"Keep typing")
        try await model.setSessionPinned("s3",pinned:true)
        model.noteChatActivity("s1",at:Date(timeIntervalSince1970:200))
        XCTAssertEqual(order(model),["s3","s1","s2","s0"],"pinned on top, then newest activity")
        model.noteChatActivity("s1",at:Date(timeIntervalSince1970:150))
        XCTAssertEqual(model.record("s1")?.lastActivityAt,Int64(200*1_000_000),"older activity never moves a chat back")
        // Saved: a relaunch lists the same order.
        try await Task.sleep(for:.milliseconds(200))
        let saved=try await model.store?.get(ChatRecord.self,kind:"chat",id:"s1")
        XCTAssertEqual(saved?.lastActivityAt,Int64(200*1_000_000))
        // Next / Previous Chat follow the order on screen.
        model.page = .chats; model.selectedID="s3"
        XCTAssertEqual(model.sidebarChatOrder,["s3","s1","s2","s0"])
    }

    /// A family is as recent as its newest member: a side that just answered
    /// lifts its parent, and stays under it.
    @MainActor func testAFamilyIsAsRecentAsItsNewestMember() async throws {
        let model=try await model(3)
        var child=ChatRecord(id:"c",workspaceID:"project",title:"Side",path:nil,profileID:"p",sidebarOrder:0); child.parentSessionID="s2"
        model.chats.append(child)
        XCTAssertEqual(order(model),["s0","s1","s2","c"])
        model.noteChatActivity("c",at:Date(timeIntervalSince1970:100))
        XCTAssertEqual(order(model),["s2","c","s0","s1"])
    }

    /// While the reader points at the sidebar, has a row's menu open or drags
    /// a row, activity does not move rows; the order catches up when the last
    /// of these ends, or the app goes to the background.
    @MainActor func testActivityDoesNotMoveRowsWhileTheReaderIsReachingForThem() async throws {
        let model=try await model(4)
        model.setSidebarOrderHold(.pointer,true)
        model.noteChatActivity("s3",at:Date(timeIntervalSince1970:100))
        XCTAssertEqual(order(model),["s0","s1","s2","s3"],"the row under the pointer stays where it is")
        XCTAssertEqual(model.record("s3")?.lastActivityAt,Int64(100*1_000_000),"the activity itself is kept")
        model.page = .chats
        XCTAssertEqual(model.sidebarChatOrder,["s0","s1","s2","s3"],"the keyboard steps through what is on screen")
        // A menu opens; the pointer leaves for it: still held.
        model.setSidebarOrderHold(.menu,true); model.setSidebarOrderHold(.pointer,false)
        model.noteChatActivity("s2",at:Date(timeIntervalSince1970:200))
        XCTAssertEqual(order(model),["s0","s1","s2","s3"])
        model.setSidebarOrderHold(.menu,false)
        XCTAssertEqual(order(model),["s2","s3","s0","s1"],"the order catches up once nothing holds it")
        // A drag, then the app goes to the background.
        model.setSidebarOrderHold(.drag,true)
        model.noteChatActivity("s0",at:Date(timeIntervalSince1970:300))
        XCTAssertEqual(order(model),["s2","s3","s0","s1"])
        model.releaseSidebarOrder()
        XCTAssertEqual(order(model),["s0","s2","s3","s1"])
        // An explicit action is not held: the reader asked for it.
        model.setSidebarOrderHold(.pointer,true)
        try await model.setSessionPinned("s1",pinned:true)
        XCTAssertEqual(order(model).first,"s1")
        model.setSidebarOrderHold(.pointer,false)
    }
}

/// What holds the sidebar's order in the views: the pointer over the list,
/// a row's menu for as long as it is open, a row's drag, and nothing once the
/// app is in the background.
final class SidebarOrderHoldViewTests: XCTestCase {
    @MainActor func testThePointerAMenuAndADragHoldTheOrderUntilTheyEnd() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "c", workspaceID: "project", title: "Chat", path: nil, profileID: "p")
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]; model.chats = [chat]
        let list = SidebarListDocument(model: model)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                         context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        list.mouseEntered(with: enter)
        XCTAssertEqual(model.sidebarOrderHolds, [.pointer])
        list.mouseExited(with: exit)
        XCTAssertEqual(model.sidebarOrderHolds, [])

        let row = SidebarChatRowView(model: model, chat: chat, state: SidebarChatRowState(draggable: true), projectID: "project", glide: list.glide)
        list.addSubview(row)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: click))
        XCTAssertEqual(model.sidebarOrderHolds, [.menu], "the order holds while the row's menu is open")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertEqual(model.sidebarOrderHolds, [.menu], "another menu ending does not release it")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(model.sidebarOrderHolds, [], "its menu closing does")

        let surface = try XCTUnwrap(row.subviews.compactMap { $0 as? TopicSessionDragSurfaceView }.first)
        surface.actions.dragging(true)
        XCTAssertEqual(model.sidebarOrderHolds, [.drag])
        surface.actions.dragging(false)
        XCTAssertEqual(model.sidebarOrderHolds, [])

        // The app going to the background lets everything go, held activity included.
        list.mouseEntered(with: enter); surface.actions.dragging(true)
        model.noteChatActivity("c")
        XCTAssertFalse(model.heldActivity.isEmpty)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(model.sidebarOrderHolds, []); XCTAssertTrue(model.heldActivity.isEmpty)
    }

    /// An open side's menu holds the order too; the pointer tracking is for
    /// an app in front only.
    @MainActor func testASidesMenuHoldsTheOrderAndTheListTracksOnlyInFront() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let side = SidebarSideRowView(model: model, state: SidebarSideRowState(id: "s", title: "Side conversation"), glide: PiKit.SelectionGlide())
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(side.menu(for: click))
        XCTAssertEqual(model.sidebarOrderHolds, [.menu])
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(model.sidebarOrderHolds, [])
        // The hold outlives whoever started it (a row let go of while its menu is up).
        // The pointer was over the list when the menu opened and is not when it ends.
        let list = SidebarListDocument(model: model)
        model.setSidebarOrderHold(.pointer, true)
        var owner: SidebarMenuOrderHold? = SidebarMenuOrderHold()
        let orphan = NSMenu()
        owner?.hold(orphan, model: model, list: list)
        owner = nil
        XCTAssertEqual(model.sidebarOrderHolds, [.menu, .pointer])
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: orphan)
        XCTAssertEqual(model.sidebarOrderHolds, [], "its menu ending still releases the order, and the list asks where the pointer is")
        // A drag whose row is let go of before it ends releases the order too.
        let chat = ChatRecord(id: "d", workspaceID: "project", title: "Dragged", path: nil, profileID: "p")
        model.chats = [chat]
        var dragged: SidebarChatRowView? = SidebarChatRowView(model: model, chat: chat, state: SidebarChatRowState(draggable: true), projectID: "project", glide: list.glide)
        list.addSubview(dragged!)
        let surface = try XCTUnwrap(dragged?.subviews.compactMap { $0 as? TopicSessionDragSurfaceView }.first)
        model.setSidebarOrderHold(.pointer, true)
        surface.actions.dragging(true)
        dragged?.removeFromSuperview(); dragged = nil
        XCTAssertEqual(model.sidebarOrderHolds, [.drag, .pointer])
        surface.actions.dragging(false)
        XCTAssertEqual(model.sidebarOrderHolds, [], "the drag's end releases the order and the list asks where the pointer is")
        XCTAssertTrue(SidebarListDocument.pointerTracking.contains(.activeInActiveApp))
        XCTAssertFalse(SidebarListDocument.pointerTracking.contains(.activeAlways), "a pointer over the list of an app in the background holds nothing")
    }

    /// Reading a chat's journal is not activity, even when the chat's state
    /// was known and the journal changes it.
    @MainActor func testAdoptingAJournalIsNotActivity() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "c", workspaceID: "project", title: "Chat", path: nil, profileID: "p", sidebarOrder: 5)
        model.chats = [chat]
        let view = SessionDisplay(id: "c"); view.runStateKnown = true; model.displays["c"] = view
        var page = try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]), "incarnation": .string("i"), "lineage": .string("root"), "older": .null, "newer": .null]))
        page.fromJournal = true
        page.retainedRun = RetainedRun(active: false, runStatus: "cancelled", queuePaused: true, queue: [], unansweredCalls: [])
        model.adoptInitialHistory(page, into: view)
        XCTAssertEqual(view.runState, .paused)
        XCTAssertEqual(model.runHolds["c"]?.state, "paused")
        XCTAssertNil(model.record("c")?.lastActivityAt, "what the journal says happened before does not move the chat")
        // A live change afterwards is activity.
        view.runState = .running
        XCTAssertNotNil(model.record("c")?.lastActivityAt)
    }
}
