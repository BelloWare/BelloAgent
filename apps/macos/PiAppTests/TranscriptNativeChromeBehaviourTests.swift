import AppKit
import XCTest
@testable import PiApp

/// How the transcript's AppKit chrome outside its rows behaves: a reply's
/// markdown controls, the quote bar and the full-table window.
@MainActor final class TranscriptNativeChromeBehaviourTests: XCTestCase {
    private var savedPasteboard: String?
    override func setUp() async throws { savedPasteboard = NSPasteboard.general.string(forType: .string) }
    override func tearDown() async throws {
        NSPasteboard.general.clearContents()
        if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) }
    }

    private func clearPasteboard() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("before", forType: .string) }

    func testAFenceToolbarCopiesItsWholeCodeUnlessThePaneTakesNoInput() {
        let toolbar = MarkdownCodeToolbarView()
        toolbar.update(language: "Swift", code: "let a = 1\nlet b = 2", environment: TranscriptRowEnvironment())
        XCTAssertEqual(toolbar.copy.accessibilityLabel(), "Copy code")
        XCTAssertEqual(toolbar.subviews.compactMap { $0.isAccessibilityElement() ? $0.accessibilityLabel() : nil }, ["Language Swift", "Copy code"])
        clearPasteboard()
        XCTAssertTrue(toolbar.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let a = 1\nlet b = 2")
        var disabled = TranscriptRowEnvironment(); disabled.isEnabled = false
        toolbar.update(language: "Swift", code: "let c = 3", environment: disabled)
        clearPasteboard()
        XCTAssertFalse(toolbar.copy.accessibilityPerformPress(), "a pane that takes no input copies nothing")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")
    }

    /// Space and Return press a Copy, as they pressed SwiftUI's button; it
    /// takes the keyboard only while the pane takes input.
    func testACopyButtonIsPressedFromTheKeyboard() throws {
        let toolbar = MarkdownCodeToolbarView()
        toolbar.update(language: nil, code: "let k = 1", environment: TranscriptRowEnvironment())
        XCTAssertTrue(toolbar.copy.acceptsFirstResponder)
        for key in [" ", "\r"] {
            clearPasteboard()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == " " ? 49 : 36))
            toolbar.copy.keyDown(with: event)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let k = 1", "\(key == " " ? "Space" : "Return") copies")
        }
        var disabled = TranscriptRowEnvironment(); disabled.isEnabled = false
        toolbar.update(language: nil, code: "let k = 1", environment: disabled)
        XCTAssertFalse(toolbar.copy.acceptsFirstResponder)
        XCTAssertFalse(toolbar.copy.isAccessibilityEnabled())
    }

    /// A reply whose pane stops taking input, its text unchanged, stops the
    /// Copy already on screen over its fence at once.
    func testAShownToolbarFollowsThePaneTakingNoInput() throws {
        let source = "```swift\nfunc send() {}\n```\n"
        let (surface, window) = MarkdownTextSurfaceTests.surface(source)
        let text = surface.textView
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let range = (text.string as NSString).range(of: "func send")
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        surface.mouseMoved(with: event)
        let toolbar = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownCodeToolbarView }.first)
        XCTAssertTrue(toolbar.copy.enabled)
        var disabled = TranscriptRowEnvironment(); disabled.isEnabled = false
        surface.read(source: source, style: .prose, capsWidth: true, streaming: false, headings: [], environment: disabled, identity: "reply")
        XCTAssertFalse(toolbar.copy.enabled, "the Copy on screen refuses once the pane takes no input")
        clearPasteboard()
        XCTAssertFalse(toolbar.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")
        withExtendedLifetime(window) {}
    }

    func testAFenceToolbarMirrorsRightToLeft() {
        let toolbar = MarkdownCodeToolbarView()
        var environment = TranscriptRowEnvironment()
        toolbar.update(language: "swift", code: "x", environment: environment)
        toolbar.frame = CGRect(origin: .zero, size: toolbar.fittingSize)
        toolbar.layoutSubtreeIfNeeded()
        let label = toolbar.subviews.first { $0 is TranscriptLabel }!
        XCTAssertLessThan(label.frame.midX, toolbar.copy.frame.midX, "the language before the Copy")
        environment.layoutDirection = .rightToLeft
        toolbar.update(language: "swift", code: "x", environment: environment)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(label.frame.midX, toolbar.copy.frame.midX, "right to left, the language after the Copy")
        XCTAssertTrue(toolbar.copy.rightToLeft)
    }

    func testAHeadingCopyCopiesItsSectionUnlessThePaneTakesNoInput() {
        let target = MarkdownCopyTarget(kind: .section(level: 2), label: "Copy section", text: "## A\n\nB")
        let action = MarkdownHeadingActionView()
        action.update(target: target, environment: TranscriptRowEnvironment())
        XCTAssertEqual(action.target, target)
        XCTAssertEqual(action.copy.accessibilityLabel(), "Copy section")
        clearPasteboard()
        XCTAssertTrue(action.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "## A\n\nB")
        var disabled = TranscriptRowEnvironment(); disabled.isEnabled = false
        action.update(target: target, environment: disabled)
        clearPasteboard()
        XCTAssertFalse(action.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")
    }

    func testOpenFullTableOpensTheTableUnlessThePaneTakesNoInput() throws {
        let mark = MarkdownTableMark(header: [AttributedString("Key")], rows: (0..<50).map { [AttributedString("Row \($0)")] }, large: true)
        let action = MarkdownTableActionView()
        var disabled = TranscriptRowEnvironment(); disabled.isEnabled = false
        action.update(mark: mark, environment: disabled)
        let before = Set(MarkdownTableWindow.open.map(ObjectIdentifier.init))
        XCTAssertFalse(action.button.accessibilityPerformPress())
        XCTAssertEqual(Set(MarkdownTableWindow.open.map(ObjectIdentifier.init)), before, "a pane that takes no input opens nothing")
        action.update(mark: mark, environment: TranscriptRowEnvironment())
        XCTAssertEqual(action.button.accessibilityLabel(), "Open full table")
        XCTAssertEqual(action.button.accessibilityRole(), .button)
        XCTAssertTrue(action.button.accessibilityPerformPress())
        let window = try XCTUnwrap(MarkdownTableWindow.open.first { !before.contains(ObjectIdentifier($0)) })
        defer { window.close() }
        XCTAssertEqual(window.title, "Table · 50 rows")
    }

    func testTheTableWindowCopiesTheWholeTableAsTSV() throws {
        let before = Set(MarkdownTableWindow.open.map(ObjectIdentifier.init))
        MarkdownTableWindow.open(header: [AttributedString("Key"), AttributedString("Value")],
                                 rows: [[AttributedString("a"), AttributedString("1")], [AttributedString("b"), AttributedString("2\t3")]])
        let window = try XCTUnwrap(MarkdownTableWindow.open.first { !before.contains(ObjectIdentifier($0)) })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView as? MarkdownTableWindowContent)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.copy.accessibilityIdentifier(), "table-window-copy")
        XCTAssertEqual(content.copy.frame.maxX, content.bounds.width - PiSpacing.md, accuracy: 0.01, "the Copy at the bar's trailing edge")
        clearPasteboard()
        content.copy.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Key\tValue\na\t1\nb\t\"2\t3\"")
    }

    func testTheQuoteBarLightsUnderThePointerAndAsks() {
        var asked = 0
        let bar = QuoteActionBarView(margin: QuoteActionPanel.margin, ask: { asked += 1 })
        bar.frame = CGRect(origin: .zero, size: bar.fittingSize)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.trigger.accessibilityIdentifier(), "quoteInSideChat")
        XCTAssertEqual(bar.trigger.accessibilityLabel(), "Ask in side chat")
        XCTAssertEqual(bar.trigger.toolTip, "Ask about the selected text in a side chat (Return)")
        // The press target covers the bar, not the room for its shadow.
        let room = bar.bounds.insetBy(dx: QuoteActionPanel.margin, dy: QuoteActionPanel.margin)
        XCTAssertTrue(room.insetBy(dx: -0.5, dy: -0.5).contains(bar.trigger.frame), "\(bar.trigger.frame) in \(room)")
        XCTAssertEqual(bar.trigger.frame.width, room.width, accuracy: 0.5)
        XCTAssertEqual(bar.trigger.frame.height, room.height, accuracy: 0.5)
        let highlight = bar.subviews.compactMap { $0 as? QuoteActionHighlight }.first!
        XCTAssertFalse(highlight.lit)
        bar.trigger.onHover?(true)
        XCTAssertTrue(bar.hovering); XCTAssertTrue(highlight.lit)
        bar.trigger.onHover?(false)
        XCTAssertFalse(highlight.lit)
        bar.trigger.performClick(nil)
        XCTAssertEqual(asked, 1)
    }
}
