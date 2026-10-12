import Foundation
import XCTest
@testable import PiAgentCore

/// Watches a chat's journal writes: whether the MCP outcome marker was still
/// on disk when the call's result row was written, a copy of it taken then
/// (what a crash at that moment would leave), and a write or sync to fail.
private final class RetentionProbe: @unchecked Sendable {
    private let lock = NSLock()
    let marker: URL, crashCopy: URL
    var failResultWrite = false, failSyncAfterResult = false
    private(set) var markerAtResultWrite: Bool?, resultWritten = false
    init(_ folder: URL) { marker = folder.appendingPathComponent("unknown.json"); crashCopy = folder.appendingPathComponent("crash-copy.json") }
    func beforeAppend(_ record: JSON) throws {
        lock.lock(); defer { lock.unlock() }
        guard record["type"].text == "message", record["message"]["role"].text == "toolResult", record["message"]["toolName"].text == "mcp" else { return }
        markerAtResultWrite = FileManager.default.fileExists(atPath: marker.path)
        if markerAtResultWrite == true { try? FileManager.default.copyItem(at: marker, to: crashCopy) }
        if failResultWrite { throw AgentError("fixture_write", "Fixture: the tool result cannot be written") }
        resultWritten = true
    }
    func beforeSynchronize() throws {
        lock.lock(); defer { lock.unlock() }
        if failSyncAfterResult, resultWritten { throw AgentError("fixture_sync", "Fixture: the journal cannot be synchronized") }
    }
}

/// An MCP call's "outcome unknown" marker stays until the call's result is in
/// the chat's journal: a crash or a failed write before then keeps the
/// evidence that a call which may have changed something ran.
final class MCPResultRetentionTests: XCTestCase {
    private func mcpReply() -> ModelReply {
        let call = ToolCall(id: "mcp-call", name: "mcp", arguments: ["action": "invoke", "server": "test", "tool": "echo", "arguments": ["text": "sent"]])
        var message = ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": JSON(call.name), "arguments": call.arguments]])
        message.providerItems = [["type": "function_call", "id": "item-mcp", "call_id": JSON(call.id), "name": JSON(call.name), "arguments": JSON(call.arguments.encoded())]]
        return ModelReply(message: message, calls: [call], usage: ["input": 100, "output": 10])
    }
    private func run(_ probe: RetentionProbe, in root: URL) async throws -> (MCPManager, FakeMCP, JSON) {
        let manager = MCPManager(cwd: root, outcomeMarker: probe.marker), transport = FakeMCP()
        await manager.installForTesting(name: "test", transport: transport)
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: manager)
        let session = try AgentSession(id: "chat", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false,
                                       resources: Resources(cwd: root, home: root), client: ScriptClient([mcpReply(), answer("Done")]), tools: tools, traces: TraceStore(), autoCompaction: false,
                                       beforeJournalAppend: { try probe.beforeAppend($0) }, beforeJournalSynchronize: { try probe.beforeSynchronize() })
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Call the server"), steer: false)
        try await eventually { !(await session.isRunning) }
        let snapshot = await session.snapshot()
        await session.close()
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1, "the server was called once")
        return (manager, transport, snapshot)
    }

    func testTheMarkerStaysUntilTheResultIsInTheJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = RetentionProbe(root)
        let (manager, _, snapshot) = try await run(probe, in: root)
        XCTAssertEqual(snapshot["state"].text, "idle")
        XCTAssertEqual(probe.markerAtResultWrite, true, "the marker is on disk while the result is written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.marker.path), "a kept result clears the marker")
        let list = try await manager.perform(["action": "list"])
        XCTAssertEqual(list["outcomeUnknown"].flag, false)
        // A crash as the result was written leaves the marker: a restart
        // reads the outcome as unknown and asks the user to verify it.
        let restarted = MCPManager(cwd: root, outcomeMarker: probe.crashCopy)
        await restarted.installForTesting(name: "test", transport: FakeMCP())
        let after = try await restarted.perform(["action": "list"])
        XCTAssertEqual(after["outcomeUnknown"].flag, true)
        do { _ = try await restarted.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": [:]]); XCTFail("must stay blocked") }
        catch let error as AgentError { XCTAssertEqual(error.code, "mcp_outcome_unknown") }
    }

    func testAFailedResultWriteLeavesTheOutcomeUnknown() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = RetentionProbe(root); probe.failResultWrite = true
        let (manager, _, _) = try await run(probe, in: root)
        try await assertUnknown(manager, marker: probe.marker)
    }

    func testAFailedJournalSyncLeavesTheOutcomeUnknown() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = RetentionProbe(root); probe.failSyncAfterResult = true
        let (manager, _, _) = try await run(probe, in: root)
        try await assertUnknown(manager, marker: probe.marker)
    }

    /// The marker and the in-memory state both say unknown; the user's
    /// acknowledgement is what clears them, as before.
    private func assertUnknown(_ manager: MCPManager, marker: URL) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the evidence that the call ran stays on disk")
        let list = try await manager.perform(["action": "list"])
        XCTAssertEqual(list["outcomeUnknown"].flag, true)
        do { _ = try await manager.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": [:]]); XCTFail("must stay blocked") }
        catch let error as AgentError { XCTAssertEqual(error.code, "mcp_outcome_unknown") }
        try await manager.acknowledgeUnknown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        _ = try await manager.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": ["text": "after"]])
    }

    /// A result its caller has not yet kept holds the marker, also after the
    /// invocation itself has ended, and the acknowledgement waits for it.
    func testAResultAwaitingRetentionHoldsTheMarker() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("unknown.json"), manager = MCPManager(cwd: root, outcomeMarker: marker)
        await manager.installForTesting(name: "test", transport: FakeMCP())
        _ = try await manager.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": [:]], retainedBy: "a")
        _ = try await manager.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": [:]], retainedBy: "a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        do { try await manager.acknowledgeUnknown(); XCTFail("a result is still on its way to the journal") }
        catch let error as AgentError { XCTAssertEqual(error.code, "mcp_busy") }
        await manager.resultsRetained(["a"], retained: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "one of the two results is still not kept")
        await manager.resultsRetained(["a"], retained: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // A caller that keeps nothing (the inspector's one-shot call) clears it on return, as before.
        _ = try await manager.perform(["action": "invoke", "server": "test", "tool": "echo", "arguments": [:]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
