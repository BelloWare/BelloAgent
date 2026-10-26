import AppKit
import XCTest
@testable import PiApp

/// PERF-3: refreshing a chat keeps measurements and pixels whose inputs stayed the same.
@MainActor final class ChatSwitchRefreshTests: XCTestCase {
    private final class ScaleWindow: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    @MainActor private final class Draws {
        var count = 0
        init(_ layer: PiKit.DrawingLayer) {
            let draw = layer.drawer
            layer.drawer = { [self] rect in count += 1; draw?(rect) }
        }
    }

    private func layoutAndDraw(_ button: PiKit.ButtonBase) {
        button.needsLayout = true; button.layoutSubtreeIfNeeded()
        button.content.displayIfNeeded()
        (button as? PiKit.StatPill)?.readingLayer.displayIfNeeded()
    }

    func testTabsKeepTheirLabelMeasurementsAcrossQueriesLayoutsAndSelections() throws {
        let tabs = PiKit.Tabs(selection: 0, items: [(0, "Agents"), (1, "Diff"), (2, "Files")])
        let buttons = try (0..<3).map { try XCTUnwrap(tabs.tab($0)) }
        let size = tabs.intrinsicContentSize
        let before = buttons.map(\.textMeasurements)
        XCTAssertEqual(before, [1, 1, 1], "the counter saw each label measured")
        for index in 0..<10 {
            tabs.selection = index % 3
            tabs.items = [(0, "Agents"), (1, "Diff"), (2, "Files")]
            tabs.frame = CGRect(origin: CGPoint(x: index, y: index), size: size)
            tabs.needsLayout = true; tabs.layoutSubtreeIfNeeded()
            XCTAssertEqual(tabs.intrinsicContentSize, size)
        }
        XCTAssertEqual(buttons.map(\.textMeasurements), before)
    }

    func testTabMeasurementChangesFollowTitlesOrderScaleAndChildInvalidation() throws {
        let window = ScaleWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let tabs = PiKit.Tabs(selection: 0, items: [(0, "Agents"), (1, "Files")])
        window.contentView?.addSubview(tabs)
        let zero = try XCTUnwrap(tabs.tab(0)), one = try XCTUnwrap(tabs.tab(1))
        let original = tabs.intrinsicContentSize
        let before = [zero.textMeasurements, one.textMeasurements]
        tabs.items = [(1, "Files"), (0, "Agents with a longer name")]
        let renamed = tabs.intrinsicContentSize
        XCTAssertGreaterThan(renamed.width, original.width)
        XCTAssertEqual([zero.textMeasurements, one.textMeasurements], [before[0] + 1, before[1]])
        let unchangedTitle = zero.title
        zero.title = unchangedTitle
        XCTAssertEqual(tabs.intrinsicContentSize, renamed)
        XCTAssertEqual(zero.textMeasurements, before[0] + 1)
        one.invalidateIntrinsicContentSize()
        XCTAssertEqual(tabs.intrinsicContentSize, renamed)
        XCTAssertEqual(one.textMeasurements, before[1] + 1, "a child can invalidate its cached size")
        for scale: CGFloat in [1, 2] {
            let counts = [zero.textMeasurements, one.textMeasurements]
            window.scale = scale
            tabs.viewDidChangeBackingProperties()
            let size = tabs.intrinsicContentSize
            XCTAssertEqual(size, tabs.intrinsicContentSize)
            XCTAssertEqual([zero.textMeasurements, one.textMeasurements], counts.map { $0 + 1 })
            tabs.frame.size = size; tabs.needsLayout = true; tabs.layoutSubtreeIfNeeded()
            XCTAssertLessThan(one.frame.minX, zero.frame.minX, "the reordered tabs keep their new order")
            XCTAssertEqual(zero.frame.size, zero.intrinsicContentSize)
        }
        tabs.items = [(1, "Files"), (2, "New")]
        _ = tabs.intrinsicContentSize
        XCTAssertNil(zero.superview)
        XCTAssertEqual(tabs.tab(2)?.textMeasurements, 1)
    }

