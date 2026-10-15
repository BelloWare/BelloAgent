import AppKit
import XCTest
@testable import PiApp

final class ConversationFamilyTests: XCTestCase {
    @MainActor func testReleasedChildCostsFollowAcceptedProgressWithoutReopeningItsReader() async throws {
        let model = try fixture(), family = try SubagentDiscoveryTests.family(model)
        try await model.traces.configure(quota:nil,bodyRetention:1000,metricRetention:1000)
        let parent = try XCTUnwrap(model.record("chat-parent")), view = try XCTUnwrap(model.displays[parent.id])
        try await model.store?.put(parent,kind:"chat",id:parent.id)
        await model.reconcileSubagents(parentID:parent.id)
        let link = try XCTUnwrap(model.record(family.child)?.delegation)
        func summary(_ turn: Int, _ elapsed: Double, _ usd: Double, _ reported: Int, _ unreported: Int = 0) -> SubagentSummary {
            .init(link:link,description:"Parser review",model:"fixture",status:.running,revision:turn,
                progress:.init(phase:"generating",elapsedMs:elapsed,requests:reported + unreported,tools:0,preview:"",usd:usd,reported:reported,unreported:unreported),
                turn:turn,executionID:"turn-\(turn)",progressEpoch:"fixture-runtime")
        }
        let first = summary(1,100,0.20,1)
        try await model.registerListedSubagent(first,parent:parent,task:"Review")
        model.displays[family.child] = SessionDisplay(id:family.child); model.opened.insert(family.child)
        model.observeCost(["cost":.object(["spentUSD":.number(0.25),"reportedRequests":.number(1)])],sessionID:family.child)
        model.displays.removeValue(forKey:family.child); model.helperSessionDidUnload(family.child)
        XCTAssertNotNil(model.budgetStates[family.child],"Eviction retains lightweight numeric state")
        _ = model.conversationFamily(parent.id)
        func check(_ usd: Double, _ reported: Int, _ unknown: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(model.conversationFamily(parent.id).agents.members.first { $0.chat.id == family.child }?.spend,usd,file:file,line:line)
            XCTAssertEqual(model.costReading(for:family.child).spentUSD,usd,file:file,line:line)
            XCTAssertEqual(model.costReading(for:family.child).reportedRequests,reported,file:file,line:line)
            XCTAssertEqual(model.costReading(for:family.child).unreportedRequests,unknown,file:file,line:line)
            var tool = SubagentTranscriptTests.tool; tool.subagent = first
            let card = view.presentAgentState(.init(id:"reply",role:"assistant",text:"",tools:[tool]))
            XCTAssertEqual(SubagentToolView(try XCTUnwrap(card.tools?.first)).cost?.spentUSD,usd,file:file,line:line)
            XCTAssertNil(model.displays[family.child],file:file,line:line); XCTAssertFalse(model.opened.contains(family.child),file:file,line:line)
        }
        let second = summary(2,100,0.65,2,1)
        try await model.registerListedSubagent(second,parent:parent,task:"Follow up"); try check(0.65,2,1)
        let later = summary(2,200,0.85,3)
        try await model.registerListedSubagent(later,parent:parent,task:"Follow up"); try check(0.85,3)
        try await model.registerListedSubagent(first,parent:parent,task:"Late old turn"); try check(0.85,3)
        // A direct accounting correction wins over repeated/older progress.
        model.observeCost(["cost":.object(["spentUSD":.number(0.90),"reportedRequests":.number(3)])],sessionID:family.child)
        try await model.registerListedSubagent(later,parent:parent,task:"Duplicate"); try check(0.90,3)
        try await model.registerListedSubagent(second,parent:parent,task:"Late progress"); try check(0.90,3)
        // A newer correction can lower dollars without losing coverage.
        let correction = summary(2,300,0.75,3)
        try await model.registerListedSubagent(correction,parent:parent,task:"Correction"); try check(0.75,3)
        var terminal = correction; terminal.status = .completed; terminal.progress = nil; terminal.revision = 3
        try await model.registerListedSubagent(terminal,parent:parent,task:"Done"); try check(0.75,3)
    }

