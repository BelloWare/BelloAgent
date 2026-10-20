import Combine
import XCTest
@testable import GitView

final class GitRepositoryStateTests: XCTestCase {
    private static let summaryService = GitService(environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    @MainActor func testSummaryAndChangesMatchRawStatusAcrossRenameScopes() async throws {
        for scope in ["global/local", "local/worktree"] {
            let root = try renameRepository()
            try Self.git(["mv", "same.txt", "moved.txt"], in: root)
            let environment = try configurationScopes(in: root, scope: scope, key: "diff.renames", earlier: "true", later: "false")
            let effective = try Self.git(["config", "--get", "diff.renames"], in: root, environment: environment).trimmingCharacters(in: .newlines)
            XCTAssertEqual(effective, "false")
            try await assertControllersMatchGitStatus(in: root, environment: environment)
        }
    }

    @MainActor func testSummaryAndChangesMatchRawStatusAcrossRenameLimitScopes() async throws {
        for scope in ["global/local", "local/worktree"] {
            for limits in [("1", "1000"), ("1000", "1")] {
                let root = try renameLimitRepository()
                let environment = try configurationScopes(in: root, scope: scope, key: "diff.renameLimit", earlier: limits.0, later: limits.1)
                let effective = try Self.git(["config", "--get", "diff.renameLimit"], in: root, environment: environment).trimmingCharacters(in: .newlines)
                XCTAssertEqual(effective, limits.1)
                try await assertControllersMatchGitStatus(in: root, environment: environment)
            }
        }
    }

    @MainActor func testSummaryAndChangesUseIncludedRenameConfiguration() async throws {
        let root = try renameRepository()
        try (renameText + "copy addition\n").write(to: root.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
        try (renameText + "source addition\n").write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root)
        let environment = try configurationScopes(in: root, scope: "global/local", key: "diff.renames", earlier: "true", later: "false")
        let included = root.appendingPathComponent(".git/fixture-included")
        try "[diff]\nrenames = copies\n".write(to: included, atomically: true, encoding: .utf8)
        try Self.git(["config", "includeIf.onbranch:main.path", included.path], in: root, environment: environment)
        let effective = try Self.git(["config", "--get", "diff.renames"], in: root, environment: environment).trimmingCharacters(in: .newlines)
        XCTAssertEqual(effective, "copies")
        try await assertControllersMatchGitStatus(in: root, environment: environment)
    }

    @MainActor func testSummaryAndChangesKeepStatusOverridesAcrossScopes() async throws {
        for key in ["renames", "renameLimit"] {
            let root = try renameLimitRepository()
            let earlier = key == "renames" ? "false" : "1", later = key == "renames" ? "true" : "1000"
            let environment = try configurationScopes(in: root, scope: "global/local", key: "status." + key, earlier: earlier, later: later)
            try Self.git(["config", "extensions.worktreeConfig", "true"], in: root, environment: environment)
            try Self.git(["config", "--worktree", "diff." + key, earlier], in: root, environment: environment)
            // Status's explicit option wins even over a later diff fallback.
            try await assertControllersMatchGitStatus(in: root, environment: environment, badges: ["R", "R", "R"])
            try Self.git(["config", "--worktree", "status." + key, earlier], in: root, environment: environment)
            try await assertControllersMatchGitStatus(in: root, environment: environment, badges: ["A", "A", "A", "D", "D", "D"])
        }
    }

    private func renameLimitRepository() throws -> URL {
        let root = try renameRepository()
        for index in 0..<3 {
            let text = (0..<20).map { "file \(index) line \($0)\n" }.joined()
            try text.write(to: root.appendingPathComponent("old-\(index).txt"), atomically: true, encoding: .utf8)
        }
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Rename limit baseline"], in: root)
        for index in 0..<3 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("old-\(index).txt"))
            let text = (0..<20).map { $0 < 5 ? "replacement \(index) \($0)\n" : "file \(index) line \($0)\n" }.joined()
            try text.write(to: root.appendingPathComponent("new-\(index).txt"), atomically: true, encoding: .utf8)
        }
        try Self.git(["add", "."], in: root)
        return root
    }

    private func configurationScopes(in root: URL, scope: String, key: String, earlier: String, later: String) throws -> [String: String] {
        let global = root.appendingPathComponent(".git/fixture-global")
        try Data().write(to: global)
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
        if scope == "global/local" {
            try Self.git(["config", "--global", key, earlier], in: root, environment: environment)
            try Self.git(["config", "--local", key, later], in: root, environment: environment)
        } else {
            try Self.git(["config", "extensions.worktreeConfig", "true"], in: root, environment: environment)
            try Self.git(["config", "--local", key, earlier], in: root, environment: environment)
            try Self.git(["config", "--worktree", key, later], in: root, environment: environment)
        }
        return environment
    }

    @MainActor private func assertControllersMatchGitStatus(in root: URL, environment: [String: String], badges: [String]? = nil,
                                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        // The installed Git owns config precedence, including its status quirks.
        let output = try Self.git(["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"], in: root, environment: environment)
        let expected = GitService.parseStatus(Data(output.utf8)).entries
        if let badges { XCTAssertEqual(expected.map(\.badge), badges, file: file, line: line) }
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
            XCTAssertEqual(panel.changeStats[entry.path], try Self.gitCounts(entry, in: root, environment: environment), file: file, line: line)
            XCTAssertEqual(panel.changeStats[entry.path], GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary),
                           entry.path + " must count the diff it opens", file: file, line: line)
        }
    }

    func testSummaryMatchesOpenedRowsWithRenameDetectionDisabled() async throws {
        for key in ["status.renames", "diff.renames"] {
            let root = try renameRepository()
            if key == "status.renames" { try Self.git(["config", "diff.renames", "copies"], in: root) }
            try Self.git(["config", key, "false"], in: root)
            try Self.git(["mv", "same.txt", "moved.txt"], in: root)
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
            if key == "status.renames" { try Self.git(["config", "diff.renames", "false"], in: root) }
            try Self.git(["config", key, "copies"], in: root)
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.txt"), to: root.appendingPathComponent("copy.txt"))
            try (renameText + "copy addition\n").write(to: root.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
            try (renameText + "source addition\n").write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            try Self.git(["add", "."], in: root)
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
        try Self.git(["mv", "same.txt", "moved.txt"], in: root)
        let changed = (0..<20).map { $0 < 5 ? "replacement line \($0)\n" : "generated line \($0)\n" }.joined()
        try changed.write(to: root.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root)
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

    func testSummaryKeepsReportedGroupingUntilRefresh() async throws {
        let root = try renameRepository()
        try Self.git(["config", "status.renames", "false"], in: root)
        try Self.git(["mv", "same.txt", "moved.txt"], in: root)
        let before = try await Self.summaryService.status(in: root.path)
        try Self.git(["config", "status.renames", "true"], in: root)
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
        try Self.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "module"], in: root)
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Generated submodule"], in: root)
        let module = root.appendingPathComponent("module")
        try "generated\n".write(to: module.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        var status = try await Self.summaryService.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty, "Background reads do not inspect a child repository's worktree")
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: [:])
        try Self.git(["config", "submodule.module.ignore", "all"], in: root)
        status = try await Self.summaryService.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty, "A configured worktree ignore remains effective")
        try Self.git(["add", "."], in: module); try Self.git(["commit", "-qm", "Advance generated submodule"], in: module)
        try Self.git(["add", "module"], in: root)
        try Self.git(["config", "diff.ignoreSubmodules", "all"], in: root)
        try Self.git(["config", "diff.submodule", "log"], in: root)
        status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.path), ["module"], "Status still lists a manually staged gitlink")
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: ["module": GitDiffStat(added: 1, removed: 1, binary: false)])
    }

    func testSummaryAndPreviewIgnoreTextConverters() async throws {
        let root = try repository()
        try "same.txt diff=fixture\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try Self.git(["add", ".gitattributes"], in: root); try Self.git(["commit", "-qm", "Generated attributes"], in: root)
        try Self.git(["config", "diff.fixture.textconv", "printf identical"], in: root)
        let status = try await Self.summaryService.status(in: root.path)
        try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: ["same.txt": GitDiffStat(added: 1, removed: 1, binary: false)])
    }

    func testSummaryUsesGitBinaryProbeAndConfiguredSizeThreshold() async throws {
        let root = try repository()
        try Self.git(["restore", "same.txt"], in: root)
        let lateNUL = Data((String(repeating: "a\n", count: 4_500) + "\0\n").utf8)
        try lateNUL.write(to: root.appendingPathComponent("late-nul.txt"))
        try Data([0, 10, 1, 10]).write(to: root.appendingPathComponent("early-nul.bin"))
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        try "no final newline".write(to: root.appendingPathComponent("tail.txt"), atomically: true, encoding: .utf8)
        for threshold in ["512m", "1k"] {
            try Self.git(["config", "core.bigFileThreshold", threshold], in: root)
            let status = try await Self.summaryService.status(in: root.path)
            let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
            for entry in status.entries {
                XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), threshold + " " + entry.path)
            }
            XCTAssertEqual(counts["late-nul.txt"], threshold == "1k"
                ? GitDiffStat(added: 0, removed: 0, binary: true) : GitDiffStat(added: 4_501, removed: 0, binary: false))
        }
    }

    func testSummaryUsesGitAttributesForUntrackedFiles() async throws {
        let root = try repository()
        try Self.git(["restore", "same.txt"], in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        try "/plain.txt -diff\n/nested/forced.txt diff\ninvalid.txt invalid:attribute\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "*.txt diff=fixture\n".write(to: root.appendingPathComponent("nested/deeper/.gitattributes"), atomically: true, encoding: .utf8)
        try "/nested/deeper/override.txt diff\n".write(to: root.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        try Self.git(["config", "diff.fixture.binary", "true"], in: root)
        try Self.git(["add", ".gitattributes", "nested/deeper/.gitattributes"], in: root)
        try Self.git(["commit", "-qm", "Generated attributes"], in: root)
        for path in ["plain.txt", "nested/deeper/plain.txt"] {
            try "ordinary text\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        for path in ["nested/forced.txt", "nested/deeper/override.txt"] {
            try Data([0, 10, 1, 10]).write(to: root.appendingPathComponent(path))
        }
        let status = try await Self.summaryService.status(in: root.path)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        for entry in status.entries { XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), entry.path) }
    }

    func testSummaryCountsEachReportedSideIncludingRenameWithWorktreeEdits() async throws {
        let root = try renameRepository()
        try Self.git(["mv", "same.txt", "moved.txt"], in: root)
        try (renameText + "worktree addition\n").write(to: root.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        try "staged\n".write(to: root.appendingPathComponent("both.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "both.txt"], in: root)
        try "worktree\nmore\n".write(to: root.appendingPathComponent("both.txt"), atomically: true, encoding: .utf8)
        let status = try await Self.summaryService.status(in: root.path)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        for entry in status.entries { XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), entry.path) }
        XCTAssertEqual(counts["moved.txt"], GitDiffStat(added: 1, removed: 0, binary: false))
        XCTAssertEqual(counts["both.txt"], GitDiffStat(added: 2, removed: 1, binary: false))
    }

    func testSummaryKeepsGitCountsForLargeTrackedFilesAndOmitsUnsafeUntrackedFiles() async throws {
        let root = try repository()
        let bytes = Data((String(repeating: "a", count: (4 << 20) + 1) + "\n").utf8)
        try bytes.write(to: root.appendingPathComponent("tracked.txt"))
        try Self.git(["add", "tracked.txt"], in: root)
        try bytes.write(to: root.appendingPathComponent("oversized.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: "tracked.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tracked-link").path, withDestinationPath: "same.txt")
        try Self.git(["add", "tracked-link"], in: root)
        let status = try await Self.summaryService.status(in: root.path)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        for entry in status.entries where !entry.untracked { XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), entry.path) }
        XCTAssertNil(counts["oversized.txt"]); XCTAssertNil(counts["link.txt"])
    }

    func testSummaryDoesNotInventCountsWhenAttributesExceedTheSafeReadLimit() async throws {
        let root = try repository()
        let attributes = String(repeating: "# generated comment\n", count: 230_000) + "/plain.txt -diff\n"
        try attributes.write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "plain text\n".write(to: root.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        let status = try await Self.summaryService.status(in: root.path)
        let entry = try XCTUnwrap(status.entries.first { $0.path == "plain.txt" })
        XCTAssertEqual(try Self.gitCounts(entry, in: root)?.binary, true)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        XCTAssertNil(counts["plain.txt"], "Unavailable attributes must not silently change Git's classification")
    }

    func testSummaryChecksBothPathsBeforeUsingBatchedRenameCounts() async throws {
        let root = try renameRepository()
        let first = (0..<20).map { "shared line \($0)\n" }.joined()
        let second = (0..<20).map { $0 < 5 ? "different line \($0)\n" : "shared line \($0)\n" }.joined()
        try first.write(to: root.appendingPathComponent("old-a.txt"), atomically: true, encoding: .utf8)
        try second.write(to: root.appendingPathComponent("old-b.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Generated rename sources"], in: root)
        try Self.git(["mv", "old-a.txt", "new-a.txt"], in: root)
        try Self.git(["mv", "old-b.txt", "new-b.txt"], in: root)
        let status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.badge), ["R", "R"])
        // The reader still has that snapshot when an editor swaps destinations.
        try second.write(to: root.appendingPathComponent("new-a.txt"), atomically: true, encoding: .utf8)
        try first.write(to: root.appendingPathComponent("new-b.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        for entry in status.entries { XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), entry.path) }
        XCTAssertEqual(counts["new-a.txt"], GitDiffStat(added: 5, removed: 5, binary: false))
        XCTAssertEqual(counts["new-b.txt"], GitDiffStat(added: 5, removed: 5, binary: false))
    }

    func testSummaryKeepsDirectoryRenamePairsInBoundedRequests() async throws {
        let (root, expected) = try pairedRepository(mixed: false)
        let status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.count, 512)
        XCTAssertTrue(status.entries.allSatisfy { $0.indexState == "R" })
        try await assertBoundedPairCounts(status, in: root, expected: expected, maximum: 4)
    }

    func testPairedCountBatchesKeepGroupsAcrossCountAndByteLimits() {
        let shared = (0..<512).map { ["source", "destination-\($0)"] }
        let batches = GitService.pairedBatches(of: shared, prefix: ["diff", "--"])
        XCTAssertEqual(batches.map(\.count), [512, 2])
        XCTAssertTrue(batches.allSatisfy { $0.contains("source") && Set($0).count == $0.count })
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(shared.flatMap { $0 }))

        let long = String(repeating: "界", count: 15_000)
        let pairs = [["first", "second"], [long + "a", long + "b"], [long + "c", long + "d"]]
        XCTAssertTrue(GitService.pairedBatches(of: pairs, prefix: ["diff", "--"]) == [pairs[0] + pairs[1], pairs[2]],
            "The byte budget must count UTF-8 bytes, keeping both paths together")
        let oversized = [long + long + "a", long + long + "b"]
        XCTAssertTrue(GitService.pairedBatches(of: [pairs[0], oversized, pairs[0]], prefix: ["diff", "--"]) ==
            [pairs[0], oversized, pairs[0]], "An oversized group must make progress without being split")
        XCTAssertEqual(GitService.pairedBatches(of: [["source", "source"]], prefix: []), [["source"]])
    }

    func testSummaryBatchesMixedRenamesCopiesAndModifications() async throws {
        let (root, expected) = try pairedRepository(mixed: true)
        let status = try await Self.summaryService.status(in: root.path)
        XCTAssertEqual(status.entries.filter { $0.indexState == "R" }.count, 260)
        XCTAssertEqual(status.entries.filter { $0.indexState == "C" }.count, 260)
        XCTAssertEqual(status.entries.filter { $0.indexState == "M" }.count, 132)
        XCTAssertEqual(status.entries.filter(\.unstaged).count, 2)
        try await assertBoundedPairCounts(status, in: root, expected: expected, maximum: 4)
    }

    private func pairedRepository(mixed: Bool) throws -> (URL, [String: GitDiffStat]) {
        let root = try repository(), fm = FileManager.default
        try Self.git(["restore", "same.txt"], in: root)
        for folder in ["source", "copies"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let renames = mixed ? 260 : 512, sources = mixed ? 130 : 0
        func text(_ kind: String, _ index: Int) -> String {
            (0..<20).map { "\(kind)-\(index)-unique-line-\($0)\n" }.joined()
        }
        func write(_ path: String, _ value: String) throws {
            try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        for index in 0..<renames { try write("source/\(index).txt", text("rename", index)) }
        for index in 0..<sources { try write("copies/\(index).txt", text("copy", index)) }
        if mixed {
            for path in ["staged.txt", "working.txt", "both.txt"] { try write(path, "base\n") }
        }
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Generated pair sources"], in: root)
        try fm.moveItem(at: root.appendingPathComponent("source"), to: root.appendingPathComponent("destination"))
        var expected: [String: GitDiffStat] = [:]
        for index in 0..<renames {
            let count = mixed ? index % 3 + 1 : 0, path = "destination/\(index).txt"
            try write(path, text("rename", index) + String(repeating: "added\n", count: count))
            expected[path] = GitDiffStat(added: count, removed: 0, binary: false)
        }
        for index in 0..<sources {
            let source = "copies/\(index).txt"
            try write(source, text("copy", index) + "source addition\n")
            expected[source] = GitDiffStat(added: 1, removed: 0, binary: false)
            for count in 1...2 {
                let path = "destination/copy-\(index)-\(count).txt"
                try write(path, text("copy", index) + String(repeating: "copy addition\n", count: count))
                expected[path] = GitDiffStat(added: count, removed: 0, binary: false)
            }
        }
        if mixed {
            try Self.git(["config", "status.renames", "copies"], in: root)
            for path in ["staged.txt", "both.txt"] { try write(path, "staged\n") }
            expected["staged.txt"] = GitDiffStat(added: 1, removed: 1, binary: false)
        }
        try Self.git(["add", "."], in: root)
        if mixed {
            try write("working.txt", "working\n")
            try write("both.txt", "staged\nworking\n")
            expected["working.txt"] = GitDiffStat(added: 1, removed: 1, binary: false)
            expected["both.txt"] = GitDiffStat(added: 1, removed: 0, binary: false)
        }
        return (root, expected)
    }

    private func assertBoundedPairCounts(_ status: GitRepositoryStatus, in root: URL, expected: [String: GitDiffStat],
                                         maximum: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let trace = root.appendingPathComponent(".git/count-trace.json")
        // This generated repository is trusted so the measured commands can
        // write their fixture trace; untrusted readers cannot write here.
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TRACE2_EVENT": trace.path], trusted: true)
        let counts = try await service.changeStats(in: root.path, status: status)
        let events = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let commands = events.compactMap { $0?["event"] as? String == "start" ? $0?["argv"] as? [String] : nil }
        print("Paired summary: \(status.entries.count) rows, \(commands.count) Git invocations")
        XCTAssertFalse(commands.isEmpty, "Git must record real invocations", file: file, line: line)
        XCTAssertLessThanOrEqual(commands.count, maximum, "Summary Git invocations: \(commands.count)", file: file, line: line)
        for command in commands where command.contains("--") {
            let paths = Array(command.dropFirst(try XCTUnwrap(command.firstIndex(of: "--")) + 1))
            XCTAssertEqual(paths.count, Set(paths).count, "Repeated copy sources waste the batch budget", file: file, line: line)
        }
        XCTAssertEqual(counts, expected, file: file, line: line)
        for entry in status.entries {
            XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root),
                entry.path + " must match the diff that row opens", file: file, line: line)
        }
    }

    func testSummarySplitsBoundedSnapshotsWithoutLosingUntrackedCounts() async throws {
        let root = try repository()
        try Self.git(["restore", "same.txt"], in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"), withIntermediateDirectories: true)
        let bytes = Data(repeating: 65, count: 4 << 20)
        for index in 0..<9 { try bytes.write(to: root.appendingPathComponent("new/file-\(index).txt")) }
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("bello-counts-") })
        let status = try await Self.summaryService.status(in: root.path)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        XCTAssertEqual(counts.count, 9)
        for entry in status.entries { XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root), entry.path) }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("bello-counts-") })
        XCTAssertEqual(after, before, "Private snapshots must be removed after each read")
    }

    func testSummarySplitsCaseCollisionsOnACaseSensitiveVolume() async throws {
        let volume = try caseSensitiveVolume()
        let cases: [(String, [(String, Int)])] = [
            ("files", [("A.txt", 1), ("a.txt", 3)]),
            ("directories", [("Dir/x.txt", 2), ("dir/x.txt", 5)]),
            ("parents", [("Tree/one.txt", 4), ("tree/two.txt", 6)]),
            ("file-directory", [("Node", 9), ("node/x.txt", 10)]),
            ("directory-file", [("Folder/x.txt", 11), ("folder", 12)])
        ]
        for (name, files) in cases {
            let root = volume.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Self.git(["init", "-qb", "main"], in: root)
            try Self.git(["commit", "--allow-empty", "-qm", "Case-sensitive fixture"], in: root)
            let fixtures = files + [("shared/one.txt", 7), ("shared/two.txt", 8)]
            for (path, lines) in fixtures {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try String(repeating: "generated\n", count: lines).write(to: url, atomically: true, encoding: .utf8)
            }
            if name == "parents" {
                try "*.txt -diff\n".write(to: root.appendingPathComponent("Tree/.gitattributes"), atomically: true, encoding: .utf8)
                try "*.txt diff\n".write(to: root.appendingPathComponent("tree/.gitattributes"), atomically: true, encoding: .utf8)
                try Self.git(["add", "Tree/.gitattributes", "tree/.gitattributes"], in: root)
                try Self.git(["commit", "-qm", "Distinct directory attributes"], in: root)
            }
            let status = try await Self.summaryService.status(in: root.path)
            XCTAssertEqual(Set(status.entries.map(\.path)), Set(fixtures.map(\.0)), name)
            var expected = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.0, GitDiffStat(added: $0.1, removed: 0, binary: false)) })
            if name == "parents" { expected["Tree/one.txt"] = GitDiffStat(added: 0, removed: 0, binary: true) }
            do { try await Self.assertSummaryMatchesOpenedRows(status, in: root, expected: expected) }
            catch { XCTFail("\(name): \(error)") }
        }
    }

    func testSummaryOmitsNormalizationAliasesThatCannotHaveDistinctCountKeys() async throws {
        let root = try repository()
        let composed = "caf\u{e9}.txt", decomposed = "cafe\u{301}.txt"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        try "generated\nsecond\n".write(to: root.appendingPathComponent(composed), atomically: true, encoding: .utf8)
        var status = try await Self.summaryService.status(in: root.path)
        // APFS cannot store both spellings. Inject the status a normalization-
        // sensitive source would report; String-keyed counts cannot separate it.
        status.entries.removeAll { $0.path == composed }
        status.entries += [composed, decomposed].map {
            GitStatusEntry(path: $0, originalPath: nil, indexState: "?", worktreeState: "?", untracked: true)
        }
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        XCTAssertNil(counts[composed])
        XCTAssertNil(counts[decomposed])
        XCTAssertEqual(counts["same.txt"], GitDiffStat(added: 1, removed: 1, binary: false))
    }

    func testSummaryDoesNotOverwriteAnAttributeFileAlias() async throws {
        let root = try caseSensitiveVolume()
        try Self.git(["init", "-qb", "main"], in: root)
        let folder = root.appendingPathComponent("attributes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "*.txt -diff\n".write(to: folder.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Attributes"], in: root)
        try "generated\nsecond\nthird\n".write(to: folder.appendingPathComponent(".GITATTRIBUTES"), atomically: true, encoding: .utf8)
        try "ordinary\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let status = try await Self.summaryService.status(in: root.path)
        let counts = try await Self.summaryService.changeStats(in: root.path, status: status)
        // Both files cannot coexist in the insensitive private tree. Refuse
        // affected counts rather than replacing the untracked file's contents.
        let sensitive = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        XCTAssertEqual(counts["attributes/.GITATTRIBUTES"], sensitive ? GitDiffStat(added: 3, removed: 0, binary: false) : nil)
        XCTAssertEqual(counts["new.txt"], try Self.gitCounts(try XCTUnwrap(status.entries.first { $0.path == "new.txt" }), in: root))
    }

    private func caseSensitiveVolume() throws -> URL {
        let base = ProcessInfo.processInfo.environment["PI_BUILD_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("git-counts-volume-" + UUID().uuidString)
        let image = folder.appendingPathComponent("fixture.dmg"), mount = folder.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        do {
            try Self.diskImage(["create", "-size", "64m", "-fs", "Case-sensitive APFS", "-volname", "BelloCountsFixture", image.path])
            try Self.diskImage(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        addTeardownBlock {
            try Self.diskImage(["detach", mount.path])
            try FileManager.default.removeItem(at: folder)
        }
        return mount
    }

    private static func diskImage(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailure(message: "hdiutil \(arguments.first ?? ""): " + String(decoding: data, as: UTF8.self))
        }
    }

    func testSummaryKeepsRelativeConfiguredAttributesAtTheOriginalRoot() async throws {
        for scope in ["global/local", "local/worktree"] {
            let root = try repository()
            try Self.git(["restore", "same.txt"], in: root)
            let earlier = root.appendingPathComponent(".git/earlier-attributes")
            try "/new.txt diff\n".write(to: earlier, atomically: true, encoding: .utf8)
            try "/new.txt -diff\n".write(to: root.appendingPathComponent(".git/later-attributes"), atomically: true, encoding: .utf8)
            let environment = try configurationScopes(in: root, scope: scope, key: "core.attributesFile", earlier: earlier.path, later: ".git/later-attributes")
            try "ordinary text\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            let service = GitService(environment: environment)
            let status = try await service.status(in: root.path)
            let counts = try await service.changeStats(in: root.path, status: status)
            let entry = try XCTUnwrap(status.entries.first)
            let expected = try Self.gitCounts(entry, in: root, environment: environment)
            XCTAssertEqual(expected?.binary, true)
            XCTAssertEqual(counts[entry.path], expected, scope)
        }
    }

    func testSummaryIgnoresRelativeOrderingWhilePreservingAttributesAndPreviewCounts() async throws {
        for scope in ["global/local", "local/worktree"] {
            let root = try repository()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
            try "nested/*\n*.txt\n".write(to: root.appendingPathComponent(".git/order"), atomically: true, encoding: .utf8)
            let environment = try configurationScopes(in: root, scope: scope, key: "diff.orderFile",
                earlier: "/dev/null", later: ".git/order")
            try "*.txt diff=fixture\n/nested/binary.txt -diff\n".write(to: root.appendingPathComponent(".git/attributes"), atomically: true, encoding: .utf8)
            for (key, value) in [("core.attributesFile", ".git/attributes"), ("diff.external", "missing-relative-driver"),
                                 ("diff.fixture.command", "missing-relative-driver"), ("diff.fixture.textconv", "missing-relative-converter"),
                                 ("diff.relative", "true")] {
                try Self.git(["config", key, value], in: root, environment: environment)
            }
            for path in ["new.txt", "nested/new.txt", "nested/binary.txt", "staged.txt"] {
                try "generated\nsecond line\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try Self.git(["add", "staged.txt"], in: root, environment: environment)
            let service = GitService(environment: environment)
            let status = try await service.status(in: root.path)
            let counts = try await service.changeStats(in: root.path, status: status)
            for entry in status.entries {
                XCTAssertEqual(counts[entry.path], try Self.gitCounts(entry, in: root, environment: environment), scope + " " + entry.path)
                let preview = try await service.diffFiles(in: root.path, paths: [entry.path], staged: !entry.unstaged && entry.staged,
                    untracked: entry.untracked, entry: entry)
                XCTAssertEqual(counts[entry.path], preview.first.map { GitDiffStat(added: $0.added, removed: $0.removed, binary: $0.binary) })
            }
        }
    }

    @MainActor func testSummaryCountFailureClearsOldCountsAndReportsUnavailable() async throws {
        let root = try repository()
        let controller = GitController(roots: [root.path], service: Self.summaryService, summaryOnly: true)
        defer { controller.letGo() }
        controller.setShown(true)
        try await wait { !controller.loading && controller.changeStats["same.txt"] != nil }
        controller.statusDidRead = {
            controller.statusDidRead = nil
            try Self.git(["config", "diff.algorithm", "invalid-fixture-algorithm"], in: root)
        }
        await controller.refresh()
        XCTAssertFalse(controller.status.entries.isEmpty)
        XCTAssertTrue(controller.changeStats.isEmpty, "Failed counts cannot retain the previous refresh's numbers")
        XCTAssertTrue(controller.notice.hasPrefix("Counts unavailable"), controller.notice)
        try Self.git(["config", "--unset", "diff.algorithm"], in: root)
        await controller.refresh(automatic: true)
        try await wait { controller.changeStats["same.txt"] != nil }
        XCTAssertEqual(controller.changeStats["same.txt"], GitDiffStat(added: 1, removed: 1, binary: false))
        XCTAssertEqual(controller.notice, "")
    }

    private static func gitCounts(_ entry: GitStatusEntry, in root: URL, environment: [String: String]? = nil) throws -> GitDiffStat? {
        let staged = !entry.unstaged && entry.staged
        let state = staged ? entry.indexState : entry.worktreeState
        var arguments = ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--submodule=short", "--ita-invisible-in-index"]
        arguments += [staged ? "--ignore-submodules=dirty" : "--ignore-submodules=none"]
        if staged { arguments += ["--cached"] }
        if entry.untracked { arguments += ["--no-index", "--", "/dev/null", entry.path] }
        else if let original = entry.originalPath, state == "R" || state == "C" {
            arguments += [state == "C" ? "--find-copies=1%" : "--find-renames=1%", "--", ":(literal)" + original, ":(literal)" + entry.path]
        } else { arguments += ["--no-renames", "--", ":(literal)" + entry.path] }
        let output = try Self.git(arguments, in: root, environment: environment, allowed: entry.untracked ? 1 : 0)
        return GitService.parseNumstat(Data(output.utf8))[entry.path]
    }

    private var renameText: String { (0..<20).map { "generated line \($0)\n" }.joined() }
    private func renameRepository() throws -> URL {
        let root = try repository()
        try renameText.write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Rename baseline"], in: root)
        return root
    }
    private static func assertSummaryMatchesOpenedRows(_ status: GitRepositoryStatus, in root: URL, expected: [String: GitDiffStat],
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let service = Self.summaryService
        let stats = try await service.changeStats(in: root.path, status: status)
        XCTAssertEqual(Set(stats.keys), Set(expected.keys), file: file, line: line)
        for entry in status.entries {
            let files = try await service.diffFiles(in: root.path, paths: status.changeOptions.paths(for: entry, staged: !entry.unstaged && entry.staged),
                staged: !entry.unstaged && entry.staged, untracked: entry.untracked, options: status.changeOptions, entry: entry)
            let opened = try XCTUnwrap(files.first { $0.path == entry.path }, entry.path, file: file, line: line)
            XCTAssertEqual(stats[entry.path], try Self.gitCounts(entry, in: root), entry.path + " must count Git's diff", file: file, line: line)
            XCTAssertEqual(stats[entry.path], expected[entry.path], entry.path, file: file, line: line)
            XCTAssertEqual(opened.binary, expected[entry.path]?.binary, file: file, line: line)
            if entry.untracked {
                XCTAssertEqual(GitDiffStat(added: opened.added, removed: opened.removed, binary: opened.binary),
                    expected[entry.path], entry.path + " must count the opened preview", file: file, line: line)
            }
        }
    }

    func testSummaryNeverKeepsDeletionCountsForUnreadableUntrackedReplacements() async throws {
        for replacement in ["symlink", "oversized", "removed after status", "readable"] {
            let root = try repository(), file = root.appendingPathComponent("same.txt")
            try Self.git(["rm", "-f", "same.txt"], in: root)
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
        try Self.git(["mv", "same.txt", "renamed.txt"], in: root)
        try Self.git(["add", "renamed.txt"], in: root)
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
        try Self.git(["init", "-qb", "main"], in: unborn)
        try "first\n".write(to: unborn.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: unborn)
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
        try Self.git(["init", "-qb", "main"], in: root)
        try Self.git(["config", "core.hooksPath", "/dev/null"], in: root)
        try "base\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Initial"], in: root)
        try "changed\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: try Self.git(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @discardableResult private static func git(_ arguments: [String], in root: URL, environment: [String: String]? = nil, allowed: Int32 = 0) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = environment ?? ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertLessThanOrEqual(process.terminationStatus, allowed)
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
        XCTAssertEqual(try Self.git(["diff", "--cached", "--name-only"], in: second), "")
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
                try Self.git(["reset", "--mixed", "HEAD"], in: second)
            } else { XCTAssertEqual(controller.repositoryRoot, second.path) }
            await controller.discard(snapshot.status.entries, context: context)
            XCTAssertEqual(try Self.git(["diff", "--cached", "--name-only"], in: first), "")
            XCTAssertEqual(try Self.git(["diff", "--cached", "--name-only"], in: second), "")
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
        try Self.git(["add", "."], in: root); try Self.git(["commit", "-qm", "Large patch"], in: root)
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
        try Self.git(["mv", "same.txt", "other.txt"], in: second)
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
        try Self.git(["worktree", "add", "-qb", "other", other.path], in: root)
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
        try Self.git(["worktree", "add", "-qb", "other", other.path], in: root)
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
