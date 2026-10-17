import XCTest
import Darwin
@testable import GitView

final class GitPathBoundaryTests: GitPanelTestCase {
    override func repository(_ name: String = "git-path") throws -> URL {
        let root = try super.repository(name)
        let pointer = try XCTUnwrap(realpath(root.path, nil))
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }
    private let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
    @discardableResult override func git(_ arguments: [String], in root: URL, expectSuccess: Bool = true) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = root; process.environment = environment
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if expectSuccess { XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)") }
        return String(decoding: data, as: UTF8.self)
    }
    override func start(_ root: URL) throws {
        try git(["init", "-q", "--template=", "-b", "main"], in: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            try git(["config", key, value], in: root)
        }
    }
    private func service() -> GitService { GitService(environment: environment) }
    @MainActor func testRewordSeesOperationMarkersInsideANewlinePath() async throws {
        let folder = try repository("git-operation-path")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("repo\ninside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try start(root); try git(["commit", "--allow-empty", "-qm", "Base"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .newlines)
        try Data((head + "\n").utf8).write(to: root.appendingPathComponent(".git/MERGE_HEAD"))
        do { _ = try await service().reword(message: "Must not reword", in: root.path, expectedHead: head); XCTFail("active merge must block reword") }
        catch { XCTAssertTrue(error.localizedDescription.contains("merge"), error.localizedDescription) }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), head + "\n")
    }

    @MainActor func testRewordRunsTheConfiguredHookInATrailingNewlineDirectory() async throws {
        let root = try repository("git-hook-path")
        defer { try? FileManager.default.removeItem(at: root) }
        try start(root); try git(["commit", "--allow-empty", "-qm", "Base"], in: root)
        let hooks = root.appendingPathComponent("hooks\n"), hook = hooks.appendingPathComponent("post-rewrite")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("#!/bin/sh\ncat > .git/rewritten\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(["config", "core.hooksPath", hooks.path], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .newlines)
        _ = try await service().reword(message: "Reworded", in: root.path, expectedHead: head)
        let new = try git(["rev-parse", "HEAD"], in: root)
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent(".git/rewritten"), encoding: .utf8), head + " " + new)
    }

    @MainActor func testPatchReviewPreservesTheRootsTrailingNewline() async throws {
        let folder = try repository("git-patch-path")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("repo\n")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try start(root)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try git(["add", "notes.txt"], in: root); try git(["commit", "-qm", "Base"], in: root)
        try Data("working\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let review = try await service().patchReview(in: root.path, path: "notes.txt", staged: false)
        XCTAssertEqual(review.root, root.path)
        XCTAssertFalse(review.patch.hunks.isEmpty)
    }

    @MainActor func testWatcherPreservesWhitespaceInExternalGitAndCommonDirectories() async throws {
        let folder = try repository("git-watch-path")
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in ["", " ", "\ninside"] {
            let root = folder.appendingPathComponent("repo" + UUID().uuidString), metadata = folder.appendingPathComponent("metadata" + suffix)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git(["init", "-q", "--template=", "--separate-git-dir", metadata.path, "-b", "main"], in: root)
            XCTAssertEqual(try git(["rev-parse", "--absolute-git-dir"], in: root), metadata.path + "\n", "Git accepts the generated location")
            for terminator in ["\n", "\r\n"] {
                try Data(("gitdir: " + metadata.path + terminator).utf8).write(to: root.appendingPathComponent(".git"))
                XCTAssertEqual(GitWorkingTreeWatcher.gitDirectory(under: root.path), metadata.resolvingSymlinksInPath().path)
            }
            let linked = folder.appendingPathComponent("linked" + UUID().uuidString)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: linked.appendingPathComponent("HEAD"))
            try Data(("gitdir: " + linked.path + "\n").utf8).write(to: root.appendingPathComponent(".git"))
            for terminator in ["\n", "\r\n"] {
                try Data((metadata.path + terminator).utf8).write(to: linked.appendingPathComponent("commondir"))
                XCTAssertEqual(try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root), metadata.path + "\n")
                XCTAssertEqual(GitWorkingTreeWatcher.commonDirectory(of: linked.path), metadata.resolvingSymlinksInPath().path)
            }
        }
    }

    @MainActor func testDiscardPreservesWhitespaceInTheRepositoryRoot() async throws {
        let folder = try repository("git-path-boundary")
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in [" ", "\t", "\n", "\r", "\r\n"] {
            let sibling = folder.appendingPathComponent("repo"), chosen = folder.appendingPathComponent("repo" + suffix)
            for root in [sibling, chosen] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try start(root)
                try Data("base\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
                try git(["add", "notes.txt"], in: root); try git(["commit", "-qm", "Base"], in: root)
                try Data("staged\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
                try git(["add", "notes.txt"], in: root)
                try Data("working\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
            }
            let index = try git(["show", ":notes.txt"], in: sibling)
            let controller = GitController(roots: [chosen.path], service: service())
            await controller.refresh()
            try await eventually("read chosen repository") { controller.statusRead && !controller.loading }
            XCTAssertEqual(controller.repositoryRoot, chosen.path, "the selected directory owns the snapshot")
            let entry = try XCTUnwrap(controller.status.entries.first { $0.path == "notes.txt" })
            await controller.discard([entry])
            XCTAssertEqual(controller.notice, "", "Discard failed for suffix \(String(reflecting: suffix))")
            XCTAssertEqual(try String(contentsOf: chosen.appendingPathComponent("notes.txt"), encoding: .utf8), "base\n")
            XCTAssertEqual(try git(["show", ":notes.txt"], in: chosen), "base\n")
            XCTAssertEqual(try String(contentsOf: sibling.appendingPathComponent("notes.txt"), encoding: .utf8), "working\n", "sibling worktree must stay untouched")
            XCTAssertEqual(try git(["show", ":notes.txt"], in: sibling), index, "sibling index must stay untouched")
            controller.letGo()
            try FileManager.default.removeItem(at: sibling)
        }
    }
}
