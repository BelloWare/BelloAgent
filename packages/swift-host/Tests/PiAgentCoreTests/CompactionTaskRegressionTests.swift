import XCTest
@testable import PiAgentCore

final class CompactionTaskRegressionTests: XCTestCase {
    func testManualCompactionUsesExplicitChoicesAndRejectsInvalidOverridesBeforeMutation() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer(String(repeating:"Evidence retained. ",count:600)),answer("Keep the objective and verified evidence.")])
        let session=try AgentSession(id:"manual-choice",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _=try await session.submit(Submission(commandID:"task",turnID:"task",text:"Preserve this objective.",model:"earlier-model",thinkingLevel:"low"),steer:false)
        try await eventually { !(await session.isRunning) }
        let before=await session.context
        for overrides:JSON in [["model":24],["thinkingLevel":"invalid"],["contextWindow":100,"maxOutputTokens":100]] {
            do { try await session.compact(overrides:overrides); XCTFail("Invalid compaction overrides were accepted") }
            catch let error as AgentError { XCTAssertEqual(error.code,"invalid_params") }
        }
        let after=await session.context, calls=await client.count
        XCTAssertEqual(before.map(\.id),after.map(\.id)); XCTAssertEqual(calls,1)
        try await session.compact(commandID:"selected-compact",overrides:["model":"selected-model","thinkingLevel":"high","contextWindow":60000,"maxOutputTokens":2048,"modelOutputLimit":16000])
        try await eventually { !(await session.isRunning) }
        let profiles=await client.profiles, snapshot=await session.snapshot()
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded())
        XCTAssertEqual(profiles.map(\.model),["earlier-model","selected-model"])
        XCTAssertEqual(profiles.last?.raw["thinkingLevel"].text,"high")
        XCTAssertEqual(profiles.last?.contextWindow,60000)
        XCTAssertEqual(profiles.last?.wireOutputLimit,16000)
        XCTAssertEqual(profiles.last?.modelOutputLimit,16000)
        await session.close()
    }

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
