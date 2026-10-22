import XCTest
@testable import GitView
@testable import GitProcessSafety

/// Every executable is a generated marker writer. Nothing contacts a remote.
final class GitRepositorySecurityTests: ViewsTestCase {
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

    private func rawRead(_ arguments: [String], environment: [String: String]) throws -> GitService.Output {
        let process = Process(), output = Pipe(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = root
        process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = diagnostics
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitService.Output(stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self), status: process.terminationStatus)
    }

    func testCRLFWarningWithExternalFilterFilenamePreservesSuccessfulReads() async throws {
        let name = "external filter.txt"
        try write(name, "base\n"); try git(["add", "--", name])
        try git(["config", "core.autocrlf", "true"]); try git(["config", "core.safecrlf", "warn"])
        try write(name, "edit\n")
        var env = environment; env["LANG"] = "en_US.UTF-8"; env["GIT_OPTIONAL_LOCKS"] = "0"
        let service = GitService(environment: env, trusted: true)
        for arguments in [["status", "--porcelain=v2", "-z"], ["diff", "--no-ext-diff", "--no-textconv", "--", name]] {
            let raw = try rawRead(arguments, environment: env)
            XCTAssertEqual(raw.status, 0, raw.stderr)
            XCTAssertTrue(raw.text.contains(name))
            if arguments.first == "diff" {
                XCTAssertTrue(raw.stderr.contains("warning: in the working copy of 'external filter.txt', LF will be replaced by CRLF"), raw.stderr)
                XCTAssertTrue(raw.text.contains("-base\n+edit\n"), raw.text)
            }
            do {
                let result = try await service.run(arguments, in: root.path)
                XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stdout, raw.stdout)
            } catch { XCTFail("A CRLF warning must not reject a successful \(arguments[0]): \(error)") }
        }
    }

    func testGlobalFilterProgressPreservesSuccessfulReads() async throws {
        let command = try program("global-progress", tail: "printf 'progress: external filter is copying\\n' >&2\ncat")
        try write(".git/global-fixture", "[filter \"fixture\"]\nclean = \(command)\nrequired = true\n")
        try write(".gitattributes", "file.txt filter=fixture\n"); try write("file.txt", "changed\n")
        var env = environment; env["GIT_CONFIG_GLOBAL"] = root.appendingPathComponent(".git/global-fixture").path
        env["LANG"] = "en_US.UTF-8"; env["GIT_OPTIONAL_LOCKS"] = "0"
        let service = GitService(environment: env, trusted: true)
        for arguments in [["status", "--porcelain=v2", "-z"], ["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"]] {
            let raw = try rawRead(arguments, environment: env)
            XCTAssertEqual(raw.status, 0, raw.stderr); XCTAssertTrue(raw.stderr.contains("progress: external filter is copying"), raw.stderr)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("ran"))
            do {
                let result = try await service.run(arguments, in: root.path)
                XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stdout, raw.stdout)
            } catch { XCTFail("A permitted global program's progress must not reject a successful read: \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path), "The permitted global filter must run")
        }
    }

    func testOptionalFilterFailureStillRejectsZeroExitReads() async throws {
        let command = try program("global-failure", tail: "exit 1")
        try write(".gitattributes", "file.txt filter=fixture\n"); try write("file.txt", "changed\n")
        var env = environment; env["GIT_CONFIG_GLOBAL"] = root.appendingPathComponent(".git/global-fixture").path
        env["LANG"] = "en_US.UTF-8"; env["GIT_OPTIONAL_LOCKS"] = "0"
        let service = GitService(environment: env, trusted: true)
        for value in [command, command + " " + String(repeating: "x", count: 5_000)] {
            try write(".git/global-fixture", "[filter \"fixture\"]\nclean = \(value)\nrequired = false\n")
            for arguments in [["status", "--porcelain=v2", "-z"], ["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"]] {
                let raw = try rawRead(arguments, environment: env)
                XCTAssertEqual(raw.status, 0, raw.stderr); XCTAssertTrue(raw.stderr.contains("error: external filter '"), raw.stderr)
                do { _ = try await service.run(arguments, in: root.path); XCTFail("An optional filter failure must not become a successful comparison (command bytes: \(value.utf8.count))") }
                catch { XCTAssertTrue(error.localizedDescription.contains("content filter"), error.localizedDescription) }
            }
        }
    }

    func testFilterFailureDiagnosticsUseGitMessageFormsAndLineBoundaries() {
        func hasFilterFailure(_ text: String) -> Bool { GitService.hasFilterFailure(Data(text.utf8)) }
        let failures = [
            "cannot fork to run external filter 'fixture'",
            "cannot feed the input to external filter 'fixture'",
            "external filter 'fixture' failed", "external filter 'fixture' failed 1", "external filter 'fixture' failed -1",
            "read from external filter 'fixture' failed",
            "external filter 'fixture' is not available anymore although not all paths have been filtered",
            "path name too long for external filter",
            "cannot fork to run subprocess 'fixture'", "initialization for subprocess 'fixture' failed",
            "file.txt: clean filter 'fixture' failed", "file.txt: smudge filter fixture failed",
            "file\nname: clean filter 'fixture' failed", "file\nname: smudge filter fixture failed",
            "external filter 'fixture\ncommand' failed",
            "external filter '\u{301}fixture' failed",
        ]
        for message in failures {
            for prefix in ["error: ", "fatal: "] {
                for surrounding in [("", ""), ("progress\n", "\nnext line\n")] {
                    XCTAssertTrue(hasFilterFailure(surrounding.0 + prefix + message + surrounding.1), message)
                }
            }
            XCTAssertFalse(hasFilterFailure("warning: " + message + "\n"), message)
            XCTAssertFalse(hasFilterFailure("progress: error: " + message + "\n"), message)
        }
        for harmless in ["progress: external filter is copying\n", "error: external filter 'fixture' finished\n",
                         "fatal: initialization for subprocess 'fixture' completed\n", "error: file.txt: clean filter 'fixture' succeeded\n",
                         "warning: in the working copy of 'external filter.txt', LF will be replaced by CRLF\n"] {
            XCTAssertFalse(hasFilterFailure(harmless), harmless)
        }
        for prefix in ["error: external filter '", "fatal: read from external filter '"] {
            var truncated = Data(prefix.utf8)
            truncated += Data(repeating: 120, count: 4094 - truncated.count)
            truncated += Data([0xc3, 10]) // A diagnostic truncated within a UTF-8 scalar.
            XCTAssertTrue(GitService.hasFilterFailure(truncated))
            XCTAssertFalse(GitService.hasFilterFailure(Data("progress: ".utf8) + truncated))
        }
        XCTAssertFalse(hasFilterFailure(String(repeating: "error: x\n", count: 7_000)))
        XCTAssertFalse(hasFilterFailure(String(repeating: "error: external filter '", count: 2_000)))
        XCTAssertTrue(hasFilterFailure("warning: in the working copy of 'name\nerror: external filter 'fixture' failed\n.txt', LF will be replaced by CRLF\n"),
                      "A newline in a filename may cause a conservative refusal, never suppress a real failure")
    }

    func testGlobalOnlyProgramsDoNotAcquireLocalOverrides() async throws {
        let global = root.appendingPathComponent(".git/global-only")
        for (name, tail) in [("glob\u{00e1}l-monitor", "printf 'token\\000'"), ("global-clean", "cat")] {
            let path = root.appendingPathComponent(".git/" + name)
            try Data("#!/bin/sh\n: > '\(root.path)/\(name)-ran'\n\(tail)\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try Data("[core]\nfsmonitor = \(root.path)/.git/glob\u{00e1}l-monitor\n[filter \"fixture=global\"]\nclean = \(root.path)/.git/global-clean\nrequired = true\n".utf8).write(to: global)
        try write(".gitattributes", "file.txt filter=fixture=global\n")
        try write("file.txt", "changed\n")
        var env = environment; env["GIT_CONFIG_GLOBAL"] = global.path
        do {
            let result = try await GitService(environment: env, trusted: true).run(["status", "--porcelain=v2"], in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        } catch { XCTFail("User-owned programs need no local override: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("glob\u{00e1}l-monitor-ran").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("global-clean-ran").path))
    }

    func testInvalidUTF8CannotRenameAProgramOverride() async throws {
        try await unrepresentableProgramName(Data("hostile".utf8) + Data([0xff]))
    }
    func testEqualsCannotSplitAProgramOverride() async throws {
        try await unrepresentableProgramName(Data("hostile=shadow".utf8))
    }
    func testCanonicallyEquivalentFilterNamesStayByteDistinct() async throws {
        let filter = try program("unicode-name"), config = root.appendingPathComponent(".git/config")
        let first = "caf\u{00e9}", second = "cafe\u{0301}"
        var bytes = try Data(contentsOf: config)
        bytes += Data("\n[filter \"\(first)\"]\nclean = \(filter)\n[filter \"\(second)\"]\nclean = \(filter)\n".utf8)
        try bytes.write(to: config)
        try write(".gitattributes", "file.txt filter=\(first)\nplain.txt filter=\(second)\n")
        try write("file.txt", "changed\n")
        do { _ = try await GitService(environment: environment, trusted: true).run(["diff", "--no-ext-diff", "--no-textconv"], in: root.path) }
        catch { XCTAssertTrue(error.localizedDescription.contains("content filter"), error.localizedDescription) }
        assertNoProgram("Canonically equivalent filter names")
    }
    private func unrepresentableProgramName(_ name: Data) async throws {
        let filter = try program("invalid-name")
        let config = root.appendingPathComponent(".git/config")
        var bytes = try Data(contentsOf: config)
        bytes += Data("\n[filter \"".utf8) + name + Data("\"]\nclean = \(filter)\n".utf8)
        try bytes.write(to: config)
        try (Data("file.txt filter=".utf8) + name + Data("\n".utf8)).write(to: root.appendingPathComponent(".gitattributes"))
        try write("file.txt", "changed\n")
        let process = Process(); process.currentDirectoryURL = root
        do {
            let policy = try GitReadProcess(process, arguments: ["diff", "--no-ext-diff", "--no-textconv"],
                                            environment: environment, trusted: true)
            defer { policy.remove() }
            XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec")
        } catch { XCTFail("Unrepresentable overrides must select confinement: \(error)") }
        do {
            _ = try await GitService(environment: environment, trusted: true).run(["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"], in: root.path)
        } catch { XCTAssertTrue(error.localizedDescription.contains("content filter"), error.localizedDescription) }
        assertNoProgram("Unrepresentable filter name")
    }

    func testTrustedReadsKeepGlobalFiltersAndRejectLocalPrograms() async throws {
        let global = root.appendingPathComponent(".git/fixture-global")
        let allowed = root.appendingPathComponent(".git/global-filter")
        let marker = root.appendingPathComponent("global-ran")
        try Data("#!/bin/sh\n: > '\(marker.path)'\nsed 's/^changed$/indexed/'\n".utf8).write(to: allowed)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: allowed.path)
        try Data("[filter \"lfs\"]\nclean = \(allowed.path)\nsmudge = \(allowed.path)\nrequired = true\n".utf8).write(to: global)
        var env = environment; env["GIT_CONFIG_GLOBAL"] = global.path
        let hostile = try program("local-filter"), monitor = try program("local-monitor", tail: "printf 'token\\000'")
        try write(".git/local-programs", "[filter \"hostile\"]\nclean = \(hostile)\nprocess = \(hostile)\n[filter \"lfs\"]\nclean = \(hostile)\n[core]\nfsmonitor = \(monitor)\nhooksPath = \(root.path)/.git/hooks\n")
        try git(["config", "includeIf.gitdir:**/\(root.lastPathComponent)/.git.path", "local-programs"])
        try git(["config", "extensions.worktreeConfig", "true"])
        try git(["config", "--worktree", "filter.lfs.smudge", hostile])
        try write(".gitattributes", "file.txt filter=lfs\nplain.txt filter=hostile\n")
        try write("file.txt", "changed\n")
        for scope in ["global", "system"] {
            if scope == "system" {
                env.removeValue(forKey: "GIT_CONFIG_NOSYSTEM"); env["GIT_CONFIG_SYSTEM"] = global.path; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            }
            let service = GitService(environment: env, trusted: true)
            for arguments in [["status", "--porcelain=v2"], ["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"]] {
                do {
                    let result = try await service.run(arguments, in: root.path); XCTAssertEqual(result.status, 0, result.stderr)
                    if arguments.first == "diff" { XCTAssertTrue(result.stdout.isEmpty, "The global conversion must match the indexed bytes") }
                } catch { XCTFail("Trusted \(scope) filters must work: \(error)") }
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The \(scope) LFS-style clean filter did not run")
                assertNoProgram(arguments.joined(separator: " "))
                try? FileManager.default.removeItem(at: marker)
            }
        }
    }

    func testReadOnlyQueriesNeverRunRepositoryPrograms() async throws {
        try await readOnlyQueries(trusted: false)
    }
    func testTrustedReadOnlyQueriesNeverRunRepositoryPrograms() async throws {
        try await readOnlyQueries(trusted: true)
    }
    private func readOnlyQueries(trusted: Bool) async throws {
        let service = GitService(environment: environment, trusted: trusted), path = root.path
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
        for trusted in [false, true] {
            let service = GitService(environment: environment, trusted: trusted)
            let result = try await service.run(["cat-file", "blob", oid], in: root.path)
            XCTAssertNotEqual(result.status, 0)
            assertNoProgram("Missing-object read, trusted: \(trusted)")
        }
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
        for trusted in [false, true] {
            let service = GitService(environment: environment, trusted: trusted)
            _ = try await service.log(in: path)
            assertNoProgram("History signature, trusted: \(trusted)")
            _ = try await service.commitDetail(in: path, commit: commit)
            assertNoProgram("Commit signature, trusted: \(trusted)")
        }
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

    func testNestedSubmoduleStatusKeepsGitlinksWithoutChildWorktreeReads() async throws {
        try git(["init", "-q", "--template=", "module-source"])
        try write("module-source/tracked.txt", "base\n")
        try git(["-C", "module-source", "add", "."])
        try git(["-C", "module-source", "commit", "-qm", "Module"])
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", root.appendingPathComponent("module-source").path, "nested"])
        let monitor = try program("nested-monitor", tail: "printf 'token\\000'")
        try git(["-C", "nested", "config", "core.fsmonitor", monitor])
        try write("nested/tracked.txt", "edit\n")
        let filter = try program("nested-filter")
        try git(["-C", "nested", "config", "filter.nested.clean", filter])
        try write("nested/.gitattributes", "tracked.txt filter=nested\n")
        for trusted in [false, true] {
            do {
                let status = try await GitService(environment: environment, trusted: trusted).status(in: root.path)
                XCTAssertTrue(status.entries.contains { $0.path == "nested" && $0.staged })
                XCTAssertFalse(status.entries.contains { $0.path == "nested" && $0.unstaged })
            } catch { XCTAssertFalse(trusted, "\(error)") }
            assertNoProgram("Submodule status, trusted: \(trusted)")
        }
    }
}
