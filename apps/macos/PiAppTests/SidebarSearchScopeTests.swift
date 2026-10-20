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

    @MainActor func testSideAndSubagentOwnMatchesKeepTheirAncestorsAndTopicVisible() throws {
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
            for (query, id) in [("Parser", "chat-child"), ("ambiguous", "chat-child"), ("side", "chat-side")] {
                view.setFilter(query); view.settle()
                XCTAssertEqual(Set(model.sidebarChatOrder), ["chat-parent", id], query)
                XCTAssertTrue(view.list.contents.entries.contains { $0.id == "chat|" + id }, query)
                if !flat { XCTAssertTrue(view.list.contents.entries.contains { $0.id == "topic|family" }, query) }
            }
            for query in ["child-alias", "side-alias"] {
                view.setFilter(query); view.settle()
                XCTAssertTrue(model.sidebarChatOrder.isEmpty, "Metadata alone does not promote a family row")
                XCTAssertFalse(view.list.contents.entries.contains { $0.id == "topic|family" })
            }
        }
    }

    @MainActor func testMetadataMatchesOnlyMainRowsAcrossScopesLayoutsAndArchives() async throws {
        let root = scratchRoot("scope-metadata-family"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces[0].path = root.appendingPathComponent("Orchard").path
        let project = model.workspaces[0]
        let topic = TopicRecord(id: "family", workspaceID: project.id, title: "Planning")
        model.topics = [topic]
        var profile = ProfileRecord(); profile.id = "studio"; profile.name = "Gateway"; profile.modelId = "default-alias"
        model.profiles = [profile]
        for index in model.chats.indices {
            model.chats[index].topicID = topic.id; model.chats[index].profileID = profile.id
            model.chats[index].model = nil
        }
        let view = WorkspaceSidebarView(model: model), search = model.sidebarSearch
        search.debounce = .zero
        for scope in SidebarSearch.Scope.allCases {
            search.setScope(scope)
            for flat in [false, true] {
                model.setSidebarFlat(flat)
                for archived in [false, true] {
                    for index in model.chats.indices { model.chats[index].archivedAt = archived ? Date() : nil }
                    model.setArchivedChatsShown(archived)
                    for query in ["orchard", "planning", "gateway", "default-alias"] {
                        view.setFilter(query); await search.settleQuery(); view.settle()
                        let context = "\(scope), flat \(flat), archived \(archived), \(query)"
                        XCTAssertEqual(model.sidebarFilterMatches(query: query), ["chat-parent"], context)
                        XCTAssertEqual(model.sidebarChatOrder, ["chat-parent"], context)
                        XCTAssertEqual(view.list.contents.entries.compactMap { entry -> String? in
                            if case .chat(let chat, _, _) = entry { return chat.id }; return nil
                        }, model.sidebarChatOrder, context)
                        XCTAssertFalse(model.sidebarMatches(model.chats[1], query: query), context)
                        XCTAssertFalse(model.sidebarMatches(model.chats[2], query: query), context)
                        let group = model.topicGroupContents(in: project, topic: topic, includesArchive: archived,
                            filter: query, sidebarWidth: 300, namesConnection: true)
                        XCTAssertEqual(group.header.chats, archived ? 0 : 1, context)
                        XCTAssertEqual(group.contents.total, archived ? 0 : 1, context)
                        XCTAssertEqual(group.archive?.total, archived ? 1 : nil, context)
                        let rootGroup = model.sidebarGroupContents(in: flat ? nil : project, topicID: flat ? nil : topic.id,
                            archived: archived, filter: query, showEmpty: false, sidebarWidth: 300, namesConnection: true)
                        XCTAssertEqual(rootGroup.total, 1, context)
                        XCTAssertEqual(view.list.contents.entries.compactMap { entry -> Int? in
                            if case .archiveHeading(_, let count, _) = entry { return count }; return nil
                        }, archived ? [1] : [], context)
                    }
                    if archived {
                        model.setArchivedChatsShown(false); view.settle()
                        XCTAssertTrue(model.sidebarChatOrder.isEmpty)
                        XCTAssertFalse(view.list.contents.entries.contains { $0.id == "topic|family" })
                    }
                }
            }
        }
    }

    @MainActor func testMetadataKeepsMainChatExceptionsAndRechecksChangedFamilyOwnership() throws {
        let root = scratchRoot("scope-metadata-eligibility"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        var profile = ProfileRecord(); profile.id = "studio"; profile.name = "Gateway"; profile.modelId = "default-alias"
        model.profiles = [profile]
        let project = model.chats[0].workspaceID
        var imported = ChatRecord(id: "imported", workspaceID: project, title: "Imported", path: nil, profileID: profile.id,
                                  parentSessionID: "chat-parent")
        imported.imported = true
        var background = ChatRecord(id: "background", workspaceID: project, title: "Background", path: nil, profileID: profile.id)
        background.backgroundTask = "title"
        model.chats += [imported, background,
            ChatRecord(id: "orphan", workspaceID: project, title: "Orphan", path: nil, profileID: profile.id, parentSessionID: "missing"),
            ChatRecord(id: "cross-project", workspaceID: "retained", title: "Cross project", path: nil, profileID: profile.id, parentSessionID: "chat-parent")]
        for index in model.chats.indices { model.chats[index].profileID = profile.id }
        model.chats[1].pinnedAt = Date(); model.chats[2].pinnedAt = Date()
        model.topics = [TopicRecord(id: "side-only", workspaceID: project, title: "Separate family group")]
        model.chats[1].topicID = "side-only"; model.chats[2].topicID = "side-only"
        model.chats[2].archivedAt = Date(); model.setArchivedChatsShown(true)
        let view = WorkspaceSidebarView(model: model)
        for scope in SidebarSearch.Scope.allCases {
            model.sidebarSearch.setScope(scope)
            for flat in [false, true] {
                model.setSidebarFlat(flat); view.setFilter("gateway"); view.settle()
                let expected: Set<String> = ["chat-parent", "imported", "orphan", "cross-project"]
                XCTAssertEqual(model.sidebarFilterMatches(query: "gateway"), expected)
                XCTAssertEqual(Set(model.sidebarChatOrder), expected)
                XCTAssertFalse(model.sidebarMatches(background, query: "gateway"))
                XCTAssertFalse(view.list.contents.entries.contains { $0.id == "topic|side-only" })
                model.chats[2].parentSessionID = "missing"; view.settle()
                XCTAssertEqual(Set(model.sidebarChatOrder), expected.union(["chat-side"]))
                if !flat { XCTAssertTrue(view.list.contents.entries.contains { $0.id == "topic|side-only" }) }
                model.chats[2].parentSessionID = "chat-parent"; view.settle()
                XCTAssertEqual(Set(model.sidebarChatOrder), expected)
            }
        }
    }

    @MainActor func testFullChatContentStillFindsAChildWhenItsGroupMetadataMatches() async throws {
        let root = scratchRoot("scope-metadata-content"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let project = model.chats[0].workspaceID
        model.topics = [TopicRecord(id: "family", workspaceID: project, title: "Marmalade")]
        for index in model.chats.indices { model.chats[index].topicID = "family" }
        let journal = try SearchJournal(root.appendingPathComponent("content-side.jsonl"), id: "chat-side")
        try journal.message("match", role: "user", "Marmalade appears in this side only.")
        model.chats[2].path = journal.url.path
        let view = WorkspaceSidebarView(model: model), search = model.sidebarSearch
        search.debounce = .zero; await search.reconcileNow()
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for archived in [false, true] {
                for index in model.chats.indices { model.chats[index].archivedAt = archived ? Date() : nil }
                model.setArchivedChatsShown(archived)
                view.setFilter("marmalade"); search.setScope(.titlesAndDetails); view.settle()
                XCTAssertEqual(model.sidebarChatOrder, ["chat-parent"])
                search.setScope(.fullChats); await search.settleQuery(); view.settle()
                XCTAssertEqual(model.sidebarChatOrder, ["chat-parent", "chat-side"])
                XCTAssertTrue(view.list.contents.entries.contains { $0.id == "snippet|chat-side" })
                XCTAssertFalse(view.list.contents.entries.contains { $0.id == "chat|chat-child" })
                XCTAssertEqual(search.hit(for: "chat-side")?.messageID, "match")
            }
        }
    }
}
