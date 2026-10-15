import AppKit
import XCTest
@testable import PiApp

final class SubagentPanelTests: XCTestCase {
    @MainActor func testNormalSidebarNeverListsChildrenOrTheirOldDisclosure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.setSubagentGroupExpanded("chat-parent", expanded: true)
        model.chats[1].pinnedAt = Date()
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            let ids = SubagentOrganizationTests.contents(model).entries.map(\.id)
            XCTAssertFalse(ids.contains("chat|chat-child"))
            XCTAssertFalse(ids.contains("subagents|chat-parent"))
            XCTAssertTrue(ids.contains("chat|chat-parent"))
            XCTAssertFalse(ids.contains("chat|chat-side"))
            XCTAssertFalse(model.sidebarChatOrder.contains("chat-child"))
            XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: "child").entries.map(\.id).contains("chat|chat-child"))
        }
    }
    @MainActor func testTopicCountsOnlyMainChatsAndMatchingTopicDoesNotHideChildSearchHits() throws {
        let model = try fixture()
        let topic = TopicRecord(id: "review", workspaceID: "pane-project", title: "child", revision: 1)
        model.topics = [topic]
        for index in model.chats.indices { model.chats[index].topicID = topic.id }
        let project = try XCTUnwrap(model.workspaces.first)
        let group = model.topicGroupContents(in: project, topic: topic, includesArchive: false, filter: "child", sidebarWidth: 300, namesConnection: false)
        XCTAssertEqual(group.header.chats, 1)
        XCTAssertEqual(Set(group.contents.rows.map { $0.chat.id }), ["chat-parent", "chat-child"])
        XCTAssertFalse(SubagentOrganizationTests.contents(model).entries.map(\.id).contains("chat|chat-child"))
    }
    @MainActor func testFamilyNeverBorrowsChildrenFromAnotherProject() throws {
        let model = try fixture()
        model.chats[1].workspaceID = "another-project"
        XCTAssertTrue(model.subagentFamily("chat-parent").members.isEmpty)
        XCTAssertTrue(model.subagentFamily("chat-child").members.isEmpty)
    }
    @MainActor func testLegacyChildLaunchRestoresReportAndTheSideTab() async throws {
        let model = try fixture()
        model.selectedID = nil; model.selected = nil; model.focusedSessionID = nil
        var remembered = RememberedSelection(chatID: "chat-child", projectID: "pane-project")
        remembered.reportOpen = true
        let restored = await model.reopenRememberedSelection(remembered, unlessSelectedSince: model.selectionRevision)
        XCTAssertTrue(restored)
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertNotNil(model.subagentTab("chat-child"))
        XCTAssertEqual(model.page, .report)
    }
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.chats[1].subagentNumber = 2
        for chat in model.chats {
            let view = SessionDisplay(id: chat.id); view.historyState = .ready; view.draftReady = true
            view.messages = [.init(id: chat.id + "-reply", role: "assistant", text: "Generated reply")]
            model.displays[chat.id] = view
        }
        model.historyWindowLoader = { id, _, _, _ in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                "messages": .array([.object(["id": .string(id + "-reply"), "role": .string("assistant"), "text": .string("Generated reply")])]),
                "older": .null, "newer": .null]))
        }
        model.selectedID = "chat-parent"; model.selected = model.displays["chat-parent"]
        model.focusedSessionID = "chat-parent"
        return model
    }
    @MainActor func testBadgeCountsQueuedAndRunningThenDisappearsAndSearchNamesTheParent() throws {
        let model = try fixture()
        let link = SubagentTranscriptTests.link
        model.subagentSummaries["chat-child"] = .init(link: link, description: "Child", model: "fixture-model", status: .queued, revision: 1)
        func row() throws -> SidebarChatRowState {
            try XCTUnwrap(SubagentOrganizationTests.contents(model).entries.compactMap {
                if case .chat(let chat, let state, _) = $0, chat.id == "chat-parent" { return state }; return nil
            }.first)
        }
        XCTAssertEqual(try row().familyActivity.active, 1)
        model.subagentSummaries["chat-child"]?.status = .running
        XCTAssertEqual(try row().familyActivity.active, 1)
        model.subagentSummaries["chat-child"]?.status = .completed
        XCTAssertEqual(try row().familyActivity.active, 0)
        XCTAssertEqual(model.subagentSearchTitle(try XCTUnwrap(model.record("chat-child"))), "#2 · child — in parent")
        XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: "#2").entries.map(\.id).contains("chat|chat-child"))
        let badge = AgentRunningBadge(); badge.update(.init(runningAgents: 2))
        XCTAssertFalse(badge.isHidden); XCTAssertEqual(badge.accessibilityLabel(), "2 sub-agents running")
        badge.update(.init()); XCTAssertTrue(badge.isHidden)
    }
    @MainActor func testFamilyIsNumberOrderedAndUpdatesWithoutReadingTranscript() throws {
        let model = try fixture()
        var earlier = try XCTUnwrap(model.record("chat-child")); earlier.id = "first"; earlier.subagentNumber = 1
        earlier.delegation?.childSessionID = earlier.id
        model.chats.append(earlier)
        XCTAssertEqual(model.subagentFamily("chat-child").members.map { $0.chat.id }, ["first", "chat-child"])
        XCTAssertEqual(model.subagentFamily("chat-parent").members.map(\.label), ["#1 · child", "#2 · child"])
        let popover = AgentFamilyPopoverView(model: model, sessionID: "chat-child", close: {}, ownerWindow: nil)
        let buttons = ConversationPaneTests.views(PiKit.Button.self, in: popover)
        XCTAssertEqual(buttons.filter { $0.title == "Open" }.map { $0.accessibilityIdentifier() }, ["open-side-chat-side", "open-agent-first", "open-agent-chat-child"])
        XCTAssertTrue(buttons.first { $0.title == "Stop All…" }?.isEnabled == false)
        XCTAssertTrue(model.sessionOpenings.isEmpty)
    }
    @MainActor func testEveryOpenUsesOneSideTabAndBackOnlyFocusesTheParent() async throws {
        let model = try fixture()
        let parent = try XCTUnwrap(model.selected)
        parent.draft = "Keep this draft"
        let reveal = TranscriptReveal(messageID: "chat-parent-reply", serial: 7)
        parent.reveal = reveal
        await model.select("chat-child")
        let tab = try XCTUnwrap(model.subagentTab("chat-child"))
        XCTAssertTrue(tab.container === model.tabs.pane)
        XCTAssertEqual(model.selectedID, "chat-parent"); XCTAssertTrue(model.selected === parent)
        XCTAssertEqual(model.focusedSessionID, "chat-child")
        let opened = await model.revealMessage(sessionID: "chat-child", messageID: "chat-child-reply")
        XCTAssertTrue(opened)
        XCTAssertTrue(model.subagentTab("chat-child") === tab); XCTAssertEqual(model.tabs.allTabs.count, 1)
        XCTAssertEqual(model.displays["chat-child"]?.reveal?.messageID, "chat-child-reply")
        await model.backToSubagentParent("chat-child")
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        XCTAssertEqual(parent.reveal, reveal); XCTAssertEqual(parent.draft, "Keep this draft")
        XCTAssertTrue(model.subagentTab("chat-child") === tab)
        XCTAssertTrue(model.sessionOpenings.isEmpty)
        model.tabs.close(tab)
        XCTAssertNil(model.subagentTab("chat-child"))
    }
    @MainActor func testRestoredChildTabWaitsForMetadataAndLoadsWithoutStartingAHelper() async throws {
        let model = try fixture()
        let name = "subagent-tab-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let host = TabHost(defaults: defaults); host.showsWindows = false; host.restore()
        host.open(kind: SubagentTab.kind, key: "chat-child") { SubagentTab(childID: "chat-child") }
        host.flush()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let restored = WorkspaceModel(stateRoot: root, vault: model.vault, tabDefaults: defaults)
        registerWorkspaceFixtureTeardown(restored, root: root)
        restored.tabs.showsWindows = false; restored.tabs.restore()
        let tab = try XCTUnwrap(restored.subagentTab("chat-child"))
        XCTAssertNil(tab.loading, "Tabs restore before chat metadata")
        let page = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("saved-reply"), "role": .string("assistant"), "text": .string("Restored child history")])]), "older": .null, "newer": .null]))
        restored.historyWindowLoader = { _, _, _, _ in page }
        restored.chats = model.chats
        tab.refresh(); tab.didShow(); await tab.loading?.value
        let display = try XCTUnwrap(restored.displays["chat-child"])
        XCTAssertEqual(display.messages.map(\.id), ["saved-reply"])
        restored.historyViewportReady(display.id, generation: display.presentationGeneration)
        XCTAssertEqual(display.historyState, .ready)
        XCTAssertEqual(tab.title, "Sub-agent 2 · child")
        XCTAssertTrue(restored.subagentTabIsShown("chat-child"))
        let content = tab.contentView
        let pane = try XCTUnwrap(ConversationPaneTests.views(ConversationPaneView.self, in: content).first)
        XCTAssertEqual(pane.chat?.id, "chat-child"); XCTAssertTrue(pane.composer.isHidden)
        XCTAssertTrue(pane.agentFamilyHeader.isHidden)
        XCTAssertTrue(restored.sessionOpenings.isEmpty)
    }

}
