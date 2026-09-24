import XCTest
@testable import PiAgentCore

/// Answers by purpose, recording every request as the Responses body pi
/// would send for it.
private actor PurposeClient: ModelClient {
    var turns: [Result<ModelReply, AgentError>], summaries: [Result<ModelReply, AgentError>]
    var bodies: [JSON]=[], purposes: [String]=[], requests: [[ChatMessage]]=[]
    /// Seconds each turn request waits before answering, so a test can queue input meanwhile.
    var turnDelay: Double = 0
    init(turns: [Result<ModelReply, AgentError>], summaries: [Result<ModelReply, AgentError>] = []) { self.turns=turns; self.summaries=summaries }
    func delayTurns(_ seconds: Double) { turnDelay=seconds }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        bodies.append(try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,promptCaching:purpose != "compaction"))
        purposes.append(purpose); requests.append(messages)
        if purpose == "compaction" {
            guard !summaries.isEmpty else { return answer("SUMMARY \(purposes.filter { $0 == "compaction" }.count)") }
            return try summaries.removeFirst().get()
        }
        if turnDelay > 0 { try await Task.sleep(nanoseconds: UInt64(turnDelay * 1_000_000_000)) }
        guard !turns.isEmpty else { throw AgentError("fixture_exhausted","Unexpected model request") }
        let next=turns.removeFirst()
        if case .success(let reply)=next { try await onDelta(.text(reply.message.text)) }
        return try next.get()
    }
    var summaryBodies: [JSON] { zip(bodies,purposes).filter { $0.1 == "compaction" }.map(\.0) }
    var turnBodies: [JSON] { zip(bodies,purposes).filter { $0.1 != "compaction" }.map(\.0) }
}

private func user(_ id: String, _ text: String) -> ChatMessage {
    var message=ChatMessage(role:"user",content:[textBlock(text)]); message.id=id; message.taskRootID=id; return message
}
private func reply(_ id: String, _ text: String, usage: JSON? = nil) -> ChatMessage {
    var message=ChatMessage(role:"assistant",content:[textBlock(text)]); message.id=id; message.usage=usage; return message
}
/// A reply that stopped at its output limit.
private func truncated(_ reply: ModelReply, output: Int) -> ModelReply {
    var value=reply; value.truncated=true; value.terminal=ModelTerminalOutcome(status:"incomplete",incompleteReason:"max_output_tokens")
    value.usage=["input":100,"output":JSON(output),"inputIncludingCache":100]
    return value
}
private func profile(window: Int = 100_000, ceiling: Int? = nil, _ change: (inout JSON) -> Void = { _ in }) throws -> Profile {
    var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window)
    if let ceiling { raw["modelOutputLimit"]=JSON(ceiling) }
    change(&raw)
    return try Profile(raw)
}

final class PiParityTests: XCTestCase {
    private func session(_ root: URL, _ client: PurposeClient, profile: Profile, seed: [ChatMessage]? = nil, auto: Bool = true, keep: Int? = nil) throws -> AgentSession {
        var policy=CompactionPolicy(); if let keep { policy.keepRecentTokens=keep }
        return try AgentSession(id:"pi-session",profile:profile,apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,autoCompaction:auto,compactionPolicy:policy)
    }
    private func settle(_ s: AgentSession) async throws -> JSON {
        try await eventually { !(await s.isRunning) }
        return await s.snapshot()
    }
    /// Tasks whose request is `chars` long, each answered briefly.
    private func tasks(_ prefix: String, _ count: Int, chars: Int) -> [ChatMessage] {
        (0..<count).flatMap { n in [user("\(prefix)\(n)","\(prefix)\(n) "+String(repeating:"u",count:chars)),reply("\(prefix)\(n)-reply","Done \(prefix)\(n).")] }
    }

    // MARK: Summary requests (compaction.ts generateSummaryWithUsage, completeSummarization)

    func testSummaryCapIsPiReserveShareWithoutTheChatBudgetOrCap() throws {
        let policy=CompactionPolicy()
        let unknown=try profile()
        XCTAssertEqual(unknown.maxOutput,4096)
        XCTAssertEqual(policy.summaryTokens(for:unknown),13_107,"An unknown ceiling bounds nothing: floor(0.8 × 16,384)")
        XCTAssertEqual(policy.summaryTokens(for:unknown,turnPrefix:true),8_192)
        XCTAssertEqual(policy.summaryTokens(for:try profile { $0["outputCap"]=2048 }),13_107,"The chat's output cap is not the model's")
        XCTAssertEqual(policy.summaryTokens(for:try profile(ceiling:8_000)),8_000)
    }

