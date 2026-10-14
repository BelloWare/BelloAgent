import XCTest
@testable import PiAgentCore

final class SubagentRecoveryTests: XCTestCase {
    func testSavedChildTerminalIsAdoptedExactlyOnceWithoutRunningAnything() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let expected = SubagentToolResult(plan: fixture.plan, status: .completed, text: "durable answer", messageIDs: ["final"], began: true)
        try fixture.write(childStatus: .running, terminal: expected)
        for _ in 0..<2 {
            let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, "result")
            XCTAssertEqual(rows.first?.text, expected.envelope.encoded()); XCTAssertEqual(rows.first?.nativeSubagent, expected.metadata)
            let paused = await parent.queuePaused, running = await parent.isRunning, continuable = await parent.canContinue
            XCTAssertTrue(paused); XCTAssertFalse(running); XCTAssertTrue(continuable)
            await parent.close()
        }
    }

    func testEachCreationBoundaryBecomesAnExplicitNonReplayableResult() async throws {
        for stage in ["no-plan", "plan-only", "queued", "running", "admitted", "dispatched"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(plan: stage != "no-plan", childStatus: ["queued", "running", "admitted", "dispatched"].contains(stage) ? (stage == "queued" ? .queued : .running) : nil,
                              admission: stage == "admitted" || stage == "dispatched" ? stage : nil)
            let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
            let result = try XCTUnwrap(rows.first), envelope = try JSON.parse(Data(result.text.utf8))
            XCTAssertEqual(envelope["status"].text, ["no-plan", "plan-only", "queued"].contains(stage) ? "not_executed" : "interrupted", stage)
            let spend = await parent.spend
            XCTAssertEqual(spend.unreported, stage == "dispatched" ? 1 : 0, stage)
            await parent.close()
        }
    }

    func testMarkerOnlyChildCreationIsCompletedFromTheDurableParentPlan() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued, damage: "incomplete-origin")
        let parent = try fixture.open(), result = await parent.history.first { $0.toolName == "subagent" }
        XCTAssertEqual(result?.nativeSubagent?["status"].text, "not_executed")
        await parent.close()
        let child = try fixture.openChild(), origin = await child.subagents.origin, status = await child.subagents.status
        XCTAssertEqual(origin, fixture.plan.origin); XCTAssertEqual(status, .notExecuted)
        await child.close()
    }

    func testReciprocalIdentityAndSavedResultIdentityAreRequired() async throws {
        for damaged in ["origin", "result", "marker", "result-status", "result-ref"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            var terminal = SubagentToolResult(plan: fixture.plan, status: .completed, text: "answer")
            if damaged == "result" { terminal.metadata["sessionId"] = "unrelated" }
            if damaged == "result-status" { terminal.metadata["status"] = "failed" }
            if damaged == "result-ref" { terminal.metadata["resultRef"] = ["messageIds":["missing"]] }
            try fixture.write(childStatus: .running, terminal: terminal, damage: damaged)
            XCTAssertThrowsError(try fixture.open(), damaged)
        }
    }

    func testRecoveredChildCostUsesOnlyTheOwnersRegisteredPhysicalAttempt() async throws {
        for ownerHasCost in [false, true] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(childStatus: .running, admission: "dispatched", ownerCost: ownerHasCost, childCost: !ownerHasCost)
            for _ in 0..<2 {
                let parent = try fixture.open(), total = await parent.spend
                XCTAssertEqual(total.usd, 0.75); XCTAssertEqual(total.reported, 1); XCTAssertEqual(total.unreported, 0)
                await parent.close()
            }
            let child = try fixture.openChild(), total = await child.spend
            XCTAssertEqual(total.usd, 0.75); XCTAssertEqual(total.reported, 1)
            await child.close()
        }
    }

    func testRecoveredChildReaderCanUnloadBeforeOpeningItsParent() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path),"resources":["codexHome":JSON(fixture.root.appendingPathComponent("codex").path)]])
        _ = try await host.command("session.open", sessionID: "child", params: ["profile":fixture.profile.raw,"apiKey":"fixture","path":JSON(fixture.root.appendingPathComponent("child.jsonl").path)])
        _ = try await host.command("session.close", sessionID: "child", params: [:])
        for id in ["parent", "child"] {
            _ = try await host.command("session.open", sessionID: id, params: ["profile":fixture.profile.raw,"apiKey":"fixture","path":JSON(fixture.root.appendingPathComponent(id + ".jsonl").path)])
        }
        let state = try await host.command("session.snapshot", sessionID: "parent", params: [:])
        XCTAssertEqual(state["state"].text, "paused")
        await host.shutdown()
    }

    func testReopenedChildKeepsItsParentsCapturePolicy() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path)])
        _ = try await host.command("session.open", sessionID: "parent", params: ["profile":fixture.profile.raw,"apiKey":"fixture","captureMode":"off","path":JSON(fixture.root.appendingPathComponent("parent.jsonl").path)])
        let child = try await host.command("session.open", sessionID: "child", params: ["profile":fixture.profile.raw,"apiKey":"fixture","captureMode":"persist","path":JSON(fixture.root.appendingPathComponent("child.jsonl").path)])
        XCTAssertEqual(child["captureMode"].text, "off")
        do { _ = try await host.command("debug.mode", sessionID: "child", params: ["mode":"memory"]); XCTFail("Child policy changed") }
        catch let error as AgentError { XCTAssertEqual(error.code, "managed_subagent") }
        await host.shutdown()
    }

    func testTerminalRecordIsSynchronizedBeforeReturningTheResult() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let child = try fixture.openChild(), before = await child.journal?.synchronizations
        try await child.saveSubagentTerminal(SubagentToolResult(plan: fixture.plan, status: .notExecuted))
        let after = await child.journal?.synchronizations
        XCTAssertEqual(after, (before ?? 0) + 1)
        await child.close()
    }

    func testUnregisteredChildCostCannotBeImported() throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, childCost: true)
        XCTAssertThrowsError(try fixture.open())
    }

    func testOldHelpersExistingResultIsPreservedDuringReupgrade() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, terminal: SubagentToolResult(plan: fixture.plan, status: .completed, text: "child complete"), oldResult: true)
        let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, "old-result"); XCTAssertEqual(rows.first?.text, "Old helper: outcome unknown")
        let savedAssistant = await parent.history.first { $0.id == "reply" }
        let assistant = try XCTUnwrap(savedAssistant)
        let displayed = await parent.displayMessage(assistant)
        XCTAssertEqual(displayed["tools"].list.first?["subagent"]["link"]["childSessionID"].text, "child")
        XCTAssertEqual(displayed["tools"].list.first?["subagent"]["status"].text, "interrupted")
        await parent.close()
    }
}

