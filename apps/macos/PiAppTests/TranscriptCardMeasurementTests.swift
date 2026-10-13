import AppKit
import XCTest
@testable import PiApp

final class TranscriptCardMeasurementTests: XCTestCase {
    @MainActor func testTheEndOfAWrappedDiffStaysVisibleWhileItsLinesMeasure() async throws {
        let scroll = TranscriptCappedLines(style: .diff, cap: 224)
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 224)
        let last = 399
        scroll.lines.update((0...last).map { index in
            .init(mark: "+", text: index == last ? "The final diff line" : "line \(index) " + String(repeating: "wrapped text ", count: 30),
                  markColor: .labelColor, background: nil)
        }, environment: .init())
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = scroll; window.orderFront(nil)
        scroll.tile(); scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.lines.unmeasuredLineCount, 200)
        let heightBefore = scroll.lines.frame.height, measurementsBefore = TranscriptCardLines.rowsMeasured
        // A single drag to the end, while most of the document is estimated.
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: heightBefore - scroll.contentView.bounds.height))
        scroll.lines.mountVisibleRows()
        let gap = scroll.lines.frame.maxY - scroll.contentView.bounds.maxY
        let measurements = TranscriptCardLines.rowsMeasured - measurementsBefore
        print("DIFF-END immediate-gap=\(gap) height-growth=\(scroll.lines.frame.height - heightBefore) measured=\(measurements)")
        XCTAssertGreaterThan(scroll.lines.frame.height - heightBefore, 1_000, "The destination must change as wrapped lines measure")
        XCTAssertEqual(gap, 0, accuracy: 0.5, "Reaching the end must show the final lines on the first scroll")
        XCTAssertNotNil(scroll.lines.builtText(at: last))
        XCTAssertLessThan(measurements, 96, "Reaching the end must measure only its viewport")
        XCTAssertGreaterThan(scroll.lines.unmeasuredLineCount, 200, "The rest must still be deferred")
        try await unpacedIdleWork {
            try await eventually("Offscreen line geometry never settled", timeout: .seconds(30)) {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return scroll.lines.unmeasuredLineCount == 0
            }
        }
        let settledGap = scroll.lines.frame.maxY - scroll.contentView.bounds.maxY
        print("DIFF-END settled-gap=\(settledGap)")
        XCTAssertEqual(settledGap, 0, accuracy: 0.5, "Idle measurement must keep the bottom destination")
        XCTAssertNotNil(scroll.lines.builtText(at: last))
        XCTAssertTrue(scroll.contentView.bounds.contains(try XCTUnwrap(scroll.lines.lineRect(at: last))))
    }

    @MainActor func testFindingTheLastWrappedLineKeepsItsStartVisible() throws {
        let scroll = TranscriptCappedLines(style: .diff, cap: 224)
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 224)
        let last = 399
        scroll.lines.update((0...last).map { index in
            .init(mark: "+", text: "line \(index) " + String(repeating: "wrapped text ", count: index == last ? 90 : 30), markColor: .labelColor, background: nil)
        }, environment: .init())
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = scroll; window.orderFront(nil)
        scroll.tile(); scroll.layoutSubtreeIfNeeded()
        XCTAssertNil(scroll.lines.builtText(at: last))
        let estimate = try XCTUnwrap(scroll.lines.lineRect(at: last))
        let offset = scroll.contentView.bounds.height - estimate.height
        let measured = try XCTUnwrap(scroll.lines.revealLine(at: last))
        XCTAssertGreaterThan(measured.height, scroll.contentView.bounds.height)
        XCTAssertEqual(measured.minY - scroll.contentView.bounds.minY, offset, accuracy: 0.5,
                       "Find keeps its target's beginning visible even when the estimated line ended at the document bottom")
        XCTAssertNotNil(scroll.lines.builtText(at: last))
        XCTAssertTrue(scroll.contentView.bounds.contains(NSPoint(x: measured.midX, y: measured.minY + 1)))
    }

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
