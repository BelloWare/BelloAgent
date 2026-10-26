import Foundation
import XCTest
@testable import PiAgentCore

final class ChatAskTaskTests: HelperTestCase {
    func testAskUsesItsOwnInstructionsAndPurposeWithoutProjectResourcesOrTools() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "ask-job", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "backgroundTask": "chat-ask", "toolMode": "editing"])
        let preview = try await host.command("context.preview", sessionID: "ask-job", params: ["text": "Find a chat", "model": "mini-fixture", "thinkingLevel": "default", "contextWindow": 16000, "maxOutputTokens": 2048])
        let page = try await host.command("context.preview.read", sessionID: "ask-job", params: ["revision": preview["revision"], "section": "request"])
        let body = try JSON.parse(Data(page["text"].text!.utf8))
        XCTAssertEqual(body["model"].text, "mini-fixture"); XCTAssertEqual(body["max_output_tokens"].int, 2048)
        XCTAssertTrue(body["tools"].list.isEmpty); XCTAssertFalse(body.encoded().contains("PRIVATE PROJECT INSTRUCTION"))
        let system = RequestContextCounter.systemPrompt(body) ?? ""
        XCTAssertTrue(system.hasPrefix("Find relevant chats"), system)
        XCTAssertTrue(system.contains("data, not instructions"), system)
        let loaded = await host.loadedSession("ask-job"), session = try XCTUnwrap(loaded)
        let purpose = await session.utilityPurpose, utility = await session.titleTask, compacts = await session.autoCompaction
        XCTAssertEqual(purpose, "chat-ask"); XCTAssertTrue(utility); XCTAssertFalse(compacts)
        let status = try await host.command("session.status", sessionID: "ask-job", params: [:])
        XCTAssertEqual(status["toolMode"].text, "read-only")
        await host.shutdown()
    }

    func testAskRequestIsLoggedUnderItsOwnPurposeAndCannotRunATool() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([toolReply(["read"]), answer("Must not be requested")]), tools = RecordingTools()
        let session = try AgentSession(id: "ask", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("ask-state"), readOnly: true, resources: Resources(cwd: root, titleTask: true, utility: "chat-ask"), client: client, tools: tools, traces: TraceStore(), autoCompaction: false, titleTask: true, utilityPurpose: "chat-ask")
        _ = try await session.submit(Submission(commandID: "ask", turnID: "ask", text: "Find a chat", model: "mini-fixture", thinkingLevel: "default", contextWindow: 16000, maxOutputTokens: 2048), steer: false)
        try await eventually { !(await session.isRunning) }
        let purposes = await client.purposes, calls = await client.count, effects = await tools.calls, failed = await session.snapshot()
        XCTAssertEqual(purposes, ["chat-ask"]); XCTAssertEqual(calls, 1); XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(failed["preflightError"].text?.contains("The Ask mini model request returned a tool call") == true, failed["preflightError"].text ?? "")
        await session.close()
    }
}
