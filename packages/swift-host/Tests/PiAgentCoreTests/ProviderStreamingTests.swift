import XCTest
@testable import PiAgentCore

/// What the accumulator makes of a provider stream: opaque reasoning kept
/// verbatim, usage counted once, and an unfinished tool call never executed.
final class ProviderStreamingTests: XCTestCase {
    func testResponsesOpaqueReplayAndUsage() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        let opaque:JSON=["type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque-test"]
        let item:JSON=["type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{\"path\":\"README.md\"}"]
        _ = try accumulator.consume(["type":"response.completed","response":["status":"completed","output":.array([opaque,item]),"usage":["input_tokens":10,"output_tokens":8,"input_tokens_details":["cached_tokens":6],"output_tokens_details":["reasoning_tokens":3]]]])
        let reply=try accumulator.result();XCTAssertEqual(reply.calls.count,1);XCTAssertEqual(reply.calls[0].arguments["path"].text,"README.md")
        XCTAssertEqual(reply.usage["output"].int,8);XCTAssertEqual(reply.usage["inputIncludingCache"].int,10)
        var result=ChatMessage(role:"toolResult",content:[textBlock("hello")]);result.toolCallId="call_1"
        var raw=try fixtureProfile().raw
        raw["routing"]=["replayPolicy":"pinned","expectedModel":"fixture-actual","replayContract":"Fixture route is fixed and native-state compatible"]
        let profile=try Profile(raw)
        var message=reply.message
        message.providerIdentity=["status":"reported","effectiveModel":"fixture-actual"]
        message.providerBinding=try ProviderClient.replayBinding(profile)
        let body=try ProviderClient.requestBody(profile:profile,messages:[message,result],instructions:"test",tools:[],sessionID:"s")
        XCTAssertEqual(body["input"].list[0],opaque);XCTAssertEqual(body["input"].list[2]["call_id"].text,"call_1")
        XCTAssertEqual(body["include"], ["reasoning.encrypted_content"])
    }
    func testResponsesMalformedArgumentsAndAbsentTerminal() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        XCTAssertThrowsError(try accumulator.result())
        _ = try accumulator.consume(["type":"response.completed","response":["status":"completed","output":[["type":"function_call","call_id":"c","name":"read","arguments":"{" ]]]])
        XCTAssertThrowsError(try accumulator.result())
    }
    func testMessagesStreamingSignaturesAndCumulativeUsage() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        let events:[JSON]=[
            ["type":"message_start","message":["type":"message","usage":["input_tokens":5,"output_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3]]],
            ["type":"content_block_start","index":0,"content_block":["type":"thinking","thinking":"","signature":""]],
            ["type":"content_block_delta","index":0,"delta":["type":"thinking_delta","thinking":"visible"]],
            ["type":"content_block_delta","index":0,"delta":["type":"signature_delta","signature":"opaque-sig"]],
            ["type":"content_block_stop","index":0],
            ["type":"content_block_start","index":1,"content_block":["type":"tool_use","id":"tool1","name":"read","input":[:]]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"{\"path\":"]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"\"a\"}"]],
            ["type":"content_block_stop","index":1],
            ["type":"message_delta","delta":["stop_reason":"tool_use"],"usage":["output_tokens":9]],
            ["type":"message_stop"]]
        for event in events { _ = try a.consume(event) }
        let reply=try a.result();XCTAssertEqual(reply.usage["output"].int,9);XCTAssertEqual(reply.usage["inputIncludingCache"].int,10)
        XCTAssertEqual(reply.message.providerItems?[0]["signature"].text,"opaque-sig")
        XCTAssertEqual(reply.calls[0].arguments["path"].text,"a")
    }
    func testMessagesUnfinishedToolBlockIsNotExecuted() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        _ = try a.consume(["type":"content_block_start","index":0,"content_block":["type":"tool_use","id":"t","name":"read","input":[:]]])
        _ = try a.consume(["type":"content_block_delta","index":0,"delta":["type":"input_json_delta","partial_json":"{"]])
        XCTAssertThrowsError(try a.consume(["type":"message_stop"]))
    }
}
