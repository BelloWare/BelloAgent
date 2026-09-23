import XCTest
import SwiftUI
import AppKit
import CoreServices
@testable import PiApp

final class GitWorkingTreeWatcherTests: GitPanelTestCase {
    func testLargeGitPatchFailsExplicitlyAndLeavesOtherReadsWorking() async throws {
        let root = try repository("git-large-patch"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let file = root.appendingPathComponent("large.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try String(repeating: "changed\n", count: 2_500_000).write(to: file, atomically: true, encoding: .utf8)
        let service = GitService()
        do { _ = try await service.run(["diff", "--", "large.txt"], in: root.path); XCTFail("Oversized patch returned as complete") }
        catch { XCTAssertTrue(error.localizedDescription.contains("16 MiB"), error.localizedDescription) }
        let status = try await service.run(["status", "--porcelain"], in: root.path)
        XCTAssertTrue(status.text.contains("large.txt"))
        let running = await service.processesRunning; XCTAssertEqual(running, 0)
    }

    @MainActor func testBackgroundWatchDeliveryCannotReachAReplacementGeneration() async throws {
        let root = try repository("git-watch-generation")
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 0) {
            MainActor.assertIsolated(); XCTAssertTrue(Thread.isMainThread); changes += 1
        }
        watcher.start(); defer { watcher.stop() }
        let old = try XCTUnwrap(watcher.bridge)
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            old.deliver([root.path + "/external.txt"], [0]); delivered.signal()
        }
        // Hold MainActor until the old callback has queued its actor hop.
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        watcher.stop(); watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes, 0, "An already-copied callback belongs to the old stream")
        let current = try XCTUnwrap(watcher.bridge)
        await Task.detached { current.deliver([root.path + "/external.txt"], [0]) }.value
        try await eventually("deliver the current generation on MainActor") { changes == 1 }
        await Task.detached { current.deliver([root.path + "/.git/objects/ab/cd"], [0]) }.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes, 1)
    }

    @MainActor func testFSEventsContextRetainAndFinalReleaseWorkOffMain() async throws {
        let root = try repository("git-watch-release")
        defer { try? FileManager.default.removeItem(at: root) }
        var bridge: GitWatchBridge? = GitWatchBridge { @Sendable _, _ in }
        weak var observed = bridge
        var context = gitWatchContext(try XCTUnwrap(bridge))
        let stream = try XCTUnwrap(FSEventStreamCreate(nil, { _, _, _, _, _, _ in }, &context,
            [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, 0))
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "test.watch.release"))
        let started = FSEventStreamStart(stream)
        let owner = GitWatchStream(); owner.adopt(stream)
        bridge = nil
        XCTAssertNotNil(observed, "FSEvents retains the borrowed context on creation")
        await Task.detached { owner.stop() }.value
        try await eventually("release the FSEvents context after queued callbacks drain") { observed == nil }
        XCTAssertTrue(started)
        // Invalidate/release before start is also a valid ownership path.
        var unstarted: GitWatchBridge? = GitWatchBridge { @Sendable _, _ in }
        weak var weakUnstarted = unstarted
        var second = gitWatchContext(try XCTUnwrap(unstarted))
        let created = try XCTUnwrap(FSEventStreamCreate(nil, { _, _, _, _, _, _ in }, &second,
            [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, 0))
        unstarted = nil; XCTAssertNotNil(weakUnstarted)
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "test.watch.unstarted"))
        FSEventStreamInvalidate(created); FSEventStreamRelease(created)
        try await eventually("release an unstarted context") { weakUnstarted == nil }
    }

    // MARK: Noticing the working tree

    /// A refresh nobody asked for must leave the reader exactly where they are.
    @MainActor func testAnAutomaticRefreshNeverMovesTheReader() async throws {
        let root = try repository("git-watch-still"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for name in ["a.txt", "b.txt", "c.txt"] { try "one\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for name in ["a.txt", "b.txt"] { try "one\ntwo\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        let controller = GitController(roots: [root.path])
        try await eventually("read two changed files") { controller.status.entries.count == 2 && !controller.loading }
        controller.selection = GitController.Selection(path: "a.txt", staged: false)
        try await eventually("read a.txt") { !controller.diffLoading && controller.diff.first?.path == "a.txt" }
        controller.checked = ["a.txt"]
        controller.wholeDiffShown = GitController.diffIdentity(path: "a.txt", staged: false)
        let commit = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = commit
        try await eventually("read the commit") { controller.detail?.commit.hash == commit.hash }
        let historyBefore = controller.commits.count

        // Somebody commits the other file from a terminal.
        try git(["add", "b.txt"], in: root)
        try git(["commit", "-q", "-m", "Committed from a terminal"], in: root)
        try await eventually("see the new commit", timeout: 6) { controller.commits.count == historyBefore + 1 }
        XCTAssertEqual(controller.commits.first?.subject, "Committed from a terminal")
        XCTAssertEqual(controller.selection, GitController.Selection(path: "a.txt", staged: false), "the selected file stays selected")
        XCTAssertEqual(controller.diff.first?.path, "a.txt")
        XCTAssertEqual(controller.checked, ["a.txt"], "the reader's ticks stay as they were")
        XCTAssertEqual(controller.wholeDiffShown, GitController.diffIdentity(path: "a.txt", staged: false), "the whole-diff gate stays open on the same diff")
        XCTAssertEqual(controller.selectedCommit?.hash, commit.hash, "the commit being read stays selected")
        XCTAssertEqual(controller.status.entries.map(\.path), ["a.txt"])
        XCTAssertEqual(controller.notice, "")

        // A refresh nobody asked for shows no spinner and disables nothing.
        XCTAssertFalse(controller.loading)
        await controller.refresh(automatic: true)
        XCTAssertFalse(controller.loading, "an automatic refresh never puts the panel in its loading state")

        // The selected file going away clears the pane and selects nothing else.
        try git(["checkout", "--", "a.txt"], in: root)
        try await eventually("drop the file that is no longer changed", timeout: 6) { controller.selection == nil }
        XCTAssertTrue(controller.diff.isEmpty)
        XCTAssertTrue(controller.status.entries.isEmpty)
    }

    /// A refresh nobody asked for used to put the diff pane in its loading
    /// state and publish the status, the history and the diff again every
    /// time, so a save in another editor flashed a spinner and redrew the
    /// whole panel — up to fifteen hundred diff rows and all of the history —
    /// even when nothing on screen had changed. The History tab shared the
    /// flag, and flashed its spinner for a diff it does not show.
    @MainActor func testAnAutomaticRefreshShowsNoSpinnerAndPublishesOnlyWhatChanged() async throws {
        let root = try repository("git-watch-quiet"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let file = root.appendingPathComponent("a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read a.txt and the history") {
            controller.selection?.path == "a.txt" && controller.diff.first?.added == 1 && !controller.diffLoading && !controller.loading && controller.commits.count == 1
        }
        try await Task.sleep(for: .milliseconds(1_200))

        var spinner = false, statuses = 0, histories = 0, diffs = 0
        let watches = [
            controller.$diffLoading.sink { if $0 { spinner = true } },
            controller.$status.dropFirst().sink { _ in statuses += 1 },
            controller.$commits.dropFirst().sink { _ in histories += 1 },
            controller.$diff.dropFirst().sink { _ in diffs += 1 },
        ]
        defer { watches.forEach { $0.cancel() } }

        // The selected file is saved again with a line more: the watch reads
        // it, and only its diff has changed.
        let before = controller.automaticRefreshes
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await eventually("see the new line", timeout: 6) { controller.diff.first?.added == 2 }
        XCTAssertGreaterThan(controller.automaticRefreshes, before, "the watch did the reading")
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertFalse(spinner, "a refresh nobody asked for never shows the diff's spinner")
        XCTAssertEqual(statuses, 0, "the status did not change, so it is not published again")
        XCTAssertEqual(histories, 0, "nor is the history")
        XCTAssertEqual(diffs, 1, "the diff is published once, with the new line")

        // A refresh that finds nothing new publishes nothing: not one pass over the panel's body.
        var changes = 0
        let everything = controller.objectWillChange.sink { changes += 1 }
        await controller.refresh(automatic: true)
        everything.cancel()
        print("PERF an automatic refresh of an unchanged repository published \(changes) change(s) to the panel")
        XCTAssertEqual(changes, 0, "an unchanged repository redraws nothing")

        // On the History tab the hidden diff is not read at all, and no spinner
        // moves for it; coming back to Changes brings it up to date.
        controller.panel = .history
        let commit = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = commit
        try await eventually("read the commit") { !controller.detailDiff.isEmpty && !controller.commitLoading }
        spinner = false; diffs = 0
        var commitSpinner = false
        let commitWatch = controller.$commitLoading.sink { if $0 { commitSpinner = true } }
        defer { commitWatch.cancel() }
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        await controller.refresh(automatic: true)
        XCTAssertEqual(controller.diff.first?.added, 2, "the diff nobody can see waits")
        XCTAssertEqual(diffs, 0)
        XCTAssertFalse(spinner, "the Changes diff is not read behind the History tab")
        XCTAssertFalse(commitSpinner, "and the commit pane's spinner does not flash for it")
        controller.panel = .changes
        try await eventually("bring the diff up to date on the way back") { controller.diff.first?.added == 3 }
        XCTAssertFalse(spinner)
        XCTAssertEqual(controller.notice, "")
    }

    /// Ten saves in a row are one refresh, not ten. Git's own writes during a
    /// stage are not a change at all.
    @MainActor func testABurstOfWritesCausesOneRefreshAndGitsOwnWritesCauseNone() async throws {
        let root = try repository("git-watch-burst"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path])
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }
        try await Task.sleep(for: .milliseconds(1_200))
        let before = controller.automaticRefreshes

        for index in 0..<10 { try "burst \(index)\n".write(to: root.appendingPathComponent("burst\(index).txt"), atomically: true, encoding: .utf8) }
        try await eventually("see the burst", timeout: 6) { controller.status.entries.count == 10 }
        try await Task.sleep(for: .milliseconds(1_500))
        let refreshes = controller.automaticRefreshes - before
        print("PERF ten writes in a burst caused \(refreshes) automatic refresh(es)")
        XCTAssertLessThanOrEqual(refreshes, 2, "a burst is coalesced, not one refresh per file")
        XCTAssertGreaterThanOrEqual(refreshes, 1)

        // Objects, locks and logs inside .git are git's business, not the panel's.
        let repository = root.resolvingSymlinksInPath().path
        XCTAssertFalse(GitWorkingTreeWatcher.isInteresting(repository + "/.git/index.lock", under: repository))
        XCTAssertFalse(GitWorkingTreeWatcher.isInteresting(repository + "/.git/objects/ab/cdef", under: repository))
        XCTAssertFalse(GitWorkingTreeWatcher.isInteresting(repository + "/.git/logs/HEAD", under: repository))
        XCTAssertFalse(GitWorkingTreeWatcher.isInteresting(repository + "/.git/COMMIT_EDITMSG", under: repository))
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(repository + "/.git/HEAD", under: repository))
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(repository + "/.git/index", under: repository))
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(repository + "/.git/refs/heads/main", under: repository))
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(repository + "/src/Thing.swift", under: repository))
    }

    /// The watch must never win a race with the reader. A refresh queued by
    /// the watch used to start while the reader's own was waiting on git, take
    /// its place, and leave the panel showing the old changes with a spinner
    /// that never stopped.
    @MainActor func testTheReadersOwnRefreshIsNeverSupersededByTheWatch() async throws {
        let root = try repository("git-watch-race"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path])
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }

        for attempt in 0..<3 {
            // Writing wakes the watch, whose refresh is queued behind this
            // synchronous loop and runs at the first await the reader hits.
            for index in 0..<60 { try "\(attempt) \(index)\n".write(to: root.appendingPathComponent("file-\(attempt)-\(index).txt"), atomically: true, encoding: .utf8) }
            await controller.refresh()
            XCTAssertEqual(controller.status.entries.count, 60 * (attempt + 1), "the reader's refresh is the one that lands")
            XCTAssertFalse(controller.loading, "and it always stops loading again")
            XCTAssertNotNil(controller.repositoryRoot)
            XCTAssertEqual(controller.notice, "")
        }
    }

    /// A refresh replaced by a newer one used to hand its cancelled branch and
    /// stash reads to the panel as empty lists: "Stash · 1" read "Stash" and
    /// the branch menu emptied for a moment, every time the agent saved files
    /// with Changes open.
    @MainActor func testASupersededRefreshNeverBlanksTheBranchesOrTheStash() async throws {
        let root = try repository("git-superseded"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let seed = root.appendingPathComponent("seed.txt")
        try "seed\n".write(to: seed, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try git(["branch", "side"], in: root)
        try "set aside\n".write(to: seed, atomically: true, encoding: .utf8)
        try git(["stash", "push", "-q", "-m", "Set aside"], in: root)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read the branches and the stash") {
            controller.stashes.count == 1 && controller.branches == ["main", "side"] && !controller.loading && controller.commits.count == 1
        }

        var stashes: [Int] = [], branches: [Int] = [], superseded = 0
        let watches = [
            controller.$stashes.sink { stashes.append($0.count) },
            controller.$branches.sink { branches.append($0.count) },
            // Each refresh is replaced the moment it has read the status, so
            // the branch and stash reads after it are the ones cancelled.
            controller.$status.dropFirst().sink { _ in
                superseded += 1
                if superseded <= 3 { controller.startRefresh() }
            },
        ]
        defer { watches.forEach { $0.cancel() } }
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        controller.startRefresh()
        try await eventually("replace a refresh halfway") { superseded >= 1 }
        try await eventually("finish the last refresh") { !controller.loading && controller.status.entries.map(\.path) == ["new.txt"] }
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertFalse(stashes.contains(0), "the stash count never blanks: \(stashes)")
        XCTAssertFalse(branches.contains(0), "nor the branch list: \(branches)")
        XCTAssertEqual(controller.stashes.count, 1)
        XCTAssertEqual(controller.branches, ["main", "side"])
        XCTAssertEqual(controller.notice, "")
    }

    /// The project's folder is renamed under the panel. The stream is on an
    /// inode that is no longer the project, so it stops and the panel says
    /// what it now finds rather than watching nothing forever.
    @MainActor func testTheWatchLetsGoWhenTheRepositoryMovesAway() async throws {
        let root = try repository("git-watch-root"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path])
        defer { controller.stop() }
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }
        XCTAssertTrue(controller.isWatching)

        let rootChanges = GitWorkingTreeWatcher.rootChangeCount
        let moved = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try await eventually("be told the root itself changed", timeout: 10) { GitWorkingTreeWatcher.rootChangeCount > rootChanges }
        try await eventually("notice the folder is gone", timeout: 10) { controller.repositoryRoot == nil }
        XCTAssertFalse(controller.isWatching, "the stream on the old folder is stopped")
        XCTAssertTrue(controller.status.entries.isEmpty)
        XCTAssertEqual(controller.notice, "", "a project folder that moved is a state, not an error")
    }

    /// A linked worktree keeps HEAD, the refs and the index somewhere else
    /// entirely. Staging there touches nothing inside the working tree, so the
    /// panel has to be watching the real git directory as well.
    @MainActor func testALinkedWorktreeIsWatchedThroughItsRealGitDirectory() async throws {
        let main = try repository("git-worktree-main"); defer { try? FileManager.default.removeItem(at: main) }
        try start(main)
        try "seed\n".write(to: main.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: main); try git(["commit", "-q", "-m", "Seed"], in: main)
        let linked = main.deletingLastPathComponent().appendingPathComponent(main.lastPathComponent + "-linked")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git(["worktree", "add", "-b", "side", linked.path], in: main)

        let resolved = linked.resolvingSymlinksInPath().path
        let gitDirectory = try XCTUnwrap(GitWorkingTreeWatcher.gitDirectory(under: resolved), "a .git file names the real directory")
        XCTAssertTrue(gitDirectory.contains("worktrees"), gitDirectory)
        XCTAssertFalse(gitDirectory.hasPrefix(resolved + "/"), "and it is outside the working tree")
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(gitDirectory + "/index", under: resolved, gitDirectory: gitDirectory))
        XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(gitDirectory + "/HEAD", under: resolved, gitDirectory: gitDirectory))
        XCTAssertFalse(GitWorkingTreeWatcher.isInteresting(gitDirectory + "/index.lock", under: resolved, gitDirectory: gitDirectory))
        XCTAssertNil(GitWorkingTreeWatcher.gitDirectory(under: main.resolvingSymlinksInPath().path), "an ordinary repository keeps its state inside")

        try "changed\n".write(to: linked.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [linked.path])
        defer { controller.stop() }
        try await eventually("read the linked worktree") { controller.status.entries.map(\.path) == ["seed.txt"] }
        XCTAssertEqual(controller.status.branch, "side")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(controller.unstaged.count, 1)

        // Staging writes the index, which lives outside this working tree.
        try git(["add", "seed.txt"], in: linked)
        try await eventually("see the staged file without touching the tree", timeout: 8) { controller.staged.count == 1 }
        XCTAssertTrue(controller.unstaged.isEmpty)
        XCTAssertEqual(controller.notice, "")
    }

    /// A panel that went away without saying so leaves no stream running.
    @MainActor func testAControllerNobodyStoppedLeavesNoStreamBehind() async throws {
        let root = try repository("git-watch-leak"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let before = GitWorkingTreeWatcher.liveStreamCount

        var controller: GitController? = GitController(roots: [root.path])
        weak var observed = controller
        try await eventually("start a watch") { controller?.isWatching == true }
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount, before + 1)
        try await eventually("settle") { controller?.loading == false }

        controller = nil
        try await eventually("let the panel go", timeout: 10) { observed == nil }
        try await eventually("stop its stream with it", timeout: 10) { GitWorkingTreeWatcher.liveStreamCount == before }
        try await eventually("leave no git behind", timeout: 10) { self.gitChildren().isEmpty }
    }

    /// Closing the panel stops the watch: no stream, no refresh, no git.
    @MainActor func testTheWatchStopsWhenThePanelCloses() async throws {
        let root = try repository("git-watch-stop"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path])
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }
        XCTAssertTrue(controller.isWatching)

        controller.stop()
        XCTAssertFalse(controller.isWatching, "the stream is gone with the panel")
        let refreshes = controller.automaticRefreshes
        try "written after the panel closed\n".write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1_800))
        XCTAssertEqual(controller.automaticRefreshes, refreshes, "a closed panel does not read the repository")
        XCTAssertTrue(controller.status.entries.isEmpty, "and does not change what it was showing")
        try await eventually("leave no git behind", timeout: 10) { self.gitChildren().isEmpty }
    }

    /// However badly the panel behaves, it may not fork without bound.
    func testNoMoreThanEightGitProcessesRunAtOnce() async throws {
        let root = try repository("git-gate"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let service = GitService()
        let reads = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask { _ = try? await service.run(["-c", "alias.wait=!sleep 1", "wait"], in: root.path, timeout: 30) }
                }
                await group.waitForAll()
            }
        }
        var peak = 0
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(120))
            peak = max(peak, gitChildren().count)
            let running = await service.processesRunning
            XCTAssertLessThanOrEqual(running, GitService.concurrentProcesses, "the gate is the gate")
        }
        print("PERF git processes alive while forty reads are queued: \(peak) (gate \(GitService.concurrentProcesses))")
        XCTAssertLessThanOrEqual(peak, GitService.concurrentProcesses, "forty queued reads never become forty processes")
        XCTAssertGreaterThan(peak, 1, "and the gate does not serialise them either")
        await reads.value
        let idle = await service.processesRunning
        XCTAssertEqual(idle, 0, "every place is given back")
    }
}
