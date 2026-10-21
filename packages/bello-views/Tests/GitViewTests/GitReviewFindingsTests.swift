import XCTest
@testable import GitView

/// The 2026-10-16 review's Git findings: discarding before the first commit,
/// the configuration location git is given, and a path with two rows.
final class GitReviewFindingsTests: ViewsTestCase {
    private var folder: URL!, root: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-review-" + UUID().uuidString)
        root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"])
        for (key, value) in [("commit.gpgsign", "false"), ("core.hooksPath", folder.appendingPathComponent("empty-hooks").path), ("core.fsmonitor", "false")] { try git(["config", key, value]) }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func git(_ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = root
        process.environment = environment ?? ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
    private func identity() throws { try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.invalid"]) }
    private func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
    private func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    private func indexed() throws -> [String] { try git(["ls-files", "--cached"]).split(separator: "\n").map(String.init) }

    // MARK: BUG-006, discarding an initial addition

    func testDiscardBeforeTheFirstCommitRemovesOnlyTheChosenAddition() async throws {
        let service = GitService()
        try write("chosen.txt", "work to discard\n"); try write("kept.txt", "staged and kept\n"); try write("loose.txt", "untracked\n")
        try git(["add", "--", "chosen.txt", "kept.txt"])
        try write("chosen.txt", "work to discard, edited after staging\n")
        let entries = try await service.status(in: root.path).entries
        let chosen = try XCTUnwrap(entries.first { $0.path == "chosen.txt" })
        XCTAssertTrue(chosen.staged && chosen.unstaged)
        try await service.discard([chosen], in: root.path)
        XCTAssertNil(read("chosen.txt"))
        XCTAssertEqual(try indexed(), ["kept.txt"])
        XCTAssertEqual(read("kept.txt"), "staged and kept\n")
        XCTAssertEqual(read("loose.txt"), "untracked\n")
        let after = try await service.status(in: root.path).entries
        XCTAssertEqual(after.map(\.path).sorted(), ["kept.txt", "loose.txt"])
    }

    /// A HEAD that cannot be read is not "before the first commit": nothing
    /// is removed, from the index or the disk. A damaged loose ref, one
    /// naming a missing commit, and unreadable packed refs.
    func testDiscardRefusesWhenTheBranchIsBrokenRatherThanUnborn() async throws {
        let service = GitService()
        try write("chosen.txt", "work\n"); try git(["add", "chosen.txt"])
        let entries = try await service.status(in: root.path).entries
        let chosen = try XCTUnwrap(entries.first { $0.path == "chosen.txt" })
        let heads = root.appendingPathComponent(".git/refs/heads"), packed = root.appendingPathComponent(".git/packed-refs")
        try FileManager.default.createDirectory(at: heads, withIntermediateDirectories: true)
        let missing = String(repeating: "0123456789", count: 4)
        for (file, text) in [(heads.appendingPathComponent("main"), "not an object id\n"), (heads.appendingPathComponent("main"), missing + "\n"),
                             (packed, "not a packed ref line\n")] {
            try? FileManager.default.removeItem(at: heads.appendingPathComponent("main")); try? FileManager.default.removeItem(at: packed)
            try Data(text.utf8).write(to: file)
            do { try await service.discard([chosen], in: root.path); XCTFail("A broken branch must not read as unborn: \(text)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("could not be read") || error.localizedDescription.contains("packed-refs"), error.localizedDescription) }
            XCTAssertEqual(read("chosen.txt"), "work\n", text)
            try? FileManager.default.removeItem(at: heads.appendingPathComponent("main")); try? FileManager.default.removeItem(at: packed)
            XCTAssertEqual(try indexed(), ["chosen.txt"], text)
        }
    }

    /// An orphan branch whose name is the start of another branch's
    /// (`topic` beside `topic/work`) is still unborn: unstage and discard work.
    func testOrphanBranchBesideANamespacedBranchIsUnborn() async throws {
        let service = GitService()
        try identity()
        try git(["commit", "-q", "--allow-empty", "-m", "Base"]); try git(["branch", "topic/work"]); try git(["switch", "-q", "--orphan", "topic"])
        try write("staged.txt", "staged\n"); try write("chosen.txt", "chosen\n"); try git(["add", "--", "staged.txt", "chosen.txt"])
        let unborn = try await service.isUnbornBranch(in: root.path)
        XCTAssertTrue(unborn)
        try await service.unstage(["staged.txt"], in: root.path)
        XCTAssertEqual(try indexed(), ["chosen.txt"])
        let entries = try await service.status(in: root.path).entries
        try await service.discard([try XCTUnwrap(entries.first { $0.path == "chosen.txt" })], in: root.path)
        XCTAssertEqual(try indexed(), [])
        XCTAssertNil(read("chosen.txt")); XCTAssertEqual(read("staged.txt"), "staged\n")
    }

    /// Discarding a newly added submodule before the first commit takes only
    /// its index entry: `.gitmodules` (its own row) stays staged as it was,
    /// and nothing inside the submodule's folder is touched.
    func testDiscardBeforeTheFirstCommitLeavesAnAddedSubmodulesContentsAndGitmodules() async throws {
        let service = GitService()
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fixture = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
        for args in [["init", "-q", "-b", "main", sub.path], ["-C", sub.path, "-c", "user.name=F", "-c", "user.email=f@example.invalid", "commit", "-q", "--allow-empty", "-m", "Sub"]] {
            try git(args, environment: fixture)
        }
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "mod"])
        try write("mod/dirty.txt", "inside the submodule\n")
        let gitmodules = try git(["ls-files", "-s", "--", ".gitmodules"]), text = read(".gitmodules")
        let entries = try await service.status(in: root.path).entries
        let module = try XCTUnwrap(entries.first { $0.path == "mod" })
        try await service.discard([module], in: root.path)
        XCTAssertEqual(try indexed(), [".gitmodules"])
        XCTAssertEqual(try git(["ls-files", "-s", "--", ".gitmodules"]), gitmodules)
        XCTAssertEqual(read(".gitmodules"), text)
        XCTAssertEqual(read("mod/dirty.txt"), "inside the submodule\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("mod/.git").path))
    }

    // MARK: BUG-007, the configuration location the app was given

    func testGitKeepsTheAppsXDGConfigurationButNotRepositoryOverrides() async throws {
        let home = folder.appendingPathComponent("home"), xdg = folder.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("git"), withIntermediateDirectories: true)
        try Data("[user]\n\tname = XDG Only\n\temail = xdg-only@example.invalid\n".utf8).write(to: xdg.appendingPathComponent("git/config"))
        let elsewhere = folder.appendingPathComponent("elsewhere").path
        let app = ["XDG_CONFIG_HOME": xdg.path, "GIT_DIR": elsewhere, "GIT_WORK_TREE": elsewhere, "GIT_INDEX_FILE": elsewhere + "/index",
                   "GIT_OBJECT_DIRECTORY": elsewhere, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_PARAMETERS": "'user.email'='leak@example.invalid'"]
        let environment = GitService.gitEnvironment(from: app, home: home.path)
        XCTAssertEqual(environment["XDG_CONFIG_HOME"], xdg.path)
        XCTAssertTrue(environment.keys.allSatisfy { !$0.hasPrefix("GIT_") || ["GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS"].contains($0) }, "\(environment.keys.sorted())")
        XCTAssertNil(GitService.gitEnvironment(from: ["XDG_CONFIG_HOME": ""], home: home.path)["XDG_CONFIG_HOME"])

        let service = GitService(environment: environment)
        try write("a.txt", "committed with the XDG identity\n")
        _ = try await service.commit(message: "From XDG", in: root.path, content: .files(paths: ["a.txt"], staging: ["a.txt"]))
        XCTAssertEqual(try git(["log", "-1", "--format=%an <%ae>"]), "XDG Only <xdg-only@example.invalid>\n")
    }

    // MARK: BUG-008, a staged deletion and an untracked file at one path

    @MainActor func testRecreatedFileShowsItsOwnPatchBesideTheStagedDeletion() async throws {
        try identity()
        try write("tracked.txt", "committed contents\n"); try git(["add", "tracked.txt"]); try git(["commit", "-q", "-m", "Base"])
        try git(["rm", "-q", "tracked.txt"]); try write("tracked.txt", "new unstaged contents\n")
        let controller = GitController(roots: [root.path]); defer { controller.letGo() }
        try await settled(controller)
        XCTAssertEqual(controller.status.entries.filter { $0.path == "tracked.txt" }.count, 2)
        for (staged, expected) in [(false, "+new unstaged contents"), (true, "-committed contents")] {
            controller.selection = GitController.Selection(path: "tracked.txt", staged: staged)
            try await until("the \(staged ? "staged" : "unstaged") patch") {
                !controller.diffLoading && controller.selection?.staged == staged && !controller.diff.isEmpty
            }
            let lines = controller.diff.flatMap(\.hunks).flatMap(\.lines).map { ($0.kind == .added ? "+" : $0.kind == .removed ? "-" : " ") + $0.text }
            XCTAssertEqual(lines, [expected], staged ? "staged deletion" : "untracked recreation")
        }
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
        try await until("settled") { controller.statusRead && !controller.loading && !controller.commitLoading }
    }
}
