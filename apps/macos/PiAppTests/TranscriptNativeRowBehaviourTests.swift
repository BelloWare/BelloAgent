import XCTest
import AppKit
@testable import PiApp

/// What the native rows do that a still capture cannot show: what the pointer
/// brings up, and what a resize does to text set in SwiftUI's line box.
final class TranscriptNativeRowBehaviourTests: XCTestCase {
    @MainActor private func mounted(_ item: TranscriptItem, width: CGFloat = 600) -> (TranscriptRowContainer, NSWindow) {
        let row = TranscriptRowContainer(item: item, fresh: false, actions: TranscriptActions())
        let height = row.measure(width: width).height
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(row)
        row.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row.layoutForViewport()
        window.contentView?.layoutSubtreeIfNeeded()
        return (row, window)
    }

    /// The pointer arriving over a laid-out row brings its pills up at their
    /// size, ready to click — not as zero-sized views nobody laid out.
    @MainActor func testPillsUnderThePointerAreLaidOut() throws {
        let (row, window) = mounted(.message(TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1_000)))
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeUserRow)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         trackingNumber: 0, userData: nil))
        content.mouseEntered(with: event)
        let pills = content.subviews.compactMap { $0 as? TranscriptPillButton }
        XCTAssertEqual(pills.map(\.title), ["Edit", "Copy", "Details"])
        for pill in pills { XCTAssertGreaterThan(pill.frame.width, 20, "\(pill.title) was laid out"); XCTAssertGreaterThan(pill.frame.height, 15) }
    }

    /// A row on screen follows a change of writing direction: its bubble moves
    /// to the other side without anything else changing.
    @MainActor func testAMountedRowMirrorsWhenTheDirectionChanges() throws {
        let item = TranscriptItem.message(TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1_000))
        let (row, window) = mounted(item)
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeUserRow)
        let bubble = { content.subviews.compactMap { $0 as? TranscriptPanel }.first?.frame ?? .zero }
        let before = bubble()
        var environment = TranscriptRowEnvironment(); environment.layoutDirection = .rightToLeft
        row.update(item: item, fresh: false, actions: TranscriptActions(), environment: environment)
        row.layoutSubtreeIfNeeded(); content.layoutSubtreeIfNeeded()
        XCTAssertEqual(bubble().minX, row.bounds.width - before.maxX, accuracy: 0.5, "the bubble stands at the other edge")
    }

    /// VoiceOver's press on a pill does what a click does, and nothing while
    /// the row takes no input.
    @MainActor func testAPillPressedByVoiceOverActs() {
        var pressed = 0
        let pill = TranscriptPillButton(title: "Retry request", accent: true, perform: { pressed += 1 })
        XCTAssertTrue(pill.accessibilityPerformPress())
        pill.enabled = false
        XCTAssertFalse(pill.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
    }

    /// Glyphs sit for the width the text is drawn at: a text that wrapped
    /// while narrow is set as one line again once it is wide again.
    @MainActor func testGlyphsFollowTheWidthTheTextIsDrawnAt() throws {
        let text = TranscriptPlainTextView()
        text.update(text: "A short question that wraps only when narrow", face: .user, environment: TranscriptRowEnvironment(), swiftUILines: true)
        func offset(drawnAt width: CGFloat) -> CGFloat? {
            _ = text.measure(width: width)
            text.frame = CGRect(x: 0, y: 0, width: width, height: 200)
            text.layoutSubtreeIfNeeded(); text.layout()
            return text.textStorage?.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat
        }
        let wide = offset(drawnAt: 600)
        let narrow = offset(drawnAt: 120)
        XCTAssertNotEqual(wide, narrow, "one line and wrapped lines sit differently")
        XCTAssertEqual(offset(drawnAt: 600), wide, "back at a width measured before, the glyphs sit as they did there")
    }
}
