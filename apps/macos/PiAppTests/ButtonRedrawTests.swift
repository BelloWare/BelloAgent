import AppKit
import XCTest
@testable import PiApp

/// PERF-2: a layout pass may move a button without changing its pixels.
@MainActor final class ButtonRedrawTests: XCTestCase {
    @MainActor private final class Draws {
        var count = 0
        init(_ button: PiKit.ButtonBase) {
            let draw = button.content.drawer
            button.content.drawer = { [self] rect in count += 1; draw?(rect) }
        }
    }

    private final class StateButton: PiKit.ButtonBase {
        override func drawContent(in rect: CGRect) {
            let active = hovering || isPressedDown || !isEffectivelyEnabled || state == .on
            (active ? NSColor.piAccent : .piInk).setFill()
            rect.fill()
        }
    }

    private final class ScaleWindow: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    private func layoutAndDraw(_ button: PiKit.ButtonBase) {
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        button.content.displayIfNeeded()
    }

    private func prepare(_ button: PiKit.ButtonBase) -> Draws {
        button.frame.size = CGSize(width: 180, height: 32)
        let draws = Draws(button)
        layoutAndDraw(button)
        XCTAssertGreaterThan(draws.count, 0, "The counter must see actual content drawing")
        return draws
    }

    func testUnchangedLayoutsAndMovesKeepTheDrawnContent() {
        let tabs = PiKit.Tabs(selection: 0, items: [(0, "Agents"), (1, "Files")])
        let buttons: [PiKit.ButtonBase] = [
            PiKit.Button("Save", symbol: "checkmark"),
            PiKit.IconButton(symbol: "plus", label: "Add"),
            ComposerPillButton(icon: "sparkles", text: "Model", maxTextWidth: 160),
            PiKit.MenuButton(title: "All chats", icon: "magnifyingglass") { [] },
            tabs.tab(0)!
        ]
        for button in buttons {
            let draws = prepare(button), before = draws.count
            for index in 0..<10 {
                button.frame.origin = CGPoint(x: index * 2, y: index)
                layoutAndDraw(button)
            }
            XCTAssertEqual(draws.count, before, "\(type(of: button)) redrew unchanged content")
        }
    }

    func testSizeChangesRedrawOnceAtTheNewSize() {
        let button = PiKit.Button("Save"), draws = prepare(button)
        for size in [CGSize(width: 210, height: 32), CGSize(width: 210, height: 40)] {
            let before = draws.count
            button.frame.size = size
            layoutAndDraw(button)
            XCTAssertEqual(draws.count, before + 1)
            XCTAssertEqual(button.content.bounds.size, size)
            layoutAndDraw(button)
            XCTAssertEqual(draws.count, before + 1, "The changed size is drawn only once")
        }
    }

    func testLabelsAndSymbolsRedrawOnlyWhenChanged() {
        let button = PiKit.Button("Save", symbol: "checkmark"), draws = prepare(button)
        let before = draws.count
        button.title = "Apply"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1)
        button.title = "Apply"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1)
        button.symbol = "plus"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 2)
        button.symbol = "plus"; layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 2)

        let changes: [() -> Void] = [
            { button.style = .primary }, { button.compact = true }, { button.symbolTrailing = true }
        ]
        for change in changes {
            let previous = draws.count
            change(); layoutAndDraw(button)
            XCTAssertEqual(draws.count, previous + 1)
            change(); layoutAndDraw(button)
            XCTAssertEqual(draws.count, previous + 1)
        }
        let icon = PiKit.IconButton(symbol: "plus", label: "Add"), icons = prepare(icon)
        let iconBefore = icons.count
        icon.symbol = "minus"; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 1)
        icon.symbol = "minus"; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 1)
        icon.tone = .danger; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 2)
        icon.tone = .danger; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 2)
        icon.size = 36; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 3)
        icon.size = 36; layoutAndDraw(icon)
        XCTAssertEqual(icons.count, iconBefore + 3)
    }

    func testHoverPressEnabledAndSelectionInvalidateContentWithoutALayout() {
        let button = StateButton(frame: .zero), draws = prepare(button)
        let changes: [() -> Void] = [
            { button.setHovering(true) }, { button.setHovering(false) },
            { button.highlight(true) }, { button.highlight(false) },
            { button.isEnabled = false }, { button.isEnabled = true },
            { button.state = .on }, { button.state = .off }
        ]
        for change in changes {
            let before = draws.count
            change(); button.content.displayIfNeeded()
            XCTAssertEqual(draws.count, before + 1, "State changes redraw even before layout")
            change(); button.content.displayIfNeeded()
            XCTAssertEqual(draws.count, before + 1, "Setting the same state keeps its pixels")
            layoutAndDraw(button)
            XCTAssertEqual(draws.count, before + 1, "Layout after a state change does not draw twice")
        }
    }

    func testPillAndTabSelectionStillRedraw() {
        let pill = ComposerPillButton(icon: "sparkles", text: "Model", maxTextWidth: 160)
        let draws = prepare(pill), before = draws.count
        pill.text = "Another model"; pill.content.displayIfNeeded()
        XCTAssertEqual(draws.count, before + 1)
        pill.active = true; pill.content.displayIfNeeded()
        XCTAssertEqual(draws.count, before + 2)
        layoutAndDraw(pill)
        XCTAssertEqual(draws.count, before + 2)

        let tabs = PiKit.Tabs(selection: 0, items: [(0, "Agents"), (1, "Files")])
        let tab = tabs.tab(0)!, tabDraws = prepare(tab), tabBefore = tabDraws.count
        tabs.selection = 1; tab.content.displayIfNeeded()
        XCTAssertEqual(tabDraws.count, tabBefore + 1)
        layoutAndDraw(tab)
        XCTAssertEqual(tabDraws.count, tabBefore + 1)
    }

    func testAppearanceChangesRedrawWithoutResizing() {
        let button = PiKit.Button("Save"), draws = prepare(button)
        button.appearance = NSAppearance(named: .aqua)
        button.content.displayIfNeeded()
        let before = draws.count
        button.appearance = NSAppearance(named: .darkAqua)
        button.content.displayIfNeeded()
        XCTAssertEqual(draws.count, before + 1)
        XCTAssertEqual(button.content.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1)
    }

    func testBackingScaleChangesRedrawAtTheNewScale() {
        let window = ScaleWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 80), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let button = PiKit.Button("Save")
        window.contentView?.addSubview(button)
        let draws = prepare(button), before = draws.count
        window.scale = 1
        button.viewDidChangeBackingProperties(); button.content.displayIfNeeded()
        XCTAssertEqual(draws.count, before + 1)
        XCTAssertEqual(button.content.contentsScale, 1)
        button.viewDidChangeBackingProperties(); layoutAndDraw(button)
        XCTAssertEqual(draws.count, before + 1, "An unchanged scale does not redraw")
        window.scale = 2
        button.viewDidChangeBackingProperties(); button.content.displayIfNeeded()
        XCTAssertEqual(draws.count, before + 2)
        XCTAssertEqual(button.content.contentsScale, 2)
    }
}
