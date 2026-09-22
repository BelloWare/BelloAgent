import XCTest
@testable import PiApp

/// Markdown has to be right at every token, not only when the reply finishes.
/// For a corpus of replies — headings, nested lists, fenced code with a
/// language, tables, links, inline code, emphasis, a long unbroken token and
/// non-Latin text — every prefix is streamed in and what the page would draw
/// is compared with `TranscriptMarkdown.parse` of that same prefix: the two
/// may differ in the one block that is still open, and nowhere else. The last
/// token leaves blocks identical to the parse of the whole reply.
final class MarkdownStreamingCorrectnessTests: XCTestCase {

    static let corpus: [(name: String, source: String)] = [
        ("headings and prose", """
        # Title

        First paragraph with **bold**, *italic*, `code` and a [link](https://example.com).

        ## Second level

        Closing line.
        """),
        ("nested lists", """
        Here is the plan:

        - First item
          - nested one
          - nested two
        - Second item with `code`

        1. Ordered one
        2. Ordered two

        Done.
        """),
        ("fenced code with a language", """
        Before the fence.

        ```swift
        func charge(_ order: Order) throws -> Receipt {
            return try gateway.charge(order)
        }
        ```

        After the fence.
        """),
        ("table", """
        Results:

        | Field | Before | After |
        |---|---:|---|
        | attempts | 1 | 3 |
        | logging | none | per attempt |

        That is all.
        """),
        ("quote and break", """
        A note:

        > quoted line
        > continuation

        Back to prose.
        """),
        ("one long unbroken token", """
        Identifier: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

        Then a short line.
        """),
        ("unicode", """
        中文标题 🙂 with e\u{301} and **粗体**.

        - 一
        - 二 🙂

        Ende.
        """),
        ("a long list that never closes", (0..<40).map { "- item \($0) with `code` and **bold** in it" }.joined(separator: "\n")),
        ("a fence with no blank line before it", """
        Intro line
        ```swift
        let a = 1
        ```
        After the fence.
        """),
        ("inline hazards", """
        A line with an unfinished [link]( and a `span that closes` later.

        Then **bold across
        a soft break** ends here.
        """)
    ]

    /// How the blocks a streaming reply would draw compare with the canonical
    /// parse of the same prefix: how many leading blocks agree, and what is
    /// left over on either side.
    private func compare(_ streamed: [MarkdownBlock], _ canonical: [MarkdownBlock]) -> (agreed: Int, streamedLeft: Int, canonicalLeft: Int) {
        var agreed = 0
        while agreed < streamed.count, agreed < canonical.count, streamed[agreed] == canonical[agreed] { agreed += 1 }
        return (agreed, streamed.count - agreed, canonical.count - agreed)
    }

    /// Every prefix of every reply, one byte at a time and one word at a time.
    private func assertPrefixesRenderCanonically(byWord: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0, openTailPrefixes = 0
        for (name, source) in Self.corpus {
            let state = StreamingMarkdownState()
            let bytes = Array(source.utf8)
            var offsets: [Int] = []
            if byWord {
                var cursor = 0
                for (index, byte) in bytes.enumerated() where byte == 0x20 || byte == 0x0a {
                    offsets.append(index + 1); cursor = index + 1
                }
                if cursor < bytes.count { offsets.append(bytes.count) }
            } else {
                offsets = Array(1...bytes.count)
            }
            for offset in offsets {
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                let streamed = state.update(prefix, style: .prose, streaming: true, identity: "reply").map(\.block)
                // Reading the tail token by token, keeping the blocks that
                // closed, must give exactly what reading it from nothing gives.
                XCTAssertEqual(streamed, TranscriptMarkdown.streamingBlocks(prefix),
                               "\(name) at \(offset) bytes: keeping the closed blocks of the tail changed what the page would draw",
                               file: file, line: line)
                let canonical = TranscriptMarkdown.parse(prefix)
                let result = compare(streamed, canonical)
                if result.streamedLeft > 0 || result.canonicalLeft > 0 { openTailPrefixes += 1 }
                // The only block that may read differently from the finished
                // reply is the one still arriving.
                XCTAssertLessThanOrEqual(result.streamedLeft, 1,
                                         "\(name) at \(offset) bytes: \(result.streamedLeft) streamed blocks disagree with the parse of the same prefix",
                                         file: file, line: line)
                XCTAssertLessThanOrEqual(result.canonicalLeft, 1,
                                         "\(name) at \(offset) bytes: \(result.canonicalLeft) parsed blocks are missing from what the page would draw",
                                         file: file, line: line)
                checked += 1
            }
            // The last token leaves exactly the finished reply.
            let streamed = state.update(source, style: .prose, streaming: true, identity: "reply").map(\.block)
            XCTAssertEqual(streamed, TranscriptMarkdown.parse(source), "\(name): the whole reply, still streaming", file: file, line: line)
            let settled = state.update(source, style: .prose, streaming: false, identity: "reply").map(\.block)
            XCTAssertEqual(settled, TranscriptMarkdown.parse(source), "\(name): the settled reply", file: file, line: line)
        }
        print("PERF markdown corpus \(byWord ? "word by word" : "byte by byte"): \(checked) prefixes checked over \(Self.corpus.count) replies, \(openTailPrefixes) of them with an open block")
        XCTAssertGreaterThan(checked, byWord ? 150 : 1_000, file: file, line: line)
    }

