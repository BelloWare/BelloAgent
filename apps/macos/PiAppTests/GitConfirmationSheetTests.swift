import AppKit
import XCTest
@testable import GitView
@testable import PiApp

final class GitConfirmationSheetTests: GitPanelTestCase {
    @MainActor func testAmendUsesAPiSheetWithCompactReviewedIdentity() async throws { try await checkSheet(.amend) }
    @MainActor func testRewordUsesAPiSheetWithCompactReviewedIdentity() async throws { try await checkSheet(.reword) }
    @MainActor func testWhitespaceReviewUsesAPiSheetWithCompactReviewedIdentity() async throws { try await checkSheet(.commit) }
    @MainActor func testLongReviewScrollsInANarrowSheetWithItsWarningAndActionsVisible() async throws {
        try await checkSheet(.amend, width: 310, message: String(repeating: "A longer reviewed message. ", count: 40), project: nil)
    }

    @MainActor func testCheckedCountHintPluralizesFiles() {
        let controller = GitController(roots: []); defer { controller.letGo() }
        var inputs = GitCommitBox.Inputs(controller)
        inputs.scope = .checkedFiles; inputs.message = "Review"
        for count in [1, 2] {
            inputs.checkedCount = count; inputs.entries = count
            let hint = GitCommitBox.presentation(inputs).hint
            XCTAssertTrue(hint.contains("\(count) of \(count) \(count == 1 ? "file" : "files") ·"), hint)
        }
    }

