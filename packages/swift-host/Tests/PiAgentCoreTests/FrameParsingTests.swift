import XCTest
@testable import PiAgentCore

/// The two framings the helper reads: NDJSON commands from the app and SSE
/// events from a gateway. Both must survive arriving one byte at a time and
/// must never invent a frame the sender did not finish.
final class FrameParsingTests: XCTestCase {
    func testMaximalJSONEscapedSubmissionSurvivesWholeAndSplitInputFrames() throws {
        let text = String(repeating: "\u{001b}", count: 256 * 1024)
        let frame: JSON = ["v": 1, "kind": "command", "hostEpoch": "fixture", "commandId": "edit", "sessionId": "s", "method": "turn.edit",
                           "params": ["text": JSON(text), "draft": ["text": JSON(text)], "clientTurnId": "t", "messageId": "m"]]
        var bytes = try frame.data()
        XCTAssertGreaterThan(bytes.count, 3 * 1024 * 1024, "Each source byte expands to six JSON bytes, twice for an edit envelope")
        print("SUBMISSION sourceBytes=\(text.utf8.count) encodedFrameBytes=\(bytes.count)")
        bytes.append(10)
        for pageSize in [bytes.count, 16_384] {
            var decoder = NDJSONDecoder(), decoded: [JSON] = []
            for offset in stride(from: 0, to: bytes.count, by: pageSize) {
                decoded += try decoder.feed(bytes.subdata(in: offset..<min(offset + pageSize, bytes.count)))
            }
            try decoder.finish()
            XCTAssertEqual(decoded, [frame])
        }
    }

    func testCommandFramingStillRejectsOversizedAndUnterminatedInput() throws {
        for terminated in [false, true] {
            var decoder = NDJSONDecoder(), bytes = Data(repeating: 32, count: HostProtocol.commandFrameBytes + 1)
            if terminated { bytes.append(10) }
            XCTAssertThrowsError(try decoder.feed(bytes))
        }
    }

    func testNDJSONSplitEveryByteAndTruncatedTail() throws {
        let source=Data("{\"text\":\"中文🙂\"}\n{\"a\":1}\n".utf8)
        var decoder=NDJSONDecoder(),result:[JSON]=[]
        for b in source { result += try decoder.feed(Data([b])) }
        try decoder.finish();XCTAssertEqual(result.count,2)
        XCTAssertEqual(result[0]["text"].text,"中文🙂")
        var incomplete=NDJSONDecoder();_ = try incomplete.feed(Data("{\"a\":1}".utf8));XCTAssertThrowsError(try incomplete.finish())
        var empty=NDJSONDecoder();XCTAssertThrowsError(try empty.feed(Data([10])))
    }
    func testSSEEverySplitIncludesCRLFAndUnicode() throws {
        let source=Data("\u{FEFF}event: delta\r\ndata: {\"text\":\"你好🙂\"}\r\n\r\ndata: first\ndata: second\n\n".utf8)
        for split in 0...source.count {
            var parser=SSEParser();let events=try parser.feed(Data(source.prefix(split)))+parser.feed(Data(source.dropFirst(split)))
            XCTAssertEqual(events.count,2,"split \(split)")
            XCTAssertEqual(events[0].data,"{\"text\":\"你好🙂\"}")
            XCTAssertEqual(events[1].data,"first\nsecond")
        }
    }
    func testSSEDoesNotInventTerminalOrInvalidUTF8() throws {
        var parser=SSEParser();XCTAssertTrue(try parser.feed(Data("data: unfinished".utf8)).isEmpty)
        var bad=SSEParser();XCTAssertThrowsError(try bad.feed(Data([100,97,116,97,58,32,255,10,10])))
    }
}
