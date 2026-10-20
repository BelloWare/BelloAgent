import XCTest
@testable import PiAgentCore

/// A tool round whose request carries the task's evidence, replayed from its content.
private func evidenceCall(_ text: String) -> ModelReply {
    var reply=toolReply(["first"]); reply.message.content.insert(textBlock(text),at:0); reply.message.providerItems=nil; return reply
}

private actor TimedCompactionClient: ModelClient {
    var purposes: [String] = []
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        purposes.append(purpose)
        try await Task.sleep(for:.milliseconds(purpose == "compaction" ? 150 : 50))
        return answer(purpose == "compaction" ? "Earlier evidence retained." : "Done.")
    }
}

final class CompactionTaskRegressionTests: XCTestCase {
    func testAutomaticCompactionCountsSummaryAndAnswerInTaskTimeAcrossReopen() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw=try fixtureProfile().raw; raw["contextWindow"]=10000; raw["maxOutputTokens"]=256
        let profile=try Profile(raw), client=TimedCompactionClient(), directory=root.appendingPathComponent("state")
        let seed=[ChatMessage(role:"user",content:[textBlock("Earlier objective")]),
                  answer(String(repeating:"Historical evidence. ",count:900)).message]
        var policy=CompactionPolicy(); policy.keepRecentTokens=1
        let session=try AgentSession(id:"timed-compact",profile:profile,apiKey:"fixture",cwd:root,directory:directory,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,compactionPolicy:policy)
        addTeardownBlock { await session.close() }
        _=try await session.keep(whenFinished:false)
        _=try await session.submit(Submission(commandID:"c",turnID:"task",text:"Continue"),steer:false)
        try await eventually { !(await session.isRunning) }
        let state=await session.snapshot(), purposes=await client.purposes
        XCTAssertEqual(state["runStatus"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(purposes,["compaction","turn"])
        let measured=try XCTUnwrap(state["turnMetrics"]["modelMs"].double)
        XCTAssertGreaterThanOrEqual(measured,200)
        XCTAssertEqual(state["taskPresentation"]["recent"].list.last?["modelMs"].double,measured)
        let saved=await session.path; await session.close()
        let reopened=try AgentSession(id:"timed-compact",profile:profile,apiKey:"fixture",cwd:root,directory:directory,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),resumePath:try XCTUnwrap(saved))
        let restored=await reopened.snapshot()
        XCTAssertEqual(restored["taskPresentation"]["recent"].list.last?["modelMs"].double,measured)
        await reopened.close()
    }

    func testManualCompactionUsesExplicitChoicesAndRejectsInvalidOverridesBeforeMutation() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // One task: a tool round, then the answer pi's one-token tail keeps.
        let client=ScriptClient([evidenceCall(String(repeating:"Evidence retained. ",count:600)),answer("Verified."),answer("Keep the objective and verified evidence.")])
        let session=try AgentSession(id:"manual-choice",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false,compactionPolicy:{ var policy=CompactionPolicy();policy.keepRecentTokens=1;return policy }())
        _=try await session.submit(Submission(commandID:"task",turnID:"task",text:"Preserve this objective.",model:"earlier-model",thinkingLevel:"low"),steer:false)
        try await eventually { !(await session.isRunning) }
        let before=await session.context
        for overrides:JSON in [["model":24],["thinkingLevel":"invalid"],["contextWindow":100,"maxOutputTokens":100]] {
            do { try await session.compact(overrides:overrides); XCTFail("Invalid compaction overrides were accepted") }
            catch let error as AgentError { XCTAssertEqual(error.code,"invalid_params") }
        }
        let after=await session.context, calls=await client.count
        XCTAssertEqual(before.map(\.id),after.map(\.id)); XCTAssertEqual(calls,2)
        let tasks=await session.snapshot()["taskPresentation"]["recent"]
        try await session.compact(commandID:"selected-compact",overrides:["model":"selected-model","thinkingLevel":"high","contextWindow":60000,"maxOutputTokens":2048,"modelOutputLimit":16000])
        try await eventually { !(await session.isRunning) }
        let profiles=await client.profiles, snapshot=await session.snapshot()
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded())
        XCTAssertEqual(profiles.map(\.model),["earlier-model","earlier-model","selected-model"])
        XCTAssertEqual(profiles.last?.raw["thinkingLevel"].text,"high")
        XCTAssertEqual(profiles.last?.contextWindow,60000)
        XCTAssertEqual(profiles.last?.wireOutputLimit,15000,"At most a quarter of the selected 60,000-token window")
        XCTAssertEqual(profiles.last?.modelOutputLimit,16000)
        XCTAssertEqual(snapshot["taskPresentation"]["recent"],tasks,"Manual utility work does not create or charge a task")
        XCTAssertTrue(snapshot["taskPresentation"]["active"].isNull)
        await session.close()
    }

    /// Pi's split turn: the one task's request goes into the turn-prefix
    /// summary ("Original Request"), with no history before it.
    func testOneUserTaskCompactsIntoPiTurnPrefixSummary() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([evidenceCall(String(repeating:"Completed work with evidence. ",count:300)), answer("Done."), answer("Completed work; preserve the user's objective.")])
        let session=try AgentSession(id:"single-task",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false,compactionPolicy:{ var policy=CompactionPolicy();policy.keepRecentTokens=1;return policy }())
        _=try await session.submit(Submission(commandID:"task",turnID:"task",text:"Keep my original objective exactly."),steer:false)
        try await eventually { !(await session.isRunning) }
        try await session.compact(commandID:"compact")
        try await eventually { !(await session.isRunning) }
        let state=await session.snapshot(), context=await session.context
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(context.first?.kind,"compaction")
        XCTAssertFalse(context.contains { $0.id=="task" })
        XCTAssertTrue(context.first?.text.contains("Completed work; preserve the user's objective.") == true)
        let calls=await client.count, requests=await client.requests; XCTAssertEqual(calls,3)
        XCTAssertTrue(requests.last?.first?.text.contains("Keep my original objective exactly.") == true)
        await session.close()
    }
}
