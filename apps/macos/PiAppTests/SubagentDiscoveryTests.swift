import Foundation
import XCTest
@testable import PiApp

final class SubagentDiscoveryTests: XCTestCase {
    @MainActor func testDiscoveryPublicationCannotUndoANewerTopicMoveOrArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let before = model.chats[1]
        var moved = before; moved.topicID = "new-topic"; moved.archivedAt = Date(); moved.organizationRevision = 10
        model.chats[1] = moved
        // A store callback begun before the organization transaction returns
        // after the transaction's committed patch has reached the main actor.
        model.publishSubagentMetadata(before)
        XCTAssertEqual(model.record(before.id)?.topicID, moved.topicID)
        XCTAssertEqual(model.record(before.id)?.archivedAt, moved.archivedAt)
        XCTAssertEqual(model.record(before.id)?.organizationRevision, 10)
    }

    @MainActor func testListingFromALostConnectionCannotPublishLiveProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        try await model.store?.putChats(model.chats)
        await model.reconcileSubagents()
        var summary = try XCTUnwrap(model.subagentSummaries[family.child]); summary.status = .running; summary.revision = 3
        var link = SubagentTranscriptTests.link; link.childSessionID = family.child
        let header = try await model.history.subagentHeader(path: family.path, directory: family.path.deletingLastPathComponent(), expected: SubagentTarget(link))
        let found = DiscoveredSubagent(header: header, path: family.path.path, task: "task", status: .running)
        do {
            try await model.registerDiscoveredSubagent(found, workspaceID: model.chats[0].workspaceID, live: summary, connection: UUID())
            XCTFail("An obsolete helper callback was accepted")
        } catch is CancellationError { }
        XCTAssertEqual(model.subagentSummaries[family.child]?.status, .completed)
    }

    @MainActor func testRecoveryFallbackCannotReplaceListedProgressButATerminalRecordCan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model), parent = model.chats[0]
        let complete = try Data(contentsOf: family.path)
        let rows = complete.split(separator: 10)
        try (rows.prefix(3).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n").write(to: family.path, atomically: true, encoding: .utf8)
        try await model.store?.putChats(model.chats)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        var link = SubagentTranscriptTests.link; link.childSessionID = family.child
        let header = try await model.history.subagentHeader(path: family.path, directory: family.path.deletingLastPathComponent(), expected: SubagentTarget(link))
        for (index, status) in [SubagentStatus.queued, .running].enumerated() {
            let summary = SubagentSummary(link: header.link, description: header.description, model: header.model.model, status: status, revision: index + 1)
            try await model.registerListedSubagent(summary, parent: parent, task: "task")
            model.displays[family.child] = SessionDisplay(id: family.child)
            await model.reconcileSubagents(parentID: parent.id)
            XCTAssertEqual(model.subagentSummaries[family.child], summary, "A disk fallback has no live status evidence")
            XCTAssertEqual(model.displays[family.child]?.subagentStatus, status)
        }
        // A genuine interrupted terminal is evidence, not the no-record fallback.
        let interrupted = String(decoding: complete, as: UTF8.self).replacingOccurrences(of: "completed", with: "interrupted")
        try interrupted.write(to: family.path, atomically: true, encoding: .utf8)
        await model.reconcileSubagents(parentID: parent.id)
        XCTAssertEqual(model.subagentSummaries[family.child]?.status, .interrupted)
        XCTAssertEqual(model.displays[family.child]?.subagentStatus, .interrupted)
    }

    @MainActor func testLiveListingAndDiscoveryAcceptTheSameCanonicalChildPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model), store = try XCTUnwrap(model.store)
        try await store.putChats(model.chats)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let parent = model.chats[0], directory = try model.subagentDirectory(parent.workspaceID)
        var link = SubagentTranscriptTests.link; link.childSessionID = family.child
        let header = try await model.history.subagentHeader(path: family.path, directory: directory,
            expected: SubagentTarget(link))
        let canonical = family.path.resolvingSymlinksInPath()
        // The helper, old metadata and Foundation directory enumeration may
        // spell /var and /private/var differently. They name the same journal.
        let alternate = canonical.path.hasPrefix("/var/") ? "/private" + canonical.path : String(canonical.path.dropFirst("/private".count))
        XCTAssertNotEqual(alternate, canonical.path, "This macOS fixture must exercise a real path alias")
        let found = DiscoveredSubagent(header: header, path: alternate, task: "task", status: .running)
        try await model.registerDiscoveredSubagent(found, workspaceID: parent.workspaceID)
        var saved = try XCTUnwrap(model.record(family.child)); saved.path = alternate
        try await store.put(saved, kind: "chat", id: saved.id)
        let summary = SubagentSummary(link: header.link, description: header.description, model: header.model.model, status: .running, revision: 1)
        try await model.registerListedSubagent(summary, parent: parent, task: "task")
        await model.reconcileSubagents(parentID: parent.id)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.chats.filter { $0.id == family.child }.count, 1)
        XCTAssertEqual(model.record(family.child)?.path, canonical.path)
        var foreign = found; foreign.path = root.appendingPathComponent("different.jsonl").path
        do { _ = try await store.registerSubagent(foreign, workspaceID: parent.workspaceID); XCTFail("A different journal cannot take over this child") } catch { }
    }

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

    @MainActor func testMissingChildFileDoesNotBlockOtherFamilyGroups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let header = try await model.history.subagentHeader(path: family.path, directory: family.path.deletingLastPathComponent(), expected: SubagentTarget((try await model.history.subagentPlans(path: URL(fileURLWithPath: model.chats[0].path!), ownerID: "chat-parent"))[0].header.link))
        var broken = header.link; broken.childSessionID = UUID().uuidString; broken.delegationID = "missing"; broken.call.toolCallID = "missing"
        for link in [broken, header.link] {
            let summary = SubagentSummary(link: link, description: "Saved task", model: "fixture", status: .failed, revision: 1)
            try await model.registerListedSubagent(summary, parent: model.chats[0], task: "Review")
        }
        XCTAssertNotNil(model.record(family.child)); XCTAssertNil(model.record(broken.childSessionID))
        let groups = try await model.traces.inspectorSubagents(owner: "chat-parent", workspaceID: "pane-project")
        XCTAssertEqual(groups.count, 2, "A task whose journal could not be created still has a family Inspector group")
    }

    @MainActor func testReupgradeRebuildsIdentityErasedByOlderDesktopMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try Self.family(model)
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child))
        // An older app understands the common fields, but its synthesized
        // encoder drops the new optional identity when it saves a rename.
        var old = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(child)).object)
        for key in ["delegation", "delegationTask", "delegationIssue"] { old.removeValue(forKey: key) }
        old["title"] = .string("Renamed in the older app")
        try await model.store?.put(old, kind: "chat", id: child.id)
        let legacy = try await model.store?.get(ChatRecord.self, kind: "chat", id: child.id)
        XCTAssertNil(legacy?.delegation)
        model.chats = try await model.store!.loadChats()
        await model.reconcileSubagents()
        XCTAssertNil(model.error)
        let restored = try XCTUnwrap(model.record(child.id))
        XCTAssertEqual(restored.delegation, child.delegation)
        XCTAssertEqual(restored.title, "Renamed in the older app")
        XCTAssertTrue(restored.isSubagent)
        var conflict = try XCTUnwrap(restored.delegation); conflict.delegationID = "different-delegation"
        old["delegation"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(conflict))
        try await model.store?.put(old, kind: "chat", id: child.id)
        model.chats = try await model.store!.loadChats()
        await model.reconcileSubagents()
        XCTAssertNotNil(model.error, "A conflicting identity is not an older encoder dropping an unknown field")
        XCTAssertEqual(model.record(child.id)?.delegation, conflict)
    }

}
