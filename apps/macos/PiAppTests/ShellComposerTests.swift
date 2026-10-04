import AppKit
import XCTest
@testable import PiApp

/// The composer's AppKit pieces on their own: the skill popover's content
/// and the editor field.
@MainActor final class ShellComposerTests: XCTestCase {
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
