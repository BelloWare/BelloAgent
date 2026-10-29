import XCTest
@testable import PiAgentCore

final class MailboxCutinTests: HelperTestCase {
    func testPartialAnswerPhaseSurvivesReplay() throws {
        var message = ChatMessage(role:"assistant",content:[textBlock("A note")])
        message.providerItems = [["type":"message","role":"assistant","id":"msg_1","phase":"partial_answer","content":[["type":"output_text","text":"A note"]]]]
        let input = try ProviderClient.assistantItems(message,profile:fixtureProfile(),msgIndex:0)
        XCTAssertEqual(input.first?["phase"].text,"partial_answer")
    }
    func testTypedCutMetadataSurvivesJournalAndDisplay() throws {
        let metadata: JSON = ["version":1,"cutId":"cut-1","attemptId":"attempt-1","responseId":"response-1","itemId":"reasoning-1"]
        let row = try ChatMessage(id:"reply",pi:["role":"assistant","content":[],"nativeMailboxCut":metadata])
        XCTAssertEqual(row.pi["nativeMailboxCut"],metadata)
        XCTAssertEqual(row.view()["nativeMailboxCut"],metadata)
        XCTAssertTrue(AgentSession.continues(from:row))
        let ordinary = try ChatMessage(id:"old",pi:["role":"assistant","content":[]])
        XCTAssertNil(ordinary.nativeMailboxCut)
        XCTAssertNil(ordinary.nativeAgentCallCancellation)
    }
}

