import XCTest
@testable import PiAgentCore

/// When pending work reaches the model: steering after a complete tool batch,
/// follow-ups only when the run would stop, and what a stopped or truncated
/// turn leaves behind.
final class SteeringAndFollowUpTests: XCTestCase {
    func testSteeringBeforeFollowUpAndCompleteToolBatch() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([toolReply(["first","second"]),answer("steered"),answer("followup")],holdFirst:true),tools=RecordingTools(),traces=TraceStore()
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:false,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"initial"),steer:false)
        try await eventually { await client.count==1 }
        _ = try await session.submit(Submission(commandID:"c2",turnID:"t2",text:"queued"),steer:false)
        _ = try await session.submit(Submission(commandID:"c3",turnID:"t3",text:"steer"),steer:true)
        await client.release();try await eventually { !(await session.isRunning) }
        let requests=await client.requests,executed=await tools.calls
        // A reply's calls run together (pi), so they may begin in either order;
        // their results reach the next request in call order.
        XCTAssertEqual(executed.sorted(),["first","second"]);XCTAssertEqual(requests.count,3)
        XCTAssertEqual(requests[1].filter{$0.role=="toolResult"}.map(\.toolCallId),["call-0","call-1"])
        XCTAssertEqual(requests[1].filter{$0.role=="user"}.map(\.text),["initial","steer"])
        XCTAssertEqual(requests[1].filter{$0.role=="toolResult"}.count,2)
        XCTAssertEqual(requests[2].filter{$0.role=="user"}.map(\.text),["initial","steer","queued"])
        await session.close()
    }
    /// A queued follow-up that starts on its own is a new turn: its clock and
    /// its model/tool split start at zero, not at the previous turn's start.
    func testAnAutoStartedFollowUpStartsItsOwnTurnClock() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer("first answer"),answer("second answer")],holdFirst:true)
        let session=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _ = try await session.submit(Submission(commandID:"c1",turnID:"t1",text:"first"),steer:false)
        try await eventually { await client.count==1 }
        _ = try await session.submit(Submission(commandID:"c2",turnID:"t2",text:"second"),steer:false)
        try await Task.sleep(nanoseconds:400_000_000)
        let firstTurn=await session.turnMetrics()
        XCTAssertGreaterThanOrEqual(firstTurn["modelMs"].double ?? 0, 0, "the first turn is still waiting on its model")
        await client.release();try await eventually { !(await session.isRunning) }
        let requests=await client.count; XCTAssertEqual(requests,2)
        let turn=await session.turnMetrics()
        let modelMs=try XCTUnwrap(turn["modelMs"].double), durationMs=try XCTUnwrap(turn["durationMs"].double)
        print("PERF follow-up turn modelMs=\(Int(modelMs)) durationMs=\(Int(durationMs)) sessionModelMs=\(Int(turn["sessionModelMs"].double ?? 0))")
        XCTAssertLessThan(modelMs, 200, "the follow-up's model time does not include the first turn's 400 ms request")
        XCTAssertLessThan(durationMs, 200, "the follow-up's clock starts when it starts")
        XCTAssertGreaterThanOrEqual(turn["sessionModelMs"].double ?? 0, 400, "the session total still counts both turns")
        await session.close()
    }
    /// Resuming a chat whose only pending message is steering starts a task
    /// for it: there is no run for it to steer any more.
    func testResumingWithOnlySteeringPendingStartsATask() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let held=ScriptClient([answer("never")],holdFirst:true)
        let first=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:held,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _ = try await first.submit(Submission(commandID:"initial",turnID:"initial",text:"first"),steer:false)
        try await eventually { await held.count==1 }
        _ = try await first.submit(Submission(commandID:"steer",turnID:"steer",text:"also consider this"),steer:true)
        let path=await first.path; await first.close()
        let resumed=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([answer("steered answer")]),tools:RecordingTools(),traces:TraceStore(),resumePath:path,autoCompaction:false)
        try await resumed.resumeQueue(); try await eventually { !(await resumed.isRunning) }
        let state=await resumed.snapshot()
        let steered=state["messages"].list.first { $0["id"].text == "steer" }
        XCTAssertEqual(steered?["taskRootID"].text,"steer","the steering message starts its own task")
        XCTAssertTrue(state["taskPresentation"]["recent"].list.contains { $0["rootID"].text == "steer" && $0["outcome"].text == "completed" },"the task has a receipt")
        XCTAssertEqual(state["commands"].list.first { $0["turnId"].text == "steer" }?["status"].text,"completed")
        await resumed.close()
    }
    func testCancelPausesQueueAndResumeDoesNotReplayInitialRequest() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer("cancelled"),answer("queued result")],holdFirst:true),tools=RecordingTools(),traces=TraceStore()
        let s=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await s.submit(Submission(commandID:"a",turnID:"a",text:"first"),steer:false);try await eventually { await client.count==1 }
        _ = try await s.submit(Submission(commandID:"b",turnID:"b",text:"second"),steer:false)
        await s.stop();try await eventually { !(await s.isRunning) }
        let paused=await s.snapshot();XCTAssertEqual(paused["queueCount"].int,1);XCTAssertEqual(paused["state"].text,"paused")
        await client.release();try await s.resumeQueue();try await eventually { !(await s.isRunning) }
        let requests=await client.requests;XCTAssertEqual(requests.count,2);XCTAssertEqual(requests[1].filter{$0.role=="user"}.map(\.text),["first","second"])
        await s.close()
    }
    func testATruncatedReplyEndsTheTurnAsAWarningNotAnError() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        var cut=answer("partial answer that stopped");cut.truncated=true
        let client=ScriptClient([cut,answer("second answer")]),traces=TraceStore()
        let s=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
        _ = try await s.submit(Submission(commandID:"a",turnID:"a",text:"hello"),steer:false);try await eventually { !(await s.isRunning) }
        let first=await s.snapshot()
        XCTAssertEqual(first["state"].text,"idle");XCTAssertEqual(first["runStatus"].text,"idle");XCTAssertTrue(first["preflightError"].isNull)
        XCTAssertEqual(first["queuePaused"].flag,false)
        let reply=first["messages"].list.last { $0["role"].text=="assistant" }
        XCTAssertEqual(reply?["stopReason"].text,"length","the row carries the reason");XCTAssertEqual(reply?["text"].text,"partial answer that stopped")
        _ = try await s.submit(Submission(commandID:"b",turnID:"b",text:"go on"),steer:false);try await eventually { !(await s.isRunning) }
        let second=await s.snapshot()
        XCTAssertEqual(second["state"].text,"idle");XCTAssertEqual(second["messages"].list.last?["text"].text,"second answer")
        await s.close()
    }
    func testTruncatedCallsAreNotExecutedAndSideSnapshotIsIndependent() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        var cut=toolReply(["first"]);cut.truncated=true
        let client=ScriptClient([cut,answer("recovered")]),tools=RecordingTools(),traces=TraceStore()
        let s=try AgentSession(id:"s",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:traces,autoCompaction:false)
        _ = try await s.submit(Submission(commandID:"a",turnID:"a",text:"hello"),steer:false);try await eventually { !(await s.isRunning) }
        let calls=await tools.calls;XCTAssertTrue(calls.isEmpty)
        let seed=await s.sideSeed(),sideClient=ScriptClient([answer("side result")])
        let side=try AgentSession(id:"side",profile:fixtureProfile(),apiKey:"test",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:sideClient,tools:tools,traces:traces,seed:seed.messages,parent:seed.info,autoCompaction:false)
        _ = try await side.submit(Submission(commandID:"s1",turnID:"s1",text:"side question"),steer:false);try await eventually { !(await side.isRunning) }
        let parent=await s.snapshot();XCTAssertFalse(parent["messages"].encoded().contains("side question"))
        let saved=try await side.keep(whenFinished:false);XCTAssertNotNil(saved["path"].text)
        await side.close();await s.close()
    }
}
