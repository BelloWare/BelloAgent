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
private enum Summary { case text, cutAtItsCap }

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
            if (summaries.isEmpty ? .text : summaries.removeFirst()) == .cutAtItsCap {
                return ModelReply(message:ChatMessage(role:"assistant",content:[textBlock("Partial")]),usage:["input":100,"output":JSON(profile.maxOutput)],truncated:true,
                                  terminal:ModelTerminalOutcome(status:"incomplete",incompleteReason:"max_output_tokens"))
            }
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
        XCTAssertTrue(text.hasSuffix("</summary>\n\n"+continuation+" Continue from the retained request and latest results without asking the owner to repeat them."),String(text.suffix(200)))
        for body in following.dropFirst() { XCTAssertEqual(try item(body["input"].list,1),checkpoint,"The checkpoint item never changes") }
        XCTAssertEqual(context.first?.compaction?["after"]["requestTokens"].int,RequestContextCounter.projectedTokens(first),"Counted with its framing")
        await s.close()
        let reopened=try session(root,FlowClient([]),tools:BulkTools(chars:1),resumePath:saved)
        let restored=await reopened.context
        XCTAssertEqual(try ProviderClient.responsesInput(Array(restored.prefix(1)),instructions:"",profile:fixtureProfile()).first,checkpoint,"The same item from the journal")
        await reopened.close()
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
