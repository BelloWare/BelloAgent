import XCTest
@testable import PiApp

/// The conversation's own search (⌘F reads it for a chat's unloaded rows)
/// finds exactly what a case-insensitive `range(of:)` over each record's
/// text finds, in the same order and counts, with its ASCII shortcut and its
/// records decoded a run at a time.
final class ContentSearchTests: XCTestCase {
    func testTheASCIIShortcutOnlyExcludesWhatCannotMatch() {
        let needle = try! XCTUnwrap(ConversationContent.asciiNeedle("Zephyr C"))
        XCTAssertTrue(ConversationContent.excludes(needle, from: "nothing here at all"))
        XCTAssertFalse(ConversationContent.excludes(needle, from: "a ZEPHYR checkpoint"), "case is folded")
        XCTAssertFalse(ConversationContent.excludes(needle, from: "ends in zephyr c"))
        XCTAssertTrue(ConversationContent.excludes(needle, from: "zephyr"), "shorter than the needle")
        // Anything but ASCII is left to range(of:).
        XCTAssertFalse(ConversationContent.excludes(needle, from: "café, nothing else"))
        XCTAssertNil(ConversationContent.asciiNeedle("straße"))
        XCTAssertNil(ConversationContent.asciiNeedle(""))
    }

    @MainActor func testSearchHitsAreThoseOfRangeOfOverEveryRecord() async throws {
        let root = scratchRoot("content-search")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try LongChatScroll.journal(turns: 40)
        // Records whose text is not ASCII alone: a Kelvin sign, a sharp s, an emoji.
        var parent = "a39b"
        for (index, text) in ["The \u{212A}elvin scale", "Die Straße und die STRASSE", "Parser 🎉 done, parser again"].enumerated() {
            data.append(try JSONEncoder().encode(["type": WireValue.string("message"), "id": .string("x\(index)"), "parentId": .string(parent),
                                                  "message": .object(["role": .string("assistant"), "content": .string(text)])]))
            data.append(10); parent = "x\(index)"
        }
        let file = root.appendingPathComponent("long.jsonl")
        try data.write(to: file)
        // The reference: every record's text, searched the way the search always did.
        let records = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().map { line in
            ConversationContent.text((try? JSONDecoder().decode(WireValue.self, from: Data(line.utf8)))?.object ?? [:])
        }
        let reader = HistoryReader()
        for query in ["everything for question 1", "PARSE(INPUT, AT: 57)", "kelvin", "strasse", "parser", "🎉", "nothing says this", "e"] {
            var expected: [(Int, Int)] = []
            for (index, text) in records.enumerated() where expected.count < 100 && text.range(of: query, options: [.caseInsensitive]) != nil {
                expected.append((index + 1, ConversationContent.occurrences(of: query, in: text)))
            }
            var found: [(Int, Int)] = [], start = 0
            while true {
                let page = try await reader.searchContent(path: file.path, query: query, start: start)
                found += page.hits.map { ($0.position, $0.count ?? 1) }
                guard found.count < 100, let next = page.next else { break }
                start = next
            }
            XCTAssertEqual(found.prefix(100).map(\.0), expected.map(\.0), "positions for \(query)")
            XCTAssertEqual(found.prefix(100).map(\.1), expected.map(\.1), "counts for \(query)")
        }
    }
}
