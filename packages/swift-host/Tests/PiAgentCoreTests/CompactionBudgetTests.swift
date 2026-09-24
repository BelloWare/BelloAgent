import XCTest
@testable import PiAgentCore

private actor BudgetProbe: ModelClient {
    enum Mode { case recover, twice, partial, filter, refusal, empty, tool, unknown, completedAtCap, holdSecond }
    let mode: Mode
    var requests: [JSON]=[], profiles: [Profile]=[], held=false
    init(_ mode: Mode = .recover) { self.mode=mode }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID)
        requests.append(body); profiles.append(profile)
        // The summary's room is kept free, and the output limit it carries is
        // the model's, clipped as pi clips any request.
        let count=try RequestContextCounter().count(messages:messages,profile:profile,request:body,reportedUsage:false)
        guard count.fits, tools.isEmpty, profile.wireOutputLimit.map({ $0 <= max(profile.maxOutput,PiContext.outputRoom(contextWindow:profile.contextWindow,requestTokens:count.requestTokens)) }) ?? true else { throw AgentError("fixture_contract","Summary input plus its actual cap must fit") }
        if mode == .holdSecond && requests.count==2 { held=true;while true { try await Task.sleep(nanoseconds:1_000_000) } }
        var value: JSON=["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"Observed work; preserve the objective."]]]],"usage":["input_tokens":100,"output_tokens":30,"output_tokens_details":["reasoning_tokens":10]]]
        switch mode {
        case .recover, .twice, .partial:
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
        case .holdSecond: break
        }
        var parser=ProviderAccumulator(api:"openai-responses");try parser.acceptJSON(value)
        var reply=try parser.result();reply.message.requestAttemptIDs=["budget-\(requests.count)"];return reply
    }
}

/// 240,000 characters cannot fit one 80,000-token request beside the cap.
private func oversized(_ s: AgentSession, _ policy: CompactionPolicy = CompactionPolicy()) async throws -> String {
    let original=await s.profile,revision=await s.contextMutation
    let p=try policy.summaryProfile(original,cap:policy.summaryTokens(for:original))
    // 80,000 of pi's tokens (characters over four): two chunks in an 80,000 window.
    return try await s.summarize(["[Assistant]: "+String(repeating:"e",count:320000)],previous:nil,turnPrefix:false,profile:p,originalProfile:original,revision:revision,sourceIDs:[])
}

final class CompactionBudgetTests: XCTestCase {
    /// An earlier task's evidence, then the current objective. The one-token
    /// tail keeps only the objective, so these budget cases summarize history.
    private func setup(_ root: URL, mode: BudgetProbe.Mode = .recover, ceiling: Int = 100000, window: Int = 200000, policy: CompactionPolicy = { var p=CompactionPolicy();p.keepRecentTokens=1;return p }()) throws -> (AgentSession,BudgetProbe,[ChatMessage]) {
        var raw=try fixtureProfile().raw
        raw["contextWindow"]=JSON(window);raw["modelOutputLimit"]=JSON(ceiling);raw["maxOutputTokens"]=4096
        raw["reasoning"]=true;raw["thinkingLevel"]="high";raw["thinkingLevelMap"]=["low":"low","high":"high"]
        var earlier=ChatMessage(role:"user",content:[textBlock("Inspect the logs.")]);earlier.id="earlier";earlier.taskRootID=earlier.id
        var evidence=ChatMessage(role:"assistant",content:[textBlock(String(repeating:"Observed evidence. ",count:800))]);evidence.taskRootID=earlier.id
        var user=ChatMessage(role:"user",content:[textBlock("Keep the original objective.")]);user.id="objective";user.taskRootID=user.id
        let seed=[earlier,evidence,user],client=BudgetProbe(mode)
        let session=try AgentSession(id:UUID().uuidString,profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,compactionPolicy:policy)
        return (session,client,seed)
    }

