import XCTest
@testable import PiAgentCore

/// Records each summary request and answers "SUMMARY n".
private actor PiSummaryClient: ModelClient {
    var bodies: [JSON]=[]
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        guard purpose == "compaction" else { return answer("Continued") }
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,compaction:purpose == "compaction")
        guard try RequestContextCounter().count(messages:messages,profile:profile,request:body,reportedUsage:false).fits, body["tool_choice"].text == "none" else {
            throw AgentError("test_contract","A summary request must fit its window beside its cap")
        }
        bodies.append(body)
        return answer("SUMMARY \(bodies.count)")
    }
    /// The conversation text of each request, all of its input messages.
    var prompts: [String] { bodies.map { $0["input"].list.flatMap { $0["content"].list }.compactMap { $0["text"].text }.joined(separator:"\n") } }
}

private func user(_ id: String, _ text: String) -> ChatMessage {
    var message=ChatMessage(role:"user",content:[textBlock(text)]); message.id=id; message.taskRootID=id; return message
}
private func reply(_ id: String, _ text: String, root: String) -> ChatMessage {
    var message=ChatMessage(role:"assistant",content:[textBlock(text)]); message.id=id; message.taskRootID=root; return message
}
private func read(_ id: String, path: String, output: String, root: String) -> [ChatMessage] {
    let arguments: JSON=["path":JSON(path)]
    var call=ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(id),"name":"read","arguments":arguments]])
    call.providerItems=[["type":"function_call","id":JSON("item-"+id),"call_id":JSON(id),"name":"read","arguments":JSON(arguments.encoded())]]
    call.id="call-"+id; call.taskRootID=root
    var result=ChatMessage(role:"toolResult",content:[textBlock(output)])
    result.id="result-"+id; result.toolCallId=id; result.toolName="read"; result.toolStats=["outcome":"completed"]; result.taskRootID=root
    return [call,result]
}
/// Tasks whose user message is `chars` long, each answered briefly.
private func tasks(_ prefix: String, _ count: Int, chars: Int) -> [ChatMessage] {
    (0..<count).flatMap { n in [user("\(prefix)\(n)","\(prefix)\(n) "+String(repeating:"u",count:chars)),reply("\(prefix)\(n)-reply","Done \(prefix)\(n).",root:"\(prefix)\(n)")] }
}

