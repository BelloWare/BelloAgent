import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// What the native work rows do that a still capture cannot show: the click,
/// the keys, the focus ring, what VoiceOver hears and can do, the pointer's
/// effect on the leading box, a file link, and a card that grows.
final class TranscriptNativeWorkBehaviourTests: XCTestCase {
    @MainActor final class Stage {
        final class Calls { var toggles = 0; var opened: [String] = [] }
        let calls = Calls()
        let row = TranscriptNativeActionRow()
        let window: NSWindow
        var environment = TranscriptRowEnvironment()
        var tool: ToolView
        var open = false
        init(_ tool: ToolView, open: Bool = false, enabled: Bool = true, rightToLeft: Bool = false, width: CGFloat = 600) {
            self.tool = tool; self.open = open
            environment.isEnabled = enabled
            environment.opensFiles = true
            environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 400))
            window.contentView?.addSubview(row)
            refresh()
            window.makeKeyAndOrderFront(nil)
        }
        func refresh() {
            let calls = calls
            row.update(tool: tool, open: open, fetched: nil, environment: environment, toggle: { calls.toggles += 1 },
                       openFile: { path, _ in calls.opened.append(path) })
            let width = window.contentView!.bounds.width
            row.frame = CGRect(x: 0, y: 0, width: width, height: ceil(row.height(width: width)))
            row.layoutSubtreeIfNeeded()
        }
        var line: TranscriptNativeWorkLine { row.line }
        func key(_ characters: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        /// A click at `point` in the line, through the window.
        func click(_ point: CGPoint) throws {
            let location = line.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        func hover(_ inside: Bool) throws {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            inside ? line.mouseEntered(with: event) : line.mouseExited(with: event)
        }
        func close() { window.orderOut(nil); window.contentView = nil; window.close() }
    }
    static func read(_ state: String = "completed", output: String = "ok") -> ToolView {
        ToolView(id: "r1", name: "read", state: state, input: "{\"path\":\"Sources/App.swift\"}", output: output, durationMs: 940,
                 truncated: false, path: "Sources/App.swift")
    }
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor private func symbols(_ stage: Stage) -> [TranscriptSymbol] { stage.line.subviews.compactMap { $0 as? TranscriptSymbol } }

    /// The whole line is the button: a click anywhere on it opens the row.
    @MainActor func testAClickOnTheLineTogglesTheRow() throws {
        let stage = Stage(Self.read())
        defer { stage.close() }
        try stage.click(CGPoint(x: 8, y: 12))
        try stage.click(CGPoint(x: stage.line.bounds.width - 10, y: 12))
        XCTAssertEqual(stage.calls.toggles, 2)
    }

    /// A click opens the row and leaves keyboard focus where it was: the
    /// composer keeps typing, as a button's click leaves it.
    @MainActor func testAClickLeavesFocusWhereItWas() async throws {
        for native in [true] {
            let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 120))
            window.contentView = canvas
            let field = NSTextField(frame: CGRect(x: 0, y: 90, width: 200, height: 22))
            canvas.addSubview(field)
            var toggles = 0
            let row: NSView
            if native {
                let made = TranscriptNativeActionRow()
                made.update(tool: Self.read(), open: false, fetched: nil, environment: TranscriptRowEnvironment(), toggle: { toggles += 1 }, openFile: nil)
                row = made
            } else {
                row = NSHostingView(rootView: ActionRowView(tool: Self.read(), toggle: { toggles += 1 }).frame(width: 600))
            }
            row.frame = CGRect(x: 0, y: 0, width: 600, height: 24)
            canvas.addSubview(row)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            canvas.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let editor = window.firstResponder
            let location = row.convert(CGPoint(x: 100, y: 12), to: nil)
            // Through the application, as a click arrives.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(toggles, 1, native ? "native" : "SwiftUI")
            XCTAssertTrue(window.firstResponder === editor, "\(native ? "native" : "SwiftUI"): focus moved to \(String(describing: window.firstResponder))")
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }

    /// Space and Return open a focused row; other keys are the conversation's.
    @MainActor func testSpaceAndReturnToggleAFocusedRow() throws {
        let stage = Stage(Self.read())
        defer { stage.close() }
        XCTAssertTrue(stage.window.makeFirstResponder(stage.line))
        try stage.key(" ", code: 49)
        try stage.key("\r", code: 36)
        try stage.key("a", code: 0)
        XCTAssertEqual(stage.calls.toggles, 2)
    }

    /// Focus from the keyboard shows the row's own ring, over exactly the
    /// line, with the marker checks find; losing focus takes it away. Focus
    /// that arrives while the pointer is over the row shows none.
    @MainActor func testKeyboardFocusShowsTheRowsOwnRing() throws {
        let stage = Stage(Self.read())
        defer { stage.close() }
        func rings() -> [CGRect] { views(TranscriptFocusMarkerView.self, in: stage.row).map { $0.convert($0.bounds, to: stage.row) } }
        // The window gives its first key view focus as it becomes key.
        XCTAssertTrue(stage.window.makeFirstResponder(nil))
        XCTAssertEqual(rings(), [])
        XCTAssertTrue(stage.window.makeFirstResponder(stage.line))
        stage.row.layoutSubtreeIfNeeded()
        XCTAssertEqual(rings(), [stage.line.frame], "the ring is the line's own frame")
        XCTAssertTrue(stage.window.makeFirstResponder(nil))
        XCTAssertEqual(rings(), [])
        try stage.hover(true)
        XCTAssertTrue(stage.window.makeFirstResponder(stage.line))
        XCTAssertEqual(rings(), [], "focus from a click leaves no ring")
    }

    /// Closed, the row is its icon; open, the chevron pointing down; under the
    /// pointer, the chevron in place of the icon, pointing right while closed.
    @MainActor func testTheIconTurnsIntoTheChevron() throws {
        let stage = Stage(Self.read())
        defer { stage.close() }
        stage.line.reduceMotion = true
        let symbols = symbols(stage)
        let icon = try XCTUnwrap(symbols.first), chevron = try XCTUnwrap(symbols.last)
        XCTAssertEqual(icon.alphaValue, 1); XCTAssertEqual(chevron.alphaValue, 0); XCTAssertEqual(chevron.rotation, -90)
        try stage.hover(true)
        XCTAssertEqual(icon.alphaValue, 0); XCTAssertEqual(chevron.alphaValue, 1); XCTAssertEqual(chevron.rotation, -90)
        try stage.hover(false)
        stage.open = true; stage.refresh()
        XCTAssertEqual(icon.alphaValue, 0); XCTAssertEqual(chevron.alphaValue, 1); XCTAssertEqual(chevron.rotation, 0)
    }

    /// A failed call says so in its dot and in a word VoiceOver hears; the row
    /// is a button whose value is whether it is open, with "Open File".
    @MainActor func testWhatVoiceOverHearsAndDoes() throws {
        let stage = Stage(Self.read("failed", output: "ENOENT: no such file\nat read"))
        defer { stage.close() }
        let line = stage.line
        XCTAssertEqual(line.accessibilityRole(), .button)
        XCTAssertEqual(line.accessibilityLabel(), "Failed, Read, ENOENT: no such file")
        XCTAssertEqual(line.accessibilityValue() as? String, "Closed")
        XCTAssertEqual(line.toolTip, "Sources/App.swift")
        XCTAssertTrue(line.accessibilityPerformPress())
        XCTAssertEqual(stage.calls.toggles, 1)
        let action = try XCTUnwrap(line.accessibilityCustomActions()?.first { $0.name == "Open File" })
        XCTAssertTrue(action.handler?() ?? false)
        XCTAssertEqual(stage.calls.opened, ["Sources/App.swift"])
        stage.open = true; stage.refresh()
        XCTAssertEqual(line.accessibilityValue() as? String, "Open")
        // A failure's words are not the file's path: no link on the summary.
        XCTAssertTrue(views(PiPopoverTriggerButton.self, in: line).isEmpty)
    }

    /// A pane that takes no input: the row draws, and acts on nothing.
    @MainActor func testADisabledRowRefusesEverything() throws {
        let stage = Stage(Self.read(), enabled: false)
        defer { stage.close() }
        try stage.click(CGPoint(x: 8, y: 12))
        XCTAssertFalse(stage.line.accessibilityPerformPress())
        XCTAssertFalse(stage.line.acceptsFirstResponder)
        XCTAssertFalse(try XCTUnwrap(stage.line.accessibilityCustomActions()?.first { $0.name == "Open File" }).handler?() ?? true)
        let link = try XCTUnwrap(views(PiPopoverTriggerButton.self, in: stage.line).first)
        XCTAssertFalse(link.isEnabled)
        try stage.hover(true)
        XCTAssertFalse(stage.line.hovering, "a disabled row does not light")
        XCTAssertEqual(stage.calls.toggles, 0); XCTAssertEqual(stage.calls.opened, [])
    }

    /// The summary of a file call is a link: its own press target, which
    /// opens the file and not the row. Without files opening here, no link.
    @MainActor func testTheSummaryLinkOpensTheFile() throws {
        let stage = Stage(Self.read())
        defer { stage.close() }
        let link = try XCTUnwrap(views(PiPopoverTriggerButton.self, in: stage.line).first { $0.accessibilityIdentifier() == "transcript-open-file" })
        XCTAssertGreaterThan(link.frame.width, 20)
        link.performClick(nil)
        XCTAssertEqual(stage.calls.opened, ["Sources/App.swift"])
        XCTAssertEqual(stage.calls.toggles, 0)
        stage.environment.opensFiles = false; stage.refresh()
        XCTAssertTrue(views(PiPopoverTriggerButton.self, in: stage.line).isEmpty)
        XCTAssertNil(stage.line.accessibilityCustomActions())
    }

    /// A right-to-left reader's row starts at the right: the icon there, the
    /// trailing figure at the left.
    @MainActor func testARightToLeftRowMirrors() throws {
        let stage = Stage(Self.read(), rightToLeft: true)
        defer { stage.close() }
        let icon = try XCTUnwrap(symbols(stage).first)
        XCTAssertGreaterThan(icon.frame.minX, stage.line.bounds.width - 20)
        let trailing = try XCTUnwrap(stage.line.subviews.compactMap { $0 as? TranscriptLabel }.first { $0.text == "0.9s" })
        XCTAssertLessThan(trailing.frame.maxX, 40)
    }

    /// "… N more lines" shows every line, and the row tells whoever placed it
    /// that it grew; "Show fewer lines" puts the head and the tail back.
    @MainActor func testShowMoreLinesExpandsTheCardAndSaysSo() throws {
        let rows = (1...30).map { "let value\($0) = \($0)" }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "V.swift", "oldText": rows.joined(separator: "\n"),
                                                                                  "newText": rows.map { $0 + " // x" }.joined(separator: "\n")]), as: UTF8.self)
        let stage = Stage(ToolView(id: "e", name: "edit", state: "completed", input: input, output: "ok", durationMs: 10, truncated: false, path: "V.swift"), open: true)
        defer { stage.close() }
        var grew = 0
        stage.row.sizeChanged = { grew += 1 }
        let before = stage.row.height(width: 600)
        let more = try XCTUnwrap(views(TranscriptCardMoreLines.self, in: stage.row).first)
        XCTAssertEqual(more.accessibilityLabel(), "Show 48 more lines")
        XCTAssertTrue(more.accessibilityPerformPress())
        XCTAssertEqual(grew, 1, "the row said it changed size")
        XCTAssertGreaterThan(stage.row.height(width: 600), before)
        XCTAssertEqual(more.accessibilityLabel(), "Show fewer lines")
        XCTAssertTrue(more.accessibilityPerformPress())
        XCTAssertEqual(stage.row.height(width: 600), before)
    }

    /// A running row sweeps, on the render server; a finished one does not.
    @MainActor func testARunningRowSweeps() throws {
        let stage = Stage(ToolView(id: "b", name: "bash", state: "running", input: "{\"command\":\"npm test\"}", output: "", durationMs: nil, truncated: false))
        defer { stage.close() }
        let shimmer = try XCTUnwrap(stage.line.subviews.compactMap { $0 as? TranscriptShimmer }.first)
        shimmer.displayIfNeeded()
        XCTAssertFalse(shimmer.isHidden)
        XCTAssertNotNil(shimmer.layer?.sublayers?.first?.animation(forKey: "sweep"))
        XCTAssertEqual(shimmer.frame, stage.line.bounds, "it covers the line and no more")
        stage.tool.state = "completed"; stage.refresh()
        XCTAssertTrue(shimmer.isHidden)
        XCTAssertNil(shimmer.layer?.sublayers?.first?.animation(forKey: "sweep"), "a finished row stops sweeping")
    }
}
