import XCTest
@testable import PiAgentCore

final class TitleTaskTests: XCTestCase {
    func testHostTitleSessionUsesMiniModelWithoutToolsOrProjectResources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "title-job", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "backgroundTask": "session-title", "toolMode": "editing"])
        let preview = try await host.command("context.preview", sessionID: "title-job", params: ["text": "Summarize the first message", "model": "mini-fixture", "thinkingLevel": "default", "contextWindow": 16000, "maxOutputTokens": 512])
        let page = try await host.command("context.preview.read", sessionID: "title-job", params: ["revision": preview["revision"], "section": "request"])
        let body = try JSON.parse(Data(page["text"].text!.utf8))
        XCTAssertEqual(body["model"].text, "mini-fixture")
        XCTAssertEqual(body["max_output_tokens"].int, 512)
        XCTAssertTrue(body["tools"].list.isEmpty); XCTAssertTrue(body["reasoning"].isNull)
        XCTAssertFalse(body.encoded().contains("PRIVATE PROJECT INSTRUCTION"))
        XCTAssertTrue(RequestContextCounter.systemPrompt(body)?.contains("Generate a short session title") == true)
        let status = try await host.command("session.status", sessionID: "title-job", params: [:])
        XCTAssertEqual(status["toolMode"].text, "read-only")
        XCTAssertNotNil(status["path"].text, "The title task owns a real journal")
        do {
            _ = try await host.command("session.open", sessionID: "unknown", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "backgroundTask": "unknown"])
            XCTFail("Unknown tasks must not silently become coding sessions")
        } catch let error as AgentError { XCTAssertEqual(error.code, "invalid_params") }
        await host.shutdown()
    }

    /// A webhook's notification is the same kind of utility request as a
    /// title: the mini model, no tools, no project instructions, and its own
    /// short instructions and purpose in the request log.
    func testHostWebhookSessionAsksTheMiniModelWithItsOwnInstructionsAndPurpose() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd": JSON(root.path), "directory": JSON(root.appendingPathComponent("state").path), "mcp": ["servers": [:]]])
        _ = try await host.command("session.open", sessionID: "webhook-job", params: ["profile": try fixtureProfile().raw, "apiKey": "synthetic", "backgroundTask": "webhook", "toolMode": "editing"])
        let preview = try await host.command("context.preview", sessionID: "webhook-job", params: ["text": "Write the notification", "model": "mini-fixture", "thinkingLevel": "default", "contextWindow": 16000, "maxOutputTokens": 2048])
        let page = try await host.command("context.preview.read", sessionID: "webhook-job", params: ["revision": preview["revision"], "section": "request"])
        let body = try JSON.parse(Data(page["text"].text!.utf8))
        XCTAssertEqual(body["model"].text, "mini-fixture"); XCTAssertEqual(body["max_output_tokens"].int, 2048)
        XCTAssertTrue(body["tools"].list.isEmpty)
        XCTAssertFalse(body.encoded().contains("PRIVATE PROJECT INSTRUCTION"))
        let system = RequestContextCounter.systemPrompt(body) ?? ""
        XCTAssertTrue(system.hasPrefix("Write the notification a webhook sends"), system)
        XCTAssertFalse(system.contains("session title"))
        let status = try await host.command("session.status", sessionID: "webhook-job", params: [:])
        XCTAssertEqual(status["toolMode"].text, "read-only")
        await host.shutdown()

        let client = ScriptClient([answer(#"{"title": "Done"}"#)])
        let session = try AgentSession(id: "webhook", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("webhook-state"), readOnly: true, resources: Resources(cwd: root, titleTask: true, utility: "webhook"), client: client, tools: DisabledTools(), traces: TraceStore(), autoCompaction: false, titleTask: true, utilityPurpose: "webhook")
        _ = try await session.submit(Submission(commandID: "webhook-command", turnID: "webhook-turn", text: "Write the notification", model: "mini-fixture", thinkingLevel: "default", contextWindow: 16000, maxOutputTokens: 2048), steer: false)
        try await eventually { !(await session.isRunning) }
        let purposes = await client.purposes
        XCTAssertEqual(purposes, ["webhook"], "The request log names the webhook's request")
        await session.close()
    }

    func testTitlePurposeAndJournalSurviveRestartWithoutResubmission() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([answer("Improve the catalog picker")])
        var session: AgentSession? = try AgentSession(id: "title", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, titleTask: true), client: client, tools: DisabledTools(), traces: TraceStore(), autoCompaction: false, titleTask: true)
        _ = try await session!.submit(Submission(commandID: "title-command", turnID: "title-turn", text: "Generate a title", model: "mini-fixture", thinkingLevel: "default", contextWindow: 16000, maxOutputTokens: 512), steer: false)
        try await eventually { !(await session!.isRunning) }
        let purposes = await client.purposes, profiles = await client.profiles, before = await session!.snapshot()
        XCTAssertEqual(purposes, ["title"]); XCTAssertEqual(profiles.first?.model, "mini-fixture"); XCTAssertEqual(profiles.first?.maxOutput, 512)
        XCTAssertEqual(before["messages"].list.last?["text"].text, "Improve the catalog picker")
        let path = try XCTUnwrap(before["path"].text)
        await session!.close(); session = nil
        let idleClient = ScriptClient([])
        let reopened = try AgentSession(id: "title", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, titleTask: true), client: idleClient, tools: DisabledTools(), traces: TraceStore(), resumePath: path, autoCompaction: false, titleTask: true)
        let restored = await reopened.snapshot(), calls = await idleClient.count
        XCTAssertEqual(restored["messages"], before["messages"]); XCTAssertEqual(calls, 0)
        await reopened.close()
    }

    func testUnexpectedToolCallFailsWithoutToolExecutionOrAnotherModelRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([toolReply(["read"]), answer("Must not be requested")]), tools = RecordingTools()
        let session = try AgentSession(id: "bad-title", profile: fixtureProfile(), apiKey: "synthetic", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, titleTask: true), client: client, tools: tools, traces: TraceStore(), autoCompaction: false, titleTask: true)
        _ = try await session.submit(Submission(commandID: "bad", turnID: "bad", text: "Title only"), steer: false)
        try await eventually { !(await session.isRunning) }
        let calls = await client.count, effects = await tools.calls, status = await session.snapshot()
        XCTAssertEqual(calls, 1); XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(status["preflightError"].text?.contains("No tool ran") == true)
        await session.close()
    }
}
