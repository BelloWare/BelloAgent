import XCTest
@testable import PiAgentCore

// What the model is given right after an automatic compaction, and what a
// compaction that cannot be made does to the turn. The owner, 2026-11-11:
// "when it's working, it got compaction, either right after I send the
// message, or after few runs, and then it stopped", and then: "remove the cap
// directly". A compaction keeps the task in hand whole and summarizes what
// came before it; one that fails leaves the turn to go on.
//
// These cases drive a session through its public surface only, so the same
// file runs against the planner it replaces (the failing-first record).

private enum Step {
    case reply(ModelReply)
    /// A reply whose reported usage counts `output` more tokens (reasoning).
    case heavy(ModelReply, output: Int)
    case fail(AgentError)
}
private enum Summary: Equatable {
    case text, cutAtItsCap
    /// A completed summary of exactly this many characters.
    case chars(Int)
}

/// Records every request body. A turn request gets the next scripted step,
/// with usage that measures the request as a gateway would report it; a
/// summary request gets "SUMMARY n", or a reply cut at its output cap.
private actor FlowClient: ModelClient {
    var script: [Step], summaries: [Summary]
    var sent: [(purpose: String, body: JSON, cap: Int?)] = []
    init(_ script: [Step], summaries: [Summary] = []) { self.script = script; self.summaries = summaries }
    init(replies: [ModelReply], summaries: [Summary] = []) { self.init(replies.map(Step.reply), summaries: summaries) }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,compaction:purpose == "compaction")
        sent.append((purpose,body,profile.wireOutputLimit))
        if purpose == "compaction" {
            let made=sent.filter { $0.purpose == "compaction" }.count
            let kind: Summary=summaries.isEmpty ? .text : summaries.removeFirst()
            if kind == .cutAtItsCap {
                return ModelReply(message:ChatMessage(role:"assistant",content:[textBlock("Partial")]),usage:["input":100,"output":JSON(profile.maxOutput)],truncated:true,
                                  terminal:ModelTerminalOutcome(status:"incomplete",incompleteReason:"max_output_tokens"))
            }
            if case .chars(let count)=kind { return answer(String(repeating:"s",count:count)) }
            return answer("SUMMARY \(made)")
        }
        guard !script.isEmpty else { throw AgentError("fixture_exhausted","Unexpected model request") }
        var reply: ModelReply, extra=0
        switch script.removeFirst() {
        case .reply(let value): reply=value
        case .heavy(let value, let output): reply=value; extra=output
        case .fail(let error): throw error
        }
        let input=RequestContextCounter.projectedTokens(body)
        reply.usage=["input":JSON(input),"output":JSON(10+extra),"inputIncludingCache":JSON(input),"total":JSON(input+10+extra)]
        return reply
    }
    var purposes: [String] { sent.map(\.purpose) }
    /// The turn requests that followed the `n`th summary request (from 0).
    func after(_ n: Int = 0) -> [JSON] {
        let marks=sent.indices.filter { sent[$0].purpose == "compaction" }
        guard n < marks.count else { return [] }
        let end=n+1 < marks.count ? marks[n+1] : sent.count
        return sent[(marks[n]+1)..<end].map(\.body)
    }
    var summaryCaps: [Int?] { sent.filter { $0.purpose == "compaction" }.map(\.cap) }
}
/// Every call returns `chars` characters that name the call. A call named in
/// `gate` waits until `open()`.
private actor BulkTools: ToolExecuting {
    let chars: Int, schema: Int, sizes: [String: Int]
    var gate: String?, waiting = false
    /// The calls made, in order: a call is made once.
    var invoked: [String] = []
    /// `schema`: characters of tool description, for a chat whose tool schemas are large.
    /// `sizes`: the characters a named call returns instead of `chars`.
    init(chars: Int, gate: String? = nil, schema: Int = 0, sizes: [String: Int] = [:]) { self.chars=chars; self.gate=gate; self.schema=schema; self.sizes=sizes }
    func open() { gate=nil }
    func definitions(readOnly:Bool)->[ToolDefinition] { [ToolDefinition("read","test"+String(repeating:"d",count:schema),[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON {
        while gate == call.id { waiting=true; try await Task.sleep(for:.milliseconds(5)) }
        invoked.append(call.id)
        return resultText("RESULT-\(call.id) "+String(repeating:"r",count:sizes[call.id] ?? chars))
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
    body["input"].list.filter { $0["type"].text == "function_call_output" }.map { String(($0["output"].text ?? "").split(separator:" ").first ?? "") }
}
private func replies(_ body: JSON) -> [String] {
    body["input"].list.filter { $0["type"].text == "message" && $0["role"].text == "assistant" }.map { $0["content"].list.compactMap { $0["text"].text }.joined() }
}
private func user(_ id: String, _ text: String, root: String? = nil) -> ChatMessage {
    var message=ChatMessage(role:"user",content:[textBlock(text)]); message.id=id; message.taskRootID=root ?? id; return message
}
private func reply(_ id: String, _ text: String, root: String) -> ChatMessage {
    var message=ChatMessage(role:"assistant",content:[textBlock(text)]); message.id=id; message.taskRootID=root; return message
}
/// Finished tasks of about 10,000 tokens each: a question, then its answer.
private func earlier(_ count: Int) -> [ChatMessage] {
    (0..<count).flatMap { n in [user("old\(n)","OLD-\(n) "+String(repeating:"u",count:8_000)),reply("old\(n)-reply","ANSWER-\(n) "+String(repeating:"a",count:32_000),root:"old\(n)")] }
}
/// The `index`th element, or a recorded failure where a run sent fewer requests.
private func item<T>(_ values: [T], _ index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(values.indices.contains(index) ? values[index] : nil,"Only \(values.count) were sent",file:file,line:line)
}
private let continuation="The task was in progress when this checkpoint was made."

final class CompactionFlowTests: HelperTestCase {
    private let task="OWNER-TASK: port the parser to the new grammar, keep the old entry point, and run every test."
    private func session(_ root: URL, _ client: FlowClient, tools: BulkTools, window: Int = 100_000, seed: [ChatMessage]? = nil, resumePath: String? = nil,
                         beforeJournalAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }) throws -> AgentSession {
        var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window)
        return try AgentSession(id:"flow",profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),resumePath:resumePath,seed:seed,beforeJournalAppend:beforeJournalAppend)
    }
    private func settled(_ s: AgentSession) async throws -> JSON {
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        return await s.snapshot()
    }
    private func finished(_ s: AgentSession, file: StaticString = #filePath, line: UInt = #line) async throws {
        let state=try await settled(s)
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? state["errorCode"].text ?? "",file:file,line:line)
    }

    // MARK: what stays (change 1)

    /// "After few runs": five rounds of 12,000 tokens are three times the old
    /// 20,000-token tail. The task stays whole; the earlier tasks are the summary.
    func testAWorkingTaskStaysWholeHoweverLarge() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<6).map { reads($0,3) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:16_000),window:200_000,seed:earlier(10))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, following=await client.after(), next=try XCTUnwrap(following.first)
        XCTAssertEqual(purposes,["turn","turn","turn","turn","turn","compaction","turn","turn"],"One compaction, once less than the growth reserve is left; the turn goes on")
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task],"The owner's request, as written; no earlier task")
        XCTAssertEqual(outputs(next),(0..<5).flatMap { round in (0..<3).map { "RESULT-c\(round)-\($0)" } },"Every round of the task, 60,000 tokens of results")
        XCTAssertEqual(next["input"].list.last?["type"].text,"function_call_output","The request ends on the step in flight")
        await s.close()
    }

    /// "Right after I send the message", while the agent works: steering joins
    /// the task it steers. It neither starts another task nor cuts the first.
    func testSteeringJoinsTheTaskItSteers() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<6).map { reads($0,3) }+[answer("All done.")]), tools=BulkTools(chars:16_000,gate:"c4-0")
        let s=try session(root,client,tools:tools,window:200_000,seed:earlier(10))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await eventually { await tools.waiting }
        _=try await s.submit(Submission(commandID:"s",turnID:"steer",text:"OWNER-STEER: also update the changelog."),steer:true)
        await tools.open()
        try await finished(s)
        let following=await client.after(), next=try XCTUnwrap(following.first)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task,"OWNER-STEER: also update the changelog."])
        XCTAssertEqual(outputs(next).count,15,"The steered task keeps every round")
        XCTAssertEqual(next["input"].list.last?["role"].text,"user","The new message is the last thing the model reads")
        await s.close()
    }

    /// At send, with the chat idle. "Yes, do the second one" refers to the
    /// reply before it: that exchange stays as written, without its tool
    /// rounds. And the compaction lands before the work: at 70% of the
    /// usable input, where the working threshold would let the task start
    /// and compact it a round or two in.
    func testAtSendTheLastExchangeStaysAndCompactionComesFirst() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var call=reads(0).message; call.id="prev-call"; call.taskRootID="prev"
        var result=ChatMessage(role:"toolResult",content:[textBlock("RESULT-prev "+String(repeating:"r",count:120_000))])
        result.id="prev-result"; result.toolCallId="c0-0"; result.toolName="read"; result.taskRootID="prev"
        let seed=earlier(10)+[user("prev","PREV-TASK: give me two ways to fix the cache."),call,result,reply("prev-reply","OPTIONS: 1) invalidate on write 2) version the keys",root:"prev")]
        let client=FlowClient(replies:[reads(1),answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:2_000),window:200_000,seed:seed)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:"yes, do the second one"),steer:false)
        try await finished(s)
        let purposes=await client.purposes, following=await client.after(), next=try XCTUnwrap(following.first)
        XCTAssertEqual(purposes,["compaction","turn","turn"])
        XCTAssertEqual(Array(userTexts(next).dropFirst()),["PREV-TASK: give me two ways to fix the cache.","yes, do the second one"])
        XCTAssertEqual(replies(next),["OPTIONS: 1) invalidate on write 2) version the keys"],"The reply the message answers")
        XCTAssertEqual(outputs(next),[],"Not the earlier task's tool rounds")
        XCTAssertEqual(next["input"].list.last?["role"].text,"user")
        XCTAssertFalse(userTexts(next).first?.contains(continuation) ?? true,"Nothing was in progress")
        await s.close()
    }

    /// After a gateway's context rejection the same things are required: the
    /// request and the results in flight are in the retried request.
    func testOverflowRecoveryKeepsTheRequestAndTheResultsInFlight() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
        let client=FlowClient([.reply(reads(0,3)),.fail(rejected),.reply(answer("All done."))])
        let s=try session(root,client,tools:BulkTools(chars:32_000),window:200_000,seed:earlier(5))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, following=await client.after(), next=try XCTUnwrap(following.first)
        XCTAssertEqual(purposes,["turn","turn","compaction","turn"])
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task])
        XCTAssertEqual(outputs(next),["RESULT-c0-0","RESULT-c0-1","RESULT-c0-2"])
        await s.close()
    }

    // MARK: the fallback and the thresholds (change 2)

    /// A task too large to keep whole keeps its request, the batch in flight
    /// and its newest rounds towards 30% of the usable input; what replaces
    /// the context is at most half of it, so the next compaction is rounds
    /// away, and the task compacts again when those rounds have come.
    func testATaskTooLargeKeepsItsNewestRoundsAndCompactsAgainLater() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<22).map { reads($0) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:22_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, first=await client.after(0), second=await client.after(1)
        XCTAssertEqual(purposes.filter { $0 == "compaction" }.count,2)
        XCTAssertEqual(purposes.firstIndex(of:"compaction"),12,"Twelve rounds reach the working threshold")
        let next=try XCTUnwrap(first.first), again=try XCTUnwrap(second.first)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task])
        XCTAssertEqual(outputs(next),(8..<12).map { "RESULT-c\($0)-0" },"Four rounds, 22,000 tokens, are within 30%; a fifth is not")
        XCTAssertEqual(first.count,8,"Eight more rounds before the next compaction")
        XCTAssertEqual(Array(userTexts(again).dropFirst()),[task],"The request is still replayed after the second")
        XCTAssertEqual(outputs(again),(16..<20).map { "RESULT-c\($0)-0" })
        // Half the usable input of a 100,000-token window, whatever the instruction measures.
        for body in [next,again] { XCTAssertLessThanOrEqual(RequestContextCounter.projectedTokens(body),(100_000-1_000-16_384)/2) }
        await s.close()
    }

    /// Nothing but the request and the batch in flight: there is nothing to
    /// summarize without dropping what the next request must answer, so
    /// nothing is summarized and the intact request goes.
    func testRequiredMaterialIsNeverSummarizedToMakeRoom() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:[reads(0,3),answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:96_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes, sent=await client.sent
        XCTAssertEqual(purposes,["turn","turn"],"No summary request")
        XCTAssertEqual(outputs(try item(sent,1).body),["RESULT-c0-0","RESULT-c0-1","RESULT-c0-2"])
        await s.close()
    }

    // MARK: a compaction that fails (change 3)

    /// A summary cut at its cap is not adopted, and that is all: the turn
    /// goes on from its intact context, no second summary is asked for this
    /// task, and the message queued behind it is answered. The next task
    /// may compact again.
    func testAFailedCompactionLeavesTheTurnToGoOnAndIsNotTriedAgainForTheTask() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:[reads(0,3),reads(1,3),reads(2,3),reads(3,1),answer("All done."),answer("Next done.")],summaries:[.cutAtItsCap])
        let s=try session(root,client,tools:BulkTools(chars:32_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        _=try await s.submit(Submission(commandID:"n",turnID:"next",text:"OWNER-NEXT: now the docs."),steer:false)
        try await finished(s)
        let purposes=await client.purposes, sent=await client.sent, context=await s.context
        XCTAssertEqual(purposes,["turn","turn","turn","compaction","turn","turn","compaction","turn"],"One failed attempt for the task; the next task compacts at its start")
        XCTAssertEqual(outputs(try item(sent,4).body).count,9,"The request after the failure is the intact one")
        XCTAssertEqual(outputs(try item(sent,5).body).count,10,"Above the threshold again, and no second attempt")
        XCTAssertEqual(context.first?.kind,"compaction"); XCTAssertTrue(context.first?.text.hasSuffix("SUMMARY 2") == true)
        XCTAssertEqual(userTexts(try item(sent,7).body).last,"OWNER-NEXT: now the docs.")
        await s.close()
    }

    /// The task's one failed attempt is remembered across a Retry and a
    /// reopen, and a real overflow then pauses the chat instead of asking
    /// for another summary that would fail the same way.
    func testTheFailedAttemptIsRememberedAcrossRetryAndReopen() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let refused=AgentError("provider_http","HTTP 400 invalid request")
        let client=FlowClient([.reply(reads(0,3)),.reply(reads(1,3)),.reply(reads(2,3)),.fail(refused)],summaries:[.cutAtItsCap])
        let s=try session(root,client,tools:BulkTools(chars:32_000))
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let stopped=try await settled(s), purposes=await client.purposes, path=await s.path, saved=try XCTUnwrap(path)
        XCTAssertEqual(stopped["state"].text,"error"); XCTAssertEqual(purposes,["turn","turn","turn","compaction","turn"],"The turn went on to the request that failed for its own reason")
        await s.close()
        let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
        let later=FlowClient([.reply(reads(3,1)),.fail(rejected)])
        let reopened=try session(root,later,tools:BulkTools(chars:32_000),resumePath:saved)
        try await reopened.retryRun()
        let end=try await settled(reopened), asked=await later.purposes
        XCTAssertEqual(asked,["turn","turn"],"No summary request after the reopen: not at the threshold, not for the overflow")
        XCTAssertEqual(end["state"].text,"error")
        await reopened.close()
    }

    /// What is not a compaction's ordinary failure still stops the run: a
    /// journal that refuses the checkpoint is never taken for a bad summary.
    func testAJournalThatRefusesTheCheckpointStillStopsTheRun() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<22).map { reads($0) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:22_000),beforeJournalAppend:{ if $0["type"].text == "compaction" { throw AgentError("fixture_disk","The disk refused the write") } })
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, context=await s.context
        XCTAssertEqual(state["state"].text,"error"); XCTAssertEqual(purposes.last,"compaction","Nothing was asked of the model after the failed write")
        XCTAssertNil(context.first?.kind)
        await s.close()
    }

    // MARK: the summary's room (change 4)

    /// A reply with long reasoning passes the growth reserve: the summary
    /// takes the room that is left, and the checkpoint records that
    /// allowance, not the nominal one.
    func testASummaryTakesTheRoomLeftAndRecordsIt() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<10).map { Step.reply(reads($0)) }+[.heavy(reads(10),output:24_000),.reply(answer("All done."))])
        let s=try session(root,client,tools:BulkTools(chars:22_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let caps=await client.summaryCaps, context=await s.context, cap=try XCTUnwrap(caps.first ?? nil)
        XCTAssertEqual(caps.count,1)
        XCTAssertLessThan(cap,16_384); XCTAssertGreaterThanOrEqual(cap,8_192)
        XCTAssertEqual(context.first?.compaction?["outputAllowance"].int,cap); XCTAssertEqual(context.first?.compaction?["wireCap"].int,cap)
        XCTAssertEqual(context.first?.compaction?["lastAttempt"]["cap"].int,cap)
        await s.close()
    }

    /// Less than the smallest allowance is left: no summary is sent, and
    /// that no longer fails a turn whose own request still fits.
    func testNoRoomForTheSmallestSummarySendsNoneAndTheTurnGoesOn() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient((0..<10).map { Step.reply(reads($0)) }+[.heavy(reads(10),output:31_000),.reply(answer("All done."))])
        let s=try session(root,client,tools:BulkTools(chars:22_000))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let purposes=await client.purposes
        XCTAssertEqual(purposes,Array(repeating:"turn",count:12))
        await s.close()
    }

    // MARK: the framing (change 5)

    /// A checkpoint made while its task worked says so, inside its own input
    /// item: the same bytes on every later request and after a reopen, and
    /// counted before it was adopted.
    func testAMidTaskCheckpointCarriesItsFramingInItsOwnItem() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<14).map { reads($0) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:22_000))
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await finished(s)
        let following=await client.after(), context=await s.context, path=await s.path, saved=try XCTUnwrap(path)
        XCTAssertEqual(following.count,3)
        let first=try item(following,0), checkpoint=try item(first["input"].list,1), text=checkpoint["content"].list.first?["text"].text ?? ""
        XCTAssertTrue(text.hasPrefix(ProviderClient.compactionSummaryPrefix+"SUMMARY 1"+ProviderClient.compactionSummarySuffix),String(text.prefix(160)))
        XCTAssertTrue(text.hasSuffix("</summary>\n\n"+continuation+" Continue from the retained request and latest results without asking the owner to repeat them, and without redoing work the summary records as done."),String(text.suffix(200)))
        for body in following.dropFirst() { XCTAssertEqual(try item(body["input"].list,1),checkpoint,"The checkpoint item never changes") }
        XCTAssertEqual(context.first?.compaction?["after"]["requestTokens"].int,RequestContextCounter.projectedTokens(first),"Counted with its framing")
        await s.close()
        let reopened=try session(root,FlowClient([]),tools:BulkTools(chars:1),resumePath:saved)
        let restored=await reopened.context
        XCTAssertEqual(try ProviderClient.responsesInput(Array(restored.prefix(1)),instructions:"",profile:fixtureProfile()).first,checkpoint,"The same item from the journal")
        await reopened.close()
    }
}

