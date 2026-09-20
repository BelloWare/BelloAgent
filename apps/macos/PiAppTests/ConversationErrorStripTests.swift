import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - Errors

extension ConversationPaneTests {
    /// A gateway or storage failure can carry a very long message. The strip
    /// has to stay a strip: it must not grow over the conversation or push the
    /// composer out of reach.
    @MainActor func testALongErrorStaysAStripAndLeavesTheComposerUsable() async throws {
        let scratch = scratchBase()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("pane-error-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bench = try Self.workbench(root: root, chats: ["Errors"])
        let model = bench.model
        defer { model.shutdown() }
        let session = SessionDisplay(id: bench.chats[0].id)
        model.displays[session.id] = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 14) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }; draw() }
        await model.select(bench.chats[0].id)
        await settle(20)
        let field = try XCTUnwrap(Self.views(ComposerTextView.self, in: hosted).first?.enclosingScrollView)
        let composer = field.convert(field.bounds, to: nil)
        let before = Self.tree(hosted).count
        model.error = "The gateway rejected the request. " + String(repeating: "Upstream detail that the provider returned verbatim and keeps going. ", count: 120)
        await settle(20)
        let after = Self.tree(hosted)
        // The strip's own message, laid out: the selectable text it renders.
        var texts: [CGRect] = []
        for entry in after where entry.name.contains("SelectionTextField") { texts.append(entry.frame) }
        let banner = try XCTUnwrap(texts.max { $0.height < $1.height }, "The error strip must be on screen (views \(before) -> \(after.count))")
        print(String(format: "PERF error message %@ in a %.0f point window, composer at %@", NSStringFromRect(banner), window.frame.height, NSStringFromRect(composer)))
        XCTAssertLessThanOrEqual(banner.height, 60, "A long error stays three lines until it is opened")
        XCTAssertGreaterThan(banner.minY, composer.maxY, "The strip must never reach the composer")
        // Open the whole message, copy it, dismiss it: three controls on the strip.
        var controls = 0
        for entry in after where entry.name.contains("FocusRing") && entry.frame.minY >= banner.minY - 30 && entry.frame.maxY <= banner.maxY + 30 { controls += 1 }
        XCTAssertGreaterThanOrEqual(controls, 3, "The strip offers More, Copy and Dismiss")
        // The composer still takes typing while the strip is up.
        let editor = try XCTUnwrap(Self.views(ComposerTextView.self, in: hosted).first)
        window.makeFirstResponder(editor)
        type("s", into: editor)
        await settle(10)
        XCTAssertEqual(session.draft, "s", "The strip never blocks the composer")
        model.error = nil
        await settle(12)
        XCTAssertEqual(Self.views(ComposerTextView.self, in: hosted).first?.string, "s", "Dismissing the strip keeps the draft")
        await model.store?.close()
    }
}

// MARK: - The error strip on its own

extension ConversationPaneTests {
    /// A kilobytes-long gateway message: the strip stays three lines until it
    /// is opened, opens into a bounded scroll rather than a wall of text, and
    /// Copy always takes the whole message.
    @MainActor func testTheErrorStripOpensBoundedAndCopiesTheWholeMessage() throws {
        let long = "The gateway rejected the request. " + String(repeating: "Upstream detail that the provider returned verbatim and keeps going. ", count: 120)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiErrorBannerCopy-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        func host(_ banner: ErrorBanner) -> (NSWindow, NSView, CGRect) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: VStack { banner; Spacer() })
            window.contentView = view; window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // The strip's own card: the rounded background behind it.
            let card = Self.tree(view).filter { $0.name.contains("ShapeHitTesting") }.map(\.frame).max { $0.height < $1.height } ?? .zero
            return (window, view, card)
        }
        XCTAssertTrue(ErrorBanner(text: long, dismiss: {}).canExpand, "A long message offers to open")
        XCTAssertFalse(ErrorBanner(text: "Short and done.", dismiss: {}).canExpand, "A one-line message has nothing to open")

        let (collapsedWindow, collapsed, shutCard) = host(ErrorBanner(text: long, pasteboard: pasteboard, dismiss: {}))
        defer { collapsedWindow.contentView = nil; collapsedWindow.close() }
        XCTAssertLessThanOrEqual(shutCard.height, 100, "Closed, the strip is a few lines tall, not a wall of text")
        XCTAssertTrue(Self.views(NSScrollView.self, in: collapsed).isEmpty, "A closed strip has nothing to scroll")

        let (openWindow, opened, openCard) = host(ErrorBanner(text: long, pasteboard: pasteboard, expanded: true, dismiss: {}))
        defer { openWindow.contentView = nil; openWindow.close() }
        XCTAssertGreaterThan(openCard.height, shutCard.height, "Opening shows more of the message")
        XCTAssertLessThanOrEqual(openCard.height, ErrorBanner.expandedHeight + 60, "Opened, the strip is still bounded: \(openCard.height) points")
        let scroll = try XCTUnwrap(Self.views(NSScrollView.self, in: opened).first, "The opened message scrolls instead of growing without end")
        XCTAssertLessThanOrEqual(scroll.frame.height, ErrorBanner.expandedHeight + 0.5)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.frame.height, "The whole message is in the scroll, not truncated")
        print(String(format: "PERF error strip %.0f points closed, %.0f open, holding %.0f points of message",
                     shutCard.height, openCard.height, scroll.documentView?.frame.height ?? 0))

        // Copy takes the whole message, not the three lines on screen.
        ErrorBanner.copy(long, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), long, "Copy puts the entire upstream message on the clipboard")
    }
}
