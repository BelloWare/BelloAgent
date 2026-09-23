import XCTest
@testable import PiAgentCore

/// Pi 0.85.1 runs a reply's tool calls together (executeToolCallsParallel) and
/// puts their results in the next request in call order.
final class ParallelToolCallTests: XCTestCase {
    /// `first` waits up to two seconds for `second` to begin: run one after
    /// another, `second` could not begin until `first` had returned. `edit`
    /// takes a moment, so a later edit that did not wait for it would show.
    actor Rendezvous: ToolExecuting {
        var started: [String] = []
        func definitions(readOnly: Bool) -> [ToolDefinition] { ["first", "second", "edit", "write"].map { ToolDefinition($0, "test", [:]) } }
        func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
            started.append(call.name)
            switch call.name {
            case "first":
                let deadline = Date().addingTimeInterval(2)
                while !started.contains("second"), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
                return resultText(started.contains("second") ? "first saw second" : "first ran alone")
            case "edit":
                try await Task.sleep(nanoseconds: 150_000_000)
                started.append("edit-done")
                return resultText("edited")
            default:
                return resultText("done " + call.name)
            }
        }
    }
    private func session(_ client: ScriptClient, _ tools: Rendezvous, root: URL, readOnly: Bool) throws -> AgentSession {
        try AgentSession(id: "parallel", profile: fixtureProfile(), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: readOnly,
                         resources: Resources(cwd: root, home: root), client: client, tools: tools, traces: TraceStore())
    }

    func testAReplysCallsRunTogetherAndTheirResultsJoinInCallOrder() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = Rendezvous(), client = ScriptClient([toolReply(["first", "second"]), answer("done")])
        let session = try session(client, tools, root: root, readOnly: true)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "go"), steer: false)
        try await eventually { !(await session.isRunning) }
        let results = await session.context.filter { $0.role == "toolResult" }
        XCTAssertEqual(results.map(\.toolCallId), ["call-0", "call-1"], "Results join the next request in call order")
        XCTAssertEqual(results.first?.text, "first saw second", "The second call began while the first was still running")
        let requests = await client.count
        XCTAssertEqual(requests, 2)
        await session.close()
    }

    func testEditingCallsKeepTheirOrderBesideTheOthers() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = Rendezvous(), client = ScriptClient([toolReply(["edit", "write", "second"]), answer("done")])
        let session = try session(client, tools, root: root, readOnly: false)
        _ = try await session.submit(Submission(commandID: "a", turnID: "a", text: "go"), steer: false)
        try await eventually { !(await session.isRunning) }
        let started = await tools.started
        XCTAssertLessThan(try XCTUnwrap(started.firstIndex(of: "edit-done")), try XCTUnwrap(started.firstIndex(of: "write")), "A later edit waits for the earlier one")
        XCTAssertLessThan(try XCTUnwrap(started.firstIndex(of: "second")), try XCTUnwrap(started.firstIndex(of: "edit-done")), "A call that changes nothing runs beside the edits")
        let results = await session.context.filter { $0.role == "toolResult" }
        XCTAssertEqual(results.map(\.toolCallId), ["call-0", "call-1", "call-2"])
        await session.close()
    }
}
