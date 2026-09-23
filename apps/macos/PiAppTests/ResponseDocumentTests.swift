import XCTest
@testable import PiApp

/// How the Response tab reads a response body: the text, the reasoning the
/// provider shared, the calls, why it stopped and what it reported using.
final class ResponseDocumentTests: XCTestCase {
    private func sse(_ events: [(String, String)]) -> Data {
        Data(events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined().utf8)
    }
    private let usage = #"{"input_tokens":18240,"input_tokens_details":{"cached_tokens":15112},"output_tokens":1104,"output_tokens_details":{"reasoning_tokens":640},"total_tokens":19344}"#
    private var items: String {
        #"[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Look at the README."}]},"# +
        #"{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"The README describes the fixture.","annotations":[]}]},"# +
        #"{"id":"fc_1","type":"function_call","call_id":"call_9","name":"bash","arguments":"{\"command\":\"ls\"}","status":"completed"}]"#
    }
    private func stream(terminal: Bool) -> Data {
        var events: [(String, String)] = [
            ("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress","model":"gpt-5.4","output":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#),
            ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","sequence_number":2,"item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","sequence_number":3,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Look at the README."}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":4,"output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","sequence_number":5,"item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":6,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"The README "}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":7,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"describes the fixture."}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":8,"output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_9","name":"bash","arguments":""}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","sequence_number":9,"item_id":"fc_1","output_index":2,"delta":"{\"command\":\"ls\"}"}"#)
        ]
        if terminal {
            events.append(("response.completed", #"{"type":"response.completed","sequence_number":10,"response":{"id":"resp_1","status":"completed","model":"gpt-5.4","output":"# + items + #","usage":"# + usage + "}}"))
        }
        return sse(events)
    }

    func testAResponsesStreamReadsAsReasoningTextAndCalls() throws {
        let document = try XCTUnwrap(try ResponseDocument.parse(stream(terminal: true)))
        XCTAssertEqual(document.status, "completed"); XCTAssertNil(document.finish); XCTAssertEqual(document.model, "gpt-5.4")
        XCTAssertFalse(document.partial)
        XCTAssertEqual(document.items.map(\.kind), [.reasoning, .assistant, .toolCall])
        guard document.items.count == 3 else { return XCTFail("3 items expected") }
        XCTAssertEqual(document.items.map(\.title), ["Reasoning summary", "Assistant", "bash"])
        XCTAssertEqual(document.items[0].preview, "Look at the README.")
        XCTAssertEqual(document.items[1].preview, "The README describes the fixture.")
        XCTAssertEqual(document.items[2].detail, "command: ls")
        XCTAssertEqual(document.items[2].callID, "call_9")
        XCTAssertEqual(document.usage.map(\.name), ["Input", "Cached input", "Output", "Reasoning", "Total"])
        XCTAssertEqual(document.usage.map(\.value), ["18,240", "15,112", "1,104", "640", "19,344"])
        XCTAssertEqual(document.summary, "Completed · 1,104 output tokens (640 reasoning)")
        XCTAssertEqual(try document.fullText(item: 1), "The README describes the fixture.")
    }

    func testAStreamWithoutItsTerminalEventIsPartial() throws {
        let document = try XCTUnwrap(try ResponseDocument.parse(stream(terminal: false)))
        XCTAssertTrue(document.partial)
        XCTAssertEqual(document.status, "in_progress")
        XCTAssertEqual(document.items.map(\.kind), [.reasoning, .assistant, .toolCall], "Everything that arrived is shown")
        guard document.items.count == 3 else { return XCTFail("3 items expected") }
        XCTAssertEqual(document.items[1].preview, "The README describes the fixture.")
        XCTAssertTrue(document.usage.isEmpty)
        XCTAssertTrue(document.summary.hasPrefix("In progress"), document.summary)
        XCTAssertNotNil(document.notice)
    }

    func testAnIncompleteJSONResponseNamesWhyItStopped() throws {
        let body = #"{"id":"resp_2","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"model":"gpt-5.4","# +
            #""output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial answer"}]}],"# +
            #""usage":{"input_tokens":100,"output_tokens":300,"total_tokens":400}}"#
        let document = try XCTUnwrap(try ResponseDocument.parse(Data(body.utf8)))
        XCTAssertEqual(document.status, "incomplete"); XCTAssertEqual(document.finish, "max_output_tokens")
        XCTAssertFalse(document.partial)
        XCTAssertEqual(document.items.map(\.preview), ["Partial answer"])
        XCTAssertEqual(document.usage.map(\.name), ["Input", "Output", "Total"])
        XCTAssertEqual(document.summary, "Incomplete · max_output_tokens · 300 output tokens")
    }

    func testAMessagesStreamIsReconstructedBlockByBlock() throws {
        let data = sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-x","content":[],"stop_reason":null,"usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Reading "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the README."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)])
        let document = try XCTUnwrap(try ResponseDocument.parse(data))
        XCTAssertEqual(document.model, "claude-x"); XCTAssertEqual(document.status, "completed"); XCTAssertEqual(document.finish, "tool_use")
        XCTAssertFalse(document.partial)
        XCTAssertEqual(document.items.map(\.kind), [.assistant, .toolCall])
        guard document.items.count == 2 else { return XCTFail("2 items expected") }
        XCTAssertEqual(document.items[0].preview, "Reading the README.")
        XCTAssertEqual(document.items[1].title, "read"); XCTAssertEqual(document.items[1].detail, "path: README.md")
        XCTAssertEqual(document.usage.map(\.name), ["Input", "Cached input", "Output"])
        XCTAssertEqual(document.usage.map(\.value), ["2,000", "800", "42"])
        XCTAssertEqual(document.summary, "Completed · tool_use · 42 output tokens")
    }

    func testABodyThatIsNeitherJSONNorAnEventStreamHasNoDocument() throws {
        XCTAssertNil(try ResponseDocument.parse(Data("plain text".utf8)))
        XCTAssertNil(try ResponseDocument.parse(Data()))
    }
}
