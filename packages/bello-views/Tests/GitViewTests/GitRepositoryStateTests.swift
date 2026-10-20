import Combine
import XCTest
@testable import GitView

final class GitRepositoryStateTests: XCTestCase {
    private static let summaryService = GitService(environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    @MainActor func testSummaryAndChangesUseEffectiveRenameConfigurationAcrossScopes() async throws {
        for scope in ["global/local", "local/worktree"] {
            let root = try renameRepository()
            try git(["mv", "same.txt", "moved.txt"], in: root)
            let environment = try configurationScopes(in: root, scope: scope, key: "diff.renames", earlier: "true", later: "false")
            let effective = try git(["config", "--get", "diff.renames"], in: root, environment: environment).trimmingCharacters(in: .newlines)
            XCTAssertEqual(effective, "false")
            try await assertControllersMatchGitStatus(in: root, environment: environment,
                statusOptions: ["-c", "status.renames=" + effective], badges: ["A", "D"])
        }
    }

    @MainActor func testSummaryAndChangesUseEffectiveRenameLimitAcrossScopes() async throws {
        for scope in ["global/local", "local/worktree"] {
            for limits in [("1", "1000"), ("1000", "1")] {
                let root = try renameLimitRepository()
                let environment = try configurationScopes(in: root, scope: scope, key: "diff.renameLimit", earlier: limits.0, later: limits.1)
                let effective = try git(["config", "--get", "diff.renameLimit"], in: root, environment: environment).trimmingCharacters(in: .newlines)
                XCTAssertEqual(effective, limits.1)
                try await assertControllersMatchGitStatus(in: root, environment: environment,
                    statusOptions: ["-c", "status.renameLimit=" + effective], badges: effective == "1" ? ["A", "A", "A", "D", "D", "D"] : ["R", "R", "R"])
            }
        }
    }

    @MainActor func testSummaryAndChangesUseIncludedRenameConfiguration() async throws {
        let root = try renameRepository()
        try (renameText + "copy addition\n").write(to: root.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
        try (renameText + "source addition\n").write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        let environment = try configurationScopes(in: root, scope: "global/local", key: "diff.renames", earlier: "true", later: "false")
        let included = root.appendingPathComponent(".git/fixture-included")
        try "[diff]\nrenames = copies\n".write(to: included, atomically: true, encoding: .utf8)
        try git(["config", "includeIf.onbranch:main.path", included.path], in: root, environment: environment)
        let effective = try git(["config", "--get", "diff.renames"], in: root, environment: environment).trimmingCharacters(in: .newlines)
        XCTAssertEqual(effective, "copies")
        try await assertControllersMatchGitStatus(in: root, environment: environment,
            statusOptions: ["-c", "status.renames=" + effective], badges: ["C", "M"])
    }

    @MainActor func testSummaryAndChangesKeepStatusOverridesAcrossScopes() async throws {
        for key in ["renames", "renameLimit"] {
            let root = try renameLimitRepository()
            let earlier = key == "renames" ? "false" : "1", later = key == "renames" ? "true" : "1000"
            let environment = try configurationScopes(in: root, scope: "global/local", key: "status." + key, earlier: earlier, later: later)
            try git(["config", "extensions.worktreeConfig", "true"], in: root, environment: environment)
            try git(["config", "--worktree", "diff." + key, earlier], in: root, environment: environment)
            // Status's explicit option wins even over a later diff fallback.
            try await assertControllersMatchGitStatus(in: root, environment: environment, badges: ["R", "R", "R"])
            try git(["config", "--worktree", "status." + key, earlier], in: root, environment: environment)
            try await assertControllersMatchGitStatus(in: root, environment: environment, badges: ["A", "A", "A", "D", "D", "D"])
        }
    }

    private func renameLimitRepository() throws -> URL {
        let root = try renameRepository()
        for index in 0..<3 {
            let text = (0..<20).map { "file \(index) line \($0)\n" }.joined()
            try text.write(to: root.appendingPathComponent("old-\(index).txt"), atomically: true, encoding: .utf8)
        }
        try git(["add", "."], in: root); try git(["commit", "-qm", "Rename limit baseline"], in: root)
        for index in 0..<3 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("old-\(index).txt"))
            let text = (0..<20).map { $0 < 5 ? "replacement \(index) \($0)\n" : "file \(index) line \($0)\n" }.joined()
            try text.write(to: root.appendingPathComponent("new-\(index).txt"), atomically: true, encoding: .utf8)
        }
        try git(["add", "."], in: root)
        return root
    }

