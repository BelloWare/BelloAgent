import XCTest
@testable import PiAgentCore

/// A completed manual compaction reports itself as completed, and its summary
/// is what a reopened journal sends to the model.
final class CompactionReceiptTests: XCTestCase {
    /// A one-token tail: the second answer stays; the first task is summarized,
    /// and the second question with pi's turn-prefix summary.
    func testCompactionReceiptAndNativeResumePreserveSummary() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"),profile=try fixtureProfile(),resources=Resources(cwd:root,home:root),traces=TraceStore()
        let client=ScriptClient([answer(String(repeating:"Completed first task evidence. ",count:80)),answer("second answer"),answer("Summary: first task was completed."),answer("Prefix: the second question was asked.")])
        let s=try AgentSession(id:"compact-session",profile:profile,apiKey:"test",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false,compactionPolicy:{ var policy=CompactionPolicy();policy.keepRecentTokens=1;return policy }())
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first question"),steer:false)
        try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"second question"),steer:false)
        try await eventually { !(await s.isRunning) }
        try await s.compact(commandID:"manual-compact")
        try await eventually { !(await s.isRunning) }
        let snapshot=await s.snapshot(),path=await s.path
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
        XCTAssertTrue(request.contains{$0.text.contains("**Turn Context (split turn):**\n\nPrefix: the second question was asked.")})
        XCTAssertTrue(request.contains{$0.text=="second answer"})
        XCTAssertFalse(request.contains{$0.text=="first question" || $0.text=="second question"})
        await resumed.close()
    }
}
