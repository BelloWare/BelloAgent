import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalPreciseScrollTests: XCTestCase {
    private func fixture() -> TerminalView {
        let emulator = TerminalEmulator(columns: 40, rows: 8)
        let view = TerminalView(emulator: emulator)
        view.setFrameSize(NSSize(width: 420, height: 176))
        for index in 0..<200 {
            emulator.feed("\u{1b}[\(index.isMultiple(of: 2) ? 41 : 44)m" + String(repeating: " ", count: emulator.columns) + "\u{1b}[0m\r\n")
        }
        view.refresh()
        return view
    }

    private func scroll(_ view: TerminalView, pixels: Int32, momentum: Bool = false) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: pixels, wheel2: 0, wheel3: 0))
        if momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        view.scrollWheel(with: event)
    }

    private func verticalPixels(_ view: TerminalView) throws -> [UInt32] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.bitmapData)
        return (0..<height).map { row in
            let offset = (row * width + 10) * 4
            return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        }
    }

    func testSubCellTrackpadAndMomentumDeltasMoveThePaintedRowsByTheSameDistance() throws {
        for momentum in [false, true] {
            let view = fixture()
            let height = Int32(view.emulator.cellPixelSize.height)
            try scroll(view, pixels: height * 30)
            let before = try verticalPixels(view)
            let origin = view.scrolledBackPoints
            let half = height / 2
            try scroll(view, pixels: half, momentum: momentum)
            let after = try verticalPixels(view)
            print("TERMINAL precise origin movement=\(view.scrolledBackPoints - origin), requested=\(half)")
            XCTAssertEqual(view.scrolledBackPoints - origin, CGFloat(half), accuracy: 0.001)
            for y in (8 + Int(height))..<(before.count - 8 - Int(height) * 2) {
                XCTAssertEqual(after[y + Int(half)], before[y], "every painted band moves with the input")
            }
        }
    }

    func testFractionalOffsetsClampAndResetOnTypingAndAlternateScreen() throws {
        let view = fixture()
        try scroll(view, pixels: 1)
        XCTAssertEqual(view.scrolledBackPoints, 1)
        view.pasteText("x")
        XCTAssertEqual(view.scrolledBackPoints, 0)
        try scroll(view, pixels: 33)
        let saved = view.scrolledBackPoints
        view.emulator.feed("\u{1b}[?1049h")
        view.refresh()
        XCTAssertEqual(view.scrolledBackPoints, 0)
        view.emulator.feed("\u{1b}[?1049l")
        view.refresh()
        XCTAssertEqual(view.scrolledBackPoints, saved)
        try scroll(view, pixels: 100_000)
        XCTAssertEqual(view.scrolledBackPoints, CGFloat(view.emulator.scrollback.count) * CGFloat(view.emulator.cellPixelSize.height))
        try scroll(view, pixels: -1)
        XCTAssertEqual(view.scrolledBackPoints, CGFloat(view.emulator.scrollback.count) * CGFloat(view.emulator.cellPixelSize.height) - 1)
        view.scrollToBottom()
        XCTAssertEqual(view.scrolledBackPoints, 0)
    }

    func testPreciseOffsetSurvivesHiddenOutputAndHeightChanges() throws {
        let view = fixture()
        let height = CGFloat(view.emulator.cellPixelSize.height)
        try scroll(view, pixels: Int32(height * 30 + 3))
        let bottom = CGFloat(view.emulator.trimmedLines + view.emulator.lineCount) * height - view.scrolledBackPoints
        view.emulator.feed("\r\n")
        view.refresh()
        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + 3 * height))
        view.refresh()
        XCTAssertEqual(CGFloat(view.emulator.trimmedLines + view.emulator.lineCount) * height - view.scrolledBackPoints, bottom, accuracy: 0.001)
    }

    func testSelectionHitsThePartiallyVisibleBoundaryRow() throws {
        let emulator = TerminalEmulator(columns: 40, rows: 8)
        let view = TerminalView(emulator: emulator)
        view.setFrameSize(NSSize(width: 420, height: 176))
        for index in 0..<200 { emulator.feed("line \(index)\r\n") }
        view.refresh()
        try scroll(view, pixels: Int32(emulator.cellPixelSize.height * 30) + 3)
        let first = emulator.scrollback.count - view.scrolledBackLines - 1
        for (type, x): (NSEvent.EventType, CGFloat) in [(.leftMouseDown, 8), (.leftMouseDragged, view.bounds.maxX), (.leftMouseUp, view.bounds.maxX)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: 9), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else if type == .leftMouseDragged { view.mouseDragged(with: event) }
            else { view.mouseUp(with: event) }
        }
        XCTAssertEqual(view.selectedText, emulator.text(atLine: first))
    }
}
