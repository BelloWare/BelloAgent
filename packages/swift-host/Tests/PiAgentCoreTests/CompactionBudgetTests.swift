import XCTest
@testable import PiAgentCore

private actor BudgetProbe: ModelClient {
    enum Mode { case recover, twice, partial, filter, refusal, empty, tool, unknown, completedAtCap, holdRetry }
    let mode: Mode
    var requests: [JSON]=[], profiles: [Profile]=[], held=false
    init(_ mode: Mode = .recover) { self.mode=mode }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID)
        requests.append(body); profiles.append(profile)
        guard try RequestContextCounter().count(messages:messages,profile:profile,request:body,reportedUsage:false).fits, tools.isEmpty, profile.maxOutput==profile.outputCap else { throw AgentError("fixture_contract","Summary input plus its actual cap must fit") }
        if mode == .holdRetry && requests.count==2 { held=true;while true { try await Task.sleep(nanoseconds:1_000_000) } }
        var value: JSON=["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"Observed work; preserve the objective."]]]],"usage":["input_tokens":100,"output_tokens":30,"output_tokens_details":["reasoning_tokens":10]]]
        switch mode {
        case .recover, .holdRetry, .twice, .partial:
            if requests.count==1 || mode == .twice {
                value["status"]="incomplete";value["incomplete_details"]=["reason":"max_output_tokens"]
                value["output"] = [["type":"reasoning","summary":[]]]
                value["usage"]["output_tokens"]=body["max_output_tokens"];value["usage"]["output_tokens_details"]["reasoning_tokens"]=body["max_output_tokens"]
                if mode == .partial { value["output"] = [["type":"message","content":[["type":"output_text","text":"Unfinished summary fragment"]]]] }
            }
        case .filter: value["status"]="incomplete";value["incomplete_details"]=["reason":"content_filter"]
        case .refusal: value["output"] = [["type":"message","content":[["type":"refusal","refusal":"Cannot summarize this."]]]]
        case .empty: value["output"] = [["type":"message","content":[["type":"output_text","text":" \n "]]]]
        case .tool: value["output"] = [["type":"function_call","call_id":"not-authorized","name":"write","arguments":"{}"]]
        case .unknown: value["status"]="incomplete";value["usage"] = .null
        case .completedAtCap: value["usage"]["output_tokens"]=body["max_output_tokens"]
        }
        var parser=ProviderAccumulator(api:"openai-responses");try parser.acceptJSON(value)
        var reply=try parser.result();reply.message.requestAttemptIDs=["budget-\(requests.count)"];return reply
    }
}

final class CompactionBudgetTests: XCTestCase {
    private func setup(_ root: URL, mode: BudgetProbe.Mode = .recover, ceiling: Int = 100000, window: Int = 200000, policy: CompactionPolicy = CompactionPolicy()) throws -> (AgentSession,BudgetProbe,[ChatMessage]) {
        var raw=try fixtureProfile().raw
        raw["contextWindow"]=JSON(window);raw["modelOutputLimit"]=JSON(ceiling);raw["maxOutputTokens"]=4096
        raw["reasoning"]=true;raw["thinkingLevel"]="high";raw["thinkingLevelMap"]=["low":"low","high":"high"]
        var user=ChatMessage(role:"user",content:[textBlock("Keep the original objective.")]);user.id="objective";user.taskRootID=user.id
        var evidence=ChatMessage(role:"assistant",content:[textBlock(String(repeating:"Observed evidence. ",count:800))]);evidence.taskRootID=user.id
        let seed=[user,evidence],client=BudgetProbe(mode)
        let session=try AgentSession(id:UUID().uuidString,profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,compactionPolicy:policy)
        return (session,client,seed)
    }

