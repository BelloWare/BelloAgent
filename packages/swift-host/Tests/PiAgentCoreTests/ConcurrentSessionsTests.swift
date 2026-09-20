import XCTest
@testable import PiAgentCore

/// Counts overlapping invocations so the test can tell serialized editing
/// tools from concurrent read-only ones.
private actor CountingTools: ToolExecuting {
    var active=0, maximum=0, calls:[String]=[]
    func definitions(readOnly:Bool)->[ToolDefinition] { [ToolDefinition("edit","test",[:]),ToolDefinition("read","test",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON {
        calls.append(call.name); active += 1; maximum=max(maximum,active); defer { active -= 1 }
        try await Task.sleep(nanoseconds:80_000_000)
        return resultText("done "+call.name)
    }
}

private actor HeldEditingTools: ToolExecuting {
    var held = true, active = 0, maximum = 0, calls: [Int] = []
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("edit", "fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        let index = call.arguments["session"].int ?? -1
        calls.append(index); active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        while index == 0 && held { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        return resultText("edited-\(index)")
    }
}

/// Two chats of one workspace answer at the same time; only their editing
/// tool calls take turns on the workspace gate.
final class ConcurrentSessionsTests: XCTestCase {
    private func session(_ id: String, root: URL, client: ScriptClient, tools: any ToolExecuting, gate: AsyncGate, traces: TraceStore) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state-"+id),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,editingGate:gate,autoCompaction:false)
    }

    func testTwentyModelRequestsOverlapAndStoppingOneDoesNotCancelItsNeighbors() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncGate(), traces = TraceStore()
        let clients = (0..<20).map { ScriptClient([answer("answer-\($0)")], holdFirst: true) }
        let sessions = try clients.enumerated().map { try session("session-\($0.offset)", root: root, client: $0.element, tools: RecordingTools(), gate: gate, traces: traces) }
        for (index, session) in sessions.enumerated() {
            _ = try await session.submit(Submission(commandID: "command-\(index)", turnID: "turn-\(index)", text: "question-\(index)"), steer: false)
        }
        try await eventually {
            for client in clients { if await client.count != 1 { return false } }
            return true
        }
        for session in sessions { let running = await session.isRunning; XCTAssertTrue(running) }
        await sessions[7].stop()
        try await eventually { !(await sessions[7].isRunning) }
        for index in 0..<20 where index != 7 {
            let running = await sessions[index].isRunning
            XCTAssertTrue(running, "Stopping session-7 must leave session-\(index) active")
            await clients[index].release()
        }
        try await eventually {
            for session in sessions { if await session.isRunning { return false } }
            return true
        }
        for (index, session) in sessions.enumerated() {
            let snapshot = await session.snapshot()
            XCTAssertEqual(snapshot["state"].text, index == 7 ? "paused" : "idle")
            let messages = snapshot["messages"].list
            XCTAssertTrue(messages.contains { $0["role"].text == "user" && $0["text"].text == "question-\(index)" })
            XCTAssertEqual(messages.filter { $0["role"].text == "assistant" }.compactMap { $0["text"].text }, index == 7 ? [] : ["answer-\(index)"])
            await session.close()
        }
    }

    func testTwentyEditingSessionsCancelGateWaitersWithoutBlockingAnotherProject() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncGate(), traces = TraceStore(), tools = HeldEditingTools()
        let sessions = try (0..<20).map { index -> AgentSession in
            let call = ToolCall(id: "call-\(index)", name: "edit", arguments: ["session": JSON(index)])
            let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": "edit", "arguments": call.arguments]]), calls: [call])
            return try session("edit-\(index)", root: root, client: ScriptClient([reply, answer("done-\(index)")]), tools: tools, gate: gate, traces: traces)
        }
        _ = try await sessions[0].submit(Submission(commandID: "command-0", turnID: "turn-0", text: "hold first edit"), steer: false)
        try await eventually { await tools.calls == [0] }
        for index in 1..<20 { _ = try await sessions[index].submit(Submission(commandID: "command-\(index)", turnID: "turn-\(index)", text: "edit-\(index)"), steer: false) }
        try await eventually {
            for session in sessions { if await session.snapshot()["activity"]["phase"].text != "tool" { return false } }
            return true
        }
        for index in 1...10 { await sessions[index].stop() }
        try await eventually {
            for index in 1...10 { if await sessions[index].isRunning { return false } }
            return true
        }
        let stillHeld = await sessions[0].isRunning, beforeRelease = await tools.calls
        XCTAssertTrue(stillHeld); XCTAssertEqual(beforeRelease, [0], "Cancelled waiters must never enter the editing tool")
        let other = try session("other-project", root: root, client: ScriptClient([toolReply(["edit"]), answer("independent")]), tools: CountingTools(), gate: AsyncGate(), traces: TraceStore())
        _ = try await other.submit(Submission(commandID: "other", turnID: "other", text: "independent edit"), steer: false)
        try await eventually { !(await other.isRunning) }
        let firstStillHeld = await sessions[0].isRunning
        XCTAssertTrue(firstStillHeld, "A different project's gate must not wait for this project's edit")
        await tools.release()
        try await eventually {
            for session in sessions { if await session.isRunning { return false } }
            return true
        }
        let calls = await tools.calls, maximum = await tools.maximum
        XCTAssertEqual(Set(calls), Set([0] + Array(11..<20)))
        XCTAssertEqual(calls.count, 10); XCTAssertEqual(maximum, 1)
        for session in sessions { await session.close() }; await other.close()
    }

    func testSecondSessionAnswersWhileTheFirstRunIsStillHeld() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate=AsyncGate(), traces=TraceStore()
        let held=ScriptClient([answer("first")],holdFirst:true), quick=ScriptClient([answer("second")])
        let a=try session("a",root:root,client:held,tools:RecordingTools(),gate:gate,traces:traces)
        let b=try session("b",root:root,client:quick,tools:RecordingTools(),gate:gate,traces:traces)
        _ = try await a.submit(Submission(commandID:"c1",turnID:"t1",text:"slow"),steer:false)
        try await eventually { await held.count==1 }
        let accepted=try await b.submit(Submission(commandID:"c2",turnID:"t2",text:"fast"),steer:false)
        XCTAssertEqual(accepted["queued"].flag,false); XCTAssertEqual(accepted["delivery"].text,"start")
        try await eventually { !(await b.isRunning) }
        let firstStillRunning=await a.isRunning
        XCTAssertTrue(firstStillRunning,"The second chat finished while the first was still waiting on its model")
        let secondRequests=await quick.count
        XCTAssertEqual(secondRequests,1)
        let secondState=await b.snapshot()["state"].text
        XCTAssertEqual(secondState,"idle")
        await held.release(); try await eventually { !(await a.isRunning) }
        await a.close(); await b.close()
    }

    func testEditingToolsOfTwoSessionsTakeTurnsWhileReadsOverlap() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let gate=AsyncGate(), traces=TraceStore()
        let edits=CountingTools()
        let a=try session("a",root:root,client:ScriptClient([toolReply(["edit"]),answer("a done")]),tools:edits,gate:gate,traces:traces)
        let b=try session("b",root:root,client:ScriptClient([toolReply(["edit"]),answer("b done")]),tools:edits,gate:gate,traces:traces)
        _ = try await a.submit(Submission(commandID:"c1",turnID:"t1",text:"edit"),steer:false)
        _ = try await b.submit(Submission(commandID:"c2",turnID:"t2",text:"edit"),steer:false)
        try await eventually { let first=await a.isRunning, second=await b.isRunning; return !first && !second }
        let editCalls=await edits.calls, editOverlap=await edits.maximum
        XCTAssertEqual(editCalls,["edit","edit"]); XCTAssertEqual(editOverlap,1,"Editing tools never overlap")
        let gateFree: Bool = await { try? await gate.acquire(); await gate.release(); return true }()
        XCTAssertTrue(gateFree,"Both leases were released")

        let reads=CountingTools()
        let c=try session("c",root:root,client:ScriptClient([toolReply(["read"]),answer("c done")]),tools:reads,gate:gate,traces:traces)
        let d=try session("d",root:root,client:ScriptClient([toolReply(["read"]),answer("d done")]),tools:reads,gate:gate,traces:traces)
        _ = try await c.submit(Submission(commandID:"c3",turnID:"t3",text:"read"),steer:false)
        _ = try await d.submit(Submission(commandID:"c4",turnID:"t4",text:"read"),steer:false)
        try await eventually { let first=await c.isRunning, second=await d.isRunning; return !first && !second }
        let readOverlap=await reads.maximum
        XCTAssertEqual(readOverlap,2,"Read-only tools run concurrently")
        XCTAssertTrue(AgentSession.isEditing(ToolCall(id:"m",name:"mcp",arguments:["action":"invoke"])))
        XCTAssertFalse(AgentSession.isEditing(ToolCall(id:"m",name:"mcp",arguments:["action":"list"])))
        await a.close(); await b.close(); await c.close(); await d.close()
    }
}
