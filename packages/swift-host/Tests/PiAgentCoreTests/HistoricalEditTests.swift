import XCTest
@testable import PiAgentCore

private actor EditMutationTools: ToolExecuting {
    let path: URL
    init(_ root: URL) { path = root.appendingPathComponent("mutation.txt") }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "Record a mutation", ["type":"object","properties":["value":["type":"integer"]]]), ToolDefinition("futureEvidence", "Read fixture evidence", ["type":"object","properties":[:]])] }
    func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON {
        if call.name == "futureEvidence" { return resultText("FUTURE_TOOL_RESULT") }
        guard !readOnly, call.name == "first", call.arguments["value"].int == 0 else { throw AgentError("fixture", "Unexpected tool call") }
        var bytes = (try? Data(contentsOf: path)) ?? Data(); bytes.append(Data("once\n".utf8)); try bytes.write(to: path)
        return resultText("MUTATED_ONCE")
    }
}
final class HistoricalEditTests: XCTestCase {
    func testEditPreparationPagesFullOriginalUnicodeInputAndRejectsChangedSource() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state"), path = state.appendingPathComponent("input.jsonl"), profile = try fixtureProfile()
        let original = String(repeating: "漢字🌍e\u{301}\u{0001}", count: 10_000)
        do {
            let journal = try SessionJournal(url: path, id: "input", cwd: root, binding: profile.binding, create: true)
            try journal.append(["type":"message", "message":["role":"user", "content":"expanded instructions", "nativeDisplayText":JSON(original), "nativeUserInput":["version":1,"attachments":[],"skills":[]]]], id: "user")
        }
        let session = try AgentSession(id: "input", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
        let first = try await session.prepareEdit("user")
        XCTAssertEqual(first["input"]["version"].int, 1); XCTAssertNotNil(first["next"].int)
        var text = first["text"].text ?? "", next = first["next"].int, count = 1
        while let offset = next {
            XCTAssertEqual(offset, (text as NSString).length)
            let page = try await session.prepareEdit("user", offset: offset, expectedTimeline: first["sourceTimeline"].text, expectedTextDigest: first["sourceTextDigest"].text)
            XCTAssertLessThan(try page.data().count, 512 * 1024)
            XCTAssertTrue(page["input"].isNull, "Input references are emitted only on the first page")
            text += try XCTUnwrap(page["text"].text); next = page["next"].int; count += 1
        }
        XCTAssertGreaterThan(count, 1); XCTAssertEqual(text, original)
        do { _ = try await session.prepareEdit("user", expectedTimeline: "stale"); XCTFail("Mixed source pages must fail") }
        catch let error as AgentError { XCTAssertEqual(error.code, "edit_changed") }
        await session.close()
    }
    func testSharedGoldenJournalHasSameOrderedContextAndRejectsAbandonedTarget() throws {
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        func replay(_ suffix: String) throws -> ConversationReplay {
            let data = try Data(contentsOf: repo.appendingPathComponent("fixtures/native/historical-edit-\(suffix).jsonl"))
            return try ConversationReplay(data.split(separator: 10).map { try JSON.parse(Data($0)) })
        }
        let before = try replay("before"), after = try replay("after")
        XCTAssertEqual(before.context.map(\.id), ["summary", "u20", "a20"])
        let prefix = (1...4).flatMap { [String(format: "u%02d", $0), String(format: "a%02d", $0)] }
        XCTAssertEqual(after.context.map(\.id), prefix + ["replacement", "new-answer"])
        XCTAssertEqual(after.visible.map(\.id), prefix + ["branch", "replacement", "new-answer"])
        XCTAssertThrowsError(try AgentSession.planEdit("u05", history: after.history, visible: after.visible, context: after.context))
    }
    func testChildCompactionAndForkOfEditedForkUseOnlyTheirOwnSnapshots() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), state = root.appendingPathComponent("state"), resources = Resources(cwd: root, home: root), traces = TraceStore()
        let parentClient = ScriptClient([answer(String(repeating: "first task evidence ", count: 1000)), answer(String(repeating: "second task evidence ", count: 1000))])
        let parent = try AgentSession(id: "parent", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: resources, client: parentClient, tools: RecordingTools(), traces: traces, autoCompaction: false)
        for id in ["first", "second"] {
            _ = try await parent.submit(Submission(commandID: id, turnID: id, text: id), steer: false); try await eventually { !(await parent.isRunning) }
        }
        let childPath = try await parent.fork(to: "child")["path"].text!
        let parentPath = await parent.path!; await parent.close(); try FileManager.default.removeItem(atPath: parentPath)
        let childClient = ScriptClient([answer("child future reply"), answer("child summary"), answer("child replacement reply")])
        let child = try AgentSession(id: "child", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: resources, client: childClient, tools: RecordingTools(), traces: traces, resumePath: childPath, autoCompaction: false)
        _ = try await child.submit(Submission(commandID: "third", turnID: "third", text: "child future input"), steer: false); try await eventually { !(await child.isRunning) }
        try await child.compact(); try await eventually { !(await child.isRunning) }
        let compacted = await child.context; XCTAssertFalse(compacted.contains { $0.id == "second" })
        _ = try await child.edit(fromMessageID: "second", input: Submission(commandID: "replacement", turnID: "replacement", text: "child replacement")); try await eventually { !(await child.isRunning) }
        let requests = await childClient.requests
        XCTAssertEqual(requests.last?.map(\.id).first, "first")
        XCTAssertFalse(requests.last?.contains { $0.id == "second" || $0.id == "third" || $0.text.contains("child summary") } ?? true)
        let grandchildPath = try await child.fork(to: "grandchild")["path"].text!; await child.close()
        let grandchildClient = ScriptClient([answer("grandchild reply")])
        let grandchild = try AgentSession(id: "grandchild", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: resources, client: grandchildClient, tools: RecordingTools(), traces: traces, resumePath: grandchildPath, autoCompaction: false)
        _ = try await grandchild.edit(fromMessageID: "replacement", input: Submission(commandID: "final", turnID: "final", text: "grandchild replacement")); try await eventually { !(await grandchild.isRunning) }
        let expected = await grandchild.context.map(\.id)
        XCTAssertFalse(expected.contains("replacement")); XCTAssertTrue(expected.contains("first")); XCTAssertTrue(expected.contains("final"))
        await grandchild.close()
        let reopened = try AgentSession(id: "grandchild", profile: profile, apiKey: "fixture", cwd: root, directory: state, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: traces, resumePath: grandchildPath, autoCompaction: false)
        let actual = await reopened.context.map(\.id); XCTAssertEqual(actual, expected); await reopened.close()
    }

    func testPurePlannerRecoversRawPrefixAndRetainsOnlyCausallySafeSummaries() throws {
        let values = [ReplayNode(id: "u1", role: "user"), ReplayNode(id: "a1", role: "assistant"),
                      ReplayNode(id: "u2", role: "user"), ReplayNode(id: "a2", role: "assistant"),
                      ReplayNode(id: "safe", role: "system", summary: true, dependencies: ["u1", "a1"], summarized: ["u1", "a1"]),
                      ReplayNode(id: "unsafe", role: "system", summary: true, dependencies: ["safe", "u2", "a2"], summarized: ["safe", "u2", "a2"])]
        let nodes = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }), visible = values.map(\.id)
        XCTAssertEqual(try EditReplayPlan.prepare(target: "u2", nodes: nodes, visible: visible, context: ["unsafe"]).replay, ["u1", "a1"])
        XCTAssertEqual(try EditReplayPlan.prepare(target: "u2", nodes: nodes, visible: visible, context: ["safe", "u2", "a2"]).replay, ["safe"])
        XCTAssertThrowsError(try EditReplayPlan.prepare(target: "a2", nodes: nodes, visible: visible, context: []))
        XCTAssertThrowsError(try EditReplayPlan.prepare(target: "u2", nodes: nodes, visible: ["u1", "a1"], context: []))
        var corrupt = nodes; corrupt.removeValue(forKey: "a1")
        XCTAssertThrowsError(try EditReplayPlan.prepare(target: "u2", nodes: corrupt, visible: visible, context: []))
        var cycle = nodes; cycle["safe"]?.dependencies = ["safe", "u1"]
        XCTAssertEqual(try EditReplayPlan.prepare(target: "u2", nodes: cycle, visible: visible, context: ["safe"]).replay, ["u1", "a1"])
    }
    func testOccurrenceLocalToolValidationAndVersionedBranchValidation() throws {
        let values = [ReplayNode(id: "a1", role: "assistant", calls: ["reused"]), ReplayNode(id: "r1", role: "toolResult", result: "reused"),
                      ReplayNode(id: "a2", role: "assistant", calls: ["reused"]), ReplayNode(id: "r2", role: "toolResult", result: "reused"), ReplayNode(id: "u", role: "user")]
        let nodes = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }), visible = values.map(\.id)
        let plan = try EditReplayPlan.prepare(target: "u", nodes: nodes, visible: visible, context: visible)
        XCTAssertEqual(plan.replay, ["a1", "r1", "a2", "r2"])
        XCTAssertThrowsError(try EditReplayPlan.validateGroups(["a1", "r1", "a2"], nodes: nodes))
        var branch = HistoricalBranch(fromMessageId: "u", keptIds: plan.replay, selectedTimelinePrefix: plan.displayPrefix, sourceTimelineDigest: plan.sourceTimeline)
        XCTAssertEqual(try EditReplayPlan.restore(branch, nodes: nodes, visible: visible, context: visible), plan)
        branch.nativeBranchVersion = 99; XCTAssertThrowsError(try EditReplayPlan.restore(branch, nodes: nodes, visible: visible, context: visible))
        branch.nativeBranchVersion = 2; branch.keptIds = ["r2"]; XCTAssertThrowsError(try EditReplayPlan.restore(branch, nodes: nodes, visible: visible, context: visible))
    }
    func testCompactedForkEditsRetainedTargetAgainstActualGatewayAndReopensWithoutRepeatingEffects() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = [repo.appendingPathComponent("fixtures/native/edit_gateway.py").path, root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) }
        let port = try XCTUnwrap(JSON.parse(Data(contentsOf: root.appendingPathComponent("ready.json")))["port"].int)
        var raw = try fixtureProfile().raw; raw["baseUrl"] = JSON("http://127.0.0.1:\(port)/v1")
        raw["routing"] = ["replayPolicy":"pinned","expectedModel":"fixture-fixed","replayContract":"Local deterministic fixture fixes compatible provider items"]
        let profile = try Profile(raw), state = root.appendingPathComponent("state"), resources = Resources(cwd: root, home: root), traces = TraceStore(), tools = EditMutationTools(root)
        let parent = try AgentSession(id: "parent", profile: profile, apiKey: "synthetic-edit-key", cwd: root, directory: state, readOnly: false, resources: resources, client: ProviderClient(traces: traces), tools: tools, traces: traces, autoCompaction: false)
        for (id, text) in [("first", "SAFE_FIRST"), ("target", "ORIGINAL_TARGET"), ("third", "FUTURE_THIRD")] {
            _ = try await parent.submit(Submission(commandID: id, turnID: id, text: text), steer: false); try await eventually { !(await parent.isRunning) }
            let status = await parent.snapshot(); XCTAssertEqual(status["state"].text, "idle", status["preflightError"].encoded())
        }
        try await parent.compact(); try await eventually { !(await parent.isRunning) }
        let parentContext = await parent.context; XCTAssertFalse(parentContext.contains { $0.id == "target" }, "Fixture must actually summarize the target out")
        let parentPath = await parent.path!, parentBytes = try Data(contentsOf: URL(fileURLWithPath: parentPath))
        XCTAssertTrue(String(decoding: parentBytes, as: UTF8.self).contains("FUTURE_TOOL_RESULT"))
        XCTAssertTrue(String(decoding: parentBytes, as: UTF8.self).contains("future-opaque"))
        let fork = try await parent.fork(to: "child"), childPath = try XCTUnwrap(fork["path"].text)
        let child = try AgentSession(id: "child", profile: profile, apiKey: "synthetic-edit-key", cwd: root, directory: state, readOnly: false, resources: resources, client: ProviderClient(traces: traces), tools: tools, traces: traces, resumePath: childPath, autoCompaction: false)
        let prepared = try await child.prepareEdit("target"); XCTAssertEqual(prepared["text"].text, "ORIGINAL_TARGET")
        let skillDir = root.appendingPathComponent(".agents/skills/edit-check"); try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: edit-check\ndescription: Current edit fixture\n---\nSKILL_CURRENT_SELECTION\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let catalog = try await resources.inspect(["refresh":true]); let descriptor = try XCTUnwrap(catalog["skills"].list.first { $0["name"].text == "edit-check" })
        let frozen = try await resources.freeze([["id":descriptor["id"],"contentHash":descriptor["contentHash"],"metadataHash":descriptor["metadataHash"],"intent":"picker","arguments":""]], text: "EDITED_REPLACEMENT", tools: [])
        _ = try await child.edit(fromMessageID: "target", input: Submission(commandID: "edit", turnID: "replacement", text: "EDITED_REPLACEMENT", skills: frozen), expectedTimeline: prepared["sourceTimeline"].text, expectedTextDigest: prepared["sourceTextDigest"].text)
        try await eventually { !(await child.isRunning) }
        let snapshot = await child.snapshot(), selected = await child.context
        XCTAssertEqual(snapshot["state"].text, "idle", snapshot["preflightError"].encoded())
        XCTAssertEqual(snapshot["messages"].list.last?["text"].text, "EDIT_ACCEPTED_SAFE_PREFIX")
        XCTAssertEqual(try String(contentsOf: tools.path), "once\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: parentPath)), parentBytes)
        let records = try Data(contentsOf: URL(fileURLWithPath: childPath)).split(separator: 10).map { try JSON.parse(Data($0)) }
        let pure = try ConversationReplay(records); XCTAssertEqual(pure.context.map(\.id), selected.map(\.id))
        XCTAssertFalse(pure.visible.contains { $0.id == "target" || $0.id == "third" })
        let secondFork = try await child.fork(to: "grandchild"); await child.close()
        let noCalls = ScriptClient([])
        for (id, path) in [("child", childPath), ("grandchild", secondFork["path"].text!)] {
            let reopened = try AgentSession(id: id, profile: profile, apiKey: "synthetic-edit-key", cwd: root, directory: state, readOnly: true, resources: resources, client: noCalls, tools: tools, traces: traces, resumePath: path, autoCompaction: false)
            let context = await reopened.context; XCTAssertEqual(context.map(\.id), selected.map(\.id)); await reopened.close()
        }
        let calls = await noCalls.count; XCTAssertEqual(calls, 0)
        let captured = try await traces.command("debug.list", session: "child", params: [:])["attempts"].list
        let observed = try Data(contentsOf: root.appendingPathComponent("records.jsonl")).split(separator: 10).map { try JSON.parse(Data($0)) }
        XCTAssertTrue(observed.allSatisfy { $0["status"].int == 200 }); XCTAssertEqual(captured.count, 1)
        for attempt in captured {
            let request = try await traces.command("debug.body", session: "child", params: ["attemptId":attempt["attemptId"],"body":"request"])
            let response = try await traces.command("debug.body", session: "child", params: ["attemptId":attempt["attemptId"],"body":"response"])
            XCTAssertTrue(observed.contains { $0["request"] == request["bytes"] && $0["response"] == response["bytes"] })
        }
        await parent.close()
    }
}
