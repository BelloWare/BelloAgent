import XCTest
@testable import PiAgentCore

/// Editing tools that fail in scripted ways: an edit rejected before it
/// touched anything, one that failed after it started writing, and one held
/// until it is released (to keep the workspace gate busy).
private actor ScriptedEditTools: ToolExecuting {
    var held = true, calls: [String] = []
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("edit", "fixture", [:]), ToolDefinition("write", "fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        calls.append(call.id)
        switch call.arguments["mode"].text {
        case "rejected": throw AgentError("edit_match", "oldText must match exactly once; found 0 matches")
        case "broken": throw AgentError("write_interrupted", "The file system failed while the file was being written")
        default:
            while held { try await Task.sleep(nanoseconds: 5_000_000) }
            return resultText("edited")
        }
    }
}

private func editReply(_ modes: [String]) -> ModelReply {
    let calls = modes.enumerated().map { ToolCall(id: "call-\($0.offset)", name: "edit", arguments: ["mode": JSON($0.element)]) }
    return ModelReply(message: ChatMessage(role: "assistant", content: calls.map { ["type": "toolCall", "id": JSON($0.id), "name": "edit", "arguments": $0.arguments] }), calls: calls)
}

/// What a tool card says happened, live and from the journal: a tool that
/// ran and failed, a tool whose effects are unknown, and one that never ran.
final class ToolOutcomeTests: XCTestCase {
    private func cards(_ snapshot: JSON) -> [String] {
        snapshot["messages"].list.filter { $0["role"].text == "assistant" }.flatMap { $0["tools"].list }.compactMap { $0["state"].text }
    }
    private func outcomes(_ session: AgentSession) async -> [String] {
        await session.history.filter { $0.role == "toolResult" }.compactMap { $0.toolStats?["outcome"].text }
    }

    func testRejectedEditFailedButAnEditThatBrokeMidwayHasAnUnknownOutcome() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), tools = ScriptedEditTools()
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([editReply(["rejected", "broken"]), answer("done")]), tools: tools, traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "edit"), steer: false)
        try await eventually { !(await session.isRunning) }
        let live = await session.snapshot(), recorded = await outcomes(session)
        XCTAssertEqual(recorded, ["failed", "unknown"], "an edit rejected before it ran failed; one that broke while writing may have changed the file")
        XCTAssertEqual(cards(live), ["failed", "unknown"])
        let path = await session.path; await session.close()
        let reopened = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: tools, traces: TraceStore(), resumePath: path, autoCompaction: false)
        let reopenedCards = cards(await reopened.snapshot())
        XCTAssertEqual(reopenedCards, ["failed", "unknown"], "the journal's recorded outcome, not isError, decides the card")
        await reopened.close()
    }

    func testAnEditStoppedWhileWaitingForTheWorkspaceNeverRan() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncGate(), tools = ScriptedEditTools()
        func session(_ id: String) throws -> AgentSession {
            try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state-" + id), readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([editReply(["held"]), answer("done")]), tools: tools, traces: TraceStore(), editingGate: gate, autoCompaction: false)
        }
        let holder = try session("holder"), waiter = try session("waiter")
        _ = try await holder.submit(Submission(commandID: "h", turnID: "h", text: "edit"), steer: false)
        try await eventually { await tools.calls.count == 1 }
        _ = try await waiter.submit(Submission(commandID: "w", turnID: "w", text: "edit"), steer: false)
        try await eventually { await waiter.snapshot()["activity"]["phase"].text == "tool" }
        await waiter.stop(); try await eventually { !(await waiter.isRunning) }
        let stopped = await waiter.snapshot(), recorded = await outcomes(waiter)
        let calls = await tools.calls
        XCTAssertEqual(calls.count, 1, "the waiting edit never entered the tool")
        XCTAssertEqual(recorded, ["not_executed"]); XCTAssertEqual(cards(stopped), ["cancelled"])
        XCTAssertTrue(stopped["messages"].list.contains { $0["role"].text == "tool" && ($0["text"].text ?? "").hasPrefix("Not executed") }, "the model is not told that effects may have occurred")
        await tools.release(); try await eventually { !(await holder.isRunning) }
        await holder.close(); await waiter.close()
    }

    /// A reader that did not ask for recorded outcomes (an app from before
    /// 0.1.85) keeps the card states it knows: a stopped call reads
    /// "cancelled" live and "failed" from the journal, as it always did.
    func testAReaderThatDidNotAskForOutcomesKeepsTheCardStatesItKnows() async throws {
        for asked in [true, false] {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("state"), tools = ScriptedEditTools()
            let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([editReply(["held", "held"])]), tools: tools, traces: TraceStore(), autoCompaction: false, unknownToolOutcomes: asked)
            _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "edit"), steer: false)
            try await eventually { await tools.calls.count == 1 }
            await session.stop(); try await eventually { !(await session.isRunning) }
            let live = cards(await session.snapshot()), recorded = await outcomes(session)
            let path = await session.path; await session.close()
            let reopened = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: tools, traces: TraceStore(), resumePath: path, autoCompaction: false, unknownToolOutcomes: asked)
            let reloaded = cards(await reopened.snapshot())
            await reopened.close()
            XCTAssertEqual(recorded, ["unknown", "not_executed"], "the journal records the outcome either way")
            XCTAssertEqual(live, asked ? ["unknown", "cancelled"] : ["cancelled", "cancelled"])
            XCTAssertEqual(reloaded, asked ? ["unknown", "cancelled"] : ["failed", "failed"])
        }
    }

    /// A tool result that holds only an image reaches the model as a short
    /// description of the image, never as its base64 encoding.
    func testAnImageOnlyResultReachesTheModelAsAPlaceholder() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = Data(repeating: 0xAB, count: 3000).base64EncodedString()
        let client = ScriptClient([toolReply(["screenshot"]), answer("seen")])
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: ImageTools(data: image), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "look"), steer: false)
        try await eventually { !(await session.isRunning) }
        let sent = await client.requests
        let result = try XCTUnwrap(sent.last?.first { $0.role == "toolResult" })
        XCTAssertEqual(result.text, "[image/png result, 3000 bytes]")
        XCTAssertFalse(result.text.contains(String(image.prefix(64))))
        await session.close()
    }
}

private actor ImageTools: ToolExecuting {
    let data: String
    init(data: String) { self.data = data }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("screenshot", "fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { ["content": [["type": "image", "mimeType": "image/png", "data": JSON(data)]], "isError": false] }
}
