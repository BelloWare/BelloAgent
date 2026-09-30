import XCTest
@testable import PiAgentCore

/// Where an edit changed its file reaches the app: on the tool's card, live
/// and as the journal brings it back, and in the result's recorded stats;
/// the text the model is given is what it always was.
final class ToolLineTests: XCTestCase {
    func testAnEditsLineIsOnItsCardLiveAndFromTheJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let notes = root.resolvingSymlinksInPath().appendingPathComponent("notes.txt").path
        let directory = root.appendingPathComponent("state")
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        let call = ToolCall(id: "call-0", name: "edit", arguments: ["path": "notes.txt", "oldText": "three", "newText": "3"])
        let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": "edit", "arguments": call.arguments]]), calls: [call])
        func open(resume: String? = nil, client: ScriptClient) throws -> AgentSession {
            try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: directory, readOnly: false,
                             resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(),
                             resumePath: resume, autoCompaction: false)
        }
        func card(_ snapshot: JSON) -> JSON? { snapshot["messages"].list.flatMap { $0["tools"].list }.first { $0["name"].text == "edit" } }
        let session = try open(client: ScriptClient([reply, answer("done")]))
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "edit"), steer: false)
        try await eventually { !(await session.isRunning) }
        let live = await session.snapshot()
        XCTAssertEqual(card(live)?["line"].int, 3, "live")
        let result = await session.history.first { $0.role == "toolResult" }
        XCTAssertEqual(result?.toolStats?["line"].int, 3, "recorded")
        XCTAssertEqual(result?.text, "Edited \(notes) (+1 -1)", "the model's text is as it was")
        let path = await session.path
        await session.close()
        let reopened = try open(resume: path, client: ScriptClient([]))
        let restored = await reopened.snapshot()
        XCTAssertEqual(card(restored)?["line"].int, 3, "from the journal")
        await reopened.close()
    }
}
