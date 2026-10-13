import Foundation
import XCTest
@testable import PiApp

final class SubagentDiscoveryTests: XCTestCase {
    @MainActor static func family(_ model: WorkspaceModel, accepted: Bool = true, task: String = "Find ambiguous parser tokens") throws -> (child: String, path: URL) {
        var link = SubagentTranscriptTests.link; link.childSessionID = UUID().uuidString
        let directory = model.root.appendingPathComponent("Workspaces/pane-project/Sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = SubagentHeader(link: link, description: "Parser review", model: .init(model: "pane-model"), readOnly: true)
        let origin = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(header))
        func write(_ rows: [[String: WireValue]], to path: URL) throws {
            var data = Data(); for row in rows { data.append(try JSONEncoder().encode(row)); data.append(10) }; try data.write(to: path)
        }
        let parent = directory.appendingPathComponent("chat-parent.jsonl")
        var parentRows: [[String: WireValue]] = [["type":.string("session"), "version":.number(3), "id":.string("chat-parent")]]
        if accepted { parentRows.append(["type":.string("custom"), "customType":.string("pi-app.subagent-call.v1"), "data":.object(["origin":origin, "task":.string(task)])]) }
        try write(parentRows, to: parent)
        model.chats[0].path = parent.path
        let path = directory.appendingPathComponent(link.childSessionID + ".jsonl")
        try write([
            ["type":.string("session"), "version":.number(3), "id":.string(link.childSessionID)],
            ["type":.string("custom"), "id":.string("marker"), "customType":.string("pi-app.native.v2"), "data":.object(["version":.number(2)])],
            ["type":.string("custom"), "id":.string("origin"), "parentId":.string("marker"), "customType":.string("pi-app.subagent-origin.v1"), "data":origin],
            ["type":.string("custom"), "id":.string("terminal"), "parentId":.string("origin"), "customType":.string("pi-app.subagent-terminal.v1"), "data":.object(["delegationID":.string(link.delegationID), "status":.string("completed")])]
        ], to: path)
        return (link.childSessionID, path)
    }
    @MainActor func testLaunchRebuildsUnregisteredChildFromReciprocalJournalsWithoutOpeningAHelper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child))
        XCTAssertEqual(child.delegation?.budgetOwnerSessionID, "chat-parent")
        XCTAssertEqual(child.title, "Parser review")
        XCTAssertTrue(model.sessionOpenings.isEmpty); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: "ambiguous").entries.map(\.id).contains("chat|" + child.id))
        await model.reconcileSubagents()
        XCTAssertEqual(model.chats.filter { $0.id == child.id }.count, 1)
    }
    @MainActor func testQueuedTaskIsSearchableBeyondTheMetadataPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model, task: String(repeating: "context ", count: 2_000) + "raredelegatedtarget")
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        let url = root.appendingPathComponent("search.sqlite")
        let index = ChatSearchIndex(url: url, indexDirectory: root), query = ChatSearchQuery(url: url)
        _ = await index.reconcile(model.sidebarSearch.sources())
        let hits = try await query.search("raredelegatedtarget")
        XCTAssertEqual(hits[family.child]?.messageID, "subagent-task:" + family.child)
        await index.close()
    }

    @MainActor func testUnacceptedOriginsAreQuarantinedAndNeverOpenedForExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model, accepted: false)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child))
        XCTAssertNotNil(child.delegationIssue); XCTAssertNil(child.parentSessionID)
        do { _ = try await model.open(child); XCTFail("Quarantined child opened") } catch { }
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testAChildSymlinkCannotCrossTheProjectDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        let outside = root.appendingPathComponent("foreign.jsonl")
        try FileManager.default.moveItem(at: family.path, to: outside)
        try FileManager.default.createSymbolicLink(at: family.path, withDestinationURL: outside)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        XCTAssertNil(model.record(family.child))
        do { try await model.deleteSubagentFamily(model.chats[0]); XCTFail("Deletion followed a child symlink") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor func testForeignTerminalAndCopiedParentCannotClaimAChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        let text = try String(contentsOf: family.path, encoding: .utf8)
        // Change the terminal only; the immutable origin still names its owner.
        var rows = try text.split(separator: "\n").map { try JSONDecoder().decode([String: WireValue].self, from: Data($0.utf8)) }
        var terminal = try XCTUnwrap(rows[3]["data"]?.object); terminal["delegationID"] = .string("foreign")
        rows[3]["data"] = .object(terminal)
        var bytes = Data(); for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }; try bytes.write(to: family.path)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        XCTAssertEqual(model.subagentSummaries[family.child]?.status, .interrupted)
        let parent = model.chats[0], forkID = "copied-parent"
        var fork = parent; fork.id = forkID
        let forkPath = URL(fileURLWithPath: try XCTUnwrap(parent.path)).deletingLastPathComponent().appendingPathComponent(forkID + ".jsonl")
        let source = try String(contentsOfFile: try XCTUnwrap(parent.path), encoding: .utf8)
        var copied = source.split(separator: "\n").map(String.init)
        copied[0] = "{\"type\":\"session\",\"version\":3,\"id\":\"\(forkID)\"}"
        try (copied.joined(separator: "\n") + "\n").write(to: forkPath, atomically: true, encoding: .utf8)
        fork.path = forkPath.path; model.chats.append(fork)
        let plans = try await model.history.subagentPlans(path: forkPath, ownerID: forkID)
        XCTAssertTrue(plans.isEmpty, "Copied calls retain provenance; the fork cannot acquire children")
        model.chats.removeAll { $0.id == parent.id || $0.isSubagent }
        await model.reconcileSubagents()
        let orphan = try XCTUnwrap(model.record(family.child))
        XCTAssertNotNil(orphan.delegationIssue); XCTAssertNil(orphan.parentSessionID)
    }

}
