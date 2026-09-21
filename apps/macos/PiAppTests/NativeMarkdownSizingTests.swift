import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class NativeMarkdownSizingTests: XCTestCase {
    @MainActor func testStreamingTailUpdatesOnlyItsAggregateSuffix() {
        let body = NativeMarkdownContainer()
        var blocks = (0..<300).map { MarkdownBlock.paragraph(AttributedString("Completed paragraph \($0).")) }
        let environment = TranscriptRowEnvironment()
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: true, headings: [], environment: environment)
        let original = body.measure(width: 600)
        body.frame = CGRect(origin: .zero, size: original); body.layoutSubtreeIfNeeded()
        let owners = body.blockOwnerIdentities, before = body.aggregateMeasurementVisits, frames = body.framePlacements
        blocks[299] = .paragraph(AttributedString(String(repeating: "Tail continues with more text. ", count: 20)))
        body.update(blocks: blocks, style: .prose, capsWidth: true, streaming: true, headings: [], environment: environment)
        let resized = body.measure(width: 600)
        body.frame.size.height = resized.height; body.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(resized.height, original.height)
        XCTAssertEqual(body.aggregateMeasurementVisits - before, 1)
        XCTAssertEqual(body.framePlacements - frames, 1)
        XCTAssertEqual(body.blockOwnerIdentities, owners)
        // A width change rebuilds every descriptor, with only its initial band measured exactly.
        _ = body.measure(width: 500)
        XCTAssertEqual(body.aggregateMeasurementVisits - before, 301)
    }

    @MainActor func testManyBlockAnswerPreparesVisibleGeometryAndKeepsFullCopySource() throws {
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
        print("REVIEW Markdown \(source.utf8.count) bytes / \(parsed.count) blocks: initial sizing \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms, retained hosts \(body.hostedBlockCount)")
        XCTAssertEqual(body.hostedBlockCount, 6)
        XCTAssertEqual(body.blockMeasurementCount, 6)
        XCTAssertEqual(body.measure(width: 620), size)
        XCTAssertEqual(body.blockMeasurementCount, 6, "A repeated width keeps provisional blocks separate from exact measurements")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        body.frame = NSRect(origin: .zero, size: size); scroll.documentView = body
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for position in [0.0, 0.5, 1.0, 0.0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: (size.height - 560) * position))
            body.needsLayout = true; body.layoutSubtreeIfNeeded()
            XCTAssertLessThan(body.mountedBlockCount, 40)
            for host in body.subviews where !(host is NSProgressIndicator) {
                XCTAssertEqual(host.frame.height, ceil(host.fittingSize.height), accuracy: 1,
                               "Every mounted block must have exact native geometry")
            }
        }
        // Section controls keep their existing 64 KiB scan limit. Large
        // messages still use the transcript's source-based whole-message copy.
        XCTAssertTrue(TranscriptCopy.targets(in: source).isEmpty)
        let copyableSource = source.components(separatedBy: "## Section 120").first!
        let targets = TranscriptCopy.targets(in: copyableSource)
        let sections = targets.filter { if case .section = $0.kind { return true }; return false }
        XCTAssertEqual(sections.count, 120)
        XCTAssertTrue(sections.last?.text.contains("let value119") == true,
                      "Copy targets include the end of the source, independent of mounted views")
    }

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
            else { XCTAssertLessThan(size.height, 8000, "A huge fence uses bounded source sections with full copy") }
            XCTAssertEqual(body.measure(width: 620), size)
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
