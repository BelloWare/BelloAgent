import AppKit
import Combine
import XCTest
@testable import PiApp
@testable import GitView

final class GitRepositorySwitchTests: GitPanelTestCase, SerialTestLane {
    @MainActor func testADraftTypedDuringASwitchSurvivesAnotherFolderInThatRepository() async throws {
        let first = try changedRepository("draft-first"), second = try changedRepository("draft-second")
        let folder = second.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = try await read(first, second)
        controller.commitMessage = "old repository draft"
        GitController.statusReadDelay = .milliseconds(500)
        controller.root = second.path
        try await eventually("resolve B while its status is held") { controller.repositoryIdentity?.root == second.path && controller.loading }
        controller.commitMessage = "new repository draft"
        controller.root = folder.path
        try await eventually("publish B's other folder") { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertEqual(controller.commitMessage, "new repository draft")
        await controller.refresh()
        XCTAssertEqual(controller.commitMessage, "new repository draft", "an ordinary refresh retains the draft")
        controller.root = first.path
        try await eventually("return to A") { controller.repositoryRoot == first.path && !controller.loading }
        XCTAssertEqual(controller.commitMessage, "", "B's draft cannot become A's draft")
    }

    @MainActor func testRetypingTheSameMessageDuringASwitchIsStillANewDraft() async throws {
        let first = try changedRepository("retyped-first"), second = try changedRepository("retyped-second")
        let controller = try await read(first, second)
        controller.commitMessage = "same words"
        GitController.statusReadDelay = .milliseconds(500)
        controller.root = second.path
        try await eventually("resolve the new repository") { controller.repositoryIdentity?.root == second.path && controller.loading }
        controller.commitMessage = ""; controller.commitMessage = "same words"
        try await eventually("publish the new status") { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertEqual(controller.commitMessage, "same words", "text equality does not identify the draft's owner")
    }

    @MainActor func testAmendDuringASwitchNeverPrefillsThePreviousRepository() async throws {
        let first = try changedRepository("amend-first"), second = try changedRepository("amend-second")
        try git(["commit", "--allow-empty", "-qm", "ONLY IN A"], in: first)
        let controller = try await read(first, second)
        var messages: [String] = []
        let watch = controller.$commitMessage.sink { messages.append($0) }
        defer { watch.cancel() }
        GitController.statusReadDelay = .milliseconds(500)
        controller.root = second.path
        controller.amend = true
        try await eventually("finish the switch") { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertFalse(messages.contains { $0.contains("ONLY IN A") }, "even a transient prefill must belong to the selected folder")
        XCTAssertEqual(controller.commitMessage, "")
        controller.amend = true
        try await eventually("prefill the resolved repository") { !controller.commitMessage.isEmpty }
        XCTAssertEqual(controller.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines), "Initial")
    }

    @MainActor func testAnAmendPrefillAlreadyReadingCannotFollowASelectionOrAnEdit() async throws {
        for switchFolder in [true, false] {
            let first = try changedRepository("prefill-first"), second = try changedRepository("prefill-second")
            let controller = try await read(first, second)
            var held: CheckedContinuation<Void, Never>?
            controller.headMessageDidRead = { await withCheckedContinuation { held = $0 } }
            defer { held?.resume(); controller.headMessageDidRead = nil }
            controller.amend = true
            try await eventually("hold A's prefill") { held != nil }
            if switchFolder {
                GitController.statusReadDelay = .milliseconds(500)
                controller.root = second.path
            } else {
                controller.commitMessage = "typed"; controller.commitMessage = ""
            }
            held?.resume(); held = nil
            // The prefill resumes ahead of this delayed status read.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(controller.commitMessage, "", "a completed read cannot outlive its folder selection or edit generation")
        }
    }

    @MainActor func testAmendDuringASameRepositorySwitchPrefillsAfterPublication() async throws {
        for beforeResolution in [true, false] {
            let root = try changedRepository("amend-subfolder")
            let folder = root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let controller = try await read(root, folder)
            var held: CheckedContinuation<Void, Never>?, prefills = 0
            controller.statusDidRead = { await withCheckedContinuation { held = $0 } }
            controller.headMessageDidRead = { prefills += 1 }
            defer { controller.statusDidRead = nil; held?.resume(); controller.headMessageDidRead = nil }
            controller.root = folder.path
            if beforeResolution { controller.amend = true }
            try await eventually("hold the subfolder's status") { held != nil }
            if !beforeResolution { controller.amend = true }
            // Let the queued prefill attempt enter while publication is held.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(controller.accepts(controller.repositoryContext))
            XCTAssertEqual(prefills, 0, "the invalidated context cannot start a HEAD read")
            XCTAssertEqual(controller.commitMessage, "")
            controller.statusDidRead = nil; held?.resume(); held = nil
            try await eventually("prefill after the same repository publishes", timeout: 10) {
                !controller.loading && !controller.commitMessage.isEmpty
            }
            print("GIT_DRAFT same repository beforeResolution=\(beforeResolution) prefills=\(prefills)")
            XCTAssertTrue(controller.amend)
            XCTAssertEqual(prefills, 1)
            XCTAssertEqual(controller.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines), "Initial")
        }
    }

    @MainActor func testDeferredAmendPrefillIsRetiredByEditsCancellationAndFolderChanges() async throws {
        for change in ["edit", "uncheck", "folder", "hide"] {
            let root = try changedRepository("cancel-amend-" + change)
            let folder = root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let controller = try await read(root, folder)
            var held: CheckedContinuation<Void, Never>?, prefills = 0
            controller.statusDidRead = { await withCheckedContinuation { held = $0 } }
            controller.headMessageDidRead = { prefills += 1 }
            defer { controller.statusDidRead = nil; held?.resume(); controller.headMessageDidRead = nil }
            controller.root = folder.path
            try await eventually("hold the subfolder's status") { held != nil }
            controller.amend = true
            try await Task.sleep(for: .milliseconds(100))
            let finished = controller.refreshesFinished
            controller.statusDidRead = nil
            switch change {
            case "edit": controller.commitMessage = "typed"; controller.commitMessage = ""
            case "uncheck": controller.amend = false
            case "folder": controller.root = root.path
            default: controller.setShown(false)
            }
            held?.resume(); held = nil
            if change == "hide" {
                controller.setShown(true)
                // A reader refresh also proves that publishing a valid
                // context cannot revive the request retired by hiding.
                await controller.refresh()
            }
            try await eventually("finish reading after " + change) { controller.refreshesFinished > finished && !controller.loading }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(prefills, 0, "\(change) must retire the deferred request, including before its HEAD read")
            XCTAssertEqual(controller.commitMessage, "")
        }
    }

    @MainActor func testADraftInAnUnresolvedFolderIsBoundBeforeTheNextFolderPublishes() async throws {
        let first = try changedRepository("unresolved-first"), second = try changedRepository("unresolved-second")
        let folder = second.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = try await read(first, second)
        controller.root = second.path
        controller.commitMessage = "typed before even resolving B"
        controller.root = folder.path
        try await eventually("resolve the second folder") { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertEqual(controller.commitMessage, "typed before even resolving B")
        // Returning before B can publish must also retire B's new draft.
        controller.root = first.path
        controller.commitMessage = "belongs to A"
        controller.root = second.path
        let before = controller.refreshesFinished
        try await eventually("resolve B again") { controller.refreshesFinished > before && !controller.loading }
        XCTAssertEqual(controller.commitMessage, "")
    }

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

    @MainActor private struct OpenForm {
        let view: GitRepositoryForm
        let submit: ((String) -> Void)?
        let cancel: (() -> Void)?
        var window: NSWindow? { view.window }
    }

    @MainActor private func openForm(_ stash: Bool, in panel: GitPanelView) async throws -> OpenForm {
        panel.refresh(); panel.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(descendants(PiKit.MenuButton.self, in: panel).first { $0.accessibilityIdentifier() == (stash ? "git-stash-menu" : "git-branch-menu") })
        if stash {
            let item = try XCTUnwrap(menu.entries().compactMap { entry -> PiMenuItem? in
                guard case .item(let item) = entry, item.title == "New Stash…" else { return nil }; return item
            }.first)
            item.perform()
        } else {
            menu.onPress?()
            var branches: GitBranchesPopover?
            try await eventually("open the branch popup", timeout: 3) {
                branches = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { self.descendants(GitBranchesPopover.self, in: $0) }.first
                return branches?.catalog != nil
            }
            try XCTUnwrap(branches).newBranch.onPress?()
        }
        var form: GitRepositoryForm?
        try await eventually("open the name form", timeout: 3) {
            form = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { self.descendants(GitRepositoryForm.self, in: $0) }.first
            return form != nil
        }
        let view = try XCTUnwrap(form), submit = view.submit
        return OpenForm(view: view, submit: { value in view.field.text = value; submit?() }, cancel: view.field.onCancel)
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
