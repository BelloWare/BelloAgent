import XCTest
import AppKit
import QuartzCore
@testable import PiApp

/// A stat pill's figure that changes rolls to its new value; the figures of
/// another chat replace the old ones at once (`PiKit.StatPill.scope`). Rolled,
/// a whole pill was drawn again for some twenty frames on every chat switch,
/// the main thread's largest drawing cost there. The pill is its own press
/// target, the same view throughout, and says and opens what it now shows.
final class StatPillRollTests: XCTestCase, SerialTestLane {
    @MainActor func testAnotherChatsFiguresReplaceTheOldOnesWithoutRolling() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 80))
        window.contentView = holder
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = nil }
        var pressed: [Int] = []
        var scope = 1
        let pill = PiKit.StatPill(symbol: "cylinder.split.1x2", label: "7.3K tok · 80 uncached · 40 cached · 7.2K out · Cache hit 33.33% · $0.005", scope: AnyHashable(1))
        pill.onPress = { pressed.append(scope) }
        pill.accessibilityName = "Usage of 1"
        holder.addSubview(pill)
        pill.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: pill.intrinsicContentSize)
        holder.layoutSubtreeIfNeeded(); window.displayIfNeeded()

        // The same chat's figure changes: it rolls.
        pill.update(label: "7.4K tok · 81 uncached · 40 cached · 7.3K out · Cache hit 33.10% · $0.006", scope: AnyHashable(1))
        XCTAssertTrue(pill.isRolling, "A figure of the same chat rolls to its new value")

        // Another chat's figures: replaced at once, a roll in progress included.
        scope = 2
        pill.update(label: "12.9K tok · 400 uncached · 1.2K cached · 11.1K out · Cache hit 75.00% · $0.0213", scope: AnyHashable(2))
        XCTAssertFalse(pill.isRolling, "Another chat's figures do not roll from the old chat's")
        pill.accessibilityName = "Usage of 2"

        // Switching back and forth during a roll also replaces the face;
        // a completion from the cancelled roll cannot remove a later one.
        pill.update(label: "7.4K tok", scope: AnyHashable(1))
        XCTAssertFalse(pill.isRolling)
        pill.update(label: "13.0K tok", scope: AnyHashable(2))
        XCTAssertFalse(pill.isRolling)
        pill.update(label: "13.1K tok", scope: AnyHashable(2))
        XCTAssertTrue(pill.isRolling)
        try await eventually("the new chat's roll finishing", timeout: .seconds(2), poll: .milliseconds(8)) {
            holder.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            return !pill.isRolling
        }

        // The press target is the same view, saying and opening the new chat's.
        XCTAssertTrue(holder.subviews.first === pill)
        XCTAssertEqual(pill.accessibilityLabel(), "Usage of 2")
        pill.performClick(nil)
        XCTAssertEqual(pressed, [2])
    }

    @MainActor func testRollingDigitsDoNotRedrawTheWholePillEveryFrame() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 80))
        window.contentView = holder
        let pill = PiKit.StatPill(symbol: "cylinder.split.1x2", label: "7.3K tok · $0.005", scope: AnyHashable(1))
        holder.addSubview(pill)
        pill.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: pill.intrinsicContentSize)
        window.makeKeyAndOrderFront(nil)
        holder.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        defer { window.contentView = nil; window.close() }
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = nil }
        var wholeDraws = 0
        let draw = pill.content.drawer
        pill.content.drawer = { rect in wholeDraws += 1; draw?(rect) }
        pill.update(label: "7.4K tok · $0.006", scope: AnyHashable(1))
        XCTAssertTrue(pill.isRolling)
        try await eventually("the layer animation finishing", timeout: .seconds(2), poll: .milliseconds(8)) {
            holder.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            return !pill.isRolling
        }
        XCTAssertGreaterThan(wholeDraws, 0, "The test observed the changed face being drawn")
        XCTAssertLessThanOrEqual(wholeDraws, 3, "The glyph layers animate without redrawing the whole pill each frame")
    }
}
