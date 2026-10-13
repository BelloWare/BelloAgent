import Foundation
import XCTest
@testable import PiApp

final class SubagentDeletionTests: XCTestCase {
    @MainActor func testDeleteFindsAnUnregisteredChildAndPreventsRediscoveryAndStaleWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let store = try XCTUnwrap(model.store), parent = try XCTUnwrap(model.record("chat-parent"))
        for chat in model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        for suffix in [".meta", ".stream", ".stream-unrestored-fixture"] { try Data("fixture".utf8).write(to: URL(fileURLWithPath: family.path.path + suffix)) }
        var recycled: [URL] = []
        model.familyFileRecycler = { urls in recycled += urls; for url in urls { try FileManager.default.removeItem(at: url) } }
        try await model.deleteSubagentFamily(parent)
        XCTAssertNil(model.record(parent.id)); XCTAssertFalse(FileManager.default.fileExists(atPath: family.path.path))
        XCTAssertTrue(recycled.contains { $0.path == family.path.path + ".meta" })
        XCTAssertEqual(model.record("chat-side")?.parentSessionID, parent.id, "Ordinary sides retain their existing independent deletion policy")
        do { try await store.put(parent, kind: "chat", id: parent.id); XCTFail("Stale parent recreated after deletion") } catch { }
        await model.reconcileSubagents()
        XCTAssertNil(model.record(family.child))
    }
    @MainActor func testPartialDeletionIsDurableAndRetriesWithoutNewAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let store = try XCTUnwrap(model.store), parent = try XCTUnwrap(model.record("chat-parent"))
        for chat in model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        model.familyFileRecycler = { _ in throw StoreError.unavailable }
        do { try await model.deleteSubagentFamily(parent); XCTFail("Injected filesystem failure ignored") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: family.path.path))
        let intents = try await store.list(SessionDeletionRecord.self, kind: SessionDeletionRecord.kind)
        XCTAssertEqual(Set(intents.map(\.id)), Set([parent.id, family.child]))
        model.shutdown()
        try await model.traces.close(); await store.close()
        let reopened = WorkspaceModel(stateRoot: model.root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { reopened.shutdown() }
        let nextStore = try XCTUnwrap(reopened.store)
        reopened.chats = try await nextStore.loadChats()
        try await reopened.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        reopened.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        await reopened.resumeFamilyDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: family.path.path))
        let saved = try await nextStore.get(ChatRecord.self, kind: "chat", id: parent.id)
        XCTAssertNil(saved); XCTAssertNil(reopened.record(parent.id))
    }
    @MainActor func testRunningFamilyCannotBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let parent = try XCTUnwrap(model.record("chat-parent")), view = SessionDisplay(id: "chat-parent")
        view.runState = .running; model.displays[view.id] = view
        do { try await model.deleteSubagentFamily(parent); XCTFail("Running family deleted") } catch { }
    }
    @MainActor func testDeletionRechecksDelegationsAcceptedWhileConfirmationWasOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        var childPath: URL?
        model.questions.answer = { _ in
            childPath = try? SubagentDiscoveryTests.family(model).path
            return true
        }
        model.familyFileRecycler = { urls in for url in urls { try FileManager.default.removeItem(at: url) } }
        model.deleteChat("chat-parent")
        for _ in 0..<200 where model.record("chat-parent") != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.record("chat-parent"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(childPath).path))
        try await model.traces.close(); await model.store?.close()
    }
    func testLateCaptureCannotRecreateDeletedFamilyGroupsOrDeleteAnotherWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let summary = SubagentSummary(link: SubagentTranscriptTests.link, description: "Review", model: "model", status: .running, revision: 1)
        for workspace in ["one", "two"] { try await archive.recordSubagent(summary, workspaceID: workspace) }
        try await archive.forgetSubagentRelationships(sessionID: "chat-parent", workspaceID: "one")
        try await archive.recordSubagent(summary, workspaceID: "one")
        let deleted = try await archive.inspectorSubagents(owner: "chat-parent", workspaceID: "one")
        let retained = try await archive.inspectorSubagents(owner: "chat-parent", workspaceID: "two")
        XCTAssertTrue(deleted.isEmpty); XCTAssertEqual(retained.count, 1)
        try await archive.close()
    }

}
