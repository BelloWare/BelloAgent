import XCTest
@testable import PiAgentCore

// What the model is given right after an automatic compaction. The owner,
// 2026-11-11: "when it's working, it got compaction, either right after I send
// the message, or after few runs, and then it stopped". A turn that is
// compacted must go on with the request it was given and the results it had
// just asked for, not with a summary alone.

/// Records every request body. A turn request gets the next scripted reply,
/// with usage that measures the request as a gateway would report it; a
/// summary request gets "SUMMARY n".
private actor FlowClient: ModelClient {
    var script: [ModelReply]
    var sent: [(purpose: String, body: JSON, cap: Int?)] = []
    init(_ script: [ModelReply]) { self.script = script }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,compaction:purpose == "compaction")
        sent.append((purpose,body,profile.wireOutputLimit))
        if purpose == "compaction" { return answer("SUMMARY \(sent.filter { $0.purpose == "compaction" }.count)") }
        guard !script.isEmpty else { throw AgentError("fixture_exhausted","Unexpected model request") }
        var reply=script.removeFirst()
        let input=RequestContextCounter.projectedTokens(body)
        reply.usage=["input":JSON(input),"output":10,"inputIncludingCache":JSON(input),"total":JSON(input+10)]
        return reply
    }
    var purposes: [String] { sent.map(\.purpose) }
    var summaryCap: Int? { sent.first { $0.purpose == "compaction" }?.cap }
    /// The turn request that followed the first summary request.
    var afterCompaction: JSON? {
        guard let index=sent.firstIndex(where: { $0.purpose == "compaction" }), index+1 < sent.count else { return nil }
        return sent[index+1].body
    }
}
/// Every call returns `chars` characters that name the call. A call named in
/// `gate` waits until `open()`.
private actor BulkTools: ToolExecuting {
    let chars: Int
    var gate: String?, waiting = false
    init(chars: Int, gate: String? = nil) { self.chars=chars; self.gate=gate }
    func open() { gate=nil }
    func definitions(readOnly:Bool)->[ToolDefinition] { [ToolDefinition("read","test",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON {
        while gate == call.id { waiting=true; try await Task.sleep(for:.milliseconds(5)) }
        return resultText("RESULT-\(call.id) "+String(repeating:"r",count:chars))
    }
}
/// A reply that asks for `count` reads at once, as models that read in parallel do.
private func reads(_ round: Int, _ count: Int = 1) -> ModelReply {
    let calls=(0..<count).map { ToolCall(id:"c\(round)-\($0)",name:"read",arguments:["path":JSON("f\(round)-\($0)")]) }
    var message=ChatMessage(role:"assistant",content:calls.map { ["type":"toolCall","id":JSON($0.id),"name":JSON($0.name),"arguments":$0.arguments] })
    message.providerItems=calls.map { ["type":"function_call","id":JSON("fc_"+$0.id),"call_id":JSON($0.id),"name":JSON($0.name),"arguments":JSON($0.arguments.encoded())] }
    return ModelReply(message:message,calls:calls,terminal:ModelTerminalOutcome(status:"completed"))
}
private func userTexts(_ body: JSON) -> [String] {
    body["input"].list.filter { $0["role"].text == "user" }.map { $0["content"].list.compactMap { $0["text"].text }.joined() }
}
private func outputs(_ body: JSON) -> [String] {
    body["input"].list.filter { $0["type"].text == "function_call_output" }.map { String(($0["output"].text ?? "").prefix(11)) }
}
private func user(_ id: String, _ text: String, root: String? = nil) -> ChatMessage {
    var message=ChatMessage(role:"user",content:[textBlock(text)]); message.id=id; message.taskRootID=root ?? id; return message
}
private func batch(_ id: String, results: Int, chars: Int, root: String) -> [ChatMessage] {
    var call=ChatMessage(role:"assistant",content:(0..<results).map { ["type":"toolCall","id":JSON("\(id)-\($0)"),"name":"read","arguments":[:]] })
    call.id=id; call.taskRootID=root
    return [call]+(0..<results).map { n in
        var result=ChatMessage(role:"toolResult",content:[textBlock(String(repeating:"r",count:chars))])
        result.id="\(id)-result-\(n)"; result.toolCallId="\(id)-\(n)"; result.toolName="read"; result.taskRootID=root
        return result
    }
}

final class CompactionFlowTests: HelperTestCase {
    private let task="OWNER-TASK: port the parser to the new grammar, keep the old entry point, and run every test."
    private func session(_ root: URL, _ client: FlowClient, tools: BulkTools, seed: [ChatMessage]? = nil, directory: URL? = nil, resumePath: String? = nil) throws -> AgentSession {
        try AgentSession(id:"flow",profile:fixtureProfile(),apiKey:"synthetic",cwd:root,directory:directory ?? root.appendingPathComponent("state"),readOnly:true,
                         resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),resumePath:resumePath,seed:seed)
    }
    private func finished(_ s: AgentSession, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        let state=await s.snapshot()
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? state["errorCode"].text ?? "",file:file,line:line)
    }

    /// Case 2, "after few runs": the round that crosses the threshold is
    /// usually a large one. Three parallel reads of 8,000 tokens each are
    /// more than the 20,000-token tail, and the whole context, with those
    /// results no request had carried yet, became the summary alone.
    func testMidTurnCompactionKeepsTheRequestAndTheResultsJustAskedFor() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<4).map { reads($0,3) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:32_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, sent=await client.afterCompaction, next=try XCTUnwrap(sent)
        XCTAssertEqual(purposes,["turn","turn","turn","compaction","turn","turn"],"The turn goes on to further requests after its compaction")
        XCTAssertTrue(userTexts(next).first?.hasPrefix(ProviderClient.compactionSummaryPrefix) == true)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task],"The owner's request is replayed as written, after the summary")
        XCTAssertEqual(outputs(next),["RESULT-c2-0","RESULT-c2-1","RESULT-c2-2"],"The results the last reply asked for reach the model")
        XCTAssertEqual(next["input"].list.last?["type"].text,"function_call_output","The request ends on the step in flight")
        await s.close()
    }

    /// Small rounds: the tail holds the newest rounds, and the request that
    /// started the turn, long since behind the cut, is still replayed.
    func testMidTurnCompactionReplaysTheOwnersRequestBehindTheCut() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<12).map { reads($0) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:32_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let sent=await client.afterCompaction, next=try XCTUnwrap(sent), context=await s.context
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task])
        XCTAssertEqual(outputs(next),["RESULT-c7-0","RESULT-c8-0"],"Pi's 20,000-token tail is unchanged")
        XCTAssertEqual(context.first { $0.kind == "compaction" }?.compaction?["protectedIDs"].list.compactMap(\.text),["task"])
        await s.close()
    }

    /// Case 1, "right after I send the message", while the agent works: the
    /// message is delivered at the tool boundary where the context compacts.
    /// The model was left with the summary and that message, without the task
    /// it interrupts or the results in flight.
    func testAMessageSentAtACompactionJoinsTheTaskAndItsResults() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<4).map { reads($0,3) }+[answer("All done.")]), tools=BulkTools(chars:32_000,gate:"c2-0")
        let s=try session(root,client,tools:tools)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await eventually { await tools.waiting }
        _=try await s.submit(Submission(commandID:"s",turnID:"steer",text:"OWNER-STEER: also update the changelog."),steer:true)
        await tools.open()
        try await finished(s)
        let sent=await client.afterCompaction, next=try XCTUnwrap(sent)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task,"OWNER-STEER: also update the changelog."])
        XCTAssertEqual(outputs(next),["RESULT-c2-0","RESULT-c2-1","RESULT-c2-2"])
        XCTAssertEqual(next["input"].list.last?["role"].text,"user","The new message is the last thing the model reads")
        await s.close()
    }

    /// Case 1 with the chat idle: the new message is kept, last, after the
    /// summary and the recent tail. (This held before the fix; it is pinned.)
    func testCompactionAtSendKeepsTheNewMessageLast() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let seed=(0..<10).flatMap { n -> [ChatMessage] in
            var reply=ChatMessage(role:"assistant",content:[textBlock("ANSWER-\(n) "+String(repeating:"a",count:20_000))]); reply.id="old\(n)-reply"; reply.taskRootID="old\(n)"
            return [user("old\(n)","OLD-\(n) "+String(repeating:"u",count:8_000)),reply]
        }
        let client=FlowClient([reads(0),answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:2_000),seed:seed)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, sent=await client.afterCompaction, next=try XCTUnwrap(sent)
        XCTAssertEqual(purposes,["compaction","turn","turn"])
        XCTAssertEqual(userTexts(next).last,task)
        XCTAssertEqual(next["input"].list.last?["role"].text,"user")
        XCTAssertFalse(userTexts(next).contains { $0.hasPrefix("OLD-0 ") },"Earlier tasks are summarized, not replayed")
        await s.close()
    }

    /// One round can add more than the 16,384 tokens the trigger leaves
    /// before the summary request stops fitting beside its full allowance.
    /// The compaction was then refused ("compaction_too_large") and the turn
    /// failed, at 85% of the window, with nothing sent.
    func testARoundLargerThanTheGrowthReserveStillCompacts() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<4).map { reads($0,3) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:37_400))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, allowed=await client.summaryCap, cap=try XCTUnwrap(allowed), sent=await client.afterCompaction, next=try XCTUnwrap(sent)
        XCTAssertEqual(purposes,["turn","turn","turn","compaction","turn","turn"])
        XCTAssertLessThan(cap,16_384,"The summary takes the room the intact context leaves")
        XCTAssertGreaterThanOrEqual(cap,CompactionPolicy().minimumSummaryTokens)
        XCTAssertEqual(outputs(next),["RESULT-c2-0","RESULT-c2-1","RESULT-c2-2"])
        await s.close()
    }

    /// A context within the smallest summary allowance of its window is
    /// still refused before anything is sent.
    func testAContextWithoutRoomForTheSmallestSummaryIsStillRefused() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient([])
        var reply=ChatMessage(role:"assistant",content:[textBlock(String(repeating:"a",count:372_000))]); reply.id="reply"; reply.taskRootID="first"
        let s=try session(root,client,tools:BulkTools(chars:1),seed:[user("first","First."),reply,user("second","Second.")])
        try await s.compact(); try await eventually { !(await s.isRunning) }
        let state=await s.snapshot(), sent=await client.purposes
        XCTAssertEqual(state["compaction"]["errorCode"].text,"compaction_too_large")
        XCTAssertEqual(sent,[])
        await s.close()
    }

    /// The checkpoint with its replayed request survives a reopen.
    func testReplayedRequestSurvivesReopen() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let directory=root.appendingPathComponent("state")
        let client=FlowClient((0..<4).map { reads($0,3) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:32_000),directory:directory)
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let before=await s.context.map(\.id), path=await s.path, saved=try XCTUnwrap(path); await s.close()
        let reopened=try session(root,FlowClient([]),tools:BulkTools(chars:1),directory:directory,resumePath:saved)
        let after=await reopened.context
        XCTAssertEqual(after.map(\.id),before)
        XCTAssertEqual(after.first?.kind,"compaction"); XCTAssertEqual(after.dropFirst().first?.text,task)
        await reopened.close()
    }

    // The planner's two rules, without a session.

    func testCutKeepsABatchNoReplyHasAnswered() throws {
        let body=try CompactionPlanner.groups([user("task","Do it.")]+batch("a",results:1,chars:8_000,root:"task")+batch("b",results:3,chars:40_000,root:"task"))
        XCTAssertEqual(CompactionPlanner.cut(body,keepRecentTokens:20_000),2,"The newest batch alone passes the target and is kept")
        var answered=ChatMessage(role:"assistant",content:[textBlock("Read them.")]); answered.id="done"
        let later=try CompactionPlanner.groups([user("task","Do it.")]+batch("b",results:3,chars:40_000,root:"task")+[answered,user("next","Next.")])
        XCTAssertEqual(CompactionPlanner.cut(later,keepRecentTokens:20_000),2,"A batch a reply has answered is cut as pi cuts it")
    }

    func testCurrentTaskInputsAreReplayedWithinTheirAllowance() throws {
        var mail=user("mail","Agent mail",root:"task"); mail.nativeAgentDelivery=["version":1]; mail.inputLane="agent"
        let work=batch("a",results:1,chars:400,root:"task")
        var context: [ChatMessage]=[user("old","Earlier task."),answer("Done.").message,user("task","Port the parser.")]
        context += work; context.append(user("steer","Keep the old entry point.",root:"task"))
        context += batch("b",results:1,chars:400,root:"task"); context.append(mail); context += batch("c",results:1,chars:400,root:"task")
        let source=try CompactionPlanner.source(context:context,taskRoot:"task",taskInputTokens:20_000)
        XCTAssertEqual(source.protectedIDs,["task","steer"],"The task's own inputs; not an earlier task's, not agent mail a reply has answered")
        let plan=CompactionPlanner.plan(source,cut:source.body.count)
        XCTAssertEqual(plan.keptMessages.map(\.id),["task","steer"])
        XCTAssertEqual(plan.summarized.count,context.count-2)
        // Newest first, within the allowance: a request too long for it is summarized as before.
        var long: [ChatMessage]=[user("task",String(repeating:"t",count:100_000))]
        long += work; long.append(user("steer","Keep the old entry point.",root:"task")); long += batch("b",results:1,chars:400,root:"task")
        XCTAssertEqual(try CompactionPlanner.source(context:long,taskRoot:"task",taskInputTokens:20_000).protectedIDs,["steer"])
        XCTAssertEqual(try CompactionPlanner.source(context:long,taskRoot:nil,taskInputTokens:20_000).protectedIDs,[])
        // A task a reply has ended is history: pi's rule, nothing replayed.
        XCTAssertEqual(try CompactionPlanner.source(context:context+[answer("All done.").message],taskRoot:"task",taskInputTokens:20_000).protectedIDs,[])
    }
}
