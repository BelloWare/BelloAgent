import XCTest
@testable import PiAgentCore

/// Counts overlapping invocations, so a test can tell tools that run
/// together from tools that take turns.
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
    /// Holds every call, not just session 0's.
    let holdAll: Bool
    init(holdAll: Bool = false) { self.holdAll = holdAll }
    func release() { held = false }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("edit", "fixture", [:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        let index = call.arguments["session"].int ?? -1
        calls.append(index); active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        while (index == 0 || holdAll) && held { try await Task.sleep(nanoseconds: 5_000_000) }
        try Task.checkCancellation()
        return resultText("edited-\(index)")
    }
}

/// Chats of one workspace answer at the same time, and nothing makes their
/// tool calls take turns, editing ones included (owner, 2026-10-08).
final class ConcurrentSessionsTests: XCTestCase {
    private func session(_ id: String, root: URL, client: ScriptClient, tools: any ToolExecuting, traces: TraceStore) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state-"+id),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
    }

    func testTwentyModelRequestsOverlapAndStoppingOneDoesNotCancelItsNeighbors() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore()
        let clients = (0..<20).map { ScriptClient([answer("answer-\($0)")], holdFirst: true) }
        let sessions = try clients.enumerated().map { try session("session-\($0.offset)", root: root, client: $0.element, tools: RecordingTools(), traces: traces) }
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

    func testTwentyEditingSessionsEditAtOnceAndStoppingSomeLeavesTheRest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(), tools = HeldEditingTools()
        let sessions = try (0..<20).map { index -> AgentSession in
            let call = ToolCall(id: "call-\(index)", name: "edit", arguments: ["session": JSON(index)])
            let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": "edit", "arguments": call.arguments]]), calls: [call])
            return try session("edit-\(index)", root: root, client: ScriptClient([reply, answer("done-\(index)")]), tools: tools, traces: traces)
        }
        _ = try await sessions[0].submit(Submission(commandID: "command-0", turnID: "turn-0", text: "hold first edit"), steer: false)
        try await eventually { await tools.calls == [0] }
        for index in 1..<20 { _ = try await sessions[index].submit(Submission(commandID: "command-\(index)", turnID: "turn-\(index)", text: "edit-\(index)"), steer: false) }
        // No chat waits for the held edit: every other chat's edit runs and its turn ends.
        try await eventually {
            for index in 1..<20 { if await sessions[index].isRunning { return false } }
            return true
        }
        let calls = await tools.calls, stillHeld = await sessions[0].isRunning
        XCTAssertEqual(Set(calls), Set(0..<20), "Every chat's edit ran while the first was still in its tool")
        XCTAssertTrue(stillHeld)
        await sessions[0].stop(); try await eventually { !(await sessions[0].isRunning) }
        for index in 1..<20 { let state = await sessions[index].snapshot()["state"].text; XCTAssertEqual(state, "idle") }
        for session in sessions { await session.close() }
    }

    /// Several chats are in their edits at once; stopping some leaves the
    /// others in theirs, and they finish when their tool returns.
    func testStoppingSomeChatsMidEditLeavesTheOthersEditing() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(), tools = HeldEditingTools(holdAll: true)
        let sessions = try (0..<6).map { index -> AgentSession in
            let call = ToolCall(id: "call-\(index)", name: "edit", arguments: ["session": JSON(index)])
            let reply = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": JSON(call.id), "name": "edit", "arguments": call.arguments]]), calls: [call])
            return try session("held-\(index)", root: root, client: ScriptClient([reply, answer("done-\(index)")]), tools: tools, traces: traces)
        }
        for (index, session) in sessions.enumerated() { _ = try await session.submit(Submission(commandID: "c\(index)", turnID: "t\(index)", text: "edit"), steer: false) }
        try await eventually { await tools.active == 6 }
        for index in 0..<3 { await sessions[index].stop() }
        try await eventually {
            for index in 0..<3 { if await sessions[index].isRunning { return false } }
            return true
        }
        for index in 3..<6 { let running = await sessions[index].isRunning; XCTAssertTrue(running, "Stopping other chats must not end chat \(index)'s edit") }
        await tools.release()
        try await eventually {
            for index in 3..<6 { if await sessions[index].isRunning { return false } }
            return true
        }
        for index in 3..<6 {
            let snapshot = await sessions[index].snapshot()
            XCTAssertEqual(snapshot["state"].text, "idle")
            XCTAssertTrue(snapshot["messages"].list.contains { $0["role"].text == "tool" && $0["text"].text == "edited-\(index)" })
        }
        for session in sessions { await session.close() }
    }

    func testSecondSessionAnswersWhileTheFirstRunIsStillHeld() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let traces=TraceStore()
        let held=ScriptClient([answer("first")],holdFirst:true), quick=ScriptClient([answer("second")])
        let a=try session("a",root:root,client:held,tools:RecordingTools(),traces:traces)
        let b=try session("b",root:root,client:quick,tools:RecordingTools(),traces:traces)
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

    func testEditingAndReadingToolsOfTwoSessionsOverlap() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let traces=TraceStore()
        let edits=CountingTools()
        let a=try session("a",root:root,client:ScriptClient([toolReply(["edit"]),answer("a done")]),tools:edits,traces:traces)
        let b=try session("b",root:root,client:ScriptClient([toolReply(["edit"]),answer("b done")]),tools:edits,traces:traces)
        _ = try await a.submit(Submission(commandID:"c1",turnID:"t1",text:"edit"),steer:false)
        _ = try await b.submit(Submission(commandID:"c2",turnID:"t2",text:"edit"),steer:false)
        try await eventually { let first=await a.isRunning, second=await b.isRunning; return !first && !second }
        let editCalls=await edits.calls, editOverlap=await edits.maximum
        XCTAssertEqual(editCalls,["edit","edit"]); XCTAssertEqual(editOverlap,2,"Two chats' editing tools run at the same time")

        let reads=CountingTools()
        let c=try session("c",root:root,client:ScriptClient([toolReply(["read"]),answer("c done")]),tools:reads,traces:traces)
        let d=try session("d",root:root,client:ScriptClient([toolReply(["read"]),answer("d done")]),tools:reads,traces:traces)
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

extension ConcurrentSessionsTests {
    /// One reply's editing calls run together too, even on the same file.
    func testOneReplysEditingCallsRunTogether() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let edits=CountingTools()
        let a=try session("a",root:root,client:ScriptClient([toolReply(["edit","edit","edit"]),answer("done")]),tools:edits,traces:TraceStore())
        _ = try await a.submit(Submission(commandID:"c",turnID:"t",text:"edit"),steer:false)
        try await eventually { !(await a.isRunning) }
        let overlap=await edits.maximum, calls=await edits.calls
        XCTAssertEqual(calls,["edit","edit","edit"]); XCTAssertEqual(overlap,3,"A reply's editing calls are not serialized")
        let results=await a.snapshot()["messages"].list.filter { $0["role"].text == "tool" }.count
        XCTAssertEqual(results,3)
        await a.close()
    }
}
