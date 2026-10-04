import AppKit
import XCTest
@testable import PiApp

/// ⌘P's list sits where SwiftUI put it: under the title bar, inside the
/// window's safe area, 56 points down, 640 points wide or the window's width
/// less 80 (never under 320), in the middle; clicks in the title bar are
/// not the list's to close it.
@MainActor final class QuickOpenPlacementTests: XCTestCase {
    func testTheListSitsUnderTheTitleBarInTheMiddle() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let quickOpen = QuickOpen()
        let overlay = QuickOpenOverlay(quickOpen: quickOpen, open: { _ in })
        let content = try XCTUnwrap(window.contentView)
        overlay.frame = content.bounds; overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        window.orderFront(nil)
        overlay.layoutSubtreeIfNeeded()
        let top = overlay.safeAreaInsets.top
        XCTAssertGreaterThan(top, 20, "the title bar's height, inside the content view")
        XCTAssertEqual(overlay.panel.frame.minY, top + QuickOpenPanel.top)
        XCTAssertEqual(overlay.panel.frame.width, 640)
        XCTAssertEqual(overlay.panel.frame.midX, 500, accuracy: 0.5)
        window.setContentSize(NSSize(width: 500, height: 700)); overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.panel.frame.width, 420, "the window's width less 80")
        window.setContentSize(NSSize(width: 360, height: 700)); overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.panel.frame.width, 320, "never under 320")
    }
}
