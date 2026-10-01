import XCTest
import SwiftUI
@testable import PiApp

/// What the window server shows of the transcript and the composer, written
/// as PNG files into `PI_CAPTURE_DIR` (opt-in): two runs in fresh processes,
/// one with a drawing setting changed (`TEST_RUNNER_PI_APP_ASYNC_DRAWING=1`
/// draws as AppKit does by default), compare file by file
/// (`scripts/compare-captures.py`). The captures are the window server's,
/// not a view drawn into a bitmap, so they include how layers were
/// composited: a long Markdown answer with code, tables and a selection, at
/// its top, middle and end, light and dark, and a pane with a draft.
final class WindowCaptureParityTests: XCTestCase, SerialTestLane {
    private static func section(_ index: Int) -> String {
        """
        ## Result \(index)

        A long reply needs **readable paragraphs**, `inlineCode`, and [a reference](https://example.com/\(index)). The transcript keeps this content selectable while the reader scrolls.

        - First finding with enough explanation to wrap naturally at the viewport width.
        - Second finding with **emphasis** and _italics_.

        ```swift
        let result\(index) = analyze(input: \(index))
        if result\(index).isValid { print("complete") }
        ```

        | Check | Result |
        | --- | --- |
        | Input \(index) | Passed |
        | Output | Preserved |
        """
    }

    @MainActor private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
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

    /// Draws until nothing is left to lay out or draw and the transcript's
    /// document has kept its height for five checks running.
    @MainActor private func settle(_ hosted: NSView, _ window: NSWindow) async throws {
        var last: CGFloat = -1, steady = 0
        try await eventually("the window finishing its drawing", timeout: .seconds(30), poll: .milliseconds(20)) {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let height = ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.enclosingScrollView?.documentView?.frame.height ?? 0
            steady = height == last && !hosted.needsLayout && !window.viewsNeedDisplay ? steady + 1 : 0
            last = height
            return steady >= 5
        }
        CATransaction.flush()
    }

    /// The window server's picture once it has shown everything: two
    /// captures in a row the same.
    @MainActor private func write(_ window: NSWindow, _ name: String, to folder: URL) async throws {
        var previous: Data?, data: Data?
        try await eventually("the window server showing the window as drawn", timeout: .seconds(10), poll: .milliseconds(100)) {
            let now = (try? capture(window))?.representation(using: .png, properties: [:])
            defer { previous = now }
            if let now, now == previous { data = now; return true }
            return false
        }
        try XCTUnwrap(data).write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// A long answer's text is drawn on the main thread: the app turns off
    /// AppKit's asynchronous drawing of large views (`NSViewCanUseGPUAcceleration`
    /// in `BelloAgentApplication.init`), whose glyph rasterizing on threads of
    /// its own held the main thread's SwiftUI text at the font-cache lock.
    @MainActor func testALongAnswersTextIsNotDrawnAsynchronously() async throws {
        if testEnvironment("PI_APP_ASYNC_DRAWING") == "1" { throw XCTSkip("Drawing as AppKit does by default, for a comparison") }
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "NSViewCanUseGPUAcceleration"))
        let answer = (0..<12).map(Self.section).joined(separator: "\n\n")
        let session = SessionDisplay(id: "async-drawing")
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Give a complete report.", turn: "question"),
                            TranscriptMessage(id: "answer", role: "assistant", text: answer, turn: "question")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, actions: TranscriptActions()))
        window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(hosted, window)
        let texts = ConversationPaneTests.views(MarkdownTextView.self, in: hosted).filter { text in
            // AppKit's size, in pixels: 768 × 768.
            let scale = window.backingScaleFactor
            return text.bounds.width * text.bounds.height * scale * scale > 768 * 768
        }
        XCTAssertFalse(texts.isEmpty, "The fixture has a text view larger than AppKit's asynchronous-drawing size")
        func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap { layers($0) } }
        for text in texts {
            let asynchronous = text.layer.map(layers)?.filter(\.drawsAsynchronously) ?? []
            XCTAssertTrue(asynchronous.isEmpty, "\(asynchronous.count) of the text view's layers draw asynchronously")
        }
    }

    @MainActor func testCaptureTheTranscriptAndComposer() async throws {
        guard let path = testEnvironment("PI_CAPTURE_DIR") else { throw XCTSkip("Set PI_CAPTURE_DIR (TEST_RUNNER_PI_CAPTURE_DIR) to capture") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The drawing these captures are of, as AppKit will read it.
        let asynchronous = UserDefaults.standard.bool(forKey: "NSViewCanUseGPUAcceleration")
        XCTAssertEqual(asynchronous, testEnvironment("PI_APP_ASYNC_DRAWING") == "1", "The app did not take the drawing asked for")
        try Data("NSViewCanUseGPUAcceleration \(asynchronous)\n".utf8).write(to: folder.appendingPathComponent("drawing.txt"))
        let answer = (0..<40).map(Self.section).joined(separator: "\n\n")
        let messages = [TranscriptMessage(id: "question", role: "user", text: "Give a complete report.", turn: "question"),
                        TranscriptMessage(id: "answer", role: "assistant", text: answer, turn: "question")]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let session = SessionDisplay(id: "capture-\(dark)")
            session.messages = messages
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = appearance
            let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, actions: TranscriptActions()))
            window.contentView = hosted
            defer { window.contentView = nil; window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(hosted, window)
            let marker = try XCTUnwrap(ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first)
            let scroll = try XCTUnwrap(marker.enclosingScrollView), document = try XCTUnwrap(scroll.documentView)
            let scheme = dark ? "dark" : "light"
            for (name, fraction) in [("top", 0.0), ("middle", 0.5), ("end", 1.0)] {
                let end = max(0, document.frame.height - scroll.contentView.bounds.height)
                marker.page?.readerWillNavigate(upward: true)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: (end * fraction).rounded()))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                try await settle(hosted, window)
                if name == "middle" {
                    // A selection in the text in view.
                    let text = try XCTUnwrap(ConversationPaneTests.views(MarkdownTextView.self, in: hosted).first { $0.visibleRect.height > 80 })
                    let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
                    var shown = text.visibleRect.insetBy(dx: 0, dy: 20)
                    shown.origin.x -= text.textContainerOrigin.x; shown.origin.y -= text.textContainerOrigin.y
                    let visible = manager.characterRange(forGlyphRange: manager.glyphRange(forBoundingRect: shown, in: container), actualGlyphRange: nil)
                    let selected = NSRange(location: visible.location, length: min(120, visible.length))
                    window.makeFirstResponder(text)
                    text.setSelectedRange(selected)
                    try await settle(hosted, window)
                    let drawn = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: selected, actualCharacterRange: nil), in: container)
                        .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                    XCTAssertTrue(drawn.intersects(text.visibleRect), "The selection is in view")
                }
                try await write(window, "transcript-\(scheme)-\(name)", to: folder)
            }
        }
        let pane = try ConversationPaneTests.Pane(messages: Array(messages), height: 700)
        defer { pane.close() }
        pane.session.historyState = .ready
        pane.session.draft = "A draft with **Markdown**, `code` and several words to wrap in the field below the transcript."
        try await settle(pane.hosted, pane.window)
        try await write(pane.window, "pane-draft", to: folder)
    }
}
