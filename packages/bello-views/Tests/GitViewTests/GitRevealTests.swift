import XCTest
@testable import GitView

/// Opening the change a blamed line came from (`GitController.revealHistory`):
/// the exact commit and file, wherever the commit is in the history and
/// whatever the history filter shows, held through refreshes until the
/// reader chooses another; the newest ask wins.
final class GitRevealTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-reveal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try git(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @MainActor private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never \(what)")
    }
    @MainActor private func settled(_ controller: GitController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if controller.statusRead, !controller.loading, !controller.commitLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never settled")
    }

    /// Seventy commits; the one asked for is the fifth, far past the first
    /// page, and the history is filtered to text it does not have.
    @MainActor func testTheCommitAskedForIsShownBeyondThePageAndTheFilter() async throws {
        try "line 1\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Commit 0"])
        var hashes: [String] = []
        for index in 1..<70 {
            try ((1...index).map { "line \($0)" } + ["line \(index + 1)"]).joined(separator: "\n").appending("\n")
                .write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["commit", "-q", "-am", "Commit \(index)"])
            hashes.append(try git(["rev-parse", "HEAD"]))
        }
        let target = hashes[4]   // "Commit 5", which added line 6
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        controller.panel = .history
        controller.logFilter.text = "nothing matches this"
        try await until("filtered to nothing") { controller.commits.isEmpty }

        let shown = await controller.revealHistory(GitHistoryTarget(commit: target, path: "a.txt", line: 6), in: top)
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.panel, .history)
        XCTAssertEqual(controller.selectedCommit?.hash, target)
        XCTAssertEqual(controller.detailFile, "a.txt")
        XCTAssertEqual(controller.revealTarget?.target.line, 6)
        try await settled(controller)
        XCTAssertEqual(controller.detailFileDiff.first?.hunks.flatMap(\.lines).first { $0.kind == .added }?.newNumber, 6, "its own diff, against its parent")

        // A refresh, and a filter change, keep it.
        await controller.refresh()
        controller.logFilter.text = "Commit 6"
        try await until("filtered to Commit 6") { controller.commits.first?.subject.hasPrefix("Commit 6") == true }
        XCTAssertEqual(controller.selectedCommit?.hash, target, "held through refreshes and filters")

        // The reader choosing another lets it go.
        let other = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = other
        XCTAssertNil(controller.revealTarget)
        controller.logFilter.text = "nothing matches this"
        try await until("no longer held: a filter that leaves it out drops it as before") { controller.selectedCommit == nil }
    }

    /// Two asks in a row, the same commit and other lines: the second is the
    /// one shown, with a token of its own.
    @MainActor func testTheNewestAskWins() async throws {
        try "a\nb\nc\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Only"])
        let hash = try git(["rev-parse", "HEAD"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        async let first = controller.revealHistory(GitHistoryTarget(commit: hash, path: "a.txt", line: 1), in: top)
        async let second = controller.revealHistory(GitHistoryTarget(commit: hash, path: "a.txt", line: 3), in: top)
        let results = await (first, second)
        XCTAssertTrue(results.1)
        XCTAssertEqual(controller.revealTarget?.target.line, 3)
        let token = try XCTUnwrap(controller.revealTarget?.token)
        _ = await controller.revealHistory(GitHistoryTarget(commit: hash, path: "a.txt", line: 3), in: top)
        XCTAssertNotEqual(controller.revealTarget?.token, token, "the same line asked again is shown again")
    }

    /// The asker's standing gone (its file no longer readable): nothing shown.
    @MainActor func testAnAskNoLongerValidShowsNothing() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Only"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        var valid = true
        let head = try git(["rev-parse", "HEAD"])
        let ask = Task { await controller.revealHistory(GitHistoryTarget(commit: head, path: "a.txt", line: 1), in: top) { valid } }
        valid = false
        let shown = await ask.value
        XCTAssertFalse(shown)
        XCTAssertNil(controller.revealTarget); XCTAssertNil(controller.selectedCommit)
    }

    /// The asker's standing lapsing after the commit is chosen, while its
    /// change is still being read: nothing of it is shown.
    @MainActor func testAStandingThatLapsesWhileTheChangeLoadsShowsNothing() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Only"])
        let head = try git(["rev-parse", "HEAD"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        var valid = true
        let shown = await controller.revealHistory(GitHistoryTarget(commit: head, path: "a.txt", line: 1), in: top) { valid }
        XCTAssertTrue(shown)
        valid = false
        try await until("dropped") { controller.selectedCommit == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(controller.detail, "nothing of the change shown")
        XCTAssertTrue(controller.detailFileDiff.isEmpty)
    }

    /// Once the reader chooses another file of the commit, the asker's old
    /// standing no longer governs it: its lapse does not clear the commit.
    @MainActor func testTheReadersOwnFileChoiceOutlivesTheAsk() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Two files"])
        let head = try git(["rev-parse", "HEAD"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        var valid = true
        _ = await controller.revealHistory(GitHistoryTarget(commit: head, path: "a.txt", line: 1), in: top) { valid }
        try await until("a.txt read") { !controller.commitLoading && !controller.detailFileDiff.isEmpty }
        valid = false
        controller.detailFile = "b.txt"
        try await until("b.txt read") { !controller.commitLoading && controller.detailFileDiff.first?.path == "b.txt" }
        XCTAssertEqual(controller.selectedCommit?.hash, head, "the reader's commit stays")
    }

    /// A second reveal, of another commit, keeps its own standing: lapsed
    /// right after it lands, nothing of that commit is shown.
    @MainActor func testASecondRevealKeepsItsOwnStanding() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "One"])
        let one = try git(["rev-parse", "HEAD"])
        try "a\nb\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Two"])
        let two = try git(["rev-parse", "HEAD"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        _ = await controller.revealHistory(GitHistoryTarget(commit: one, path: "a.txt", line: 1), in: top) { true }
        try await until("one read") { !controller.commitLoading && controller.detail?.commit.hash == one }
        var valid = true
        _ = await controller.revealHistory(GitHistoryTarget(commit: two, path: "a.txt", line: 2), in: top) { valid }
        valid = false
        try await until("dropped") { controller.selectedCommit == nil }
    }

    /// Another folder chosen: a commit held for a reveal is held no more.
    @MainActor func testAnotherFolderLetsGoOfThePin() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "One"])
        let one = try git(["rev-parse", "HEAD"])
        let other = root.deletingLastPathComponent().appendingPathComponent("git-reveal-other-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q", "-b", "main"]; process.currentDirectoryURL = other
        process.standardOutput = FileHandle.nullDevice; try process.run(); process.waitUntilExit()
        let controller = GitController(roots: [root.path, other.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        _ = await controller.revealHistory(GitHistoryTarget(commit: one, path: "a.txt", line: 1), in: top)
        XCTAssertEqual(controller.selectedCommit?.hash, one)
        controller.root = other.path
        XCTAssertNil(controller.revealTarget)
        try await until("the other repository read, the commit not held") { controller.repositoryRoot != top && controller.selectedCommit == nil }
    }

    /// A commit the reader chooses while a reveal waits for the hidden panel
    /// wins: the reveal lands nothing over it.
    @MainActor func testTheReadersChoiceDuringTheWaitWins() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "One"])
        let one = try git(["rev-parse", "HEAD"])
        try "a\nb\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Two"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        controller.setShown(true)
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        controller.setShown(false)
        XCTAssertTrue(controller.suspended)
        let ask = Task { await controller.revealHistory(GitHistoryTarget(commit: one, path: "a.txt", line: 1), in: top) }
        try await Task.sleep(for: .milliseconds(150))   // waiting for the panel
        controller.setShown(true)
        try await until("history read") { !controller.commits.isEmpty }
        let mine = try XCTUnwrap(controller.commits.first)
        controller.selectedCommit = mine
        let landed = await ask.value
        XCTAssertFalse(landed)
        XCTAssertEqual(controller.selectedCommit?.hash, mine.hash, "the reader's choice stays")

        // The same commit, another file chosen while a reveal waits.
        try "c\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Three"])
        let three = try git(["rev-parse", "HEAD"])
        let found = try await GitService().commit(three, in: top)
        let threeCommit = try XCTUnwrap(found)
        controller.selectedCommit = threeCommit; controller.detailFile = "a.txt"
        controller.setShown(false)
        let again = Task { await controller.revealHistory(GitHistoryTarget(commit: three, path: "c.txt", line: 1), in: top) }
        try await Task.sleep(for: .milliseconds(150))
        controller.setShown(true)
        controller.detailFile = "b.txt"
        let landedAgain = await again.value
        XCTAssertFalse(landedAgain)
        XCTAssertEqual(controller.detailFile, "b.txt", "the reader's file stays")
    }

    /// Shown, then hidden while a reveal is on its way: dropped, even if the
    /// panel is shown again before it would land.
    @MainActor func testHidingAfterShowingDropsAReveal() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "One"])
        let one = try git(["rev-parse", "HEAD"])
        let top = try git(["rev-parse", "--show-toplevel"])
        // The panel's first read held, so the reveal is still waiting for it
        // when the panel is hidden and shown again.
        GitController.statusReadDelay = .milliseconds(400)
        defer { GitController.statusReadDelay = .zero }
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        controller.setShown(true)
        let ask = Task { await controller.revealHistory(GitHistoryTarget(commit: one, path: "a.txt", line: 1), in: top) }
        try await Task.sleep(for: .milliseconds(100))
        controller.setShown(false); controller.setShown(true)
        let landed = await ask.value
        XCTAssertFalse(landed)
        XCTAssertNil(controller.revealTarget)
    }

    @MainActor func testACommitNotHereOrAnotherRepositoryIsSaid() async throws {
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "Only"])
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        let top = try XCTUnwrap(controller.repositoryRoot)
        let missing = await controller.revealHistory(GitHistoryTarget(commit: String(repeating: "a", count: 40), path: "a.txt", line: 1), in: top)
        XCTAssertFalse(missing)
        XCTAssertTrue(controller.notice.contains("not in this repository"), controller.notice)
        let elsewhere = await controller.revealHistory(GitHistoryTarget(commit: try git(["rev-parse", "HEAD"]), path: "a.txt", line: 1), in: "/somewhere/else")
        XCTAssertFalse(elsewhere)
        XCTAssertNil(controller.revealTarget)
    }
}