    func testSummaryRequestUsesPiCapSessionEffortAndNoPromptCache() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[.success(answer("Continued"))])
        let s=try session(root,client,profile:profile { $0["thinkingLevel"]="high" },seed:tasks("A",8,chars:16_000))
        try await s.compact(); _=try await settle(s)
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"next"),steer:false)
        let state=try await settle(s), summaries=await client.summaryBodies, turns=await client.turnBodies
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(summaries.map { $0["max_output_tokens"].int },[nil],"No summary cap: an unknown model ceiling sends no limit, as for any request")
        XCTAssertEqual(summaries.first?["reasoning"]["effort"].text,"high")
        XCTAssertTrue(summaries.first?["prompt_cache_key"].isNull == true,"A summary is sent with cacheRetention none")
        XCTAssertEqual(turns.first?["prompt_cache_key"].text,"pi-session","A turn routes to the session's prompt cache")
        await s.close()
    }

    func testGatewayWithoutOutputLimitsStillCompactsUncapped() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[])
        let s=try session(root,client,profile:profile { $0["compat"]=["supportsMaxOutputTokens":false] },seed:tasks("A",8,chars:16_000))
        try await s.compact(); let state=try await settle(s)
        let summaries=await client.summaryBodies, context=await s.context
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(summaries.count,1); XCTAssertTrue(summaries.first?["max_output_tokens"].isNull == true)
        XCTAssertEqual(context.first?.kind,"compaction")
        await s.close()
    }

    /// Ours, kept: where pi's clampMaxTokensToContext would clip the summary
    /// cap to the room its one request leaves, the source is summarized in
    /// chained chunks at the whole cap instead of risking a cut summary.
    func testSourceThatWouldClipTheCapIsChainedAtTheWholeCap() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[])
        let s=try session(root,client,profile:profile(window:40_000,ceiling:100_000),seed:tasks("A",8,chars:15_000),keep:1)
        try await s.compact(); let state=try await settle(s)
        let summaries=await client.summaryBodies.filter { !$0.encoded().contains("This is the PREFIX of a turn") }
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertGreaterThan(summaries.count,1)
        XCTAssertTrue(summaries.allSatisfy { ($0["max_output_tokens"].int ?? Int.max) >= 13_107 },"Never below the summary's room")
        await s.close()
    }

    func testCheckpointIsAdoptedWithoutMeasuringWhatFollowsIt() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[],summaries:[.success(answer(String(repeating:"summary ",count:25_000)))])
        let s=try session(root,client,profile:profile(window:40_000,ceiling:100_000),seed:tasks("A",4,chars:12_000),keep:1)
        try await s.compact(); let state=try await settle(s), context=await s.context
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(context.first?.kind,"compaction","Pi adopts the summary however long it came back")
        await s.close()
    }

    func testCompactionReplaysNoInputVerbatimAndAnEmptySinceCompactsNothing() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[])
        var call=ChatMessage(role:"assistant",content:[["type":"toolCall","id":"c1","name":"first","arguments":[:]]]); call.id="call"
        var result=ChatMessage(role:"toolResult",content:[textBlock(String(repeating:"evidence ",count:600))]); result.id="result"; result.toolCallId="c1"; result.toolName="first"
        let seed=[user("task","Keep my objective."),call,result,reply("done","Done.")]
        let s=try session(root,client,profile:profile(),seed:seed,keep:1)
        try await s.compact(); _=try await settle(s)
        let context=await s.context, prompts=await client.requests.map { $0.map(\.text).joined() }
        XCTAssertEqual(context.map(\.id).dropFirst(),["done"],"The task's request is summarized, not replayed")
        XCTAssertTrue(prompts.first?.contains("## Original Request") == true,"Pi's turn-prefix summary carries it")
        try await s.compact(); let again=try await settle(s)
        XCTAssertEqual(again["state"].text,"error")
        XCTAssertTrue(again["preflightError"].text?.hasPrefix("Already compacted") == true,again["preflightError"].encoded())
        let count=await client.purposes.count; XCTAssertEqual(count,1)
        await s.close()
    }

    func testCutCountsThePreviousSummaryWherePiSessionPathHoldsIt() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[])
        // A checkpoint that kept O0 and O1 (1,000 tokens each), then two new
        // tasks of 1,000 tokens. The summary is 3,000 tokens: with 4,500 kept,
        // pi's walk reaches it after the new tasks and cuts at N0.
        var checkpoint=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+String(repeating:"s",count:12_000))])
        checkpoint.id="checkpoint"; checkpoint.kind="compaction"
        checkpoint.compaction=["version":2,"keptIDs":["O0","O0-reply","O1","O1-reply"],"protectedIDs":[],"sourceIDs":[]]
        let old=(0..<2).flatMap { n in [user("O\(n)",String(repeating:"o",count:3_990)),reply("O\(n)-reply","o".padding(toLength:10,withPad:"o",startingAt:0))] }
        let new=(0..<2).flatMap { n in [user("N\(n)",String(repeating:"n",count:3_990)),reply("N\(n)-reply","n".padding(toLength:10,withPad:"n",startingAt:0))] }
        let s=try session(root,client,profile:profile(),seed:[checkpoint]+old+new,keep:4_500)
        try await s.compact(); let state=try await settle(s), context=await s.context
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(context.dropFirst().map(\.id),["N0","N0-reply","N1","N1-reply"])
        await s.close()
    }

    func testFileListsSortInJavaScriptOrder() {
        func read(_ path: String) -> ChatMessage { ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(path),"name":"read","arguments":["path":JSON(path)]]]) }
        let lists=CompactionSourceBuilder.fileLists([read("a\u{FF5E}"),read("a\u{1F600}")],previous:nil)
        XCTAssertEqual(lists.read,["a\u{1F600}","a\u{FF5E}"],"UTF-16 code units: a surrogate pair sorts before U+FF5E")
    }

    func testTokensBeforeIsPiEstimateOfTheContext() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[])
        // After a checkpoint no reply has measured the context: pi estimates
        // the rows as they are, without the request's instructions and tools.
        var checkpoint=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+"Earlier work.")])
        checkpoint.id="checkpoint"; checkpoint.kind="compaction"
        checkpoint.compaction=["version":2,"keptIDs":[],"protectedIDs":[],"sourceIDs":[]]
        let seed=[checkpoint]+tasks("A",8,chars:16_000)
        let s=try session(root,client,profile:profile(),seed:seed)
        try await s.compact(); _=try await settle(s)
        let context=await s.context
        XCTAssertEqual(context.first?.detail,compactionDetail(tokens:PiContext.estimateContextTokens(seed).tokens,kept:context.count-1))
        await s.close()
    }

    // MARK: The Responses request (openai-responses.ts buildParams, convertResponsesMessages)

    func testRequestBodyFollowsPiBuildParams() throws {
        var image=ChatMessage(role:"user",content:[textBlock("look"),["type":"image","mimeType":"image/png","data":"AAAA"]]); image.id="u"
        let tools=[ToolDefinition("read","Read a file",["type":"object"])]
        let body=try ProviderClient.requestBody(profile:profile(ceiling:8) { raw in
            raw["thinkingLevel"]="off"; raw["input"]=["text","image"]; raw["samplingParams"]=["temperature":0.25,"top_k":20]
        },messages:[image],instructions:"System prompt.",tools:tools,sessionID:"session-1")
        XCTAssertTrue(body["instructions"].isNull)
        XCTAssertEqual(body["input"].list.first,["role":"developer","content":"System prompt."],"A reasoning model gets the system prompt as a developer message")
        XCTAssertEqual(body["input"].list.dropFirst().first,["role":"user","content":[["type":"input_text","text":"look"],["type":"input_image","detail":"auto","image_url":"data:image/png;base64,AAAA"]]])
        XCTAssertEqual(body["tools"],[["type":"function","name":"read","description":"Read a file","parameters":["type":"object"]]],"No strict flag unless the gateway declares strict mode")
        XCTAssertTrue(body["parallel_tool_calls"].isNull)
        XCTAssertEqual(body["reasoning"],["effort":"none"]); XCTAssertTrue(body["include"].isNull)
        XCTAssertEqual(body["prompt_cache_key"].text,"session-1")
        XCTAssertEqual(body["max_output_tokens"].int,16,"Responses rejects a cap below 16")
        XCTAssertEqual(body["top_k"].int,20); XCTAssertEqual(body["temperature"].double,0.25)

        let plain=try ProviderClient.requestBody(profile:profile { raw in
            raw["reasoning"]=false; raw["compat"]=["supportsStrictMode":true]; raw["thinkingLevel"]="high"
        },messages:[image],instructions:"System prompt.",tools:tools,sessionID:String(repeating:"k",count:80))
        XCTAssertEqual(plain["input"].list.first,["role":"system","content":"System prompt."])
        XCTAssertEqual(plain["input"].list.dropFirst().first?["content"].list.last,["type":"input_text","text":"(image omitted: model does not support images)"])
        XCTAssertEqual(plain["tools"].list.first?["strict"],false)
        XCTAssertTrue(plain["reasoning"].isNull)
        XCTAssertEqual(plain["prompt_cache_key"].text?.count,64)

        let offNull=try ProviderClient.requestBody(profile:profile { raw in raw["thinkingLevel"]="off"; raw["thinkingLevelMap"]=["off":.null] },messages:[image],instructions:"",tools:[],sessionID:"s")
        XCTAssertTrue(offNull["reasoning"].isNull)
        let clamped=try ProviderClient.requestBody(profile:profile { raw in raw["thinkingLevel"]="minimal"; raw["thinkingLevelMap"]=["minimal":.null,"low":"low-effort"] },messages:[image],instructions:"",tools:[],sessionID:"s")
        XCTAssertEqual(clamped["reasoning"],["effort":"low-effort","summary":"auto"])
        XCTAssertEqual(clamped["include"],["reasoning.encrypted_content"])
        let developerless=try ProviderClient.requestBody(profile:profile { raw in raw["compat"]=["supportsDeveloperRole":false] },messages:[image],instructions:"x",tools:[],sessionID:"s")
        XCTAssertEqual(developerless["input"].list.first?["role"].text,"system")
    }

    func testToolResultsCheckpointsAndOrphansFollowPi() throws {
        let calls=ChatMessage(role:"assistant",content:["c1","c2","c3","c4"].map { (id: String) -> JSON in ["type":"toolCall","id":JSON(id),"name":"read","arguments":["path":"a"]] })
        func result(_ id: String, _ content: [JSON]) -> ChatMessage { var message=ChatMessage(role:"toolResult",content:content); message.toolCallId=id; return message }
        let image: JSON=["type":"image","mimeType":"image/png","data":"AAAA"]
        var checkpoint=ChatMessage(role:"system",content:[textBlock(CompactionCheckpoint.replayPrefix+"The summary.")]); checkpoint.kind="compaction"
        let orphan=ChatMessage(role:"assistant",content:[["type":"toolCall","id":"lost","name":"read","arguments":[:]]])
        let messages=[checkpoint,calls,result("c1",[textBlock("line 1"),textBlock("line 2")]),result("c2",[]),result("c3",[image]),result("c4",[textBlock("see"),image]),orphan,ChatMessage(role:"user",content:[textBlock("next")])]
        let vision=try ProviderClient.requestBody(profile:profile { $0["input"]=["text","image"] },messages:messages,instructions:"",tools:[],sessionID:"s")["input"].list
        XCTAssertEqual(vision.first,["role":"user","content":[["type":"input_text","text":"The conversation history before this point was compacted into the following summary:\n\n<summary>\nThe summary.\n</summary>"]]])
        let outputs=vision.filter { $0["type"].text == "function_call_output" }
        XCTAssertEqual(outputs.map { $0["output"] },["line 1\nline 2","(no tool output)",[["type":"input_image","detail":"auto","image_url":"data:image/png;base64,AAAA"]],
                                                     [["type":"input_text","text":"see"],["type":"input_image","detail":"auto","image_url":"data:image/png;base64,AAAA"]],"No result provided"])
        XCTAssertEqual(vision.last,["role":"user","content":[["type":"input_text","text":"next"]]])
        let text=try ProviderClient.requestBody(profile:profile(),messages:messages,instructions:"",tools:[],sessionID:"s")["input"].list.filter { $0["type"].text == "function_call_output" }
        XCTAssertEqual(text[2]["output"],"(tool image omitted: model does not support images)")
        XCTAssertEqual(text[3]["output"],"see\n(tool image omitted: model does not support images)")
    }

    func testAssistantReplayFollowsPiForTheSameAndAnotherModel() throws {
        let portable=try profile { $0["routing"]=["replayPolicy":"portable"] }, route=try profile()
        // A reply without reasoning replays its own items as pi rebuilds them.
        var plain=ChatMessage(role:"assistant",content:[textBlock("Hi"),["type":"toolCall","id":"call_1","name":"read","arguments":["path":"a"]]])
        plain.providerItems=[["type":"message","id":"msg_1","role":"assistant","status":"completed","content":[["type":"output_text","text":"Hi","annotations":[["type":"url_citation"]],"logprobs":[]]]],
                             ["type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"a\"}","status":"completed"]]
        plain.providerBinding=try ProviderClient.replayBinding(route)
        var result=ChatMessage(role:"toolResult",content:[textBlock("ok")]); result.toolCallId="call_1"
        let same=try ProviderClient.requestBody(profile:route,messages:[plain,result],instructions:"",tools:[],sessionID:"s")["input"].list
        XCTAssertEqual(same[0],["type":"message","role":"assistant","content":[["type":"output_text","text":"Hi","annotations":[]]],"status":"completed","id":"msg_1"])
        XCTAssertEqual(same[1],["type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"a\"}"])
        // Reasoning that is not replayed: dropped for the same model, text for another.
        var reasoned=ChatMessage(role:"assistant",content:[["type":"thinking","thinking":"Thought"],textBlock("Answer")])
        reasoned.providerItems=[["type":"reasoning","id":"rs_1","summary":[["type":"summary_text","text":"Thought"]],"encrypted_content":"opaque"],
                                ["type":"message","id":"msg_2","role":"assistant","content":[["type":"output_text","text":"Answer"]]]]
        reasoned.providerBinding=try ProviderClient.replayBinding(portable)
        let user=ChatMessage(role:"user",content:[textBlock("go")])
        let dropped=try ProviderClient.requestBody(profile:portable,messages:[user,reasoned],instructions:"",tools:[],sessionID:"s")["input"].list
        XCTAssertEqual(dropped.last,["type":"message","role":"assistant","content":[["type":"output_text","text":"Answer","annotations":[]]],"status":"completed","id":"msg_pi_1"])
        XCTAssertEqual(dropped.count,2)
        reasoned.providerBinding=try ProviderClient.replayBinding(profile { $0["modelId"]="another-model"; $0["routing"]=["replayPolicy":"portable"] })
        let other=try ProviderClient.requestBody(profile:portable,messages:[user,reasoned],instructions:"",tools:[],sessionID:"s")["input"].list
        XCTAssertEqual(Array(other.dropFirst()),[["type":"message","role":"assistant","content":[["type":"output_text","text":"Thought","annotations":[]]],"status":"completed","id":"msg_pi_1"],
                                                 ["type":"message","role":"assistant","content":[["type":"output_text","text":"Answer","annotations":[]]],"status":"completed","id":"msg_pi_1_1"]])
    }

    // MARK: The response (openai-responses-shared.ts processResponsesStream)

    func testResponseStreamFollowsPi() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        let calls: [JSON]=(0..<70).map { ["type":"function_call","id":JSON("fc_\($0)"),"call_id":JSON("call_\($0)"),"name":"read","arguments":"{\"path\":\"a\nb\"}"] }
        let streamed: JSON=["type":"function_call","id":"fc_s","call_id":"call_s","name":"read","arguments":""]
        // The streamed call is the last output item, index 73.
        for event: JSON in [["type":"response.output_item.added","output_index":73,"item":streamed],
                            ["type":"response.function_call_arguments.delta","output_index":73,"delta":"{\"path\":"],
                            ["type":"response.function_call_arguments.done","output_index":73,"arguments":"{\"path\":\"s\"}"]] { _=try accumulator.consume(event) }
        let output: [JSON]=[["type":"reasoning","id":"rs","summary":[["type":"summary_text","text":"A"],["type":"summary_text","text":"B"]]],
                            ["type":"reasoning","id":"rs2","summary":[],"content":[["type":"reasoning_text","text":"C"]]],
                            ["type":"message","id":"m","content":[["type":"output_text","text":"x"],["type":"refusal","refusal":"y"]]]]+calls+[streamed]
        _=try accumulator.consume(["type":"response.completed","response":["status":"completed","output":.array(output)]])
        let reply=try accumulator.result()
        XCTAssertEqual(reply.message.content.filter { $0["type"].text == "thinking" }.map { $0["thinking"].text },["A\n\nB","C"])
        XCTAssertEqual(reply.message.content.filter { $0["type"].text == "text" }.map { $0["text"].text },["xy"],"One text block per message item")
        XCTAssertEqual(reply.calls.count,71,"Pi has no limit on calls per reply")
        XCTAssertEqual(reply.calls.first?.arguments["path"].text,"a\nb","Pi repairs a raw control character in a string")
        XCTAssertEqual(reply.calls.last?.arguments["path"].text,"s","Arguments the item lacks come from the stream")

        var broken=ProviderAccumulator(api:"openai-responses")
        _=try broken.consume(["type":"response.completed","response":["status":"completed","output":[["type":"function_call","call_id":"c","name":"read","arguments":"{\"path\":\"a\""]]]])
        XCTAssertEqual(try broken.result().calls.first?.arguments,["path":"a"],"Unfinished JSON is read as far as it goes")

        for reason: JSON in ["content_filter",.null] {
            var filtered=ProviderAccumulator(api:"openai-responses")
            _=try filtered.consume(["type":"response.incomplete","response":["status":"incomplete","incomplete_details":["reason":reason],"output":[]]])
            XCTAssertThrowsError(try filtered.result()) { error in
                XCTAssertEqual((error as? AgentError)?.message,reason.isNull ? "Response incomplete without a provider reason" : "Response incomplete: content_filter")
            }
        }
    }

    func testPiErrorTextForProviderFailures() {
        XCTAssertEqual(PiErrorText.http(status:400,body:Data(#"{"error":{"message":"Your input exceeds the context window of this model.","code":"context_length_exceeded"}}"#.utf8)),
                       #"OpenAI API error (400): {"code":"context_length_exceeded","message":"Your input exceeds the context window of this model."}"#)
        XCTAssertEqual(PiErrorText.http(status:502,body:Data("Bad gateway".utf8)),"OpenAI API error (502): 502 Bad gateway")
        XCTAssertEqual(PiErrorText.http(status:503,body:Data()),"OpenAI API error (503): 503 status code (no body)")
        XCTAssertEqual(PiErrorText.http(status:400,body:Data(#"{"detail":"x"}"#.utf8)),"OpenAI API error (400): 400 status code (no body)")
        XCTAssertEqual(PiErrorText.stream(["type":"error","code":"server_error","message":"The server had an error"]),"Error Code server_error: The server had an error")
        XCTAssertEqual(PiErrorText.stream(["type":"response.failed","response":["error":["code":"rate_limit_exceeded","message":"Slow down"]]]),"rate_limit_exceeded: Slow down")
        XCTAssertEqual(PiErrorText.stream(["error":["message":"upstream failed"]]),"upstream failed")
    }

    // MARK: Retries and overflow (utils/retry.ts, utils/overflow.ts, agent-session.ts)

    func testHTTPTimeoutsArePiIdleTimeout() {
        XCTAssertEqual(HTTPStream.idleTimeout, 300, "pi's httpIdleTimeoutMs for the head and each body gap")
        XCTAssertEqual(HTTPStream.totalTimeout, 604_800, "pi bounds no whole request")
    }

    func testRetryAndOverflowClassificationFollowPi() {
        func http(_ status: Int, _ body: String) -> AgentError {
            AgentError("provider_http","Provider returned HTTP \(status).",providerMessage:PiErrorText.http(status:status,body:Data(body.utf8)))
        }
        XCTAssertTrue(AgentSession.isRetryable(http(400,#"{"error":{"message":"Something went wrong. Please retry your request."}}"#)),"Pi retries on the provider's words, not its status")
        XCTAssertFalse(AgentSession.isRetryable(http(408,"")),"408 alone names nothing pi retries")
        XCTAssertFalse(AgentSession.isRetryable(http(425,"")))
        XCTAssertFalse(AgentSession.isRetryable(http(429,#"{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}"#)),"Quota is not transient")
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_failed","Service temporarily unavailable")),"No pi pattern names it")
        let overflow=http(400,#"{"error":{"message":"Your input exceeds the context window of this model."}}"#)
        XCTAssertTrue(AgentSession.isContextOverflow(overflow),"Pi reads the overflow from the text; no structured code is needed")
        XCTAssertFalse(AgentSession.isContextOverflow(http(429,#"{"error":{"message":"Rate limit reached: too many tokens per minute"}}"#)))
        XCTAssertFalse(AgentSession.isRetryable(AgentError("provider_failed","Server error, and the prompt is too long",providerMessage:"server_error: prompt is too long")),"An overflow is compacted, never retried")
        XCTAssertEqual(PiProviderRules.RetrySettings().maxRetries,3)
        XCTAssertEqual([1,2,3].map(PiProviderRules.RetrySettings().delayMs),[2_000,4_000,8_000])
        XCTAssertTrue(PiProviderRules.isUsageOverflow(stopReason:"stop",usage:["input":90_000,"cacheRead":20_000],contextWindow:100_000))
        XCTAssertTrue(PiProviderRules.isUsageOverflow(stopReason:"length",usage:["input":99_000,"output":0],contextWindow:100_000))
        XCTAssertTrue(PiProviderRules.isRecoverableLength(stopReason:"length",usage:["output":500],desiredMaxOutput:8_000))
        XCTAssertFalse(PiProviderRules.isRecoverableLength(stopReason:"length",usage:["output":8_000],desiredMaxOutput:8_000))
    }

    func testAnOverflowNamedOnlyInTheProviderTextIsCompactedAndRetried() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let overflow=AgentError("provider_http","Provider returned HTTP 400. Your input exceeds the context window of this model.")
        let client=PurposeClient(turns:[.failure(overflow),.success(answer("fits now"))])
        let s=try session(root,client,profile:profile(),seed:tasks("A",8,chars:16_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(purposes,["turn","compaction","turn"],"Pi's overflow patterns need no structured error code")
        XCTAssertEqual(state["messages"].list.last?["text"].text,"fits now")
        await s.close()
    }

    func testThreeRetriesThenTheFailureStands() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let failure=AgentError("provider_failed","Model overloaded (overloaded_error)")
        let client=PurposeClient(turns:Array(repeating:.failure(failure),count:5))
        let s=try session(root,client,profile:profile())
        await s.useRetrySettings(.init(enabled:true,maxRetries:3,baseDelayMs:10))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), count=await client.purposes.count
        XCTAssertEqual(count,4,"The first request and pi's three retries")
        XCTAssertEqual(state["preflightError"].text,"Failed after 4 attempts. Model overloaded (overloaded_error)")
        await s.close()
    }

    func testSteeringQueuedDuringABackoffJoinsTheRetriedRequest() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[.failure(AgentError("provider_transport","stream dropped")),.success(answer("done"))])
        let s=try session(root,client,profile:profile())
        await s.useRetrySettings(.init(enabled:true,maxRetries:3,baseDelayMs:400))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        try await eventually { await s.snapshot()["runStatus"].text == "retrying" }
        _=try await s.submit(Submission(commandID:"steer",turnID:"steer",text:"also this"),steer:true)
        let state=try await settle(s), requests=await client.requests
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(requests.count,2)
        XCTAssertEqual(requests.last?.filter { $0.role == "user" && $0.replayEligible }.map(\.text),["go","also this"],"Pi's continued loop delivers steering first")
        await s.close()
    }

    // MARK: The turn loop (agent-loop.ts runLoop, agent-session.ts _checkCompaction)

    func testARunHasNoRequestLimit() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:Array(repeating:.success(toolReply(["first"])),count:260)+[.success(answer("done"))])
        let s=try session(root,client,profile:profile(),auto:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let deadline=Date().addingTimeInterval(60)
        while await s.isRunning, Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
        let state=await s.snapshot(), count=await client.purposes.count
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(count,261)
        await s.close()
    }

    func testCallsOfATruncatedReplyFailWithPiTextAndTheLoopContinues() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[.success(truncated(toolReply(["first"]),output:4_096)),.success(answer("re-issued"))])
        let s=try session(root,client,profile:profile(),auto:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), requests=await client.requests
        XCTAssertEqual(requests.count,2,"Pi continues after the failed batch")
        let result=try XCTUnwrap(requests.last?.last { $0.role == "toolResult" })
        XCTAssertEqual(result.text,"Tool call \"first\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.")
        XCTAssertEqual(state["messages"].list.last?["text"].text,"re-issued")
        await s.close()
    }

    func testReplyCutBelowTheModelLimitIsCompactedAndRetriedOnce() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[.success(truncated(answer("cut short"),output:500)),.success(answer("complete"))])
        let s=try session(root,client,profile:profile(ceiling:8_000),seed:tasks("A",8,chars:16_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes, requests=await client.requests
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(purposes,["turn","compaction","turn"])
        let retried=try XCTUnwrap(requests.last)
        XCTAssertEqual(retried.first?.kind,"compaction")
        XCTAssertFalse(retried.contains { $0.text == "cut short" },"The cut reply leaves the retried context")
        XCTAssertEqual(retried.last?.text,"go")
        XCTAssertEqual(state["messages"].list.last?["text"].text,"complete")
        await s.close()
    }

    func testFailedThresholdCompactionStillSendsTheRequest() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PurposeClient(turns:[.success(answer("answered"))],summaries:[.failure(AgentError("provider_http","Provider returned HTTP 400. Bad request."))])
        var seed=tasks("A",6,chars:16_000); seed[seed.count-1].usage=["input":30_000,"output":100,"cacheRead":0,"cacheWrite":0,"totalTokens":30_100]
        let s=try session(root,client,profile:profile(window:40_000),seed:seed)
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(purposes,["compaction","turn"])
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(state["compaction"]["phase"].text,"failed")
        XCTAssertEqual(state["messages"].list.last?["text"].text,"answered")
        await s.close()
    }

    /// Ours: mid-run, a failed threshold compaction stops the run. Pi sends the
    /// next request anyway, and its next round tries the same failing summary.
    func testAFailedThresholdCompactionMidRunStopsTheRunInsteadOfLooping() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var measured=toolReply(["first"]); measured.usage=["input":30_000,"output":100,"inputIncludingCache":30_000]
        let client=PurposeClient(turns:[.success(measured),.success(answer("never sent"))],summaries:[.failure(AgentError("provider_http","Provider returned HTTP 400. Bad request."))])
        // About 16,000 tokens of history: under the 23,616-token threshold, past the kept tail.
        let s=try session(root,client,profile:profile(window:40_000),seed:tasks("A",4,chars:16_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(purposes,["turn","compaction"],"No request follows the failed summary")
        XCTAssertEqual(state["state"].text,"error")
        XCTAssertEqual(state["errorCode"].text,"provider_http")
        await s.close()
    }

    /// Ours: a mid-run compaction the next measurement still finds over the
    /// threshold freed no room; the run stops instead of compacting every round.
    func testACompactionThatFreesNoRoomStopsTheRunInsteadOfLooping() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        func measuredCall(_ id: String) -> ModelReply {
            var message=ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(id),"name":"first","arguments":[:]]])
            message.providerItems=[["type":"function_call","id":JSON("item-"+id),"call_id":JSON(id),"name":"first","arguments":"{}"]]
            return ModelReply(message:message,calls:[ToolCall(id:id,name:"first",arguments:[:])],usage:["input":30_000,"output":100,"inputIncludingCache":30_000])
        }
        let client=PurposeClient(turns:[.success(measuredCall("a")),.success(measuredCall("b")),.success(answer("never sent"))],summaries:[.success(answer("SUMMARY"))])
        let s=try session(root,client,profile:profile(window:40_000),seed:tasks("A",4,chars:16_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(purposes,["turn","compaction","turn"],"No second compaction and no further request")
        XCTAssertEqual(state["errorCode"].text,"compact_no_progress")
        await s.close()
    }

    func testThresholdIsMeasuredBeforeAFollowUpJoins() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // The first reply reports 23,000 of a 23,616 threshold; the follow-up
        // adds 1,000 more, but pi measures before it joins.
        var first=answer("first"); first.usage=["input":22_900,"output":100,"total":23_000,"inputIncludingCache":22_900]
        let client=PurposeClient(turns:[.success(first),.success(answer("second"))])
        await client.delayTurns(0.3)
        let s=try session(root,client,profile:profile(window:40_000),seed:tasks("A",4,chars:16_000))
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"go"),steer:false)
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:String(repeating:"f",count:4_000)),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        XCTAssertEqual(purposes,["turn","turn"])
        await s.close()
    }

    func testCompletedReplyOverTheWindowCompactsAsOverflow() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var big=answer("done"); big.usage=["input":120_000,"output":100,"total":120_100,"inputIncludingCache":120_000]
        let client=PurposeClient(turns:[.success(big)])
        let s=try session(root,client,profile:profile(),seed:tasks("A",8,chars:16_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        let state=try await settle(s), purposes=await client.purposes
        XCTAssertEqual(purposes,["turn","compaction"],"Case 2 compacts without a retry")
        XCTAssertEqual(state["compaction"]["reason"].text,"overflow")
        await s.close()
    }

    // MARK: Tool calls (agent-loop prepareToolCall, utils/validation.ts)

    func testArgumentsConvertAsPiValidateToolArgumentsConvertsThem() {
        let schema: JSON = ["type":"object","properties":[
            "path":["type":"string"],"offset":["type":"integer","minimum":1],"limit":["type":"integer"],"exact":["type":"boolean"],
            "ratio":["type":"number"],"label":["type":["string","null"]],"note":["type":"string"],
            "choice":["anyOf":[["type":"string","enum":["a","b"]],["type":"number"]]],"tags":["type":"array","items":["type":"string"]]],
            "required":["path","note"],"additionalProperties":false]
        let sent: JSON = ["path":12,"offset":"2","limit":nil,"exact":"true","ratio":" 0x10 ","label":nil,"note":nil,"choice":"5","tags":[1,true,"x"]]
        XCTAssertEqual(PiProviderRules.coerceArguments(sent,schema:schema),
                       ["path":"12","offset":2,"exact":true,"ratio":16,"label":nil,"note":"","choice":5,"tags":["1","true","x"]])
        // What pi leaves as it is, for the tool to reject.
        let unconverted: JSON = ["path":"a","note":"n","offset":"2.5","exact":"yes","ratio":"12px"]
        XCTAssertEqual(PiProviderRules.coerceArguments(unconverted,schema:schema),unconverted)
        XCTAssertEqual(PiProviderRules.jsNumber("1e3"),1000); XCTAssertEqual(PiProviderRules.jsNumber(" .5 "),0.5)
        XCTAssertTrue(PiProviderRules.jsNumber("-0x10").isNaN); XCTAssertTrue(PiProviderRules.jsNumber("0x1p3").isNaN)
        XCTAssertEqual([1e21,1e-7,0.000001,5,-2.5,1.2345678901234568e20].map(PiProviderRules.jsString),["1e+21","1e-7","0.000001","5","-2.5","123456789012345680000"])
    }

    func testToolCallsArePreparedAsPiPreparesThem() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        try "one\ntwo\nthree".write(to:root.appendingPathComponent("notes.txt"),atomically:true,encoding:.utf8)
        let read=ToolCall(id:"call-0",name:"read",arguments:["path":"notes.txt","offset":"2","limit":nil])
        let write=ToolCall(id:"call-1",name:"write",arguments:["path":"x.txt","content":"x"])
        var first=ModelReply(message:ChatMessage(role:"assistant",content:[read,write].map { ["type":"toolCall","id":JSON($0.id),"name":JSON($0.name),"arguments":$0.arguments] }),calls:[read,write])
        first.usage=["input":100,"output":10]
        let client=PurposeClient(turns:[.success(first),.success(answer("done"))])
        let tools=NativeTools(cwd:root,outputs:root.appendingPathComponent("out"),mcp:MCPManager(cwd:root))
        let s=try AgentSession(id:"pi-session",profile:profile(),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                               resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"t",text:"go"),steer:false)
        _=try await settle(s)
        let requests=await client.requests
        let results=try XCTUnwrap(requests.last).filter { $0.role == "toolResult" }
        XCTAssertEqual(results.map(\.text),["two\nthree","Tool write not found"],"Arguments converted to the schema; an unoffered tool in pi's words")
        XCTAssertEqual(results.map(\.isError),[false,true])
        let call=try XCTUnwrap(requests.last?.first { $0.role == "assistant" }?.content.first)
        XCTAssertEqual(call["arguments"],["path":"notes.txt","offset":"2","limit":nil],"The reply keeps what the model sent")
        await s.close()
    }
}
