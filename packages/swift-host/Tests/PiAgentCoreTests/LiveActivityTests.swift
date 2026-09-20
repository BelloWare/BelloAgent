import XCTest
@testable import PiAgentCore

private final class ActivityNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func received() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private actor HeldActivityTool: ToolExecuting {
    private var held = true
    private(set) var running = false
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("first", "Silent held fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        running = true
        while held { try await Task.sleep(nanoseconds: 1_000_000) }
        return resultText("Finished")
    }
    func release() { held = false }
}

private actor StreamingActivityClient: ModelClient {
    private var callback: (@Sendable (StreamDelta) async throws -> Void)?
    private var held = true
    var ready: Bool { callback != nil }
    func emit(_ delta: StreamDelta) async throws { try await callback?(delta) }
    func release() { held = false }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        callback = onDelta
        while held { try await Task.sleep(nanoseconds: 1_000_000) }
        return answer("Completed")
    }
}

final class LiveActivityTests: XCTestCase {
    func testHiddenStatusSeesModelAndSilentToolPhaseChangesThroughNotifications() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ScriptClient([toolReply(["first"]), answer("Done")], holdFirst: true)
        let tools = HeldActivityTool(), notifications = ActivityNotifications()
        let session = try AgentSession(id: "phases", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore(), autoCompaction: false, changed: { _, _ in notifications.received() })
        addTeardownBlock { await tools.release(); await session.close() }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Run silent tool"), steer: false)
        try await eventually { await client.count == 1 }
        let generating = await session.snapshot(["includeMessages": false]), before = notifications.count
        XCTAssertEqual(generating["activity"]["phase"].text, "model")
        await client.release(); try await eventually { await tools.running }
        let executing = await session.snapshot(["includeMessages": false])
        XCTAssertGreaterThan(notifications.count, before, "Tool start must notify even with no tool progress output")
        XCTAssertTrue(executing["messages"].isNull)
        XCTAssertEqual(executing["activity"]["phase"].text, "tool")
        XCTAssertEqual(executing["activity"]["toolNames"].list, ["first"])
        XCTAssertEqual(executing["activity"]["modelActive"].flag, false)
        XCTAssertTrue(executing["activity"]["estimatedOutputTokensPerSecond"].isNull)
        let during = notifications.count
        await tools.release(); try await eventually { !(await session.isRunning) }
        XCTAssertGreaterThan(notifications.count, during)
        let settled = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(settled["activity"]["phase"].text, "idle")
    }

    func testActivityContainsNoByteDerivedRateBeforeDuringOrAfterVisibleOutput() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = StreamingActivityClient()
        let session = try AgentSession(id: "reported-rates", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        addTeardownBlock { await client.release(); await session.close() }
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "Stream output"), steer: false)
        try await eventually { await client.ready }
        let waiting = await session.snapshot(["includeMessages": false])
        try await client.emit(.text(String(repeating: "x", count: 20_000)))
        try await client.emit(.thinking("Exposed reasoning 🌍"))
        try await client.emit(.tool("call", "read", "{\"path\":\"file\"}"))
        let streaming = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(streaming["activity"]["phase"].text, "model")
        XCTAssertEqual(streaming["activity"]["modelActive"].flag, true)
        await client.release(); try await eventually { !(await session.isRunning) }
        let completed = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(completed["activity"]["phase"].text, "idle")
        XCTAssertEqual(completed["activity"]["modelActive"].flag, false)
        for snapshot in [waiting, streaming, completed] {
            XCTAssertEqual(snapshot["activity"]["version"].int, 2)
            for field in ["estimatedOutputTokensPerSecond", "outputBytes", "windowMS", "rateSource"] {
                XCTAssertNil(snapshot["activity"].map[field], "Activity must not expose byte-derived rate telemetry")
            }
        }
    }

    func testStatusContainsDurableAssistantCountsThroughEditAndRestore() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state"), profile = try fixtureProfile(), resources = Resources(cwd: root, home: root)
        let client = ScriptClient([answer("First answer"), answer("Replacement answer")], holdFirst: true)
        let session = try AgentSession(id: "activity", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: client, tools: RecordingTools(), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "first", turnID: "first", text: "First question"), steer: false)
        try await eventually { await client.count == 1 }
        let running = await session.snapshot(["includeMessages": false])
        XCTAssertTrue(running["messages"].isNull)
        XCTAssertEqual(running["assistantMessageCount"].int, 0)
        XCTAssertTrue(running["latestAssistantMessageId"].isNull)
        XCTAssertEqual(running["activity"]["phase"].text, "model")
        XCTAssertEqual(running["activity"]["modelActive"].flag, true)
        XCTAssertTrue(running["activity"]["estimatedOutputTokensPerSecond"].isNull)
        await client.release(); try await eventually { !(await session.isRunning) }
        let first = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(first["assistantMessageCount"].int, 1)
        _ = try await session.edit(fromMessageID: "first", input: Submission(commandID: "edit", turnID: "edit", text: "Replacement question"))
        try await eventually { !(await session.isRunning) }
        let edited = await session.snapshot(["includeMessages": false])
        XCTAssertEqual(edited["assistantMessageCount"].int, 2, "Abandoning a visible branch cannot rewind observed outputs")
        XCTAssertNotEqual(edited["latestAssistantMessageId"], first["latestAssistantMessageId"])
        XCTAssertEqual(edited["activity"]["phase"].text, "idle")
        XCTAssertTrue(edited["activity"]["estimatedOutputTokensPerSecond"].isNull)
        let path = await session.path; await session.close()
        let restored = try AgentSession(id: "activity", profile: profile, apiKey: "fixture", cwd: root, directory: directory, readOnly: true, resources: resources, client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(), resumePath: path, autoCompaction: false)
        let reopened = await restored.snapshot(["includeMessages": false])
        XCTAssertEqual(reopened["assistantMessageCount"], edited["assistantMessageCount"])
        XCTAssertEqual(reopened["latestAssistantMessageId"], edited["latestAssistantMessageId"])
        await restored.close()
    }
}
