import AppKit
import XCTest
@testable import PiApp

final class SubagentOrganizationTests: XCTestCase {
    @MainActor static func fixture(_ root: URL) throws -> WorkspaceModel {
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child", "side"])
        bench.model.chats[1].delegation = SubagentTranscriptTests.link
        bench.model.chats[1].parentSessionID = "chat-parent"
        bench.model.chats[2].parentSessionID = "chat-parent"
        return bench.model
    }
    @MainActor static func contents(_ model: WorkspaceModel, filter: String = "") -> SidebarListContents {
        SidebarListContents.build(model: model, filter: filter, sidebarWidth: 300, confirmingRemove: [], removing: [], dropTarget: nil)
    }
    @MainActor func testNarrowDisclosureKeepsItsChevronAndCompleteAccessibleCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        for count in [4, 12_000, Int.max] {
            let state = SubagentGroupState(parentID: "chat-parent", count: count, active: 2, queued: count - 2, expanded: true, indent: 42)
            let group = SidebarSubagentGroupView(model: model, state: state)
            let button = try XCTUnwrap(group.subviews.first as? PiKit.Button)
            for width in [184.0, 220.0, 264.0, 600.0, 184.0] {
                group.frame = CGRect(x: 0, y: 0, width: width, height: 28)
                group.needsLayout = true; group.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(button.intrinsicContentSize.width, button.bounds.width, "The centered Pi label must fit so its chevron remains visible")
                XCTAssertFalse(button.title.isEmpty)
                XCTAssertEqual(button.toolTip, state.label)
                XCTAssertEqual(button.accessibilityLabel(), state.label + ", expanded")
                if width == 600 { XCTAssertEqual(button.title, state.label) }
            }
        }
    }
    @MainActor func testDisclosureFaceKeepsItsIndentWhenChildSelectionChangesTheCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let state = SubagentGroupState(parentID: "chat-parent", count: 4, active: 2, queued: 0, expanded: true, indent: 42)
        let group = SidebarSubagentGroupView(model: model, state: state)
        let button = try XCTUnwrap(group.subviews.first as? PiKit.Button)
        for width in [220.0, 300.0, 600.0] {
            group.frame = CGRect(x: 0, y: 0, width: width, height: 28)
            var leading: CGFloat?
            for active in [2, 0, 2] {
                var next = state; next.active = active; group.update(next); group.layoutSubtreeIfNeeded()
                // Pi buttons center their face. Measure its leading edge,
                // excluding the fixed padding shared by every label.
                let x = button.frame.minX + (button.bounds.width - button.intrinsicContentSize.width) / 2
                if let leading { XCTAssertEqual(x, leading, accuracy: 0.5, "Changing status must not move the group chevron") }
                leading = x
                XCTAssertEqual(x, state.indent, accuracy: 0.5)
            }
        }
    }
    @MainActor func testChildrenStartFoldedApartFromSidesInTopicsAndFlatAndSearchRevealsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        for flat in [false, true] {
            model.setProjectListsFlat("pane-project", flat: flat)
            let entries = Self.contents(model).entries.map(\.id)
            XCTAssertTrue(entries.contains("subagents|chat-parent"))
            XCTAssertFalse(entries.contains("chat|chat-child"))
            XCTAssertTrue(entries.contains("chat|chat-side"), "Ordinary sides keep their independent disclosure")
            XCTAssertFalse(model.sidebarChatOrder.contains("chat-child"))
            XCTAssertTrue(Self.contents(model, filter: "child").entries.map(\.id).contains("chat|chat-child"))
            XCTAssertFalse(Self.contents(model).entries.map(\.id).contains("chat|chat-child"), "Search does not persist expansion")
        }
    }
    @MainActor func testChildNeverCreatesUnreadDraftWebhookOrTitleWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.readStatesRestored = true
        let child = "chat-child"
        model.unreadStates[child] = SessionReadState(id: child, observedAssistantCount: 1, latestAssistantID: "before", unreadOutputs: 3, unreadFailure: true, markedUnread: true)
        model.draftChatIDs.insert(child)
        XCTAssertEqual(model.unreadOutputCount(sessionID: child), 0)
        XCTAssertFalse(model.unreadFailure(sessionID: child)); XCTAssertEqual(model.unreadCount, 0)
        XCTAssertFalse(model.canMarkSessionUnread(child)); XCTAssertFalse(model.showsDraftMark(child))
        XCTAssertFalse(model.webhookEligible(child))
        model.unreadStates = [:]
        model.observeAssistantOutputs(sessionID: child, snapshot: ["assistantMessageCount":.number(1), "latestAssistantMessageId":.string("reply")])
        XCTAssertNil(model.unreadStates[child])
        model.scheduleTitleGeneration(sourceID: child, input: "Delegated task")
        XCTAssertNil(model.titleGenerationTasks[child])
    }

    @MainActor func testSelectedChildRevealsItsGroupWithoutSavingADisclosureChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        for flat in [false, true] {
            model.setProjectListsFlat("pane-project", flat: flat)
            model.selectedID = "chat-child"; model.focusedSessionID = "chat-child"
            let states = Self.contents(model).entries.compactMap { entry -> SidebarChatRowState? in
                if case .chat(let chat, let state, _) = entry, chat.id == "chat-child" { return state }; return nil
            }
            XCTAssertEqual(states.first?.selected, true)
            XCTAssertTrue(model.subagentGroupExpanded("chat-parent"))
            XCTAssertNotEqual(model.projectSidebarStates["pane-project"]?.expandedSubagents?.contains("chat-parent"), true)
            model.selectedID = "chat-parent"; model.focusedSessionID = "chat-parent"
            XCTAssertFalse(model.subagentGroupExpanded("chat-parent"))
            XCTAssertFalse(Self.contents(model).entries.map(\.id).contains("chat|chat-child"))
        }
    }

    @MainActor func testMovingParentMovesManagedChildrenAndOrdinarySidesTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store)
        try await store.putChats(model.chats)
        let topic = try await model.createTopic(in: "pane-project", title: "Review")
        try await model.moveSessions(["chat-parent"], in: "pane-project", toTopic: topic.id)
        for id in ["chat-parent", "chat-child", "chat-side"] {
            XCTAssertEqual(model.record(id)?.topicID, topic.id)
            let saved = try await store.get(ChatRecord.self, kind: "chat", id: id)
            XCTAssertEqual(saved?.topicID, topic.id)
        }
        XCTAssertEqual(model.record("chat-child")?.delegation, SubagentTranscriptTests.link)
        do { try await model.moveSessions(["chat-child"], in: "pane-project", toTopic: nil); XCTFail("Independent child move accepted") } catch { }
    }
    @MainActor func testArchiveFollowsTheOwnerButSideOrganizationStaysIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let store = try XCTUnwrap(model.store)
        for chat in model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        try await model.setSessionArchived("chat-parent", archived: true)
        XCTAssertEqual(model.record("chat-child")?.isArchived, true)
        XCTAssertEqual(model.record("chat-side")?.isArchived, false)
        try await model.setSessionArchived("chat-parent", archived: false)
        XCTAssertEqual(model.record("chat-child")?.isArchived, false)
        let rejected = try await store.updateChatOrganizations(ids: ["chat-child"], change: .pinned(true))
        XCTAssertTrue(rejected.rejected.contains("chat-child"))
        do { try await model.setSessionPinned("chat-child", pinned: true); XCTFail("Child pin accepted") } catch { }
        do { try await model.setSessionArchived("chat-child", archived: true); XCTFail("Independent child archive accepted") } catch { }
        do { try await model.moveSessions(["chat-child"], in: "pane-project", toTopic: nil); XCTFail("Independent child move accepted") } catch { }
    }
    @MainActor func testFamilyRunHoldPersistsCountsWithoutAnIndependentChildHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        for id in ["chat-parent", "chat-child"] {
            let view = SessionDisplay(id: id); view.runState = .running; view.runStateKnown = true; model.displays[id] = view
        }
        model.subagentSummaries["chat-child"] = SubagentSummary(link: SubagentTranscriptTests.link, description: "Review", model: "model", status: .running, revision: 1)
        model.reconcileRunHold("chat-parent"); model.reconcileRunHold("chat-child")
        let hold = try XCTUnwrap(model.runHolds["chat-parent"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(hold)) as? [String: Any])
        XCTAssertEqual((json["family"] as? [String: Int])?["active"], 1)
        XCTAssertNil(model.runHolds["chat-child"])
    }

    @MainActor func testExpandedGroupsStayTogetherAndTheirDisclosureSurvivesRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.setSubagentGroupExpanded("chat-parent", expanded: true)
        model.sides["chat-parent"] = SideRecord(id: "pending-side", parentID: "chat-parent", workspaceID: "pane-project", profileID: model.chats[0].profileID, title: "Unsaved side", pending: true)
        let flushed = await model.flushProjectSidebarState(); XCTAssertTrue(flushed)
        for flat in [false, true] {
            model.setProjectListsFlat("pane-project", flat: flat)
            let ids = Self.contents(model).entries.map(\.id)
            let group = try XCTUnwrap(ids.firstIndex(of: "subagents|chat-parent"))
            XCTAssertEqual(ids[group + 1], "chat|chat-child")
            XCTAssertGreaterThan(try XCTUnwrap(ids.firstIndex(of: "chat|chat-side")), group + 1)
        }
        let finalFlush = await model.flushProjectSidebarState(); XCTAssertTrue(finalFlush)
        model.projectSidebarStates = [:]
        try await model.restoreProjectSidebarStates()
        XCTAssertTrue(model.subagentGroupExpanded("chat-parent"))
    }

    @MainActor func testArchivingALargeFamilyHasNoChildCountCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        let original = model.chats[1]
        let children = (0..<520).map { index -> ChatRecord in
            var child = original; child.id = UUID().uuidString; child.title = "Task \(index)"
            child.delegation?.childSessionID = child.id; child.delegation?.delegationID = child.id
            child.delegation?.call.toolCallID = child.id
            return child
        }
        model.chats = [model.chats[0]] + children
        let store = try XCTUnwrap(model.store)
        try await store.putChats(model.chats)
        try await model.setSessionArchived("chat-parent", archived: true)
        XCTAssertTrue(model.chats.allSatisfy(\.isArchived))
        XCTAssertEqual(model.chats.count, 521)
    }

    @MainActor func testChildCompletionIsSilentWhileParentCompletionStillSounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var played = 0, clock = 0.0
        let sound = CompletionSound(now: { clock += 2; return clock }, playback: { played += 1; return true })
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()), completionSound: sound)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats = [ChatRecord(id: "chat-parent", workspaceID: "project", title: "Parent", profileID: "profile"),
                       ChatRecord(id: "chat-child", workspaceID: "project", title: "Child", profileID: "profile", delegation: SubagentTranscriptTests.link)]
        for id in ["chat-child", "chat-parent"] {
            model.displays[id] = SessionDisplay(id: id)
            model.observeSessionCompletion(sessionID: id, snapshot: ["monitoring":.object(["epoch":.string("one")]), "commands":.array([])], baseline: true)
            model.observeSessionCompletion(sessionID: id, snapshot: ["monitoring":.object(["epoch":.string("one")]), "commands":.array([.object(["commandId":.string("task"), "turnId":.string("task"), "state":.string("completed")])])])
            XCTAssertEqual(played, id == "chat-parent" ? 1 : 0)
        }
    }

    @MainActor func testManagedChildrenDoNotCreateAnOrdinarySideDisclosure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try Self.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.removeAll { $0.id == "chat-side" }
        let states = Self.contents(model).entries.compactMap { entry -> SidebarChatRowState? in
            if case .chat(let chat, let state, _) = entry, chat.id == "chat-parent" { return state }; return nil
        }
        XCTAssertEqual(states.first?.hasSide, false)
    }

}
