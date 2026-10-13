import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalSelectionScrollTests: XCTestCase {
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
