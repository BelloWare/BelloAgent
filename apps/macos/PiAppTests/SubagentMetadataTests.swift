import XCTest
@testable import PiApp

final class SubagentMetadataTests: XCTestCase {
    private let child = """
    {"id":"child","workspaceID":"project","title":"Task","profileID":"profile","parentSessionID":"parent",
     "delegation":{"version":1,"delegationID":"delegation","childSessionID":"child","budgetOwnerSessionID":"parent",
       "call":{"parentSessionID":"parent","assistantMessageID":"reply","toolCallID":"call"},
       "parentTurnID":"turn","parentExecutionID":"execution","depth":1}}
    """

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

    func testDamagedDeletionIntentCannotDisappearFromRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.put(["ownerID":"parent"], kind: SessionDeletionRecord.kind, id: "damaged")
        do { _ = try await store.pendingFamilyDeletions(); XCTFail("Recovery silently omitted a durable intent") } catch { }
        await store.close()
    }
}
