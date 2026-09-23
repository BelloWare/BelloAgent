import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Records the frame of the view it is the background of, so a check can
/// compare what is drawn against the row's own bounds.
private struct RowFrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> RowFrameProbeView { RowFrameProbeView() }
    func updateNSView(_ view: RowFrameProbeView, context: Context) {}
}
private final class RowFrameProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Keyboard focus in the transcript. A row that opens with Space or Return
/// shows that it has focus the app's own way, over the whole row, and never
/// with the system's ring, which traced whatever the row happened to be
/// drawing: on a running call, its shimmer, so the ring changed width as the
/// shimmer moved.
final class TranscriptFocusTests: XCTestCase {

    /// A finished call's row and, under it, a running call's row, in a key
    /// window. Focus starts on the first; Tab takes it to the running one.
    @MainActor final class Stage {
        final class Toggles { var count = 0 }
        let toggles = Toggles()
        let window: NSWindow
        let hosted: NSView
        init() {
            let tool = ToolView(id: "t1", name: "bash", state: "running", input: "{\"command\":\"npm test\"}",
                                output: "", durationMs: nil, truncated: false)
            let toggles = self.toggles
            let finished = ToolView(id: "t0", name: "read", state: "done", input: "{\"path\":\"README.md\"}",
                                    output: "Read.", durationMs: 12, truncated: false)
            hosted = NSHostingView(rootView: VStack(spacing: 16) {
                ActionRowView(tool: finished, toggle: {})
                ActionRowView(tool: tool, toggle: { toggles.count += 1 }).background(RowFrameProbe())
            }
            .frame(width: 600).padding(24).background(Color.piContent))
            window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 648, height: 112), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
        }
        func settle(_ turns: Int = 6) async {
            for _ in 0..<turns { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
        }
        /// One key, the way the window delivers it to whatever has focus.
        func press(_ characters: String, keyCode: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        /// The row's own frame, in window coordinates.
        var row: CGRect? {
            ConversationPaneTests.views(RowFrameProbeView.self, in: hosted).first.map { $0.convert($0.bounds, to: nil) }
        }
        /// The rows' own focus outlines that show, with their frames in window coordinates.
        var rings: [CGRect] {
            ConversationPaneTests.views(TranscriptFocusMarkerView.self, in: hosted).filter { $0.window != nil }.map { $0.convert($0.bounds, to: nil) }
        }
        /// What the window server has on screen for this window.
        func capture() throws -> NSBitmapImageRep {
            typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("Window capture unavailable") }
            let create = unsafeBitCast(symbol, to: ListImage.self)
            let screen = NSScreen.screens.first?.frame ?? .zero
            let bounds = CGRect(x: window.frame.minX, y: screen.height - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            guard let image = create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                     CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
            else { throw XCTSkip("Window capture returned no image") }
            return NSBitmapImageRep(cgImage: image)
        }
        /// How many points of the band around `rect`, up to 8 pt out from its
        /// edge, differ between two captures: what is drawn outside the row.
        func changed(around rect: CGRect, _ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
            let scale = CGFloat(first.pixelsWide) / window.frame.width
            // Half a point of the edge is the row's own antialiasing.
            let outer = rect.insetBy(dx: -8, dy: -8), inner = rect.insetBy(dx: -0.5, dy: -0.5)
            var count = 0
            var y = outer.minY
            while y < outer.maxY {
                var x = outer.minX
                while x < outer.maxX {
                    defer { x += 1 }
                    guard !inner.contains(CGPoint(x: x, y: y)) else { continue }
                    let px = Int(x * scale), py = Int((window.frame.height - y) * scale)
                    guard px >= 0, py >= 0, px < first.pixelsWide, py < first.pixelsHigh,
                          let a = first.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                          let b = second.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                    if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)) > 0.015 {
                        count += 1
                    }
                }
                y += 1
            }
            return count
        }
        func close() { window.contentView = nil; window.close() }
    }

    /// A running call's row with keyboard focus draws nothing outside itself:
    /// no system ring around it, no shimmer past its edges, however far the
    /// shimmer has travelled. Space and Return still open and close it.
    @MainActor func testAFocusedRunningRowDrawsNothingAroundItself() async throws {
        let stage = Stage()
        defer { stage.close() }
        await stage.settle(10)
        let row = try XCTUnwrap(stage.row, "The row is not on screen")
        let unfocused = try stage.capture()
        try stage.press("\t", keyCode: 48)
        await stage.settle()
        // The shimmer is somewhere else in each of these.
        var drawn: [Int] = [], rings: [[CGRect]] = []
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(260))
            await stage.settle(2)
            drawn.append(stage.changed(around: row, unfocused, try stage.capture()))
            rings.append(stage.rings)
        }
        XCTAssertEqual(drawn, [0, 0, 0, 0], "Points drawn around the focused row, at four moments of its shimmer")
        // The row says it has focus itself: one outline, exactly the row, the
        // same at every moment of the shimmer.
        XCTAssertEqual(rings, Array(repeating: [row], count: 4), "The focus outline is the row's own frame \(row), whatever the shimmer is doing")
        try stage.press(" ", keyCode: 49)
        await stage.settle()
        XCTAssertEqual(stage.toggles.count, 1, "Space opens the focused row")
        try stage.press("\r", keyCode: 36)
        await stage.settle()
        XCTAssertEqual(stage.toggles.count, 2, "Return opens it too")
        XCTAssertEqual(stage.rings, [row], "Opening and closing leaves the outline where it was")
    }

    /// The line a folded turn reads as takes focus the same way: its own
    /// outline over the whole line, no system ring, Space and Return open it.
    @MainActor func testAFocusedTurnFoldLineDrawsItsOwnOutline() async throws {
        final class Toggles { var count = 0 }
        let toggles = Toggles()
        let spec = TurnFoldSpec(group: "u1", answerResponseID: "a1", toolCalls: 3, messages: 2)
        let hosted = NSHostingView(rootView: VStack(spacing: 16) {
            ActionRowView(tool: ToolView(id: "t0", name: "read", state: "done", input: "{\"path\":\"README.md\"}",
                                         output: "Read.", durationMs: 12, truncated: false), toggle: {})
            TurnFoldControlRow(spec: spec, open: false, toggle: { toggles.count += 1 }).background(RowFrameProbe())
        }
        .frame(width: 600).padding(24).background(Color.piContent))
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 648, height: 128), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() async { for _ in 0..<8 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) } }
        func press(_ characters: String, _ code: UInt16) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        await settle()
        let probe = try XCTUnwrap(ConversationPaneTests.views(RowFrameProbeView.self, in: hosted).first)
        let line = probe.convert(probe.bounds, to: nil)
        try press("\t", 48)
        await settle()
        let rings = ConversationPaneTests.views(TranscriptFocusMarkerView.self, in: hosted).filter { $0.window != nil }.map { $0.convert($0.bounds, to: nil) }
        XCTAssertEqual(rings.count, 1, "The fold line shows its own outline")
        let ring = try XCTUnwrap(rings.first)
        XCTAssertEqual(ring.minX, line.minX, accuracy: 0.5); XCTAssertEqual(ring.width, line.width, accuracy: 0.5, "The outline spans the whole line")
        XCTAssertLessThanOrEqual(ring.height, line.height + 0.5, "and stays within it")
        try press(" ", 49); await settle()
        XCTAssertEqual(toggles.count, 1, "Space opens the fold")
        try press("\r", 36); await settle()
        XCTAssertEqual(toggles.count, 2, "Return too")
    }
}
