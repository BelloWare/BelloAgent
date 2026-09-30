import XCTest
@testable import PiApp

final class FileSyntaxTests: XCTestCase {
    func testResumingKeepsNestedCommentsAndMultilineStringsAcrossLines() {
        var state = SyntaxHighlighter.State()
        func read(_ line: String) -> [SyntaxHighlighter.TokenKind] {
            let scan = SyntaxHighlighter.resume(line + "\n", language: .swift, state: state)
            state = scan.state
            return scan.tokens.map(\.kind)
        }
        XCTAssertEqual(read("/* outside"), [.comment])
        XCTAssertEqual(read("/* nested */ still outside"), [.comment])
        XCTAssertEqual(read("*/ let count = 1"), [.comment, .keyword, .number])
        XCTAssertEqual(state.commentDepth, 0)
        XCTAssertEqual(read("let value = \"\"\""), [.keyword, .string])
        XCTAssertEqual(read("a string, not let or // a comment"), [.string])
        XCTAssertEqual(read("\"\"\"; return value"), [.string, .keyword])
        XCTAssertNil(state.delimiter)
        XCTAssertEqual(read("struct"), [.keyword])
        XCTAssertEqual(read("Widget {}"), [.title], "a declaration can name its type on the next line")
    }

    @MainActor func testDeepVisibleLinesUseBoundedCheckpointsWithoutColouringThePrefix() async {
        let reader = FileSyntaxReader()
        let lines = (0..<300).map { index in index == 0 ? "/* comment" : index == 269 ? "*/" : "still a comment" }
        var loaded: [ClosedRange<Int>] = []
        let load: FileSyntaxReader.Load = { range in
            loaded.append(range)
            return range.map { lines[$0] }.joined(separator: "\n")
        }
        let ink = await reader.tokens(line: 270, text: "😀 let count = 1", language: .swift, load: load)
        XCTAssertEqual(ink.first?.kind, .keyword)
        XCTAssertEqual(ink.first?.range, 3..<6, "colours address UTF-16 after a surrogate pair")
        XCTAssertTrue(loaded.allSatisfy { $0.count <= 128 })
        let coloured = await reader.colouredLines
        XCTAssertEqual(coloured, [270], "prefix work produces states, not colours")
        let before = loaded.count
        _ = await reader.tokens(line: 271, text: "let next = 2", language: .swift, load: load)
        XCTAssertTrue(loaded.dropFirst(before).allSatisfy { $0.lowerBound >= 256 }, "earlier checkpoints are reused")
    }
}
