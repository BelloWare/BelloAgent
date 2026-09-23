import XCTest
@testable import PiAgentCore

/// The streaming row is built and sized without the encoder; these hold the
/// direct forms to exactly what the encoder produces.
final class ResponseTimelineJSONTests: XCTestCase {
    func testCountedSizeIsTheEncodedSizeForEveryCharacterClass() throws {
        var samples: [String] = ["", "plain", "\"quoted\"", "back\\slash", "slash/", "tab\tnew\nline\r", "\u{08}\u{0C}", "中文🦉👩‍👩‍👧", "\u{2028}\u{2029}\u{7F}\u{FEFF}"]
        samples.append(String((0..<128).map { Character(UnicodeScalar(UInt8($0))) }))
        for text in samples {
            XCTAssertEqual(JSONSize.string(text), try JSON.string(text).data().count, text.debugDescription)
            // Every scalar boundary: where one appended string ends and the next begins.
            let boundaries = text.unicodeScalars.reduce(into: [0]) { $0.append($0.last! + String($1).utf8.count) }
            for split in boundaries {
                let head = String(decoding: text.utf8.prefix(split), as: UTF8.self), tail = try XCTUnwrap(utf8Suffix(text, from: split))
                XCTAssertEqual(head + tail, text)
                XCTAssertEqual(JSONSize.escaped(head.utf8) + JSONSize.escaped(tail.utf8), JSONSize.escaped(text.utf8), "sizes add up across an append")
            }
        }
        for number in [0.0, -0.0, 1, -3, 42, 1e14, 999_999_999_999_999, 1e15, 1e20, 0.1, -2.5, 123456.789, 1727000000123.456] {
            XCTAssertEqual(JSONSize.value(.number(number)), try JSON.number(number).data().count, "\(number)")
        }
        let value: JSON = ["a": [1, "two", ["x": JSON.null, "y": true, "z": false]], "b": "\"q\"\n", "empty": [:], "list": []]
        XCTAssertEqual(JSONSize.value(value), try value.data().count)
        let pair: JSON = ["a": 1, "b": "text"]
        XCTAssertEqual(JSONSize.object(["a": 1], sized: ["b": JSONSize.value("text")]), try pair.data().count)
        XCTAssertNil(utf8Suffix("ab", from: 3)); XCTAssertEqual(utf8Suffix("ab", from: 2), "")
    }

    func testDirectTimelineJSONIsTheEncodedTimeline() throws {
        var timeline = ResponseTimeline()
        var event = ResponsePartEvent(attemptID: "a", ordinal: 1, itemID: "item", outputIndex: 0, partIndex: 0, providerSequence: 7, kind: "text", update: "append",
                                      text: "Hello \"there\"\n", callID: nil, name: nil, observedAt: 12345.678)
        event.sessionOrdinal = 3
        timeline.consume(event)
        timeline.consume(ResponsePartEvent(attemptID: "a", ordinal: 2, itemID: "call", outputIndex: 1, partIndex: nil, kind: "toolArguments", update: "append",
                                           text: "{\"path\":\"中文\"}", callID: "call-1", name: "write"))
        timeline.consume(ResponsePartEvent(attemptID: "a", ordinal: 3, itemID: "item", outputIndex: 0, partIndex: 0, kind: "text", update: "replace", text: "different"))
        let encoded = try JSON.parse(JSONEncoder().encode(timeline))
        XCTAssertEqual(timeline.displayJSON, encoded)
        XCTAssertTrue(timeline.segments.contains { $0.part.reconcilesPartKey != nil }, "the correction segment carries every optional field")
        timeline.finish("completed")
        XCTAssertEqual(timeline.displayJSON, try JSON.parse(JSONEncoder().encode(timeline)), "a terminal is included once set")
        for segment in timeline.segments {
            XCTAssertEqual(segment.displayJSON, try JSON.parse(JSONEncoder().encode(segment)))
            XCTAssertEqual(JSONSize.value(segment.displayJSON), try segment.displayJSON.data().count)
        }
    }
}
