import XCTest
import SwiftUI
@testable import PiApp

/// Markdown blocks, syntax colouring and copy targets, the native replacements
/// for the transcript's former markdown, highlighting and copy-range modules.
final class TranscriptMarkdownTests: XCTestCase {
    private func text(_ value: AttributedString) -> String { String(value.characters) }

    func testMarkdownBecomesNativeBlocksWithInlineStyling() throws {
        let blocks = TranscriptMarkdown.blocks("Intro **bold** and `code` [link](https://example.com) ~~gone~~ ![alt](https://x/y.png)\n\n# Title\n\n- one\n- two\n  1. nested\n\n```swift\nlet a = 1\n```\n\n| A | B |\n|---|:-:|\n| 1 | 2 |\n\n> quote line")
        guard case .paragraph(let intro) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(text(intro), "Intro bold and code link gone [Image not loaded: alt]")
        let bold = try XCTUnwrap(intro.runs.first { text(AttributedString(intro[$0.range])) == "bold" })
        XCTAssertEqual(bold.font, .system(size: 14.5, weight: .semibold))
        let link = try XCTUnwrap(intro.runs.first { text(AttributedString(intro[$0.range])) == "link" })
        XCTAssertEqual(link.link, URL(string: "https://example.com"))
        let struck = try XCTUnwrap(intro.runs.first { text(AttributedString(intro[$0.range])) == "gone" })
        XCTAssertEqual(struck.strikethroughStyle, .single)
        guard case .heading(let level, let title, let plain) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(level, 1); XCTAssertEqual(text(title), "Title"); XCTAssertEqual(plain, "Title")
        guard case .list(let ordered, _, let items) = blocks[2] else { return XCTFail("\(blocks[2])") }
        XCTAssertFalse(ordered); XCTAssertEqual(items.count, 2)
        guard case .list(let nestedOrdered, let start, let nested) = items[1][1] else { return XCTFail("\(items[1])") }
        XCTAssertTrue(nestedOrdered); XCTAssertEqual(start, 1); XCTAssertEqual(nested.count, 1)
        guard case .code(let language, let code) = blocks[3] else { return XCTFail("\(blocks[3])") }
        XCTAssertEqual(language, "swift"); XCTAssertEqual(code, "let a = 1")
        guard case .table(let alignments, let header, let rows) = blocks[4] else { return XCTFail("\(blocks[4])") }
        XCTAssertEqual(alignments, [.left, .center]); XCTAssertEqual(header.map(text), ["A", "B"]); XCTAssertEqual(rows.map { $0.map(text) }, [["1", "2"]])
        guard case .quote(let quoted) = blocks[5], case .paragraph(let line) = quoted[0] else { return XCTFail("\(blocks[5])") }
        XCTAssertEqual(text(line), "quote line")
    }

    func testSoftBreaksStayTypedForUsersAndFlowForProse() {
        guard case .paragraph(let user) = TranscriptMarkdown.blocks("first line\nsecond line", style: .user)[0],
              case .paragraph(let prose) = TranscriptMarkdown.blocks("first line\nsecond line")[0] else { return XCTFail() }
        XCTAssertEqual(text(user), "first line\nsecond line"); XCTAssertEqual(text(prose), "first line second line")
    }

