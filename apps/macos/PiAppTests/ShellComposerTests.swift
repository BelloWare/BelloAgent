import AppKit
import XCTest
@testable import PiApp

/// The composer's AppKit pieces on their own: the skill popover's content
/// and the editor field.
@MainActor final class ShellComposerTests: XCTestCase, SerialTestLane {
    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    /// A catalog answer or a file that comes or goes while the popover is up
    /// updates it where it stands: the same text fields (a selection in one
    /// survives), and Open and Reveal follow the file.
    func testTheSkillPopoverUpdatesInPlace() async throws {
        let session = SessionDisplay(id: "popover")
        @MainActor final class State { var detail = ShellParityTests.detail(context: .sent, arguments: "", revision: .checking); var actions = SkillPopoverActions(open: nil, reveal: nil) }
        let state = State()
        let view = SkillPopoverContentView(session: session) { (state.detail, state.actions) }
        view.frame = NSRect(x: 0, y: 0, width: SkillPopovers.popoverWidth, height: view.height(forWidth: SkillPopovers.popoverWidth))
        view.layoutSubtreeIfNeeded()
        let fields = views(ShellSelectableText.self, in: view)
        let file = try XCTUnwrap(fields.first { $0.text == "release-checklist/SKILL.md" })
        func button(_ id: String) throws -> PiKit.Button { try XCTUnwrap(views(PiKit.Button.self, in: view).first { $0.accessibilityIdentifier() == id }) }
        XCTAssertFalse(try button("skill-popover-open").isEnabled)
        XCTAssertNotNil(views(ShellNote.self, in: view).first { $0.text.hasPrefix("Checking") })

        state.detail.revision = .changed(now: "fedcba98")
        state.actions = SkillPopoverActions(open: {}, reveal: {})
        session.objectWillChange.send()
        try await eventually("the popover took the catalog's answer") {
            views(ShellNote.self, in: view).contains { $0.text.hasPrefix("Changed since this message") && !$0.isHiddenOrHasHiddenAncestor }
        }
        XCTAssertTrue(views(ShellSelectableText.self, in: view).contains { $0 === file }, "the source field is the same view")
        XCTAssertTrue(views(ShellSelectableText.self, in: view).contains { $0.text == "01234567 · now fedcba98" })
        XCTAssertTrue(try button("skill-popover-open").isEnabled, "Open follows the file")
        XCTAssertTrue(try button("skill-popover-reveal").isEnabled)

        state.actions = SkillPopoverActions(open: nil, reveal: nil)
        session.objectWillChange.send()
        try await eventually("Open follows the file going") { !((try? button("skill-popover-open").isEnabled) ?? true) }
    }

    /// A field made to hold still, under a low ceiling, is so from the start.
    func testAComposerFieldTakesItsSettingsWhenItIsMade() throws {
        let scroll = NativeComposer(text: "draft", send: { _ in }, maximumFieldHeight: ComposerScrollView.besideTerminalHeight, editable: false).makeView()
        let editor = try XCTUnwrap(scroll.documentView as? ComposerTextView)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(scroll.ceiling, ComposerScrollView.besideTerminalHeight)
    }

    /// The toolbar can be wider than a narrow chat, but the draft still
    /// wraps inside that chat and keeps its leading inset and caret visible.
    func testANarrowComposerWrapsTheDraftInsideItsPaneDespiteToolbarOverflow() async throws {
        let root = scratchRoot("narrow-native-composer")
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["narrow"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var alternate = bench.profile
        alternate.id = "alternate-connection"; alternate.name = "Alternate connection"
        bench.model.profiles.append(alternate)
        let session = SessionDisplay(id: bench.chats[0].id)
        bench.model.displays[session.id] = session
        session.draft = "Now add a unit test for the jitter bounds and show me the diff."
        let view = ComposerInputView(model: bench.model)
        view.paneWidth = 310; view.show(session)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 220))
        host.addSubview(view)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let field = try XCTUnwrap(view.field)
        let editor = try XCTUnwrap(field.documentView as? ComposerTextView)
        let container = try XCTUnwrap(editor.textContainer)
        let manager = try XCTUnwrap(editor.layoutManager)
        editor.setSelectedRange(NSRange(location: (session.draft as NSString).length, length: 0))
        XCTAssertTrue(window.makeFirstResponder(editor))