    func testPiSummaryCapSessionEffortAndPiPromptShape() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (session,client,_)=try setup(root,mode:.completedAtCap)
        try await session.compact();try await eventually { !(await session.isRunning) }
        let requests=await client.requests,snapshot=await session.snapshot(),profile=await session.profile
        XCTAssertEqual(requests.map { $0["max_output_tokens"].int },[100000],"The model's own 100,000, not a 13,107-token summary cap")
        XCTAssertEqual(requests.map { $0["reasoning"]["effort"].text },["high"])
        let request=try XCTUnwrap(requests.first),input=request["input"].list
        XCTAssertEqual(RequestContextCounter.systemPrompt(request),CompactionSourceBuilder.systemPrompt)
        XCTAssertEqual(input.count,2,"Pi's system prompt, then the one summary message")
        XCTAssertEqual(input.last?["content"].list.first?["text"].text,"<conversation>\n[User]: Inspect the logs.\n\n[Assistant]: "+String(repeating:"Observed evidence. ",count:800)+"\n</conversation>\n\n"+CompactionSourceBuilder.summarizationPrompt)
        XCTAssertEqual(profile.raw["thinkingLevel"].text,"high");XCTAssertEqual(profile.maxOutput,4096)
        XCTAssertEqual(snapshot["state"].text,"idle",snapshot["preflightError"].encoded())
        XCTAssertEqual(snapshot["compaction"]["httpAttempts"].int,1,"Usage at the cap alone is not evidence of incomplete output")
        await session.close()
    }

    func testCapExhaustionNeverAdoptsReasoningOnlyOrPartialText() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for mode:BudgetProbe.Mode in [.recover,.partial] {
            let (s,c,seed)=try setup(root,mode:mode)
            try await s.compact();try await eventually { !(await s.isRunning) }
            let state=await s.snapshot(),context=await s.context,calls=await c.requests,usage=await s.cumulativeUsage
            XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(calls.count,1,"Pi never retries a length stop")
            XCTAssertEqual(state["compaction"]["errorCode"].text,"compaction_output_exhausted")
            XCTAssertEqual(state["compaction"]["lastAttempt"]["reasoningTokens"].int,100000)
            XCTAssertEqual(usage.output,100000,"A failed summary still consumed its reported output, including reasoning once")
            XCTAssertTrue(state["preflightError"].text?.contains("budget-1") == true);await s.close()
        }
    }

    func testRefusalEmptyToolAndUnknownIncompleteHaveDistinctErrorsWithoutRetry() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for (mode,code):(BudgetProbe.Mode,String) in [(.refusal,"compaction_refused"),(.empty,"compaction_empty_summary"),(.tool,"compaction_unexpected_tool_call"),(.filter,"provider_incomplete"),(.unknown,"provider_incomplete")] {
            let (s,c,seed)=try setup(root,mode:mode)
            try await s.compact();try await eventually { !(await s.isRunning) }
            let state=await s.snapshot(),context=await s.context,calls=await c.requests
            XCTAssertEqual(state["compaction"]["errorCode"].text,code)
            XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(calls.count,1)
            if mode == .unknown { XCTAssertTrue(state["compaction"]["lastAttempt"]["outputTokens"].isNull) }
            await s.close()
        }
    }

    func testOversizedSourceIsChainedAtTheFullCapNeverClipped() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (s,c,_)=try setup(root,mode:.completedAtCap,window:80000)
        let result=try await oversized(s),requests=await c.requests
        let texts=requests.map { $0["input"].list.last?["content"].list.first?["text"].text ?? "" }
        XCTAssertEqual(result,"Observed work; preserve the objective.")
        XCTAssertEqual(requests.count,2)
        // Each chunk carries the model's limit, clipped to its window, and never less than the summary's room.
        XCTAssertTrue(requests.allSatisfy { ($0["max_output_tokens"].int ?? 0) >= 13107 && $0["reasoning"]["effort"].text=="high" })
        XCTAssertTrue(texts[1].contains("[continued]: e"));XCTAssertTrue(texts[1].contains("<previous-summary>\nObserved work; preserve the objective.\n</previous-summary>"))
        XCTAssertEqual(texts.map { $0.split(whereSeparator: { $0 != "e" }).map(\.count).max() ?? 0 }.reduce(0,+),320000,"Nothing is dropped between chunks")
        await s.close()
    }

    func testOutputExhaustionStopsAtOnceWithoutAdoptionUnderAnyBudget() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        for limit in [1,8] {
            var policy=CompactionPolicy();policy.maximumAttempts=limit;policy.keepRecentTokens=1
            let (s,c,seed)=try setup(root,mode:.twice,window:80000,policy:policy)
            do { _=try await oversized(s,policy);XCTFail("must not adopt incomplete data") }
            catch let e as AgentError { XCTAssertEqual(e.code,"compaction_output_exhausted") }
            let calls=await c.requests,context=await s.context
            XCTAssertEqual(calls.count,1);XCTAssertEqual(context.map(\.id),seed.map(\.id));await s.close()
        }
    }

    func testCancellationDuringALaterChunkPreservesContextAndAccounting() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let (s,c,seed)=try setup(root,mode:.holdSecond,window:80000)
        let task=Task { try await oversized(s) }
        try await eventually { await c.held };task.cancel()
        do { _=try await task.value;XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let context=await s.context,usage=await s.cumulativeUsage,requests=await c.requests
        XCTAssertEqual(context.map(\.id),seed.map(\.id));XCTAssertEqual(requests.count,2)
        XCTAssertEqual(usage.output,30,"Only the completed first chunk reported output");await s.close()
    }

    func testCeilingsCompatibilityAndDefaultEffortFollowPi() throws {
        var raw=try fixtureProfile().raw;raw["modelOutputLimit"]=100000;raw["outputCap"]=24000;raw["thinkingLevel"]="max"
        let policy=CompactionPolicy()
        XCTAssertEqual(policy.summaryTokens(for:try Profile(raw)),13107,"Pi's cap is the reserve's share; the chat's output cap is not the model's")
        raw["modelOutputLimit"]=12000
        XCTAssertEqual(policy.summaryTokens(for:try Profile(raw)),12000,"within the model's own ceiling")
        XCTAssertEqual(try policy.summaryProfile(Profile(raw),cap:12000).raw["thinkingLevel"].text,"max")
        raw["thinkingLevel"]="default"
        let p=try policy.summaryProfile(Profile(raw),cap:12000)
        let request=try ProviderClient.requestBody(profile:p,messages:[],instructions:"",tools:[],sessionID:"policy")
        XCTAssertTrue(request["reasoning"].isNull)
        raw["compat"]=["supportsMaxOutputTokens":false]
        let uncapped=try ProviderClient.requestBody(profile:policy.summaryProfile(Profile(raw),cap:12000),messages:[],instructions:"",tools:[],sessionID:"policy",promptCaching:false)
        XCTAssertTrue(uncapped["max_output_tokens"].isNull,"Pi sends no cap to a gateway that takes none")
    }

    func testJSONAndSSETerminalReasonAndRefusalFollowPi() throws {
        for streaming in [false,true] {
            // Pi: an incomplete response for another reason than max_output_tokens is an error.
            let filtered:JSON=["status":"incomplete","incomplete_details":["reason":"content_filter"],"output":[["type":"message","content":[["type":"refusal","refusal":"Not available"]]]]]
            var parser=ProviderAccumulator(api:"openai-responses")
            if streaming { _=try parser.consume(["type":"response.incomplete","response":filtered]) } else { try parser.acceptJSON(filtered) }
            XCTAssertThrowsError(try parser.result()) { XCTAssertEqual(($0 as? AgentError)?.message,"Response incomplete: content_filter") }
            // A refusal is text, and the terminal outcome says it was one.
            let refused:JSON=["status":"completed","output":[["type":"message","content":[["type":"refusal","refusal":"Not available"]]]]]
            var reader=ProviderAccumulator(api:"openai-responses")
            if streaming { _=try reader.consume(["type":"response.completed","response":refused]) } else { try reader.acceptJSON(refused) }
            let reply=try reader.result()
            XCTAssertEqual(reply.message.text,"Not available");XCTAssertEqual(reply.terminal?.refusal,true);XCTAssertEqual(reply.terminal?.outputExhausted,false)
        }
    }
}