    func testMarkdownNeverEnablesScriptsExecutableURLsCredentialURLsOrRemoteImages() {
        let blocks = TranscriptMarkdown.blocks("<script>window.pwned=1</script>\n\n[run](javascript:alert%281%29) ![tracking](https://evil.example/pixel) [bad](https://secret:pass@evil.example) [good](https://example.com/page)\n\n```js\n<script>text</script>\n```")
        let links = blocks.flatMap { block -> [URL] in
            guard case .paragraph(let paragraph) = block else { return [] }
            return paragraph.runs.compactMap(\.link)
        }
        XCTAssertEqual(links, [URL(string: "https://example.com/page")!], "only the plain web link survives as a link")
        let rendered = blocks.compactMap { block -> String? in if case .paragraph(let p) = block { return text(p) }; return nil }.joined(separator: "\n")
        XCTAssertTrue(rendered.contains("[Image not loaded: tracking]")); XCTAssertTrue(rendered.contains("run")); XCTAssertTrue(rendered.contains("bad"))
        guard case .code(_, let code) = blocks.last! else { return XCTFail("\(blocks)") }
        XCTAssertEqual(code, "<script>text</script>", "code is text, never markup")
        for value in ["file:///etc/passwd", "data:text/html,x", "//evil.example", "https://name:secret@evil.example", "javascript:alert(1)"] { XCTAssertNil(TranscriptMarkdown.safeURL(value), value) }
        XCTAssertEqual(TranscriptMarkdown.safeURL("https://example.com/page")?.absoluteString, "https://example.com/page")
    }

    func testUnfinishedFencesAndLongCodeStayText() {
        let long = "```ts\nconst x = 1;\n" + String(repeating: "x", count: 100_000)
        let blocks = TranscriptMarkdown.blocks(long)
        guard case .code(let language, let code) = blocks[0] else { return XCTFail("\(blocks.count)") }
        XCTAssertEqual(language, "ts"); XCTAssertTrue(code.hasSuffix(String(repeating: "x", count: 100_000)))
        XCTAssertTrue(SyntaxHighlighter.tokens(code, language: .typescript).isEmpty, "oversized code is not coloured")
        XCTAssertEqual(TranscriptMarkdown.blocks(""), [])
    }

    func testHighlighterFindsCommentsStringsNumbersKeywordsAndNames() {
        let ts = "const x = \"<img src=x onerror=alert(1)>\"; // note\nconst earth = '🌍'; /* block */ function greet() { return 1.5e3; }"
        let tokens = SyntaxHighlighter.tokens(ts, language: .typescript)
        let scalars = Array(ts.unicodeScalars)
        func words(_ kind: SyntaxHighlighter.TokenKind) -> [String] { tokens.filter { $0.kind == kind }.map { String(String.UnicodeScalarView(scalars[$0.range])) } }
        XCTAssertEqual(words(.keyword), ["const", "const", "function", "return"])
        XCTAssertEqual(words(.string), ["\"<img src=x onerror=alert(1)>\"", "'🌍'"], "markup inside a string is string, and the emoji survives")
        XCTAssertEqual(words(.comment), ["// note", "/* block */"])
        XCTAssertEqual(words(.title), ["greet"]); XCTAssertEqual(words(.number), ["1.5e3"])
        XCTAssertEqual(SyntaxHighlighter.tokens("def greet(name):\n    return '''multi\nline'''  # trailing", language: .python).map(\.kind), [.keyword, .title, .keyword, .string, .comment])
        XCTAssertEqual(SyntaxHighlighter.tokens("echo $# and \"quoted # not\" # comment", language: .bash).map(\.kind), [.string, .comment], "a dollar-hash is a parameter, not a comment")
        XCTAssertEqual(SyntaxHighlighter.tokens("{\"a\": true, \"b\": 0x1F, \"c\": null}", language: .json).map(\.kind), [.string, .keyword, .string, .number, .string, .keyword])
        XCTAssertEqual(SyntaxHighlighter.tokens("func charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }", language: .swift).filter { $0.kind == .title }.count, 1)
        XCTAssertNil(SyntaxHighlighter.language(named: "unknown")); XCTAssertEqual(SyntaxHighlighter.language(named: "ts"), .typescript); XCTAssertEqual(SyntaxHighlighter.language(named: "SH"), .bash)
        XCTAssertTrue(SyntaxHighlighter.tokens(String(repeating: "x", count: 16_385), language: .typescript).isEmpty)
        let styled = SyntaxHighlighter.attributed("let a = 1 // c", language: "swift")
        XCTAssertEqual(styled.runs.count, 5, "keyword, plain, number, plain, comment")
    }