    func testEveryByteOfEveryReplyRendersAsTheParseOfThatPrefix() {
        assertPrefixesRenderCanonically(byWord: false)
    }

    func testEveryWordOfEveryReplyRendersAsTheParseOfThatPrefix() {
        assertPrefixesRenderCanonically(byWord: true)
    }

    /// A settled block never changes again, however the rest of the reply
    /// arrives: that is what lets the page keep its geometry and the reader's
    /// selection.
    func testSettledBlocksNeverChangeAgain() {
        for (name, source) in Self.corpus {
            let state = StreamingMarkdownState()
            let bytes = Array(source.utf8)
            var settled: [MarkdownBlockIdentity: MarkdownBlock] = [:]
            for offset in 1...bytes.count {
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                for record in state.update(prefix, style: .prose, streaming: true, identity: "reply") where !record.provisional {
                    if let previous = settled[record.id] {
                        XCTAssertEqual(previous, record.block, "\(name): a settled block changed at \(offset) bytes")
                    }
                    settled[record.id] = record.block
                }
            }
            // A reply with no blank line in it has nothing to settle: the
            // whole of it is still open until it finishes.
            XCTAssertEqual(settled.isEmpty, !source.contains("\n\n"), "\(name): what settled does not match where the blank lines are")
        }
    }

    /// Nothing is lost and nothing is shown twice: the records' source ranges
    /// tile the reply's bytes in order.
    func testTheRecordsCoverTheSourceExactlyOnce() {
        for (name, source) in Self.corpus {
            let bytes = Array(source.utf8)
            let state = StreamingMarkdownState()
            for offset in stride(from: 1, through: bytes.count, by: 3) {
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                let records = state.update(prefix, style: .prose, streaming: true, identity: "reply")
                var cursor = 0
                for record in records {
                    XCTAssertGreaterThanOrEqual(record.range.lowerBound, cursor, "\(name): overlapping ranges at \(offset) bytes")
                    cursor = max(cursor, record.range.upperBound)
                }
                XCTAssertLessThanOrEqual(cursor, prefix.utf8.count, "\(name): a range ran past the source at \(offset) bytes")
            }
        }
    }

    /// What the tail costs to re-read, by how much of the reply is still open.
    /// The tail is everything since the last blank line, so this is the figure
    /// that decides whether a token can stay inside its frame.
    func testWhatReParsingTheTailCosts() {
        for lines in [4, 16, 64, 256] {
            let tail = (0..<lines).map { "- item \($0) with `code` and **bold** text in it" }.joined(separator: "\n")
            let state = StreamingMarkdownState()
            _ = state.update(tail, style: .prose, streaming: true, identity: "cost")
            let rounds = 20
            var whole = ProcessInfo.processInfo.systemUptime
            for round in 0..<rounds { _ = TranscriptMarkdown.streamingBlocks(tail + " \(round)") }
            whole = (ProcessInfo.processInfo.systemUptime - whole) / Double(rounds)
            // The same growth through one state, which keeps the blocks of the
            // tail that have closed: what a token actually costs.
            var text = tail
            var token = ProcessInfo.processInfo.systemUptime
            for round in 0..<rounds { text += " x\(round)"; _ = state.update(text, style: .prose, streaming: true, identity: "cost") }
            token = (ProcessInfo.processInfo.systemUptime - token) / Double(rounds)
            print(String(format: "PERF re-reading a %d-byte open tail (%d list items): %.2f ms from nothing, %.2f ms per token (%d tails kept, %d read whole)",
                         tail.utf8.count, lines, whole * 1000, token * 1000, state.tailReuseCount, state.tailFullReadCount))
        }
    }
}
