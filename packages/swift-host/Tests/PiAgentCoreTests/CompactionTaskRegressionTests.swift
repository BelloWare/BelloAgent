import XCTest
@testable import PiAgentCore

final class CompactionTaskRegressionTests: XCTestCase {
    func testOneUserTaskCanCompactWithoutDiscardingItsObjective() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer(String(repeating:"Completed work with evidence. ",count:300)), answer("Completed work; preserve the user's objective.")])
        let session=try AgentSession(id:"single-task",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _=try await session.submit(Submission(commandID:"task",turnID:"task",text:"Keep my original objective exactly."),steer:false)
        try await eventually { !(await session.isRunning) }
        try await session.compact(commandID:"compact")
        try await eventually { !(await session.isRunning) }
        let state=await session.snapshot(), context=await session.context
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(context.first?.kind,"compaction")
        XCTAssertTrue(context.contains { $0.id=="task" && $0.text=="Keep my original objective exactly." })
        let calls=await client.count; XCTAssertEqual(calls,2)
        await session.close()
    }
}
