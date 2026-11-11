import XCTest
@testable import PiAgentCore

/// What the accumulator makes of a provider stream: opaque reasoning kept
/// verbatim, usage counted once, and an unfinished tool call never executed.
final class ProviderStreamingTests: HelperTestCase {
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
        // Pi's system prompt first, then the reply's reasoning item as received and its call.
        XCTAssertEqual(body["input"].list[0]["role"].text,"developer")
        XCTAssertEqual(body["input"].list[1],opaque);XCTAssertEqual(body["input"].list[2]["call_id"].text,"call_1");XCTAssertEqual(body["input"].list[3]["call_id"].text,"call_1")
        XCTAssertEqual(body["include"], ["reasoning.encrypted_content"])
    }
    func testResponsesMalformedArgumentsAndAbsentTerminal() throws {
        var accumulator=ProviderAccumulator(api:"openai-responses")
        XCTAssertThrowsError(try accumulator.result())
        _ = try accumulator.consume(["type":"response.completed","response":["status":"completed","output":[["type":"function_call","call_id":"c","name":"read","arguments":"{" ]]]])
        // Pi's parseStreamingJson never fails: the tool is given what parses and says what is wrong.
        XCTAssertEqual(try accumulator.result().calls.first?.arguments,[:])
    }
    func testResponsesSignatureBearingIDsSurviveStreamingPersistenceAndReplay() throws {
        let ids = [fixtureGeminiToolCallID(tail: 0xfc), fixtureGeminiToolCallID(tail: 0xfd)]
        XCTAssertGreaterThan(ids[0].utf8.count, 2048)
        XCTAssertEqual(String(ids[0].prefix(512)), String(ids[1].prefix(512)))
        XCTAssertNotEqual(ids[0], ids[1])
        let output: [JSON] = ids.enumerated().map { index, id in
            ["type":"function_call", "id":JSON("fc_\(index)"), "call_id":JSON(id), "name":"read", "arguments":JSON("{\"path\":\"file-\(index)\"}")]
        }
        for streamed in [false, true] {
            var accumulator = ProviderAccumulator(api: "openai-responses")
            if streamed {
                for (index, item) in output.enumerated() {
                    var beginning = item; beginning["arguments"] = ""
                    let deltas = try accumulator.consume(["type":"response.output_item.added", "output_index":JSON(index), "item":beginning])
                    let first = try XCTUnwrap(deltas.first)
                    guard case .tool(let id, _, _) = first else { return XCTFail("Missing streamed tool identity") }
                    XCTAssertEqual(id, ids[index])
                    _ = try accumulator.consume(["type":"response.function_call_arguments.delta", "output_index":JSON(index), "item_id":item["id"], "delta":item["arguments"]])
                    _ = try accumulator.consume(["type":"response.output_item.done", "output_index":JSON(index), "item":item])
                }
                // Some gateways leave the terminal output empty after streaming it.
                _ = try accumulator.consume(["type":"response.completed", "response":["status":"completed", "output":[]]])
            } else {
                try accumulator.acceptJSON(["status":"completed", "output":.array(output)])
            }
            let reply = try accumulator.result()
            XCTAssertEqual(reply.calls.map(\.id), ids)
            XCTAssertEqual(reply.calls.compactMap { $0.arguments["path"].text }, ["file-0", "file-1"])
            XCTAssertEqual(reply.message.providerItems, output)
            for policy in ["pinned", "portable"] {
                var raw = try fixtureProfile().raw
                raw["routing"] = policy == "pinned"
                    ? ["replayPolicy":"pinned", "expectedModel":"fixture-actual", "replayContract":"Synthetic fixed route"]
                    : ["replayPolicy":"portable"]
                let profile = try Profile(raw)
                var message = reply.message
                message.providerIdentity = ["status":"reported", "effectiveModel":"fixture-actual"]
                message.providerBinding = try ProviderClient.replayBinding(profile)
                let results = ids.map { id -> ChatMessage in
                    var result = ChatMessage(role: "toolResult", content: [textBlock("read complete")])
                    result.toolCallId = id; return result
                }
                let restored = try ([message] + results).map { try ChatMessage(id: $0.id, pi: JSON.parse($0.pi.data())) }
                XCTAssertEqual(restored[0].content.compactMap { $0["id"].text }, ids)
                XCTAssertEqual(restored[0].providerItems, output)
                XCTAssertEqual(restored.dropFirst().compactMap(\.toolCallId), ids)
                let body = try ProviderClient.requestBody(profile: profile, messages: restored, instructions: "test", tools: [], sessionID: "s")
                let calls = body["input"].list.filter { $0["type"].text == "function_call" }
                let answers = body["input"].list.filter { $0["type"].text == "function_call_output" }
                XCTAssertEqual(calls.compactMap { $0["call_id"].text }, ids, "Replay must preserve the entire signature under \(policy)")
                XCTAssertEqual(answers.compactMap { $0["call_id"].text }, ids, "Each result must answer its exact call, without a synthetic missing result")
            }
        }
    }
    func testProviderToolCallIDsUseAnOpaqueUTF8ByteBound() throws {
        func parse(_ id: JSON, api: String) throws -> ModelReply {
            var accumulator = ProviderAccumulator(api: api)
            if api == "openai-responses" {
                try accumulator.acceptJSON(["status":"completed", "output":[["type":"function_call", "call_id":id, "name":"read", "arguments":"{}"]]])
            } else {
                try accumulator.acceptJSON(["type":"message", "stop_reason":"tool_use", "content":[["type":"tool_use", "id":id, "name":"read", "input":[:]]]])
            }
            return try accumulator.result()
        }
        let asciiBoundary = String(repeating: "x", count: 65_536)
        let unicodeBoundary = String(repeating: "🙂", count: 16_384)
        XCTAssertEqual(unicodeBoundary.utf8.count, 65_536)
        let invalid: [JSON] = ["", .null, 42, true, [:], JSON(asciiBoundary + "x"), JSON(unicodeBoundary + "x"), "call\nline", "call\u{0000}", "call\u{007f}"]
        for api in ["openai-responses", "anthropic-messages"] {
            for id in ["call-short", fixtureGeminiToolCallID(), asciiBoundary, unicodeBoundary] {
                XCTAssertEqual(try parse(JSON(id), api: api).calls.first?.id, id)
            }
            for id in invalid {
                XCTAssertThrowsError(try parse(id, api: api)) { error in
                    XCTAssertEqual((error as? AgentError)?.code, "invalid_params")
                }
            }
        }
    }
    func testMessagesStreamingSignaturesAndCumulativeUsage() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        let callID = fixtureGeminiToolCallID()
        let events:[JSON]=[
            ["type":"message_start","message":["type":"message","usage":["input_tokens":5,"output_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3]]],
            ["type":"content_block_start","index":0,"content_block":["type":"thinking","thinking":"","signature":""]],
            ["type":"content_block_delta","index":0,"delta":["type":"thinking_delta","thinking":"visible"]],
            ["type":"content_block_delta","index":0,"delta":["type":"signature_delta","signature":"opaque-sig"]],
            ["type":"content_block_stop","index":0],
            ["type":"content_block_start","index":1,"content_block":["type":"tool_use","id":JSON(callID),"name":"read","input":[:]]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"{\"path\":"]],
            ["type":"content_block_delta","index":1,"delta":["type":"input_json_delta","partial_json":"\"a\"}"]],
            ["type":"content_block_stop","index":1],
            ["type":"message_delta","delta":["stop_reason":"tool_use"],"usage":["output_tokens":9]],
            ["type":"message_stop"]]
        for event in events { _ = try a.consume(event) }
        let reply=try a.result();XCTAssertEqual(reply.usage["output"].int,9);XCTAssertEqual(reply.usage["inputIncludingCache"].int,10)
        XCTAssertEqual(reply.message.providerItems?[0]["signature"].text,"opaque-sig")
        XCTAssertEqual(reply.calls[0].id, callID)
        XCTAssertEqual(reply.calls[0].arguments["path"].text,"a")
    }
    func testMessagesUnfinishedToolBlockIsNotExecuted() throws {
        var a=ProviderAccumulator(api:"anthropic-messages")
        _ = try a.consume(["type":"content_block_start","index":0,"content_block":["type":"tool_use","id":"t","name":"read","input":[:]]])
        _ = try a.consume(["type":"content_block_delta","index":0,"delta":["type":"input_json_delta","partial_json":"{"]])
        XCTAssertThrowsError(try a.consume(["type":"message_stop"]))
    }
}
