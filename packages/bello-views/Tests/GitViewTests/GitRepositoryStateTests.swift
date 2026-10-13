import Combine
import XCTest
@testable import GitView

final class GitRepositoryStateTests: XCTestCase {
    private func repository() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-qb", "main"], in: root)
        try git(["config", "core.hooksPath", "/dev/null"], in: root)
        try "base\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Initial"], in: root)
        try "changed\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @discardableResult private func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
    @MainActor private func read(_ roots: [URL]) async throws -> GitController {
        let controller = GitController(roots: roots.map(\.path))
        addTeardownBlock { @MainActor in controller.letGo(); GitController.statusReadDelay = .zero }
        controller.setShown(true)
        try await wait { controller.statusRead && !controller.loading }
        return controller
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("The expected state never came", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testHidingDuringPublicationDoesNotRestartTheWatcherOrDiff() async throws {
        let root = try repository(), controller = try await read([root])
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        var hidden = false, restarted = false
        let diff = controller.$diffLoading.sink { if hidden && $0 { restarted = true } }
        let watch = controller.$repository.dropFirst().sink { _ in hidden = true; controller.setShown(false) }
        defer { watch.cancel(); diff.cancel() }
        await controller.refresh()
        XCTAssertFalse(controller.isShown)
        XCTAssertFalse(controller.isWatching, "a stopped refresh cannot start a new watch after notifying observers")
        XCTAssertFalse(controller.diffLoading)
        XCTAssertFalse(restarted, "no new diff read starts after the observer hid the panel")
    }

    @MainActor func testChangesAfterTheStatusSnapshotAreCaughtOnOpenResumeAndSwitch() async throws {
        for transition in ["open", "resume", "switch"] {
            let first = try repository(), second = try repository()
            let controller = GitController(roots: [first.path, second.path])
            defer { controller.letGo() }
            if transition != "open" {
                await controller.refresh()
                controller.setShown(false)
            }
            let destination = transition == "switch" ? second : first
            if transition == "switch" { controller.root = second.path }
            let before = controller.repository
            var read = false, watched = false
            controller.statusDidRead = {
                controller.statusDidRead = nil; read = true; watched = controller.isWatching
                XCTAssertTrue(watched, "\(transition): the stream must precede the snapshot")
                XCTAssertEqual(controller.repository, before, "the completed snapshot is still unpublished")
                try "late\n".write(to: destination.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
                // Deliver the save while the snapshot is held. The refresh
                // must drain that event after publishing what Git read earlier.
                try await Task.sleep(for: .milliseconds(1200))
            }
            controller.setShown(true)
            try await wait { read && !controller.loading }
            if watched { try await wait { controller.status.entries.contains { $0.path == "late.txt" } } }
            XCTAssertTrue(controller.status.entries.contains { $0.path == "late.txt" }, transition)
        }
    }

    @MainActor func testSwitchingAgainDuringResetDoesNotRearmTheSupersededRepository() async throws {
        let first = try repository(), second = try repository(), third = try repository()
        let controller = try await read([first, second, third])
        XCTAssertNotNil(controller.selection)
        let watch = controller.$selection.dropFirst().sink { selection in
            if selection == nil { GitController.statusReadDelay = .seconds(2); controller.root = third.path }
        }
        defer { watch.cancel() }
        controller.root = second.path
        try await wait { controller.root == third.path }
        XCTAssertFalse(controller.accepts(controller.repositoryContext), "the superseded reset cannot give B a token for C's generation")
        await controller.stage(["same.txt"], context: controller.repositoryContext)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
    }

    @MainActor func testSlowAndFailedSwitchesKeepTheSnapshotAndRejectItsActions() async throws {
        for failure in [false, true] {
            let first = try repository(), second = try repository(), controller = try await read([first, second])
            let snapshot = controller.repository, context = controller.repositoryContext
            GitController.statusReadDelay = .milliseconds(500)
            if failure { try Data("broken index".utf8).write(to: second.appendingPathComponent(".git/index")) }
            controller.root = second.path
            try await wait { controller.loading }
            XCTAssertEqual(controller.repository, snapshot)
            XCTAssertFalse(controller.accepts(context))
            await controller.stage(["same.txt"], context: context)
            try await wait { !controller.loading }
            if failure {
                XCTAssertEqual(controller.repository, snapshot)
                try FileManager.default.removeItem(at: second.appendingPathComponent(".git/index"))
                try git(["reset", "--mixed", "HEAD"], in: second)
            } else { XCTAssertEqual(controller.repositoryRoot, second.path) }
            await controller.discard(snapshot.status.entries, context: context)
            XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "")
            XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
            XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("same.txt"), encoding: .utf8), "changed\n")
            XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("same.txt"), encoding: .utf8), "changed\n")
            controller.letGo(); GitController.statusReadDelay = .zero
        }
    }

    @MainActor func testASwitchClearsOnlyTheCommitMessageItStartedWith() async throws {
        for edit in ["unchanged", "immediate", "during read", "restarted read"] {
            let first = try repository(), second = try repository(), controller = try await read([first, second])
            defer { controller.letGo(); GitController.statusReadDelay = .zero }
            controller.commitMessage = "Draft from the first repository"
            GitController.statusReadDelay = .milliseconds(300)
            controller.root = second.path
            if edit == "during read" || edit == "restarted read" { try await wait { controller.loading } }
            if edit != "unchanged" { controller.commitMessage = "Draft typed for the second repository" }
            // Replacing a slow read must not adopt the newer draft as the
            // message the repository switch is allowed to clear.
            if edit == "restarted read" { controller.startRefresh() }
            try await wait { controller.repositoryRoot == second.path && !controller.loading }
            XCTAssertEqual(controller.commitMessage, edit == "unchanged" ? "" : "Draft typed for the second repository", edit)
        }
    }

    @MainActor func testACommitReadResumesAfterSwitchingFoldersInTheSameRepository() async throws {
        let root = try repository(), folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = try await read([root, folder])
        controller.panel = .history
        let commit = try XCTUnwrap(controller.commits.first), finished = controller.refreshesFinished
        controller.selectedCommit = commit
        XCTAssertTrue(controller.commitLoading)
        // Switch before the read's task can run: the interrupted selection
        // survives both folder changes, even though its action tokens do not.
        controller.root = folder.path; controller.root = root.path; controller.root = folder.path
        try await wait { controller.refreshesFinished > finished }
        try await wait { !controller.commitLoading }
        XCTAssertEqual(controller.selectedCommit, commit)
        XCTAssertEqual(controller.detail?.commit, commit)
        XCTAssertEqual(controller.detailDiff.map(\.path), ["same.txt"])
    }

    @MainActor func testAWholePatchReadResumesAfterSwitchingFoldersInTheSameRepository() async throws {
        let root = try repository(), folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<31 { try "file \(index)\n".write(to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8) }
        try git(["add", "."], in: root); try git(["commit", "-qm", "Large patch"], in: root)
        let controller = try await read([root, folder]), commit = try XCTUnwrap(controller.commits.first)
        controller.panel = .history; controller.selectedCommit = commit
        try await wait { controller.detailDiffDeferred && !controller.commitLoading }
        let finished = controller.refreshesFinished
        controller.loadDeferredCommitDiff()
        XCTAssertTrue(controller.commitLoading)
        controller.root = folder.path
        try await wait { controller.refreshesFinished > finished }
        try await wait { !controller.commitLoading }
        XCTAssertEqual(controller.selectedCommit, commit)
        XCTAssertEqual(controller.detailDiff.count, 32)
        XCTAssertFalse(controller.detailDiffDeferred)
    }

    @MainActor func testSwitchingRepositoriesClearsAnInvalidSelectionWithoutChoosingTheFirstRow() async throws {
        let first = try repository(), second = try repository()
        try git(["mv", "same.txt", "other.txt"], in: second)
        let controller = try await read([first, second]), finished = controller.refreshesFinished
        XCTAssertEqual(controller.selection?.path, "same.txt")
        controller.root = second.path
        try await wait { controller.refreshesFinished > finished }
        XCTAssertEqual(controller.status.entries.map(\.path), ["other.txt"])
        XCTAssertNil(controller.selection)
        XCTAssertTrue(controller.diff.isEmpty)
    }

    @MainActor func testSwitchingRepositoriesKeepsAStillValidSelection() async throws {
        let first = try repository(), second = try repository(), controller = try await read([first, second])
        try "another row\n".write(to: second.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let selection = controller.selection, finished = controller.refreshesFinished
        controller.root = second.path
        try await wait { controller.refreshesFinished > finished }
        XCTAssertEqual(controller.selection, selection)
        XCTAssertEqual(controller.diff.first?.path, selection?.path)
    }

    @MainActor func testABlameRevealSurvivesTheSharedCommitsRepositoryReset() async throws {
        let root = try repository(), other = root.appendingPathComponent("worktree")
        try git(["worktree", "add", "-qb", "other", other.path], in: root)
        let controller = try await read([root, other]), commit = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = commit; controller.detailFile = "same.txt"
        try await wait { !controller.commitLoading }
        GitController.statusReadDelay = .milliseconds(300)
        controller.root = other.path
        let shown = await controller.revealHistory(GitHistoryTarget(commit: commit.hash, path: "same.txt", line: 1), in: other.path)
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.repositoryRoot, other.path)
        XCTAssertEqual(controller.selectedCommit?.hash, commit.hash)
        XCTAssertEqual(controller.detailFile, "same.txt")
        XCTAssertEqual(controller.revealTarget?.target.line, 1)
    }

    @MainActor func testAReadersChoiceAwayAndBackStillCancelsAPendingReveal() async throws {
        for changeFile in [false, true] {
            let root = try repository(), controller = try await read([root]), commit = try XCTUnwrap(controller.commits.first)
            controller.selectedCommit = commit; controller.detailFile = "same.txt"
            try await wait { !controller.commitLoading }
            controller.setShown(false)
            var entered = false
            let ask = Task {
                entered = true
                return await controller.revealHistory(GitHistoryTarget(commit: commit.hash, path: "same.txt", line: 1), in: root.path)
            }
            try await wait { entered }
            if changeFile { controller.detailFile = nil; controller.detailFile = "same.txt" }
            else { controller.selectedCommit = nil; controller.selectedCommit = commit; controller.detailFile = "same.txt" }
            controller.setShown(true)
            let shown = await ask.value
            XCTAssertFalse(shown, "even a choice back to the same value belongs to the reader")
            XCTAssertNil(controller.revealTarget)
        }
    }

    @MainActor func testAFileChoiceDuringTheRepositoryResetCancelsAPendingReveal() async throws {
        let root = try repository(), other = root.appendingPathComponent("worktree")
        try git(["worktree", "add", "-qb", "other", other.path], in: root)
        let controller = try await read([root, other]), commit = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = commit; controller.detailFile = "same.txt"
        try await wait { !controller.commitLoading }
        var chose = false
        let watch = controller.$detailFile.dropFirst().sink { file in
            guard file == nil, !chose else { return }
            chose = true
            // An observer can choose synchronously during the implicit clear.
            // Coming back to the same file is still a new reader choice.
            controller.detailFile = "reader.txt"; controller.detailFile = "same.txt"
        }
        defer { watch.cancel() }
        GitController.statusReadDelay = .milliseconds(300)
        controller.root = other.path
        let shown = await controller.revealHistory(GitHistoryTarget(commit: commit.hash, path: "same.txt", line: 1), in: other.path)
        XCTAssertTrue(chose)
        XCTAssertFalse(shown)
        XCTAssertNil(controller.revealTarget)
    }
}