/// What Astra's review of the redesign found (2026-11-11), each as the owner
/// would meet it.
final class CompactionReviewTests: HelperTestCase {
    private let task="OWNER-TASK: port the parser to the new grammar, keep the old entry point, and run every test."
    private func session(_ root: URL, _ client: FlowClient, tools: BulkTools, window: Int = 100_000, seed: [ChatMessage]? = nil, resumePath: String? = nil,
                         beforeJournalAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }) throws -> AgentSession {
        var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window)
        return try AgentSession(id:"review",profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),resumePath:resumePath,seed:seed,beforeJournalAppend:beforeJournalAppend)
    }
    private func settled(_ s: AgentSession) async throws -> JSON {
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        return await s.snapshot()
    }

    /// A 32,768-token window: the summary's allowance is a third of the
    /// usable input, so filling the kept rounds towards 30% of it can never
    /// fit half of it. The optional rounds give way; what the next request
    /// must answer stays, and the task compacts instead of being written off.
    func testASmallWindowCompactsWithWhatItMustKeep() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:(0..<6).map { reads($0) }+[answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:7_000),window:32_768,seed:earlier(1))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, following=await client.after(), context=await s.context, held=await s.suppressedCompactionTask
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
        XCTAssertEqual(purposes.filter { $0 == "compaction" }.count,1,"The compaction is made: \(purposes)")
        XCTAssertNil(held,"and the task is not written off")
        XCTAssertEqual(context.first?.kind,"compaction")
        let next=try item(following,0)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task]); XCTAssertEqual(outputs(next).last,"RESULT-c4-0","The batch awaiting its reply")
        XCTAssertLessThanOrEqual(RequestContextCounter.projectedTokens(next),(32_768-327-8_192)/2)
        await s.close()
    }

    /// A request and a batch in flight that are more than half the usable
    /// input of a small window, whatever the summary: nothing can be
    /// compacted without cutting one of them. 0.1.136 cut the request (and
    /// its first build failed the turn); now the turn goes on as it is.
    func testATaskTooLargeForAnyReplacementGoesOnUncompacted() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let long="OWNER-TASK: "+String(repeating:"t",count:32_000)
        let client=FlowClient(replies:[reads(0),reads(1),answer("All done.")])
        let s=try session(root,client,tools:BulkTools(chars:24_000),window:32_768)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:long),steer:false)
        let state=try await settled(s), purposes=await client.purposes, sent=await client.sent, held=await s.suppressedCompactionTask
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
        XCTAssertEqual(purposes,["turn","turn","turn"],"No summary is asked for, and the turn is not stopped")
        let last=try item(sent,2).body
        XCTAssertEqual(userTexts(last),[long],"The request as written"); XCTAssertEqual(outputs(last),["RESULT-c0-0","RESULT-c1-0"],"and both batches")
        // A plan that could not be made cost nothing: it is not a failed attempt, and nothing is written off.
        let fingerprint=await s.failedCompactionFingerprint, path=await s.path, journal=try String(contentsOfFile:try XCTUnwrap(path),encoding:.utf8)
        XCTAssertNil(held); XCTAssertNil(fingerprint); XCTAssertFalse(journal.contains(JournalRecordKind.compactionFailure),"No failure record")
        await s.close()
    }

    /// The record that ends a task's automatic attempts is a journal write
    /// like any other: when it cannot be saved the run stops there, before
    /// another request is paid for on a journal that refuses writes.
    func testASuppressionThatCannotBeSavedStopsTheRunBeforeAnotherRequest() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:[reads(0,3),reads(1,3),reads(2,3),reads(3,1),answer("All done.")],summaries:[.cutAtItsCap])
        let s=try session(root,client,tools:BulkTools(chars:32_000),beforeJournalAppend:{
            if $0["customType"].text == "pi-app.compaction-failure.v1", !$0["data"]["taskRootId"].isNull { throw AgentError("fixture_disk","The disk refused the write") }
        })
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, held=await s.suppressedCompactionTask
        XCTAssertEqual(purposes,["turn","turn","turn","compaction"],"Nothing is asked of the model after the write that failed")
        XCTAssertEqual(state["state"].text,"error"); XCTAssertEqual(state["errorCode"].text,"fixture_disk")
        XCTAssertNil(held,"Nothing is published in memory that the journal does not hold")
        await s.close()
    }

    /// A chat from before task metadata (every chat the owner has, at its
    /// first compaction after upgrading): there is no task to cut by, so the
    /// surviving body is kept from its newest rows back, and the latest
    /// request stays with its reply, compacted by hand or at send.
    func testALegacyChatKeepsItsLatestRequestAndReply() async throws {
        func legacy() -> [ChatMessage] {
            var rows=(0..<6).flatMap { n in [ChatMessage(role:"user",content:[textBlock("LEGACY-\(n) "+String(repeating:"u",count:8_000))]),
                                             ChatMessage(role:"assistant",content:[textBlock("ANSWER-\(n) "+String(repeating:"a",count:32_000))])] }
            rows += [ChatMessage(role:"user",content:[textBlock("LEGACY-LAST: give me two ways to fix the cache.")]),
                     ChatMessage(role:"assistant",content:[textBlock("OPTIONS: 1) invalidate on write 2) version the keys")])]
            return rows
        }
        for manual in [true,false] {
            let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
            let client=FlowClient(replies:[answer("Done.")])
            let s=try session(root,client,tools:BulkTools(chars:1),seed:legacy())
            if manual { try await s.compact(); _=try await settled(s) }
            _=try await s.submit(Submission(commandID:"c",turnID:"task",text:"yes, do the second one"),steer:false)
            let state=try await settled(s), purposes=await client.purposes, sent=await client.sent
            XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
            XCTAssertEqual(purposes,["compaction","turn"],manual ? "by hand" : "at send")
            let next=try item(sent,1).body, texts=userTexts(next)
            XCTAssertTrue(texts.first?.hasPrefix(ProviderClient.compactionSummaryPrefix) == true)
            XCTAssertTrue(texts.contains("LEGACY-LAST: give me two ways to fix the cache."),"The latest request stays (\(manual ? "by hand" : "at send")): \(texts.map { String($0.prefix(24)) })")
            XCTAssertEqual(replies(next).last,"OPTIONS: 1) invalidate on write 2) version the keys","with its reply")
            XCTAssertEqual(texts.last,"yes, do the second one")
            XCTAssertFalse(texts.contains { $0.hasPrefix("LEGACY-0 ") },"The oldest rows are the summary")
            await s.close()
        }
    }

    /// A side chat not saved yet has no journal for the failure record. Kept,
    /// its first journal carries it: reopened from that journal alone, the
    /// task's Resume does not ask for a second summary.
    func testAFailedAttemptInAnUnsavedSideIsRememberedOnceItIsKept() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let refused=AgentError("provider_http","HTTP 400 invalid request")
        let client=FlowClient([.reply(reads(0,3)),.reply(reads(1,3)),.reply(reads(2,3)),.fail(refused)],summaries:[.cutAtItsCap])
        let s=try session(root,client,tools:BulkTools(chars:32_000),seed:earlier(1))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let stopped=try await settled(s), purposes=await client.purposes, unsaved=await s.path
        XCTAssertEqual(stopped["state"].text,"error"); XCTAssertEqual(purposes,["turn","turn","turn","compaction","turn"]); XCTAssertNil(unsaved,"Not saved yet")
        _=try await s.keep(whenFinished:false)
        let path=await s.path, saved=try XCTUnwrap(path); await s.close()
        // From the journal alone: no metadata file to carry the field.
        JournalCheckpoint.remove(for:URL(fileURLWithPath:saved))
        let later=FlowClient(replies:[reads(3,1),answer("All done.")])
        let reopened=try session(root,later,tools:BulkTools(chars:32_000),resumePath:saved)
        let held=await reopened.suppressedCompactionTask
        XCTAssertEqual(held,"task")
        try await reopened.retryRun()
        let end=try await settled(reopened), asked=await later.purposes
        XCTAssertEqual(asked,["turn","turn"],"No second summary for the task")
        XCTAssertEqual(end["state"].text,"idle",end["errorMessage"].text ?? "")
        await reopened.close()
    }
}

