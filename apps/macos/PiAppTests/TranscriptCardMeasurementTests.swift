import AppKit
import XCTest
@testable import PiApp

final class TranscriptCardMeasurementTests: XCTestCase {
    @MainActor func testDeferredMeasurementsKeepTheReadingLineAndSelection() async throws {
        let scroll = TranscriptCappedLines(style: .diff, cap: 224)
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 224)
        scroll.lines.update((0..<3_000).map { index in
            .init(mark: "+", text: "line \(index) " + String(repeating: "wrapped text ", count: index < 1_500 ? 30 : 1), markColor: .labelColor, background: nil)
        }, environment: .init())
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = scroll; window.orderFront(nil)
        scroll.tile(); scroll.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(scroll.lines.lineRect(at: 1_500))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target.minY + 3))
        scroll.lines.mountVisibleRows()
        let text = try XCTUnwrap(scroll.lines.builtText(at: 1_500))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        let offset = try XCTUnwrap(scroll.lines.lineRect(at: 1_500)).minY - scroll.contentView.bounds.minY
        try await unpacedIdleWork {
            try await eventually("Offscreen line geometry never settled", timeout: .seconds(30)) {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return scroll.lines.unmeasuredLineCount == 0
            }
        }
        XCTAssertEqual(try XCTUnwrap(scroll.lines.lineRect(at: 1_500)).minY - scroll.contentView.bounds.minY, offset, accuracy: 0.5)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertTrue(scroll.lines.builtText(at: 1_500) === text)
        XCTAssertEqual(scroll.lines.frame.height, try XCTUnwrap(scroll.lines.lineRect(at: 2_999)).maxY, accuracy: 0.5)
    }

    @MainActor func testAnExpandedThreeThousandLineDiffMeasuresOnlyItsViewport() throws {
        let rows = (0..<3_000).map { DiffRow(kind: .added, text: "let value\($0) = compute(\($0)) // a generated diff row") }
        let request = TranscriptActivity.EditRequest(before: "", after: rows.map(\.text).joined(separator: "\n"), mode: "write", rows: rows,
            hiddenRows: 0, complete: true, tooLarge: false, lines: rows.count)
        let card = TranscriptNativeDiffCard()
        card.update(.diff(request, path: "Fixture.swift", outcome: .done, added: rows.count, removed: 0), link: nil, environment: .init())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let before = TranscriptCardLines.rowsMeasured
        card.setExpanded(true)
        card.frame = NSRect(x: 0, y: 0, width: 520, height: card.height(width: 520))
        window.contentView = card
        card.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let scroller = try XCTUnwrap(LongChatScroll.views(TranscriptCappedLines.self, in: card).first)
        let measured = TranscriptCardLines.rowsMeasured - before
        print("SCROLL-11 first-frame measured=\(measured) built=\(scroller.lines.builtCount)")
        XCTAssertLessThan(measured, 96, "The capped viewport must not measure the other 3,000 lines before painting")
        XCTAssertEqual(scroller.lines.lines.count, 3_000)
        XCTAssertEqual(scroller.lines.lines.last?.text, rows.last?.text)
        XCTAssertGreaterThan(scroller.lines.builtCount, 0)
        let beforeResize = TranscriptCardLines.rowsMeasured
        card.frame.size = NSSize(width: 380, height: card.height(width: 380))
        card.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertLessThan(TranscriptCardLines.rowsMeasured - beforeResize, 96, "A new width also measures viewport-first")
    }
}
