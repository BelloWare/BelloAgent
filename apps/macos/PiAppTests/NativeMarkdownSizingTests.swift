import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class NativeMarkdownSizingTests: XCTestCase {
    @MainActor func testManyBlockAnswerKeepsExactGeometryAndFullCopySource() throws {
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
        print("REVIEW Markdown \(source.utf8.count) bytes / \(parsed.count) blocks: exact sizing \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms, retained hosts \(body.hostedBlockCount)")
        XCTAssertEqual(body.hostedBlockCount, parsed.count)
        XCTAssertEqual(body.blockMeasurementCount, parsed.count)
        XCTAssertEqual(body.measure(width: 620), size)
        XCTAssertEqual(body.blockMeasurementCount, parsed.count, "A repeated width uses each block's exact record")
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
            for host in body.subviews {
                XCTAssertEqual(host.frame.height, ceil(host.fittingSize.height), accuracy: 1,
                               "The descriptor's measured height must match the actual selectable host")
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
            XCTAssertGreaterThan(size.height, 1000)
            XCTAssertEqual(body.measure(width: 620), size)
        }
    }
}
