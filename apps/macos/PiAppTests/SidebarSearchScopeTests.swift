import AppKit
import XCTest
@testable import PiApp

final class SidebarSearchScopeTests: XCTestCase {
    @MainActor private func fixture() throws -> WorkspaceSidebarView {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("search-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        addTeardownBlock { await MainActor.run { model.shutdown() }; try? FileManager.default.removeItem(at: root) }
        model.workspaces = [WorkspaceRecord(id: "project", path: root.appendingPathComponent("Orchard").path, trusted: true)]
        model.topics = [TopicRecord(id: "topic", workspaceID: "project", title: "Café planning")]
        var profile = ProfileRecord(); profile.id = "profile"; profile.name = "Studio gateway"; profile.modelId = "default-alias"
        model.profiles = [profile]
        let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
        try journal.message("match", role: "user", "The hidden marmalade message")
        var chat = ChatRecord(id: "chat", workspaceID: "project", title: "Release notes", path: journal.url.path, profileID: profile.id)
        chat.topicID = "topic"; chat.model = "chosen-alias"
        model.chats = [chat]
        let view = WorkspaceSidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700); view.settle()
        return view
    }

    @MainActor func testDefaultSearchDoesNotAskForContentEvenWhenTheIndexChanges() async throws {
        let view = try fixture(), model = view.model, search = model.sidebarSearch
        await search.reconcileNow()
        view.setFilter("marmalade"); await search.settleQuery(); view.settle()
        XCTAssertTrue(model.sidebarChatOrder.isEmpty)
        XCTAssertNil(model.sidebarSearchHit("chat"))
        XCTAssertEqual(search.answeredQueries, 0)
        let journal = URL(fileURLWithPath: try XCTUnwrap(model.chats[0].path))
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"later\",\"parentId\":\"match\",\"message\":{\"role\":\"assistant\",\"content\":\"More marmalade\"}}\n".utf8))
        try handle.close()
        await search.reconcileNow(); await search.settleQuery()
        XCTAssertEqual(search.answeredQueries, 0)
        let indexed = await search.index.documentCount(chat: "chat")
        XCTAssertEqual(indexed, 2, "The default scope still maintains the content index")
        XCTAssertEqual(view.filterField.field.placeholderString, "Search titles and details")
    }

    @MainActor func testEveryDisplayedDetailMatchesInTopicsAndFlat() throws {
        let view = try fixture(), model = view.model
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for query in ["RELEASE", "orchard", "CAFE\u{301}", "studio", "chosen-alias"] {
                view.setFilter(query); view.settle()
                XCTAssertEqual(model.sidebarChatOrder, ["chat"], query)
                XCTAssertTrue(view.list.contents.entries.contains { $0.id == "chat|chat" }, query)
                XCTAssertTrue(model.sidebarMatches(model.chats[0], query: query), query)
            }
            model.chats[0].model = nil
            view.setFilter("default-alias"); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, ["chat"])
            model.chats[0].model = "chosen-alias"
        }
        view.model.sidebarSearch.setScope(.fullChats)
        view.setFilter("studio"); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["chat"], "Full chats includes the same details")
    }

    @MainActor func testSearchScopePillIsPresentAndNamed() throws {
        let view = try fixture()
        view.setFilter("release"); view.settle()
        let scope = try XCTUnwrap(view.subviews.first { $0.accessibilityLabel() == "Search scope" })
        XCTAssertFalse(scope.isHidden)
        XCTAssertEqual(scope.accessibilityRole(), .group)
        XCTAssertEqual(view.model.sidebarSearch.scope, .titlesAndDetails)
        XCTAssertTrue(try XCTUnwrap(view.searchScope.tab(.titlesAndDetails)).isAccessibilitySelected())
        XCTAssertFalse(try XCTUnwrap(view.searchScope.tab(.fullChats)).isAccessibilitySelected())
        XCTAssertEqual(view.filterField.field.accessibilityLabel(), "Search chats: Titles & details")
    }

    @MainActor func testSwitchingImmediatelyRefiltersAndOnlyFullChatsShowsSnippets() async throws {
        let view = try fixture(), model = view.model
        await model.sidebarSearch.reconcileNow()
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            view.setFilter("marmalade"); await model.sidebarSearch.settleQuery(); view.settle()
            XCTAssertTrue(model.sidebarChatOrder.isEmpty)
            view.searchScope.tab(.fullChats)?.performClick(nil)
            await model.sidebarSearch.settleQuery(); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, ["chat"])
            XCTAssertTrue(view.list.contents.entries.contains { $0.id == "snippet|chat" })
            XCTAssertEqual(view.filterField.field.placeholderString, "Search chats and messages")
            XCTAssertEqual(view.filterField.field.accessibilityLabel(), "Search chats: Full chats")
            XCTAssertTrue(try XCTUnwrap(view.searchScope.tab(.fullChats)).isAccessibilitySelected())
            view.searchScope.tab(.titlesAndDetails)?.performClick(nil)
            XCTAssertTrue(model.sidebarChatOrder.isEmpty)
            XCTAssertFalse(view.list.contents.entries.contains { $0.id == "snippet|chat" })
        }
    }

    @MainActor func testClearButtonEscapeAndDeleteAllResetTheScope() async throws {
        let view = try fixture(), search = view.model.sidebarSearch
        for action in ["clear", "escape", "delete"] {
            view.setFilter("marmalade")
            view.searchScope.tab(.fullChats)?.performClick(nil)
            switch action {
            case "clear": view.clearFilter.performClick(nil)
            case "escape":
                let delegate = try XCTUnwrap(view.filterField.field.delegate as? SidebarFilterDelegate)
                XCTAssertTrue(delegate.control(view.filterField.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            default:
                view.filterField.field.stringValue = ""
                view.filterField.field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: view.filterField.field))
            }
            XCTAssertEqual(view.filter, "", action)
            XCTAssertEqual(search.scope, .titlesAndDetails, action)
            XCTAssertEqual(view.searchScope.selection, .titlesAndDetails, action)
            view.setFilter("marmalade"); await search.settleQuery(); view.settle()
            XCTAssertTrue(view.model.sidebarChatOrder.isEmpty, action)
        }
        view.setFilter(""); search.setScope(.fullChats)
        view.setFilter("")
        XCTAssertEqual(search.scope, .titlesAndDetails, "An already empty field can also be cleared")
    }

    @MainActor func testANewModelStartsInTitlesAndDetails() throws {
        let view = try fixture(), root = view.model.root
        view.setFilter("marmalade"); view.model.sidebarSearch.setScope(.fullChats)
        view.model.shutdown()
        let reopened = makeWorkspaceModel(stateRoot: root); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.sidebarSearch.scope, .titlesAndDetails)
        XCTAssertEqual(reopened.sidebarSearch.query, "")
    }

    @MainActor func testSwitchingBackCancelsLateContentAnswersAndMessageReveals() async throws {
        let view = try fixture(), model = view.model, search = model.sidebarSearch
        model.chats[0].title = "Marmalade notes"
        let display = SessionDisplay(id: "chat"); display.historyState = .ready
        model.displays["chat"] = display; model.selectedID = "chat"; model.selected = display; model.focusedSessionID = "chat"
        await search.reconcileNow(); search.setScope(.fullChats)
        view.setFilter("marmalade"); await search.settleQuery()
        let hit = try XCTUnwrap(model.sidebarSearchHit("chat")), opening = model.beginSidebarOpen()
        var revealed = false
        SidebarSearchReveal.override = { _, _ in revealed = true }
        defer { SidebarSearchReveal.override = nil }
        search.setScope(.titlesAndDetails)
        await model.revealSidebarSearchHit("chat", hit: hit, opening: opening)
        await model.openFromSidebar("chat")
        XCTAssertFalse(revealed)
        XCTAssertEqual(model.sidebarChatOrder, ["chat"], "Title matches still open normally")
        search.reader.delay = 0.15; search.debounce = .zero
        search.setScope(.fullChats)
        await Task.yield()
        search.setScope(.titlesAndDetails)
        await search.settleQuery(); view.settle()
        XCTAssertNil(model.sidebarSearchHit("chat"))
        XCTAssertTrue(model.sidebarContentMatches.isEmpty)
        XCTAssertFalse(view.list.contents.entries.contains { $0.id == "snippet|chat" })
    }

    @MainActor func testMetadataChangesInvalidateTheFilterAndArchivesFollowTheSwitch() throws {
        let view = try fixture(), model = view.model
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            model.profiles[0].name = "Studio gateway"
            view.setFilter("studio"); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, ["chat"])
            model.profiles[0].name = "Renamed connection"; view.settle()
            XCTAssertTrue(model.sidebarChatOrder.isEmpty)
            view.setFilter("renamed"); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, ["chat"])
            model.chats[0].archivedAt = Date(); view.settle()
            XCTAssertTrue(model.sidebarChatOrder.isEmpty)
            model.setArchivedChatsShown(true); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, ["chat"])
            XCTAssertTrue(view.list.contents.entries.contains { $0.id == "chat|chat" })
            model.chats[0].archivedAt = nil; model.setArchivedChatsShown(false)
        }
    }

    @MainActor func testSideAndSubagentDetailsKeepTheirAncestorsAndTopicVisible() throws {
        let root = scratchRoot("scope-family"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats[1].title = "Parser investigation"; model.chats[1].delegationTask = "Check ambiguous boundaries"
        model.chats[1].model = "child-alias"; model.chats[2].model = "side-alias"
        let project = model.chats[0].workspaceID
        model.topics = [TopicRecord(id: "family", workspaceID: project, title: "Planning")]
        for index in model.chats.indices { model.chats[index].topicID = "family" }
        let view = WorkspaceSidebarView(model: model)
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for (query, id) in [("Parser", "chat-child"), ("ambiguous", "chat-child"), ("child-alias", "chat-child"), ("side-alias", "chat-side")] {
                view.setFilter(query); view.settle()
                XCTAssertEqual(Set(model.sidebarChatOrder), ["chat-parent", id], query)
                XCTAssertTrue(view.list.contents.entries.contains { $0.id == "chat|" + id }, query)
                if !flat { XCTAssertTrue(view.list.contents.entries.contains { $0.id == "topic|family" }, query) }
            }
        }
    }
}