/// The state watch blame uses: told of a commit or a stage, not of a save.
final class GitStateWatchTests: XCTestCase {
    @MainActor func testACommitIsToldAndASaveIsNot() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-state-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=F", "-c", "user.email=f@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = root; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }
        try git(["init", "-q", "-b", "main"])
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "First"])
        var told = 0
        let watch = GitStateWatch(root: root.path) { told += 1 }
        watch.start(); defer { watch.stop() }
        XCTAssertTrue(watch.isWatching)
        try await Task.sleep(for: .milliseconds(800))
        told = 0
        try "a2\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(told, 0, "a save is not the watch's")
        try git(["commit", "-q", "-am", "Second"])
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while told == 0, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(told, 0, "a commit is")

        // A linked worktree: its branch lives in the main repository's git
        // directory, and moving it there is told too.
        let linked = root.deletingLastPathComponent().appendingPathComponent("git-state-linked-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked) }
        try git(["worktree", "add", "-q", "-b", "side", linked.path])
        var toldLinked = 0
        let linkedWatch = GitStateWatch(root: linked.path) { toldLinked += 1 }
        linkedWatch.start(); defer { linkedWatch.stop() }
        try await Task.sleep(for: .milliseconds(800))
        toldLinked = 0
        try git(["update-ref", "refs/heads/side", "HEAD~1"])
        let until = ProcessInfo.processInfo.systemUptime + 10
        while toldLinked == 0, ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(toldLinked, 0, "a linked worktree's branch moved in the common directory")
        // Its own HEAD, in its own git directory inside the common one.
        try await Task.sleep(for: .milliseconds(800))
        toldLinked = 0
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", "-q", "--detach"]; process.currentDirectoryURL = linked
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let again = ProcessInfo.processInfo.systemUptime + 10
        while toldLinked == 0, ProcessInfo.processInfo.systemUptime < again { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThan(toldLinked, 0, "the worktree's own HEAD moved")
    }
}
