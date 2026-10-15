import XCTest
@testable import PiApp

final class SubagentMetadataTests: XCTestCase {
    private let child = """
    {"id":"child","workspaceID":"project","title":"Task","profileID":"profile","parentSessionID":"parent",
     "delegation":{"version":1,"delegationID":"delegation","childSessionID":"child","budgetOwnerSessionID":"parent",
       "call":{"parentSessionID":"parent","assistantMessageID":"reply","toolCallID":"call"},
       "parentTurnID":"turn","parentExecutionID":"execution","depth":1}}
    """

    func testPersistedBudgetProjectionHonorsForkDeletionDamageAndProjectBoundaries() async throws {
        let root = URL(fileURLWithPath:scratchBase()).appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url:root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at:root) }
        func side(_ id: String, _ parent: String, workspace: String = "project", fork: Bool = false) -> ChatRecord {
            ChatRecord(id:id,workspaceID:workspace,title:id,path:"/fixture/" + (fork ? "fork_" : "side_") + id + ".jsonl",profileID:"profile",parentSessionID:parent)
        }
        let main = ChatRecord(id:"main",workspaceID:"project",title:"Main",profileID:"profile")
        let records = [main,side("side","main"),side("nested","side"),side("fork","main",fork:true),side("fork-side","fork"),
            side("foreign","main",workspace:"elsewhere"),side("cycle-a","cycle-b"),side("cycle-b","cycle-a"),side("damaged-child","damaged")]
        try await store.putChats(records)
        try await store.put("undecodable chat",kind:"chat",id:"damaged")
        var projection = try await store.sideBudgetAncestry()
        XCTAssertEqual(projection["project"]?["nested"],["side","main"])
        XCTAssertEqual(projection["project"]?["fork"],[])
        XCTAssertEqual(projection["project"]?["fork-side"],["fork"])
        XCTAssertEqual(projection["elsewhere"]?["foreign"],[])
        XCTAssertNil(projection["project"]?["cycle-a"]); XCTAssertNil(projection["project"]?["cycle-b"])
        XCTAssertNil(projection["project"]?["damaged-child"],"Unreadable metadata is not evidence of deletion")
        try await store.put("deleted",kind:"session-deleted",id:"main")
        projection = try await store.sideBudgetAncestry()
        XCTAssertEqual(projection["project"]?["side"],[])
        XCTAssertEqual(projection["project"]?["nested"],["side"])
        XCTAssertEqual(projection["project"]?["fork-side"],["fork"])
        await store.close()
    }

    func testManagedIdentitySurvivesMetadataRoundTrip() throws {
        let record = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let link = try XCTUnwrap(saved["delegation"] as? [String: Any])
        XCTAssertEqual(link["budgetOwnerSessionID"] as? String, "parent")
        XCTAssertEqual(link["childSessionID"] as? String, "child")
    }

    func testOldMetadataUpdateCannotEraseManagedIdentity() throws {
        let previous = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        let old = ChatRecord(id: "child", workspaceID: "project", title: "Task", profileID: "profile")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old.merged(over: previous))) as? [String: Any])
        XCTAssertNotNil(saved["delegation"])
    }

    func testManagedChildrenCannotHideTheirParentBehindTheMetadataWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        var owner = ChatRecord(id: "parent", workspaceID: "project", title: "Parent", profileID: "profile")
        owner.sidebarOrder = 1
        var records = [owner]
        for index in 0..<10_001 {
            var record = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
            record.id = UUID().uuidString; record.delegation?.childSessionID = record.id
            record.delegation?.delegationID = "delegation-\(index)"; record.delegation?.call.toolCallID = "call-\(index)"
            record.sidebarOrder = Int64(index + 2); records.append(record)
        }
        try await store.putChats(records)
        let loaded = try await store.loadChats()
        XCTAssertEqual(loaded.count, records.count)
        XCTAssertTrue(loaded.contains { $0.id == owner.id })
        let unlisted = await store.unlistedChats
        XCTAssertEqual(unlisted, 0)
        await store.close()
    }

    func testDeletionRecoveryReadsEveryAcceptedFamilyMember() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let members = [SessionDeletionRecord(id: "parent", ownerID: "parent", workspaceID: "project")]
            + (0..<10_001).map { _ in SessionDeletionRecord(id: UUID().uuidString, ownerID: "parent", workspaceID: "project") }
        try await store.beginFamilyDeletion(members)
        let restored = try await store.pendingFamilyDeletions()
        XCTAssertEqual(restored.count, members.count)
        XCTAssertTrue(Set(members.map(\.id)).isSubset(of: Set(restored.map(\.id))))
        await store.close()
    }

    func testOrdinaryChatsKeepTheirExistingMetadataWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let records = (0..<10_002).map { ChatRecord(id: "ordinary-\($0)", workspaceID: "project", title: "Chat", profileID: "profile", sidebarOrder: Int64($0)) }
        try await store.putChats(records)
        let loaded = try await store.loadChats(), unlisted = await store.unlistedChats
        XCTAssertEqual(loaded.count, 10_000); XCTAssertEqual(unlisted, 2)
        XCTAssertFalse(loaded.contains { $0.id == "ordinary-0" || $0.id == "ordinary-1" })
        await store.close()
    }

    func testListedSidesAndManagedChildrenRetainBudgetAncestorsOutsideTheRootWindow() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let main = ChatRecord(id: "main", workspaceID: "project", title: "Main", profileID: "profile", sidebarOrder: 1)
        let side = ChatRecord(id: "side", workspaceID: "project", title: "Side", path: "/fixture/side_side.jsonl", profileID: "profile", sidebarOrder: 2, parentSessionID: "main")
        let unrelated = ChatRecord(id: "unrelated", workspaceID: "project", title: "Unrelated", profileID: "profile", sidebarOrder: 3)
        let nested = ChatRecord(id: "nested", workspaceID: "project", title: "Nested", path: "/fixture/side_nested.jsonl", profileID: "profile", sidebarOrder: 20_001, parentSessionID: "side")
        let fork = ChatRecord(id: "fork", workspaceID: "project", title: "Fork", path: "/fixture/fork_fork.jsonl", profileID: "profile", sidebarOrder: 20_002, parentSessionID: "unrelated")
        var agent = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        agent.parentSessionID = "side"; agent.delegation?.budgetOwnerSessionID = "side"; agent.delegation?.call.parentSessionID = "side"
        var records = [main, side, unrelated]
        records += (0..<10_000).map { ChatRecord(id: "ordinary-\($0)", workspaceID: "project", title: "Chat", profileID: "profile", sidebarOrder: Int64($0 + 4)) }
        records += [nested, fork, agent]
        try await store.putChats(records)
        let loaded = try await store.loadChats(), ids = Set(loaded.map(\.id))
        XCTAssertTrue(Set(["main", "side", "nested", "fork", "child"]).isSubset(of: ids))
        XCTAssertFalse(ids.contains("unrelated"), "A fork's source is not its budget owner")
        XCTAssertEqual(loaded.count, 10_003, "Keep the existing ordinary window plus its required ancestors and managed children")
        let unlisted = await store.unlistedChats
        XCTAssertEqual(unlisted, records.count - loaded.count)
        await store.close()
    }

    func testAncestorRecoveryHonorsDeletionProjectAndForkBoundaries() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let main = ChatRecord(id: "main", workspaceID: "project", title: "Main", profileID: "profile")
        let side = ChatRecord(id: "side", workspaceID: "project", title: "Side", path: "/fixture/side_side.jsonl", profileID: "profile", parentSessionID: "main")
        let dead = ChatRecord(id: "dead", workspaceID: "project", title: "Deleted", profileID: "profile")
        try await store.putChats([main, side, dead])
        try await store.put("dead", kind: "session-deleted", id: "dead")
        var agent = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        agent.parentSessionID = "side"; agent.delegation?.budgetOwnerSessionID = "side"; agent.delegation?.call.parentSessionID = "side"
        let foreign = ChatRecord(id: "foreign", workspaceID: "other", title: "Foreign", path: "/fixture/side_foreign.jsonl", profileID: "profile", parentSessionID: "main")
        let orphan = ChatRecord(id: "orphan", workspaceID: "project", title: "Orphan", path: "/fixture/side_orphan.jsonl", profileID: "profile", parentSessionID: "dead")
        let fork = ChatRecord(id: "fork", workspaceID: "project", title: "Fork", path: "/fixture/fork_fork.jsonl", profileID: "profile", parentSessionID: "dead")
        let restored = try await store.loadBudgetAncestors(of: [agent, orphan, fork, foreign])
        XCTAssertEqual(Set(restored.map(\.id)), ["main", "side"])
        let durable = try await store.get(ChatRecord.self, kind: "chat", id: main.id)
        XCTAssertNotNil(durable?.sidebarOrder, "An ancestor receives the same stable metadata migration as a listed root")
        let repeated = try await store.loadBudgetAncestors(of: [agent, orphan, fork, foreign] + restored)
        XCTAssertTrue(repeated.isEmpty)
        await store.close()
    }

    func testDamagedDeletionIntentCannotDisappearFromRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.put(["ownerID":"parent"], kind: SessionDeletionRecord.kind, id: "damaged")
        do { _ = try await store.pendingFamilyDeletions(); XCTFail("Recovery silently omitted a durable intent") } catch { }
        await store.close()
    }
}
