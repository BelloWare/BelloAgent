import XCTest
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
        let hosted = WorkspaceRootView(model: model)
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 14) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }; draw() }
        await model.select(bench.chats[0].id)
        await settle(20)
        let field = try XCTUnwrap(Self.views(ComposerTextView.self, in: hosted).first?.enclosingScrollView)
        let composer = field.convert(field.bounds, to: nil)
        model.error = "The gateway rejected the request. " + String(repeating: "Upstream detail that the provider returned verbatim and keeps going. ", count: 120)
        await settle(30)
        let banner = try XCTUnwrap(Self.views(ErrorBannerView.self, in: hosted).first, "The error strip must be on screen")
        let message = banner.message.convert(banner.message.bounds, to: nil)
        print(String(format: "PERF error message %@ in a %.0f point window, composer at %@", NSStringFromRect(message), window.frame.height, NSStringFromRect(composer)))
        XCTAssertLessThanOrEqual(message.height, 60, "A long error stays three lines until it is opened")
        XCTAssertGreaterThan(message.minY, composer.maxY, "The strip must never reach the composer")
        // Open the whole message, copy it, dismiss it: three controls on the strip.
        let controls = [banner.more, banner.copyButton, banner.dismissButton].filter { !$0.isHidden && $0.window != nil }
        XCTAssertEqual(controls.count, 3, "The strip offers More, Copy and Dismiss")
        // The composer still takes typing while the strip is up.
        let editor = try XCTUnwrap(Self.views(ComposerTextView.self, in: hosted).first)
        window.makeFirstResponder(editor)
        type("s", into: editor)
        await settle(10)
        XCTAssertEqual(session.draft, "s", "The strip never blocks the composer")
        banner.dismissButton.performClick(nil)
        XCTAssertNil(model.error, "Dismiss clears the error")
        await settle(30)
        XCTAssertTrue(Self.views(ErrorBannerView.self, in: hosted).isEmpty, "and the strip goes")
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
        func host(_ banner: ErrorBannerView) -> (NSWindow, CGRect) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            window.contentView = content
            content.addSubview(banner)
            banner.frame = CGRect(x: 0, y: 0, width: 640, height: banner.height(forWidth: 640))
            window.makeKeyAndOrderFront(nil)
            banner.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return (window, banner.frame)
        }
        XCTAssertTrue(ErrorBannerView.canExpand(long), "A long message offers to open")
        XCTAssertFalse(ErrorBannerView.canExpand("Short and done."), "A one-line message has nothing to open")

        let collapsed = ErrorBannerView(text: long)
        collapsed.pasteboard = pasteboard
        let (collapsedWindow, shutCard) = host(collapsed)
        defer { collapsedWindow.contentView = nil; collapsedWindow.close() }
        XCTAssertLessThanOrEqual(shutCard.height, 100, "Closed, the strip is a few lines tall, not a wall of text")
        XCTAssertTrue(Self.views(NSScrollView.self, in: collapsed).isEmpty, "A closed strip has nothing to scroll")

        let opened = ErrorBannerView(text: long, expanded: true)
        let (openWindow, openCard) = host(opened)
        defer { openWindow.contentView = nil; openWindow.close() }
        XCTAssertGreaterThan(openCard.height, shutCard.height, "Opening shows more of the message")
        XCTAssertLessThanOrEqual(openCard.height, ErrorBannerView.expandedHeight + 60, "Opened, the strip is still bounded: \(openCard.height) points")
        let scroll = try XCTUnwrap(Self.views(NSScrollView.self, in: opened).first, "The opened message scrolls instead of growing without end")
        XCTAssertLessThanOrEqual(scroll.frame.height, ErrorBannerView.expandedHeight + 0.5)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.frame.height, "The whole message is in the scroll, not truncated")
        print(String(format: "PERF error strip %.0f points closed, %.0f open, holding %.0f points of message",
                     shutCard.height, openCard.height, scroll.documentView?.frame.height ?? 0))

        // More opens and Less closes, in place.
        collapsed.more.performClick(nil)
        XCTAssertTrue(collapsed.expanded); XCTAssertEqual(collapsed.more.title, "Less")
        collapsed.more.performClick(nil)
        XCTAssertFalse(collapsed.expanded); XCTAssertEqual(collapsed.more.title, "More")

        // Copy takes the whole message, not the three lines on screen.
        collapsed.copyButton.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), long, "Copy puts the entire upstream message on the clipboard")
    }
}
