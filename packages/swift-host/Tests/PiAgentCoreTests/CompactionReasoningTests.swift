import XCTest
@testable import PiAgentCore

// Encrypted reasoning beside what a compaction keeps. The owner, 2026-11-11:
// "encrypted reasoning should be not ignored… unless it got rejected by
// litellm due to model switch, which then we need user confirmation to
// proceed with previous encrypted reasoning removed or something like that,
// while keep new encrypted reasoning". On a route that replays it (a pinned
// one), every reasoning item of a retained reply stays in the request, byte
// for byte, in its place before the calls it led to: in the ordinary
// request, in the summary request, and after a compaction, whole or by the
// fallback. And it is counted.

/// A pinned route's gateway: every reply carries a reasoning item with
/// `cipher` characters of encrypted content before its one read call.
private actor ReasoningClient: ModelClient {
    let rounds: Int, cipher: Int
    var sent: [(purpose: String, body: JSON)] = []
    init(rounds: Int, cipher: Int) { self.rounds=rounds; self.cipher=cipher }
    static func reasoning(_ round: Int, _ cipher: Int) -> JSON {
        ["type":"reasoning","id":JSON("rs_\(round)"),"summary":[],"encrypted_content":JSON("enc-\(round)-"+String(repeating:"A",count:cipher))]
    }
    func complete(profile:Profile,apiKey:String,messages:[ChatMessage],instructions:String,tools:[ToolDefinition],sessionID:String,turnID:String,purpose:String,onDelta:@escaping @Sendable(StreamDelta) async throws -> Void) async throws -> ModelReply {
        let body=try ProviderClient.requestBody(profile:profile,messages:messages,instructions:instructions,tools:tools,sessionID:sessionID,compaction:purpose == "compaction")
        sent.append((purpose,body))
        if purpose == "compaction" { return answer("SUMMARY") }
        let round=sent.filter { $0.purpose == "turn" }.count-1, input=RequestContextCounter.projectedTokens(body)
        var reply: ModelReply
        if round < rounds {
            let call=ToolCall(id:"c\(round)",name:"read",arguments:["path":JSON("f\(round)")])
            var message=ChatMessage(role:"assistant",content:[["type":"toolCall","id":JSON(call.id),"name":"read","arguments":call.arguments]])
            message.providerItems=[Self.reasoning(round,cipher),["type":"function_call","id":JSON("fc_"+call.id),"call_id":JSON(call.id),"name":"read","arguments":JSON(call.arguments.encoded())]]
            reply=ModelReply(message:message,calls:[call],terminal:ModelTerminalOutcome(status:"completed"))
        } else { reply=answer("All done.") }
        // What the real client records for a reply of a pinned route.
        reply.message.providerBinding=try ProviderClient.replayBinding(profile)
        reply.message.providerIdentity=["status":"reported","effectiveModel":JSON(profile.model)]
        reply.usage=["input":JSON(input),"output":10,"inputIncludingCache":JSON(input),"total":JSON(input+10)]
        return reply
    }
}
private struct Reads: ToolExecuting {
    let chars: Int
    func definitions(readOnly:Bool)->[ToolDefinition] { [ToolDefinition("read","test",[:])] }
    func invoke(_ call:ToolCall,readOnly:Bool) async throws -> JSON { resultText("RESULT-\(call.id) "+String(repeating:"r",count:chars)) }
}
/// The reasoning items of a request and, for each, the call that follows it.
private func reasoning(_ body: JSON) -> [(item: JSON, call: String?)] {
    let input=body["input"].list
    return input.indices.filter { input[$0]["type"].text == "reasoning" }.map { (input[$0], $0+1 < input.count ? input[$0+1]["call_id"].text : nil) }
}

final class CompactionReasoningTests: HelperTestCase {
    private func session(_ root: URL, _ client: ReasoningClient, chars: Int, seed: [ChatMessage]? = nil) throws -> AgentSession {
        var raw=try fixtureProfile().raw
        raw["routing"]=["replayPolicy":"pinned","expectedModel":"fixture-model","replayContract":"fixture contract: one fixed route"]
        return try AgentSession(id:"reasoning",profile:Profile(raw),apiKey:"synthetic",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,
                                resources:Resources(cwd:root,home:root),client:client,tools:Reads(chars:chars),traces:TraceStore(),seed:seed)
    }
    private func run(_ s: AgentSession) async throws {
        _=try await s.submit(Submission(commandID:"c",turnID:"task",text:"OWNER-TASK: read them all."),steer:false)
        try await eventually(timeout:.seconds(30)) { !(await s.isRunning) }
        let state=await s.snapshot()
        XCTAssertEqual(state["state"].text,"idle",state["errorMessage"].text ?? "")
    }
    private func expect(_ body: JSON, rounds: Range<Int>, cipher: Int, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let found=reasoning(body)
        XCTAssertEqual(found.map(\.item),rounds.map { ReasoningClient.reasoning($0,cipher) },message,file:file,line:line)
        XCTAssertEqual(found.map(\.call),rounds.map { "c\($0)" },"Each before the call it led to",file:file,line:line)
    }

