import XCTest
@testable import PiAgentCore

final class ResponseTimelineTests: XCTestCase {
    private func text(_ index: Int, _ text: String) -> JSON { ["type":"response.output_text.delta","item_id":JSON("m\(index)"),"output_index":JSON(index),"content_index":0,"delta":JSON(text)] }
    func testInterleavedPartsKeepObservedOrderThroughCanonicalCompletion() {
        var adapter=ProviderDisplayEvents(api:"openai-responses",attempt:"attempt")
        _=adapter.consume(text(0,"First "),at:1)
        _=adapter.consume(["type":"response.reasoning_summary_text.delta","output_index":1,"item_id":"r","summary_index":0,"sequence_number":7,"delta":"Returned summary"],at:2)
        _=adapter.consume(text(0,"continued"),at:3)
        _=adapter.consume(["type":"response.output_item.added","output_index":2,"item":["id":"fc","type":"function_call","call_id":"same","name":"read","arguments":""]],at:4)
        _=adapter.consume(["type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc","delta":"{}"],at:5)
        let before=adapter.timeline.segments.map(\.id)
        XCTAssertEqual(adapter.timeline.segments.map(\.part.kind),["text","reasoningSummary","text","toolArguments"])
        XCTAssertEqual(adapter.timeline.segments.map(\.text),["First ","Returned summary","continued","{}"])
        XCTAssertEqual(adapter.timeline.segments[1].part.providerSequence,7)
        _=adapter.consume(["type":"response.completed","response":["status":"completed","output":[
            ["type":"message","id":"m0","content":[["type":"output_text","text":"First continued"]]],
            ["type":"reasoning","id":"r","summary":[["type":"summary_text","text":"Returned summary"]]],
            ["type":"function_call","id":"fc","call_id":"same","name":"read","arguments":"{}"]]]],at:6)
        XCTAssertEqual(adapter.timeline.segments.map(\.id),before)
        XCTAssertEqual(adapter.timeline.segments.map(\.text),["First ","Returned summary","continued","{}"])
        XCTAssertEqual(adapter.timeline.terminal,"completed")
    }
    func testReasoningFirstMultipartAndTerminalCorrectionStayLocal() {
        var adapter=ProviderDisplayEvents(api:"openai-responses",attempt:"a")
        _=adapter.consume(["type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":1,"delta":"Summary"],at:1)
        _=adapter.consume(text(1,"Draft"),at:2)
        let ids=adapter.timeline.segments.map(\.id)
        _=adapter.consume(["type":"response.output_text.done","output_index":1,"content_index":0,"text":"Corrected"],at:3)
        XCTAssertEqual(adapter.timeline.segments.prefix(2).map(\.id),ids)
        XCTAssertEqual(adapter.timeline.segments.last?.part.kind,"correction")
        XCTAssertEqual(adapter.timeline.segments.last?.text,"Corrected")
        XCTAssertEqual(adapter.timeline.segments.first?.part.partIndex,1)
    }
    func testAnthropicOpaqueSignatureNeverBecomesInventedThinking() throws {
        var adapter=ProviderDisplayEvents(api:"anthropic-messages",attempt:"a"), accumulator=ProviderAccumulator(api:"anthropic-messages")
        let events:[JSON]=[
            ["type":"message_start","message":["type":"message"]],
            ["type":"content_block_start","index":0,"content_block":["type":"text","text":"Answer"]],
            ["type":"content_block_stop","index":0],
            ["type":"content_block_start","index":1,"content_block":["type":"thinking","thinking":"Returned reasoning"]],
            ["type":"content_block_delta","index":1,"delta":["type":"signature_delta","signature":"secret-opaque-signature"]],
            ["type":"content_block_stop","index":1],
            ["type":"content_block_start","index":2,"content_block":["type":"redacted_thinking","data":"opaque"]],
            ["type":"content_block_stop","index":2],
            ["type":"message_delta","delta":["stop_reason":"end_turn"]], ["type":"message_stop"]]
        for event in events { _=try accumulator.consume(event); _=adapter.consume(event,at:1) }
        XCTAssertEqual(adapter.timeline.segments.map(\.part.kind),["text","reasoningText","opaque"])
        XCTAssertFalse(adapter.timeline.segments.map(\.text).joined().contains("secret-opaque-signature"))
        XCTAssertEqual(try accumulator.result().message.providerItems?[1]["signature"].text,"secret-opaque-signature")
    }
    func testPreparationFailureHasNoExecutionAndDuplicateCallIDsHaveDistinctAttempts() throws {
        var a=ProviderDisplayEvents(api:"openai-responses",attempt:"a"), b=ProviderDisplayEvents(api:"openai-responses",attempt:"b"), accumulator=ProviderAccumulator(api:"openai-responses")
        let begin:JSON=["type":"response.output_item.added","output_index":0,"item":["type":"function_call","id":"fc","call_id":"same","name":"read","arguments":""]]
        _=try accumulator.consume(begin);_=a.consume(begin,at:1);_=b.consume(begin,at:1)
        _=a.consume(["type":"response.function_call_arguments.delta","output_index":0,"delta":"{"],at:2)
        XCTAssertThrowsError(try accumulator.result())
        XCTAssertEqual(a.timeline.segments[0].part.kind,"toolArguments")
        XCTAssertNotEqual(a.timeline.segments[0].id,b.timeline.segments[0].id)
    }
    func testProjectionNeverShrinksExistingPartsAndCoverageIsExplicit() {
        var timeline=ResponseTimeline()
        timeline.consume(ResponsePartEvent(attemptID:"a",ordinal:0,itemID:"first",kind:"text",update:"append",text:String(repeating:"prefix 🙂 ",count:3000)))
        let first=timeline.projected().segments[0]
        for i in 1..<100 { timeline.consume(ResponsePartEvent(attemptID:"a",ordinal:i,itemID:"\(i)",kind:i%2==0 ? "toolArguments":"reasoningText",update:"append",text:"Part \(i)")) }
        XCTAssertEqual(timeline.projected().segments[0].text,first.text)
        XCTAssertEqual(timeline.projected().segments[0].id,first.id)
        XCTAssertEqual(timeline.segments.count,ResponseTimeline.maximumSegments)
        XCTAssertGreaterThan(timeline.omittedEvents,0);XCTAssertEqual(timeline.coverage,"partial")
        XCTAssertTrue(timeline.segments.contains { $0.part.kind=="toolArguments" && $0.text=="Part 2" })
    }
    func testTimelineMetadataDoesNotChangeReplayOrUsage() throws {
        let profile=try fixtureProfile()
        var reply=answer("Answer").message
        let original=try ProviderClient.requestBody(profile:profile,messages:[reply],instructions:"stable",tools:[],sessionID:"s")
        reply.responseTimeline=ResponseTimeline.canonical([("text","Answer",nil,nil)],sourceID:reply.id)
        XCTAssertEqual(try ProviderClient.requestBody(profile:profile,messages:[reply],instructions:"stable",tools:[],sessionID:"s"),original)
        let restored=try ChatMessage(id:reply.id,pi:reply.pi)
        XCTAssertEqual(restored.responseTimeline,reply.responseTimeline)
    }
}
