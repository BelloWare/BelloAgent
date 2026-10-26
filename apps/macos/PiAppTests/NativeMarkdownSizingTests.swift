import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class NativeMarkdownSizingTests: XCTestCase {
    /// A change to the reply's last block sets that block's text again, not
    /// the 299 above it; a new width lays the text out once.
    @MainActor func testStreamingTailUpdatesOnlyItsOwnText() {
        let body = NativeMarkdownContainer()
        var blocks = (0..<300).map { MarkdownBlock.paragraph(AttributedString("Completed paragraph \($0).")) }
        let environment = TranscriptRowEnvironment()
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: true, headings: [], environment: environment)
        let original = body.measure(width: 600)
        body.frame = CGRect(origin: .zero, size: original); body.layoutSubtreeIfNeeded()
        let settled = (body.textView.string as NSString).range(of: "Completed paragraph 299.").location
        let passes = body.layoutPasses
        blocks[299] = .paragraph(AttributedString(String(repeating: "Tail continues with more text. ", count: 20)))
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: true, headings: [], environment: environment)
        let resized = body.measure(width: 600)
        body.frame.size.height = resized.height; body.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(resized.height, original.height)
        XCTAssertGreaterThanOrEqual(body.lastReplacedLocation, settled, "only the last block's text was set again")
        XCTAssertEqual(body.layoutPasses - passes, 1)
        _ = body.measure(width: 500)
        XCTAssertEqual(body.layoutPasses - passes, 2, "a width lays the text out once")
        XCTAssertEqual(body.measure(width: 500).height, body.measure(width: 500).height)
        XCTAssertEqual(body.layoutPasses - passes, 2, "and a width it knows is not laid out again")
    }

    /// Prose that wraps differently at the page's 840 points and at a
    /// narrower reading column.
    static let wrappingProse = (0..<24).map { index in
        "Paragraph \(index): " + String(repeating: "Words that wrap differently in a narrower column. ", count: 9)
    }.joined(separator: "\n\n")

    /// PERF-1: a reply's text joining the page — a view tree, then a window —
    /// is not laid out for it. Before, AppKit marking the new text view for
    /// display laid its whole text out at the 840 points its container
    /// started at, and the measurement laid it out again at the row's width.
    @MainActor func testTextJoiningThePageIsLaidOutOnlyAtItsMeasuredWidth() {
        let body = NativeMarkdownContainer()
        body.update(blocks: TranscriptMarkdown.blocks(Self.wrappingProse, style: .prose), style: .prose, capsWidth: true, streaming: false,
                    headings: [], environment: TranscriptRowEnvironment())
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        holder.addSubview(body)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView?.addSubview(holder)
        XCTAssertEqual(body.textLayouts, 0, "joining a view tree and a window lays nothing out")
        let size = body.measure(width: 600)
        XCTAssertEqual(body.textLayouts, 1, "the measurement lays the text out once")
        XCTAssertEqual(body.textLayoutWidth, 600)
        body.frame = CGRect(origin: .zero, size: size)
        holder.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertEqual(body.textLayouts, 1, "placing and drawing it at that width lays nothing out again")
        // A new width is still one layout, there.
        _ = body.measure(width: 500)
        XCTAssertEqual(body.textLayouts, 2)
        XCTAssertEqual(body.textLayoutWidth, 500)
    }

    /// PERF-1: a reply still arriving puts its caret after its last word as
    /// soon as it has words, which lays them out: at the width its row will
    /// show them at, which the row knows before it has placed them, so its
    /// measurement there finds the layout done.
    @MainActor func testAReplyIsLaidOutAtItsRowsWidthBeforeItIsPlaced() {
        for streaming in [true, false] {
            let message = TranscriptMessage(id: "reply", role: "assistant", text: Self.wrappingProse, state: streaming ? "streaming" : nil, turn: "question")
            let inputs = TranscriptRowInputs(item: TranscriptNativePartView.wordsItem(message), fresh: false, actions: TranscriptActions(),
                                             width: 600, environment: TranscriptRowEnvironment())
            let row = TranscriptNativeReplyRow(inputs: inputs)
            let holder = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            holder.addSubview(row)
            func surfaces(_ view: NSView) -> [NativeMarkdownContainer] {
                (view as? NativeMarkdownContainer).map { [$0] } ?? view.subviews.flatMap { surfaces($0) }
            }
            guard let surface = surfaces(row).first else { return XCTFail("the reply has no text surface") }
            XCTAssertEqual(surface.textLayouts, streaming ? 1 : 0, "streaming \(streaming): only the caret lays the words out before they are measured")
            if streaming { XCTAssertEqual(surface.textLayoutWidth, 600, "the caret laid the words out at the row's width") }
            let height = row.height(width: 600)
            row.frame = CGRect(x: 0, y: 0, width: 600, height: height); row.layoutSubtreeIfNeeded()
            XCTAssertEqual(surface.textLayouts, 1, "streaming \(streaming): one layout, at the row's width")
            XCTAssertEqual(surface.textLayoutWidth, 600)
        }
    }

    @MainActor func testManyBlockAnswerIsOneTextMeasuredOnceAndKeepsFullCopySource() throws {
        let source = (0..<160).map { index in
            """
            ## Section \(index)

            A **selectable** paragraph with [a link](https://example.invalid/\(index)) and `inline code`. \(String(repeating: "Words that wrap naturally. ", count: 12))

            ~~~swift
            let value\(index) = inspect("\(index)")
            ~~~

            | Field | Value |
            | --- | --- |
            | Index | \(index) |
            """
        }.joined(separator: "\n\n")
        let body = NativeMarkdownContainer()
        let parsed = TranscriptMarkdown.blocks(source, style: .prose)
        body.update(blocks: parsed, style: .prose, capsWidth: true, streaming: false,
                    headings: TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false },
                    environment: TranscriptRowEnvironment())
        let start = ProcessInfo.processInfo.systemUptime
        let size = body.measure(width: 620)
        print("REVIEW Markdown \(source.utf8.count) bytes / \(parsed.count) blocks: initial sizing \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms as one text")
        XCTAssertEqual(body.layoutPasses, 1)
        XCTAssertEqual(body.measure(width: 620), size)
        XCTAssertEqual(body.layoutPasses, 1, "A repeated width is not laid out again")
        // Every block of it is in the one text a selection runs across.
        let text = body.textView
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        let copied = text.copyText(text.selectedRanges.map(\.rangeValue))
        XCTAssertTrue(copied.hasPrefix("Section 0\n\nA selectable paragraph"))
        XCTAssertTrue(copied.contains("let value159 = inspect(\"159\")"))
        XCTAssertTrue(copied.hasSuffix("Index\t159"), String(copied.suffix(40)))
        // Section controls keep their existing 64 KiB scan limit. Large
        // messages still use the transcript's source-based whole-message copy.
        XCTAssertTrue(TranscriptCopy.targets(in: source).isEmpty)
        let copyableSource = source.components(separatedBy: "## Section 120").first!
        let targets = TranscriptCopy.targets(in: copyableSource)
        let sections = targets.filter { if case .section = $0.kind { return true }; return false }
        XCTAssertEqual(sections.count, 120)
        XCTAssertTrue(sections.last?.text.contains("let value119") == true,
                      "Copy targets include the end of the source, independent of the view")
    }

    /// A 2,500-line fence is shown whole — one text, laid out once — and a
    /// 1,500-row table keeps its bounded inline preview.
    @MainActor func testSingleCodeFenceAndTableHaveSeparateMeasuredCosts() {
        let code = "~~~swift\n" + (0..<2500).map { "let value\($0) = inspect(index: \($0))" }.joined(separator: "\n") + "\n~~~"
        let table = "| Key | Value |\n| --- | --- |\n" + (0..<1500).map { "| Field \($0) | A measured value for row \($0) |" }.joined(separator: "\n")
        for (label, source) in [("code fence", code), ("table", table)] {
            let body = NativeMarkdownContainer()
            body.update(blocks: TranscriptMarkdown.blocks(source, style: .prose), style: .prose, capsWidth: true,
                        streaming: false, headings: [], environment: TranscriptRowEnvironment())
            let started = ProcessInfo.processInfo.systemUptime
            let size = body.measure(width: 620)
            print("REVIEW single \(label): \(source.utf8.count) bytes, sizing \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms, height \(size.height)")
            if label == "table" { XCTAssertLessThan(size.height, 1500, "Large tables intentionally render a bounded inline preview") }
            else { XCTAssertTrue(body.textView.string.contains("let value2499"), "the whole fence is in the text") }
            XCTAssertEqual(body.measure(width: 620), size)
            XCTAssertEqual(body.layoutPasses, 1)
        }
    }
    @MainActor func testFullTableUsesVisibleCellsAndKeepsTheLastCellAndCompleteCopy() throws {
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        let header = [AttributedString("Key"), AttributedString("Value")]
        let longCell = "Last cell\twith a quote \" and\n" + String(repeating: "中文🙂 ", count: 1000)
        let rows = (0..<1500).map { [AttributedString("Row \($0)"), AttributedString($0 == 1499 ? longCell : "Value \($0)")] }
        XCTAssertTrue(MarkdownTablePresentation.isLarge(header: header, rows: rows))
        MarkdownTableWindow.open(header: header, rows: rows)
        let window = try XCTUnwrap(NSApp.windows.first { !previous.contains(ObjectIdentifier($0)) && $0.title.hasPrefix("Table ·") })
        defer { window.close() }
        func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
        }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let table = try XCTUnwrap(descendants(NSTableView.self, root).first)
        XCTAssertEqual(table.numberOfRows, 1500)
        XCTAssertGreaterThan(table.rows(in: table.visibleRect).length, 0)
        XCTAssertLessThan(descendants(NSTextField.self, table).count, 100)
        table.scrollRowToVisible(1499)
        table.selectRowIndexes(IndexSet(integer: 1499), byExtendingSelection: false)
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(descendants(NSTextView.self, root).contains { $0.string.contains(longCell) })
        let copied = MarkdownTablePresentation.tsv(header: ["Key", "Value"], rows: [["last", longCell]])
        XCTAssertTrue(copied.hasSuffix("\""))
        XCTAssertTrue(copied.contains("a quote \"\""))
        XCTAssertTrue(copied.contains(String(repeating: "中文🙂 ", count: 1000)))
        XCTAssertEqual(MarkdownTablePresentation.tsv(header: ["A"], rows: [["a\rb"]]), "A\n\"a\rb\"")
    }
}
