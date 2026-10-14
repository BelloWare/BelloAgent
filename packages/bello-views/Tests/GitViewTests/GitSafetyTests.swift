import XCTest
@testable import GitView

/// Generated repositories only. No inherited hooks, signing, remotes or helpers.
final class GitSafetyTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"])
        for (key, value) in [("user.name", "Safety Fixture"), ("user.email", "safety@example.invalid"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("credential.helper", ""),
                             ("core.hooksPath", root.appendingPathComponent(".git/hooks").path),
                             ("core.fsmonitor", "false"), ("protocol.allow", "never")] {
            try git(["config", key, value])
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ args: [String], status: Int32 = 0) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, status, "git \(args)")
        return String(decoding: bytes, as: UTF8.self)
    }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    private func bytes(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    private func seed() throws { try write("file.txt", "base\n"); try git(["add", "."]); try git(["commit", "-qm", "Base"]) }
    private func conflict() throws {
        try seed(); try git(["checkout", "-qb", "side"]); try write("file.txt", "side\n")
        try git(["commit", "-qam", "Side"]); try git(["checkout", "-q", "main"])
        try write("file.txt", "main\n"); try git(["commit", "-qam", "Main"]); try git(["merge", "side"], status: 1)
    }
    @MainActor private func read() async throws -> GitController {
        let controller = GitController(roots: [root.path])
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        while !controller.statusRead || controller.loading {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitFailure(message: "Fixture status never loaded") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return controller
    }

    func testUnbornUnstagePreservesWorkingBytesAndUnrelatedIndexBlobs() async throws {
        try write("[a].txt", "staged\n"); try write("a.txt", "held\n"); try git(["add", "."])
        try write("[a].txt", "later working bytes\r\n")
        let working = try bytes("[a].txt"), held = try git(["show", ":a.txt"])
        try await GitService().unstage(["[a].txt"], in: root.path)
        XCTAssertEqual(try bytes("[a].txt"), working)
        XCTAssertEqual(try git(["show", ":a.txt"]), held)
        XCTAssertEqual(try git(["ls-files", "-z"]), "a.txt\0")
        let status = try await GitService().status(in: root.path)
        XCTAssertNil(status.head)
        XCTAssertTrue(status.entries.contains { $0.path == "[a].txt" && $0.untracked })
    }

    func testUnmergedEntriesAreConflictsAndNeverStagedOrUntracked() async throws {
        try conflict(); try write("untracked.txt", "untracked\n")
        let status = try await GitService().status(in: root.path)
        let entry = try XCTUnwrap(status.entries.first { $0.path == "file.txt" })
        XCTAssertEqual(entry.summary, "Conflict")
        XCTAssertEqual(entry.badge, "!")
        XCTAssertFalse(entry.staged)
        XCTAssertFalse(entry.untracked)
        XCTAssertTrue(entry.unstaged)
        XCTAssertEqual(status.entries.first { $0.path == "untracked.txt" }?.summary, "Untracked")
    }

    @MainActor func testAmendRefusesTheHeadThatChangedAfterThePanelReadIt() async throws {
        try seed(); try write("file.txt", "reviewed work\n")
        let controller = try await read(); defer { controller.letGo() }
        controller.amend = true; controller.commitMessage = "Reviewed amend"
        try git(["commit", "--allow-empty", "-qm", "Made elsewhere"])
        let head = try git(["rev-parse", "HEAD"]), index = try git(["ls-files", "-s"]), work = try bytes("file.txt")
        await controller.commitInScope()
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["ls-files", "-s"]), index)
        XCTAssertEqual(try bytes("file.txt"), work)
        XCTAssertEqual(controller.commitMessage, "Reviewed amend")
        XCTAssertTrue(controller.notice.contains("changed"), controller.notice)
    }

    @MainActor func testAmendRefusesAnotherBranchEvenWhenItNamesTheSameHead() async throws {
        try seed(); try write("file.txt", "reviewed work\n")
        let controller = try await read(); defer { controller.letGo() }
        controller.amend = true; controller.commitMessage = "Reviewed amend"
        try git(["checkout", "-qb", "elsewhere"])
        let head = try git(["rev-parse", "HEAD"]), index = try git(["ls-files", "-s"]), work = try bytes("file.txt")
        await controller.commitInScope()
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["ls-files", "-s"]), index)
        XCTAssertEqual(try bytes("file.txt"), work)
        XCTAssertEqual(controller.commitMessage, "Reviewed amend")
    }

    func testConflictRefusalHappensBeforeStagingAnyCheckedFiles() async throws {
        try conflict(); try write("new.txt", "new\n")
        let head = try git(["rev-parse", "HEAD"]), index = try git(["ls-files", "-s"]), work = try bytes("file.txt")
        do {
            _ = try await GitService().commit(message: "Unsafe", in: root.path, content: .files(paths: ["file.txt", "new.txt"], staging: ["new.txt"]))
            XCTFail("Conflicts must be resolved explicitly")
        } catch { }
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["ls-files", "-s"]), index)
        XCTAssertEqual(try bytes("file.txt"), work)
        XCTAssertEqual(try bytes("new.txt"), Data("new\n".utf8))
    }

    func testEveryUnmergedPairKeepsItsConflictMeaningAndLiteralPath() {
        for pair in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let raw = "u \(pair) N... 100644 100644 100644 100644 a b c a file\nwith spaces.txt\0"
            let entry = GitService.parseStatus(Data(raw.utf8)).entries.first
            XCTAssertEqual(entry?.path, "a file\nwith spaces.txt")
            XCTAssertEqual(entry?.summary, "Conflict", pair)
            XCTAssertEqual(entry?.badge, "!", pair)
            XCTAssertEqual(entry?.staged, false, pair)
            XCTAssertEqual(entry?.untracked, false, pair)
        }
    }

    func testWhitespaceChecksTheChosenBytesWithoutChangingTheIndexOrWorktree() async throws {
        try seed(); try write("file.txt", "clean staged\n"); try git(["add", "file.txt"])
        try write("file.txt", "working with spaces  \n"); try write("[new].txt", "new with spaces  \n")
        let service = GitService(), index = try bytes(".git/index"), work = try bytes("file.txt"), new = try bytes("[new].txt")
        let head = try git(["rev-parse", "HEAD^{tree}"])
        let staged = try await service.preflight(in: root.path, content: .staged)
        let checked = try await service.preflight(in: root.path, content: .files(paths: ["file.txt"], staging: []))
        let untracked = try await service.preflight(in: root.path, content: .files(paths: ["[new].txt"], staging: ["[new].txt"]))
        XCTAssertFalse(staged.hasWarnings)
        XCTAssertTrue(checked.hasWarnings); XCTAssertTrue(checked.detail.contains("file.txt"))
        XCTAssertFalse(checked.detail.contains("[new].txt"), "unchecked files are outside the whitespace scope")
        XCTAssertTrue(untracked.hasWarnings)
        XCTAssertEqual(try bytes(".git/index"), index)
        XCTAssertEqual(try bytes("file.txt"), work); XCTAssertEqual(try bytes("[new].txt"), new)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), head)
        try git(["add", "file.txt"]); try write("file.txt", "clean working\n")
        let dirtyIndex = try await service.preflight(in: root.path, content: .staged)
        let cleanDisk = try await service.preflight(in: root.path, content: .files(paths: ["file.txt"], staging: []))
        XCTAssertTrue(dirtyIndex.hasWarnings); XCTAssertFalse(cleanDisk.hasWarnings)
    }

    func testPreflightKeepsAdvisoryLineEndingWarningsAndAllowsTheConfiguredCommit() async throws {
        try seed(); try git(["config", "core.autocrlf", "input"]); try git(["config", "core.safecrlf", "warn"])
        try write("file.txt", "first\r\nsecond\n")
        let index = try bytes(".git/index"), working = try bytes("file.txt"), service = GitService()
        let result = try await service.preflight(in: root.path, content: .files(paths: ["file.txt"], staging: []))
        XCTAssertTrue(result.canCommit); XCTAssertTrue(result.hasWarnings)
        XCTAssertTrue(result.detail.contains("CRLF"), result.detail)
        XCTAssertEqual(try bytes(".git/index"), index); XCTAssertEqual(try bytes("file.txt"), working)
        _ = try await service.commit(message: "Configured conversion", in: root.path, content: .files(paths: ["file.txt"], staging: []))
        XCTAssertEqual(try git(["show", "HEAD:file.txt"]), "first\nsecond\n")
        XCTAssertEqual(try bytes("file.txt"), working)
    }

    func testUnbornPreflightChecksCurrentBytesAndHonorsGitWhitespaceRules() async throws {
        try write("file.txt", "staged spaces  \n"); try git(["add", "file.txt"]); try write("file.txt", "clean disk\n")
        let service = GitService()
        let staged = try await service.preflight(in: root.path, content: .staged)
        let checked = try await service.preflight(in: root.path, content: .files(paths: ["file.txt"], staging: []))
        XCTAssertTrue(staged.hasWarnings); XCTAssertFalse(checked.hasWarnings)
        try git(["config", "core.whitespace", "-blank-at-eol"])
        let configured = try await service.preflight(in: root.path, content: .staged)
        XCTAssertFalse(configured.hasWarnings)
    }

    func testServiceRejectsAnOldAmendTargetBeforeStagingNewFiles() async throws {
        try seed()
        let service = GitService(), target = try await service.commitTarget(in: root.path)
        try git(["commit", "--allow-empty", "-qm", "New HEAD"])
        try write("new.txt", "new\n")
        let index = try bytes(".git/index"), head = try git(["rev-parse", "HEAD"])
        do {
            _ = try await service.commit(message: "Stale", in: root.path, content: .files(paths: ["new.txt"], staging: ["new.txt"]), amend: true, expectedTarget: target)
            XCTFail("The old target must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try bytes(".git/index"), index)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try bytes("new.txt"), Data("new\n".utf8))
    }

    func testRewordRejectsAnotherBranchWithTheSameHead() async throws {
        try seed(); let service = GitService(), target = try await service.commitTarget(in: root.path)
        try git(["checkout", "-qb", "elsewhere"])
        let index = try bytes(".git/index"), head = try git(["rev-parse", "HEAD"])
        do {
            _ = try await service.reword(message: "Stale", in: root.path, expectedHead: target?.head, expectedTarget: target)
            XCTFail("A branch switch invalidates a reword confirmation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try bytes(".git/index"), index); XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }

    func testAmendRechecksItsTargetAfterPreparingUntrackedFiles() async throws {
        try seed()
        let service = GitService(), target = try await service.commitTarget(in: root.path)
        let tree = try git(["rev-parse", "HEAD^{tree}"])
        try write(".gitattributes", "new.txt filter=advance\n"); try write("new.txt", "new\n")
        let hook = root.appendingPathComponent(".git/hooks/advance")
        let script = "#!/bin/sh\nif [ ! -f .git/advanced ]; then\n  touch .git/advanced\n  next=$(git commit-tree HEAD^{tree} -p HEAD -m 'Filter advanced HEAD')\n  git update-ref HEAD \"$next\"\nfi\ncat\n"
        try Data(script.utf8).write(to: hook)
        try git(["config", "filter.advance.clean", "sh .git/hooks/advance"])
        do {
            _ = try await service.commit(message: "Unsafe amend", in: root.path, content: .files(paths: ["new.txt"], staging: ["new.txt"]), amend: true, expectedTarget: target)
            XCTFail("The HEAD changed during preparation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed"), error.localizedDescription) }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Filter advanced HEAD\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]).trimmingCharacters(in: .newlines), target?.head)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), tree)
        // Preparation has already staged this new file; never roll an index
        // back across a hook/external writer. The newer HEAD is not amended.
        XCTAssertEqual(try git(["show", ":new.txt"]), "new\n")
        XCTAssertEqual(try bytes("new.txt"), Data("new\n".utf8))
    }

    func testSignOffReachesHooksAndPreservesCommitScopeAndRewordTree() async throws {
        try seed(); try write("file.txt", "staged\n"); try git(["add", "file.txt"]); try write("file.txt", "working\n")
        let hook = root.appendingPathComponent(".git/hooks/commit-msg")
        try Data("#!/bin/sh\ncp \"$1\" .git/seen-message\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let service = GitService()
        _ = try await service.commit(message: "Signed", in: root.path, content: .staged, signOff: true)
        let trailer = "Signed-off-by: Safety Fixture <safety@example.invalid>"
        XCTAssertTrue(String(decoding: try bytes(".git/seen-message"), as: UTF8.self).contains(trailer))
        XCTAssertTrue(try git(["log", "-1", "--format=%B"]).contains(trailer))
        XCTAssertEqual(try git(["show", "HEAD:file.txt"]), "staged\n")
        XCTAssertEqual(try bytes("file.txt"), Data("working\n".utf8))
        let tree = try git(["rev-parse", "HEAD^{tree}"]), index = try bytes(".git/index")
        let head = try await service.headCommit(in: root.path)
        _ = try await service.reword(message: "Reworded\n\n" + trailer, in: root.path, expectedHead: head, signOff: true)
        let message = try git(["log", "-1", "--format=%B"])
        XCTAssertEqual(message.components(separatedBy: trailer).count, 2, "a repeated sign-off is not duplicated")
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), tree)
        XCTAssertEqual(try bytes(".git/index"), index)
        XCTAssertEqual(try bytes("file.txt"), Data("working\n".utf8))
    }
}