/// A plan that cannot be made costs nothing and is tried again when the chat
/// changes; a summary that was paid for and not adopted ends the task's
/// automatic attempts (Astra's ruling, 2026-11-11). The case behind it, in a
/// 128,000-token window: a batch of 60,000 tokens in flight when the working
/// threshold is crossed. Nothing can be planned around it; one small round
/// later a plan fits easily, and writing the task off at the first refusal
/// stopped the chat at an overflow it could have compacted away.
final class CompactionRefusalTests: HelperTestCase {
    private let task="OWNER-TASK: port the parser to the new grammar, keep the old entry point, and run every test."
    /// Four results of 15,000 tokens, each under the 65,536 bytes a tool's
    /// result may be before the session cuts it: 60,000 tokens in flight.
    private let large=["c0-0":60_000,"c0-1":60_000,"c0-2":60_000,"c0-3":60_000]
    private func profile() throws -> Profile { var raw=try fixtureProfile().raw; raw["contextWindow"]=128_000; return try Profile(raw) }
    private func session(_ root: URL, _ client: FlowClient, tools: BulkTools, window: Int = 128_000, seed: [ChatMessage]? = nil) throws -> AgentSession {
        var raw=try fixtureProfile().raw; raw["contextWindow"]=JSON(window)
        return try AgentSession(id:"refusal",profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:tools,traces:TraceStore(),seed:seed)
    }
    private func settled(_ s: AgentSession) async throws -> JSON {
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        return await s.snapshot()
    }
    private func attempts(_ s: AgentSession) async -> Int { await s.history.filter { $0.kind == "execution" && ($0.detail ?? "").hasPrefix("Compaction") }.count }
    /// Half the usable input, from the instruction a summary request carried.
    private func half(_ request: JSON) throws -> Int {
        let policy=CompactionPolicy(), instruction=try XCTUnwrap(request["input"].list.last)
        return policy.share(try policy.usable(profile:profile(),instructionTokens:RequestContextCounter.inputTokens([instruction])),policy.replacementShare)
    }

