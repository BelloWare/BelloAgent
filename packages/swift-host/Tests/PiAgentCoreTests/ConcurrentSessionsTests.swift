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

/// Two chats of one workspace answer at the same time; only their editing
/// tool calls take turns on the workspace gate.
final class ConcurrentSessionsTests: XCTestCase {
    private func session(_ id: String, root: URL, client: ScriptClient, tools: any ToolExecuting, gate: AsyncGate, traces: TraceStore) throws -> AgentSession {
        try AgentSession(id:id,profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state-"+id),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,editingGate:gate,autoCompaction:false)
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
