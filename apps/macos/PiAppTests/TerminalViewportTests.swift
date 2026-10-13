import AppKit
import XCTest
@testable import PiApp

/// Generated output only: no shell, preferences, pasteboard or app window.
@MainActor final class TerminalViewportTests: XCTestCase {
    private func fixture(limit: Int = 1_000) -> TerminalView {
        let emulator = TerminalEmulator(columns: 40, rows: 8, scrollbackLimit: limit)
        let view = TerminalView(emulator: emulator)
        view.setFrameSize(NSSize(width: 420, height: 176))
        for index in 0..<200 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        return view
    }

    private func scroll(_ view: TerminalView, notches: Int32) throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: notches, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        view.scrollWheel(with: event)
    }

    private func bottomLine(_ view: TerminalView) -> Int {
        view.emulator.trimmedLines + view.emulator.lineCount - view.scrolledBackLines - 1
    }

    func testAlternateScreenShowsImmediatelyAndRestoresTheNormalReadingPosition() throws {
        for mode in [47, 1047, 1049] {
            let view = fixture()
            try scroll(view, notches: 17)
            let offset = view.scrolledBackLines
            view.emulator.feed("\u{1b}[?\(mode)h\u{1b}[HALTERNATE")
            view.refresh()
            XCTAssertEqual(view.scrolledBackLines, 0, "the fullscreen program is visible immediately")
            let first = view.emulator.scrollback.count - view.scrolledBackLines
            XCTAssertEqual(view.emulator.text(atLine: first), "ALTERNATE")
            var sent = Data()
            view.onInput = { sent.append($0) }
            try scroll(view, notches: 1)
            XCTAssertEqual(String(decoding: sent, as: UTF8.self), String(repeating: "\u{1b}[A", count: 3))
            view.emulator.feed("\u{1b}[?\(mode)l")
            view.refresh()
            XCTAssertEqual(view.scrolledBackLines, offset, "return to the normal screen's reading position")
        }
    }

    func testGrowingAndShrinkingPreserveTheBottomVisibleLineThroughRefresh() throws {
        let view = fixture()
        try scroll(view, notches: 17)
        let bottom = bottomLine(view)
        let original = view.frame.size
        let height = CGFloat(view.emulator.cellPixelSize.height)
        for change: CGFloat in [5, 0, -3, 0] {
            view.setFrameSize(NSSize(width: original.width, height: original.height + change * height))
            XCTAssertEqual(bottomLine(view), bottom, "resize holds the bottom visible line")
            view.refresh()
            print("TERMINAL resize bottom displacement=\(bottomLine(view) - bottom)")
            XCTAssertEqual(bottomLine(view), bottom, "resized lines must not be counted again as new output")
        }
    }

    func testOutputBeforeEnteringTheAlternateScreenStillPreservesTheNormalAnchor() throws {
        let view = fixture()
        try scroll(view, notches: 17)
        let bottom = bottomLine(view)
        view.emulator.feed("more\r\n\u{1b}[?1049h")
        view.refresh()
        view.emulator.feed("\u{1b}[?1049l")
        view.refresh()
        XCTAssertEqual(bottomLine(view), bottom)
    }

    func testGrowingAtTheOldestLineClampsBeforeTheNextRefresh() throws {
        let view = fixture()
        try scroll(view, notches: 10_000)
        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + 10 * CGFloat(view.emulator.cellPixelSize.height)))
        XCTAssertLessThanOrEqual(view.scrolledBackLines, view.emulator.scrollback.count)
    }

    func testHiddenLiveOutputDoesNotInvalidateAnUnchangedHistoryViewport() throws {
        let view = fixture()
        try scroll(view, notches: 17)
        let bottom = bottomLine(view)
        // A detached view's needsDisplay is not a record of redraw requests.
        // Observe both AppKit invalidation entry points before they coalesce.
        var requestedDisplay = false
        view.onDisplayInvalidation = { _ in requestedDisplay = true }
        view.needsDisplay = true
        XCTAssertTrue(requestedDisplay, "the probe must observe a full redraw before asserting no redraws")
        var invalidations = 0
        for index in 0..<20 {
            requestedDisplay = false
            view.emulator.feed(index.isMultiple(of: 2) ? "x" : "\r\n")
            view.refresh()
            if requestedDisplay { invalidations += 1 }
            XCTAssertEqual(bottomLine(view), bottom)
        }
        print("TERMINAL hidden output invalidations=\(invalidations)/20")
        XCTAssertEqual(invalidations, 0)
    }

    func testAVisibleLiveRowAndEvictedHistoryStillInvalidate() throws {
        let view = fixture(limit: 200)
        try scroll(view, notches: 1)
        XCTAssertGreaterThan(view.scrolledBackLines, 0)
        XCTAssertLessThan(view.scrolledBackLines, view.rows, "the viewport includes live rows")
        var redrawRects: [NSRect] = []
        view.onDisplayInvalidation = { redrawRects.append($0) }
        view.emulator.feed("\u{1b}[Hchanged")
        view.refresh()
        XCTAssertTrue(redrawRects.contains { !$0.intersection(view.bounds).isEmpty },
                      "the top live row is visible below the history")
        try scroll(view, notches: 10_000)
        let trimmed = view.emulator.trimmedLines
        redrawRects.removeAll()
        view.emulator.feed(String(repeating: "new\r\n", count: 50))
        view.refresh()
        XCTAssertGreaterThan(view.emulator.trimmedLines, trimmed, "output must evict visible history")
        XCTAssertTrue(redrawRects.contains(view.bounds), "evicting the oldest visible line changes the viewport")
        redrawRects.removeAll()
        view.emulator.feed("\u{1b}[3J")
        view.refresh()
        XCTAssertTrue(view.emulator.scrollback.isEmpty)
        XCTAssertTrue(redrawRects.contains(view.bounds), "clearing history shows the live screen")
        XCTAssertEqual(view.scrolledBackLines, 0)
    }
}
