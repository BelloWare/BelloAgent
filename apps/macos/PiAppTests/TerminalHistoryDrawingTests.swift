import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalHistoryDrawingTests: XCTestCase {
    private func fixture() -> TerminalView {
        let emulator = TerminalEmulator(columns: 40, rows: 8, scrollbackLimit: 1_000)
        let view = TerminalView(emulator: emulator)
        view.setFrameSize(NSSize(width: 420, height: 176))
        for index in 0..<700 { emulator.feed("line \(index) 中文\r\n") }
        view.refresh()
        return view
    }

    private func scroll(_ view: TerminalView, notches: Int32) throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: notches, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        view.scrollWheel(with: event)
    }

    private func paint(_ view: TerminalView) {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    func testOverlappingHistoryRepaintsDecodeOnlyNewlyExposedLines() throws {
        let view = fixture()
        try scroll(view, notches: 20)
        paint(view)
        let warm = view.decodedHistoryLineCount
        XCTAssertEqual(warm, view.rows)
        for _ in 0..<10 {
            try scroll(view, notches: 1)
            paint(view)
        }
        print("TERMINAL history decodes after warm=\(view.decodedHistoryLineCount - warm), newly exposed=30")
        XCTAssertEqual(view.decodedHistoryLineCount - warm, 30)
        let beforeReturn = view.decodedHistoryLineCount
        for _ in 0..<10 {
            try scroll(view, notches: -1)
            paint(view)
        }
        XCTAssertEqual(view.decodedHistoryLineCount, beforeReturn, "recent rows survive a direction change")
    }

    func testClearedHistoryAndRearchivedLiveRowsNeverReuseOldCells() {
        let view = fixture()
        let emulator = view.emulator
        _ = view.cellsForDrawing(at: 0)
        emulator.feed("\u{1b}[3J\u{1b}[2J\u{1b}[Hreplacement\r\n" + String(repeating: "\r\n", count: emulator.rows))
        view.refresh()
        XCTAssertEqual(TerminalEmulator.text(of: view.cellsForDrawing(at: 0)), "replacement")

        let tail = emulator.scrollback.count - 1
        _ = view.cellsForDrawing(at: tail)
        emulator.resize(columns: emulator.columns, rows: emulator.rows + 1)
        emulator.feed("\u{1b}[Hedited")
        emulator.feed("\u{1b}[\(emulator.rows);1Hbottom")
        emulator.resize(columns: emulator.columns, rows: 1)
        view.refresh()
        XCTAssertEqual(TerminalEmulator.text(of: view.cellsForDrawing(at: tail)), "edited")
    }

    func testDecodedHistoryRetentionIsBoundedAndKeepsRecentlyReadRows() {
        let view = fixture()
        for index in 0..<view.emulator.scrollback.count { _ = view.cellsForDrawing(at: index) }
        XCTAssertLessThanOrEqual(view.decodedHistoryCacheCount, TerminalView.decodedHistoryLineLimit)
        XCTAssertLessThanOrEqual(view.decodedHistoryBytes, TerminalView.decodedHistoryByteLimit)
        let before = view.decodedHistoryLineCount
        let end = view.emulator.scrollback.count
        for index in (end - 20)..<end { _ = view.cellsForDrawing(at: index) }
        XCTAssertEqual(view.decodedHistoryLineCount, before)
    }

    func testASingleOversizedDecodedRowDoesNotExceedTheCacheByteBudget() {
        let emulator = TerminalEmulator(columns: 100_000, rows: 1)
        let view = TerminalView(emulator: emulator)
        emulator.feed(String(repeating: "x", count: emulator.columns) + "\r\n")
        let cells = view.cellsForDrawing(at: 0)
        XCTAssertEqual(cells.count, 100_000)
        XCTAssertLessThanOrEqual(view.decodedHistoryBytes, TerminalView.decodedHistoryByteLimit)
        XCTAssertEqual(view.decodedHistoryCacheCount, 0)
    }
}
