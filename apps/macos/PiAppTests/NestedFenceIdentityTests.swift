import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Every fence of a reply is its own, however deep in quotes and lists it
/// sits: it shows, and its toolbar and assistive technology copy, its own
/// code, and a fence keeps its place while another one streams after it.
final class NestedFenceIdentityTests: XCTestCase {
    static let nested = "> ```swift\n> let value = 1\n> ```\n>\n> > ```swift\n> > let value = 10\n> > ```\n"

    /// The fences a builder's paragraphs hold, in order: each paragraph's
    /// text and the mark its toolbar copies.
    @MainActor private func fences(_ paragraphs: [MarkdownTextParagraph]) -> [(text: String, mark: MarkdownCodeMark)] {
        paragraphs.compactMap { paragraph in (paragraph.marks[.piCodeBlock] as? MarkdownCodeMark).map { (paragraph.text.string, $0) } }
    }
    @MainActor private func build(_ block: MarkdownBlock, builder: MarkdownTextBuilder = MarkdownTextBuilder(), component: Int = 0) -> [MarkdownTextParagraph] {
        builder.paragraphs(block, identity: MarkdownBlockIdentity(generation: 1, sourceOffset: 0, component: component),
                           context: MarkdownTextContext(style: .prose, capsWidth: true), gap: 0, headingIndex: nil)
    }
    private func assertDistinct(_ found: [(text: String, mark: MarkdownCodeMark)], _ codes: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.map(\.text), codes, "each fence shows its own code", file: file, line: line)
        XCTAssertEqual(found.map(\.mark.code), codes, "each fence copies its own code", file: file, line: line)
        XCTAssertEqual(Set(found.map { ObjectIdentifier($0.mark) }).count, codes.count, "no two fences share a mark", file: file, line: line)
    }

    /// The review's tree, a pair that is not a prefix, deeper quotes and
    /// lists, and two top-level blocks the reading told apart.
    @MainActor func testNestedFencesInOneBlockHaveTheirOwnMarks() {
        func code(_ text: String) -> MarkdownBlock { .code(language: "swift", code: text) }
        assertDistinct(fences(build(.quote([code("let value = 1"), .quote([code("let value = 10")])]))), ["let value = 1", "let value = 10"])
        assertDistinct(fences(build(.quote([code("print(a)"), .quote([code("return b")])]))), ["print(a)", "return b"])
        let deep = MarkdownBlock.list(ordered: false, start: 1, items: [
            [.quote([code("one"), .list(ordered: true, start: 1, items: [[code("one two")], [.quote([code("three")])]])])],
            [code("four"), .quote([.quote([code("five")])])],
        ])
        assertDistinct(fences(build(.quote([deep, code("six")]))), ["one", "one two", "three", "four", "five", "six"])
        let builder = MarkdownTextBuilder(), tree = MarkdownBlock.quote([code("first")])
        let first = fences(build(tree, builder: builder, component: 0)), second = fences(build(.quote([code("second")]), builder: builder, component: 1))
        assertDistinct(first + second, ["first", "second"])
    }

    /// The Markdown itself, drawn: the text reads both fences, the toolbar
    /// over each copies its own code, and assistive technology offers one
    /// copy action per fence, each over its own mark.
    @MainActor func testNestedFencesReadAndCopyTheirOwnCode() throws {
        let source = "Before.\n\n" + Self.nested + "\n- item one\n  > ```js\n  > a()\n  > ```\n  >\n  > > ```js\n  > > a(); b()\n  > > ```\n"
        let (surface, window) = MarkdownTextSurfaceTests.surface(source)
        let text = surface.textView, storage = try XCTUnwrap(text.textStorage)
        var marks: [MarkdownCodeMark] = []
        storage.enumerateAttribute(.piCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let mark = value as? MarkdownCodeMark, marks.last !== mark { marks.append(mark) }
        }
        let codes = ["let value = 1", "let value = 10", "a()", "a(); b()"]
        XCTAssertEqual(marks.map(\.code), codes)
        XCTAssertEqual(Set(marks.map { ObjectIdentifier($0) }).count, codes.count)
        for code in codes { XCTAssertTrue(text.string.contains(code), "shows \(code)") }
        let names = (text.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertEqual(names.filter { $0.hasPrefix("Copy code") }, ["Copy code 1", "Copy code 2", "Copy code 3", "Copy code 4"])
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        for code in codes {
            let range = (text.string as NSString).range(of: code)
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil), in: container)
            let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            surface.mouseMoved(with: event)
            let bar = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSHostingView<MarkdownCodeToolbar> }.first, "a toolbar over \(code)")
            XCTAssertEqual(bar.rootView.code, code, "the toolbar over \(code) copies it")
        }
        withExtendedLifetime(window) {}
    }

    /// The nested fence streams in after the outer one: the outer fence keeps
    /// its mark, its code and a selection in it, token by token and when the
    /// reply settles.
    @MainActor func testAStreamingNestedFenceLeavesTheOuterFenceAlone() throws {
        let opening = "> ```swift\n> let value = 1\n> ```\n>\n> > ```swift\n> > let"
        let (surface, window) = MarkdownTextSurfaceTests.surface(opening, streaming: true)
        let text = surface.textView, storage = try XCTUnwrap(text.textStorage)
        let chosen = (text.string as NSString).range(of: "value = 1")
        XCTAssertNotEqual(chosen.location, NSNotFound)
        text.setSelectedRange(chosen)
        let outer = try XCTUnwrap(storage.attribute(.piCodeBlock, at: chosen.location, effectiveRange: nil) as? MarkdownCodeMark)
        func check(_ moment: String) throws {
            XCTAssertEqual(text.selectedRange(), chosen, moment)
            XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "value = 1", moment)
            let mark = try XCTUnwrap(storage.attribute(.piCodeBlock, at: chosen.location, effectiveRange: nil) as? MarkdownCodeMark, moment)
            XCTAssertTrue(mark === outer, "\(moment): the outer fence keeps its mark")
            XCTAssertEqual(mark.code, "let value = 1", moment)
        }
        var source = opening
        for token in [" va", "lue", " = ", "1", "0", "\n> > ", "```", "\n"] {
            source += token
            _ = surface.appendStreaming(source, identity: "reply")
            try check("after \(token.debugDescription)")
        }
        XCTAssertEqual(source, Self.nested)
        surface.read(source: source, style: .prose, capsWidth: true, streaming: false, headings: [],
                     environment: TranscriptRowEnvironment(), identity: "reply")
        try check("settled")
        var codes: [String] = []
        storage.enumerateAttribute(.piCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let mark = value as? MarkdownCodeMark, codes.last != mark.code { codes.append(mark.code) }
        }
        XCTAssertEqual(codes, ["let value = 1", "let value = 10"])
        withExtendedLifetime(window) {}
    }
}