    /// At the threshold: refused with the large batch in flight, planned
    /// again one small round later, and compacted then.
    func testAPlanThatCouldNotBeMadeIsMadeWhenTheChatChanges() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient(replies:[reads(0,4),reads(1),answer("All done.")]), tools=BulkTools(chars:4_000,sizes:large)
        let s=try session(root,client,tools:tools,seed:earlier(4))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, following=await client.after(), held=await s.suppressedCompactionTask, fingerprint=await s.failedCompactionFingerprint
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
        XCTAssertEqual(purposes,["turn","turn","compaction","turn"],"No summary with the large batch in flight; one as soon as a plan fits")
        XCTAssertNil(held); XCTAssertNil(fingerprint)
        let next=try item(following,0)
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task]); XCTAssertEqual(outputs(next),["RESULT-c1-0"],"The small batch in flight stays; the large one, answered, is the summary")
        XCTAssertLessThanOrEqual(RequestContextCounter.projectedTokens(next),(128_000-1_024-16_384)/2)
        await s.close()
    }

    /// At an overflow: the ordinary plan cannot be made, and recovery keeps
    /// exactly what it must (the request and the batch in flight) though that
    /// is more than half the usable input, because it fits a normal request
    /// beside the whole summary allowance. No tool runs twice.
    func testAnOverflowRecoversWithWhatMustStayAboveTheHalf() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
        let client=FlowClient([.reply(reads(0,4)),.fail(rejected),.reply(answer("All done."))]), tools=BulkTools(chars:4_000,sizes:large)
        let s=try session(root,client,tools:tools,seed:earlier(4))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, sent=await client.sent, context=await s.context, invoked=await tools.invoked, held=await s.suppressedCompactionTask
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
        XCTAssertEqual(purposes,["turn","turn","compaction","turn"],"Refused at the threshold, rejected by the gateway, recovered")
        XCTAssertEqual(context.first?.kind,"compaction"); XCTAssertEqual(context.first?.compaction?["reason"].text,"context-rejection"); XCTAssertNil(held)
        let request=try XCTUnwrap(sent.first { $0.purpose == "compaction" }?.body), after=try XCTUnwrap(context.first?.compaction?["after"]["requestTokens"].int)
        XCTAssertGreaterThan(after,try half(request),"Adopted above the half: recovery's own acceptance")
        let next=try item(sent,3).body
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task]); XCTAssertEqual(outputs(next),["RESULT-c0-0","RESULT-c0-1","RESULT-c0-2","RESULT-c0-3"],"Nothing that must stay is dropped")
        XCTAssertEqual(invoked.sorted(),["c0-0","c0-1","c0-2","c0-3"],"and no tool ran again")
        await s.close()
    }

    /// The same refusal is not planned twice for the same chat; a change of
    /// the chat plans again; an overflow asks afresh, because recovery admits
    /// what the threshold could not.
    func testARefusalIsRememberedForTheSameChatOnlyAndAnOverflowAsksAfresh() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var call=reads(0,3).message; call.id="batch"; call.taskRootID="task"
        let results=(0..<3).map { n -> ChatMessage in
            var result=ChatMessage(role:"toolResult",content:[textBlock("RESULT-c0-\(n) "+String(repeating:"r",count:80_000))])
            result.id="batch-result-\(n)"; result.toolCallId="c0-\(n)"; result.toolName="read"; result.taskRootID="task"; return result
        }
        let client=FlowClient([])
        let s=try session(root,client,tools:BulkTools(chars:1),seed:earlier(4)+[user("task",task),call]+results)
        var planned=try await s.automaticCompaction(reason:"threshold"); var rows=await attempts(s)
        XCTAssertFalse(planned); XCTAssertEqual(rows,1)
        planned=try await s.automaticCompaction(reason:"threshold"); rows=await attempts(s)
        XCTAssertFalse(planned); XCTAssertEqual(rows,1,"Identical inputs: the refusal is reused, with no new operation row")
        try await s.append(user("steer","OWNER-STEER: and the changelog.",root:"task"))
        planned=try await s.automaticCompaction(reason:"threshold"); rows=await attempts(s)
        XCTAssertFalse(planned); XCTAssertEqual(rows,2,"The chat changed: planned again")
        var held=await s.suppressedCompactionTask, fingerprint=await s.failedCompactionFingerprint, asked=await client.purposes
        XCTAssertNil(held); XCTAssertNil(fingerprint); XCTAssertEqual(asked,[],"Three refusals, nothing spent, nothing written off")
        planned=try await s.automaticCompaction(reason:"context-rejection"); rows=await attempts(s)
        held=await s.suppressedCompactionTask; asked=await client.purposes
        let context=await s.context
        XCTAssertTrue(planned,"Recovery admits the required rows"); XCTAssertEqual(rows,3); XCTAssertEqual(asked,["compaction"]); XCTAssertNil(held)
        XCTAssertEqual(context.dropFirst().map(\.id),["task","batch","batch-result-0","batch-result-1","batch-result-2","steer"])
        await s.close()
    }

    /// The same case at an overflow: refused with the large batch in flight,
    /// then, the small batch after it in flight, a context rejection is
    /// recovered by the ordinary plan, under the half.
    func testAnOverflowAfterARefusalIsRecoveredOnceTheLargeBatchIsAnswered() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        func batch(_ round: Int, _ count: Int, chars: Int) -> [ChatMessage] {
            var call=reads(round,count).message; call.id="batch\(round)"; call.taskRootID="task"
            return [call]+(0..<count).map { n -> ChatMessage in
                var result=ChatMessage(role:"toolResult",content:[textBlock("RESULT-c\(round)-\(n) "+String(repeating:"r",count:chars))])
                result.id="batch\(round)-result-\(n)"; result.toolCallId="c\(round)-\(n)"; result.toolName="read"; result.taskRootID="task"; return result
            }
        }
        let client=FlowClient([])
        let s=try session(root,client,tools:BulkTools(chars:1),seed:earlier(4)+[user("task",task)]+batch(0,3,chars:80_000))
        var planned=try await s.automaticCompaction(reason:"threshold")
        XCTAssertFalse(planned,"60,000 tokens in flight: no plan")
        for message in batch(1,1,chars:4_000) { try await s.append(message) }
        planned=try await s.automaticCompaction(reason:"context-rejection")
        let asked=await client.purposes, sent=await client.sent, context=await s.context, held=await s.suppressedCompactionTask
        XCTAssertTrue(planned); XCTAssertEqual(asked,["compaction"]); XCTAssertNil(held)
        XCTAssertEqual(context.dropFirst().map(\.id),["task","batch1","batch1-result-0"],"The request and the batch in flight; the large batch is the summary")
        let request=try XCTUnwrap(sent.first?.body), after=try XCTUnwrap(context.first?.compaction?["after"]["requestTokens"].int)
        XCTAssertLessThanOrEqual(after,try half(request),"The ordinary plan, within the half")
        await s.close()
    }

    /// One paid summary between two replies of the model. What can add to a
    /// chat without a reply is the owner's steering and agent mail: here a
    /// threshold compaction, then 30,000 tokens of steering, then a context
    /// rejection. A second summary could be planned, and is not sent; steering
    /// does not clear that, the model's next reply does.
    func testNoSecondSummaryIsPaidForUntilTheModelReplies() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let rounds=(0..<8).flatMap { n -> [ChatMessage] in
            var call=reads(n).message; call.id="call\(n)"; call.taskRootID="task"
            var result=ChatMessage(role:"toolResult",content:[textBlock("RESULT-c\(n)-0 "+String(repeating:"r",count:32_000))])
            result.id="result\(n)"; result.toolCallId="c\(n)-0"; result.toolName="read"; result.taskRootID="task"; return [call,result]
        }
        let client=FlowClient(replies:[answer("Noted.")])
        let s=try session(root,client,tools:BulkTools(chars:1),seed:earlier(4)+[user("task",task)]+rounds)
        var adopted=try await s.automaticCompaction(reason:"threshold"), asked=await client.purposes
        XCTAssertTrue(adopted); XCTAssertEqual(asked,["compaction"])
        try await s.append(user("steer","OWNER-STEER: "+String(repeating:"s",count:120_000),root:"task"))
        adopted=try await s.automaticCompaction(reason:"context-rejection"); asked=await client.purposes
        var held=await s.suppressedCompactionTask, rows=await attempts(s)
        XCTAssertFalse(adopted); XCTAssertEqual(asked,["compaction"],"Steering is not a reply: no second summary"); XCTAssertNil(held); XCTAssertEqual(rows,1,"and no attempt is shown")
        adopted=try await s.automaticCompaction(reason:"threshold"); asked=await client.purposes
        XCTAssertFalse(adopted); XCTAssertEqual(asked,["compaction"],"at a threshold either")
        _=try await s.submit(Submission(commandID:"n",turnID:"next",text:"And the changelog."),steer:false)
        _=try await settled(s); asked=await client.purposes
        XCTAssertEqual(asked,["compaction","turn"],"The request goes as it is")
        _=try await s.automaticCompaction(reason:"threshold"); asked=await client.purposes; held=await s.suppressedCompactionTask
        XCTAssertEqual(asked,["compaction","turn","compaction"],"The model replied: a summary may be paid for again"); XCTAssertNil(held)
        await s.close()
    }

    /// A new task counts afresh, as it does for a task's suppression: a
    /// summary that no reply followed does not leave the next message without
    /// recovery. Here the request of the next task is rejected and recovered.
    func testANewTaskMayPayForASummaryThoughNoReplyFollowedTheLast() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let rounds=(0..<8).flatMap { n -> [ChatMessage] in
            var call=reads(n).message; call.id="call\(n)"; call.taskRootID="task"
            var result=ChatMessage(role:"toolResult",content:[textBlock("RESULT-c\(n)-0 "+String(repeating:"r",count:32_000))])
            result.id="result\(n)"; result.toolCallId="c\(n)-0"; result.toolName="read"; result.taskRootID="task"; return [call,result]
        }
        let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
        let client=FlowClient([.fail(rejected),.reply(answer("Noted."))])
        let s=try session(root,client,tools:BulkTools(chars:1),seed:earlier(4)+[user("task",task)]+rounds)
        let adopted=try await s.automaticCompaction(reason:"threshold")
        XCTAssertTrue(adopted)
        _=try await s.submit(Submission(commandID:"n",turnID:"next",text:"And the changelog."),steer:false)
        let state=try await settled(s), asked=await client.purposes, context=await s.context
        XCTAssertEqual(asked,["compaction","turn","compaction","turn"],"Rejected, recovered with one summary, answered")
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? ""); XCTAssertEqual(context.first?.compaction?["reason"].text,"context-rejection")
        await s.close()
    }

    /// A request that overflows right after a compaction, with nothing added
    /// since, is not answered with a second summary: the overflow is the
    /// run's failure, once.
    func testAnOverflowRightAfterACompactionIsNotSummarizedAgain() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
        // A 200,000-token window: the compaction keeps the task's five rounds
        // whole (60,000 tokens).
        let client=FlowClient((0..<5).map { Step.reply(reads($0,3)) }+[.fail(rejected)])
        let s=try session(root,client,tools:BulkTools(chars:16_000),window:200_000,seed:earlier(10))
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        let state=try await settled(s), purposes=await client.purposes, context=await s.context
        XCTAssertEqual(purposes,Array(repeating:"turn",count:5)+["compaction","turn"],"The compaction, the request that overflowed, and no second summary")
        XCTAssertEqual(state["state"].text,"error"); XCTAssertEqual(context.filter { $0.kind == "compaction" }.count,1)
        await s.close()
    }
}