    func testSectionCopyFollowsHeadingHierarchyIncludesNestedSectionsAndExcludesPeers() {
        let source = "Intro **Markdown**.\n\n# Setup\nRoot.\n\n## Install\nRun it.\n\n### macOS\nKeep this.\n\n## Test\nDifferent step.\n\n# Done\nFinish."
        let targets = TranscriptCopy.targets(in: source)
        func copy(_ label: String) -> String? { targets.first { $0.label == label }?.text }
        XCTAssertEqual(copy("Copy introduction as Markdown"), "Intro **Markdown**.\n\n")
        XCTAssertEqual(copy("Copy Setup as Markdown"), String(source[source.range(of: "# Setup")!.lowerBound..<source.range(of: "# Done")!.lowerBound]))
        XCTAssertEqual(copy("Copy Install as Markdown"), "## Install\nRun it.\n\n### macOS\nKeep this.\n\n")
        XCTAssertEqual(copy("Copy macOS as Markdown"), "### macOS\nKeep this.\n\n")
        XCTAssertEqual(copy("Copy Test as Markdown"), "## Test\nDifferent step.\n\n")
        XCTAssertEqual(copy("Copy Done as Markdown"), "# Done\nFinish.")
    }

    func testCopySectionsHonorSetextHeadingsAndIgnoreCodeQuotedAndListedHeadings() {
        let source = "First\n=====\n\n```md\n# fenced\n```\n\n> # quoted\n> text\n\n- ## listed\n\nSecond\n======\nFinal"
        let targets = TranscriptCopy.targets(in: source)
        XCTAssertEqual(targets.filter { $0.kind != .code }.map(\.label), ["Copy First as Markdown", "Copy Second as Markdown"])
        XCTAssertEqual(targets.first { $0.label == "Copy First as Markdown" }?.text, String(source[..<source.range(of: "Second")!.lowerBound]))
        XCTAssertEqual(targets.first { $0.kind == .code }?.text, "# fenced\n")
        let noHeading = "**A reply** with [a link](https://example.com) and `inline code`.\n"
        let fallback = TranscriptCopy.targets(in: noHeading)
        XCTAssertEqual(fallback.count, 1); XCTAssertEqual(fallback[0].label, "Copy as Markdown"); XCTAssertEqual(fallback[0].text, noHeading)
    }

    func testCodeCopiesPreserveSourceBytesWithoutFencesLabelsOrFabricatedNewlines() {
        let code = "const earth = \"🌍\";  \r\n\tconst html = \"<img src=x>\";\r\n\r\n"
        let source = "Before\r\n\r\n```typescript linenums\r\n" + code + "```\r\n\r\nAfter"
        XCTAssertEqual(TranscriptCopy.targets(in: source).first { $0.kind == .code }?.text, code)
        for source in ["```js\nconst x = 1;", "~~~\n# still code\n  value  ", "    first\n    second"] {
            let expected = source.hasPrefix("    ") ? "first\nsecond" : String(source[source.index(after: source.firstIndex(of: "\n")!)...])
            XCTAssertEqual(TranscriptCopy.targets(in: source).first { $0.kind == .code }?.text, expected, source)
        }
        XCTAssertTrue(TranscriptCopy.targets(in: "```\n```").filter { $0.kind == .code }.isEmpty, "empty code has no misleading copy action")
        XCTAssertTrue(TranscriptCopy.targets(in: String(repeating: "x", count: 70_000)).isEmpty, "oversized sources offer no targets")
    }

    func testNestedFencedAndIndentedCodeCopyDropsOnlyContainerPrefixes() {
        let source = "- Example:\n\n  ```js\n  const a = 1;\n    indented();\n  ```\n\n> ```sh\n> echo hi\n>   echo there\n> ```\n\n    plain\n      deeper"
        XCTAssertEqual(TranscriptCopy.targets(in: source).filter { $0.kind == .code }.map(\.text), ["const a = 1;\n  indented();\n", "echo hi\n  echo there\n", "plain\n  deeper"])
    }
}
