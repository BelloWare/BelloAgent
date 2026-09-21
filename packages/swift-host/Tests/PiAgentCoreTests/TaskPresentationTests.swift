import XCTest
@testable import PiAgentCore

private actor PhaseTools: ToolExecuting {
    var invoked = 0
    var released = 0
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("read","Fixture",[:])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        invoked += 1; let index = invoked
        while released < index { try await Task.sleep(nanoseconds:1_000_000) }
        return resultText("fixture result")
    }
    func advance() { released += 1 }
}

private actor NoOutputRetryClient: ModelClient {
    var calls = 0
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        calls += 1
        if calls <= 2 { throw AgentError("provider_http","HTTP 401: deterministic request rejection") }
        return answer("Done")
    }
}

final class TaskPresentationTests: XCTestCase {
    private func make(_ root: URL, client: any ModelClient, tools: any ToolExecuting = RecordingTools(), resume: String? = nil) throws -> AgentSession {
        try AgentSession(id:"phases",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
            resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),resumePath:resume,autoCompaction:false)
    }
    private func lifecycle(_ session: AgentSession) async throws -> TaskPresentationProjection {
        try JSONDecoder().decode(TaskPresentationProjection.self,from: await session.snapshot(["includeMessages":false])["taskPresentation"].data())
    }
    func testFifteenSlowToolRoundsAreOneTaskAndCountsDoNotDependOnProjection() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools=PhaseTools(), client=ScriptClient(Array(repeating:toolReply(["read"]),count:15)+[answer("Done")])
        let session=try make(root,client:client,tools:tools); addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID:"c",turnID:"u",text:"Task"),steer:false)
        var key: String?
        for index in 1...15 {
            try await eventually { await tools.invoked == index }
            let value=try await lifecycle(session), active=try XCTUnwrap(value.active)
            XCTAssertTrue(value.valid); XCTAssertTrue(value.recent.isEmpty); XCTAssertEqual(active.phase,"tools")
            XCTAssertEqual(active.issuedCalls,index); XCTAssertEqual(active.replies,index)
            XCTAssertEqual(active.rootID,"u"); if let key { XCTAssertEqual(active.key,key) } else { key=active.key }
            let again=try await lifecycle(session); XCTAssertEqual(again.active?.key,key)
            await tools.advance()
        }
        try await eventually { !(await session.isRunning) }
        let done=try await lifecycle(session)
        XCTAssertNil(done.active); XCTAssertNil(done.utilityPhase); XCTAssertEqual(done.recent.count,1)
        XCTAssertEqual(done.recent.first?.outcome,"completed"); XCTAssertEqual(done.recent.first?.issuedCalls,15)
        let built=await session.displayProjectionBuildCount; XCTAssertEqual(built,0,"Hidden status never projects the task's full history")
        let savedPath=await session.path
        let path=try XCTUnwrap(savedPath)
        await session.close()
        let reopened=try make(root,client:ScriptClient([]),resume:path); addTeardownBlock { await reopened.close() }
        let restored=try await lifecycle(reopened); XCTAssertEqual(restored.recent,done.recent)
        let history=try await reopened.historyWindow([:]); XCTAssertEqual(history["taskRecords"].list.count,1)
    }
    func testSteeringHasItsOwnInputButFinalizesOriginalTaskBeforeFollowUp() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools=PhaseTools(), client=ScriptClient([toolReply(["read"]),answer("Steered"),toolReply(["read"]),answer("Next")])
        let session=try make(root,client:client,tools:tools); addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID:"first",turnID:"first",text:"Task"),steer:false)
        try await eventually { await tools.invoked == 1 }
        _ = try await session.submit(Submission(commandID:"steer",turnID:"steer",text:"Steer"),steer:true)
        _ = try await session.submit(Submission(commandID:"next",turnID:"next",text:"Next task"),steer:false)
        await tools.advance(); try await eventually { await tools.invoked == 2 }
        let mid=try await lifecycle(session)
        XCTAssertEqual(mid.active?.rootID,"next"); XCTAssertEqual(mid.recent.count,1)
        XCTAssertEqual(mid.recent.first?.rootID,"first"); XCTAssertEqual(mid.recent.first?.activeInputID,"steer")
        XCTAssertEqual(mid.recent.first?.outcome,"completed")
        await tools.advance(); try await eventually { !(await session.isRunning) }
        let end=try await lifecycle(session); XCTAssertEqual(end.recent.count,2)
    }
    func testCancellationAndOutputLimitNeverProduceSuccessAndRestartDoesNotSpin() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer("No")],holdFirst:true), session=try make(root,client:client)
        _ = try await session.submit(Submission(commandID:"c",turnID:"u",text:"Task"),steer:false)
        try await eventually { await client.count == 1 }
        let partial=await session.snapshot(), projected=try XCTUnwrap(partial["messages"].list.last)
        XCTAssertEqual(projected["turn"].text,"u"); XCTAssertEqual(projected["taskRootID"].text,"u")
        XCTAssertNotNil(projected["taskExecutionID"].text); XCTAssertNotNil(projected["at"].double)
        await session.stop(); try await eventually { !(await session.isRunning) }
        let stopped=try await lifecycle(session); XCTAssertNil(stopped.active); XCTAssertEqual(stopped.recent.last?.outcome,"cancelled")
        await session.close()
        var cut=answer("Partial"); cut.truncated=true
        let otherRoot=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:otherRoot) }
        let other=try make(otherRoot,client:ScriptClient([cut])); addTeardownBlock { await other.close() }
        _ = try await other.submit(Submission(commandID:"c",turnID:"u",text:"Task"),steer:false)
        try await eventually { !(await other.isRunning) }
        let ended=try await lifecycle(other); XCTAssertEqual(ended.recent.last?.outcome,"output-limited")
    }

    func testNoOutputRetriesHaveDurableAnchorsAndAnEditRetiresAbandonedEvidence() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let session=try make(root,client:NoOutputRetryClient()); addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID:"c",turnID:"u",text:"Task"),steer:false)
        try await eventually { !(await session.isRunning) }
        for _ in 0..<2 { try await session.retryRun(); try await eventually { !(await session.isRunning) } }
        let ended=try await lifecycle(session)
        XCTAssertEqual(ended.recent.map(\.outcome),["failed","failed","completed"])
        XCTAssertEqual(Set(ended.recent.map(\.key)).count,3)
        XCTAssertTrue(ended.recent.allSatisfy { $0.rootID == "u" && $0.anchorSourceID == "u" })
        XCTAssertEqual(ended.recent.prefix(2).map(\.lastSourceID),["u","u"])
        let rows=await session.snapshot()["messages"].list
        XCTAssertEqual(rows.filter { $0["role"].text == "user" }.count,1)
        let history=try await session.historyWindow([:]); XCTAssertEqual(history["taskRecords"].list.count,3)
        _ = try await session.edit(fromMessageID:"u",input:Submission(commandID:"edited",turnID:"replacement",text:"Revised task"))
        try await eventually { !(await session.isRunning) }
        let branch=try await lifecycle(session)
        XCTAssertNotEqual(branch.timeline,ended.timeline)
        XCTAssertEqual(branch.recent.map(\.rootID),["replacement"])
        let savedPath=await session.path
        await session.close()
        let reopened=try make(root,client:ScriptClient([]),resume:try XCTUnwrap(savedPath)); addTeardownBlock { await reopened.close() }
        let restored=try await lifecycle(reopened)
        XCTAssertEqual(restored.recent,branch.recent)
    }

    func testCrashCheckpointRestoresInterruptedEvidenceAndNeverReexecutesTool() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let tools=PhaseTools(), session=try make(root,client:ScriptClient([toolReply(["read"])]),tools:tools)
        addTeardownBlock { await session.close() }
        _ = try await session.submit(Submission(commandID:"c",turnID:"u",text:"Task"),steer:false)
        try await eventually { await tools.invoked == 1 }
        let savedPath=await session.path
        let crash=root.appendingPathComponent("state/crash.jsonl")
        try FileManager.default.copyItem(atPath:try XCTUnwrap(savedPath),toPath:crash.path)
        let recoveredTools=RecordingTools(), restored=try make(root,client:ScriptClient([]),tools:recoveredTools,resume:crash.path)
        addTeardownBlock { await restored.close() }
        let value=try await lifecycle(restored)
        XCTAssertNil(value.active); XCTAssertNil(value.utilityPhase)
        XCTAssertEqual(value.recent.last?.outcome,"interrupted")
        XCTAssertEqual(value.recent.last?.issuedCalls,1,"Reconstruct counters beyond the last pre-request state checkpoint")
        let stillRunning=await restored.isRunning; XCTAssertFalse(stillRunning)
        XCTAssertTrue(value.recent.last?.detail?.contains("no work was replayed") == true)
    }
}