    func testModelAllowanceAndSessionEffortArePreservedWithInstructionAtBottom() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (session,client,_)=try setup(root,mode:.completedAtCap)
        try await session.compact();try await eventually { !(await session.isRunning) }
        let requests=await client.requests,snapshot=await session.snapshot(),profile=await session.profile
        XCTAssertEqual(requests.map { $0["max_output_tokens"].int },[100000])
        XCTAssertEqual(requests.map { $0["reasoning"]["effort"].text },["high"])
        let request=try XCTUnwrap(requests.first),source=request["input"].list.first?["content"].list.first?["text"].text
        XCTAssertEqual(request["instructions"].text,"")
        XCTAssertTrue(source?.contains("sourceMessageId") == true)
        XCTAssertEqual(request["input"].list.last?["content"].list.first?["text"].text,CompactionSourceBuilder.instructions)
        XCTAssertFalse(CompactionSourceBuilder.instructions.contains("tokens"));XCTAssertFalse(CompactionSourceBuilder.instructions.contains("characters"))
        XCTAssertEqual(profile.raw["thinkingLevel"].text,"high");XCTAssertEqual(profile.maxOutput,4096)
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded())
        XCTAssertEqual(snapshot["compaction"]["httpAttempts"].int,1,"Usage at the cap alone is not evidence of incomplete output")
        await session.close()
    }

    func testFullModelCapExhaustionNeverAdoptsReasoningOnlyOrPartialText() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for mode:BudgetProbe.Mode in [.recover,.partial] {
            let (s,c,seed)=try setup(root,mode:mode)
            try await s.compact();try await eventually { !(await s.isRunning) }
            let state=await s.snapshot(),context=await s.context,calls=await c.requests,usage=await s.cumulativeUsage
            XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(calls.count,1)
            XCTAssertEqual(state["compaction"]["errorCode"].text,"compaction_output_exhausted")
            XCTAssertEqual(state["compaction"]["lastAttempt"]["reasoningTokens"].int,100000)
            XCTAssertEqual(usage.output,100000,"A failed summary still consumed its reported output, including reasoning once")
            XCTAssertTrue(state["preflightError"].text?.contains("budget-1") == true);await s.close()
        }
    }

    func testRefusalEmptyToolAndUnknownIncompleteHaveDistinctErrorsWithoutBudgetRetry() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for (mode,code):(BudgetProbe.Mode,String) in [(.refusal,"compaction_refused"),(.empty,"compaction_empty_summary"),(.tool,"compaction_unexpected_tool_call"),(.filter,"compaction_incomplete"),(.unknown,"compaction_incomplete")] {
            let (s,c,seed)=try setup(root,mode:mode)
            try await s.compact();try await eventually { !(await s.isRunning) }
            let state=await s.snapshot(),context=await s.context,calls=await c.requests
            XCTAssertEqual(state["compaction"]["errorCode"].text,code)
            XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(calls.count,1)
            if mode == .unknown { XCTAssertTrue(state["compaction"]["lastAttempt"]["outputTokens"].isNull) }
            await s.close()
        }
    }

    func testHeadroomClippingRecountsAndOneSourceReductionCanIncreaseActualCap() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (s,c,_)=try setup(root,window:80000),original=await s.profile
        let p=try CompactionPolicy().summaryProfile(original,cap:100000),revision=await s.contextMutation
        let result=try await s.summarizeBounded([String(repeating:"e",count:190000)],profile:p,originalProfile:original,revision:revision,sourceIDs:[])
        let requests=await c.requests
        XCTAssertEqual(result,"Observed work; preserve the objective.")
        XCTAssertGreaterThan(requests.count,2);XCTAssertLessThanOrEqual(requests.count,8)
        XCTAssertLessThan(requests[0]["max_output_tokens"].int!,100000)
        XCTAssertGreaterThan(requests[1]["max_output_tokens"].int!,requests[0]["max_output_tokens"].int!)
        XCTAssertLessThan(requests[1]["input"].encoded().utf8.count,requests[0]["input"].encoded().utf8.count)
        XCTAssertTrue(requests.allSatisfy { $0["reasoning"]["effort"].text=="high" });await s.close()
    }

    func testSecondExhaustionOrGlobalAttemptBudgetStopsWithoutAdoption() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for limit in [1,8] {
            var policy=CompactionPolicy();policy.maximumAttempts=limit
            let (s,c,seed)=try setup(root,mode:.twice,window:80000,policy:policy),original=await s.profile
            let p=try policy.summaryProfile(original,cap:100000),revision=await s.contextMutation
            do { _=try await s.summarizeBounded([String(repeating:"e",count:190000)],profile:p,originalProfile:original,revision:revision,sourceIDs:[]);XCTFail("must not adopt incomplete data") }
            catch let e as AgentError { XCTAssertEqual(e.code,"compaction_output_exhausted") }
            let calls=await c.requests,context=await s.context
            XCTAssertEqual(calls.count,limit==1 ? 1:2);XCTAssertEqual(context.map(\.id),seed.map(\.id));await s.close()
        }
    }

    func testCancellationDuringLargerHeadroomAttemptPreservesContextAndAccounting() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (s,c,seed)=try setup(root,mode:.holdRetry,window:80000),original=await s.profile
        let p=try CompactionPolicy().summaryProfile(original,cap:100000),revision=await s.contextMutation
        let task=Task { try await s.summarizeBounded([String(repeating:"e",count:190000)],profile:p,originalProfile:original,revision:revision,sourceIDs:[]) }
        try await eventually { await c.held };task.cancel()
        do { _=try await task.value;XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let context=await s.context,usage=await s.cumulativeUsage,requests=await c.requests
        XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(requests.count,2)
        XCTAssertEqual(usage.output,requests[0]["max_output_tokens"].int);await s.close()
    }

    func testExplicitCeilingsCompatibilityAndDefaultEffortRemainHonest() throws {
        var raw=try fixtureProfile().raw;raw["modelOutputLimit"]=100000;raw["outputCap"]=24000;raw["thinkingLevel"]="max"
        var policy=CompactionPolicy()
        XCTAssertEqual(policy.outputAllowance(for:try Profile(raw)),24000)
        policy.summaryOutputTokens=12000
        XCTAssertEqual(policy.outputAllowance(for:try Profile(raw)),12000)
        XCTAssertEqual(try policy.summaryProfile(Profile(raw),cap:12000).raw["thinkingLevel"].text,"max")
        raw["thinkingLevel"]="default"
        let p=try policy.summaryProfile(Profile(raw),cap:12000)
        let request=try ProviderClient.requestBody(profile:p,messages:[],instructions:"",tools:[],sessionID:"policy")
        XCTAssertTrue(request["reasoning"].isNull)
        raw["compat"]=["supportsMaxOutputTokens":false]
        XCTAssertThrowsError(try policy.summaryProfile(Profile(raw),cap:12000))
    }

    func testJSONAndSSETerminalReasonAndRefusalArePreserved() throws {
        for streaming in [false,true] {
            let response:JSON=["status":"incomplete","incomplete_details":["reason":"content_filter"],"output":[["type":"message","content":[["type":"refusal","refusal":"Not available"]]]]]
            var parser=ProviderAccumulator(api:"openai-responses")
            if streaming { _=try parser.consume(["type":"response.incomplete","response":response]) } else { try parser.acceptJSON(response) }
            let reply=try parser.result()
            XCTAssertEqual(reply.terminal?.status,"incomplete");XCTAssertEqual(reply.terminal?.incompleteReason,"content_filter")
            XCTAssertEqual(reply.terminal?.refusal,true);XCTAssertEqual(reply.terminal?.outputExhausted,false)
        }
    }
}
