import XCTest
@testable import PiAgentCore

private actor HeldTools: ToolExecuting {
    var calls: [String] = []
    var held = true
    func definitions(readOnly: Bool) -> [ToolDefinition] {
        [ToolDefinition("first", "Fixture", [:]), ToolDefinition("second", "Fixture", [:])]
    }
    func release() { held = false }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        calls.append(call.name)
        while held { try await Task.sleep(nanoseconds: 5_000_000) }
        return resultText("Completed " + call.name)
    }
}

private actor AcceptanceCaptureSink {
    var packets: [JSON] = []
    func accept(_ packet: JSON) -> Bool { packets.append(packet); return true }
}

final class AcceptanceTests: XCTestCase {
    func testSideDuringModelAndToolUsesCompleteBoundaryAndIndependentCancellation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), resources = Resources(cwd: root, home: root)
        let client = ScriptClient([toolReply(["first", "second"]), answer("parent complete")], holdFirst: true)
        let tools = HeldTools(), traces = TraceStore()
        let parent = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: tools, traces: traces, autoCompaction: false)
        _ = try await parent.submit(Submission(commandID: "initial", turnID: "initial", text: "Parent question"), steer: false)
        try await eventually { await client.count == 1 }
        let duringModel = await parent.sideSeed()
        XCTAssertEqual(duringModel.messages.map(\.role), ["user"])
        let modelSide = try AgentSession(id: "model-side", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([answer("independent answer")]), tools: tools, traces: traces, seed: duringModel.messages, parent: duringModel.info, autoCompaction: false)
        _ = try await modelSide.submit(Submission(commandID: "side-1", turnID: "side-1", text: "While model runs"), steer: false)
        try await eventually { !(await modelSide.isRunning) }
        let stillRunning = await parent.isRunning; XCTAssertTrue(stillRunning)
        await client.release()
        try await eventually { await tools.calls.count == 1 }
        let duringTool = await parent.sideSeed()
        XCTAssertEqual(duringTool.messages.map(\.id), duringModel.messages.map(\.id), "An unfinished tool batch must not enter a side snapshot")
        let sideClient = ScriptClient([answer("never delivered")], holdFirst: true)
        let toolSide = try AgentSession(id: "tool-side", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: sideClient, tools: tools, traces: traces, seed: duringTool.messages, parent: duringTool.info, autoCompaction: false)
        _ = try await toolSide.submit(Submission(commandID: "side-2", turnID: "side-2", text: "While tools run"), steer: false)
        try await eventually { await sideClient.count == 1 }
        await tools.release(); try await eventually { !(await parent.isRunning) }
        let sideStillRunning = await toolSide.isRunning; XCTAssertTrue(sideStillRunning)
        await toolSide.stop(); try await eventually { !(await toolSide.isRunning) }
        let parentState = await parent.snapshot(), sideState = await toolSide.snapshot()
        XCTAssertEqual(parentState["state"].text, "idle"); XCTAssertEqual(sideState["runStatus"].text, "cancelled")
        XCTAssertFalse(parentState["messages"].encoded().contains("While tools run"))
        let complete = await parent.sideSeed(); XCTAssertEqual(complete.messages.filter { $0.role == "toolResult" }.count, 2)
        await toolSide.close(); await modelSide.close(); await parent.close()
    }

    func testRemovedQueueAndSteeringSurviveRestartPausedUntilExplicitResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), client = ScriptClient([answer("cancelled")], holdFirst: true)
        let tools = RecordingTools(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let first = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: client, tools: tools, traces: traces, autoCompaction: false)
        _ = try await first.submit(Submission(commandID: "initial", turnID: "initial", text: "initial"), steer: false)
        try await eventually { await client.count == 1 }
        for (id, steering) in [("removed-follow", false), ("kept-follow", false), ("removed-steer", true), ("kept-steer", true)] {
            _ = try await first.submit(Submission(commandID: id, turnID: id, text: id), steer: steering)
        }
        try await first.removeQueued("removed-follow"); try await first.removeQueued("removed-steer")
        let path = await first.path; await first.close()
        let nextClient = ScriptClient([answer("steering answer"), answer("follow-up answer")])
        let resumed = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: nextClient, tools: tools, traces: traces, resumePath: path, autoCompaction: false)
        let paused = await resumed.snapshot(), initialCount = await nextClient.count
        XCTAssertEqual(paused["state"].text, "paused"); XCTAssertEqual(paused["queueCount"].int, 2); XCTAssertEqual(initialCount, 0)
        XCTAssertTrue(paused["commands"].list.filter { $0["turnId"].text?.hasPrefix("removed-") == true }.allSatisfy { $0["status"].text == "removed" })
        try await resumed.resumeQueue(); try await eventually { !(await resumed.isRunning) }
        let requests = await nextClient.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].filter { $0.role == "user" }.map(\.id), ["initial", "kept-steer"])
        XCTAssertEqual(requests[1].filter { $0.role == "user" }.map(\.id), ["initial", "kept-steer", "kept-follow"])
        await resumed.close()
    }

    func testCancellationDuringToolPairsEntireBatchAndNeverReinvokesOnResume() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), tools = HeldTools(), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let first = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: ScriptClient([toolReply(["first", "second"])]), tools: tools, traces: traces, autoCompaction: false)
        _ = try await first.submit(Submission(commandID: "initial", turnID: "initial", text: "Run tools"), steer: false)
        try await eventually { await tools.calls.count == 1 }
        _ = try await first.submit(Submission(commandID: "follow", turnID: "follow", text: "Continue after inspection"), steer: false)
        await first.stop(); try await eventually { !(await first.isRunning) }
        let before = await first.snapshot(), path = await first.path
        let results = before["messages"].list.filter { $0["role"].text == "tool" }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(try XCTUnwrap(results.first?["text"].text).contains("Effects may already have occurred"))
        XCTAssertTrue(try XCTUnwrap(results.last?["text"].text).contains("Not executed"))
        await first.close()
        let client = ScriptClient([answer("Continued")])
        let resumed = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: resources, client: client, tools: tools, traces: traces, resumePath: path, autoCompaction: false)
        try await resumed.resumeQueue(); try await eventually { !(await resumed.isRunning) }
        let calls = await tools.calls, requests = await client.requests
        XCTAssertEqual(calls, ["first"]); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].filter { $0.role == "toolResult" }.count, 2)
        await resumed.close()
    }

    func testDisplayCarriesMessageClocksToolStatsAndTimingSplit() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let client = ScriptClient([answer("done")]), tools = RecordingTools(), traces = TraceStore()
        let session = try AgentSession(id: "t", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: resources, client: client, tools: tools, traces: traces, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "c", text: "hello"), steer: false)
        try await eventually { !(await session.isRunning) }
        let state = await session.snapshot()
        for message in state["messages"].list { XCTAssertNotNil(message["at"].double, "every displayed message carries its clock") }
        let timing = state["turnMetrics"]
        XCTAssertGreaterThanOrEqual(timing["modelMs"].double ?? -1, 0); XCTAssertEqual(timing["toolMs"].double, 0)
        XCTAssertEqual(timing["sessionModelMs"].double, timing["modelMs"].double, "one turn: session and turn model time agree")
        await session.close()
        // The split survives a reopen through the persisted native state.
        let reopened = try AgentSession(id: "t", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: resources, client: ScriptClient([]), tools: tools, traces: traces, resumePath: root.appendingPathComponent("state/t.jsonl").path, autoCompaction: false)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["turnMetrics"]["sessionModelMs"].double, timing["sessionModelMs"].double)
        await reopened.close()
    }

    func testQueuedExplicitSkillRevocationPausesWithoutSendingOrLosingOtherQueue() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let skillRoot = root.appendingPathComponent(".codex/skills/review"), agents = skillRoot.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("---\nname: review\ndescription: Fixture review\n---\nFrozen explicit body".utf8).write(to: skillRoot.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent(".codex").path)], home: root)
        let snapshot = try await resources.resolve(); var selection = try XCTUnwrap(snapshot.skills.first)
        selection["intent"] = "picker"
        let frozen = try await resources.freeze([selection], text: "", tools: [])
        let pasted = try await resources.freeze([], text: "/review or an embedded picker object", tools: []); XCTAssertTrue(pasted.isEmpty)
        let client = ScriptClient([answer("initial")], holdFirst: true), tools = RecordingTools(), traces = TraceStore()
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: resources, client: client, tools: tools, traces: traces, autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "first"), steer: false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID: "skill", turnID: "skill", text: "review", skills: frozen), steer: false)
        _ = try await session.submit(Submission(commandID: "later", turnID: "later", text: "still pending"), steer: false)
        try await resources.configure(["codexHome": JSON(root.appendingPathComponent(".codex").path), "disabled": [selection["id"]]])
        await client.release(); try await eventually { !(await session.isRunning) }
        let state = await session.snapshot(), count = await client.count
        XCTAssertEqual(state["state"].text, "error"); XCTAssertEqual(count, 1)
        XCTAssertFalse(state["messages"].encoded().contains("Frozen explicit body"))
        XCTAssertEqual(state["commands"].list.first { $0["turnId"].text == "skill" }?["status"].text, "failed")
        // The revoked submission is kept at the head of the paused queue so its
        // text can be inspected or removed; nothing the user typed is lost.
        XCTAssertEqual(state["queueCount"].int, 2)
        let queued = state["queue"].list
        XCTAssertEqual(queued.count, 2)
        XCTAssertTrue(queued.first?.encoded().contains("\"skill\"") ?? false, "The failed submission stays first")
        XCTAssertTrue(queued.last?.encoded().contains("still pending") ?? false, "The later submission is untouched")
        await session.close()
    }

    func testSkillIdentitySymlinkDedupDependenciesUnsupportedPolicyAndUnicodeBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex"), skills = codex.appendingPathComponent("skills")
        for name in ["a", "b", "invalid"] {
            let folder = skills.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("agents"), withIntermediateDirectories: true)
            try Data("---\nname: collision\ndescription: Distinct source \(name)\n---\nBody \(name)".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("alias-a"), withDestinationURL: skills.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("cycle"), withDestinationURL: skills)
        try Data("dependencies:\n  tools:\n    - type: builtin\n      value: write\n".utf8).write(to: skills.appendingPathComponent("a/agents/openai.yaml"))
        try Data("policy:\n  unknown_mandatory_rule: true\n".utf8).write(to: skills.appendingPathComponent("invalid/agents/openai.yaml"))
        try Data("🙂汉字🙂".utf8).write(to: codex.appendingPathComponent("AGENTS.md"))
        let resources = Resources(cwd: root, options: ["codexHome": JSON(codex.path), "maxInstructionBytes": 8], home: root)
        let snapshot = try await resources.resolve()
        XCTAssertEqual(snapshot.skills.count, 3); XCTAssertEqual(Set(snapshot.skills.compactMap { $0["id"].text }).count, 3)
        XCTAssertEqual(snapshot.includedBytes, 7); XCTAssertEqual(snapshot.sources[0]["text"].text, "🙂汉")
        XCTAssertEqual(snapshot.sources[0]["truncated"].flag, true)
        var skill = try XCTUnwrap(snapshot.skills.first { $0["path"].text?.contains("/a/") == true }); skill["intent"] = "picker"
        do { _ = try await resources.freeze([skill], text: "", tools: ["read"]); XCTFail("Missing dependency must deny selection") }
        catch let error as AgentError { XCTAssertEqual(error.code, "skill_dependency") }
        let frozen = try await resources.freeze([skill], text: "", tools: ["write"])
        do { try await resources.validate(frozen, tools: ["read"]); XCTFail("A queued dependency cannot disappear silently") }
        catch let error as AgentError { XCTAssertEqual(error.code, "skill_dependency") }
        var invalid = try XCTUnwrap(snapshot.skills.first { $0["policy"].text == "needsAttention" }); invalid["intent"] = "picker"
        do { _ = try await resources.freeze([invalid], text: "", tools: ["write"]); XCTFail("Unknown mandatory policy must remain disabled") } catch { }
    }

    func testRecoveredUnknownToolResultRetainsOriginatingRequestLink() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), path = directory.appendingPathComponent("s.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: path, id: "s", cwd: root, binding: profile.binding, create: true)
        var assistant = toolReply(["first"]).message; assistant.requestAttemptIDs = ["prior-request"]
        try journal?.append(["type": "message", "message": assistant.pi], id: assistant.id)
        journal = nil
        let recorder = AcceptanceCaptureSink(), traces = TraceStore(sink: { await recorder.accept($0) })
        let session = try AgentSession(id: "s", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: traces, resumePath: path.path, autoCompaction: false)
        let context = await session.sideSeed(), state = await session.snapshot()
        let recovered = try XCTUnwrap(context.messages.first { $0.role == "toolResult" })
        XCTAssertEqual(state["state"].text, "paused"); XCTAssertTrue(recovered.isError)
        XCTAssertTrue(recovered.text.contains("Outcome unknown"))
        XCTAssertEqual(recovered.requestAttemptIDs, ["prior-request"], "Recovery results must remain inspectable through their original request")
        let packets = await recorder.packets
        XCTAssertTrue(packets.contains { $0["attemptId"].text == "prior-request" && $0["outputMessageIds"].list.contains(JSON(recovered.id)) }, "Snapshot recovery must republish the request link to the durable native recorder")
        await session.close()
    }

    func testReopenedAndSideHistoryRestoresPairedToolCardsWithoutInventingDuration() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), path = directory.appendingPathComponent("s.jsonl"), profile = try fixtureProfile()
        var journal: SessionJournal? = try SessionJournal(url: path, id: "s", cwd: root, binding: profile.binding, create: true)
        var assistantIDs: [String] = []
        for (text, failed) in [("first durable result", false), ("second failed result", true)] {
            let assistant = toolReply(["read"]).message; assistantIDs.append(assistant.id)
            try journal?.append(["type": "message", "message": assistant.pi], id: assistant.id)
            var result = ChatMessage(role: "toolResult", content: [textBlock(text)])
            result.toolCallId = "call-0"; result.toolName = "read"; result.isError = failed
            try journal?.append(["type": "message", "message": result.pi], id: result.id)
        }
        var unknown = ChatMessage(role: "assistant", content: [["type": "toolCall", "id": "unresolved", "name": "read", "arguments": [:]]])
        unknown.requestAttemptIDs = ["unknown-request"]; assistantIDs.append(unknown.id)
        try journal?.append(["type": "message", "message": unknown.pi], id: unknown.id)
        journal = nil
        let resources = Resources(cwd: root, home: root), traces = TraceStore(), tools = RecordingTools()
        let session = try AgentSession(id: "s", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: tools, traces: traces, resumePath: path.path, autoCompaction: false)
        let snapshot = await session.snapshot(), page = await session.historyPage(before: nil)
        for value in [snapshot, page] {
            let cards = assistantIDs.compactMap { id in value["messages"].list.first { $0["id"].text == id }?["tools"].list.first }
            XCTAssertEqual(cards.count, 3)
            XCTAssertEqual(cards.map { $0["state"].text }, ["completed", "failed", "failed"])
            XCTAssertEqual(cards.first?["output"].text, "first durable result", "A reused call ID must not replace an earlier result")
            XCTAssertTrue(cards.allSatisfy { $0["durationMs"].isNull }, "Restart cannot reconstruct elapsed time from a result")
            XCTAssertTrue(cards.last?["output"].text?.contains("Outcome unknown") == true)
        }
        let seed = await session.sideSeed()
        let side = try AgentSession(id: "side", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: tools, traces: traces, seed: seed.messages, parent: seed.info, autoCompaction: false)
        let sideView = await side.snapshot()
        XCTAssertEqual(sideView["messages"].list.first { $0["id"].text == assistantIDs[0] }?["tools"].list.first?["state"].text, "completed")
        let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
        await side.close(); await session.close()
    }
}
