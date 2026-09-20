import XCTest
@testable import PiApp

final class SessionOrderingTests: XCTestCase {
    func testManualRanksSurviveReopenStaleBackgroundWritesAndPreserveFamilies() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("metadata.sqlite"), store=MetadataStore(url:url)
        var rows=(0..<5).map { ChatRecord(id:"s\($0)",workspaceID:"project",title:"Chat \($0)",path:nil,profileID:"p",sidebarOrder:Int64(5-$0)) }
        rows.append(ChatRecord(id:"child",workspaceID:"project",title:"Child",path:nil,profileID:"p",parentSessionID:"s0"))
        for row in rows { try await store.put(row,kind:"chat",id:row.id) }
        try await store.put(WireValue.object(["id":.string("unreadable"),"workspaceID":.string("project")]),kind:"chat",id:"unreadable")
        let moved=try await store.reorderChats(["s3","s1"],relativeTo:"s4",after:true,workspaceID:"project")
        XCTAssertEqual(moved.map(\.id),["s0","s2","s4","s1","s3"],"A marked set keeps its sidebar-relative order")
        var stale=rows[1]; stale.model="new-model"; stale.path="/retained/conversation.jsonl"
        try await store.put(stale,kind:"chat",id:stale.id)
        let after=try await store.get(ChatRecord.self,kind:"chat",id:stale.id)
        XCTAssertEqual(after?.manualSidebarOrder,3); XCTAssertEqual(after?.model,"new-model")
        await store.close()
        let reopened=MetadataStore(url:url), saved=try await reopened.loadChats()
        XCTAssertEqual(saved.filter { $0.parentSessionID == nil }.map(\.id),moved.map(\.id))
        XCTAssertEqual(saved.first { $0.id == "child" }?.parentSessionID,"s0")
        let restored=try await reopened.reorderChats(["s3"],relativeTo:"s0",after:false,workspaceID:"project")
        XCTAssertEqual(restored.map(\.id),["s3","s0","s2","s4","s1"])
        await reopened.close()
    }
    func testInvalidCrossGroupSelectionIsAtomicAndLegacyRecordsDecode() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MetadataStore(url:root.appendingPathComponent("metadata.sqlite"))
        let rows=[ChatRecord(id:"a",workspaceID:"p",title:"A",path:nil,profileID:"x"),ChatRecord(id:"b",workspaceID:"p",title:"B",path:nil,profileID:"x"),ChatRecord(id:"foreign",workspaceID:"other",title:"F",path:nil,profileID:"x")]
        for row in rows { try await store.put(row,kind:"chat",id:row.id) }
        for ids in [["a","foreign"],["missing"],["a","a"]] {
            do { _=try await store.reorderChats(ids,relativeTo:"b",after:false,workspaceID:"p"); XCTFail("Invalid selection accepted") } catch { }
        }
        let unchanged=try await store.loadChats()
        XCTAssertTrue(unchanged.allSatisfy { $0.manualSidebarOrder == nil && ($0.organizationRevision ?? 0) == 0 })
        let legacy=Data(#"{"id":"old","workspaceID":"p","title":"Old","profileID":"x","toolMode":"editing","imported":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatRecord.self,from:legacy).manualSidebarOrder)
        await store.close()
    }
    @MainActor func testActualDragProviderReordersSidebarAndPreservesRunningDraft() async throws {
        let root=URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        let model=WorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        model.workspaces=[WorkspaceRecord(id:"project",path:root.path,trusted:true)]
        model.chats=(0..<4).map { ChatRecord(id:"s\($0)",workspaceID:"project",title:"Chat \($0)",path:nil,profileID:"p",sidebarOrder:Int64(4-$0)) }
        for row in model.chats { try await model.store?.put(row,kind:"chat",id:row.id) }
        let running=SessionDisplay(id:"s0"); running.state="running"; running.draft="Keep typing"; model.displays[running.id]=running
        let finished=expectation(description:"drop committed")
        XCTAssertTrue(TopicSessionDrag.accept([TopicSessionDrag(sessionID:"s0",workspaceID:"project").provider()],in:"project") { ids in
            try await model.reorderSessions(ids,relativeTo:"s2",after:true,in:"project"); finished.fulfill()
        } failure: { message in XCTFail(message); finished.fulfill() })
        await fulfillment(of:[finished],timeout:3)
        XCTAssertEqual(model.sidebarChats(in:"project",archived:false).map(\.id),["s1","s2","s0","s3"])
        XCTAssertEqual(running.state,"running"); XCTAssertEqual(running.draft,"Keep typing")
        XCTAssertEqual(model.topicOperationsInFlight,0)
    }
}
