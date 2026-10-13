import AppKit
import Combine
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
        try await refusesWrite(controller) { menu.performActionForItem(at: 0) }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
        controller.root = first.path
        try await eventually("read the first repository again") { controller.repositoryRoot == first.path && !controller.loading }
        try await refusesWrite(controller) { menu.performActionForItem(at: 0) }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "", "returning to the same path cannot revive the old generation")
    }

    @MainActor private func refusesWrite(_ controller: GitController, action: () -> Void) async throws {
        var started = false
        let watch = controller.$busy.sink { if $0 { started = true } }
        defer { watch.cancel() }
        action()
        // Give an incorrectly queued write a turn to enter, even when its
        // eventual status read would be suppressed by the hidden panel.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(started, "the stale control must refuse before starting a write")
    }

    @MainActor func testARetainedRowCannotStartAWriteAfterThePanelHides() async throws {
        for menuAction in [true, false] {
            let root = try changedRepository("hidden-row"), controller = try await read(root, root)
            let row = GitFileRowView(controller: controller, discard: { _ in }, glide: PiKit.SelectionGlide())
            row.apply(entry: try XCTUnwrap(controller.status.entries.first), staged: false, selected: false, checked: true)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(row.menu(for: event)), stage = try XCTUnwrap(descendants(PiKit.IconButton.self, in: row).first)
            controller.setShown(false)
            try await refusesWrite(controller) { if menuAction { menu.performActionForItem(at: 0) } else { stage.onPress?() } }
            XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: root), "")
        }
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
            try await refusesWrite(controller) { confirm(.alertFirstButtonReturn) }
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

    @MainActor private func openForm(_ stash: Bool, in panel: GitPanelView) async throws -> GitNamePopover {
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(descendants(PiKit.MenuButton.self, in: panel).first { $0.accessibilityIdentifier() == (stash ? "git-stash-menu" : "git-branch-menu") })
        guard case .item(let item) = menu.entries().first else { throw NSError(domain: "Git form", code: 1) }
        item.perform()
        var form: GitNamePopover?
        try await eventually("open the name form", timeout: 3) {
            form = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { self.descendants(GitNamePopover.self, in: $0) }.first
            return form != nil
        }
        return try XCTUnwrap(form)
    }

    @MainActor func testOpenFormsSurviveStatusChangesAndFoldersInTheSameRepository() async throws {
        PiKit.Motion.reducedOverride = true; defer { PiKit.Motion.reducedOverride = nil }
        for stash in [false, true] { for switchFolder in [false, true] {
            let root = try changedRepository("forms"), folder = root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Stash removes empty untracked directories; this project folder
            // must remain present so its resulting status can still be read.
            try "tracked\n".write(to: folder.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            try git(["add", "folder/keep.txt"], in: root); try git(["commit", "-qm", "Project folder"], in: root)
            let controller = try await read(root, folder), panel = GitPanelView(controller: controller), window = host(panel)
            defer { controller.letGo(); window.close() }
            try await eventually("show the panel") { controller.isShown && !controller.loading }
            let form = try await openForm(stash, in: panel), before = controller.repositoryContext
            if switchFolder {
                let finished = controller.refreshesFinished
                controller.root = folder.path
                try await eventually("read the other project folder") { controller.refreshesFinished > finished }
            } else {
                try "agent\n".write(to: root.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
                try git(["add", "agent.txt"], in: root)
                await controller.refresh(automatic: true)
            }
            try await eventually("publish the refreshed row context") { controller.repositoryContext != before && !controller.loading }
            XCTAssertTrue(form.window?.isVisible == true, "a status snapshot does not dismiss the form")
            form.submit?("from-form")
            try await eventually("perform \(stash ? "Stash" : "New Branch") after \(switchFolder ? "switching folders" : "status refresh")", timeout: 6) {
                !controller.busy && (stash ? !controller.stashes.isEmpty : controller.status.branch == "from-form")
            }
            if stash { XCTAssertTrue(try git(["stash", "list"], in: root).contains("from-form")) }
            else { XCTAssertEqual(try git(["branch", "--show-current"], in: root), "from-form\n") }
        } }
    }

    @MainActor func testOpenFormsCloseWithAnExplanationOnRealAndFailedRepositorySwitches() async throws {
        PiKit.Motion.reducedOverride = true; defer { PiKit.Motion.reducedOverride = nil }
        for stash in [false, true] { for failure in [false, true] {
            let first = try changedRepository("form-first"), second = try changedRepository("form-second")
            let controller = try await read(first, second), panel = GitPanelView(controller: controller), window = host(panel)
            defer { controller.letGo(); window.close(); GitController.statusReadDelay = .zero }
            try await eventually("show the panel") { controller.isShown && !controller.loading }
            let form = try await openForm(stash, in: panel), submit = form.submit
            if failure { try Data("broken index".utf8).write(to: second.appendingPathComponent(".git/index")) }
            GitController.statusReadDelay = .milliseconds(300)
            controller.root = second.path
            try await eventually("start the switch") { controller.loading }
            try await eventually("finish or fail the switch") { !controller.loading }
            panel.refresh()
            XCTAssertFalse(form.window?.isVisible == true)
            XCTAssertTrue(descendants(PiKit.TextLine.self, in: panel).contains { $0.line.text.lowercased().contains("repository changed") })
            try await refusesWrite(controller) { submit?("stale-form") }
            controller.root = first.path
            try await eventually("start the return") { controller.loading }
            try await eventually("finish the return") { !controller.loading && controller.repositoryRoot == first.path }
            try await refusesWrite(controller) { submit?("stale-form") }
            XCTAssertEqual(try git(["branch", "--list", "stale-form"], in: first), "")
            XCTAssertEqual(try git(["stash", "list"], in: first), "")
            form.cancel?()
        } }
    }

    @MainActor func testACancelledFormCannotSubmitAfterAnotherFormOpens() async throws {
        PiKit.Motion.reducedOverride = true; defer { PiKit.Motion.reducedOverride = nil }
        for stash in [false, true] {
            let root = try changedRepository("cancelled-form"), controller = try await read(root, root)
            let panel = GitPanelView(controller: controller), window = host(panel)
            defer { controller.letGo(); window.close() }
            try await eventually("show the panel") { controller.isShown && !controller.loading }
            let old = try await openForm(stash, in: panel), submit = old.submit
            old.cancel?()
            let current = try await openForm(stash, in: panel)
            try await refusesWrite(controller) { submit?("cancelled-form") }
            XCTAssertTrue(current.window?.isVisible == true)
            current.cancel?()
        }
    }
}