    @MainActor func testUnchangedStreamingCostDoesNoFamilyWorkAfterManyChatsWereVisited() throws {
        let model = try fixture(), parent = "chat-parent", side = "chat-side"
        model.chats[try XCTUnwrap(model.chats.firstIndex { $0.id == side })].path = "/fixture/side_chat-side.jsonl"
        let other = (0..<200).map { ChatRecord(id:"visited-\($0)",workspaceID:"pane-project",title:"Visited \($0)",profileID:"pane-profile") }
        model.chats.append(contentsOf:other)
        for item in other { _ = model.budgetState(for:item.id) }
        for id in [side,"chat-child"] { _ = model.budgetState(for:id) }
        func snapshot(_ usd: Double) -> [String:WireValue] { ["cost":.object(["spentUSD":.number(usd),"reportedRequests":.number(1),"limitUSD":.number(25)])] }
        model.observeCost(snapshot(0.4),sessionID:parent)
        let before = model.budgetFamilyRefreshVisits
        for _ in 0..<200 { model.observeCost(snapshot(0.4),sessionID:parent) }
        XCTAssertEqual(model.budgetFamilyRefreshVisits,before,"Unchanged per-token cost must not traverse retained chats")
        model.observeCost(snapshot(0.6),sessionID:parent)
        XCTAssertEqual(model.budgetStates[side]?.reading.budgetSpentUSD,0.6)
        XCTAssertEqual(model.budgetStates["chat-child"]?.reading.budgetSpentUSD,0.6)
        XCTAssertTrue(other.allSatisfy { model.budgetStates[$0.id]?.reading.spentUSD == nil })
        // Ownership/attribution changes still apply when the amount repeats.
        model.observeCost(snapshot(0.1),sessionID:side)
        model.chats.removeAll { $0.id == parent }
        model.observeCost(snapshot(0.1),sessionID:side)
        XCTAssertNil(model.budgetStates[side]?.reading.budgetOwnerID)
        XCTAssertNil(model.budgetStates[side]?.reading.costAttribution)
    }
    @MainActor func testCachedCardAttributionFollowsSavedSideOrphaningWithoutAnotherCharge() throws {
        let model = try fixture()
        let sideIndex = try XCTUnwrap(model.chats.firstIndex { $0.id == "chat-side" })
        model.chats[sideIndex].path = "/fixture/side_chat-side.jsonl"
        let childIndex = try XCTUnwrap(model.chats.firstIndex { $0.id == "chat-child" })
        model.chats[childIndex].parentSessionID = "chat-side"
        model.chats[childIndex].delegation?.budgetOwnerSessionID = "chat-side"
        model.chats[childIndex].delegation?.call.parentSessionID = "chat-side"
        let side = SessionDisplay(id:"chat-side"); model.displays[side.id] = side
        model.observeCost(["cost":.object(["spentUSD":.number(0.6),"reportedRequests":.number(1)])],sessionID:"chat-child")
        let first = side.presentAgentState(cardRow(model)).tools?.first
        XCTAssertEqual(SubagentToolView(try XCTUnwrap(first)).cost?.costAttribution,"Counts toward parent")
        model.chats.removeAll { $0.id == "chat-parent" }
        model.refreshCostReading("chat-child")
        let orphan = side.presentAgentState(cardRow(model)).tools?.first
        XCTAssertEqual(SubagentToolView(try XCTUnwrap(orphan)).cost?.costAttribution,"Counts toward side")
        XCTAssertEqual(SubagentToolView(try XCTUnwrap(orphan)).cost?.spentUSD,0.6)
    }
    @MainActor private func cardRow(_ model: WorkspaceModel) -> TranscriptMessage {
        var tool = SubagentTranscriptTests.tool
        tool.subagent = .init(link:model.record("chat-child")!.delegation!,description:"Child",model:"fixture",status:.completed,revision:1)
        return .init(id:"reply",role:"assistant",text:"",tools:[tool])
    }
    @MainActor func testFamilyCostsPreferAuthoritativeBudgetStateAndRefreshCachedPickerAndCards() throws {
        let model = try fixture(), child = try XCTUnwrap(model.record("chat-child"))
        var old = GatewayTotals(); old.costUSD = 0.04; old.costSamples = 1
        model.publishChatStats(old,sessionID:"chat-side")
        model.subagentSummaries[child.id] = .init(link:try XCTUnwrap(child.delegation),description:child.title,model:"fixture",status:.completed,revision:1,
            progress:.init(phase:"done",elapsedMs:100,requests:1,tools:0,preview:"",usd:0.05,reported:1,unreported:0))
        let picker = AgentFamilyPopoverView(model:model,sessionID:"chat-parent",close:{},ownerWindow:nil)
        _ = model.conversationFamily("chat-parent")
        for (id,usd) in [("chat-side",0.75),("chat-child",0.60)] {
            model.observeCost(["cost":.object(["spentUSD":.number(usd),"reportedRequests":.number(2),"unreportedRequests":.number(1),"limitUSD":.number(25)])],sessionID:id)
        }
        let family = model.conversationFamily("chat-parent")
        XCTAssertEqual(family.sides.first?.spend,0.75)
        XCTAssertEqual(family.agents.members.first?.spend,0.60)
        XCTAssertNil(model.displays["chat-side"],"Cost-only state must not allocate a hidden transcript")
        picker.refresh()
        let rows = ConversationPaneTests.views(FamilyPickerRow.self,in:picker)
        XCTAssertTrue(rows.contains { $0.accessibilityIdentifier() == "open-side-chat-side" && $0.secondary?.contains("$0.75") == true })
        XCTAssertTrue(rows.contains { $0.accessibilityIdentifier() == "open-agent-chat-child" && $0.secondary?.contains("$0.60") == true })
        var tool = SubagentTranscriptTests.tool; tool.nativeSubagent = SubagentTranscriptTests.metadata
        tool.subagent = model.subagentSummaries[child.id]
        let parent = try XCTUnwrap(model.displays["chat-parent"])
        let projected = parent.presentAgentState(.init(id:"reply",role:"assistant",text:"",tools:[tool]))
        let row = TranscriptNativeActionRow()
        row.update(tool:try XCTUnwrap(projected.tools?.first),open:true,fetched:nil,environment:.init(),toggle:{},openFile:nil)
        XCTAssertTrue(ConversationPaneTests.views(PiKit.SelectableText.self,in:row).contains { $0.stringValue == "$0.60" })
        XCTAssertTrue(ConversationPaneTests.views(PiKit.WrappedText.self,in:row).contains { $0.text.contains("Counts toward") })
        // Late capture refresh cannot downgrade a durable helper total.
        model.publishChatStats(old,sessionID:"chat-child"); model.publishChatStats(old,sessionID:"chat-side")
        XCTAssertEqual(model.conversationFamily("chat-parent").agents.members.first?.spend,0.60)
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.first?.spend,0.75)
    }
    @MainActor func testNestedSavedForksAndTheirAgentsStayReachableInTreeOrderAndSearch() throws {
        let model = try fixture()
        var fork = try XCTUnwrap(model.record("chat-side")); fork.id = "nested-fork"; fork.title = "Nested review"; fork.parentSessionID = "chat-side"
        var deep = fork; deep.id = "deep-fork"; deep.title = "Deep review"; deep.parentSessionID = fork.id
        model.chats.append(contentsOf: [fork, deep])
        let original = try XCTUnwrap(model.record("chat-child"))
        for owner in ["chat-side", fork.id, deep.id] {
            var child = original; child.id = owner + "-agent"; child.parentSessionID = owner
            child.delegation?.childSessionID = child.id; child.delegation?.budgetOwnerSessionID = owner; child.delegation?.call.parentSessionID = owner
            child.subagentNumber = 1; child.title = "Review " + owner
            model.chats.append(child)
        }
        let family = model.conversationFamily("chat-parent")
        XCTAssertEqual(family.sides.map(\.id), ["chat-side", fork.id, deep.id])
        XCTAssertEqual(family.agentCount, 4)
        let picker = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: picker).filter { $0.accessibilityIdentifier().hasPrefix("open-") }
        XCTAssertEqual(rows.map { $0.accessibilityIdentifier() }, ["open-side-chat-side", "open-side-nested-fork", "open-side-deep-fork",
            "open-agent-deep-fork-agent", "open-agent-nested-fork-agent", "open-agent-chat-side-agent", "open-agent-chat-child"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, 2, 1, 0])
        XCTAssertEqual(rows.map(\.titleInset), [30, 44, 58, 72, 58, 44, 30])
        XCTAssertTrue(rows[3].accessibilityLabel()?.contains("in Deep review") == true)
        var totals = GatewayTotals(); totals.costUSD = 0.04; totals.costSamples = 1
        model.publishChatStats(totals, sessionID: deep.id)
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.last?.spend, 0.04)
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            XCTAssertEqual(model.sidebarChatOrder, ["chat-parent"])
            for chat in model.chats where chat.id != "chat-parent" {
                XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: chat.title).entries.map(\.id).contains("chat|" + chat.id), chat.id)
            }
        }
        model.chats[model.chats.firstIndex { $0.id == fork.id }!].archivedAt = Date()
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.map(\.id), ["chat-side", fork.id, deep.id])
        let leaf = try XCTUnwrap(model.record("deep-fork-agent"))
        model.subagentSummaries[leaf.id] = .init(link: leaf.delegation!, description: leaf.title, model: "fixture", status: .running, revision: 1)
        XCTAssertEqual(model.conversationFamily("chat-parent").activity.runningAgents, 1, "Activity invalidates every ancestor's cached family")
        XCTAssertEqual(model.subagentFamily(deep.id).members.map(\.chat.id), [leaf.id], "Display grouping never reparents delegation authority")
    }
    @MainActor func testNestedForkOpensBesideItsActualParentWithTheRootFamilyStillAvailable() async throws {
        let model = try fixture()
        var fork = try XCTUnwrap(model.record("chat-side")); fork.id = "nested-fork"; fork.parentSessionID = "chat-side"; model.chats.append(fork)
        model.historyWindowLoader = { _, _, _, _ in try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]), "incarnation": .string("fixture"), "lineage": .string("root"), "older": .null, "newer": .null])) }
        await model.openFamilySide(fork.id)
        XCTAssertEqual(model.selectedID, "chat-side"); XCTAssertEqual(model.focusedSessionID, fork.id)
        XCTAssertEqual(model.sides["chat-side"]?.id, fork.id)
        XCTAssertEqual(model.record(fork.id)?.parentSessionID, "chat-side")
        let header = AgentFamilyHeaderView(); header.update(model: model, sessionID: "chat-side", enabled: true)
        XCTAssertEqual(header.button.title, "2 sides · 1 agent")
        var owners: [String] = []
        let subscription = model.agentFamilyRequests.sink { owners.append($0) }; defer { subscription.cancel() }
        model.showAgentFamily(); XCTAssertEqual(owners, ["chat-parent"])
        XCTAssertEqual(model.selectionToRemember.shownSides?["chat-side"], fork.id)
    }
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats[1].subagentNumber = 2
        let parent = SessionDisplay(id: "chat-parent"); parent.historyState = .ready
        model.displays[parent.id] = parent; model.selected = parent
        model.selectedID = parent.id; model.focusedSessionID = parent.id
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        return model
    }
    @MainActor func testOpenPickerRemeasuresItsDocumentWhenFamilyRowsChange() throws {
        let model = try fixture(), child = try XCTUnwrap(model.record("chat-child"))
        let picker = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let document = PiPopoverPresenter.NativeDocument(content: picker, width: 400, room: 480)
        let controller = NSViewController(); document.controller = controller
        document.layoutSubtreeIfNeeded(); let before = document.frame.height
        document.needsLayout = false
        for index in 0..<7 {
            var next = child; next.id = "new-agent-\(index)"; next.delegation?.childSessionID = next.id; next.subagentNumber = index + 3
            model.chats.append(next)
        }
        picker.refresh()
        XCTAssertTrue(document.needsLayout, "The document, not only the rebuilt stack, must remeasure")
        document.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(document.frame.height, before)
        XCTAssertEqual(document.frame.height, picker.height(forWidth: 400))
        XCTAssertEqual(controller.preferredContentSize.height, 480)
        model.chats.removeAll { $0.id.hasPrefix("new-agent-") }; picker.refresh(); document.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.frame.height, before)
        XCTAssertEqual(controller.preferredContentSize.height, before)
    }
    @MainActor func testNormalTopicsAndFlatOmitSidesIncludingPinnedAndOpenDraftsButSearchFindsSavedSides() throws {
        let model = try fixture()
        model.chats[2].pinnedAt = Date()
        model.openSide()
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            let rows = SubagentOrganizationTests.contents(model).entries
            XCTAssertEqual(rows.compactMap { if case .chat(let chat, _, _) = $0 { return chat.id }; return nil }, ["chat-parent"])
            XCTAssertFalse(rows.contains { if case .side = $0 { return true }; return false })
            XCTAssertEqual(model.sidebarChatOrder, ["chat-parent"])
            XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: "side").entries.map(\.id).contains("chat|chat-side"))
        }
    }
    @MainActor func testOneMainColumnPickerListsSidesAndAgentsAndOffersNewSide() throws {
        let model = try fixture()
        let header = AgentFamilyHeaderView(); header.update(model: model, sessionID: "chat-parent", enabled: true)
        XCTAssertFalse(header.isHidden); XCTAssertEqual(header.button.title, "1 side · 1 agent")
        let popover = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let buttons = ConversationPaneTests.views(PiKit.ButtonBase.self, in: popover)
        XCTAssertEqual(buttons.filter { $0.accessibilityIdentifier().hasPrefix("open-") }.map { $0.accessibilityIdentifier() }, ["open-side-chat-side", "open-agent-chat-child"])
        XCTAssertNotNil(buttons.first { $0.title == "New Side" })
        XCTAssertTrue(model.sessionOpenings.isEmpty)
        model.chats.removeAll { $0.parentSessionID != nil }
        header.update(model: model, sessionID: "chat-parent", enabled: true)
        XCTAssertTrue(header.isHidden)
    }
    @MainActor func testQueuedAgentsAreNotLabelledRunningAndWorkingSidesAreIncluded() throws {
        let model = try fixture()
        let original = try XCTUnwrap(model.record("chat-child"))
        for index in 0..<4 {
            var child = original; child.id = "agent-\(index)"; child.delegation?.childSessionID = child.id; child.subagentNumber = index + 1
            model.chats.append(child)
            model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture",
                status: index < 2 ? .running : .queued, revision: 1)
        }
        model.chats.removeAll { $0.id == original.id }
        let side = SessionDisplay(id: "chat-side"); side.runState = .running; model.displays[side.id] = side
        XCTAssertEqual(model.subagentFamily("chat-parent").runningCount, 2)
        let header = AgentFamilyHeaderView(); header.update(model: model, sessionID: "chat-parent", enabled: true)
        XCTAssertEqual(header.button.title, "1 side · 4 agents")
        let label = header.button.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("1 side working"), label)
        XCTAssertTrue(label.contains("2 sub-agents running"), label)
        XCTAssertTrue(label.contains("2 sub-agents queued"), label)
    }
    @MainActor func testPickerKeepsNewSideDraftInMemoryOnly() throws {
        let model = try fixture(), saved = model.chats
        model.openSide()
        let side = try XCTUnwrap(model.sides["chat-parent"])
        model.displays[side.id]?.draft = "An unsent side draft"
        let header = AgentFamilyHeaderView(); header.update(model: model, sessionID: "chat-parent", enabled: true)
        XCTAssertEqual(header.button.title, "2 sides · 1 agent")
        let popover = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let new = try XCTUnwrap(ConversationPaneTests.views(PiKit.ButtonBase.self, in: popover).first { $0.title == "New Side" })
        new.onPress?()
        XCTAssertEqual(model.sides["chat-parent"]?.id, side.id)
        XCTAssertEqual(model.displays[side.id]?.draft, "An unsent side draft")
        XCTAssertTrue(model.isEphemeral(side.id)); XCTAssertTrue(model.sides["chat-parent"]?.pending == true)
        XCTAssertEqual(model.chats, saved); XCTAssertTrue(model.sessionOpenings.isEmpty)
    }
    @MainActor func testSidebarBadgeTracksLiveSidesWithoutRebuildingTheParentTranscript() async throws {
        let model = try fixture(), parent = try XCTUnwrap(model.record("chat-parent"))
        let sidebar = SidebarChatRowView(model: model, chat: parent, state: .init(available: 220), projectID: parent.workspaceID, glide: PiKit.SelectionGlide())
        let side = SessionDisplay(id: "chat-side"); model.displays[side.id] = side
        side.runState = .running
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(sidebar.body.content?.familyActivity.workingSides, 1)
        XCTAssertTrue(sidebar.row.accessibilityLabel()?.contains("1 side working") == true)
        XCTAssertEqual(ConversationPaneTests.views(PiSpinnerView.self, in: sidebar).count, 1)
        let badge = try XCTUnwrap(ConversationPaneTests.views(AgentRunningBadge.self, in: sidebar).first)
        XCTAssertEqual(badge.toolTip, "1 side working")
        side.runState = .idle
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(badge.isHidden)
        XCTAssertTrue(ConversationPaneTests.views(PiSpinnerView.self, in: sidebar).isEmpty)
    }
    @MainActor func testSideStatusesAndSpendRefreshFromExistingUsage() throws {
        let model = try fixture()
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.first?.status, "Saved")
        model.readStatesRestored = true
        model.unreadStates["chat-side"] = .init(id: "chat-side", observedAssistantCount: 1, latestAssistantID: "reply", unreadOutputs: 1)
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.first?.status, "New reply")
        model.unreadStates["chat-side"]?.unreadFailure = true
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.first?.status, "Failed")
        var totals = GatewayTotals(); totals.costUSD = 0.123; totals.costSamples = 1
        model.publishChatStats(totals, sessionID: "chat-side")
        XCTAssertEqual(model.conversationFamily("chat-parent").sides.first?.spend, 0.123)
        XCTAssertEqual(model.conversationFamily("chat-side").ownerID, "chat-side")
    }
    @MainActor func testPickerOpensSavedSideAndReusesItBesideTheParent() async throws {
        let model = try fixture()
        model.historyWindowLoader = { _, _, _, _ in try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]), "incarnation": .string("fixture"), "lineage": .string("root"), "older": .null, "newer": .null])) }
        model.tabs.open(kind: HostedTab.kind, key: "file") { HostedTab(key: "file", title: "File", symbol: "doc") }
        await model.openFamilySide("chat-side")
        XCTAssertEqual(model.selectedID, "chat-parent"); XCTAssertEqual(model.focusedSessionID, "chat-side")
        XCTAssertEqual(model.sides["chat-parent"]?.id, "chat-side"); XCTAssertTrue(model.tabs.pane.sideShown)
        let display = model.displays["chat-side"]
        await model.openFamilySide("chat-side")
        XCTAssertTrue(display === model.displays["chat-side"])
        XCTAssertEqual(model.selectionToRemember.shownSides, ["chat-parent": "chat-side"])
        XCTAssertTrue(model.sessionOpenings.isEmpty)
    }
    @MainActor func testLegacyPanelPinIsIgnoredAndUnsavedSideDraftNeverPersists() async throws {
        let model = try fixture()
        let old = Data(#"{"chatID":"chat-parent","projectID":"pane-project","shownSides":{"chat-parent":"chat-side"},"sidesPanelPinned":true,"revision":1}"#.utf8)
        let remembered = try JSONDecoder().decode(RememberedSelection.self, from: old)
        XCTAssertEqual(remembered.shownSides, ["chat-parent": "chat-side"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self).contains("sidesPanelPinned"))
        model.openNewFamilySide("chat-parent")
        let info = try XCTUnwrap(model.sides["chat-parent"]), view = try XCTUnwrap(model.displays[info.id])
        view.draft = "Unsent ephemeral text"; model.draftChanged(view)
        await model.flushSelection()
        XCTAssertNil(model.selectionToRemember.shownSides?["chat-parent"])
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: info.id)
        let chat = try await model.store?.get(ChatRecord.self, kind: "chat", id: info.id)
        XCTAssertNil(draft); XCTAssertNil(chat)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.root.appendingPathComponent("Workspaces/pane-project/Sessions/side_" + info.id + ".jsonl").path))
    }
    @MainActor func testOrphanedAndCrossProjectSidesRemainFindableAsMainChats() throws {
        let model = try fixture()
        model.chats[2].parentSessionID = "deleted"
        XCTAssertTrue(SubagentOrganizationTests.contents(model).entries.map(\.id).contains("chat|chat-side"))
        model.chats[2].parentSessionID = "chat-parent"; model.chats[2].workspaceID = "other-project"
        XCTAssertTrue(model.conversationFamily("chat-parent").sides.isEmpty)
        XCTAssertNil(model.sideFamilyOwner(model.chats[2]))
    }

    @MainActor func testEmbeddedReadersNeverRevealASecondPillOnFamilyActivity() async throws {
        let model = try fixture(), chat = try XCTUnwrap(model.record("chat-child"))
        let child = SessionDisplay(id: chat.id); child.historyState = .ready; model.displays[chat.id] = child
        let side = SessionDisplay(id: "chat-side"); model.displays[side.id] = side
        let pane = ConversationPaneView(model: model); pane.showsAgentFamily = false; pane.show(session: child, chat: chat)
        XCTAssertTrue(pane.agentFamilyHeader.isHidden)
        model.subagentSummaries[chat.id] = .init(link: chat.delegation!, description: chat.title, model: "fixture", status: .running, revision: 1)
        for _ in 0..<20 { await Task.yield() }
        side.runState = .running
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(pane.agentFamilyHeader.isHidden, "Only the main column owns the combined picker")
    }

    @MainActor func testNewSideHeaderFitsBesideTheMainPillAtNarrowWidths() throws {
        let model = try fixture(); model.openNewFamilySide("chat-parent")
        let info = try XCTUnwrap(model.sides["chat-parent"]), display = try XCTUnwrap(model.displays[info.id])
        let header = SideHeaderView(model: model)
        header.update(side: info, chat: info.chat, session: display, boundary: "Draft side · created when you send", detail: "Created when you send", loading: false)
        for width: CGFloat in [310, 186, 600, 310] {
            header.frame = CGRect(x: 0, y: 0, width: width, height: header.height(forWidth: width)); header.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(header.minimumWidth, width)
            for control in ConversationPaneTests.views(PiKit.IconButton.self, in: header) where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.convert(control.bounds, to: header)
                XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, width)
            }
        }
    }

    @MainActor func testSavedSideRetainsItsOwnDelegationFamilyAndIsReachableFromTheMainPicker() throws {
        let model = try fixture()
        var child = try XCTUnwrap(model.record("chat-child")); child.id = "side-agent"; child.subagentNumber = 1
        child.parentSessionID = "chat-side"; child.delegation?.childSessionID = child.id; child.delegation?.budgetOwnerSessionID = "chat-side"
        model.chats.append(child)
        XCTAssertEqual(model.conversationFamily("chat-side").agents.ownerID, "chat-side")
        XCTAssertEqual(model.conversationFamily("chat-side").agents.members.map(\.chat.id), [child.id])
        let popover = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        XCTAssertTrue(ConversationPaneTests.views(PiKit.ButtonBase.self, in: popover).contains { $0.accessibilityIdentifier() == "open-agent-side-agent" })
        let header = AgentFamilyHeaderView(); header.update(model: model, sessionID: "chat-parent", enabled: true)
        XCTAssertEqual(header.button.title, "1 side · 2 agents")
        model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture", status: .running, revision: 1)
        XCTAssertEqual(model.conversationFamily("chat-parent").activity.runningAgents, 1)
        XCTAssertEqual(model.subagentFamily("chat-parent").members.map(\.chat.id), ["chat-child"], "The side's agents are displayed together without changing delegation ownership")
        model.focusedSessionID = "chat-side"
        XCTAssertTrue(model.canShowAgentFamily, "The side's menu reaches the main column picker")
        let side = try XCTUnwrap(model.record("chat-side")), session = SessionDisplay(id: side.id)
        let entries = ConversationActionsMenu.entries(model: model, session: session, chat: side)
        let action = try XCTUnwrap(entries.compactMap { entry -> PiMenuItem? in
            if case .item(let item) = entry, item.title == "Sides and Agents…" { return item }; return nil
        }.first)
        var owners: [String] = []
        let subscription = model.agentFamilyRequests.sink { owners.append($0) }
        defer { subscription.cancel() }
        action.perform()
        XCTAssertEqual(owners, ["chat-parent"], "The side actions menu must address the visible main picker, not its hidden header")
    }
    @MainActor func testPickerFitsSixCompactRowsAndFormatsSpendInCents() throws {
        let model = try fixture(), original = try XCTUnwrap(model.record("chat-child"))
        for index in 0..<3 {
            var child = original; child.id = "extra-\(index)"; child.delegation?.childSessionID = child.id; child.subagentNumber = index + 3
            model.chats.append(child)
        }
        var side = try XCTUnwrap(model.record("chat-side")); side.id = "second-side"; model.chats.append(side)
        var totals = GatewayTotals(); totals.costUSD = 0.025; totals.costSamples = 1
        model.publishChatStats(totals, sessionID: "chat-side")
        let popover = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        XCTAssertLessThanOrEqual(popover.height(forWidth: 400), 480)
        let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.ButtonBase.self, in: popover).first { $0.accessibilityIdentifier() == "open-side-chat-side" })
        XCTAssertTrue(open.accessibilityLabel()?.contains("$0.03") == true)
        XCTAssertFalse(open.accessibilityLabel()?.contains("Reported") == true)
        XCTAssertTrue(ConversationPaneTests.views(PiKit.ButtonBase.self, in: popover).filter { $0.title == "Open" }.isEmpty)
        for (amount, expected) in [(0.00042, "$0.00042"), (0.00000001, "<$0.000001"), (0, "$0.00")] {
            totals.costUSD = amount; model.publishChatStats(totals, sessionID: "chat-side"); popover.refresh()
            let row = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self, in: popover).first { $0.accessibilityIdentifier() == "open-side-chat-side" })
            XCTAssertTrue(row.accessibilityLabel()?.contains(expected) == true, expected)
        }
    }

}
