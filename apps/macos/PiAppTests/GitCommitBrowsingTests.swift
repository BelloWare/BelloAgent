import XCTest
@testable import PiApp

/// Moving through history against a real repository: a commit's files appear
/// before any patch is read, a commit that was already read comes back without
/// running git again, a big commit keeps its patch off screen until it is
/// asked for, and one path's history is its own list.
final class GitCommitBrowsingTests: XCTestCase {
    private func repository() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("git-browse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
    private func start(_ root: URL) throws {
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "Fixture"], in: root)
        try git(["config", "user.email", "fixture@example.com"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
    }
    @MainActor private func eventually(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Never \(what)", file: file, line: line)
    }

    @MainActor func testCommitDetailsAreCachedCancellableAndNeverParsedTwice() async throws {
        let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for index in 1...3 {
            try String(repeating: "line \(index)\n", count: 20).write(to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Commit \(index)"], in: root)
        }
        let controller = GitController(roots: [root.path])
        try await eventually("read the history") { controller.commits.count == 3 }
        XCTAssertEqual(controller.commits.map(\.subject), ["Commit 3", "Commit 2", "Commit 1"])

        let newest = controller.commits[0], older = controller.commits[1]
        controller.selectedCommit = newest
        try await eventually("read the newest commit") { !controller.detailDiff.isEmpty }
        XCTAssertEqual(controller.detail?.commit.hash, newest.hash)
        XCTAssertEqual(controller.detail?.files.map(\.path), ["file3.txt"])
        XCTAssertEqual(controller.detail?.insertions, 20); XCTAssertEqual(controller.detail?.deletions, 0)
        XCTAssertEqual(controller.detailDiff.map(\.path), ["file3.txt"])
        XCTAssertFalse(controller.detailDiffDeferred)

        controller.selectedCommit = older
        try await eventually("read the older commit") { controller.detailDiff.map(\.path) == ["file2.txt"] }

        // Coming back shows the commit with no further read: this is what makes
        // clicking through history feel immediate rather than re-running git.
        controller.selectedCommit = newest
        XCTAssertEqual(controller.detail?.commit.hash, newest.hash, "the cached detail is there before any await")
        XCTAssertEqual(controller.detailDiff.map(\.path), ["file3.txt"])
        XCTAssertFalse(controller.diffLoading, "a cached commit starts no git process")

        // Racing through commits leaves the last one showing, never an earlier one.
        for commit in controller.commits { controller.selectedCommit = commit }
        try await eventually("settle on the oldest commit") { !controller.diffLoading && controller.detail?.commit.hash == controller.commits[2].hash }
        XCTAssertEqual(controller.detailDiff.map(\.path), ["file1.txt"])
        XCTAssertEqual(controller.notice, "")
    }

    @MainActor func testALargeCommitListsItsFilesBeforeAnyPatchAndOpensOneFileAtATime() async throws {
        let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for index in 1...40 {
            try String(repeating: "content \(index)\n", count: 120).write(to: root.appendingPathComponent("big\(index).txt"), atomically: true, encoding: .utf8)
        }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Forty files"], in: root)

        let controller = GitController(roots: [root.path])
        try await eventually("read the history") { controller.commits.count == 2 }
        controller.selectedCommit = controller.commits[0]
        try await eventually("list the changed files") { controller.detail?.files.count == 40 }
        XCTAssertTrue(controller.detail?.isLarge == true)
        XCTAssertEqual(controller.detail?.insertions, 40 * 120)
        XCTAssertEqual(controller.detail?.summary, "40 files · +4800 −0")
        XCTAssertTrue(controller.detailDiffDeferred, "a big patch waits to be asked for")
        XCTAssertTrue(controller.detailDiff.isEmpty)

        // One file opens on its own, without the other thirty-nine.
        controller.detailFile = "big7.txt"
        try await eventually("read one file's diff") { controller.detailFileDiff.map(\.path) == ["big7.txt"] }
        XCTAssertEqual(controller.detailFileDiff.first?.added, 120)
        XCTAssertTrue(controller.detailDiff.isEmpty)

        controller.detailFile = nil
        try await eventually("return to the file list") { controller.detailDiffDeferred }
        controller.loadDeferredCommitDiff()
        try await eventually("read the whole patch") { controller.detailDiff.count == 40 }
        XCTAssertFalse(controller.detailDiffDeferred)
    }

    /// Opt-in measurement against a real repository, for the release record:
    /// PI_APP_GIT_BENCH_REPO names the checkout to read. It prints what one
    /// click on a commit costs now and what reading its whole patch costs.
    func testMeasureCommitBrowsingWhenRequested() async throws {
        guard let path = testEnvironment("PI_APP_GIT_BENCH_REPO") else {
            throw XCTSkip("Set PI_APP_GIT_BENCH_REPO to measure commit browsing against a real repository")
        }
        let service = GitService()
        let discovered = await service.repositoryRoot(of: path)
        let root = try XCTUnwrap(discovered)
        let commits = try await service.log(in: root, limit: 12)
        XCTAssertFalse(commits.isEmpty)
        func milliseconds(_ work: () async throws -> Void) async rethrows -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            try await work()
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        var legacy = 0.0, metadata = 0.0, patches = 0.0, lines = 0, files = 0
        for commit in commits {
            // What one click cost before: three reads in a row, the last one the
            // whole patch, and the text parsed by the caller that is waiting.
            legacy += try await milliseconds {
                _ = try await service.run(["show", "--no-patch", "--format=%B", commit.hash], in: root)
                _ = try await service.run(["show", "--format=", "--name-status", "-z", "--find-renames", "-m", "--first-parent", commit.hash], in: root)
                let patch = try await service.run(["show", "--format=", "--no-ext-diff", "-U3", "--find-renames", "-m", "--first-parent", commit.hash], in: root)
                _ = GitDiffParser.parse(patch.text)
            }
            var detail: GitCommitDetail?
            metadata += try await milliseconds { detail = try await service.commitDetail(in: root, commit: commit) }
            var parsed: [GitDiffFile] = []
            patches += try await milliseconds { parsed = try await service.commitDiffFiles(in: root, commit: commit) }
            lines += parsed.reduce(0) { $0 + $1.lineCount }; files += detail?.files.count ?? 0
        }
        let count = Double(commits.count)
        print(String(format: "PERF git one commit, previous shape (three reads, whole patch, parsed by the caller): %.1f ms", legacy / count))
        print(String(format: "PERF git commit metadata (message, %d files, line counts): %.1f ms per commit", files, metadata / count))
        print(String(format: "PERF git whole-commit patch read and parse off the main thread (%d diff lines): %.1f ms per commit", lines, patches / count))
        print("PERF git commits measured: \(commits.count) from \(root)")
    }

    @MainActor func testOnePathHasItsOwnHistoryThatFollowsARename() async throws {
        let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "first\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "other\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Add both files"], in: root)
        try "first\nsecond\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Extend the notes"], in: root)
        try git(["mv", "notes.txt", "renamed.txt"], in: root)
        try git(["commit", "-q", "-m", "Rename the notes"], in: root)
        try "other\nchanged\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Touch the other file"], in: root)

        let controller = GitController(roots: [root.path])
        try await eventually("read the history") { controller.commits.count == 4 }
        controller.showFileHistory("renamed.txt")
        XCTAssertEqual(controller.panel, .history)
        try await eventually("filter the history to one path") { controller.commits.count == 3 }
        XCTAssertEqual(controller.commits.map(\.subject), ["Rename the notes", "Extend the notes", "Add both files"])
        controller.clearFileHistory()
        try await eventually("show every commit again") { controller.commits.count == 4 }

        // The rename keeps both names in the commit that performed it.
        let service = GitService()
        let renameCommit = try XCTUnwrap(controller.commits.first { $0.subject == "Rename the notes" })
        let detail = try await service.commitDetail(in: root.path, commit: renameCommit)
        XCTAssertEqual(detail.files.first?.badge, "R")
        XCTAssertEqual(detail.files.first?.originalPath, "notes.txt")
        XCTAssertEqual(detail.stats["renamed.txt"], GitDiffStat(added: 0, removed: 0, binary: false))
    }
}
