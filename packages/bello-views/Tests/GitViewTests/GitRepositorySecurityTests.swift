import XCTest
@testable import GitView

/// Every executable is a generated marker writer. Nothing contacts a remote.
final class GitRepositorySecurityTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String] { ["PATH": "/usr/bin:/bin", "HOME": root.path,
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"] }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-programs-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"])
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            try git(["config", key, value])
        }
        try write("file.txt", "base\n"); try write("plain.txt", "plain\n")
        try git(["add", "."]); try git(["commit", "-qm", "Base"])
        try git(["branch", "other"])
        try write("file.txt", "stashed\n"); try git(["stash", "push", "-qm", "Fixture"])
        try write("file.txt", "indexed\n"); try git(["add", "file.txt"])
        try write("file.txt", "working\n"); try write("plain.txt", "changed plain\n"); try write("new.txt", "new\n")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = root
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.environment = environment; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Fixture: \(arguments)")
        return String(decoding: bytes, as: UTF8.self)
    }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    private func program(_ name: String, tail: String = "cat") throws -> String {
        let path = root.appendingPathComponent(".git/" + name)
        try Data("#!/bin/sh\nprintf '%s\\n' '\(name)' >> '\(root.path)/ran'\n\(tail)\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }
    private func assertNoProgram(_ operation: String, file: StaticString = #filePath, line: UInt = #line) {
        let marker = root.appendingPathComponent("ran")
        let ran = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(operation) executed: \(ran)", file: file, line: line)
        try? FileManager.default.removeItem(at: marker)
    }

    func testReadOnlyQueriesNeverRunRepositoryPrograms() async throws {
        let service = GitService(environment: environment), path = root.path
        let commits = try await service.log(in: path)
        let commit = try XCTUnwrap(commits.first)
        let monitor = try program("monitor", tail: "printf 'token\\000'")
        let driver = try program("driver", tail: "printf 'converted\\n'")
        let filter = try program("filter")
        let hooks = root.appendingPathComponent(".git/hostile-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "post-checkout", "post-merge", "post-rewrite", "post-index-change", "reference-transaction", "pre-push"] {
            let source = try program(name, tail: "exit 0")
            try FileManager.default.copyItem(atPath: source, toPath: hooks.appendingPathComponent(name).path)
        }
        // Drivers arrived through includeIf -> include, not just .git/config.
        try write(".git/included", "[core]\nfsmonitor = \(monitor)\nhooksPath = \(hooks.path)\nsshCommand = \(driver)\npager = \(driver)\neditor = \(driver)\n[diff]\nexternal = \(driver)\n[diff \"hostile\"]\ncommand = \(driver)\ntextconv = \(driver)\n[filter \"hostile\"]\nclean = \(filter)\nsmudge = \(filter)\n[credential]\nhelper = !\(driver)\n")
        try write(".git/conditional", "[include]\npath = included\n")
        try git(["config", "includeIf.gitdir:**/\(root.lastPathComponent)/.git.path", "conditional"])
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"]), monitor + "\n")
        try write(".gitattributes", "file.txt filter=hostile diff=hostile\nnew.txt diff=hostile\n")
        let operations: [(String, () async throws -> Void)] = [
            ("root", { _ = await service.repositoryRoot(of: path) }),
            ("status", { _ = try await service.status(in: path) }),
            ("path history", { _ = try await service.log(in: path, path: "file.txt") }),
            ("history pages", {
                _ = try await service.historyReferences(in: path)
                let snapshot = try await service.historySnapshot(in: path, query: .init(path: "file.txt"))
                _ = try await service.historyPage(snapshot)
                _ = try await service.historyCommit(commit.hash, in: path)
            }),
            ("commit detail", { _ = try await service.commitDetail(in: path, commit: commit) }),
            ("working diff", { _ = try await service.diffFiles(in: path, paths: ["file.txt"], staged: false) }),
            ("staged diff", { _ = try await service.diffFiles(in: path, paths: ["file.txt"], staged: true) }),
            ("untracked diff", { _ = try await service.diffFiles(in: path, paths: ["new.txt"], staged: false, untracked: true) }),
            ("commit diff", { _ = try await service.commitDiffFiles(in: path, commit: commit) }),
            ("blame", { _ = try await service.blame(path: "file.txt", contents: Data("working\n".utf8), in: path) }),
            ("ignored paths", { _ = try await service.ignoredPaths(in: path) }),
            ("branches", { _ = try await service.branches(in: path) }),
            ("branch catalog and comparison", {
                let catalog = try await service.branchCatalog(in: path)
                _ = try await service.compareBranch(XCTUnwrap(catalog.branches.first { $0.name == "other" }), in: path)
            }),
            ("stash list", { _ = try await service.stashes(in: path) }),
            ("stash preview", {
                let stashes = try await service.stashRecords(in: path)
                let stash = try XCTUnwrap(stashes.first)
                for file in try await service.stashFiles(stash, in: path) { _ = try await service.stashDiff(stash, file: file, in: path) }
            }),
            ("working tree snapshot", { _ = try await service.worktreeSnapshot(in: path) }),
            ("commit preflight", { _ = try await service.preflight(in: path, content: .files(paths: ["file.txt"], staging: [])) }),
            ("hunk review", { _ = try await service.patchReview(in: path, path: "plain.txt", staged: false) }),
            ("watcher directories", { _ = try await service.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: path) }),
        ]
        for (name, operation) in operations {
            do { try await operation() }
            catch {
                XCTAssertTrue(["status", "working diff", "blame", "commit preflight"].contains(name) && error.localizedDescription.contains("repository programs"), "\(name): \(error)")
            }
            assertNoProgram(name)
        }
    }

    func testContentReadsNeverRunCleanOrProcessFilters() async throws {
        let service = GitService(environment: environment)
        for kind in ["clean", "process"] {
            let filter = try program(kind, tail: kind == "clean" ? "cat" : "exit 1")
            try git(["config", "filter.\(kind).\(kind)", filter])
            try write(".gitattributes", "file.txt filter=\(kind)\n")
            // Force index stat mismatch with the same blob size, so status
            // must examine bytes instead of stopping at the size comparison.
            try write("file.txt", "changed\n")
            for (name, arguments, input) in [
                ("status", ["status", "--porcelain=v2", "-z"], nil),
                ("diff", ["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"], nil),
                ("blame", ["blame", "--porcelain", "--no-textconv", "--contents", "-", "--", "file.txt"], Data("changed\n".utf8)),
            ] as [(String, [String], Data?)] {
                do { _ = try await service.run(arguments, in: root.path, input: input) }
                catch { XCTAssertTrue(error.localizedDescription.contains("repository programs"), "\(error)") }
                assertNoProgram("\(kind): \(name)")
            }
        }
    }

    func testObjectReadsNeverStartPromisorRemotePrograms() async throws {
        let oid = try git(["rev-parse", "HEAD:file.txt"]).trimmingCharacters(in: .newlines)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2)))
        let remote = try program("remote", tail: "exit 1")
        try git(["config", "extensions.partialClone", "origin"])
        try git(["config", "remote.origin.promisor", "true"])
        try git(["config", "remote.origin.url", "ext::" + remote])
        try git(["config", "protocol.ext.allow", "always"])
        let service = GitService(environment: environment)
        let result = try await service.run(["cat-file", "blob", oid], in: root.path)
        XCTAssertNotEqual(result.status, 0)
        assertNoProgram("Missing-object read")
    }

    func testHistoryNeverRunsRepositorySignatureVerifier() async throws {
        let original = try git(["cat-file", "commit", "HEAD"])
        let signature = "\ngpgsig -----BEGIN PGP SIGNATURE-----\n fixture\n -----END PGP SIGNATURE-----\n\n"
        let commitFile = ".git/signed-fixture"
        try write(commitFile, original.replacingOccurrences(of: "\n\n", with: signature))
        let oid = try git(["hash-object", "-t", "commit", "-w", commitFile]).trimmingCharacters(in: .newlines)
        try git(["update-ref", "HEAD", oid])
        let service = GitService(environment: environment), path = root.path
        let commits = try await service.log(in: path), commit = try XCTUnwrap(commits.first)
        let verifier = try program("signature-verifier", tail: "exit 1")
        try git(["config", "gpg.program", verifier]); try git(["config", "log.showSignature", "true"])
        _ = try await service.log(in: path)
        assertNoProgram("History signature")
        _ = try await service.commitDetail(in: path, commit: commit)
        assertNoProgram("Commit signature")
    }

    func testExplicitMutationsKeepConfiguredFiltersAndCommitHooks() async throws {
        let filter = try program("clean"), hook = try program("pre-commit", tail: "exit 0")
        try git(["config", "filter.fixture.clean", filter])
        try write(".gitattributes", "file.txt filter=fixture\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: hook, toPath: root.appendingPathComponent(".git/hooks/pre-commit").path)
        let service = GitService(environment: environment), marker = root.appendingPathComponent("ran")
        try await service.stage(["file.txt"], in: root.path)
        XCTAssertTrue(try String(contentsOf: marker, encoding: .utf8).contains("clean"))
        try FileManager.default.removeItem(at: marker)
        _ = try await service.commit(message: "Explicit fixture action", in: root.path, content: .staged)
        XCTAssertTrue(try String(contentsOf: marker, encoding: .utf8).contains("pre-commit"))
    }

    func testNestedSubmoduleStatusKeepsGitChildrenButNeverRunsTheirMonitor() async throws {
        try git(["init", "-q", "--template=", "module-source"])
        try write("module-source/tracked.txt", "base\n")
        try git(["-C", "module-source", "add", "."])
        try git(["-C", "module-source", "commit", "-qm", "Module"])
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", root.appendingPathComponent("module-source").path, "nested"])
        let monitor = try program("nested-monitor", tail: "printf 'token\\000'")
        try git(["-C", "nested", "config", "core.fsmonitor", monitor])
        try write("nested/tracked.txt", "edit\n")
        let status = try await GitService(environment: environment).status(in: root.path)
        XCTAssertTrue(status.entries.contains { $0.path == "nested" && $0.unstaged })
        assertNoProgram("Submodule status")
    }
}
