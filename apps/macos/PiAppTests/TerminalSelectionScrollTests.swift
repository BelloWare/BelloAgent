import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalSelectionScrollTests: XCTestCase {
    private func alternateFixture(mode: Int = 1049, limit: Int = 1_000, text: String = "ALT") -> TerminalView {
        let view = TerminalView(emulator: TerminalEmulator(columns: 10, rows: 4, scrollbackLimit: limit))
        resize(view, rows: 4)
        view.emulator.feed("old\r\none\r\ntwo\r\nthree\r\nfour")
        view.emulator.feed("\u{1b}[?\(mode)h\u{1b}[H" + text)
        view.refresh()
        return view
    }

    private func resize(_ view: TerminalView, rows: Int) {
        view.setFrameSize(NSSize(width: 16 + 10 * view.emulator.cellPixelSize.width + 0.25,
                                height: 16 + Double(rows) * view.emulator.cellPixelSize.height))
    }

    func testAlternateSelectionsFollowHiddenHistoryThroughShrinkAndGrowth() {
        for mode in [47, 1047, 1049] { for limit in [1, 1_000] { for direct in [false, true] {
            let view = alternateFixture(mode: mode, limit: limit, text: "ALT\r\nNEXT")
            view.selectAll(nil)
            XCTAssertEqual(view.selectedText, "ALT\nNEXT")
            let origin = view.emulator.trimmedLines + view.emulator.scrollback.count
            for rows in [2, 4] {
                if direct {
                    view.emulator.resize(columns: 10, rows: rows)
                    view.refresh()
                } else { resize(view, rows: rows) }
                if rows == 2 {
                    XCTAssertGreaterThan(view.emulator.trimmedLines + view.emulator.scrollback.count, origin)
                }
                XCTAssertEqual(view.selectedText, "ALT\nNEXT", "mode=\(mode) limit=\(limit) direct=\(direct) rows=\(rows)")
                view.refresh()
                XCTAssertEqual(view.selectedText, "ALT\nNEXT", "refresh must not shift a selection twice")
            }
        } } }
    }

    func testAnAlternateDragAnchorFollowsHiddenHistory() throws {
        let view = alternateFixture(text: "ALTword")
        let width = view.emulator.cellPixelSize.width, y = 8 + view.emulator.cellPixelSize.height / 2
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8.1 + 3 * width, y: y))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8.1 + 7 * width, y: y))
        XCTAssertEqual(view.selectedText, "word")
        resize(view, rows: 2)
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8.1 + 6 * width, y: y))
        XCTAssertEqual(view.selectedText, "wor")
        resize(view, rows: 4)
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8.1 + 5 * width, y: y))
        XCTAssertEqual(view.selectedText, "wo")
        try mouse(view, type: .leftMouseUp, point: .zero)
    }

    func testNormalSelectionsKeepTheirAbsoluteHistoryCoordinatesWhenResizing() {
        let view = alternateFixture()
        view.emulator.feed("\u{1b}[?1049l"); view.refresh()
        view.selectAll(nil)
        let selected = view.selectedText
        XCTAssertEqual(selected, "old\none\ntwo\nthree\nfour")
        for rows in [2, 6, 4] {
            resize(view, rows: rows)
            view.refresh()
            XCTAssertEqual(view.selectedText, selected)
        }
    }

    private func fixture() -> TerminalView {
        let emulator = TerminalEmulator(columns: 40, rows: 8)
        let view = TerminalView(emulator: emulator)
        view.setFrameSize(NSSize(width: 420, height: 176))
        for index in 0..<200 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        return view
    }

    private func mouse(_ view: TerminalView, type: NSEvent.EventType, point: NSPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    func testDraggingBeyondTheTopSelectsPreviouslyOffscreenHistory() throws {
        let view = fixture()
        let oldTop = view.emulator.scrollback.count
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        defer { try? mouse(view, type: .leftMouseUp, point: .zero) }
        print("TERMINAL selection edge scroll=\(view.scrolledBackLines) rows")
        XCTAssertGreaterThan(view.scrolledBackLines, 0)
        let newTop = view.emulator.scrollback.count - view.scrolledBackLines
        XCTAssertLessThan(newTop, oldTop)
        XCTAssertTrue(view.selectedText?.contains(view.emulator.text(atLine: newTop)) == true)
    }

    func testHeldDragAdvancesAndStopsOnReleaseOrReentry() throws {
        let view = fixture()
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        XCTAssertTrue(view.selectionAutoscrollActive)
        let first = view.scrolledBackLines
        for _ in 0..<5 { view.advanceSelectionAutoscroll() }
        XCTAssertGreaterThan(view.scrolledBackLines, first)
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: 60))
        XCTAssertFalse(view.selectionAutoscrollActive)
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        XCTAssertTrue(view.selectionAutoscrollActive)
        try mouse(view, type: .leftMouseUp, point: .zero)
        let released = view.scrolledBackLines
        XCTAssertFalse(view.selectionAutoscrollActive)
        view.advanceSelectionAutoscroll()
        XCTAssertEqual(view.scrolledBackLines, released)
    }

    func testDraggingBelowTheViewportReturnsToTheLiveScreenWithoutShellInput() throws {
        let view = fixture()
        var sent = Data()
        view.onInput = { sent.append($0) }
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        for _ in 0..<10 { view.advanceSelectionAutoscroll() }
        XCTAssertGreaterThan(view.scrolledBackLines, 0)
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: view.bounds.maxY + 50))
        for _ in 0..<20 { view.advanceSelectionAutoscroll() }
        XCTAssertEqual(view.scrolledBackLines, 0)
        XCTAssertFalse(view.selectionAutoscrollActive)
        XCTAssertTrue(sent.isEmpty)
        try mouse(view, type: .leftMouseUp, point: .zero)
    }

    func testScreenSwitchAndDetachmentCancelTheDrag() throws {
        let view = fixture()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: view.bounds)
        window.contentView = content
        content.addSubview(view)
        defer { window.close() }
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        view.removeFromSuperview()
        XCTAssertFalse(view.selectionAutoscrollActive)
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        view.emulator.feed("\u{1b}[?1049h")
        view.refresh()
        XCTAssertFalse(view.selectionAutoscrollActive)
        XCTAssertNil(view.selectedText)
        try mouse(view, type: .leftMouseDown, point: NSPoint(x: 8, y: 60))
        try mouse(view, type: .leftMouseDragged, point: NSPoint(x: 8, y: -50))
        XCTAssertFalse(view.selectionAutoscrollActive)
        XCTAssertEqual(view.scrolledBackLines, 0)
        try mouse(view, type: .leftMouseUp, point: .zero)
    }
}
