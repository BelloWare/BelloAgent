import XCTest
@testable import PiApp

final class CombinedResponseTests: XCTestCase {
    private func stream(_ events: [[String: Any]], tail: String = "") throws -> CapturedEventStream {
        let lines = try events.map { event in
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self) + "\n\n"
        }.joined() + tail
        return try XCTUnwrap(CapturedEventStream.parse(Data(lines.utf8)))
    }

    private func combined(_ events: [[String: Any]], tail: String = "") throws -> CombinedResponse {
        try XCTUnwrap(CombinedResponse.parse(stream(events, tail: tail)))
    }

    private func object(_ result: CombinedResponse) throws -> [String: Any] {
        try XCTUnwrap(result.json.value as? [String: Any])
    }

    private func outputs(_ result: CombinedResponse) throws -> [[String: Any]] {
        try XCTUnwrap(object(result)["output"] as? [[String: Any]])
    }

    private func created(_ id: String = "resp_one") -> [String: Any] {
        ["type": "response.created", "response": ["id": id, "object": "response", "status": "in_progress", "model": "auto-router", "output": []]]
    }

    private func message(_ id: String = "msg_one", index: Int = 0) -> [String: Any] {
        ["type": "response.output_item.added", "output_index": index,
         "item": ["id": id, "type": "message", "role": "assistant", "content": []]]
    }

    private func text(_ value: String, id: String = "msg_one", index: Int = 0, content: Int = 0) -> [String: Any] {
        ["type": "response.output_text.delta", "output_index": index, "item_id": id, "content_index": content, "delta": value]
    }

    private func terminal(_ status: String = "completed", id: String = "resp_one", text: String = "Final") -> [String: Any] {
        ["type": "response.\(status)", "response": ["id": id, "object": "response", "status": status,
            "model": "auto-router", "router_model_name": "gpt-5.4-mini",
            "output": [["id": "msg_one", "type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]]]
    }

    func testTerminalResponsePreservesExactObjectIncludingUsageRoutingAndOpaqueFields() throws {
        var event = terminal()
        var response = try XCTUnwrap(event["response"] as? [String: Any])
        response["usage"] = ["input_tokens": 38, "input_tokens_details": ["cached_tokens": 0, "cache_write_tokens": 0],
                             "output_tokens": 302, "output_tokens_details": ["reasoning_tokens": 253], "total_tokens": 340, "cost": NSNull()] as [String: Any]
        response["future_provider_extension"] = ["nested": ["preserved", NSNull(), 9] as [Any]]
        response["encrypted_content"] = "opaque-provider-state-not-inspected"
        event["response"] = response
        let value = try combined([created(), message(), text("A prefix"), event], tail: "data: [DONE]\n\n")
        XCTAssertFalse(value.isPartial)
        XCTAssertTrue(NSDictionary(dictionary: try object(value)).isEqual(to: response))
        XCTAssertTrue(value.notice.contains("response.completed"))
        XCTAssertTrue(value.notice.contains("derived view"))
        XCTAssertTrue(value.json.formatted.contains("\n"))
        XCTAssertEqual(value.json.rootLabel, "Combined response")
    }

    func testCanonicalItemAndTerminalDoNotAppendTheSameTextAgain() throws {
        let item: [String: Any] = ["id": "msg_one", "type": "message", "content": [["type": "output_text", "text": "Hello world"]]]
        let value = try combined([created(), message(), text("Hello "), text("world"),
            ["type": "response.output_text.done", "output_index": 0, "item_id": "msg_one", "content_index": 0, "text": "Hello world"],
            ["type": "response.output_item.done", "output_index": 0, "item": item], terminal(text: "Hello world")])
        let content = try XCTUnwrap(try outputs(value).first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Hello world")
        XCTAssertFalse(value.isPartial)
    }

    func testPartialReconstructionCombinesReasoningTextRefusalAndToolArguments() throws {
        let value = try combined([created(),
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "reason_one", "type": "reasoning", "summary": [], "encrypted_content": "kept"]],
            ["type": "response.reasoning_summary_part.added", "output_index": 0, "item_id": "reason_one", "summary_index": 0, "part": ["type": "summary_text", "text": ""]],
            ["type": "response.reasoning_summary_text.delta", "output_index": 0, "item_id": "reason_one", "summary_index": 0, "delta": "Considering "],
            ["type": "response.reasoning_summary_text.delta", "output_index": 0, "item_id": "reason_one", "summary_index": 0, "delta": "the inputs"],
            ["type": "response.reasoning_text.delta", "output_index": 0, "item_id": "reason_one", "content_index": 0, "delta": "Reported reasoning text"],
            message(index: 1), text("Hello ", index: 1), text("🌍", index: 1),
            ["type": "response.refusal.delta", "output_index": 1, "item_id": "msg_one", "content_index": 1, "delta": "Cannot "],
            ["type": "response.refusal.delta", "output_index": 1, "item_id": "msg_one", "content_index": 1, "delta": "continue"],
            ["type": "response.output_item.added", "output_index": 2, "item": ["id": "call_item", "type": "function_call", "call_id": "call_one", "name": "read", "arguments": ""]],
            ["type": "response.function_call_arguments.delta", "output_index": 2, "item_id": "call_item", "delta": "{\"path\":"],
            ["type": "response.function_call_arguments.delta", "item_id": "call_item", "delta": "\"file\"}"]])
        let output = try outputs(value)
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual((output[0]["summary"] as? [[String: Any]])?.first?["text"] as? String, "Considering the inputs")
        XCTAssertEqual((output[0]["content"] as? [[String: Any]])?.first?["text"] as? String, "Reported reasoning text")
        XCTAssertEqual(output[0]["encrypted_content"] as? String, "kept")
        XCTAssertEqual((output[1]["content"] as? [[String: Any]])?.first?["text"] as? String, "Hello 🌍")
        XCTAssertEqual((output[1]["content"] as? [[String: Any]])?[1]["refusal"] as? String, "Cannot continue")
        XCTAssertEqual(output[2]["arguments"] as? String, #"{"path":"file"}"#)
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.notice.contains("no terminal response object"))
        XCTAssertNil(try object(value)["usage"], "Missing usage must not be invented from streamed text")
        XCTAssertEqual(try object(value)["status"] as? String, "in_progress")
    }

    func testDoneEventsReplaceAccumulatedTextAndPreservePartExtensions() throws {
        let part: [String: Any] = ["type": "output_text", "text": "Final text", "annotations": [], "future_field": ["value": 7]]
        let value = try combined([created(), message(), text("Draft text"),
            ["type": "response.output_text.done", "output_index": 0, "item_id": "msg_one", "content_index": 0, "text": "Corrected text"],
            ["type": "response.content_part.done", "output_index": 0, "item_id": "msg_one", "content_index": 0, "part": part]])
        let content = try XCTUnwrap(try outputs(value).first?["content"] as? [[String: Any]])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(content.first)).isEqual(to: part))
    }

    func testFunctionDoneIsAuthoritativeAndArgumentsStayAJSONString() throws {
        let value = try combined([created(),
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "tool_one", "type": "function_call", "call_id": "call_one", "name": "read", "arguments": ""]],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "tool_one", "delta": "{\"wrong\":1}"],
            ["type": "response.function_call_arguments.done", "output_index": 0, "item_id": "tool_one", "name": "read", "arguments": "{\"correct\":2}"]])
        XCTAssertEqual(try outputs(value).first?["arguments"] as? String, #"{"correct":2}"#)
        XCTAssertTrue(value.isPartial)
    }

    func testReasoningAndRefusalDoneEventsReplaceTheirDeltas() throws {
        let value = try combined([created(),
            ["type": "response.output_item.added", "output_index": 0, "item": ["id": "reason_one", "type": "reasoning"]],
            ["type": "response.reasoning_summary_text.delta", "output_index": 0, "item_id": "reason_one", "summary_index": 0, "delta": "Draft"],
            ["type": "response.reasoning_summary_text.done", "output_index": 0, "item_id": "reason_one", "summary_index": 0, "text": "Summary"],
            ["type": "response.reasoning_text.delta", "output_index": 0, "item_id": "reason_one", "content_index": 0, "delta": "Draft reasoning"],
            ["type": "response.reasoning_text.done", "output_index": 0, "item_id": "reason_one", "content_index": 0, "text": "Reported reasoning"],
            message(index: 1),
            ["type": "response.refusal.delta", "output_index": 1, "item_id": "msg_one", "content_index": 0, "delta": "Draft refusal"],
            ["type": "response.refusal.done", "output_index": 1, "item_id": "msg_one", "content_index": 0, "refusal": "Final refusal"]])
        let output = try outputs(value)
        XCTAssertEqual((output[0]["summary"] as? [[String: Any]])?.first?["text"] as? String, "Summary")
        XCTAssertEqual((output[0]["content"] as? [[String: Any]])?.first?["text"] as? String, "Reported reasoning")
        XCTAssertEqual((output[1]["content"] as? [[String: Any]])?.first?["refusal"] as? String, "Final refusal")
    }

    func testAnnotationsRetainNestedProviderData() throws {
        let annotation: [String: Any] = ["type": "url_citation", "url": "https://example.invalid/source", "title": "Source", "extra": ["retained": true]]
        let value = try combined([created(), message(), text("Answer"),
            ["type": "response.output_text.annotation.added", "output_index": 0, "item_id": "msg_one", "content_index": 0, "annotation_index": 0, "annotation": annotation]])
        let content = try XCTUnwrap(try outputs(value).first?["content"] as? [[String: Any]])
        let annotations = try XCTUnwrap(content.first?["annotations"] as? [[String: Any]])
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(annotations.first)).isEqual(to: annotation))
    }

    func testFailedAndIncompleteCanonicalObjectsRetainErrorAndStatus() throws {
        for status in ["failed", "incomplete"] {
            var event = terminal(status)
            var response = try XCTUnwrap(event["response"] as? [String: Any])
            response["error"] = ["code": "test_error", "message": "Provider message"]
            response["incomplete_details"] = ["reason": "max_output_tokens"]
            event["response"] = response
            let value = try combined([created(), event])
            XCTAssertTrue(NSDictionary(dictionary: try object(value)).isEqual(to: response))
            XCTAssertTrue(value.notice.contains("provider reported"))
            XCTAssertTrue(value.notice.contains(status == "failed" ? "failed response" : "incomplete response"))
        }
    }

    func testMalformedFramesKeepTerminalUsefulButFlagIncompletePresentation() throws {
        let valid = try stream([created(), terminal()])
        let malformed = try stream([], tail: "event: response.output_text.delta\ndata: {bad json}\n\n")
        let combinedStream = CapturedEventStream(frames: [valid.frames[0], malformed.frames[0], valid.frames[1]], outline: valid.outline)
        let value = try XCTUnwrap(CombinedResponse.parse(combinedStream))
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.notice.contains("Malformed"))
        XCTAssertEqual(try object(value)["status"] as? String, "completed", "The retained canonical object is not rewritten")
    }

    func testDifferentResponseIdentitiesAreNeverMerged() throws {
        let value = try combined([created("resp_owner"), message(), text("Owner"), terminal(id: "resp_foreign", text: "Foreign")])
        XCTAssertTrue(value.isPartial)
        XCTAssertEqual(try object(value)["id"] as? String, "resp_owner")
        XCTAssertFalse(value.json.formatted.contains("Foreign"))
        XCTAssertTrue(value.notice.contains("conflicting"))
    }

    func testConflictingTerminalObjectsDoNotReplaceFirstCanonicalObject() throws {
        let value = try combined([created(), terminal(text: "First canonical"), terminal(text: "Different canonical")])
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.json.formatted.contains("First canonical"))
        XCTAssertFalse(value.json.formatted.contains("Different canonical"))
    }

    func testConflictingItemIDCannotAttachTextToAnotherOutput() throws {
        let value = try combined([created(), message(), text("Owner"), text("Foreign", id: "msg_foreign"),
            ["type": "response.output_item.added", "output_index": 1, "item": ["id": "msg_one", "type": "message"]]])
        XCTAssertTrue(value.isPartial)
        XCTAssertEqual(try outputs(value).count, 1)
        XCTAssertFalse(value.json.formatted.contains("Foreign"))
    }

    func testSequencedReplayDoesNotDoubleAppendAndOutOfOrderDeltaIsExcluded() throws {
        var start = created(); start["sequence_number"] = 0
        var item = message(); item["sequence_number"] = 1
        var delta = text("Once"); delta["sequence_number"] = 2
        var stale = text("Out of order"); stale["sequence_number"] = 1
        let value = try combined([start, item, delta, delta, stale])
        let content = try XCTUnwrap(try outputs(value).first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Once")
        XCTAssertTrue(value.notice.contains("out-of-order"))
    }

    func testHeaderTypeFallbackAndUnfinishedCanonicalFrame() throws {
        let bytes = Data("event: response.completed\ndata: {\"response\":{\"id\":\"resp_one\",\"status\":\"completed\",\"output\":[]}}".utf8)
        let value = try XCTUnwrap(CombinedResponse.parse(XCTUnwrap(CapturedEventStream.parse(bytes))))
        XCTAssertTrue(value.isPartial)
        XCTAssertTrue(value.notice.contains("unfinished event frame"))
        XCTAssertEqual(try object(value)["status"] as? String, "completed")
    }

    func testMismatchedHeaderAndDataTypesDoNotMutatePartialOutput() throws {
        let stream = try stream([created(), message(), text("Safe")], tail: "event: response.output_item.done\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_one\",\"content_index\":0,\"delta\":\"Wrong\"}\n\n")
        let value = try XCTUnwrap(CombinedResponse.parse(stream))
        XCTAssertFalse(value.json.formatted.contains("Wrong"))
        XCTAssertTrue(value.notice.contains("Malformed"))
    }

    func testUnsupportedStreamsHaveNoCombinedResponse() throws {
        for events in [
            [["type": "message_start", "message": ["id": "anthropic"]] as [String: Any]],
            [["type": "response.future_extension", "payload": "unknown"]],
            [["type": "error", "message": "No response lifecycle"]]
        ] { XCTAssertNil(try CombinedResponse.parse(stream(events))) }
        XCTAssertNil(try CombinedResponse.parse(stream([], tail: "data: [DONE]\n\n")))
    }

    func testUnsupportedResponseEventsAreVisibleInNoticeAndTerminalStillAuthoritative() throws {
        let value = try combined([created(), ["type": "response.future_extension", "data": ["unmapped": true]], terminal()])
        XCTAssertFalse(value.isPartial)
        XCTAssertTrue(value.notice.contains("Additional event types"))
        XCTAssertTrue(value.notice.contains("terminal response object remains authoritative"))
    }

    func testExtremeAndInvalidIndicesAreRejectedWithoutAllocatingHugeArrays() throws {
        let value = try combined([created(), message(), text("Safe"), text("Huge", index: Int.max), text("Negative", content: -1),
            ["type": "response.output_text.delta", "output_index": true, "content_index": 0, "delta": "Boolean index"],
            ["type": "response.output_text.delta", "output_index": 0, "content_index": 1.5, "delta": "Fractional index"]])
        XCTAssertEqual(try outputs(value).count, 1)
        XCTAssertTrue(value.notice.contains("Malformed"))
        XCTAssertFalse(value.json.formatted.contains("Huge"))
        XCTAssertFalse(value.json.formatted.contains("Negative"))
        XCTAssertFalse(value.json.formatted.contains("Boolean index"))
        XCTAssertFalse(value.json.formatted.contains("Fractional index"))
    }

    func testSparseOutputAndContentIndicesKeepTheirPositions() throws {
        let value = try combined([created(), message(index: 2), text("Third item, second content", index: 2, content: 1)])
        let output = try XCTUnwrap(try object(value)["output"] as? [Any])
        XCTAssertEqual(output.count, 3)
        XCTAssertTrue(output[0] is NSNull)
        XCTAssertTrue(output[1] is NSNull)
        let content = try XCTUnwrap((output[2] as? [String: Any])?["content"] as? [Any])
        XCTAssertEqual(content.count, 2)
        XCTAssertTrue(content[0] is NSNull)
        XCTAssertTrue(value.isPartial)
    }

    func testManyUnicodeDeltasAreCombinedWithoutLosingBytes() throws {
        let count = 5_000
        let value = try combined([created(), message()] + Array(repeating: text("🌍é"), count: count))
        let content = try XCTUnwrap(try outputs(value).first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, String(repeating: "🌍é", count: count))
        XCTAssertTrue(value.isPartial)
    }

    func testCancellationStopsCombinationBeforeItPublishes() async throws {
        let stream = try stream([created(), message(), text("Never published")])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CombinedResponse.parse(stream)
        }
        do { _ = try await task.value; XCTFail("A cancelled parse cannot publish a combined response") }
        catch is CancellationError { }
    }
}
