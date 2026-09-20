import XCTest
@testable import PiApp

/// Marking several sidebar rows: Shift for a range, Command for one row, then
/// one bulk action or one drag for all of them.
final class SidebarMultiSelectionTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("sidebar-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// The sidebar lists the largest order first, so chat1 leads the list.
    private func chat(_ id: String, order: Int64, project: String = "project") -> ChatRecord {
        ChatRecord(id: id, workspaceID: project, title: id.capitalized, path: nil, profileID: "p", sidebarOrder: 100 - order)
    }
    @MainActor private func model(_ root: URL, chats: [ChatRecord], projects: [String] = ["project"]) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = projects.map { WorkspaceRecord(id: $0, path: "/projects/" + $0, trusted: true) }
        model.chats = chats
        model.selectedWorkspaceID = projects.first
        for chat in chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        return model
    }

    @MainActor func testShiftMarksARangeAndCommandAddsAndRemovesOneRow() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...5).map { chat("chat\($0)", order: Int64($0)) }
        let model = try await model(root, chats: chats); defer { model.shutdown() }
        XCTAssertEqual(model.sidebarChatOrder, ["chat1", "chat2", "chat3", "chat4", "chat5"])
        model.selectedID = "chat2"

        // Shift from the open chat covers everything in between, in sidebar order.
        model.extendSessionMarks(to: "chat4")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat2", "chat3", "chat4"])
        XCTAssertTrue(model.hasMarkedSessions); XCTAssertTrue(model.isSessionMarked("chat3"))

        // A second Shift-click re-measures from the same anchor rather than growing.
        model.extendSessionMarks(to: "chat1")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2"])

        // Command adds one row and takes it away again.
        model.toggleSessionMark("chat5")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat1", "chat2", "chat5"])
        model.toggleSessionMark("chat1")
        XCTAssertEqual(model.markedChats.map(\.id), ["chat2", "chat5"])

        // One mark on the chat that is already open is an ordinary selection.
        model.toggleSessionMark("chat5")
        XCTAssertFalse(model.hasMarkedSessions); XCTAssertTrue(model.markedChats.isEmpty)
        // A deleted chat cannot stay marked.
        model.extendSessionMarks(to: "chat4")
        XCTAssertEqual(model.markedChats.count, 3)
        model.chats.removeAll { $0.id == "chat3" }
        XCTAssertEqual(model.markedChats.map(\.id), ["chat2", "chat4"])
        model.clearSessionMarks()
        XCTAssertTrue(model.markedSessionIDs.isEmpty)
        await model.store?.close()
    }

    @MainActor func testOneRightClickArchivesEveryMarkedChatAndKeepsTheRest() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...4).map { chat("chat\($0)", order: Int64($0)) }
        let model = try await model(root, chats: chats); defer { model.shutdown() }
        model.selectedID = "chat1"
        model.extendSessionMarks(to: "chat3")
        XCTAssertEqual(model.markedChats.count, 3)

        model.archiveMarkedSessions(true)
        XCTAssertTrue(model.markedSessionIDs.isEmpty, "the marks are spent by the action")
        try await eventually { model.sidebarChats(in: "project", archived: true).count == 3 }
        XCTAssertEqual(model.sidebarChats(in: "project", archived: false).map(\.id), ["chat4"])
        for id in ["chat1", "chat2", "chat3"] {
            let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: id)
            XCTAssertTrue(saved?.isArchived == true, id)
        }

        // Restoring works the same way from the archive list.
        model.selectedID = nil
        model.markedSessionIDs = ["chat1", "chat2"]
        model.archiveMarkedSessions(false)
        try await eventually { model.sidebarChats(in: "project", archived: false).count == 3 }
        XCTAssertEqual(model.sidebarChats(in: "project", archived: true).map(\.id), ["chat3"])
        await model.store?.close()
    }

    @MainActor func testMarkedRowsDragTogetherAndMoveIntoOneTopic() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var chats = (1...3).map { chat("chat\($0)", order: Int64($0)) }
        chats.append(chat("other", order: 4, project: "second"))
        let model = try await model(root, chats: chats, projects: ["project", "second"]); defer { model.shutdown() }
        let topic = try await model.createTopic(in: "project", title: "Billing")
        model.selectedID = "chat1"
        model.extendSessionMarks(to: "chat2")

        // A marked row drags every marked chat of its project; an unmarked row drags itself.
        XCTAssertEqual(model.dragSessionIDs(for: "chat1", in: "project"), ["chat1", "chat2"])
        XCTAssertEqual(model.dragSessionIDs(for: "chat3", in: "project"), ["chat3"])
        let payload = TopicSessionDrag(sessionIDs: model.dragSessionIDs(for: "chat1", in: "project"), workspaceID: "project")
        let data = try XCTUnwrap(payload.encoded())
        XCTAssertEqual(TopicSessionDrag.decode(data, in: "project")?.sessionIDs, ["chat1", "chat2"])

        model.moveMarkedSessions(toTopic: topic.id)
        try await eventually { model.record("chat1")?.topicID == topic.id && model.record("chat2")?.topicID == topic.id }
        XCTAssertNil(model.record("chat3")?.topicID)
        XCTAssertTrue(model.markedSessionIDs.isEmpty)

        // Marks spread across projects cannot move as one, and say so.
        model.markedSessionIDs = ["chat3", "other"]
        XCTAssertNil(model.markedProjectID)
        model.moveMarkedSessions(toTopic: topic.id)
        XCTAssertEqual(model.error, "Move chats that are all in the same project.")
        XCTAssertNil(model.record("chat3")?.topicID)
        await model.store?.close()
    }

    /// A bulk action runs one durable write at a time, so a chat can be deleted
    /// while the loop is partway through it. The ones that are still there are
    /// archived, and the reader is not told that the chat they just deleted
    /// could not be archived.
    @MainActor func testABulkActionSkipsAChatThatIsDeletedWhileItRuns() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let chats = (1...4).map { chat("chat\($0)", order: Int64($0)) }
        let model = try await model(root, chats: chats); defer { model.shutdown() }
        model.selectedID = "chat1"
        model.extendSessionMarks(to: "chat3")
        XCTAssertEqual(model.markedChats.count, 3)

        model.archiveMarkedSessions(true)
        // The loop has not reached chat2 yet: it is awaiting its first write.
        model.chats.removeAll { $0.id == "chat2" }
        try await eventually { model.record("chat1")?.isArchived == true && model.record("chat3")?.isArchived == true }
        XCTAssertNil(model.error, "A chat the reader deleted is nothing to report")
        XCTAssertNil(model.record("chat2"))
        XCTAssertEqual(model.sidebarChats(in: "project", archived: false).map(\.id), ["chat4"])

        // The same for pins and for marking read.
        model.markedSessionIDs = ["chat1", "chat4"]
        model.pinMarkedSessions(true)
        model.chats.removeAll { $0.id == "chat4" }
        try await eventually { model.record("chat1")?.isPinned == true }
        XCTAssertNil(model.error)
        await model.store?.close()
    }

    @MainActor private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was never met", file: file, line: line)
    }
}
