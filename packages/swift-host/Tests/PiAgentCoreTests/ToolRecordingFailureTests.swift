import XCTest
@testable import PiAgentCore

private actor UnretainedMCPTools: ToolExecuting {
    let text: String
    private(set) var retention: [String: Bool] = [:]
    init(bytes: Int) { text = String(repeating: "x", count: bytes) }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("mcp", "Fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) -> JSON { resultText(text) }
    func resultsRetained(_ ids: [String], retained: Bool) { for id in ids { retention[id] = retained } }
}

final class ToolRecordingFailureTests: XCTestCase {
    func testAnUnwritableToolOutputFolderSettlesTheLiveCard() async throws { try await check(bytes: 70 * 1024, unwritable: true) }
    func testAnOversizeToolResultSettlesTheLiveCard() async throws { try await check(bytes: 16 * 1024 * 1024 + 1, unwritable: false) }

    private func check(bytes: Int, unwritable: Bool) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), output = directory.appendingPathComponent("tool-output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if unwritable { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.path) }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path) }
        let call = ToolCall(id: "call", name: "mcp", arguments: ["action": "invoke", "server": "fixture", "tool": "echo"])
        var reply = ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": "mcp", "arguments": call.arguments]])
        reply.requestAttemptIDs = ["attempt"]
        let client = ScriptClient([ModelReply(message: reply, calls: [call]), answer("Done")]), tools = UnretainedMCPTools(bytes: bytes)
        let session = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Run fixture tool"), steer: false)
        try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot(), history = await session.history, retention = await tools.retention
        let card = try XCTUnwrap(snapshot["messages"].list.flatMap { $0["tools"].list }.first)
        XCTAssertEqual(card["state"].text, "unknown", "The tool returned but its result was lost; it is no longer running")
        XCTAssertTrue(card["output"].text?.contains("could not be recorded") == true)
        XCTAssertTrue(snapshot["activity"]["toolNames"].list.isEmpty)
        let result = try XCTUnwrap(history.first { $0.role == "toolResult" })
        XCTAssertEqual(result.requestAttemptIDs, ["attempt"])
        XCTAssertEqual(result.toolStats?["outcome"].text, "unknown")
        XCTAssertNotNil(result.toolStats?["durationMs"].double)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(retention["call"], false, "The MCP unknown-outcome marker must remain")
        let path = await session.path
        await session.close()
        let reopened = try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: tools, traces: TraceStore(), resumePath: path)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored["messages"].list.flatMap { $0["tools"].list }.first?["state"].text, "unknown")
        await reopened.close()
    }
}
