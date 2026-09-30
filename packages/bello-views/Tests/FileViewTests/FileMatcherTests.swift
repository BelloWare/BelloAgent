import XCTest
@testable import FileView

/// What a search matches (`FileMatcher`): the query literally, within a line,
/// leftmost first and each sought from where the one before ended; case
/// folded a character at a time to one of the same length, so a match is
/// always as long as the query; nothing for an empty query, one too long, or
/// one holding a line ending.
final class FileMatcherTests: XCTestCase {
    private func matches(_ line: String, _ query: String, matchCase: Bool = false) -> [Range<Int>] {
        FileMatcher(query: query, matchCase: matchCase).matches(in: line)
    }

    func testCaseIsMatchedOnlyWhenAsked() {
        XCTAssertEqual(matches("Foo foo FOO", "foo"), [0..<3, 4..<7, 8..<11])
        XCTAssertEqual(matches("Foo foo FOO", "foo", matchCase: true), [4..<7])
        XCTAssertEqual(matches("a.b a*b", ".", matchCase: true), [1..<2], "literally, not a pattern")
    }

    func testMatchesAreLeftmostFirstAndNeverOverlap() {
        XCTAssertEqual(matches("aaaa", "aa"), [0..<2, 2..<4])
        XCTAssertEqual(matches("aaaaa", "aaa"), [0..<3])
        XCTAssertEqual(matches("ababa", "aba"), [0..<3])
        XCTAssertEqual(matches("abababa", "aba"), [0..<3, 4..<7])
    }

    func testPlacesAreUTF16Units() {
        // é as one character and as e with a combining accent, and a
        // character outside the first plane: two units.
        let line = "é😀e\u{301}x😀x"
        XCTAssertEqual(matches(line, "x"), [5..<6, 8..<9])
        XCTAssertEqual(matches(line, "😀"), [1..<3, 6..<8])
        XCTAssertEqual(matches(line, "e\u{301}"), [3..<5])
        XCTAssertEqual(matches(line, "é"), [0..<1], "literally: the composed é only")
    }

    func testFoldingKeepsEachCharacterItsLength() {
        XCTAssertEqual(matches("Straße", "STRASSE"), [], "ß is not SS")
        XCTAssertEqual(matches("straße", "STRAßE"), [0..<6])
        XCTAssertEqual(matches("\u{212A}elvin", "kelvin"), [0..<6], "the Kelvin sign is a k")
        XCTAssertEqual(matches("ΣΑΣ σας", "σασ"), [0..<3, 4..<7], "final sigma too")
        XCTAssertEqual(matches("\u{10400}\u{10428}", "\u{10428}"), [0..<2, 2..<4], "outside the first plane")
        XCTAssertEqual(matches("\u{10400}", "\u{10400}", matchCase: true), [0..<2])
        // Folding twice is folding once: the query and the text agree however
        // often either was folded.
        var units = (0..<65_536).map { UInt16($0) }
        units.withUnsafeMutableBufferPointer { FileMatcher.fold($0) }
        var again = units
        again.withUnsafeMutableBufferPointer { FileMatcher.fold($0) }
        XCTAssertEqual(units, again)
    }

    func testOverlapsAreKnownAfterFolding() {
        XCTAssertTrue(FileMatcher(query: "aba", matchCase: true).overlaps)
        XCTAssertTrue(FileMatcher(query: "aa", matchCase: true).overlaps)
        XCTAssertTrue(FileMatcher(query: "Aa", matchCase: false).overlaps, "Aa folds to aa")
        XCTAssertFalse(FileMatcher(query: "Aa", matchCase: true).overlaps)
        XCTAssertFalse(FileMatcher(query: "abc", matchCase: false).overlaps)
        XCTAssertFalse(FileMatcher(query: "a", matchCase: false).overlaps)
    }

    func testSomeQueriesMatchNothing() {
        XCTAssertTrue(FileMatcher(query: "", matchCase: false).matchesNothing)
        XCTAssertTrue(FileMatcher(query: "a\nb", matchCase: false).matchesNothing)
        XCTAssertTrue(FileMatcher(query: "a\rb", matchCase: false).matchesNothing)
        XCTAssertEqual(matches("a\nb", "a\nb"), [])
        let long = String(repeating: "x", count: FileMatcher.characterLimit + 1)
        XCTAssertTrue(FileMatcher(query: long, matchCase: false).isTooLong)
        XCTAssertTrue(FileMatcher(query: String(repeating: "x", count: 1 << 20), matchCase: false).units.isEmpty, "a pasted page is not copied or folded")
        XCTAssertFalse(FileMatcher(query: String(long.dropLast()), matchCase: false).isTooLong)
        // Few characters, many units: one letter with a thousand marks.
        let marked = "a" + String(repeating: "\u{301}", count: FileMatcher.unitLimit)
        XCTAssertEqual(marked.count, 1)
        XCTAssertTrue(FileMatcher(query: marked, matchCase: false).isTooLong)
    }
}