private struct RecoveryFixture {
    let root: URL, profile: Profile
    let plan = SubagentPlan(origin: subagentFixtureOrigin(), task: "task", resultMessageID: "result")
    init() throws { root = try temporaryDirectory(); profile = try fixtureProfile() }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(plan hasPlan: Bool = true, childStatus: SubagentStatus? = nil, terminal: SubagentToolResult? = nil,
               admission: String? = nil, ownerCost: Bool = false, childCost: Bool = false, damage: String? = nil, oldResult: Bool = false) throws {
        let parent = try SessionJournal(url: root.appendingPathComponent("parent.jsonl"), id: "parent", cwd: root, binding: profile.binding, create: true)
        var task = ChatMessage(role: "user", content: [textBlock("task")]); task.id = "turn"
        try parent.append(["type":"message", "message":task.pi], id: task.id)
        var assistant = toolReply([]).message
        assistant.content = [["type":"toolCall","id":"call","name":"subagent","arguments":["task":"task"]]]
        assistant.id = "reply"; assistant.turn = "turn"
        try parent.append(["type":"message", "message":assistant.pi], id: assistant.id)
        if hasPlan { try parent.append(["type":"custom","customType":JSON(JournalRecordKind.subagentCall),"data":try subagentJSON(plan)]) }
        if let admission { var record = admissionRecord("physical"); record["state"] = JSON(admission)
            try parent.append(["type":"custom","customType":JSON(JournalRecordKind.budgetAttempt),"data":record]) }
        let cost = costRecord("physical", usd: 0.75, revision: 2)
        if ownerCost { try parent.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":cost]) }
        if oldResult {
            var result = ChatMessage(role: "toolResult", content: [textBlock("Old helper: outcome unknown")]); result.toolName = "subagent"; result.toolCallId = "call"; result.isError = true; result.toolStats = ["outcome":"unknown"]
            try parent.append(["type":"message","message":result.pi], id: "old-result")
        }
        try parent.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":["active":true,"queue":[],"steering":[],"commands":[]]])
        if let childStatus {
            let child = try SessionJournal(url: root.appendingPathComponent("child.jsonl"), id: "child", cwd: root, binding: profile.binding, create: true, managedChild: damage != "marker")
            if damage == "incomplete-origin" { return }
            var origin = plan.origin
            if damage == "origin" { origin.description = "forged grant" }
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":try subagentJSON(origin)])
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentState),"data":["delegationID":"delegation","status":JSON(childStatus.rawValue)]])
            if childCost { try child.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":cost]) }
            if let terminal, damage != "result-ref" {
                for id in terminal.metadata["resultRef"]["messageIds"].list.compactMap(\.text) {
                    let reply = ChatMessage(role: "assistant", content: [textBlock(terminal.envelope["text"].text ?? "")])
                    try child.append(["type":"message","message":reply.pi], id: id)
                }
            }
            if let terminal { try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentTerminal),"data":["delegationID":"delegation","status":JSON(terminal.status.rawValue),"result":try subagentJSON(terminal)]]) }
        }
    }
    func open() throws -> AgentSession { try session("parent") }
    func openChild() throws -> AgentSession { try session("child") }
    private func session(_ id: String) throws -> AgentSession {
        try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true,
                         resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                         resumePath: root.appendingPathComponent(id + ".jsonl").path)
    }
}
