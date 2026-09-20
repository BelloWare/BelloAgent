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
        XCTAssertEqual(executed,["first","second"]);XCTAssertEqual(requests.count,3)
        XCTAssertEqual(requests[1].filter{$0.role=="user"}.map(\.text),["initial","steer"])
        XCTAssertEqual(requests[1].filter{$0.role=="toolResult"}.count,2)
        XCTAssertEqual(requests[2].filter{$0.role=="user"}.map(\.text),["initial","steer","queued"])
        await session.close()
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
