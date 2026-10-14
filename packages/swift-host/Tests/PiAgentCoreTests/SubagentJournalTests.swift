import XCTest
@testable import PiAgentCore

final class SubagentJournalTests: XCTestCase {
    func testDurableTerminalNotifiesTheOpenChildViewer() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let origin = subagentFixtureOrigin()
        let child = try AgentSession(id: "child", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                                     readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                                     tools: DisabledTools(), traces: TraceStore(), prepared: nil, subagentOrigin: origin)
        let before = await child.sequence
        let plan = SubagentPlan(origin: origin, task: "task", resultMessageID: "result")
        try await child.saveSubagentTerminal(SubagentToolResult(plan: plan, status: .completed, text: "answer"))
        let after = await child.sequence, snapshot = await child.snapshot()
        XCTAssertGreaterThan(after, before, "The viewer must learn that coordinator settlement is complete")
        XCTAssertEqual(snapshot["subagentStatus"].text, "completed")
        await child.close()
    }

    func testFrozenMCPPolicyIsDurableAndCannotBeReplaced() throws {
        var value = try subagentJSON(subagentFixtureOrigin())
        value["mcpPolicy"] = ["server":"original-digest"]
        let origin = try JSONDecoder().decode(SubagentOrigin.self, from: value.data())
        XCTAssertEqual(try subagentJSON(origin)["mcpPolicy"], value["mcpPolicy"])
        var state = SubagentJournalState()
        try state.consume(["type":"custom", "customType":JSON(JournalRecordKind.subagentOrigin), "data":value], sessionID: "child")
        value["mcpPolicy"] = ["server":"changed-digest"]
        XCTAssertThrowsError(try state.consume(["type":"custom", "customType":JSON(JournalRecordKind.subagentOrigin), "data":value], sessionID: "child"))
    }

    func testManagedOriginAndTerminalSurviveCheckpointAndFullReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile()
        var origin = subagentFixtureOrigin(); origin.mcpPolicy = ["server":"original-digest"]
        let s = try AgentSession(id: "child", profile: profile, apiKey: "fixture", cwd: root, directory: root,
                                 readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]),
                                 tools: DisabledTools(), traces: TraceStore(), prepared: nil, subagentOrigin: origin)
        var task = ChatMessage(role: "user", content: [textBlock("task")]); task.id = "task"
        try await s.append(task)
        try await s.appendForTesting([
            ["type":"custom", "customType":JSON(JournalRecordKind.subagentTerminal),
             "data":["delegationID":"delegation", "status":"completed", "text":"answer"]],
            ["type":"custom", "customType":JSON(JournalRecordKind.context), "data":["ids":["task"]]]
        ])
        await s.close()
        func open() throws -> AgentSession {
            try AgentSession(id: "child", profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true,
                             resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: DisabledTools(),
                             traces: TraceStore(), resumePath: root.appendingPathComponent("child.jsonl").path)
        }
        let first = try open(), state = await first.subagents
        XCTAssertEqual(state.origin, origin); XCTAssertEqual(state.status, .completed)
        await first.close()
        XCTAssertNotNil(JournalCheckpoint.read(for: root.appendingPathComponent("child.jsonl")))
        let checkpoint = try open(), saved = await checkpoint.subagents
        XCTAssertEqual(saved, state)
        await checkpoint.close()
        JournalCheckpoint.remove(for: root.appendingPathComponent("child.jsonl"))
        let full = try open(), replayed = await full.subagents
        XCTAssertEqual(replayed, state)
        await full.close()
    }

    func testParentPlanCannotTransferOwnershipToAFork() throws {
        let plan = SubagentPlan(origin: subagentFixtureOrigin(), task: "task", resultMessageID: "result")
        let row: JSON = ["type":"custom", "customType":JSON(JournalRecordKind.subagentCall), "data":try subagentJSON(plan)]
        var state = SubagentJournalState()
        try state.consume(row, sessionID: "parent")
        XCTAssertEqual(state.plans.count, 1)
        state.retarget("fork")
        XCTAssertTrue(state.plans.isEmpty)
        try state.consume(row, sessionID: "fork")
        XCTAssertTrue(state.plans.isEmpty)
    }

    func testConflictingChildOriginIsRejected() throws {
        var origin = subagentFixtureOrigin(), state = SubagentJournalState()
        func row(_ origin: SubagentOrigin) throws -> JSON { ["type":"custom", "customType":JSON(JournalRecordKind.subagentOrigin), "data":try subagentJSON(origin)] }
        try state.consume(row(origin), sessionID: "child")
        origin.link.budgetOwnerSessionID = "other"
        XCTAssertThrowsError(try state.consume(row(origin), sessionID: "child"))
    }

    func testAChildCannotAlsoCarryTheOldWritableMarker() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("child.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: url, id: "child", cwd: root, binding: profile.binding, create: true, managedChild: true)
        try journal?.append(["type":"custom", "customType":JSON(JournalRecordKind.marker), "data":["binding":profile.binding]])
        journal = nil
        XCTAssertThrowsError(try SessionJournal(url: url, id: "child", cwd: root, binding: profile.binding, create: false))
    }

    func testV2ChildOpensWithoutRewritingItsMarker() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("child.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: url, id: "child", cwd: root, binding: profile.binding, create: true)
        journal = nil
        let text = try String(contentsOf: url).replacingOccurrences(of: "pi-app.native.v1", with: "pi-app.native.v2")
        try Data(text.utf8).write(to: url)
        let before = try Data(contentsOf: url)
        journal = try SessionJournal(url: url, id: "child", cwd: root, binding: profile.binding, create: false)
        XCTAssertNotNil(journal)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOrdinaryParentRemainsV1AndOptionalRecordsArePreserved() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("parent.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: url, id: "parent", cwd: root, binding: profile.binding, create: true)
        try journal?.append(["type":"custom", "customType":"future.optional", "data":["retained":true]])
        journal = nil
        let before = try Data(contentsOf: url)
        journal = try SessionJournal(url: url, id: "parent", cwd: root, binding: profile.binding, create: false)
        XCTAssertNotNil(journal)
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("pi-app.native.v1"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

func subagentFixtureOrigin(child: String = "child", parent: String = "parent", call: String = "call") -> SubagentOrigin {
    SubagentOrigin(link: .init(delegationID: "delegation", childSessionID: child, budgetOwnerSessionID: parent,
                              call: .init(parentSessionID: parent, assistantMessageID: "reply", toolCallID: call),
                              parentTurnID: "turn", parentExecutionID: "execution"),
                   description: "Task", model: .init(model: "fixture-model"), tools: [], readOnly: true, resourceRevision: "fixture")
}
