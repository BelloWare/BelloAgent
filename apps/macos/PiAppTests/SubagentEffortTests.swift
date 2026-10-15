import AppKit
import XCTest
@testable import PiApp

final class SubagentEffortTests: XCTestCase {
    @MainActor func testAcceptedEffortRefreshesAnAlreadyShownHeaderAfterTheChildSnapshot() async throws {
        let (model, original) = try await fixture()
        var found = original; found.header.model.thinkingLevel = "low"; found.header.model.reasoning = ["low", "high"]
        try await model.registerDiscoveredSubagent(found, workspaceID: "pane-project", live: summary(found, effort: "low"))
        let id = found.header.link.childSessionID, display = SessionDisplay(id: found.header.link.childSessionID)
        display.historyState = .ready; display.subagentTurn = 2; display.subagentStatus = .running
        model.displays[id] = display
        let pane = ConversationPaneView(model: model)
        pane.show(session: display, chat: try XCTUnwrap(model.record(id)))
        let header = try XCTUnwrap(ConversationPaneTests.views(SubagentHeaderView.self, in: pane).first)
        func text() -> String { ConversationPaneTests.views(PiKit.TextLine.self, in: header).map { $0.line.text }.joined(separator: " ") }
        XCTAssertTrue(text().contains(" · low"))
        let generation = display.presentationGeneration
        for (accepted, expected) in [("high", "high"), ("default", "model default"), ("low", "low")] {
            // The child's turn/status are already current; only its parent's
            // later accepted-effort summary changes before this refresh.
            model.subagentSummaries[id] = summary(found, effort: accepted, turn: 2)
            pane.refresh()
            XCTAssertTrue(text().contains(" · " + expected), text())
            XCTAssertEqual(display.presentationGeneration, generation)
            XCTAssertEqual(display.subagentTurn, 2)
        }
        model.subagentEfforts[id] = .init(initial: "default", reasoning: [])
        pane.refresh()
        XCTAssertFalse(text().contains(" · low"), "A model without effort controls removes the old label")
        XCTAssertFalse(text().contains("model default"))
    }
    @MainActor private func fixture() async throws -> (WorkspaceModel, DiscoveredSubagent) {
        let root = scratchRoot("subagent-effort")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        try await model.store?.putChats(model.chats)
        let discovered = try await model.history.discoverSubagents(directory: family.path.deletingLastPathComponent(), parents: model.chats)
        let found = try XCTUnwrap(discovered.first)
        let parent = SessionDisplay(id: "chat-parent"); parent.historyState = .ready
        model.displays[parent.id] = parent; model.selected = parent; model.selectedID = parent.id
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        return (model, found)
    }
    private func summary(_ found: DiscoveredSubagent, effort: String?, turn: Int = 1) -> SubagentSummary {
        .init(link: found.header.link, description: found.header.description, model: found.header.model.model,
              status: .running, revision: turn, turn: turn, effort: effort)
    }
    private func tool(_ summary: SubagentSummary, name: String = "subagent_start") -> ToolView {
        var tool = SubagentSteeringPresentationTests.tool
        tool.name = name; tool.nativeSubagent = nil; tool.subagent = summary
        tool.output = "{\"accepted\":true,\"route\":\"follow_up\",\"turn\":\(summary.turn ?? 1)}"
        return tool
    }
    @MainActor private func check(_ model: WorkspaceModel, found: DiscoveredSubagent, summary: SubagentSummary, expected: String?, inspector: Bool = true) async throws {
        let id = found.header.link.childSessionID
        let popup = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let row = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self, in: popup).first { $0.accessibilityIdentifier() == "open-agent-" + id })
        let parent = try XCTUnwrap(model.selected)
        let source = tool(summary)
        let shown = try XCTUnwrap(parent.presentAgentState(.init(id: "call", role: "assistant", text: "", tools: [source])).tools?.first)
        let card = TranscriptNativeSubagentCard(); card.configure(.subagent(SubagentToolView(shown)))
        let display = SessionDisplay(id: id); display.historyState = .ready; model.displays[id] = display
        let pane = ConversationPaneView(model: model); pane.show(session: display, chat: try XCTUnwrap(model.record(id)))
        let header = try XCTUnwrap(ConversationPaneTests.views(SubagentHeaderView.self, in: pane).first)
        let headerText = ConversationPaneTests.views(PiKit.TextLine.self, in: header).map { $0.line.text }.joined(separator: " ")
        let strings = [row.accessibilityLabel() ?? "", SubagentToolView(shown).label, card.accessibilityLabel() ?? "", headerText]
        for text in strings {
            if let expected { XCTAssertTrue(text.contains(" · " + expected), text) }
            else { XCTAssertFalse(text.contains("model default"), text); XCTAssertFalse(text.contains(" · high"), text) }
        }
        XCTAssertEqual(shown.input, source.input); XCTAssertEqual(shown.output, source.output)
        XCTAssertEqual(shown.nativeSubagent, source.nativeSubagent)
        guard inspector else { return }
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        try await model.traces.recordSubagent(summary, workspaceID: "pane-project")
        let inspector = SessionInspectorModel(scope: .init(sessionID: "chat-parent", workspaceID: "pane-project"), title: "Parent", archive: model.traces,
            workspace: model, usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        inspector.setVisible(true); defer { inspector.setVisible(false) }
        for _ in 0..<300 where inspector.groups.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let detail = try XCTUnwrap(inspector.groups.first).detail
        if let expected { XCTAssertTrue(detail.contains(" · " + expected), detail) }
        else { XCTAssertFalse(detail.contains("model default")); XCTAssertFalse(detail.contains(" · high")) }
    }
    @MainActor func testExplicitInheritedDefaultAndUnavailableEffortAcrossVisibleSurfaces() async throws {
        for (requested, accepted, levels, expected) in [
            ("high", "high", ["low", "high"], "high"),
            (nil, "low", ["low", "high"], "low"),
            ("default", "default", ["low", "high"], "model default"),
            (nil, "default", [], nil)
        ] as [(String?, String, [String], String?)] {
            let (model, original) = try await fixture()
            var found = original
            found.header.model.thinkingLevel = requested ?? "low"; found.header.model.reasoning = levels
            let summary = summary(found, effort: accepted)
            try await model.registerDiscoveredSubagent(found, workspaceID: "pane-project", live: summary)
            try await check(model, found: found, summary: summary, expected: expected)
        }
    }
    @MainActor func testFollowUpUpdatesCurrentEffortWithoutRelabellingAnOlderSendReceipt() async throws {
        let (model, original) = try await fixture()
        var found = original; found.header.model.thinkingLevel = "low"; found.header.model.reasoning = ["low", "high"]
        let first = summary(found, effort: "low"), next = summary(found, effort: "high", turn: 2)
        try await model.registerDiscoveredSubagent(found, workspaceID: "pane-project", live: first)
        try await model.registerDiscoveredSubagent(found, workspaceID: "pane-project", live: next)
        try await check(model, found: found, summary: next, expected: "high")
        let parent = try XCTUnwrap(model.selected)
        var old = tool(first, name: "subagent_send")
        old.nativeSubagent = .object(["version": .number(2), "delegationId": .string(first.link.delegationID),
            "sessionId": .string(first.link.childSessionID), "budgetOwnerSessionId": .string(first.link.budgetOwnerSessionID),
            "parentAssistantMessageId": .string("old-call"), "toolCallId": .string("old-send"), "turn": .number(1)])
        let receipt = try XCTUnwrap(parent.presentAgentState(.init(id: "old", role: "assistant", text: "", tools: [old])).tools?.first)
        XCTAssertTrue(SubagentToolView(receipt).label.hasSuffix(" · low"))
        XCTAssertEqual(receipt.subagent?.turn, 1); XCTAssertEqual(receipt.output, old.output)
    }
    @MainActor func testColdDiscoveryRecoversTheLatestTurnEffortWithoutWritingJournals() async throws {
        let (model, found) = try await fixture()
        let child = URL(fileURLWithPath: found.path)
        let handle = try FileHandle(forWritingTo: child); try handle.seekToEnd()
        for (kind, effort, state) in [("pi-app.subagent-turn.v1", "high", nil), ("pi-app.subagent-turn-terminal.v1", nil, "completed")] as [(String, String?, String?)] {
            var turn: [String: WireValue] = ["childID": .string(found.header.link.childSessionID), "turn": .number(2), "executionID": .string("second")]
            turn["effort"] = effort.map(WireValue.string); turn["status"] = state.map(WireValue.string)
            var data = try JSONEncoder().encode(["customType": WireValue.string(kind), "data": .object(turn)]); data.append(10); try handle.write(contentsOf: data)
        }
        try handle.close()
        let bytes = try Data(contentsOf: child)
        await model.reconcileSubagents()
        let saved = try XCTUnwrap(model.subagentSummaries[found.header.link.childSessionID])
        XCTAssertEqual(saved.effort, "high"); XCTAssertEqual(saved.turn, 2)
        try await check(model, found: found, summary: saved, expected: "high", inspector: false)
        XCTAssertEqual(try Data(contentsOf: child), bytes); XCTAssertTrue(model.hosts.isEmpty)
    }
    @MainActor func testSavedSendReceiptsKeepAcceptedEffortWithoutASummary() async throws {
        let (model, original) = try await fixture()
        var found = original; found.header.model.thinkingLevel = "low"; found.header.model.reasoning = ["low", "high"]
        try await model.registerDiscoveredSubagent(found, workspaceID: "pane-project", live: summary(found, effort: "low", turn: 3))
        let parent = try XCTUnwrap(model.selected), link = found.header.link
        for (native, output, expected) in [("high", "low", "high"), (nil, "high", "high"), (nil, "default", "model default"), (nil, nil, "low")] as [(String?, String?, String)] {
            var metadata: [String: WireValue] = ["version": .number(2), "sessionId": .string(link.childSessionID), "delegationId": .string(link.delegationID),
                "budgetOwnerSessionId": .string(link.budgetOwnerSessionID), "parentAssistantMessageId": .string("follow-up"), "toolCallId": .string("send"),
                "turn": .number(2), "route": .string("follow_up"), "status": .string("accepted"), "effects": .string("completed")]
            metadata["effort"] = native.map(WireValue.string)
            var envelope: [String: WireValue] = ["accepted": .bool(true), "child_id": .string(link.childSessionID), "turn": .number(2), "route": .string("follow_up")]
            envelope["effort"] = output.map(WireValue.string)
            let receipt = ToolView(id: "send", name: "subagent_send", state: "completed", input: "{\"child_id\":\"\(link.childSessionID)\",\"message\":\"Check again\"}",
                output: String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self), durationMs: 0, truncated: false, nativeSubagent: .object(metadata))
            // Round-trip the receipt exactly as saved; production has no summary.
            let saved = try JSONDecoder().decode(ToolView.self, from: JSONEncoder().encode(receipt))
            XCTAssertNil(saved.subagent)
            let shown = try XCTUnwrap(parent.presentAgentState(.init(id: "follow-up", role: "assistant", text: "", tools: [saved])).tools?.first)
            XCTAssertEqual(shown.subagentEffort, expected)
            XCTAssertTrue(SubagentToolView(shown).label.hasSuffix(" · " + expected))
            XCTAssertNil(shown.subagent, "Turn 3 must not rewrite the saved turn-2 receipt")
            XCTAssertEqual(shown.nativeSubagent, saved.nativeSubagent); XCTAssertEqual(shown.output, saved.output)
        }
    }
}
