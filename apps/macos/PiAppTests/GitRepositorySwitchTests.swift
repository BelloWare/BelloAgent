import AppKit
import XCTest
@testable import PiApp
@testable import GitView

final class GitRepositorySwitchTests: GitPanelTestCase, SerialTestLane {
    private func changedRepository(_ name: String) throws -> URL {
        let root = try repository(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "base\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Initial"], in: root)
        try "\(name) changed\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @MainActor private func read(_ first: URL, _ second: URL) async throws -> GitController {
        let controller = GitController(roots: [first.path, second.path])
        addTeardownBlock { @MainActor in controller.letGo(); GitController.statusReadDelay = .zero }
        await controller.refresh()
        try await eventually("read the first repository") { controller.statusRead && !controller.loading }
        XCTAssertEqual(controller.repositoryRoot, first.path)
        XCTAssertEqual(controller.status.entries.map(\.path), ["same.txt"])
        return controller
    }

    @MainActor func testASlowSwitchKeepsTheRowsAndRootTogetherAndRefusesStage() async throws {
        let first = try changedRepository("first"), second = try changedRepository("second")
        let controller = try await read(first, second)
        let rows = controller.status.entries
        GitController.statusReadDelay = .seconds(2)
        controller.root = second.path
        try await eventually("start the slow read") { controller.loading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.repositoryRoot, first.path)
        XCTAssertEqual(controller.status.entries, rows)
        await controller.stage(["same.txt"])
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "", "the old row cannot stage the new repository's file")
        try await eventually("finish the slow read") { !controller.loading }
        XCTAssertEqual(controller.repositoryRoot, second.path)
    }

    @MainActor func testAFailedSwitchKeepsTheOldSnapshotButRefusesItsDiscard() async throws {
        let first = try changedRepository("first"), second = try changedRepository("second")
        let controller = try await read(first, second), rows = controller.status.entries
        GitController.statusReadDelay = .milliseconds(300)
        try Data("broken index".utf8).write(to: second.appendingPathComponent(".git/index"))
        controller.root = second.path
        try await eventually("report the failed status read") { !controller.loading && !controller.notice.isEmpty }
        XCTAssertEqual(controller.repositoryRoot, first.path)
        XCTAssertEqual(controller.status.entries, rows)
        // Let a misplaced discard succeed, so preserving both files proves refusal.
        try FileManager.default.removeItem(at: second.appendingPathComponent(".git/index"))
        try git(["reset", "--mixed", "HEAD"], in: second)
        await controller.discard(rows)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("same.txt"), encoding: .utf8), "first changed\n")
        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("same.txt"), encoding: .utf8), "second changed\n")
    }

    @MainActor func testARetainedRowMenuCannotStageAfterSwitchingAwayAndBack() async throws {
        let first = try changedRepository("first"), second = try changedRepository("second")
        let controller = try await read(first, second)
        let row = GitFileRowView(controller: controller, discard: { _ in }, glide: PiKit.SelectionGlide())
        row.apply(entry: try XCTUnwrap(controller.status.entries.first), staged: false, selected: false, checked: true)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: event))
        controller.root = second.path
        try await eventually("read the second repository") { controller.repositoryRoot == second.path && !controller.loading }
        try await perform(menu, controller)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
        controller.root = first.path
        try await eventually("read the first repository again") { controller.repositoryRoot == first.path && !controller.loading }
        try await perform(menu, controller)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "", "returning to the same path cannot revive the old generation")
    }

    @MainActor private func perform(_ menu: NSMenu, _ controller: GitController) async throws {
        let before = controller.refreshesFinished
        menu.performActionForItem(at: 0)
        try await eventually("finish or refuse the menu action") { controller.notice.contains("repository changed") || controller.refreshesFinished > before }
    }

    @MainActor func testIdenticalRowsReceiveTheNewRepositoryContext() async throws {
        let first = try changedRepository("first"), second = try changedRepository("second")
        let controller = try await read(first, second)
        let row = GitFileRowView(controller: controller, discard: { _ in }, glide: PiKit.SelectionGlide())
        let entry = try XCTUnwrap(controller.status.entries.first)
        row.apply(entry: entry, staged: false, selected: false, checked: true)
        controller.root = second.path
        try await eventually("read the second repository") { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertEqual(controller.status.entries, [entry])
        row.apply(entry: entry, staged: false, selected: false, checked: true)
        let buttons = descendants(PiKit.IconButton.self, in: row)
        let stage = try XCTUnwrap(buttons.first)
        stage.onPress?()
        try await eventually("stage the second repository's row") { !controller.staged.isEmpty && !controller.busy }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "same.txt\n")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "")
    }

    @MainActor func testADiscardConfirmationCannotFollowARepositorySwitch() async throws {
        for finishRead in [false, true] {
            let first = try changedRepository("first"), second = try changedRepository("second")
            let controller = try await read(first, second)
            let questions = PiQuestion()
            var answer: ((NSApplication.ModalResponse) -> Void)?
            questions.present = { _, _, complete in answer = complete }
            let panel = GitPanelView(controller: controller, questions: questions)
            let window = host(panel)
            defer { controller.letGo(); window.close(); GitController.statusReadDelay = .zero }
            try await eventually("show the panel") { controller.isShown && !controller.loading }
            panel.refresh()
            let discard = try XCTUnwrap(descendants(PlainTextButton.self, in: panel).first { $0.accessibilityIdentifier() == "git-discard-all" })
            discard.onPress?()
            let confirm = try XCTUnwrap(answer)
            GitController.statusReadDelay = .seconds(1)
            controller.root = second.path
            if finishRead {
                try await eventually("read the second repository") { controller.repositoryRoot == second.path && !controller.loading }
            }
            confirm(.alertFirstButtonReturn)
            try await eventually("refuse the old confirmation") { controller.notice.contains("repository changed") }
            XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("same.txt"), encoding: .utf8), "first changed\n")
            XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("same.txt"), encoding: .utf8), "second changed\n")
        }
    }

    @MainActor func testAnUnchangedRefreshKeepsTheRowsContext() async throws {
        let first = try changedRepository("first"), second = try changedRepository("second")
        let controller = try await read(first, second), context = controller.repositoryContext
        await controller.refresh(automatic: true)
        XCTAssertEqual(controller.repositoryContext, context)
        XCTAssertTrue(controller.accepts(context))
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
}
