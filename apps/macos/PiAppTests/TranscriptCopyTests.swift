import XCTest
@testable import PiApp

final class TranscriptCopyTests: XCTestCase {
    private func request(_ message: TranscriptMessage, source: String? = nil, field: String = "text", ranges: [[String: Any]]) -> [String: Any] {
        ["id": message.id, "field": field, "source": source ?? (field == "thinking" ? message.thinking ?? "" : message.text), "ranges": ranges]
    }
    private func range(_ substring: String, in source: String) -> [String: Any] {
        let value = (source as NSString).range(of: substring)
        return ["start": value.location, "end": NSMaxRange(value)]
    }
    func testCopiesOriginalCodeAndMarkdownWithoutFormattingOrAdjacentSection() {
        let code = "let earth = \"🌍\";  \r\nprint(\"<script>\")\r\n"
        let section = "## Install\r\n\r\n```swift\r\n" + code + "```\r\n\r\n"
        let message = TranscriptMessage(id: "reply", role: "assistant", text: section + "## Next\r\nUnrelated")
        XCTAssertEqual(TranscriptClipboard.content(request(message, ranges: [range(code, in: message.text)]), messages: [message]), code)
        XCTAssertEqual(TranscriptClipboard.content(request(message, ranges: [range(section, in: message.text)]), messages: [message]), section)
    }
    func testOrderedRangesRemoveOnlyMarkdownContainerPrefixesAndThinkingIsSeparate() {
        let message = TranscriptMessage(id: "reply", role: "assistant", text: "> ```sh\n> echo one\n>   echo two\n> ```", thinking: "## Explanation\nA visible summary.")
        let ranges = [range("echo one\n", in: message.text), range("  echo two\n", in: message.text)]
        XCTAssertEqual(TranscriptClipboard.content(request(message, ranges: ranges), messages: [message]), "echo one\n  echo two\n")
        let thinking = message.thinking!
        XCTAssertEqual(TranscriptClipboard.content(request(message, field: "thinking", ranges: [range(thinking, in: thinking)]), messages: [message]), thinking)
        XCTAssertNil(TranscriptClipboard.content(request(message, source: thinking, ranges: [range(thinking, in: thinking)]), messages: [message]))
    }
    func testStreamingChangesAndUnicodeNormalizationRejectStaleSelections() {
        let original = TranscriptMessage(id: "stream:one", role: "assistant", text: "# Answer\nPartial", state: "streaming")
        let body = request(original, ranges: [range(original.text, in: original.text)])
        var latest = original; latest.text += " and complete."
        XCTAssertNil(TranscriptClipboard.content(body, messages: [latest]))
        XCTAssertEqual(TranscriptClipboard.content(request(latest, ranges: [range(latest.text, in: latest.text)]), messages: [latest]), latest.text)
        let composed = TranscriptMessage(id: "unicode", role: "assistant", text: "é")
        XCTAssertNil(TranscriptClipboard.content(request(composed, source: "e\u{301}", ranges: [["start": 0, "end": 1]]), messages: [composed]))
    }
    func testRejectsMalformedRangesAndSurrogateSplits() {
        let message = TranscriptMessage(id: "reply", role: "assistant", text: "x🌍y")
        let invalid: [[[String: Any]]] = [[], [["start": -1, "end": 1]], [["start": 0, "end": 0]], [["start": 0, "end": 5]],
            [["start": 1, "end": 2]], [["start": 2, "end": 3]], [["start": 0.5, "end": 1]], [["start": false, "end": 1]],
            [["start": "0", "end": 1]], [["start": Double.nan, "end": 1]], [["start": 0, "end": Double.infinity]],
            [["start": 0, "end": 3], ["start": 1, "end": 4]], [["start": 3, "end": 4], ["start": 0, "end": 1]]]
        for ranges in invalid { XCTAssertNil(TranscriptClipboard.content(request(message, ranges: ranges), messages: [message]), "Accepted malformed ranges: \(ranges)") }
        XCTAssertEqual(TranscriptClipboard.content(request(message, ranges: [["start": 1, "end": 3]]), messages: [message]), "🌍")
    }
    func testUnknownMessagesAndFieldsCannotSupplyArbitraryClipboardText() {
        let message = TranscriptMessage(id: "reply", role: "assistant", text: "Original")
        var body = request(message, ranges: [range(message.text, in: message.text)])
        body["text"] = "Arbitrary replacement"
        XCTAssertEqual(TranscriptClipboard.content(body, messages: [message]), "Original")
        body["id"] = "another-chat"
        XCTAssertNil(TranscriptClipboard.content(body, messages: [message]))
        XCTAssertNil(TranscriptClipboard.content(request(message, field: "requestBody", ranges: [["start": 0, "end": 1]]), messages: [message]))
    }
    func testCopyPayloadAndRangeCountStayBounded() {
        let large = TranscriptMessage(id: "large", role: "assistant", text: String(repeating: "🌍", count: 16_385))
        XCTAssertNil(TranscriptClipboard.content(request(large, ranges: [["start": 0, "end": 2]]), messages: [large]))
        let normal = TranscriptMessage(id: "normal", role: "assistant", text: String(repeating: "x", count: 8_194))
        let ranges = (0..<4_097).map { ["start": $0 * 2, "end": $0 * 2 + 1] as [String: Any] }
        XCTAssertNil(TranscriptClipboard.content(request(normal, ranges: ranges), messages: [normal]))
        let longID = TranscriptMessage(id: String(repeating: "x", count: 257), role: "assistant", text: "x")
        XCTAssertNil(TranscriptClipboard.content(request(longID, ranges: [["start": 0, "end": 1]]), messages: [longID]))
    }
}