    private func configurationScopes(in root: URL, scope: String, key: String, earlier: String, later: String) throws -> [String: String] {
        let global = root.appendingPathComponent(".git/fixture-global")
        try Data().write(to: global)
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
        if scope == "global/local" {
            try git(["config", "--global", key, earlier], in: root, environment: environment)
            try git(["config", "--local", key, later], in: root, environment: environment)
        } else {
            try git(["config", "extensions.worktreeConfig", "true"], in: root, environment: environment)
            try git(["config", "--local", key, earlier], in: root, environment: environment)
            try git(["config", "--worktree", key, later], in: root, environment: environment)
        }
        return environment
    }

    @MainActor private func assertControllersMatchGitStatus(in root: URL, environment: [String: String], statusOptions: [String] = [], badges: [String],
                                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        // Git 2.39 status uses the first diff.* fallback. Pass Git's effective
        // value explicitly when testing the requested last-value policy.
        let output = try git(statusOptions + ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"], in: root, environment: environment)
        let expected = GitService.parseStatus(Data(output.utf8)).entries
        XCTAssertEqual(expected.map(\.badge), badges, file: file, line: line)
        let service = GitService(environment: environment)
        let panel = GitController(roots: [root.path], service: service, summaryOnly: true)
        let changes = GitController(roots: [root.path], service: service)
        defer { panel.letGo(); changes.letGo() }
        panel.setShown(true); changes.setShown(true)
        try await wait { panel.statusRead && !panel.loading && changes.statusRead && !changes.loading && !changes.diffLoading }
        XCTAssertEqual(panel.status.entries, expected, "Panel grouping must match git status", file: file, line: line)
        XCTAssertEqual(changes.status.entries, expected, "Changes grouping must match git status", file: file, line: line)
        for entry in expected {
            changes.selection = .init(path: entry.path, staged: true)
            try await wait { !changes.diffLoading }
            let opened = try XCTUnwrap(changes.diff.first { $0.path == entry.path }, entry.path, file: file, line: line)
            XCTAssertEqual(panel.changeStats[entry.path], GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary),
                           entry.path + " must count the diff it opens", file: file, line: line)
        }
    }

