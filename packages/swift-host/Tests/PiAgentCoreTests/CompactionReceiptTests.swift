import XCTest
@testable import PiAgentCore

/// A completed manual compaction reports itself as completed, and its summary
/// is what a reopened journal sends to the model.
final class CompactionReceiptTests: HelperTestCase {
    /// The last exchange stays as written (0.1.136): the second question and
    /// its answer; one request summarizes the first task.
    func testCompactionReceiptAndNativeResumePreserveSummary() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"),profile=try fixtureProfile(),resources=Resources(cwd:root,home:root),traces=TraceStore()
        let client=ScriptClient([answer(String(repeating:"Completed first task evidence. ",count:80)),answer("second answer"),answer("Summary: first task was completed.\n\n---\n\n**Constraints:**\n\nNone were given.")])
        let s=try AgentSession(id:"compact-session",profile:profile,apiKey:"test",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first question"),steer:false)
        try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"second question"),steer:false)
        try await eventually { !(await s.isRunning) }
        try await s.compact(commandID:"manual-compact")
        try await eventually { !(await s.isRunning) }
        let snapshot=await s.snapshot(),path=await s.path,purposes=await client.purposes
        XCTAssertEqual(purposes,["turn","turn","compaction"],"A compaction is one request")
        XCTAssertEqual(snapshot["commands"].list.last?["commandId"].text,"manual-compact")
        XCTAssertEqual(snapshot["commands"].list.last?["state"].text,"completed")
        XCTAssertEqual(snapshot["taskPresentation"]["recent"].list.count,2,"Manual compaction is utility work, not a fabricated third conversation task")
        XCTAssertTrue(snapshot["taskPresentation"]["active"].isNull)
        XCTAssertTrue(snapshot["taskPresentation"]["utilityPhase"].isNull)
        await s.close()
        let next=ScriptClient([answer("continued")])
        let resumed=try AgentSession(id:"compact-session",profile:profile,apiKey:"test",cwd:root,directory:state,readOnly:true,resources:resources,client:next,tools:RecordingTools(),traces:traces,resumePath:path,autoCompaction:false)
        _=try await resumed.submit(Submission(commandID:"c3",turnID:"t3",text:"continue"),steer:false)
        try await eventually { !(await resumed.isRunning) }
        let request=await next.requests[0]
        XCTAssertTrue(request.contains{$0.text.contains("Summary: first task was completed.")})
        XCTAssertTrue(request.contains{$0.text.contains("**Constraints:**\n\nNone were given.")},"The summary is replayed whole")
        XCTAssertEqual(request.filter(\.replayEligible).dropFirst().map(\.text),["second question","second answer","continue"],"The last exchange, as written, then the new message")
        XCTAssertFalse(request.contains{$0.text=="first question"},"The first task is the summary")
        await resumed.close()
    }
}