    /// The task whole: every reply's reasoning is in the summary request and
    /// in the request after the compaction, as it was received.
    func testReasoningStaysWithATaskKeptWhole() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var old=ChatMessage(role:"user",content:[textBlock("OLD "+String(repeating:"u",count:120_000))]); old.id="old"; old.taskRootID="old"
        var done=ChatMessage(role:"assistant",content:[textBlock("ANSWER "+String(repeating:"a",count:100_000))]); done.id="old-reply"; done.taskRootID="old"
        let client=ReasoningClient(rounds:8,cipher:400)
        let s=try session(root,client,chars:8_000,seed:[old,done])
        try await run(s)
        let sent=await client.sent, mark=try XCTUnwrap(sent.firstIndex { $0.purpose == "compaction" })
        XCTAssertEqual(sent.filter { $0.purpose == "compaction" }.count,1)
        let rounds=0..<sent[..<mark].count
        XCTAssertGreaterThan(rounds.count,1)
        expect(sent[mark].body,rounds:rounds,cipher:400,"The summary request holds every reasoning item")
        expect(sent[mark+1].body,rounds:rounds,cipher:400,"So does the request after the compaction")
        XCTAssertFalse(sent[mark+1].body["input"].list.contains { $0["content"].list.contains { $0["text"].text?.hasPrefix("OLD ") == true } })
        await s.close()
    }

    /// The fallback keeps whole groups: a retained round keeps its reasoning,
    /// a summarized round takes its reasoning with it.
    func testReasoningStaysWithTheRoundsTheFallbackKeeps() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ReasoningClient(rounds:14,cipher:400)
        let s=try session(root,client,chars:22_000)
        try await run(s)
        let sent=await client.sent, mark=try XCTUnwrap(sent.firstIndex { $0.purpose == "compaction" })
        let all=0..<(sent[..<mark].count), next=sent[mark+1].body
        expect(sent[mark].body,rounds:all,cipher:400,"The summary request holds every round's reasoning")
        let outputs=next["input"].list.filter { $0["type"].text == "function_call_output" }.count
        XCTAssertGreaterThan(outputs,1); XCTAssertLessThan(outputs,all.count)
        expect(next,rounds:(all.count-outputs)..<all.count,cipher:400,"The kept rounds' reasoning, in order")
        await s.close()
    }

    /// Opaque reasoning is counted where no reply's usage has measured it:
    /// its serialized size over four, an upper bound.
    func testReplayedReasoningIsCountedByItsSize() throws {
        let plain: JSON=["type":"function_call","call_id":"c","name":"read","arguments":"{}"]
        let bare=RequestContextCounter.inputTokens([plain])
        let cipher=String(repeating:"A",count:40_000)
        XCTAssertEqual(RequestContextCounter.inputTokens([["type":"reasoning","id":"rs","summary":[],"encrypted_content":JSON(cipher)],plain]),bare+8+10_000)
        XCTAssertEqual(RequestContextCounter.inputTokens([["type":"reasoning","id":"rs","summary":[["type":"summary_text","text":"abcd"]]],plain]),bare+8+1,"A summary alone counts as its text")
        XCTAssertEqual(RequestContextCounter.inputTokens([["type":"message","role":"user","content":[["type":"input_text","text":"abcd"]],"encrypted_content":JSON(cipher)]]),8+1,"Only a reasoning item's")
    }

    /// Counted, a reply's reasoning cannot carry what a compaction keeps past
    /// its target unnoticed: rounds heavy with it are kept fewer.
    func testHeavyReasoningCountsAgainstWhatTheFallbackKeeps() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        func keptRounds(cipher: Int) async throws -> Int {
            let directory=root.appendingPathComponent("c\(cipher)"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let client=ReasoningClient(rounds:40,cipher:cipher)
            let s=try session(directory,client,chars:8_000)
            try await run(s)
            let sent=await client.sent, mark=try XCTUnwrap(sent.firstIndex { $0.purpose == "compaction" })
            await s.close()
            XCTAssertLessThanOrEqual(RequestContextCounter.projectedTokens(sent[mark+1].body),(100_000-1_000-16_384)/2)
            return reasoning(sent[mark+1].body).count
        }
        let light=try await keptRounds(cipher:400), heavy=try await keptRounds(cipher:24_000)
        XCTAssertGreaterThan(light,heavy,"8,000 tokens a round instead of 2,000: fewer rounds fit")
        XCTAssertGreaterThan(heavy,0)
    }
}
