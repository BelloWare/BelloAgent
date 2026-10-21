import XCTest
import SwiftUI
import AppKit
import CoreServices
@testable import PiApp
@testable import GitView

final class GitWorkingTreeWatcherTests: GitPanelTestCase {
    @MainActor func testEventsAfterTheIgnoreScanStillRefresh() async throws {
        try await newerThanIgnore(throttled: false, summary: false)
    }

    @MainActor func testThrottledEventsAfterTheIgnoreScanStillRefresh() async throws {
        try await newerThanIgnore(throttled: true, summary: false)
    }

    @MainActor func testSummaryEventsAfterTheIgnoreScanStillRefresh() async throws {
        try await newerThanIgnore(throttled: false, summary: true)
    }

    @MainActor func testThrottledSummaryEventsAfterTheIgnoreScanStillRefresh() async throws {
        try await newerThanIgnore(throttled: true, summary: true)
    }

    @MainActor private func newerThanIgnore(throttled: Bool, summary: Bool) async throws {
        let root = try repository("git-watch-newer-ignore")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "cache/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Ignore directories"], in: root)
        let controller = GitController(roots: [root.path], summaryOnly: summary)
        defer { controller.stop() }
        try await eventually("finish the initial empty scan") { controller.refreshesFinished > 0 && !controller.loading }
        let watcher = try XCTUnwrap(controller.watcher), bridge = try XCTUnwrap(watcher.bridge?.isolatedCopy())
        watcher.interval = 3_600
        let before = controller.automaticRefreshes, finished = controller.refreshesFinished
        var held: CheckedContinuation<Void, Never>?
        var scans = 0
        controller.ignoredDidRead = { ignored in
            scans += 1
            if scans == 1 {
                XCTAssertEqual(ignored, ["cache/"])
                await withCheckedContinuation { held = $0 }
            }
        }
        defer { controller.ignoredDidRead = nil; held?.resume() }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        try "object\n".write(to: cache.appendingPathComponent("first.o"), atomically: false, encoding: .utf8)
        await Task.detached { bridge.deliver([cache.path], [0]) }.value
        try await eventually("hold the completed ignore scan before publication") { held != nil }
        XCTAssertTrue(controller.status.entries.isEmpty)
        XCTAssertFalse(watcher.ignored.covers(cache.path), "The published cache still predates the directory")
        try FileManager.default.removeItem(at: cache)
        try "a regular file\n".write(to: cache, atomically: false, encoding: .utf8)
        await Task.detached { bridge.deliver([cache.path], [0]) }.value
        try await eventually("queue the newer replacement event") { watcher.hasTrailingChange }
        if !throttled {
            watcher.deliverTrailingChange()
            XCTAssertTrue(controller.hasPendingAutomaticChange)
        }
        held?.resume(); held = nil
        try await eventually("finish the held refresh and drain queued replacements") {
            if watcher.hasTrailingChange { watcher.deliverTrailingChange() }
            return controller.refreshesFinished > finished && !controller.isAutomaticallyRefreshing && !watcher.hasTrailingChange
        }
        XCTAssertGreaterThanOrEqual(controller.automaticRefreshes - before, 2, "The older scan cannot vouch for the newer event")
        XCTAssertEqual(controller.status.entries.map(\.path), ["cache"], "The replacement file must become visible")
        XCTAssertTrue(controller.status.entries.first?.untracked == true)
    }

    @MainActor func testIgnoredWritesAfterAStagedDeletionStayQuiet() async throws {
        try await stagedDeletion(summary: false)
    }

    @MainActor func testSummaryIgnoredWritesAfterAStagedDeletionStayQuiet() async throws {
        try await stagedDeletion(summary: true)
    }

    @MainActor private func stagedDeletion(summary: Bool) async throws {
        let root = try repository("git-watch-staged-deletion")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let log = root.appendingPathComponent("run.log")
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try "tracked\n".write(to: log, atomically: false, encoding: .utf8)
        try git(["add", ".gitignore"], in: root); try git(["add", "-f", "run.log"], in: root)
        try git(["commit", "-q", "-m", "Track log"], in: root)
        try git(["rm", "--cached", "run.log"], in: root)
        let controller = GitController(roots: [root.path], summaryOnly: summary)
        defer { controller.stop() }
        var held: CheckedContinuation<Void, Never>?
        var reads = 0
        controller.statusDidRead = {
            reads += 1
            if reads == 1 { await withCheckedContinuation { held = $0 } }
        }
        defer { controller.statusDidRead = nil; held?.resume() }
        try await eventually("hold the staged deletion before reading ignores") { held != nil }
        let watcher = try XCTUnwrap(controller.watcher), bridge = try XCTUnwrap(watcher.bridge?.isolatedCopy())
        watcher.interval = 3_600
        let before = controller.automaticRefreshes, finished = controller.refreshesFinished
        try "ignored write\n".write(to: log, atomically: false, encoding: .utf8)
        await Task.detached { bridge.deliver([log.path], [0]) }.value
        try await eventually("queue the log write during the reader refresh") {
            if watcher.hasTrailingChange { watcher.deliverTrailingChange() }
            return controller.hasMissedChange
        }
        held?.resume(); held = nil
        try await eventually("finish the staged deletion read and any follow-up") {
            if watcher.hasTrailingChange { watcher.deliverTrailingChange() }
            return controller.refreshesFinished > finished && !controller.loading && !controller.isAutomaticallyRefreshing && !watcher.hasTrailingChange
        }
        let entry = try XCTUnwrap(controller.status.entries.first)
        XCTAssertEqual(controller.status.entries.count, 1)
        XCTAssertEqual(entry.path, "run.log"); XCTAssertEqual(entry.indexState, "D"); XCTAssertEqual(entry.worktreeState, ".")
        XCTAssertTrue(watcher.ignored.covers(log.path), "The ignored working copy cannot change the staged-deletion row")
        XCTAssertEqual(controller.automaticRefreshes, before, "A reconciled staged deletion must not keep refreshing for ignored writes")
    }

    @MainActor func testAnIgnoredReplacementOfADisplayedFileStillRefreshes() async throws {
        try await ignoredReplacement(throttled: false)
    }

    @MainActor func testAThrottledIgnoredReplacementOfADisplayedFileStillRefreshes() async throws {
        try await ignoredReplacement(throttled: true)
    }

    @MainActor func testAnIgnoredReplacementOfACleanTrackedFileStillRefreshes() async throws {
        try await ignoredReplacement(throttled: false, committed: true)
    }

    @MainActor func testAThrottledIgnoredReplacementOfACleanTrackedFileStillRefreshes() async throws {
        try await ignoredReplacement(throttled: true, committed: true)
    }

    @MainActor func testASummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile() async throws {
        try await ignoredReplacement(throttled: false, summary: true)
    }

    @MainActor func testAThrottledSummaryRefreshPreservesAnIgnoredReplacementOfADisplayedFile() async throws {
        try await ignoredReplacement(throttled: true, summary: true)
    }

    @MainActor private func ignoredReplacement(throttled: Bool, committed: Bool = false, summary: Bool = false) async throws {
        let root = try repository("git-watch-visible-ignore")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "cache/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Ignore directories"], in: root)
        let cache = root.appendingPathComponent("cache")
        try "a regular file\n".write(to: cache, atomically: false, encoding: .utf8)
        if committed { try git(["add", "cache"], in: root); try git(["commit", "-q", "-m", "Track cache"], in: root) }
        let controller = GitController(roots: [root.path], summaryOnly: summary)
        defer { controller.stop() }
        try await eventually("read the regular file") { controller.refreshesFinished > 0 && !controller.loading }
        let initialPaths = committed ? [] : ["cache"]
        XCTAssertEqual(controller.status.entries.map(\.path), initialPaths)
        let watcher = try XCTUnwrap(controller.watcher), bridge = try XCTUnwrap(watcher.bridge?.isolatedCopy())
        watcher.interval = 3_600
        let before = controller.automaticRefreshes, finished = controller.refreshesFinished
        var held: CheckedContinuation<Void, Never>?
        var reads = 0
        controller.statusDidRead = {
            reads += 1
            if reads == 1 { await withCheckedContinuation { held = $0 } }
        }
        defer { controller.statusDidRead = nil; held?.resume() }
        await Task.detached { bridge.deliver([cache.path], [0]) }.value
        try await eventually("hold the status before replacing cache") { held != nil }
        XCTAssertTrue(controller.isAutomaticallyRefreshing)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let object = cache.appendingPathComponent("first.o")
        try "object\n".write(to: object, atomically: false, encoding: .utf8)
        // A child-only batch must also preserve the deletion of its tracked ancestor.
        let paths = committed ? [object.path] : [cache.path, object.path]
        await Task.detached { bridge.deliver(paths, paths.map { _ in 0 }) }.value
        try await eventually("queue the replacement batch in the throttle") { watcher.hasTrailingChange }
        if !throttled {
            watcher.deliverTrailingChange()
            XCTAssertTrue(controller.hasPendingAutomaticChange)
        }
        // --others excludes an indexed file even when the worktree now holds
        // a directory at that name. It cannot teach the watcher "cache/".
        let ignored = try await GitService().ignoredPaths(in: root.path)
        XCTAssertEqual(ignored, committed ? [] : ["cache/"])
        held?.resume(); held = nil
        if throttled {
            try await eventually("learn ignores before delivering the queued batch") {
                controller.refreshesFinished > finished && !controller.isAutomaticallyRefreshing
            }
            XCTAssertEqual(controller.status.entries.map(\.path), initialPaths, "The held snapshot predates the replacement")
            watcher.deliverTrailingChange()
        }
        try await eventually("finish the read and its follow-up") {
            if watcher.hasTrailingChange { watcher.deliverTrailingChange() }
            return controller.refreshesFinished > finished && !controller.isAutomaticallyRefreshing && !watcher.hasTrailingChange
        }
        XCTAssertEqual(controller.automaticRefreshes - before, 2, "The stale status needs exactly one follow-up")
        if committed {
            XCTAssertEqual(controller.status.entries.map(\.path), ["cache"], "The tracked deletion must appear")
            XCTAssertEqual(controller.status.entries.first?.worktreeState, "D")
            XCTAssertFalse(watcher.ignored.covers(object.path), "The indexed ancestor is never learned as ignored")
        } else {
            XCTAssertTrue(controller.status.entries.isEmpty, "The untracked file was replaced by an ignored directory")
            XCTAssertTrue(watcher.ignored.covers(object.path), "Once the stale row is gone, ignored writes are quiet again")
        }
    }

    @MainActor func testIgnoredFilteringPreservesBothRenamePathsAndTheirRelatives() async throws {
        let root = try repository("git-watch-visible-renames")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for directory in ["cache", "renamed"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
        }
        try "source\n".write(to: root.appendingPathComponent("cache/item"), atomically: false, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try git(["mv", "cache/item", "renamed/item"], in: root)
        let controller = GitController(roots: [root.path])
        defer { controller.stop() }
        try await eventually("read both names of the rename") { controller.refreshesFinished > 0 && !controller.loading }
        let entry = try XCTUnwrap(controller.status.entries.first)
        XCTAssertEqual(entry.path, "renamed/item"); XCTAssertEqual(entry.originalPath, "cache/item")
        for restarted in [false, true] {
            if restarted { controller.stop(); await controller.refresh() }
            let ignored = try XCTUnwrap(controller.watcher).ignored
            // Model a newer ignored list arriving after this rename snapshot.
            ignored.update(root: root.path, relative: ["cache/", "renamed/", "cache-other/", "renamed-other/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
            for path in ["cache", "cache/", "cache/item", "cache/item/", "cache/item/child", "renamed", "renamed/item", "renamed/item/child"] {
                XCTAssertFalse(ignored.covers(root.path + "/" + path), "A displayed rename still owns \(path), restarted: \(restarted)")
            }
            for path in ["cache/sibling", "renamed/sibling", "cache-other/item", "renamed-other/item"] {
                XCTAssertTrue(ignored.covers(root.path + "/" + path), "An unrelated ignored path stays quiet: \(path)")
            }
        }
    }

    func testIgnoredFilteringUsesFilesystemSeparatorsBeforeCombiningCharacters() {
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: ["cache/", "source/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        ignored.preserve(root: "/repo", entries: [
            GitStatusEntry(path: "cache/\u{301}item", originalPath: "source/\u{301}item",
                           indexState: "R", worktreeState: ".", untracked: false)
        ])
        for directory in ["cache", "source"] {
            for path in [directory, directory + "/"] {
                XCTAssertFalse(ignored.covers("/repo/" + path), "A combining character must not hide a filesystem separator: \(path)")
            }
        }
        ignored.update(root: "/repo", relative: [
            "cache/item/\u{301}child", "source/item/\u{301}child", "cache/\u{301}sibling", "source/\u{301}sibling"
        ], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        ignored.preserve(root: "/repo", entries: [
            GitStatusEntry(path: "cache/item", originalPath: "source/item",
                           indexState: "R", worktreeState: ".", untracked: false)
        ])
        for directory in ["cache", "source"] {
            XCTAssertFalse(ignored.covers("/repo/" + directory + "/item/\u{301}child"))
            XCTAssertTrue(ignored.covers("/repo/" + directory + "/\u{301}sibling"))
        }
    }

    func testQueuedPathsStayBoundedWithoutHidingUncertainChanges() {
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: ["build/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        let paths = (0..<4_096).map { "/repo/build/unit\($0).o" }
        var changes = GitWatchChanges(paths, receivedAt: 1)
        XCTAssertFalse(changes.isInteresting(ignoring: ignored))
        changes.formUnion(GitWatchChanges(["/repo/build/overflow.o"]))
        XCTAssertTrue(changes.isInteresting(ignoring: ignored), "Overflow keeps the previous conservative refresh")
        XCTAssertTrue(changes.paths.isEmpty, "A stalled read cannot retain unlimited paths")
        XCTAssertTrue(GitWatchChanges(paths + ["/repo/build/extra.o"]).isInteresting(ignoring: ignored))
        changes = GitWatchChanges(["/repo/build/ignored.o"])
        changes.formUnion(.unknown)
        XCTAssertTrue(changes.isInteresting(ignoring: ignored), "A root move is never filtered as an ignored file")
        XCTAssertFalse(GitWatchChanges().isInteresting(ignoring: ignored))
    }

    func testQueuedRechecksUseTheNewestEventAndScanStart() {
        let ignored = GitIgnoredPaths()
        let path = "/repo/build/first.o"
        XCTAssertTrue(GitWatchChanges([path], receivedAt: 10).isInteresting(ignoring: ignored))
        ignored.update(root: "/repo", relative: ["build/"], scanStartedAt: 20)
        XCTAssertFalse(GitWatchChanges([path], receivedAt: 10).isInteresting(ignoring: ignored))
        XCTAssertTrue(GitWatchChanges([path], receivedAt: 20).isInteresting(ignoring: ignored), "Equal times cannot prove ordering")
        var changes = GitWatchChanges([path], receivedAt: 21)
        changes.formUnion(GitWatchChanges(["/repo/build/older.o"], receivedAt: 5))
        changes.formUnion(GitWatchChanges())
        XCTAssertTrue(changes.isInteresting(ignoring: ignored), "Merging an older or empty batch cannot age newer events")
        ignored.update(root: "/repo", relative: ["build/"], scanStartedAt: 30)
        XCTAssertFalse(changes.isInteresting(ignoring: ignored), "A later scan can vouch for the whole batch")
        XCTAssertTrue(changes.isInteresting(ignoring: nil), "A missing scan must keep the refresh")
        changes.formUnion(GitWatchChanges(["/repo/source.swift"], receivedAt: 10))
        XCTAssertTrue(changes.isInteresting(ignoring: ignored), "Every path must be covered")
    }

    func testIgnoredProtectionExcludesOnlyReconciledStagedDeletions() {
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: ["run.log"], scanStartedAt: 20)
        let states: [(Character, Character, Bool, Bool)] = [
            ("D", ".", false, false), ("D", "D", false, true), ("D", "U", false, true),
            ("M", ".", false, true), ("A", ".", false, true), ("R", ".", false, true),
            (".", "D", false, true), (".", "M", false, true), ("?", "?", true, true)
        ]
        for (index, worktree, untracked, protected) in states {
            ignored.preserve(root: "/repo", entries: [GitStatusEntry(path: "run.log", originalPath: nil,
                indexState: index, worktreeState: worktree, untracked: untracked)])
            XCTAssertEqual(ignored.covers("/repo/run.log"), !protected, "\(index)\(worktree), untracked: \(untracked)")
        }
    }

    @MainActor func testAThrottledBatchIsRecheckedAgainstNewlyLearnedIgnores() async throws {
        let root = try repository("git-watch-queued-ignore")
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 3_600) { _ in changes += 1 }
        watcher.start(); defer { watcher.stop() }
        let bridge = try XCTUnwrap(watcher.bridge)
        await Task.detached { bridge.deliver([root.path + "/build"], [0]) }.value
        try await eventually("deliver the directory batch") { changes == 1 }
        await Task.detached { bridge.deliver([root.path + "/build/out/first.o"], [0]) }.value
        try await eventually("queue the separate file batch") { watcher.hasTrailingChange }
        watcher.ignored.update(root: root.path, relative: ["build/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        watcher.deliverTrailingChange()
        XCTAssertFalse(watcher.hasTrailingChange)
        XCTAssertEqual(changes, 1, "The first refresh learned that the queued file is ignored")
        let before = changes
        await Task.detached { bridge.deliver([root.path + "/source.swift"], [0]) }.value
        try await eventually("queue a subsequent source change") { watcher.hasTrailingChange }
        watcher.deliverTrailingChange()
        XCTAssertEqual(changes, before + 1)
    }

    @MainActor func testIgnoredEventsDuringAnAutomaticRefreshAreRechecked() async throws {
        try await queuedEvents(automatic: true, tracked: false)
    }

    @MainActor func testIgnoredEventsDuringAReaderRefreshAreRechecked() async throws {
        try await queuedEvents(automatic: false, tracked: false)
    }

    @MainActor func testIgnoredEventsDuringAnAutomaticSummaryRefreshAreRechecked() async throws {
        try await queuedEvents(automatic: true, tracked: false, summary: true)
    }

    @MainActor func testIgnoredEventsDuringAReaderSummaryRefreshAreRechecked() async throws {
        try await queuedEvents(automatic: false, tracked: false, summary: true)
    }

    @MainActor func testTrackedEventsDuringAnAutomaticRefreshStillRefresh() async throws {
        try await queuedEvents(automatic: true, tracked: true)
    }

    @MainActor func testTrackedEventsDuringAReaderRefreshStillRefresh() async throws {
        try await queuedEvents(automatic: false, tracked: true)
    }

    @MainActor private func queuedEvents(automatic: Bool, tracked: Bool, summary: Bool = false) async throws {
        let root = try repository("git-watch-reading-ignore")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        let source = root.appendingPathComponent("source.swift")
        try "let value = 1\n".write(to: source, atomically: false, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path], summaryOnly: summary)
        defer { controller.stop() }
        try await eventually("finish the initial read") { controller.refreshesFinished > 0 && !controller.loading }
        let watcher = try XCTUnwrap(controller.watcher), bridge = try XCTUnwrap(watcher.bridge?.isolatedCopy())
        let before = controller.automaticRefreshes, finished = controller.refreshesFinished
        var held: CheckedContinuation<Void, Never>?
        var reads = 0
        controller.statusDidRead = {
            reads += 1
            if reads == 1 { await withCheckedContinuation { held = $0 } }
        }
        defer { controller.statusDidRead = nil; held?.resume() }
        let build = root.appendingPathComponent("build/out", isDirectory: true)
        func writeObject() throws {
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try "object\n".write(to: build.appendingPathComponent("first.o"), atomically: false, encoding: .utf8)
        }
        if automatic {
            try writeObject()
            await Task.detached { bridge.deliver([root.path + "/build"], [0]) }.value
        } else { controller.startRefresh() }
        try await eventually("hold the status snapshot before ignored paths are read") { held != nil }
        guard controller.loading == !automatic, controller.isAutomaticallyRefreshing == automatic else {
            XCTFail("The held snapshot must belong to the requested kind of refresh")
            return
        }
        XCTAssertFalse(watcher.ignored.covers(build.path + "/first.o"))
        // Arm the reader before writing: an earlier queued file event can
        // otherwise start an automatic refresh before the reader task enters.
        if !automatic { try writeObject() }
        if tracked { try "let value = 2\n".write(to: source, atomically: false, encoding: .utf8) }
        let paths = [build.path + "/first.o"] + (tracked ? [source.path] : [])
        await Task.detached { bridge.deliver(paths, paths.map { _ in 0 }) }.value
        // A reader refresh cannot be superseded; an automatic one queues one
        // further pass. Wait for actual delivery, not an assumed FSEvents delay.
        if automatic {
            try await eventually("queue the batch during the held refresh") { controller.hasPendingAutomaticChange }
        } else {
            try await eventually("deliver the batch during the reader's refresh") { controller.hasMissedChange }
        }
        held?.resume(); held = nil
        let expected = (automatic ? 1 : 0) + (tracked ? 1 : 0)
        try await eventually("finish the held read and any required follow-up") {
            controller.refreshesFinished > finished && reads >= (tracked ? 2 : 1) &&
                !controller.loading && !controller.isAutomaticallyRefreshing && !watcher.hasTrailingChange
        }
        XCTAssertTrue(watcher.ignored.covers(build.path + "/first.o"))
        if tracked {
            XCTAssertGreaterThanOrEqual(controller.automaticRefreshes - before, expected,
                                        "An unignored change must still cause a follow-up")
        } else {
            XCTAssertEqual(controller.automaticRefreshes - before, expected,
                           "Recheck the queued paths after the refresh learns build/")
        }
        XCTAssertEqual(controller.status.entries.map(\.path), tracked ? ["source.swift"] : [])
    }

    @MainActor func testDiscoveryWatchUsesOnlyTheProjectAndNoticesTheGitMarker() async throws {
        let root = try repository("git-discovery-watch"), outside = try repository("git-discovery-outside")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try "gitdir: \(outside.path)\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../unverified-common\n".write(to: outside.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        var changes = 0
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 0, stateOnly: true, discoveringRepository: true) { _ in changes += 1 }
        XCTAssertNil(watcher.gitDirectory, "Discovery must not resolve metadata before Git verifies the repository")
        XCTAssertNil(watcher.commonDirectory)
        watcher.start(); defer { watcher.stop() }
        let bridge = try XCTUnwrap(watcher.bridge)
        await Task.detached { bridge.deliver([root.path + "/ordinary.txt", root.path + "/.git/objects/ab/cd"], [0, 0]) }.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes, 0)
        await Task.detached { bridge.deliver([root.path + "/.git"], [0]) }.value
        try await eventually("discover a .git directory or worktree marker appearing", timeout: 5) { changes == 1 }
    }

    @MainActor func testDiscoveryEventsBypassCachedIgnores() async throws {
        let root = try repository("git-discovery-ignored")
        defer { try? FileManager.default.removeItem(at: root) }
        var batches: [GitWatchChanges] = []
        let watcher = GitWorkingTreeWatcher(root: root.path, stateOnly: true, discoveringRepository: true) { batches.append($0) }
        watcher.ignored.update(root: root.path, relative: [".git/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        watcher.start(); defer { watcher.stop() }
        let bridge = try XCTUnwrap(watcher.bridge)
        await Task.detached { bridge.deliver([root.path + "/.git"], [0]) }.value
        try await eventually("deliver discovery regardless of a cached ignore", timeout: 5) { batches.count == 1 }
        XCTAssertTrue(batches.first?.isInteresting(ignoring: watcher.ignored) == true, "Discovery is unconditional")
    }

    @MainActor func testThrottledDiscoveryEventsSurviveNewIgnores() async throws {
        let root = try repository("git-discovery-queued")
        defer { try? FileManager.default.removeItem(at: root) }
        var batches: [GitWatchChanges] = []
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 3_600, stateOnly: true, discoveringRepository: true) { batches.append($0) }
        watcher.start(); defer { watcher.stop() }
        let bridge = try XCTUnwrap(watcher.bridge)
        await Task.detached { bridge.deliver([root.path + "/.git"], [0]) }.value
        try await eventually("deliver the first discovery batch") { batches.count == 1 }
        await Task.detached { bridge.deliver([root.path + "/.git/HEAD"], [0]) }.value
        try await eventually("queue a second discovery batch") { watcher.hasTrailingChange }
        watcher.ignored.update(root: root.path, relative: [".git/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        watcher.deliverTrailingChange()
        XCTAssertEqual(batches.count, 2, "A newly learned ignore must not discard discovery")
        XCTAssertTrue(batches.allSatisfy { $0.isInteresting(ignoring: watcher.ignored) }, "Discovery batches stay unconditional")
    }

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
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 0) { _ in
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

        let controller = GitController(roots: [root.path]); defer { controller.stop() }
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
            controller.$repository.map(\.status).removeDuplicates().dropFirst().sink { _ in statuses += 1 },
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
        // Stopped when the test ends, so nothing of it is still winding down
        // in the test that runs next.
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
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

    /// A build or an install writing into an ignored folder changes nothing
    /// the panel shows. It used to refresh the panel every second for as
    /// long as it ran: every path outside `.git` counted.
    @MainActor func testWritesIntoAnIgnoredFolderCauseNoRefresh() async throws {
        let root = try repository("git-watch-ignored"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "node_modules/\nbuild/\n*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Ignore"], in: root)
        let modules = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "0\n".write(to: modules.appendingPathComponent("index.js"), atomically: false, encoding: .utf8)
        try "log\n".write(to: root.appendingPathComponent("run.log"), atomically: false, encoding: .utf8)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }
        try await Task.sleep(for: .milliseconds(1_500))
        let before = controller.automaticRefreshes
        for index in 0..<20 {
            try "\(index)\n".write(to: modules.appendingPathComponent("file\(index).js"), atomically: false, encoding: .utf8)
            try "log \(index)\n".write(to: root.appendingPathComponent("run.log"), atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(2_000))
        XCTAssertEqual(controller.automaticRefreshes, before, "writes into ignored paths refresh nothing")
        // A new folder needs a scan. Batches delivered after that scan starts
        // conservatively need another; the held-read fixtures prove that settled
        // pre-scan batches cost only one refresh. Once learned, writes stay quiet.
        let build = root.appendingPathComponent("build/out", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "o\n".write(to: build.appendingPathComponent("first.o"), atomically: false, encoding: .utf8)
        let watcher = try XCTUnwrap(controller.watcher)
        try await eventually("learn build and drain uncertain batches") {
            watcher.ignored.covers(build.path + "/first.o") && !controller.isAutomaticallyRefreshing && !watcher.hasTrailingChange
        }
        let learned = controller.automaticRefreshes
        XCTAssertGreaterThan(learned, before, "The new ignored folder is learned by the watcher")
        for index in 0..<20 {
            try "\(index)\n".write(to: build.appendingPathComponent("unit\(index).o"), atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(2_000))
        XCTAssertEqual(controller.automaticRefreshes, learned, "once learned, the new ignored folder refreshes nothing")
        try "tracked\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: false, encoding: .utf8)
        try await eventually("a tracked change still refreshes", timeout: 6) { controller.status.entries.contains { $0.path == "tracked.txt" } }
    }

    /// A repository whose refresh outlasts the watcher's one-second interval
    /// still finishes one while the tree keeps changing. Every change used to
    /// cancel the refresh under way, so none finished until the writes stopped.
    @MainActor func testASlowRefreshFinishesWhileTheTreeKeepsChanging() async throws {
        let root = try repository("git-watch-slow"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path]); defer { controller.stop(); GitController.statusReadDelay = .zero }
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }
        try await Task.sleep(for: .milliseconds(1_200))
        GitController.statusReadDelay = .milliseconds(1_500)
        let began = Date()
        var sawChangeWhileWriting = false
        for index in 0..<16 {
            try "\(index)\n".write(to: root.appendingPathComponent("busy\(index).txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(250))
            if !controller.status.entries.isEmpty { sawChangeWhileWriting = true; break }
        }
        XCTAssertTrue(sawChangeWhileWriting, "a refresh finished \(Date().timeIntervalSince(began)) s into continuous writes")
    }

    func testIgnoredPathsCoverTheirFoldersAndFilesOnly() {
        let ignored = GitIgnoredPaths()
        ignored.update(root: "/repo", relative: ["node_modules/", "build/", "debug.log"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(ignored.covers("/repo/node_modules/pkg/index.js"))
        XCTAssertTrue(ignored.covers("/repo/node_modules"))
        XCTAssertTrue(ignored.covers("/repo/build/out/app.o"))
        XCTAssertTrue(ignored.covers("/repo/debug.log"))
        XCTAssertFalse(ignored.covers("/repo/node_modules_notes.md"))
        XCTAssertFalse(ignored.covers("/repo/src/build.swift"))
        XCTAssertFalse(ignored.covers("/repo/debug.log.txt"))
        // FSEvents keeps "/private" where the resolved root drops it.
        ignored.update(root: "/var/folders/x/repo", relative: ["node_modules/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(ignored.covers("/private/var/folders/x/repo/node_modules/a.js"))
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
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
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
            controller.$repository.map(\.status).removeDuplicates().dropFirst().sink { _ in
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
        // This repository's streams only. The process-wide count also held
        // the stream of a panel an earlier test let go of; when that one
        // closed in the middle of this test, the count could never come back
        // to where it started, and the wait below ran out under load. Here a
        // panel elsewhere is open when this test starts and closes halfway,
        // as that one did.
        let elsewhere = try repository("git-watch-elsewhere"); defer { try? FileManager.default.removeItem(at: elsewhere) }
        let other = GitWorkingTreeWatcher(root: elsewhere.path) { _ in }
        other.start(); defer { other.stop() }
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: elsewhere.path), 1)
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: root.path), 0)

        var controller: GitController? = GitController(roots: [root.path])
        weak var observed = controller
        try await eventually("start a watch") { controller?.isWatching == true }
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: root.path), 1)
        try await eventually("settle") { controller?.loading == false }

        controller = nil
        other.stop()
        XCTAssertEqual(GitWorkingTreeWatcher.liveStreamCount(under: elsewhere.path), 0)
        try await eventually("let the panel go", timeout: 10) { observed == nil }
        try await eventually("stop its stream with it", timeout: 10) { GitWorkingTreeWatcher.liveStreamCount(under: root.path) == 0 }
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