    func testUnchangedStatPillsKeepTheirGlyphAndReadingAcrossRefreshesAndMoves() {
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "1.0K tok", warningTail: "90%", scope: 1)
        let glyph = Draws(pill.content), reading = Draws(pill.readingLayer)
        pill.frame.size = CGSize(width: 220, height: 28); layoutAndDraw(pill)
        let before = [glyph.count, reading.count]
        XCTAssertTrue(before.allSatisfy { $0 > 0 })
        for index in 0..<10 {
            pill.update(glyph: .symbol("chart.pie"), label: "1.0K tok", warningTail: "90%", scope: index % 2)
            pill.frame.origin = CGPoint(x: index, y: index)
            layoutAndDraw(pill)
        }
        XCTAssertEqual([glyph.count, reading.count], before)
        XCTAssertEqual(pill.scope, AnyHashable(1), "even identical figures belong to the newly shown chat")
        XCTAssertEqual(pill.accessibilityLabel(), "1.0K tok")
    }

    func testStatPillsRedrawTheChangedReadingOrGlyph() {
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "1.0K tok", scope: 1)
        let glyph = Draws(pill.content), reading = Draws(pill.readingLayer)
        pill.frame.size = CGSize(width: 220, height: 28); layoutAndDraw(pill)
        var before = [glyph.count, reading.count]
        pill.update(label: "2.0K tok", scope: 1); layoutAndDraw(pill)
        XCTAssertEqual([glyph.count, reading.count], [before[0], before[1] + 1])
        XCTAssertEqual(pill.accessibilityLabel(), "2.0K tok")
        before = [glyph.count, reading.count]
        pill.update(label: "2.0K tok", warningTail: "90%", scope: 1); layoutAndDraw(pill)
        XCTAssertEqual([glyph.count, reading.count], [before[0], before[1] + 1])
        for next in [PiKit.StatPill.Glyph.symbol("dollarsign.circle"), .ring(nil), .ring(0.5), .symbol("chart.pie")] {
            before = [glyph.count, reading.count]
            pill.update(glyph: next, label: "2.0K tok", warningTail: "90%", scope: 1); layoutAndDraw(pill)
            if next != .ring(0.5) { XCTAssertEqual(glyph.count, before[0] + 1, "a changed glyph clears the old one") }
            XCTAssertEqual(reading.count, before[1], "the unchanged reading keeps its pixels")
            let changed = [glyph.count, reading.count]
            pill.update(glyph: next, label: "2.0K tok", warningTail: "90%", scope: 1); layoutAndDraw(pill)
            XCTAssertEqual([glyph.count, reading.count], changed)
        }
    }

    func testStatPillReadingFollowsSizeAppearanceAndScale() {
        let window = ScaleWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "1.0K tok")
        pill.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(pill)
        let reading = Draws(pill.readingLayer)
        pill.frame.size = CGSize(width: 220, height: 28); layoutAndDraw(pill)
        var before = reading.count
        pill.frame.size.width += 20; layoutAndDraw(pill)
        XCTAssertEqual(reading.count, before + 1)
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            before = reading.count
            pill.appearance = NSAppearance(named: name); pill.readingLayer.displayIfNeeded()
            XCTAssertEqual(reading.count, before + 1, "an appearance change redraws before layout")
            before = reading.count
            layoutAndDraw(pill)
            XCTAssertEqual(reading.count, before, "layout after an appearance change draws nothing twice")
            XCTAssertEqual(pill.readingLayer.appearance?.bestMatch(from: [.aqua, .darkAqua]), name)
        }
        for scale: CGFloat in [1, 2] {
            before = reading.count
            window.scale = scale; pill.viewDidChangeBackingProperties(); pill.readingLayer.displayIfNeeded()
            XCTAssertEqual(reading.count, before + 1, "a backing change redraws before layout")
            XCTAssertEqual(pill.readingLayer.contentsScale, scale)
            layoutAndDraw(pill)
            XCTAssertEqual(reading.count, before + 1)
        }
    }

    func testAnIdenticalReadingKeepsItsRollUntilTheChatChanges() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 100), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "1.0K tok", scope: 1)
        window.contentView?.addSubview(pill)
        pill.frame.size = CGSize(width: 220, height: 28); layoutAndDraw(pill)
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = nil }
        pill.update(label: "1.1K tok", scope: 1)
        XCTAssertTrue(pill.isRolling)
        let layers = pill.face.sublayers
        pill.update(label: "1.1K tok", scope: 1)
        XCTAssertTrue(pill.isRolling)
        XCTAssertEqual(pill.face.sublayers, layers, "an unchanged refresh keeps the existing rolling layers")
        pill.update(label: "1.1K tok", scope: 2)
        XCTAssertFalse(pill.isRolling, "a chat switch ends a roll even when both chats show identical figures")
        XCTAssertEqual(pill.scope, AnyHashable(2))
    }

    func testSidebarLinksRedrawOnlyWhenTheirTitleChanges() {
        let button = SidebarLinkButton(title: "Show more", symbol: "chevron.down", ink: .piInkTertiary, action: {})
        let draws = Draws(button.content)
        button.frame.size = CGSize(width: 220, height: 28); layoutAndDraw(button)
        let before = draws.count
        for _ in 0..<10 { button.title = "Show more"; layoutAndDraw(button) }
        XCTAssertEqual(draws.count, before)
        button.title = "Show 100 more"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1)
        button.title = "Show 100 more"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1)
    }
}
