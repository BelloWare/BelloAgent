import XCTest
@testable import PiApp

final class SubagentSteeringInspectorTests: XCTestCase {
    @MainActor func testInspectAgentDeliveryFindsTheConsumingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(workspace, root: root)
        try await workspace.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let attempt = UUID().uuidString
        let metadata: [String:WireValue] = ["attemptId":.string(attempt), "sessionId":.string("child"), "turnId":.string("physical-turn"),
            "purpose":.string("turn"), "api":.string("openai-responses"), "mode":.string("off"), "outcome":.string("completed"),
            "wallTimestamp":.number(Date().timeIntervalSince1970), "messageIds":.array([.string("delivery")])]
        try await workspace.traces.begin(metadata, workspace: "w"); try await workspace.traces.finish(metadata)
        let display = SessionDisplay(id: "child"); display.historyState = .ready
        var row = TranscriptMessage(id: "delivery", role: "user", text: "Agent input", kind: "agent_message")
        row.nativeAgentDelivery = SubagentSteeringPresentationTests.delivery
        display.messages = [row]; workspace.displays[display.id] = display
        let model = SessionInspectorModel(scope: .init(sessionID: "child", workspaceID: "w"), title: "Child", archive: workspace.traces,
            workspace: workspace, usageLoader: { _, _, _ in throw CaptureFailure.unavailable })
        model.follow(display); model.setVisible(true); defer { model.setVisible(false) }
        for _ in 0..<200 where !model.indexLoaded { try await Task.sleep(for: .milliseconds(10)) }
        model.focus(.message("delivery"))
        for _ in 0..<200 where model.page != .request(attempt) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.page, .request(attempt), "Agent provider-role user rows are inputs to a request, not human turn roots")
    }
    func testFamilyGroupNamesTheCurrentTurnAndDeliveryState() {
        var summary = SubagentSteeringPresentationTests.tool.subagent!
        summary.turn = 3; summary.status = .completed; summary.deliveryState = "delivered"
        let group = InspectorSubagentGroup(summary: summary, requests: 6, cost: 0.18, costSamples: 6)
        XCTAssertEqual(group.detail, "Delivered to parent · turn 3 · 6 requests · $0.18")
    }
    func testLiveRequestProjectsTheChildTurnIndependentlyOfCreation() throws {
        var scope = try XCTUnwrap(subagentCaptureScope(source: "child").object)
        scope["childTurn"] = .number(3); scope["parentExecutionID"] = .string("follow-up-parent-execution")
        scope["agentDeliveryIDs"] = .array([.string("steer-3")])
        let metadata: [String:WireValue] = ["attemptId":.string(UUID().uuidString), "sessionId":.string("child"), "turnId":.string("turn"),
            "purpose":.string("compaction"), "api":.string("openai-responses"), "requestScope":.object(scope.merging(["purpose":.string("compaction")], uniquingKeysWith: { _, new in new }))]
        let row = try XCTUnwrap(InspectorRequestRow.live(metadata))
        XCTAssertEqual(row.sessionID, "child"); XCTAssertEqual(row.parentAttemptID, "parent-attempt")
        XCTAssertEqual(row.childTurn, 3)
        XCTAssertEqual(row.agentDeliveryIDs, ["steer-3"])
    }
    func testCoordinationLinksStayWithPhysicalSessionsAndTheOwningProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let source = UUID().uuidString, consumed = UUID().uuidString
        for (session, owner, workspace, id, wall) in [("parent", "parent", "w", source, 20.0), ("child", "parent", "w", consumed, 21),
                                                       ("unrelated", "other", "w", UUID().uuidString, 1), ("child", "parent", "foreign", UUID().uuidString, 0)] {
            var metadata: [String:WireValue] = ["attemptId":.string(id), "sessionId":.string(session), "turnId":.string("turn"), "purpose":.string("turn"),
                "api":.string("openai-responses"), "mode":.string("off"), "outcome":.string("completed"), "wallTimestamp":.number(Date().timeIntervalSince1970 + wall),
                "messageIds":.array([.string("delivery")]), "outputMessageIds":.array([.string("source-call")])]
            if session != "parent" {
                var scope = try XCTUnwrap(subagentCaptureScope(source: session, owner: owner).object)
                scope["childTurn"] = .number(2); scope["parentExecutionID"] = .string("sponsoring-execution")
                scope["agentDeliveryIDs"] = .array([.string("event")])
                metadata["requestScope"] = .object(scope)
            }
            try await archive.begin(metadata, workspace: workspace); try await archive.finish(metadata)
        }
        let entry = AgentCoordinationEntry(id: "event", childID: "child", turn: 2, kind: "steer", author: "parent",
            sourceSessionID: "parent", sourceMessageID: "source-call", sourceToolCallID: "send", recipientID: "child", recipientMessageID: "delivery", disposition: "delivered")
        let linked = try await archive.coordinationRequests([entry], ownerID: "parent", workspaceID: "w")
        XCTAssertEqual(linked.first?.sourceAttemptID, source)
        XCTAssertEqual(linked.first?.consumingAttemptID, consumed)
        let rows = try await archive.inspectorRows(sessionID: "child", workspaceID: "w")
        XCTAssertEqual(rows.rows.first?.childTurn, 2)
        XCTAssertEqual(rows.rows.first?.parentExecutionID, "sponsoring-execution")
        XCTAssertEqual(rows.rows.first?.agentDeliveryIDs, ["event"])
        let wrongOwner = try await archive.coordinationRequests([entry], ownerID: "other", workspaceID: "w")
        XCTAssertNil(wrongOwner.first?.sourceAttemptID); XCTAssertNil(wrongOwner.first?.consumingAttemptID)
        let direct = try await archive.attemptsConsuming("delivery", sessionID: "child", workspaceID: "w")
        XCTAssertEqual(direct, [consumed])
        try await archive.close()
    }

    @MainActor func testJournalProjectsEachTurnSourceDeliveryAndUserStopHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(workspace, root: root)
        workspace.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(workspace), owner = workspace.chats[0]
        let path = URL(fileURLWithPath: try XCTUnwrap(owner.path))
        var bytes = try Data(contentsOf: path)
        func append(_ type: String, _ data: [String:WireValue]) throws {
            bytes.append(try JSONEncoder().encode(WireValue.object(["type":.string("custom"),"customType":.string(type),"data":.object(data)]))); bytes.append(10)
        }
        func key(_ source: String, _ assistant: String, _ tool: String) -> WireValue {
            .object(["parentSessionID":.string(source),"assistantMessageID":.string(assistant),"toolCallID":.string(tool)])
        }
        for number in 2...3 {
            try append("pi-app.agent-operation.v1", ["key":key(owner.id, "follow-up-\(number)", "send-\(number)"), "turn":.object([
                "childID":.string(family.child),"turn":.number(Double(number)),"inputID":.string("input-\(number)")])])
        }
        for (source, id) in [(family.child, "question"), ("foreign", "forged")] {
            try append("pi-app.agent-operation.v1", ["key":key(source, "ask", "report"), "message":.object([
                "id":.string(id),"childID":.string(family.child),"turn":.number(3),"author":.string("subagent"),"kind":.string("question")])])
        }
        try append("pi-app.agent-delivery.v1", ["rowID":.string("inbox-row"),"recipientID":.string(owner.id),"eventIDs":.array([.string("question")]),"committed":.bool(true)])
        try append("pi-app.family-run.v1", ["heldChildren":.array([.string(family.child),.string("foreign")])])
        try bytes.write(to: path)
        let state = try await workspace.history.agentCoordination(path: path, ownerID: owner.id)
        XCTAssertEqual(state.entries.map(\.id), ["input-2", "input-3", "question"])
        XCTAssertEqual(state.entries[1].sourceMessageID, "follow-up-3"); XCTAssertEqual(state.entries[1].sourceToolCallID, "send-3")
        XCTAssertEqual(state.entries[2].sourceSessionID, family.child); XCTAssertEqual(state.entries[2].recipientMessageID, "inbox-row")
        XCTAssertEqual(state.entries[2].disposition, "delivered"); XCTAssertEqual(state.heldChildren, [family.child])
        let cached = try await workspace.history.agentCoordination(path: path, ownerID: owner.id)
        XCTAssertEqual(cached, state)
        try append("pi-app.family-run.v1", ["heldChildren":.array([])])
        try bytes.write(to: path)
        let resumed = try await workspace.history.agentCoordination(path: path, ownerID: owner.id)
        XCTAssertTrue(resumed.heldChildren.isEmpty, "A new epoch invalidates the cached Stop hold")
    }

}
