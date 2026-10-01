import XCTest
@testable import GitView

/// File names git would otherwise read as patterns or magic: each command
/// touches the chosen file and nothing its name happens to match.
final class GitLiteralPathTests: XCTestCase {
    /// Pattern-like names, each beside the plain files its pattern would match.
    static let tricky = ["[id].txt", "*.md", "?.txt", ":odd", ":(glob)g"]
    static let bystanders = ["i.txt", "d.txt", "a.md", "x.txt", "odd", "g"]
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-literal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try git(["config", "commit.gpgsign", "false"])
        for name in Self.tricky + Self.bystanders { try write(name, "one\n") }
        try git(["add", "-A"]); try git(["commit", "-q", "-m", "Initial"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    private func lines(_ text: String) -> Set<String> { Set(text.split(separator: "\n").map(String.init)) }
    private func modified() throws -> Set<String> { lines(try git(["diff", "--name-only"])) }
    private func staged() throws -> Set<String> { lines(try git(["diff", "--cached", "--name-only"])) }
    private func committed() throws -> Set<String> { lines(try git(["show", "--name-only", "--format=", "HEAD"])) }

    func testDiscardAndCleanTouchOnlyTheChosenFiles() async throws {
        let service = GitService()
        for name in Self.tricky + Self.bystanders { try write(name, "two\n") }
        for name in ["[u].new", "u.new", "*.tmp", "b.tmp"] { try write(name, "new\n") }
        let entries = try await service.status(in: root.path).entries
        let chosen = entries.filter { Self.tricky.contains($0.path) || ["[u].new", "*.tmp"].contains($0.path) }
        XCTAssertEqual(chosen.count, Self.tricky.count + 2)
        try await service.discard(chosen, in: root.path)
        for name in Self.tricky { XCTAssertEqual(read(name), "one\n", name) }
        XCTAssertEqual(try modified(), Set(Self.bystanders))
        XCTAssertNil(read("[u].new")); XCTAssertNil(read("*.tmp"))
        XCTAssertEqual(read("u.new"), "new\n"); XCTAssertEqual(read("b.tmp"), "new\n")
    }

    func testStageAndUnstageTouchOnlyTheChosenFiles() async throws {
        let service = GitService()
        for name in Self.tricky + Self.bystanders { try write(name, "two\n") }
        try await service.stage(Self.tricky, in: root.path)
        XCTAssertEqual(try staged(), Set(Self.tricky))
        try await service.stage(Self.bystanders, in: root.path)
        try await service.unstage(Self.tricky, in: root.path)
        XCTAssertEqual(try staged(), Set(Self.bystanders))
    }

    func testCommitTakesOnlyTheChosenFiles() async throws {
        let service = GitService()
        for name in Self.tricky + Self.bystanders { try write(name, "two\n") }
        _ = try await service.commit(message: "Tricky only", in: root.path, paths: Self.tricky)
        XCTAssertEqual(try committed(), Set(Self.tricky))
        XCTAssertEqual(try modified(), Set(Self.bystanders))
        XCTAssertTrue(try staged().isEmpty)
    }

    /// Past one argv's worth of paths the list goes to git in a file, whose
    /// entries are pathspecs too. Newlines and backslashes ride along.
    func testALongCommitListInAPathspecFileIsLiteralToo() async throws {
        let service = GitService()
        let many = (0..<600).map { "f\($0).new" } + ["new\nline.new", "back\\slash.new"]
        for name in many { try write(name, "new\n") }
        for name in Self.tricky + Self.bystanders { try write(name, "two\n") }
        let paths = many + Self.tricky
        XCTAssertGreaterThan(GitService.batches(of: GitService.literal(paths), prefix: ["commit", "-q", "-m", "Many", "--only", "--"]).count, 1)
        _ = try await service.commit(message: "Many", in: root.path, paths: paths, staging: many)
        let names = try git(["show", "--name-only", "-z", "--format=", "HEAD"]).split(separator: "\0").map(String.init)
        XCTAssertEqual(Set(names), Set(paths))
        XCTAssertEqual(try modified(), Set(Self.bystanders))
    }

    /// The literal marking stays on git's command line: a hook's own patterns
    /// still match as patterns.
    func testACommitHookKeepsItsPatterns() async throws {
        let service = GitService()
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\ngit diff --cached --name-only -- '*.md' > .git/hook-out\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("a.md", "two\n")
        _ = try await service.commit(message: "Markdown", in: root.path, paths: ["a.md"])
        XCTAssertEqual(read(".git/hook-out"), "a.md\n")
    }

    func testARenameDiscardsBackToItsLiteralName() async throws {
        let service = GitService()
        try write("r.txt", "one\n"); try git(["add", "r.txt"]); try git(["commit", "-q", "-m", "Plain r"])
        try write("r.txt", "changed\n")
        try git(["mv", "[id].txt", "[r].txt"])
        let rename = try await renameRow("[r].txt")
        try await service.discard([rename], in: root.path)
        XCTAssertEqual(read("[id].txt"), "one\n"); XCTAssertNil(read("[r].txt"))
        XCTAssertEqual(try modified(), ["r.txt"])
    }

    /// When another row holds the old name, only the index goes back, by its
    /// literal name: a staged "i.txt" stays staged.
    func testAHeldRenameUnstagesOnlyItsLiteralOldName() async throws {
        let service = GitService()
        try write("i.txt", "two\n"); try git(["add", "i.txt"])
        try git(["mv", "[id].txt", "[r].txt"])
        let rename = try await renameRow("[r].txt")
        try await service.discard([rename], in: root.path, held: ["[id].txt"])
        XCTAssertTrue(try staged().contains("i.txt"))
    }

    private func renameRow(_ path: String) async throws -> GitStatusEntry {
        let entries = try await GitService().status(in: root.path).entries
        let rename = try XCTUnwrap(entries.first { $0.path == path })
        XCTAssertTrue(rename.isRename)
        return rename
    }

    func testHistoryAndDiffsReadOnlyTheLiteralPath() async throws {
        let service = GitService()
        try write("i.txt", "two\n"); try git(["commit", "-q", "-am", "Plain i"])
        let plain = try git(["rev-parse", "--short=8", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["mv", "[id].txt", "[s].txt"]); try git(["commit", "-q", "-m", "Rename"])
        try write("[s].txt", "two\n"); try write("s.txt", "two\n"); try git(["add", "-A"]); try git(["commit", "-q", "-m", "Both"])

        let history = try await service.log(in: root.path, path: "[s].txt")
        XCTAssertEqual(history.map(\.subject), ["Both", "Rename", "Initial"])
        let byHash = try await service.log(in: root.path, path: "[s].txt", filter: GitLogFilter(text: plain))
        XCTAssertFalse(byHash.contains { $0.subject == "Plain i" })
        let both = try XCTUnwrap(history.first)
        let shown = try await service.commitDiffFiles(in: root.path, commit: both, path: "[s].txt")
        XCTAssertEqual(shown.map(\.path), ["[s].txt"])

        try write("[s].txt", "three\n"); try write("s.txt", "three\n")
        let unstaged = try await service.diffFiles(in: root.path, paths: ["[s].txt"], staged: false)
        XCTAssertEqual(unstaged.map(\.path), ["[s].txt"])
        try git(["add", "-A"])
        let cached = try await service.diffFiles(in: root.path, paths: ["[s].txt"], staged: true)
        XCTAssertEqual(cached.map(\.path), ["[s].txt"])
    }
}
