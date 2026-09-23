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
        """),
        // The reply's last token is its closing fence: nothing after it ever
        // settles the block, so the stream itself must end on the finished one.
        ("a reply that ends in a fence", """
        Here is the fix:

        ```swift
        let a = 1
        let b = 2
        ```
        """),
        ("a reply that ends in a longer tilde fence", """
        Output:

        ~~~
        ok
        ~~~~
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

    // MARK: A closing fence still arriving

    /// The code a streamed reply shows in its first fence, token by token.
    private func streamedCode(_ source: String, step: Int = 1) -> [(offset: Int, code: String)] {
        let state = StreamingMarkdownState()
        let bytes = Array(source.utf8)
        var result: [(offset: Int, code: String)] = []
        for offset in stride(from: 1, through: bytes.count, by: step) {
            guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
            for record in state.update(prefix, style: .prose, streaming: true, identity: "fence") {
                if case .code(_, let code) = record.block { result.append((offset, code)); break }
            }
        }
        return result
    }

    /// A closing fence arrives a marker at a time. Until the line is a close
    /// it could still become one, so it is not code: drawing it as a line of
    /// code grows the block by a line that the next token takes away again.
    /// Once the run is as long as the opening one it is the close, and the
    /// block the stream draws is the block the finished reply parses to.
    func testAClosingFenceStillArrivingIsNeverDrawnAsCode() {
        let cases: [(opening: String, closings: [String])] = [
            ("```swift\nlet a = 1\n", ["`", "``", "```", "````", "``` ", "   ```", " ``"]),
            ("~~~~\nlet a = 1\n", ["~", "~~", "~~~", "~~~~", "~~~~~"])
        ]
        for (opening, closings) in cases {
            for closing in closings {
                let source = opening + closing
                let blocks = StreamingMarkdownState().update(source, style: .prose, streaming: true, identity: "fence").map(\.block)
                XCTAssertEqual(blocks.count, 1, "\(source.debugDescription): \(blocks)")
                guard case .code(_, let code)? = blocks.first else { XCTFail("\(source.debugDescription) is not a code block: \(blocks)"); continue }
                XCTAssertEqual(code, "let a = 1", "\(source.debugDescription): a closing fence that is still arriving was drawn as code")
            }
        }
        for source in ["```swift\nlet a = 1\n```", "~~~~\nlet a = 1\n~~~~~", "```\nlet a = 1\n   ```  "] {
            XCTAssertEqual(StreamingMarkdownState().update(source, style: .prose, streaming: true, identity: "fence").map(\.block),
                           TranscriptMarkdown.parse(source), "\(source.debugDescription): a complete close must read as the finished reply")
        }
        // A line that can no longer close the fence is code, and is shown.
        for (line, code) in [("``x", "let a = 1\n``x"), ("    ```", "let a = 1\n    ```"), ("~~~", "let a = 1\n~~~"), ("`` ", "let a = 1\n`` ")] {
            let blocks = StreamingMarkdownState().update("```swift\nlet a = 1\n" + line, style: .prose, streaming: true, identity: "fence").map(\.block)
            XCTAssertEqual(blocks, [.code(language: "swift", code: code)], "\(line.debugDescription) cannot close a ``` fence")
        }
    }

    /// Over consecutive tokens, the code a fence shows only ever grows: every
    /// token's code is a prefix of the finished block's code, so no line is
    /// drawn and then taken away again. Nor does the blank line after a closed
    /// fence become a block of its own for a token: an empty paragraph there
    /// is a line the finished reply does not have.
    func testAFenceNeverShowsALineTheNextTokenTakesAway() {
        for (name, source) in [("ends in a fence", "Here:\n\n```swift\nlet a = 1\nlet b = 2\n```"),
                               ("fence then prose", "Here:\n\n```swift\nlet a = 1\n```\n\nAfter the fence."),
                               ("tilde fence", "~~~~python\nprint(1)\n~~~~\n"),
                               ("fence and trailing blank lines", "Here:\n\n```swift\nlet a = 1\n```\n\n\n")] {
            let state = StreamingMarkdownState()
            let bytes = Array(source.utf8)
            for offset in 1...bytes.count {
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                for case .paragraph(let text) in state.update(prefix, style: .prose, streaming: true, identity: "gap").map(\.block) {
                    XCTAssertFalse(String(text.characters).allSatisfy(\.isWhitespace),
                                   "\(name) at \(offset) bytes: an empty paragraph was drawn for the gap after the fence")
                }
            }
            XCTAssertEqual(state.update(source, style: .prose, streaming: true, identity: "gap").map(\.block), TranscriptMarkdown.parse(source),
                           "\(name): the whole reply, still streaming, reads as the finished one")
            let final = TranscriptMarkdown.parse(source).compactMap { block -> String? in
                if case .code(_, let code) = block { return code }; return nil
            }.first
            guard let final else { XCTFail("\(name): the finished reply has no code block"); continue }
            var shown = 0
            for (offset, code) in streamedCode(source) {
                XCTAssertTrue(final.hasPrefix(code),
                              "\(name) at \(offset) bytes: the fence shows \(code.debugDescription), which the finished block \(final.debugDescription) does not begin with")
                let lines = code.isEmpty ? 0 : code.split(separator: "\n", omittingEmptySubsequences: false).count
                XCTAssertGreaterThanOrEqual(lines, shown, "\(name) at \(offset) bytes: the fence lost a line it had drawn")
                shown = lines
            }
        }
    }

    // MARK: An open block past the parse limit

    /// A list or table that keeps growing without a blank line passes the
    /// tail's parse limit. What it has drawn formatted stays formatted: the
    /// items it already shows as a list never turn into raw "- " and "**"
    /// text. Read an entry at a time, it never meets the limit at all — past
    /// it, the whole block still reads as the parse does — and the finished
    /// reply is the canonical parse.
    func testAnOpenListOrTablePastTheParseLimitNeverTurnsFormattedTextRaw() {
        let list = (0..<400).map { "- item \($0) with `code` and **bold** in it" }.joined(separator: "\n")
        let table = "| Field | Before | After |\n|---|---:|---|\n" + (0..<400).map { "| row \($0) | `\($0)` | **\($0 * 2)** |" }.joined(separator: "\n")
        for (name, block) in [("list", list), ("table", table)] {
            XCTAssertGreaterThan(block.utf8.count, StreamingMarkdownState.tailParseLimit + 3_000, "the fixture must pass the limit")
            let source = "Intro.\n\n" + block + "\n\nDone."
            let state = StreamingMarkdownState()
            let bytes = Array(source.utf8)
            // Every token below the limit reads the whole block again, so the
            // stream starts a little short of it, crosses it a few bytes at a
            // time and then runs to the end in longer steps.
            let limit = 8 + StreamingMarkdownState.tailParseLimit
            var formatted = 0, offset = limit - 600, seed: UInt64 = 7, step = 0
            var passedTheLimit = false
            while offset < bytes.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                offset = min(bytes.count, offset + (offset < limit + 3_000 ? 1 + Int((seed >> 33) % 24) : 311))
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                let blocks = state.update(prefix, style: .prose, streaming: true, identity: name).map(\.block)
                // Read an entry at a time, the block never meets the limit at
                // all: past it, it still reads exactly as the parse does.
                step += 1
                if offset >= limit + 3_000 || step % 20 == 0 {
                    XCTAssertEqual(blocks, TranscriptMarkdown.parse(prefix), "\(name) at \(offset) bytes: the open \(name) must read as the parse")
                }
                // How much of the block is drawn formatted: list items, or table rows.
                let count = blocks.reduce(0) { sum, block in
                    switch block {
                    case .list(_, _, let items): return sum + items.count
                    case .table(_, _, let rows): return sum + rows.count
                    default: return sum
                    }
                }
                XCTAssertGreaterThanOrEqual(count, formatted,
                                            "\(name) at \(offset) bytes: \(formatted - count) of the \(formatted) \(name) entries drawn formatted became raw text")
                formatted = max(formatted, count)
                if offset > 8 + StreamingMarkdownState.tailParseLimit + 200 { passedTheLimit = true }
            }
            XCTAssertTrue(passedTheLimit)
            XCTAssertEqual(state.update(source, style: .prose, streaming: true, identity: name).map(\.block), TranscriptMarkdown.parse(source),
                           "\(name): once the block has closed, the reply reads as the finished parse")
            XCTAssertEqual(state.update(source, style: .prose, streaming: false, identity: name).map(\.block), TranscriptMarkdown.parse(source))
        }
    }

    // MARK: Lists and tables, a token at a time

    /// Replies made of lists and tables: nested and loose lists, code inside
    /// items, ordered lists with wide markers and lazy lines, a list ended by
    /// a heading, and tables. An open list is read an item at a time and an
    /// open table a row at a time, so these hold the reading to the parse.
    static let listCorpus: [(name: String, source: String)] = [
        ("nested lists", """
        Plan:

        1. Parse the input
           - read the header
           - validate **each** field
             - reject `NaN`
        2. Transform it
           - map fields
        3. Write the result

        Done.
        """),
        ("a loose list", """
        - First point, with a paragraph.

          A second paragraph in the same item.

        - Second point.

        - Third point with `code`.
        """),
        ("code blocks inside items", """
        Steps:

        1. Install:
           ```bash
           npm install
           ```
        2. Run the tests:
           ```bash
           npm test -- --watch
           ```
        3. Check the output.
        """),
        ("a table", """
        Results:

        | Field | Before | After |
        |---|---:|:---:|
        | attempts | 1 | 3 |
        | logging | none | per **attempt** |
        | cost | `$0.01` | `$0.03` |

        That is all.
        """),
        ("a long tight list", (0..<24).map { "- item \($0) with `code` and **bold** in it" }.joined(separator: "\n")),
        ("wide ordered markers and lazy lines", """
        8. eight
        9. nine
        continued lazily
        10. ten
        11. eleven with [a link](https://example.com)
        """),
        ("a list, a heading, a list", """
        - a
        - b
        # Heading
        * c
        * d
        """),
        ("a table that ends the reply", "| a | b |\n|---|---|\n| 1 | 2 |\n| **3** | `4` |")
    ]

    /// How many list items and table rows the blocks draw formatted.
    static func formattedEntries(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { sum, block in
            switch block {
            case .list(_, _, let items): return sum + items.count + items.reduce(0) { $0 + formattedEntries($1) }
            case .quote(let inner): return sum + formattedEntries(inner)
            case .table(_, _, let rows): return sum + rows.count
            default: return sum
            }
        }
    }

    /// Every prefix, a byte at a time, and three streams of tokens of one to
    /// nine bytes — a token that jumps from "2" to "2. step" reads the text
    /// differently from one that stops at "2." — hold the reading to the
    /// parse: it equals a fresh reading of the same text, differs from the
    /// parse of that prefix in the one block still open at most, never turns
    /// a list item or table row it has drawn back into raw text, and keeps
    /// every settled block and every identity. The finished reply is the parse.
    func testListHeavyRepliesRenderAsTheirParseAtEveryPrefix() {
        var checked = 0
        for (sample, source) in Self.listCorpus { for pass in 0..<4 {
            let name = pass == 0 ? sample : "\(sample) (tokens \(pass))"
            let state = StreamingMarkdownState()
            let bytes = Array(source.utf8)
            var offsets: [Int] = [], at = 0, seed = UInt64(pass) &* 0x9E3779B97F4A7C15
            while at < bytes.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                at = min(bytes.count, at + (pass == 0 ? 1 : 1 + Int((seed >> 33) % 9)))
                offsets.append(at)
            }
            var formatted = 0
            var settled: [MarkdownBlockIdentity: MarkdownBlock] = [:]
            for offset in offsets {
                guard let prefix = String(bytes: bytes[0..<offset], encoding: .utf8) else { continue }
                let records = state.update(prefix, style: .prose, streaming: true, identity: "lists")
                let streamed = records.map(\.block)
                XCTAssertEqual(streamed, TranscriptMarkdown.streamingBlocks(prefix),
                               "\(name) at \(offset) bytes: reading token by token differs from reading the same text afresh")
                let canonical = TranscriptMarkdown.parse(prefix)
                var agreed = 0
                while agreed < streamed.count, agreed < canonical.count, streamed[agreed] == canonical[agreed] { agreed += 1 }
                XCTAssertLessThanOrEqual(streamed.count - agreed, 1, "\(name) at \(offset) bytes: streamed blocks disagree with the parse")
                XCTAssertLessThanOrEqual(canonical.count - agreed, 1, "\(name) at \(offset) bytes: parsed blocks are missing")
                let entries = Self.formattedEntries(streamed)
                XCTAssertGreaterThanOrEqual(entries, formatted, "\(name) at \(offset) bytes: a list item or table row drawn formatted became raw")
                formatted = max(formatted, entries)
                XCTAssertEqual(Set(records.map(\.id)).count, records.count, "\(name) at \(offset) bytes: two blocks share an identity")
                for record in records where !record.provisional {
                    if let previous = settled[record.id] { XCTAssertEqual(previous, record.block, "\(name): a settled block changed at \(offset) bytes") }
                    settled[record.id] = record.block
                }
                checked += 1
            }
            XCTAssertEqual(state.update(source, style: .prose, streaming: true, identity: "lists").map(\.block), TranscriptMarkdown.parse(source),
                           "\(name): the whole reply, still streaming")
            XCTAssertEqual(state.update(source, style: .prose, streaming: false, identity: "lists").map(\.block), TranscriptMarkdown.parse(source),
                           "\(name): the settled reply")
        } }
        print("PERF list-heavy corpus: \(checked) prefixes checked over \(Self.listCorpus.count) replies, a byte at a time and in three streams of tokens")
        XCTAssertGreaterThan(checked, 2_500)
    }

    /// A numbered step whose last line is a closing fence: the next step's
    /// number arrives on its own first, and "2" alone after a closed fence is
    /// a paragraph that ends the list. When ". Run" arrives the list has to
    /// take the step back — not draw it as a second list that starts at 2,
    /// which the reply kept until the list settled.
    func testANumberedStepAfterACodeBlockStaysInItsList() {
        let steps = "1. Install:\n   ```bash\n   npm install\n   ```\n"
        let state = StreamingMarkdownState()
        _ = state.update(steps, style: .prose, streaming: true, identity: "steps")
        let alone = state.update(steps + "2", style: .prose, streaming: true, identity: "steps").map(\.block)
        XCTAssertEqual(alone, TranscriptMarkdown.parse(steps + "2"))
        for next in ["2. Run", "2. Run the tests", "2. Run the tests:\n   ```bash\n   npm test\n   ```\n3. Check"] {
            let blocks = state.update(steps + next, style: .prose, streaming: true, identity: "steps").map(\.block)
            XCTAssertEqual(blocks, TranscriptMarkdown.parse(steps + next), "\(next.debugDescription): the step must be read as the parse reads it")
            guard blocks.count == 1, case .list(true, 1, let items) = blocks[0] else {
                XCTFail("\(next.debugDescription): the steps are one numbered list, not \(blocks.count) blocks"); continue
            }
            XCTAssertEqual(items.count, next.hasSuffix("Check") ? 3 : 2)
        }
    }

    /// A token on an open list or table reads the entry still arriving, not
    /// the block: the one at 7.5 KB costs what the one at 1 KB costs. Before,
    /// every token parsed the whole open block again, which near the parse
    /// limit is a frame or more on every token.
    func testATokenOnAnOpenListOrTableCostsTheSameAtOneAndSevenAndAHalfKilobytes() {
        func list(_ bytes: Int) -> String {
            var lines: [String] = [], size = 0
            while size < bytes { let line = "- item \(lines.count) with `code` and **bold** text in it"; lines.append(line); size += line.utf8.count + 1 }
            return lines.joined(separator: "\n")
        }
        func table(_ bytes: Int) -> String {
            var lines = ["| Field | Before | After |", "|---|---:|:---:|"], size = 50
            while size < bytes { let line = "| row \(lines.count) | `\(lines.count)` | **\(lines.count * 2)** |"; lines.append(line); size += line.utf8.count + 1 }
            return lines.joined(separator: "\n")
        }
        // A token is a word; the next entry arrives a piece at a time.
        let listTokens = ["\n- item next", " with", " `code`", " and", " **bold**", " text"]
        let tableTokens = ["\n| row next", " | `7`", " | **14**", " |"]
        let rounds = 48
        for (name, make, tokens) in [("list", list, listTokens), ("table", table, tableTokens)] {
            var medians: [Int: Double] = [:]
            for size in [1_024, 7_500] {
                var text = make(size)
                let state = StreamingMarkdownState()
                _ = state.update(text, style: .prose, streaming: true, identity: name)
                var samples: [Double] = []
                for round in 0..<rounds {
                    text += tokens[round % tokens.count]
                    let start = ProcessInfo.processInfo.systemUptime
                    let blocks = state.update(text, style: .prose, streaming: true, identity: name).map(\.block)
                    samples.append(ProcessInfo.processInfo.systemUptime - start)
                    XCTAssertEqual(blocks.count, 1, "\(name) of \(size) bytes: the open block is one \(name)")
                }
                XCTAssertLessThan(text.utf8.count, StreamingMarkdownState.tailParseLimit, "the fixture stays under the parse limit")
                XCTAssertEqual(state.update(text, style: .prose, streaming: true, identity: name).map(\.block), TranscriptMarkdown.parse(text),
                               "\(name) of \(size) bytes: the reading is the parse")
                // The shape that holds in any configuration: every token read
                // the entry still arriving, and no more than an entry's bytes.
                XCTAssertEqual(state.entryReadCount, rounds, "\(name) of \(size) bytes: a token read the whole \(name) again")
                XCTAssertLessThan(state.entryBytesRead / rounds, 200,
                                  "\(name) of \(size) bytes: a token parsed \(state.entryBytesRead / rounds) bytes")
                medians[size] = samples.sorted()[rounds / 2]
                print(String(format: "PERF a token on an open %d-byte %@: %.3f ms (median of %d), parsing %d bytes a token",
                             text.utf8.count, name, medians[size]! * 1000, rounds, state.entryBytesRead / rounds))
            }
            guard let short = medians[1_024], let long = medians[7_500] else { continue }
            XCTAssertLessThan(long, short * 2 + 0.000_3,
                              String(format: "a token on a 7.5 KB open %@ cost %.3f ms against %.3f ms at 1 KB", name, long * 1000, short * 1000))
            XCTAssertLessThan(long, releaseBudget(0.002), String(format: "a token on a 7.5 KB open %@ cost %.3f ms", name, long * 1000))
        }
    }

    // MARK: What a token costs inside a long fence

    /// A token inside an open code fence, at the end of a long reply. The
    /// reply above it is settled and the fence's earlier lines are read, so
    /// what a token costs must not grow with either: not with the prose above
    /// (the settled cuts are resumed, not found again), not with the fence's
    /// lines (they are not read again), and not in the code view (which
    /// appends and colours only from its last checkpoint). Measured for the
    /// whole path a token takes through the parts this reply's code owns: the
    /// streaming reading, the section split and the native code text.
    @MainActor func testATokenInsideALongOpenFenceCostsTheSameWhateverItsLength() {
        func reply(lines: Int) -> String {
            // Typographic quotes and a dash, as real replies have: a string
            // that is not all ASCII is compared a character at a time by
            // `hasPrefix`, which is the whole reply again for every token.
            let prose = (0..<lines / 10).map { "Paragraph \($0) of the reply above the fence — with **bold**, “quotes”, `code` and a [link](https://example.com)." }
            let code = (0..<lines).map { "let value\($0) = compute(\($0)) // line \($0) of the fence" }
            return prose.joined(separator: "\n\n") + "\n\n```swift\n" + code.joined(separator: "\n") + "\n"
        }
        let rounds = 48
        var medians: [Int: (model: Double, view: Double)] = [:]
        for lines in [250, 2_000] {
            var text = reply(lines: lines)
            let state = StreamingMarkdownState()
            _ = state.update(text, style: .prose, streaming: true, identity: "fence")
            let view = TranscriptCodeTextView()
            var model: [Double] = [], shown: [Double] = []
            var code = ""
            for round in 0..<rounds {
                // A token is a word; every sixth ends its line.
                text += round % 6 == 5 ? "x\(round)\n" : "x\(round) "
                var start = ProcessInfo.processInfo.systemUptime
                let records = state.update(text, style: .prose, streaming: true, identity: "fence")
                model.append(ProcessInfo.processInfo.systemUptime - start)
                guard case .code(let language, let next)? = records.last?.block else { XCTFail("the fence is not the open block"); return }
                code = next
                start = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(CodeBlockSections.ranges(code, enabled: false).isEmpty)
                view.update(source: code, language: language, size: 12.5, environment: TranscriptRowEnvironment())
                shown.append(ProcessInfo.processInfo.systemUptime - start)
            }
            XCTAssertEqual(view.string, code, "the code view holds the whole fence")
            XCTAssertTrue(code.hasSuffix("x\(rounds - 1)"), "the code holds the last token")
            let median = { (values: [Double]) in values.sorted()[values.count / 2] }
            medians[lines] = (median(model), median(shown))
            print(String(format: "PERF a token inside a %d-line open fence under %d paragraphs (%d bytes): reading %.3f ms, code view %.3f ms (medians of %d tokens)",
                         lines, lines / 10, text.utf8.count, median(model) * 1000, median(shown) * 1000, rounds))
        }
        guard let short = medians[250], let long = medians[2_000] else { return }
        // Eight times the fence and the prose above it. What grows with them
        // is a copy of the code into the block, never a reading of it; the
        // slack is for a machine that is busy with something else.
        XCTAssertLessThan(long.model, short.model * 3 + 0.000_2,
                          String(format: "reading a token cost %.3f ms in a 2,000-line fence against %.3f ms in a 250-line one", long.model * 1000, short.model * 1000))
        XCTAssertLessThan(long.view, short.view * 3 + 0.000_2,
                          String(format: "showing a token cost %.3f ms in a 2,000-line fence against %.3f ms in a 250-line one", long.view * 1000, short.view * 1000))
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
