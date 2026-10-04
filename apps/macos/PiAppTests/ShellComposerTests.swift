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
}