final class CompactionPiTests: XCTestCase {
    private func session(_ root: URL, _ client: PiSummaryClient, seed: [ChatMessage], window: Int = 100_000, modelOutputLimit: Int? = nil,
                         policy: CompactionPolicy = CompactionPolicy()) throws -> AgentSession {
        var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window)
        if let modelOutputLimit { raw["modelOutputLimit"]=JSON(modelOutputLimit) }
        return try AgentSession(id:UUID().uuidString,profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:seed,compactionPolicy:policy)
    }
    private func compact(_ s: AgentSession) async throws -> JSON {
        try await s.compact(); try await eventually { !(await s.isRunning) }
        let state=await s.snapshot()
        XCTAssertEqual(state["state"].text,"idle",state["preflightError"].encoded())
        return state
    }

    /// Pi's compact(customInstructions) ends the summary prompt with
    /// "Additional focus: …".
    func testManualCompactionCarriesTheFocusAsPisAdditionalFocus() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PiSummaryClient(), s=try session(root,client,seed:tasks("t",8,chars:12_000))
        try await s.compact(focus:"the retry budget"); try await eventually { !(await s.isRunning) }
        let prompts=await client.prompts
        XCTAssertEqual(prompts.count,1)
        XCTAssertTrue(prompts.first?.contains("Optional user focus: \"the retry budget\"") == true, prompts.first.map { String($0.suffix(200)) } ?? "no prompt")
        await s.close()
    }

    /// Pi's compact() aborts the running turn, then compacts.
    func testManualCompactionStopsARunningTurnFirst() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw=try fixtureProfile().raw; raw["contextWindow"]=100_000
        let client=ScriptClient([answer("never finished"),answer("SUMMARY")],holdFirst:true)
        let s=try AgentSession(id:"stop-then-compact",profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                               resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),seed:tasks("t",8,chars:12_000))
        _ = try await s.submit(Submission(commandID:"run",turnID:"run",text:"keep going"),steer:false)
        try await eventually { await client.count == 1 }
        try await s.compact(); try await eventually { !(await s.isRunning) }
        let purposes=await client.purposes, context=await s.context
        XCTAssertEqual(purposes,["turn","compaction"],"The running turn stopped, then the compaction ran")
        XCTAssertEqual(context.first?.kind,"compaction")
        await s.close()
    }

    func testIntactHistoryBeyondTheWindowIsRefusedWithoutExcerpts() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let seed=[user("task","Survey every file.")]+(0..<120).flatMap { read("r\($0)",path:"src/f\($0).swift",output:"R\($0) "+String(repeating:"x",count:24_000),root:"task") }
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,window:200_000)
        try await s.compact(); try await eventually { !(await s.isRunning) }
        let state=await s.snapshot(), context=await s.context, bodies=await client.bodies
        XCTAssertEqual(state["compaction"]["errorCode"].text,"compaction_too_large")
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertEqual(context.map(\.id),seed.map(\.id))
        await s.close()
    }

    func testSecondCompactionSummarizesOnlyNewMessagesAndUpdatesThePreviousSummary() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PiSummaryClient(), s=try session(root,client,seed:tasks("A",8,chars:16_000))
        _=try await compact(s)
        let first=await client.prompts.count, summary=await s.context.first
        XCTAssertEqual(summary?.kind,"compaction"); XCTAssertEqual(summary?.text.hasSuffix("SUMMARY \(first)"),true)
        for message in tasks("B",8,chars:16_000) { try await s.append(message) }
        _=try await compact(s)
        let prompts=Array(await client.prompts.dropFirst(first)), context=await s.context
        XCTAssertEqual(prompts.count,1)
        let prompt=try XCTUnwrap(prompts.first)
        XCTAssertEqual(prompt.components(separatedBy:ProviderClient.compactionSummaryPrefix).count-1,1)
        for n in 0..<3 { XCTAssertFalse(prompt.contains("A\(n) u"),"Removed originals are not resurrected") }
        for n in 3..<8 { XCTAssertTrue(prompt.contains("A\(n) u"),"The retained history is seen by the next summary") }
        for n in 0..<8 { XCTAssertTrue(prompt.contains("B\(n) u"),"Both sides of the new cut are seen") }
        XCTAssertEqual(context.first?.text.hasSuffix("SUMMARY \(first+1)"),true)
        // Pi replays no input verbatim: the kept tail starts at B3.
        XCTAssertEqual(Array(context.dropFirst().map(\.id).prefix(2)),["B3","B3-reply"])
        await s.close()
    }

    func testNormalProjectionIsPreservedIncludingCompleteToolResultsAndFocus() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var policy=CompactionPolicy(); policy.keepRecentTokens=1
        let output="🙂"+String(repeating:"y",count:4_997)+"🙂tail"
        let seed=[user("task",String(repeating:"task ",count:1000))]+read("c1",path:"a.txt",output:output,root:"task")+[reply("done","Read it.",root:"task"),user("next","Next task")]
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,policy:policy)
        _=try await compact(s)
        let bodies=await client.bodies, context=await s.context, profile=await s.profile
        let body=try XCTUnwrap(bodies.first)
        let normal=try ProviderClient.requestBody(profile:profile,messages:seed,instructions:RequestContextCounter.systemPrompt(body) ?? "",tools:await s.sessionDefinitions(),sessionID:await s.id)
        XCTAssertEqual(Array(body["input"].list.dropLast()),normal["input"].list)
        XCTAssertEqual(body["tools"],normal["tools"])
        XCTAssertEqual(body["input"].list.first { $0["type"].text == "function_call_output" }?["output"].text,output)
        XCTAssertEqual(context.dropFirst().map(\.id),["next"])
        XCTAssertEqual(context.first?.compaction?["dependencyIDs"].list.compactMap(\.text),seed.map(\.id))
        XCTAssertEqual(context.first?.compaction?["summarySourceIDs"].list.compactMap(\.text),Array(seed.dropLast().map(\.id)))
        await s.close()
    }

    func testKeptTailIsPiRecentTwentyThousandTokensCutAtATurnStart() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // Each task is 5,000 tokens by pi's estimate: 2,000 asked, 3,000 answered.
        let seed=(0..<10).flatMap { n in [user("T\(n)","T\(n) "+String(repeating:"u",count:7_997)),reply("T\(n)-reply",String(repeating:"a",count:12_000),root:"T\(n)")] }
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,modelOutputLimit:100_000)
        _=try await compact(s)
        let context=await s.context, bodies=await client.bodies
        let kept=Array(context.dropFirst())
        XCTAssertEqual(kept.first?.id,"T6","The cut is at a turn start")
        XCTAssertEqual(kept.reduce(0) { $0+PiContext.estimateTokens($1) },20_000)
        XCTAssertEqual(bodies.count,1); XCTAssertFalse(context.first?.text.contains("Turn Context") ?? true)
        XCTAssertGreaterThanOrEqual(bodies.first?["max_output_tokens"].int ?? 0,16_384,"The model's limit, never below pi's 0.8 × 16,384 share")
        await s.close()
    }

    func testSplitTurnGetsPiTurnPrefixSummaryOfItsRequest() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // One turn: ten reads of 4,000 tokens each.
        let seed=[user("task","Inspect the reads.")]+(0..<10).flatMap { read("r\($0)",path:"f\($0)",output:String(repeating:"o",count:16_000),root:"task") }
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,modelOutputLimit:100_000)
        _=try await compact(s)
        let context=await s.context, bodies=await client.bodies, prompts=await client.prompts
        XCTAssertEqual(context.dropFirst().map(\.id),(6..<10).flatMap { ["call-r\($0)","result-r\($0)"] },"Four reads are the tail; the request is in the prefix summary")
        XCTAssertEqual(bodies.count,1,"No history precedes the turn")
        XCTAssertGreaterThanOrEqual(bodies.first?["max_output_tokens"].int ?? 0,8_192,"The model's limit, never below pi's 0.5 × reserve for a turn prefix")
        XCTAssertTrue(prompts.first?.contains("retainedRanges") == true)
        XCTAssertTrue(prompts.first?.hasPrefix("Inspect the reads.") == true)
        XCTAssertEqual(context.first?.text,CompactionCheckpoint.replayPrefix+"SUMMARY 1")
        await s.close()
    }

    /// A split turn with history before it: one request summarizes both,
    /// the turn's start in <turn-prefix> with pi's turn-prefix prompt last,
    /// where pi sends a second request for it.
    func testSplitTurnAfterHistoryIsSummarizedInTheSameRequest() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // Three earlier tasks, then one turn of ten reads of 4,000 tokens each.
        let seed=tasks("H",3,chars:8_000)+[user("task","Inspect the reads.")]+(0..<10).flatMap { read("r\($0)",path:"f\($0)",output:String(repeating:"o",count:16_000),root:"task") }
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,modelOutputLimit:100_000)
        _=try await compact(s)
        let context=await s.context, bodies=await client.bodies, prompts=await client.prompts
        XCTAssertEqual(bodies.count,1,"A compaction is one request")
        XCTAssertEqual(context.dropFirst().map(\.id),(6..<10).flatMap { ["call-r\($0)","result-r\($0)"] })
        let prompt=try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.hasPrefix("H0 u"))
        XCTAssertTrue(prompt.contains("Inspect the reads."))
        XCTAssertTrue(prompt.contains("retainedRanges"))
        let body=try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["input"].list.filter { $0["type"].text == "function_call" }.count,10,"Retained calls are seen too")
        XCTAssertEqual(body["max_output_tokens"].int,16384)
        XCTAssertEqual(context.first?.text,CompactionCheckpoint.replayPrefix+"SUMMARY 1")
        await s.close()
    }

    /// Nothing is ever split into chunks: a history too large for one
    /// request is refused before anything is sent, and the context stays.
    func testHistoryTooLargeForOneRequestIsRefusedAndKept() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let seed=tasks("C",30,chars:16_000)
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,modelOutputLimit:100_000)
        try await s.compact(); try await eventually { !(await s.isRunning) }
        let state=await s.snapshot(), context=await s.context, bodies=await client.bodies
        XCTAssertEqual(state["compaction"]["errorCode"].text,"compaction_too_large")
        XCTAssertEqual(bodies.count,0,"Nothing was sent")
        XCTAssertEqual(context.map(\.id),seed.map(\.id))
        await s.close()
    }

    func testSummaryMaxTokensFollowPiRule() throws {
        func profile(window: Int, limit: Int?, budget: Int = 4096) throws -> Profile {
            var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window); raw["maxOutputTokens"]=JSON(budget)
            if let limit { raw["modelOutputLimit"]=JSON(limit) }
            return try Profile(raw)
        }
        let policy=CompactionPolicy()
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:100_000)),16_384)
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:8_000)),8_000)
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:nil)),16_384,"Without a declared ceiling nothing bounds it: min(13,107, ∞)")
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:20_000,limit:100_000)),5_000,"At most a quarter of a small window")
        XCTAssertEqual(policy.keepRecentTokens(contextWindow:200_000),20_000)
        XCTAssertEqual(policy.keepRecentTokens(contextWindow:32_768),8_192)
    }
}