    func testSummaryMatchesOpenedRowsWithRenameDetectionDisabled() async throws {
        for key in ["status.renames", "diff.renames"] {
            let root = try renameRepository()
            if key == "status.renames" { try git(["config", "diff.renames", "copies"], in: root) }
            try git(["config", key, "false"], in: root)
            try git(["mv", "same.txt", "moved.txt"], in: root)
            let status = try await Self.summaryService.status(in: root.path)
            XCTAssertEqual(status.entries.map(\.badge), ["A", "D"])
            try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: [
                "moved.txt": GitDiffStat(added: 20, removed: 0, binary: false),
                "same.txt": GitDiffStat(added: 0, removed: 20, binary: false)
            ])
        }
    }

    @MainActor func testSummaryMatchesOpenedRowsWithCopyDetection() async throws {
        for key in ["status.renames", "diff.renames"] {
            let root = try renameRepository()
            if key == "status.renames" { try git(["config", "diff.renames", "false"], in: root) }
            try git(["config", key, "copies"], in: root)
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.txt"), to: root.appendingPathComponent("copy.txt"))
            try (renameText + "copy addition\n").write(to: root.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
            try (renameText + "source addition\n").write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root)
            let status = try await Self.summaryService.status(in: root.path)
            XCTAssertEqual(status.entries.map(\.badge), ["C", "M"])
            try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: [
                "copy.txt": GitDiffStat(added: 1, removed: 0, binary: false),
                "same.txt": GitDiffStat(added: 1, removed: 0, binary: false)
            ])
            let strict = try await Self.summaryService.status(in: root.path, renameSimilarity: 90)
            XCTAssertEqual(strict.entries.map(\.badge), ["C", "M"])
            try await Self.assertSummaryMatchesOpenedRows(strict, in: root, expected: [
                "copy.txt": GitDiffStat(added: 1, removed: 0, binary: false),
                "same.txt": GitDiffStat(added: 1, removed: 0, binary: false)
            ])
            let controller = GitController(roots: [root.path], service: Self.summaryService)
            defer { controller.letGo() }
            controller.setShown(true)
            try await wait { controller.statusRead && !controller.loading && !controller.diffLoading }
            for entry in status.entries {
                controller.selection = .init(path: entry.path, staged: true)
                try await wait { !controller.diffLoading }
                XCTAssertEqual(controller.diff.map(\.path), [entry.path], "Only the selected copy or source belongs in this preview")
                XCTAssertEqual(controller.diff.first?.added, 1)
                XCTAssertEqual(controller.diff.first?.removed, 0)
            }
        }
    }

    func testSummaryMatchesOpenedRowsWithCustomRenameSimilarity() async throws {
        let root = try renameRepository()
        try git(["mv", "same.txt", "moved.txt"], in: root)
        let changed = (0..<20).map { $0 < 5 ? "replacement line \($0)\n" : "generated line \($0)\n" }.joined()
        try changed.write(to: root.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        // Ask Git for a stricter grouping than the default 50% similarity.
        let status = try await Self.summaryService.status(in: root.path, renameSimilarity: 90)
        XCTAssertEqual(status.entries.map(\.badge), ["A", "D"])
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: [
            "moved.txt": GitDiffStat(added: 20, removed: 0, binary: false),
            "same.txt": GitDiffStat(added: 0, removed: 20, binary: false)
        ])
        let lower = try await Self.summaryService.status(in: root.path, renameSimilarity: 60)
        XCTAssertEqual(lower.entries.map(\.badge), ["R"])
        try await Self.assertSummaryMatchesOpenedRows(lower, in: root, expected: ["moved.txt": GitDiffStat(added: 5, removed: 5, binary: false)])
    }

    func testSummaryKeepsStatusOptionsUntilRefresh() async throws {
        let root = try renameRepository()
        try git(["config", "status.renames", "false"], in: root)
        try git(["mv", "same.txt", "moved.txt"], in: root)
        let before = try await Self.summaryService.status(in: root.path)
        try git(["config", "status.renames", "true"], in: root)
        try await Self.assertSummaryMatchesOpenedRows(before, in: root, expected: [
            "moved.txt": GitDiffStat(added: 20, removed: 0, binary: false),
            "same.txt": GitDiffStat(added: 0, removed: 20, binary: false)
        ])
        let after = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(after.entries.map(\.badge), ["R"])
        try await Self.assertSummaryMatchesOpenedRows(after, in: root, expected: ["moved.txt": GitDiffStat(added: 0, removed: 0, binary: false)])
    }

    func testSummaryMatchesSubmoduleRowsAndIgnoreSettings() async throws {
        let root = try repository(), source = try repository()
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "module"], in: root)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Generated submodule"], in: root)
        let module = root.appendingPathComponent("module")
        try "generated\n".write(to: module.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        var status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.path), ["module"])
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: ["module": GitDiffStat(added: 1, removed: 1, binary: false)])
        try git(["config", "submodule.module.ignore", "all"], in: root)
        status = try await Self.summaryService.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty, "A configured worktree ignore remains effective")
        try git(["add", "."], in: module); try git(["commit", "-qm", "Advance generated submodule"], in: module)
        try git(["add", "module"], in: root)
        try git(["config", "diff.ignoreSubmodules", "all"], in: root)
        try git(["config", "diff.submodule", "log"], in: root)
        status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.path), ["module"], "Status still lists a manually staged gitlink")
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: ["module": GitDiffStat(added: 1, removed: 1, binary: false)])
    }

    func testSummaryAndPreviewIgnoreTextConverters() async throws {
        let root = try repository()
        try "same.txt diff=fixture\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try git(["add", ".gitattributes"], in: root); try git(["commit", "-qm", "Generated attributes"], in: root)
        try git(["config", "diff.fixture.textconv", "printf identical"], in: root)
        let status = try await Self.summaryService.status(in: root.path)
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: ["same.txt": GitDiffStat(added: 1, removed: 1, binary: false)])
    }

    private var renameText: String { (0..<20).map { "generated line \($0)\n" }.joined() }
    private func renameRepository() throws -> URL {
        let root = try repository()
        try renameText.write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Rename baseline"], in: root)
        return root
    }
    private static func assertSummaryMatchesOpenedRows(_ status: GitRepositoryStatus, in root: URL, expected: [String: GitDiffStat],
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let service = summaryService
        let stats = try await service.changeStats(in: root.path, status: status)
        XCTAssertEqual(Set(stats.keys), Set(expected.keys), file: file, line: line)
        for entry in status.entries {
            let files = try await service.diffFiles(in: root.path, paths: [entry.originalPath, entry.path].compactMap { $0 },
                staged: !entry.unstaged && entry.staged, untracked: entry.untracked, options: status.changeOptions)
            let opened = try XCTUnwrap(files.first { $0.path == entry.path }, entry.path, file: file, line: line)
            let counted = GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary)
            XCTAssertEqual(stats[entry.path], counted, entry.path + " must count the diff it opens", file: file, line: line)
            XCTAssertEqual(counted, expected[entry.path], entry.path, file: file, line: line)
        }
    }

    func testSummaryNeverKeepsDeletionCountsForUnreadableUntrackedReplacements() async throws {
        for replacement in ["symlink", "oversized", "removed after status", "readable"] {
            let root = try repository(), file = root.appendingPathComponent("same.txt")
            try git(["rm", "-f", "same.txt"], in: root)
            if replacement == "symlink" {
                let target = root.appendingPathComponent("target.txt")
                try "generated target\n".write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            } else if replacement == "oversized" {
                try Data(repeating: 10, count: (4 << 20) + 1).write(to: file)
            } else {
                try "replacement\nhas\nthree lines\n".write(to: file, atomically: true, encoding: .utf8)
            }
            let status = try await GitService.shared.status(in: root.path), entries = status.entries
            XCTAssertTrue(entries.contains { $0.path == "same.txt" && $0.staged })
            XCTAssertTrue(entries.contains { $0.path == "same.txt" && $0.untracked })
            if replacement == "removed after status" { try FileManager.default.removeItem(at: file) }
            let stats = try await GitService.shared.changeStats(in: root.path, status: status)
            if replacement == "readable" {
                XCTAssertEqual(stats["same.txt"]?.added, 3)
                XCTAssertEqual(stats["same.txt"]?.removed, 0)
            } else {
                XCTAssertNil(stats["same.txt"], replacement + " must not inherit the staged deletion's counts")
            }
        }
    }

    func testSummaryNeverFollowsAReplacedDirectoryOutsideTheRepository() async throws {
        let root = try repository(), outside = try repository()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("replaced"), withDestinationURL: outside)
        let status = GitService.parseStatus(Data("? replaced/same.txt\0".utf8))
        let stats = try await GitService.shared.changeStats(in: root.path, status: status)
        XCTAssertNil(stats["replaced/same.txt"], "A directory replaced after status was read must not escape the project")
    }

    @MainActor func testSummaryReadsCountsWithoutPatchesHistoryOrSelection() async throws {
        let root = try repository()
        try "new\nlast line".write(to: root.appendingPathComponent("new\nfile.txt"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.dat"))
        let controller = GitController(roots: [root.path], summaryOnly: true)
        defer { controller.letGo() }
        XCTAssertFalse(controller.statusRead)
        controller.setShown(true)
        try await wait { controller.statusRead && !controller.loading }
        XCTAssertEqual(controller.changeStats["same.txt"]?.added, 1)
        XCTAssertEqual(controller.changeStats["same.txt"]?.removed, 1)
        XCTAssertEqual(controller.changeStats["new\nfile.txt"]?.added, 2)
        XCTAssertEqual(controller.changeStats["binary.dat"]?.binary, true)
        XCTAssertNil(controller.selection); XCTAssertTrue(controller.diff.isEmpty); XCTAssertTrue(controller.commits.isEmpty)
        XCTAssertTrue(controller.branches.isEmpty); XCTAssertTrue(controller.stashes.isEmpty)
        XCTAssertTrue(controller.isWatching)
        controller.setShown(false)
        XCTAssertTrue(controller.suspended); XCTAssertFalse(controller.isWatching)
    }

    @MainActor func testSummaryCountsFollowTheDiffSideIncludingUnbornStagedAndRenamedFiles() async throws {
        let root = try repository()
        try git(["mv", "same.txt", "renamed.txt"], in: root)
        try git(["add", "renamed.txt"], in: root)
        let controller = GitController(roots: [root.path], summaryOnly: true)
        defer { controller.letGo() }
        controller.setShown(true)
        try await wait { controller.statusRead && !controller.loading }
        XCTAssertEqual(controller.changeStats["renamed.txt"]?.added, 1)
        try "changed\nmore\n".write(to: root.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
        await controller.refresh()
        XCTAssertTrue(controller.status.entries.first { $0.path == "renamed.txt" }?.unstaged == true)
        XCTAssertEqual(controller.changeStats["renamed.txt"]?.added, 1, "The row opens the working-tree side, not index plus worktree")
        XCTAssertEqual(controller.changeStats["renamed.txt"]?.removed, 0)
        let unborn = root.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        try git(["init", "-qb", "main"], in: unborn)
        try "first\n".write(to: unborn.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: unborn)
        controller.root = unborn.path
        try await wait { controller.repositoryRoot == unborn.path && !controller.loading }
        XCTAssertEqual(controller.changeStats.keys.sorted(), ["first.txt"])
        XCTAssertEqual(controller.changeStats["first.txt"]?.added, 1)
        XCTAssertTrue(controller.commits.isEmpty)
    }

    @MainActor func testHiddenOrSupersededSummaryCannotPublishOldCounts() async throws {
        let first = try repository(), second = try repository()
        try "one\ntwo\nthree\n".write(to: first.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [first.path, second.path], summaryOnly: true)
        defer { controller.letGo(); GitController.statusReadDelay = .zero }
        GitController.statusReadDelay = .milliseconds(200)
        controller.setShown(true)
        try await wait { controller.loading }
        controller.setShown(false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(controller.statusRead); XCTAssertTrue(controller.changeStats.isEmpty)
        controller.root = second.path; controller.setShown(true)
        try await wait { controller.repositoryRoot == second.path && !controller.loading }
        XCTAssertEqual(controller.changeStats["same.txt"]?.added, 1)
        XCTAssertEqual(controller.changeStats["same.txt"]?.removed, 1)
        XCTAssertTrue(controller.diff.isEmpty); XCTAssertTrue(controller.commits.isEmpty)
    }

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
    @discardableResult private func git(_ arguments: [String], in root: URL, environment: [String: String]? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = environment ?? ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
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