/// The last resort end to end (Astra, 2026-11-11): a 32,768-token window whose
/// tool schemas are about 5,000 tokens, so what must stay cannot pass half the
/// usable input beside the summary's whole allowance. It is planned at the
/// summary's requested length, which is an admission estimate and never an
/// adoption exemption: the completed checkpoint is adopted when the actual
/// replacement measures within the half, whatever the summary's length, and
/// rejected as it is, one token over.
final class CompactionLastResortTests: HelperTestCase {
    private let task="OWNER-TASK: port the parser to the new grammar, keep the old entry point, and run every test."
    private struct Run { let state: JSON, purposes: [String], sent: [(purpose: String, body: JSON, cap: Int?)], context: [ChatMessage], path: String, held: String? }
    private func profile() throws -> Profile { var raw=try fixtureProfile().raw; raw["contextWindow"]=32_768; return try Profile(raw) }
    private func open(_ root: URL, _ client: FlowClient, seed: [ChatMessage]? = nil, resumePath: String? = nil) throws -> AgentSession {
        try AgentSession(id:"resort",profile:profile(),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                         resources:Resources(cwd:root,home:root),client:client,tools:BulkTools(chars:2_800,schema:20_000),traces:TraceStore(),resumePath:resumePath,seed:seed)
    }
    /// One earlier task, then a task of 700-token reads: the fourth round
    /// reaches the working threshold, and the summary is `summary` long.
    private func run(_ root: URL, summary: Int, then steps: [Step]) async throws -> Run {
        let client=FlowClient((0..<4).map { Step.reply(reads($0)) }+steps,summaries:[.chars(summary)])
        let s=try open(root,client,seed:earlier(1))
        _=try await s.keep(whenFinished:false)
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:task),steer:false)
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        let state=await s.snapshot(), purposes=await client.purposes, sent=await client.sent, context=await s.context, path=await s.path, held=await s.suppressedCompactionTask
        await s.close()
        return Run(state:state,purposes:purposes,sent:sent,context:context,path:try XCTUnwrap(path),held:held)
    }
    private func finishing() -> [Step] { [.reply(reads(4)),.reply(reads(5)),.reply(answer("All done."))] }

    func testACompletedSummaryIsHeldToTheHalfWhateverItsLength() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        func folder(_ name: String) throws -> URL { let url=root.appendingPathComponent(name); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }
        // At the requested length (2,048 tokens): adopted, and it tells what the limit is.
        // (The folders' names are equally long: the working folder is in the system prompt.)
        let asked=try await run(try folder("run-0"),summary:8_192,then:finishing())
        XCTAssertEqual(asked.state["state"].text,"idle",asked.state["errorMessage"].text ?? "")
        XCTAssertEqual(asked.purposes,["turn","turn","turn","turn","compaction","turn","turn","turn"],"Adopted, and no second compaction follows it")
        let request=try XCTUnwrap(asked.sent.first { $0.purpose == "compaction" }?.body), instruction=try XCTUnwrap(request["input"].list.last)
        let policy=CompactionPolicy(), usable=try policy.usable(profile:profile(),instructionTokens:RequestContextCounter.inputTokens([instruction]))
        let target=policy.share(usable,policy.replacementShare), measured=try XCTUnwrap(asked.context.first?.compaction?["after"]["requestTokens"].int)
        XCTAssertEqual(asked.context.first?.kind,"compaction"); XCTAssertLessThan(measured,target)
        // The plan was the last resort: at its whole allowance the same replacement passes the half.
        XCTAssertGreaterThan(measured-2_048+policy.summaryTokens(for:try profile()),target,"Only the requested length admitted this plan")
        XCTAssertEqual(asked.context.dropFirst().prefix(3).map(\.role),["user","assistant","toolResult"],"What must stay: the request and the batch in flight")
        let next=try item(asked.sent,5).body
        XCTAssertEqual(Array(userTexts(next).dropFirst()),[task]); XCTAssertEqual(outputs(next),["RESULT-c3-0"])
        // Longer than asked for and still within the half; exactly at it; one token over.
        let room=target-measured
        for (name,label,extra,adopted) in [("run-1","longer",room/2,true),("run-2","at the limit",room,true),("run-3","one over",room+1,false)] {
            let result=try await run(try folder(name),summary:8_192+4*extra,then:adopted ? finishing() : [.fail(AgentError("provider_http","HTTP 400 invalid request"))])
            let summary=result.context.first { $0.kind == "compaction" }
            if adopted {
                XCTAssertEqual(summary?.compaction?["after"]["requestTokens"].int,measured+extra,label)
                XCTAssertEqual(result.purposes,asked.purposes,label); XCTAssertEqual(result.state["state"].text,"idle",label); XCTAssertNil(result.held,label)
                XCTAssertEqual(outputs(try item(result.sent,5).body),["RESULT-c3-0"],label)
                continue
            }
            // Rejected as it is: nothing truncated, nothing asked again, the context as it was.
            XCTAssertNil(summary,label); XCTAssertEqual(result.purposes,["turn","turn","turn","turn","compaction","turn"],"\(label): no repair request; the intact request goes")
            XCTAssertEqual(result.state["compaction"]["errorCode"].text,"compact_no_progress",label)
            XCTAssertEqual(outputs(try item(result.sent,5).body),(0..<4).map { "RESULT-c\($0)-0" },"\(label): every round is still there")
            XCTAssertEqual(result.held,"task",label)
            // The task's one attempt is remembered across a reopen, and its overflow then stops the chat.
            let rejected=AgentError("provider_http","HTTP 400 rejected input",failure:.inputContextExceeded)
            let later=FlowClient([.reply(reads(4)),.fail(rejected)])
            let reopened=try open(root.appendingPathComponent(name),later,resumePath:result.path)
            let restored=await reopened.context, held=await reopened.suppressedCompactionTask
            XCTAssertEqual(restored.map(\.id),result.context.map(\.id),label); XCTAssertEqual(held,"task",label)
            try await reopened.retryRun()
            try await eventually(timeout:.seconds(30)) { !(await reopened.isRunning) }
            let end=await reopened.snapshot(), asked=await later.purposes
            XCTAssertEqual(asked,["turn","turn"],"\(label): no summary for the overflow"); XCTAssertEqual(end["state"].text,"error",label)
            await reopened.close()
        }
    }
}

