import AppKit
import XCTest
@testable import PiApp

/// Real production helper, isolated app host and generated loopback provider.
final class SubagentCodexIntegrationTests: XCTestCase, SerialTestLane {
    @MainActor func testNamedForkSiblingQueueReceivingTurnAndInterrupt() async throws {
        let setup = try await gatewayWorkspace("codex-app", projectID: "codex-app", chatBriefs: false,
            gatewayEnvironment: ["PI_APP_UI_FIXTURE_CODEX_AGENTS": "1"])
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        addTeardownBlock { @MainActor in
            for name in ["release-audit", "release-interrupt", "release-codex-followup"] {
                try? Data().write(to: setup.root.appendingPathComponent(name))
            }
            model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
            if let folder = testEnvironment("PI_APP_CODEX_EVIDENCE") {
                let destination = URL(fileURLWithPath: folder)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: setup.root, to: destination)
            }
        }
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: UUID().uuidString, workspaceID: setup.workspace.id, title: "Main", profileID: setup.profile.id)
        model.chats = [parent]; try await model.store?.put(parent, kind: "chat", id: parent.id)
        let host = try await model.open(parent)
        XCTAssertTrue(host.supportsCodexAgents, "Real handshake advertises the v4 capability")
        func submit(_ text: String) async throws {
            _ = try await host.request("turn.submit", sessionID: parent.id, params: ["text": .string(text), "clientTurnId": .string(UUID().uuidString)])
        }
        func settled() async throws {
            try await eventually("Parent settles without pending queue-only mail holding it open", timeout: .seconds(30), until: {
                try await host.request("session.status", sessionID: parent.id).object?["state"]?.string == "idle"
            })
        }
        try await submit("Earlier context sentinel"); try await settled()
        try await submit("codex app family")
        try await eventually("Named fork and fresh child are discovered", timeout: .seconds(30)) {
            model.chats.filter { $0.isSubagent }.count == 2 && model.subagentSummaries.values.contains { $0.taskName == "/root/tests" && $0.status == .completed }
        }
        let audit = try XCTUnwrap(model.chats.first { $0.subagentTaskName == "/root/audit" })
        let tests = try XCTUnwrap(model.chats.first { $0.subagentTaskName == "/root/tests" })
        XCTAssertEqual(audit.displayTitle, "audit"); XCTAssertEqual(tests.displayTitle, "tests")
        XCTAssertEqual(audit.title, "codex audit task")
        await model.openSubagent(SubagentTarget(try XCTUnwrap(audit.delegation)))
        let auditView = try XCTUnwrap(model.displays[audit.id])
        XCTAssertTrue(auditView.supportsCodexAgents)
        XCTAssertEqual(model.subagentTab(audit.id)?.title, "audit")
        let inherited = auditView.presentedMessages.filter { $0.nativeInherited != nil }
        XCTAssertFalse(inherited.isEmpty)
        XCTAssertTrue(inherited.allSatisfy { $0.earlierVersion == true })
        let folds = TaskTranscriptPlan.items(auditView.presentedMessages, lifecycle: nil).compactMap { item -> TurnFoldSpec? in
            if case .block(let block) = item { return block.foldSummary }; return nil
        }
        XCTAssertTrue(folds.contains { $0.label.hasPrefix("Started with the main chat's context · ") })
        XCTAssertTrue(auditView.presentedMessages.flatMap { AgentMessagePresentation($0).events }.contains { $0.title == "main · New task" })
        await model.openSubagent(SubagentTarget(try XCTUnwrap(tests.delegation)))
        let testsView = try XCTUnwrap(model.displays[tests.id])
        XCTAssertTrue(testsView.presentedMessages.allSatisfy { $0.nativeInherited == nil }, "Fresh child has no inherited prefix")
        try Data().write(to: setup.root.appendingPathComponent("release-audit"))
        try await settled()
        // A hidden child relinquishes its reader. Revisit it through the
        // normal attachment path before inspecting its newly saved mail.
        await model.openSubagent(SubagentTarget(try XCTUnwrap(audit.delegation)))
        do {
            try await eventually("Sibling send projects queue-only idle state") {
                auditView.presentedMessages.flatMap { $0.tools ?? [] }.contains { $0.name == "send_message" && SubagentToolView($0).label == "Waiting for its next turn" }
            }
        } catch {
            print("Codex source tools:", auditView.presentedMessages.flatMap { $0.tools ?? [] }.map { "\($0.name): \(SubagentToolView($0).label)" })
            print("Codex coordination:", auditView.agentCoordination)
            throw error
        }
        let mailTool = try XCTUnwrap(auditView.presentedMessages.flatMap { $0.tools ?? [] }.first { $0.name == "send_message" })
        let pending = SubagentToolView(mailTool)
        XCTAssertEqual(pending.heading, "To tests")
        XCTAssertFalse(try XCTUnwrap(pending.target).isHistorical(in: audit.id))
        XCTAssertFalse(testsView.presentedMessages.flatMap { AgentMessagePresentation($0).events }.contains { $0.kind == "MESSAGE" })
        let mainView = try XCTUnwrap(model.displays[parent.id])
        try await eventually("Full final answer reaches main") {
            mainView.presentedMessages.flatMap { AgentMessagePresentation($0).events }.contains { $0.title == "audit · Final answer" && $0.text.hasSuffix("FINAL-ANSWER-TAIL") }
        }
        let firstTools = mainView.presentedMessages.flatMap { $0.tools ?? [] }
        XCTAssertTrue(firstTools.contains { $0.name == "spawn_agent" && SubagentToolView($0).heading == "Started audit" })
        XCTAssertTrue(firstTools.contains { $0.name == "list_agents" && SubagentToolView($0).result.contains("audit") })
        XCTAssertTrue(firstTools.contains { $0.name == "wait_agent" && SubagentToolView($0).result.hasPrefix("Wait ") })
        let queued = try await host.request("subagent.list", sessionID: parent.id, params: ["detail": .string("messages"), "childId": .string(tests.id)])
        XCTAssertTrue(queued.object?["messages"]?.array?.contains { $0.object?["deliveryState"]?.string == "waiting_next_turn" } == true)

        await model.openSubagent(SubagentTarget(try XCTUnwrap(tests.delegation)))
        try await submit("codex app follow up")
        try await eventually("Queued sibling mail arrives in the next child turn", timeout: .seconds(20)) {
            testsView.presentedMessages.flatMap { AgentMessagePresentation($0).events }.contains { $0.title == "audit → tests · Message" && $0.turn == 2 }
        }
        let delivered = try XCTUnwrap(testsView.presentedMessages.flatMap { AgentMessagePresentation($0).events }.first { $0.kind == "MESSAGE" })
        XCTAssertEqual(delivered.text, "Queued sibling **finding**.")
        let ownerPath = URL(fileURLWithPath: try XCTUnwrap(model.record(parent.id)?.path))
        let coordination = try await model.history.agentCoordination(path: ownerPath, ownerID: parent.id)
        let entry = try XCTUnwrap(coordination.entries.first { $0.id == delivered.eventID })
        XCTAssertEqual(entry.turn, 2, "The delivered receiving turn replaces the idle acceptance turn")
        XCTAssertEqual(entry.disposition, "delivered")
        await model.openAgentSource(.init(childID: delivered.childID, turn: delivered.turn, eventID: delivered.eventID), from: tests.id)
        XCTAssertEqual(model.displays[audit.id]?.reveal?.toolCallID, entry.sourceToolCallID, "Source returns to the sending sibling's exact tool")
        let details = try await host.request("subagent.list", sessionID: parent.id, params: ["detail": .string("messages"), "childId": .string(tests.id)])
        XCTAssertEqual(details.object?["messages"]?.array?.first { $0.object?["event_id"]?.string == delivered.eventID }?.object?["turn"]?.number, 2)
        try Data().write(to: setup.root.appendingPathComponent("release-interrupt"))
        try await settled()
        try await eventually("Follow-up and interrupt receipts are projected") {
            let tools = mainView.presentedMessages.flatMap { $0.tools ?? [] }
            return tools.contains { $0.name == "followup_task" && SubagentToolView($0).heading == "New task for tests · turn 2" }
                && tools.contains { $0.name == "interrupt_agent" && SubagentToolView($0).result == "Previous status: running" }
        }
        XCTAssertNil(model.error)
    }
}
