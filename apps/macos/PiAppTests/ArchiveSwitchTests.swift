import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The archive is one switch for the whole sidebar. Off, every project lists
/// its active chats. On, each group of every project lists its archived chats
/// after its active ones, under an "Archived" heading, on a page of their own.
final class ArchiveSwitchTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("archive-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Two projects. The first has an active and an archived chat in a topic
    /// and at its root; every chat of the second is archived.
    @MainActor private func model(_ root: URL) -> WorkspaceModel {
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.workspaces = [WorkspaceRecord(id: "one", path: root.appendingPathComponent("one").path, trusted: true),
                            WorkspaceRecord(id: "two", path: root.appendingPathComponent("two").path, trusted: true)]
        model.topics = [TopicRecord(id: "topic", workspaceID: "one", title: "Billing")]
        model.chats = [chat("one-active", in: "one", order: 1), chat("one-archived", in: "one", order: 2, archived: true),
                       chat("one-topic-active", in: "one", order: 3, topic: "topic"),
                       chat("one-topic-archived", in: "one", order: 4, topic: "topic", archived: true),
                       chat("two-archived", in: "two", order: 5, archived: true)]
        return model
    }

    private func chat(_ id: String, in project: String, order: Int64, topic: String? = nil, archived: Bool = false) -> ChatRecord {
        var record = ChatRecord(id: id, workspaceID: project, title: id, path: nil, profileID: "fixture", sidebarOrder: 1_000 - order)
        record.topicID = topic
        if archived { record.archivedAt = Date(timeIntervalSince1970: 1_000_000 + Double(order)) }
        return record
    }

    @MainActor func testTheSwitchListsEveryProjectsArchivedChatsAfterItsActiveOnes() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root); defer { model.shutdown() }
        let one = model.workspaces[0], two = model.workspaces[1], topic = model.topics[0]
        func topicGroup() -> TopicGroupContents {
            model.topicGroupContents(in: one, topic: topic, includesArchive: model.sidebarShowsArchived, filter: "", sidebarWidth: 300, namesConnection: false)
        }
        func archive(_ project: WorkspaceRecord) -> SidebarGroupContents? {
            model.sidebarArchiveContents(in: project, topicID: nil, includesArchive: model.sidebarShowsArchived, filter: "",
                                         sidebarWidth: 300, namesConnection: false)
        }

        XCTAssertFalse(model.sidebarShowsArchived, "The switch starts off")
        XCTAssertEqual(model.sidebarChatOrder, ["one-topic-active", "one-active"], "Off: active chats only, in every project")
        XCTAssertNil(topicGroup().archive); XCTAssertNil(archive(one)); XCTAssertNil(archive(two))
        let allArchived = model.sidebarGroupContents(in: two, topicID: nil, archived: false, filter: "", showEmpty: true,
                                                     sidebarWidth: 300, namesConnection: false)
        XCTAssertEqual(allArchived.emptyLabel, "No active chats", "A project whose chats are all archived does not say it has none")

        model.setArchivedChatsShown(true)
        XCTAssertTrue(model.showArchivedSessions)
        XCTAssertEqual(model.sidebarChatOrder, ["one-topic-active", "one-topic-archived", "one-active", "one-archived", "two-archived"],
                       "On: each group lists its archived chats after its active ones, in every project")
        let group = topicGroup()
        XCTAssertEqual(group.contents.rows.map(\.id), ["one-topic-active"])
        XCTAssertEqual(group.archive?.rows.map(\.id), ["one-topic-archived"], "The topic's archived chat stays in its topic")
        XCTAssertEqual(group.archive?.archived, true, "and is listed under the Archived heading")
        XCTAssertEqual(group.archive?.total, 1)
        XCTAssertEqual(group.archive?.groupID, SidebarSessionPresentation.archiveGroupID(topic.id), "It pages on its own")
        XCTAssertEqual(group.header.chats, 1, "The topic's count is still its active chats")
        XCTAssertEqual(archive(one)?.rows.map(\.id), ["one-archived"])
        let second = try XCTUnwrap(archive(two), "A project whose chats are all archived lists them too")
        XCTAssertEqual(second.rows.map(\.id), ["two-archived"])
        XCTAssertEqual(second.rows.first?.state.subtitle, "Archived")
        XCTAssertEqual(second.rows.first?.state.draggable, true, "Its rows are dragged and reordered as today's archive rows were")
        let above = model.sidebarGroupContents(in: two, topicID: nil, archived: false, filter: "", showEmpty: false,
                                               sidebarWidth: 300, namesConnection: false)
        XCTAssertNil(above.emptyLabel, "Its archived chats stand where the empty line was")

        // The filter looks through both lists.
        model.sidebarFilter = "archived"
        XCTAssertEqual(model.sidebarChatOrder, ["one-topic-archived", "one-archived", "two-archived"])
        model.sidebarFilter = "topic"
        XCTAssertEqual(model.sidebarChatOrder, ["one-topic-active", "one-topic-archived"])
        model.sidebarFilter = ""

        model.setArchivedChatsShown(false)
        XCTAssertEqual(model.sidebarChatOrder, ["one-topic-active", "one-active"], "Off again: nothing archived is listed")
    }

    /// Opening an archived chat from anywhere lists the archive, so its row
    /// can be seen. Nothing else turns the switch on or off.
    @MainActor func testRevealingAnArchivedChatTurnsTheSwitchOnAndNothingElseTurnsItOff() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root); defer { model.shutdown() }
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.select("one-active")
        XCTAssertFalse(model.showArchivedSessions, "An active chat lists no archive")
        await model.select("two-archived")
        XCTAssertTrue(model.showArchivedSessions, "An archived chat opened lists the archive, where its row is")
        XCTAssertTrue(model.sidebarChatOrder.contains("two-archived"))
        await model.select("one-active")
        XCTAssertTrue(model.showArchivedSessions, "Opening an active chat leaves the switch as it was")
        model.newChat(in: "one")
        XCTAssertTrue(model.showArchivedSessions, "A new chat does too: the archive no longer stands in for the chats")
        try await model.setSessionArchived("one-active", archived: true)
        try await model.setSessionArchived("one-active", archived: false)
        XCTAssertTrue(model.showArchivedSessions, "Archiving and restoring leave it as it was")
        model.toggleArchivedChats()
        XCTAssertFalse(model.showArchivedSessions)
        await model.select("one-topic-active")
        XCTAssertFalse(model.showArchivedSessions)
        await model.store?.close()
    }

    /// A project preference written before the archive was one switch still
    /// reads. What it saved about disclosure stands; its archive filter is not
    /// the switch.
    @MainActor func testAProjectRecordFromBeforeTheSwitchStillReadsAndItsArchiveFilterIsIgnored() async throws {
        let old = try JSONDecoder().decode(ProjectSidebarState.self, from: Data(#"{"id":"one","expanded":false,"archived":true,"revision":7}"#.utf8))
        XCTAssertEqual(old.id, "one"); XCTAssertFalse(old.expanded); XCTAssertEqual(old.revision, 7)
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSidebarState(id: "two"))) as? [String: Any])
        XCTAssertNotNil(written["archived"], "A record this version writes still carries the field earlier versions require")

        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root); defer { model.shutdown() }
        try await model.store?.put(old, kind: "project-sidebar", id: old.id, revision: old.revision)
        try await model.restoreProjectSidebarStates()
        XCTAssertFalse(model.projectIsExpanded("one"), "The disclosure it saved still stands")
        XCTAssertFalse(model.sidebarShowsArchived, "Its archive filter is not the switch")
        XCTAssertEqual(model.sidebarChatOrder, [], "The collapsed project lists nothing, and the other has no active chat")
        // A later change to the project keeps what it read.
        model.setProjectExpanded("one", expanded: true)
        await model.flushProjectSidebarState()
        let saved = try await model.store?.get(ProjectSidebarState.self, kind: "project-sidebar", id: "one")
        XCTAssertEqual(saved?.expanded, true); XCTAssertEqual(saved?.archived, true, "Kept as it was read, for an earlier version")
        await model.store?.close()
    }

    /// The rows on screen: the switch adds each group's archived rows under
    /// the active ones, and takes them away again.
    @MainActor func testTheArchivedRowsAppearOnScreenUnderTheActiveOnes() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root); defer { model.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // Pinned to the top, as the sidebar's list is: a centred group moved
        // every row whenever it grew.
        window.contentView = makeSidebar(model)
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        func settle() { hosted.needsLayout = true; hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func rows(_ view: NSView) -> [TopicSessionDragSurfaceView] {
            (view as? TopicSessionDragSurfaceView).map { [$0] } ?? view.subviews.flatMap { rows($0) }
        }
        func tops() -> [CGFloat] { rows(hosted).map { $0.convert($0.bounds, to: nil).maxY }.sorted(by: >) }
        settle()
        XCTAssertEqual(rows(hosted).count, 2, "Off: the topic's active chat and the project's (the second project has none)")
        let before = tops()
        model.setArchivedChatsShown(true)
        settle()
        XCTAssertEqual(rows(hosted).count, 5, "On: each group's archived chat joins it, the second project's too")
        XCTAssertEqual(tops().first, before.first, "The first active row stays where it was")
        model.setArchivedChatsShown(false)
        settle()
        XCTAssertEqual(rows(hosted).count, 2)
        XCTAssertEqual(tops(), before, "and off again, every row is back where it was")
    }
}