/// Mail between agents meets the same policy as a threshold (Astra's Q7): a
/// compaction that cannot make room for it is not the family's failure.
final class CompactionAgentDeliveryTests: HelperTestCase {
    private func fixture(_ root: URL, client: any ModelClient, seed: [ChatMessage]) async throws -> (AgentSession,AgentSteeringCoordinator) {
        let profile=try fixtureProfile().overriding(model:nil,thinkingLevel:nil,contextWindow:100_000,maxOutputTokens:8_192)
        let parent=try AgentSession(id:"parent",profile:profile,apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        for message in seed { try await parent.append(message) }
        let coordinator=AgentSteeringCoordinator(); await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator,codex:true)
        try await parent.appendAgentRecord(JournalRecordKind.familyRun,AgentFamilyRun(epoch:"epoch"))
        return (parent,coordinator)
    }
    private func mail(_ chars: Int) -> AgentFamilyMessage {
        var row=AgentFamilyMessage(id:"message-0",sequence:1,childID:"child-0",turn:1,author:"subagent",kind:"note",text:String(repeating:"m",count:chars),task:"Task",epoch:"epoch")
        row.type="MESSAGE"; row.sender="/root/agent_0"; row.recipient="/root"; row.senderChildID=row.childID; row.queueOnly=true
        return row
    }
    /// The summary fails; the mail fits the window, though not beside the
    /// preferred output reserve, and is delivered.
    func testMailIsDeliveredWhenTheCompactionForItFails() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=FlowClient([],summaries:[.cutAtItsCap])
        let (parent,coordinator)=try await fixture(root,client:client,seed:earlier(8))
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,mail(48_000))
        let delivered=try await coordinator.boundary(parent,final:false)
        let purposes=await client.purposes, state=await parent.agentState(), context=await parent.context
        XCTAssertTrue(delivered); XCTAssertEqual(purposes,["compaction"],"One attempt")
        XCTAssertEqual(state.messages["message-0"]?.disposition,"delivered")
        XCTAssertNil(context.first?.kind); XCTAssertNotNil(context.last?.nativeAgentDelivery)
        await parent.close()
    }
    /// Mail the window cannot take stays accepted and undelivered between
    /// rounds, where the recipient's own request can still go; at the final
    /// boundary it is the limit that pauses, as before.
    func testMailTheWindowCannotTakeIsHeldBetweenRounds() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let (parent,coordinator)=try await fixture(root,client:FlowClient([]),seed:[user("task","Start."),reply("pre","Waiting for the agents.",root:"task")])
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,mail(420_000))
        let delivered=try await coordinator.boundary(parent,final:false)
        var state=await parent.agentState()
        XCTAssertFalse(delivered); XCTAssertEqual(state.messages["message-0"]?.disposition,"pending","Accepted, not delivered, not lost")
        do { _=try await coordinator.boundary(parent,final:true); XCTFail("Mail that cannot fit must not be passed over at the end") }
        catch { XCTAssertEqual((error as? AgentError)?.code,"coordination_limit") }
        state=await parent.agentState(); let rows=await parent.history
        XCTAssertEqual(state.messages["message-0"]?.disposition,"pending"); XCTAssertFalse(rows.contains { $0.nativeAgentDelivery != nil })
        await parent.close()
    }
}