        var narrowHeight: CGFloat?
        for width: CGFloat in [310, 900, 296, 310] {
            window.setContentSize(NSSize(width: width, height: 220))
            view.paneWidth = width
            try await eventually("The draft wraps to its \(width)-point pane", timeout: .seconds(3)) {
                view.frame = NSRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
                view.layoutSubtreeIfNeeded()
                manager.ensureLayout(for: container)
                editor.reportContentHeight()
                return abs(field.bounds.width - (width - PiSpacing.lg * 2)) <= 0.5
                    && abs(field.bounds.height - field.fieldHeight) <= 0.5
            }
            let frame = view.convert(field.bounds, from: field)
            XCTAssertEqual(frame.minX, PiSpacing.lg, accuracy: 0.5, "The editor retains the card's leading inset")
            XCTAssertEqual(frame.maxX, width - PiSpacing.lg, accuracy: 0.5, "The editor stays inside the pane")
            let first = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
            if width < 400 {
                XCTAssertGreaterThan(view.minimumWidth, width, "This fixture really overflows the toolbar")
                XCTAssertGreaterThan(last.minY, first.minY, "The narrow draft wraps instead of clipping")
                if width == 310 {
                    if let narrowHeight { XCTAssertEqual(field.fieldHeight, narrowHeight, accuracy: 0.5, "Shrinking restores the wrapped field's height") }
                    else { narrowHeight = field.fieldHeight }
                }
            } else {
                XCTAssertEqual(last.minY, first.minY, accuracy: 0.5, "The wide draft fits on one line")
                XCTAssertLessThan(field.fieldHeight, try XCTUnwrap(narrowHeight), "Widening lets the field shrink")
            }
            let glyph = manager.boundingRect(forGlyphRange: NSRange(location: manager.numberOfGlyphs - 1, length: 1), in: container)
            let end = field.contentView.convert(NSPoint(x: glyph.maxX + editor.textContainerOrigin.x,
                                                       y: glyph.maxY + editor.textContainerOrigin.y), from: editor)
            XCTAssertLessThanOrEqual(end.x, field.contentView.bounds.maxX, "The end of the draft is horizontally visible")
            XCTAssertLessThanOrEqual(end.y, field.contentView.bounds.maxY, "The end of the draft is vertically visible")
            XCTAssertTrue(window.firstResponder === editor, "Resizing keeps the editor focused")
            XCTAssertEqual(editor.selectedRange().location, (session.draft as NSString).length, "Resizing preserves the caret")
        }
    }

    /// The chat's actions menu reads the chat when it opens.
    func testTheChatActionsMenuIsBuiltForItsChat() throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("chat-actions-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["menu"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let session = SessionDisplay(id: bench.chats[0].id)
        bench.model.displays[session.id] = session
        let view = ConversationActionsMenuView(model: bench.model, sessionID: session.id)
        view.session = session
        var shown: [NSMenu] = []
        PiMenus.intercept = { menu, _ in shown.append(menu) }
        defer { PiMenus.intercept = nil }
        let control = try XCTUnwrap(views(NSButton.self, in: view).first { $0.accessibilityIdentifier() == "conversationActions" })
        control.performClick(nil)
        let menu = try XCTUnwrap(shown.last)
        XCTAssertTrue(menu.items.contains { $0.identifier?.rawValue == "sessionInspector" })
    }

    /// The window's disabled state (the app preparing to close) reaches the
    /// pane's own controls, and they come back as they were.
    func testThePaneFollowsTheWindowsDisabledState() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("pane-disabled-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["disabled"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let session = SessionDisplay(id: bench.chats[0].id)
        bench.model.displays[session.id] = session
        session.draft = "ready to send"
        let pane = ConversationPaneView(model: bench.model)
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        pane.show(session: session, chat: bench.chats[0])
        pane.layoutSubtreeIfNeeded()
        func button(_ label: String) -> NSButton? { views(NSButton.self, in: pane).first { $0.accessibilityLabel() == label } }
        try await eventually("the composer can send") { button("Send")?.isEnabled == true }
        XCTAssertEqual(button("Skills…")?.isEnabled, true)
        // An edit's banner too: its Cancel.
        session.draftBeforeEdit = DraftRecord(id: session.id, text: "")
        session.editingMessageID = "earlier"
        func cancel() -> NSButton? { views(NSButton.self, in: pane).first { ($0 as? PiKit.Button)?.title == "Cancel" } }
        try await eventually("the edit banner is up") { cancel()?.isEnabled == true }
        pane.inheritedEnabled = false
        try await eventually("the composer stands down") {
            !pane.composer.send.isEnabled && button("Skills…")?.isEnabled == false && cancel()?.isEnabled == false
        }
        pane.inheritedEnabled = true
        try await eventually("the composer comes back") { button("Skills…")?.isEnabled == true && cancel()?.isEnabled == true }
    }
}