extension MailboxCutinTests {
    private func nativeProfile(expected: String = "gpt-5.4") throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["routing"] = ["replayPolicy":"pinned","expectedModel":JSON(expected),"replayContract":"Generated native route"]
        return try Profile(raw)
    }
    private var reasoning: JSON { ["type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque\n+/=雪","status":"completed"] }
    private func note(_ phase: String) -> JSON { ["type":"message","id":"msg_1","role":"assistant","phase":JSON(phase),"status":"completed","content":[["type":"output_text","text":"Retained note","annotations":[]]]] }
    private func tracker() -> MailboxCutPrefix {
        var result = MailboxCutPrefix()
        _ = result.consume(["type":"response.created","response":["id":"resp_1","model":"gpt-5.4"]])
        return result
    }
    func testWholeReasoningCommentaryAndPartialAnswerOnly() {
        for item in [reasoning,note("commentary"),note("partial_answer")] {
            var prefix = tracker()
            XCTAssertNil(prefix.consume(["type":"response.output_item.added","output_index":0,"item":item]))
            XCTAssertNil(prefix.consume(["type":"response.reasoning_summary_part.done","output_index":0,"item":item]))
            XCTAssertNil(prefix.consume(["type":"response.output_text.done","output_index":0,"item":item]))
            XCTAssertEqual(prefix.consume(["type":"response.output_item.done","output_index":0,"item":item]),[item])
            XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":0,"item":item]))
        }
    }
    func testIneligibleItemsMissingOpaqueStateAndUnknownTypes() {
        let tool: JSON = ["type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":"{}"]
        for item in [note("final_answer"),note("unknown"),note("").removing(["phase"]),tool,reasoning.removing(["encrypted_content"]),["type":"vendor","id":"x"]] {
            var prefix = tracker()
            XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":0,"item":item]),item.encoded())
        }
    }
    func testOpenEarlierItemGapAndConflictingDuplicateFailClosed() {
        var prefix = tracker()
        _ = prefix.consume(["type":"response.output_item.added","output_index":0,"item":note("commentary")])
        XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":1,"item":reasoning]))
        var gap = tracker()
        XCTAssertNil(gap.consume(["type":"response.output_item.done","output_index":1,"item":reasoning]))
        var duplicate = tracker()
        _ = duplicate.consume(["type":"response.output_item.done","output_index":0,"item":reasoning])
        XCTAssertNil(duplicate.consume(["type":"response.output_item.done","output_index":0,"item":note("commentary")]))
        XCTAssertTrue(duplicate.invalid)
    }
    func testTerminalBeforeItemCompletionWins() {
        for type in ["response.completed","response.incomplete","response.failed","error"] {
            var prefix = tracker(); _ = prefix.consume(["type":JSON(type)])
            XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":0,"item":reasoning]))
        }
    }
    func testCompletedCallRetainedInProviderOrderButDoesNotCut() {
        var prefix = tracker()
        let call: JSON = ["type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":"{ \"command\": \"touch forbidden\" }"]
        XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":0,"item":call]))
        XCTAssertEqual(prefix.consume(["type":"response.output_item.done","output_index":1,"item":reasoning]),[call,reasoning])
        var interleaved = tracker()
        XCTAssertNil(interleaved.consume(["type":"response.output_item.done","output_index":1,"item":call]))
        XCTAssertEqual(interleaved.consume(["type":"response.output_item.done","output_index":0,"item":reasoning]),[reasoning,call])
    }
    func testMalformedMessageAndDuplicateCallIDsDoNotCut() {
        for content: JSON in [.null,"invalid",["wrong":"shape"]] {
            var prefix = tracker(), item = note("commentary"); item["content"] = content
            XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":0,"item":item]))
        }
        var prefix = tracker()
        for index in 0...1 {
            let call: JSON = ["type":"function_call","id":JSON("fc_\(index)"),"call_id":"duplicate","name":"bash","arguments":"{}"]
            XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":JSON(index),"item":call]))
        }
        XCTAssertNil(prefix.consume(["type":"response.output_item.done","output_index":2,"item":reasoning]))
    }
    func testPinnedOpenAIRouteNameRuleAndEveryNegative() throws {
        for expected in ["gpt-4o","openai/gpt-4.1-mini","gpt-5.4","gpt-6.1","o3-mini","o4-mini"] {
            let profile = try nativeProfile(expected:expected)
            let body = try ProviderClient.requestBody(profile:profile,messages:[],instructions:"",tools:[],sessionID:"s")
            XCTAssertTrue(ProviderClient.mailboxCutRoute(profile:profile,identity:["status":"reported","effectiveModel":JSON(expected)],body:body),expected)
        }
        for policy in ["portable","ask","pinned"] { for model in ["claude-opus-4","gemini-3","vendor/gpt-5","alias","gpt-5","gpt-50"] {
            var raw = try nativeProfile(expected:model).raw; raw["routing"]["replayPolicy"] = JSON(policy)
            let profile = try Profile(raw), body = try ProviderClient.requestBody(profile:profile,messages:[],instructions:"",tools:[],sessionID:"s")
            XCTAssertEqual(ProviderClient.mailboxCutRoute(profile:profile,identity:["status":"reported","effectiveModel":JSON(model)],body:body),policy == "pinned" && model == "gpt-5")
        } }
        let profile = try nativeProfile(), body = try ProviderClient.requestBody(profile:profile,messages:[],instructions:"",tools:[],sessionID:"s")
        for identity: JSON in [[:],["status":"unreported"],["status":"conflict","effectiveModel":"gpt-5.4"],["status":"reported","effectiveModel":"gpt-5"]] {
            XCTAssertFalse(ProviderClient.mailboxCutRoute(profile:profile,identity:identity,body:body))
        }
        for key in ["input","model","stream","store","previous_response_id","conversation","context_management","truncation","background"] {
            var raw = profile.raw; raw["samplingParams"][key] = "override"
            XCTAssertFalse(ProviderClient.mailboxCutRoute(profile:try Profile(raw),identity:["status":"reported","effectiveModel":"gpt-5.4"],body:body),key)
        }
    }
    func testCutReplayIsVerbatimIncludingOpaquePhaseAndCallArguments() throws {
        let profile = try nativeProfile()
        let items: [JSON] = [reasoning,note("partial_answer"),["type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":"{ \"command\": \"pwd\" }"]]
        var message = ChatMessage(role:"assistant",content:[])
        message.providerItems = items; message.providerBinding = try ProviderClient.replayBinding(profile)
        message.providerIdentity = ["status":"reported","effectiveModel":"gpt-5.4"]
        message.nativeMailboxCut = ["version":1]
        XCTAssertEqual(try ProviderClient.assistantItems(message,profile:profile,msgIndex:0),items)
    }
    func testLazyPromotionKeepsV4UntilFirstCutAndNeverDowngrades() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let journal = try SessionJournal(url:root.appendingPathComponent("s.jsonl"),id:"s",cwd:root,binding:fixtureProfile().binding,create:true)
        try journal.promoteToCodex(managedChild:false)
        XCTAssertEqual(journal.markerKind,JournalRecordKind.codexMarker)
        try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentCutPrepared),"data":[:]])
        XCTAssertEqual(journal.markerKind,JournalRecordKind.codexMarker)
        let size = journal.size
        try journal.promoteToMailboxCut(managedChild:false)
        XCTAssertEqual(journal.size,size); XCTAssertEqual(journal.markerKind,JournalRecordKind.cutinMarker)
        try journal.promoteToCodex(managedChild:false); try journal.promoteToSteering(managedChild:false)
        XCTAssertEqual(journal.markerKind,JournalRecordKind.cutinMarker)
    }
}
