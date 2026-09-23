import XCTest
@testable import PiAgentCore

/// Records each summary request and answers "SUMMARY n".
private actor PiSummaryClient: ModelClient {
    var bodies: [JSON]=[]
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        guard purpose == "compaction" else { return answer("Continued") }
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID)
        guard try RequestContextCounter().count(messages:messages,profile:profile,request:body,reportedUsage:false).fits, tools.isEmpty else {
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

    func testHistoryFarBeyondTheOldTwoMiBSourceCapCompacts() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // One task of 300 reads, 24,000 characters each: 7 MB of history.
        let seed=[user("task","Survey every file.")]+(0..<300).flatMap { read("r\($0)",path:"src/f\($0).swift",output:"R\($0) "+String(repeating:"x",count:24_000),root:"task") }
        XCTAssertGreaterThan(seed.reduce(0) { $0+$1.text.utf8.count },3*2*1024*1024)
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,window:200_000)
        let state=try await compact(s), context=await s.context, prompts=await client.prompts
        XCTAssertEqual(state["compaction"]["phase"].text,"completed")
        XCTAssertEqual(context.first?.kind,"compaction")
        XCTAssertGreaterThan(prompts.count,1,"The source is larger than one request, so it is summarized in chained chunks")
        for (n,prompt) in prompts.enumerated() { XCTAssertEqual(prompt.contains("<previous-summary>\nSUMMARY \(n)\n</previous-summary>"),n>0) }
        // Each result appears once, cut to 2,000 characters: "Rn " and the x's after it.
        let results=prompts.flatMap { $0.components(separatedBy:"[Tool result]: R").dropFirst() }
        XCTAssertEqual(results.map { Int($0.prefix { $0 != " " }) ?? -1 },Array(0..<297))
        XCTAssertTrue(results.allSatisfy { $0.drop { $0 != " " }.dropFirst().prefix { $0 == "x" }.count == 2000-2-$0.prefix { $0 != " " }.count })
        XCTAssertEqual(context.dropFirst().map(\.id),["task"]+(297..<300).flatMap { ["call-r\($0)","result-r\($0)"] })
        XCTAssertTrue(context.first?.text.contains("<read-files>\nsrc/f0.swift\nsrc/f1.swift") == true,"Pi's file lists close the summary")
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
        XCTAssertTrue(prompt.contains("</conversation>\n\n<previous-summary>\nSUMMARY \(first)\n</previous-summary>\n\nThe messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags."))
        for n in 0..<3 { XCTAssertFalse(prompt.contains("[User]: A\(n) u"),"A\(n) was summarized by the first compaction") }
        for n in 3..<8 { XCTAssertTrue(prompt.contains("[User]: A\(n) u"),"A\(n) was kept by the first compaction and is summarized now") }
        XCTAssertTrue(prompt.contains("[User]: B2 u")); XCTAssertFalse(prompt.contains("[User]: B3 u"))
        XCTAssertEqual(context.first?.text.hasSuffix("SUMMARY \(first+1)"),true)
        // Appended rows start no task, so A7 is still the current task: its
        // request is replayed verbatim ahead of the kept tail.
        XCTAssertEqual(Array(context.dropFirst().map(\.id).prefix(2)),["A7","B3"])
        await s.close()
    }

    func testToolResultsAreCutAtTwoThousandCharactersInPiConversationText() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var policy=CompactionPolicy(); policy.keepRecentTokens=1
        let long="L"+String(repeating:"l",count:4_999), output="🙂"+String(repeating:"y",count:1_997)+"🙂tail"
        let calls=read("c1",path:"a.txt",output:output,root:"task")
        let seed=[user("task",long)]+calls+[reply("done","Read it.",root:"task"),user("next","Next task")]
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,policy:policy)
        _=try await compact(s)
        let bodies=await client.bodies, context=await s.context
        let body=try XCTUnwrap(bodies.first)
        XCTAssertTrue(body["instructions"].text?.hasPrefix("You are a context summarization assistant.") == true)
        XCTAssertEqual(body["input"].list.count,1)
        let prompt=try XCTUnwrap(body["input"].list.first?["content"].list.first?["text"].text)
        let expected="<conversation>\n[User]: \(long)\n\n[Assistant tool calls]: read(path=\"a.txt\")\n\n[Tool result]: 🙂" + String(repeating:"y",count:1_997) +
            "\n\n[... 6 more characters truncated]\n[history_read: \(CompactionSourceBuilder.reference(calls[1]))]\n\n[Assistant]: Read it.\n</conversation>\n\nThe messages above are a conversation to summarize."
        XCTAssertTrue(prompt.hasPrefix(expected),prompt)
        XCTAssertFalse(prompt.contains("tail"))
        XCTAssertEqual(context.map(\.id).dropFirst(),["next"])
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
        XCTAssertEqual(bodies.first?["max_output_tokens"].int,13_107,"0.8 × pi's 16,384-token reserve")
        await s.close()
    }

    func testSplitTurnGetsPiTurnPrefixSummaryAndKeepsItsRequestVerbatim() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        // One turn: ten reads of 4,000 tokens each.
        let seed=[user("task","Inspect the reads.")]+(0..<10).flatMap { read("r\($0)",path:"f\($0)",output:String(repeating:"o",count:16_000),root:"task") }
        let client=PiSummaryClient(), s=try session(root,client,seed:seed,modelOutputLimit:100_000)
        _=try await compact(s)
        let context=await s.context, bodies=await client.bodies, prompts=await client.prompts
        XCTAssertEqual(context.dropFirst().map(\.id),["task"]+(6..<10).flatMap { ["call-r\($0)","result-r\($0)"] },"Four reads are the tail; the request stays verbatim")
        XCTAssertEqual(bodies.count,1,"No history precedes the turn")
        XCTAssertEqual(bodies.first?["max_output_tokens"].int,8_192,"0.5 × pi's reserve for a turn prefix")
        XCTAssertTrue(prompts.first?.contains("Be concise. Focus on what's needed to understand the kept suffix.\n\nAdditional focus: Keep the history_read references") == true)
        XCTAssertTrue(prompts.first?.hasPrefix("<conversation>\n[User]: Inspect the reads.") == true)
        XCTAssertTrue(context.first?.text.contains("No prior history.\n\n---\n\n**Turn Context (split turn):**\n\nSUMMARY 1\n\n<read-files>\nf0\nf1\nf2\nf3\nf4\nf5\n</read-files>") == true,context.first?.text ?? "")
        await s.close()
    }

    func testHistoryTooLargeForOneRequestIsSummarizedInChainedChunks() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=PiSummaryClient(), s=try session(root,client,seed:tasks("C",30,chars:16_000),modelOutputLimit:100_000)
        _=try await compact(s)
        let prompts=await client.prompts, bodies=await client.bodies, context=await s.context
        XCTAssertGreaterThanOrEqual(prompts.count,2)
        XCTAssertTrue(bodies.allSatisfy { $0["max_output_tokens"].int == 13_107 })
        XCTAssertFalse(prompts[0].contains("<previous-summary>")); XCTAssertTrue(prompts[0].hasSuffix("Preserve exact file paths, function names, and error messages."))
        for n in 1..<prompts.count {
            XCTAssertTrue(prompts[n].contains("\n</conversation>\n\n<previous-summary>\nSUMMARY \(n)\n</previous-summary>\n\nThe messages above are NEW conversation messages"))
        }
        for n in 0..<25 { XCTAssertEqual(prompts.filter { $0.contains("[User]: C\(n) u") }.count,1,"C\(n) is summarized exactly once") }
        XCTAssertEqual(context.first?.text.hasSuffix("SUMMARY \(prompts.count)"),true)
        XCTAssertEqual(context.dropFirst().first?.id,"C25")
        await s.close()
    }

    func testSummaryMaxTokensFollowPiRule() throws {
        func profile(window: Int, limit: Int?, budget: Int = 4096) throws -> Profile {
            var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window); raw["maxOutputTokens"]=JSON(budget)
            if let limit { raw["modelOutputLimit"]=JSON(limit) }
            return try Profile(raw)
        }
        let policy=CompactionPolicy()
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:100_000)),13_107)
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:100_000),turnPrefix:true),8_192)
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:8_000)),8_000)
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:200_000,limit:nil)),4_096,"Without a declared ceiling, the configured budget")
        XCTAssertEqual(policy.summaryTokens(for:try profile(window:20_000,limit:100_000)),8_000,"A small window's reserve is half of it")
        XCTAssertEqual(policy.keepRecentTokens(contextWindow:200_000),20_000)
        XCTAssertEqual(policy.keepRecentTokens(contextWindow:32_768),8_192)
    }
}