    @MainActor func testConflictsStayInlineWithoutAnAlertOrAnOverrideQuestion() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.conflict()
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        let place = GitPanelPlace(), questions = PiQuestion()
        questions.present = { _, _, answer in XCTFail("Conflicts must never use NSAlert"); answer(.alertSecondButtonReturn) }
        let panel = GitPanelView(controller: controller, place: place, questions: questions)
        let window = host(panel); defer { place.cancelQuestion(); window.close() }
        try await eventually("read conflicts") { controller.isShown && controller.statusRead && !controller.loading }
        controller.commitMessage = "Keep the draft"
        let before = try fixture.snapshot()
        place.requestCommit(controller, context: controller.repositoryContext, reword: true, questions: questions)
        try await eventually("refuse unresolved conflicts") { place.operation?.pending == false }
        XCTAssertEqual(controller.preflight?.conflicts, 1)
        XCTAssertNil(window.attachedSheet); XCTAssertFalse(questions.asking)
        XCTAssertNil(controller.lastCommit); XCTAssertEqual(controller.commitMessage, "Keep the draft")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor func testAChangedTargetAfterPiConfirmationStaysInlineAndDoesNotRewrite() async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", "working\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        let place = GitPanelPlace(), questions = PiQuestion()
        questions.present = { _, _, answer in XCTFail("Stale targets must never use NSAlert"); answer(.alertSecondButtonReturn) }
        let panel = GitPanelView(controller: controller, place: place, questions: questions)
        let window = host(panel); defer { place.cancelQuestion(); window.close() }
        try await eventually("read target") { controller.isShown && controller.statusRead && !controller.loading }
        controller.commitMessage = "Keep the draft"
        place.requestCommit(controller, context: controller.repositoryContext, reword: true, questions: questions)
        try await eventually("show reviewed target") { window.attachedSheet != nil }
        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        let action = try XCTUnwrap(GitOperationSafetyTests.views(PiKit.Button.self, in: content).first { $0.title == "Reword" })
        try fixture.git(["commit", "--allow-empty", "-qm", "A newer commit"])
        let before = try fixture.snapshot()
        action.performClick(nil)
        try await eventually("refuse stale target") { place.operation?.pending == false && !controller.busy }
        XCTAssertTrue(controller.notice.contains("changed"), controller.notice)
        XCTAssertNil(controller.lastCommit); XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(controller.commitMessage, "Keep the draft")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor private func checkSheet(_ kind: GitCommitRequest.Kind, width: CGFloat = 920,
                                      message: String = "The reviewed message", project: String? = "Review fixture") async throws {
        let fixture = try GitSafetyRepository(); defer { fixture.remove() }
        try fixture.seed(); try fixture.write("file.txt", kind == .commit ? "review spaces  \n" : "staged\n")
        try fixture.git(["add", "file.txt"]); try fixture.write("file.txt", "later unstaged work\n")
        let controller = GitController(roots: [fixture.root.path]); defer { controller.letGo() }
        let place = GitPanelPlace(), questions = PiQuestion()
        var usedStockAlert = false
        questions.present = { _, _, answer in usedStockAlert = true; answer(.alertSecondButtonReturn) }
        let panel = GitPanelView(controller: controller, place: place, questions: questions, project: project)
        let window = host(panel, width: width, height: 600)
        defer { place.cancelQuestion(); window.close() }
        try await eventually("read review fixture") { controller.isShown && controller.statusRead && !controller.loading }
        controller.commitMessage = message; controller.amend = kind == .amend
        let before = try fixture.snapshot(), head = try XCTUnwrap(controller.status.head)
        place.requestCommit(controller, context: controller.repositoryContext, reword: kind == .reword, questions: questions)
        try await eventually("present the confirmation") { usedStockAlert || window.attachedSheet != nil || place.operation?.pending == false }
        XCTAssertFalse(usedStockAlert, "Git confirmations must never enter the NSAlert presenter")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.bounds.width, width)
        XCTAssertLessThanOrEqual(content.bounds.height, 600)
        XCTAssertEqual(GitOperationSafetyTests.views(PiKit.Sheet.self, in: content).count, 1)
        XCTAssertTrue(GitOperationSafetyTests.views(NSButton.self, in: content).allSatisfy { $0 is PiKit.ButtonBase })
        let buttons = GitOperationSafetyTests.views(PiKit.Button.self, in: content)
        let action = try XCTUnwrap(buttons.first { $0.title == kind.title })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        XCTAssertEqual(action.keyEquivalent, "")
        // AppKit may transfer the Return equivalent into its default cell.
        XCTAssertTrue(cancel.keyEquivalent == "\r" || sheet.defaultButtonCell === cancel.cell)
        XCTAssertTrue(sheet.defaultButtonCell === cancel.cell)
        XCTAssertEqual(action.style, kind == .commit ? .primary : .danger)
        let lines = GitOperationSafetyTests.views(PiKit.TextLine.self, in: content)
        let repository = try XCTUnwrap(lines.first { $0.accessibilityIdentifier() == "git-question-repository" })
        XCTAssertEqual(repository.line.text, project ?? fixture.root.lastPathComponent)
        let path = try XCTUnwrap(lines.first { $0.accessibilityIdentifier() == "git-question-path" })
        XCTAssertEqual(path.line.text, controller.repositoryRoot); XCTAssertEqual(path.truncation, .middle)
        XCTAssertEqual(path.toolTip, controller.repositoryRoot)
        if kind != .commit {
            let target = try XCTUnwrap(lines.first { $0.accessibilityIdentifier() == "git-question-target" })
            XCTAssertEqual(target.line.text, "main · " + String(head.prefix(9)))
            XCTAssertTrue(target.toolTip?.contains(head) == true)
            XCTAssertTrue(target.accessibilityLabel()?.contains(head) == true)
        }
        let texts = GitOperationSafetyTests.views(ShellText.self, in: content)
        let scope = try XCTUnwrap(texts.first { $0.accessibilityIdentifier() == "git-question-scope" })
        XCTAssertTrue(scope.text.contains(kind == .reword ? "Message only" : "1 file ·"), scope.text)
        XCTAssertFalse(scope.text.contains("1 files"))
        let reviewedMessage = try XCTUnwrap(texts.first { $0.accessibilityIdentifier() == "git-question-message" })
        XCTAssertEqual(reviewedMessage.text, String(message.prefix(500)) + (message.count > 500 ? "…" : ""))
        XCTAssertEqual(reviewedMessage.toolTip, message)
        XCTAssertTrue(reviewedMessage.accessibilityLabel()?.contains(message) == true)
        let warning = try XCTUnwrap(texts.first { $0.accessibilityIdentifier() == "git-question-warning" })
        for view in [warning, cancel, action] as [NSView] {
            XCTAssertTrue(content.bounds.contains(view.convert(view.bounds, to: content)))
        }
        if message.count > 500 {
            let scroll = try XCTUnwrap(GitOperationSafetyTests.views(NSScrollView.self, in: content).first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            XCTAssertTrue(sheet.makeFirstResponder(cancel))
            func press(_ key: UInt16, _ characters: String) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key))
                sheet.sendEvent(event)
            }
            try press(121, "\u{f72d}")
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Long details remain reachable from a focused button with Page Down")
            try press(119, "\u{f72b}")
            XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.height, accuracy: 1)
            try press(116, "\u{f72c}")
            XCTAssertLessThan(scroll.contentView.bounds.maxY, document.bounds.height)
            try press(115, "\u{f729}")
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        }
        if kind != .commit {
            XCTAssertTrue(texts.first { $0.accessibilityIdentifier() == "git-question-warning" }?.text.contains("published history") == true)
        }
        cancel.performClick(nil)
        try await eventually("cancel without writing") { !questions.asking && place.operation?.pending != true }
        XCTAssertEqual(try fixture.snapshot(), before)
    }
}
