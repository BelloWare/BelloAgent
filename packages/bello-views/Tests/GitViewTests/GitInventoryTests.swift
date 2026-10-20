import XCTest
import Darwin
import CoreServices
@testable import GitView
@testable import GitProcessSafety

final class GitInventoryTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String]!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-inventory-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_CONFIG_GLOBAL": root.appendingPathComponent("global").path, "GIT_TERMINAL_PROMPT": "0"]
        try git(["init", "-q", "--template=", "-b", "main"])
        try write("file", "base\n"); try git(["add", "file"]); try git(["commit", "-qm", "Fixture"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = directory ?? root
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return String(decoding: data, as: UTF8.self)
    }
    private func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }

    private func monitor() throws -> String {
        try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        let path = root.appendingPathComponent("monitor").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testDeinitializedSubmoduleKeepsRedirectRefusal() async throws {
        try await storedModuleRedirect(nested: false)
    }

    func testNestedStoredSubmoduleKeepsRedirectRefusal() async throws {
        try await storedModuleRedirect(nested: true)
    }

    private func storedModuleRedirect(nested: Bool) async throws {
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", "--name", "group/child", root.path, "child"])
        let child = root.appendingPathComponent("child")
        if nested {
            try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", root.path, "nested"], in: child)
        }
        try git(["submodule", "deinit", "-f", "--all"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path))
        let stored = root.appendingPathComponent(".git/modules/group/child" + (nested ? "/modules/nested" : ""))
        let config = stored.appendingPathComponent("config").path
        let before = try GitConfiguration(in: root, environment: environment).redirectOptions()
        XCTAssertFalse(before.protected)
        let warm = GitConfiguration.queryCount
        try git(["config", "--file", config, "http.extraHeader", "X-Fixture: stored-module"])
        try git(["config", "--file", config, "http.followRedirects", "false"])
        try git(["config", "--file", config, "http.https://fixture.invalid/.followRedirects", "true"])
        try git(["config", "--file", config, "core.fsmonitor", try monitor()])
        let policy = try GitConfiguration(in: root, environment: environment).redirectOptions()
        XCTAssertTrue(policy.protected)
        XCTAssertTrue(policy.options.contains("http.followredirects=false"))
        XCTAssertTrue(policy.options.contains("http.https://fixture.invalid/.followredirects=false"))
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm, "Stored config edits invalidate the parent inventory")
        var childEnvironment = environment!
        childEnvironment["GIT_DIR"] = stored.path; childEnvironment["GIT_WORK_TREE"] = stored.path
        let effective = try GitConfiguration.query(policy.options + ["config", "--get-urlmatch", "http.followRedirects", "https://fixture.invalid/repo"],
                                                    in: stored, environment: childEnvironment)
        XCTAssertEqual(effective.status, 0)
        XCTAssertEqual(effective.data, Data("false\n".utf8))
        _ = try await GitService(environment: environment, trusted: true).status(in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testNewStoredModuleInvalidatesWarmInventory() throws {
        XCTAssertFalse(try GitConfiguration(in: root, environment: environment).redirectOptions().protected)
        let warm = GitConfiguration.queryCount
        let stored = root.appendingPathComponent(".git/modules/group/absent-checkout")
        try git(["init", "-q", "--bare", "--template=", stored.path])
        try git(["config", "--file", stored.appendingPathComponent("config").path, "http.extraHeader", "X-Fixture: new"])
        XCTAssertTrue(try GitConfiguration(in: root, environment: environment).redirectOptions().protected)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
    }

    func testUninspectableStoredConfigCannotRelaxRedirects() throws {
        let stored = root.appendingPathComponent(".git/modules/child")
        try git(["init", "-q", "--bare", "--template=", stored.path])
        let config = stored.appendingPathComponent("config"), original = try Data(contentsOf: config)
        for key in ["include.path", "includeIf.onbranch:absent.path"] {
            try original.write(to: config)
            try git(["config", "--file", config.path, key, "/dev/stdin"])
            XCTAssertThrowsError(try GitConfiguration(in: root, environment: environment).redirectOptions(), key)
        }
    }

    func testStoredModuleDoesNotWeakenHeaderFreeRedirectPolicy() throws {
        let stored = root.appendingPathComponent(".git/modules/child")
        try git(["init", "-q", "--bare", "--template=", stored.path])
        try git(["config", "--file", stored.appendingPathComponent("config").path, "http.followRedirects", "false"])
        for parent in ["false", "true"] {
            try git(["config", "http.followRedirects", parent])
            let policy = try GitConfiguration(in: root, environment: environment).redirectOptions()
            XCTAssertFalse(policy.protected)
            var childEnvironment = environment!
            childEnvironment["GIT_DIR"] = stored.path; childEnvironment["GIT_WORK_TREE"] = stored.path
            let child = try GitConfiguration.query(policy.options + ["config", "--get", "http.followRedirects"],
                                                    in: stored, environment: childEnvironment)
            XCTAssertEqual(child.status, 0)
            XCTAssertEqual(child.data, Data("false\n".utf8))
            let own = try GitConfiguration.query(policy.options + ["config", "--get", "http.followRedirects"],
                                                  in: root, environment: environment)
            XCTAssertEqual(own.data, Data((parent + "\n").utf8))
        }
    }

    func testStoredModuleAliasKeepsItsOwnConditionalHeaders() throws {
        let child = root.appendingPathComponent("child"), modules = root.appendingPathComponent(".git/modules")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try git(["init", "-q", "--template="], in: child)
        let commit = String(try git(["rev-parse", "HEAD"]).dropLast())
        try git(["update-index", "--add", "--cacheinfo", "160000," + commit + ",child"])
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let alias = modules.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child.appendingPathComponent(".git"))
        try write("module-policy", "[http]\nextraHeader = X-Fixture: alias\n[core]\nfsmonitor = " + (try monitor()) + "\n")
        try git(["config", "includeIf.gitdir:*/modules/alias.path", root.appendingPathComponent("module-policy").path], in: child)
        var storedEnvironment = environment!
        storedEnvironment["GIT_DIR"] = alias.path; storedEnvironment["GIT_WORK_TREE"] = alias.path
        let included = try GitConfiguration.query(["config", "--get", "http.extraHeader"], in: alias, environment: storedEnvironment)
        XCTAssertEqual(included.status, 0)
        XCTAssertEqual(included.data, Data("X-Fixture: alias\n".utf8))
        let policy = try GitConfiguration(in: root, environment: environment).redirectOptions()
        XCTAssertTrue(policy.protected, "A stored spelling can activate different includes from its populated checkout")
        XCTAssertTrue(policy.options.contains("http.followredirects=false"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testStoredModuleEnvironmentCannotRewriteGitdirConditions() throws {
        // Python passes the fixture's composed UTF-8 bytes directly to Git;
        // Foundation would decompose them while creating its argv/envp.
        let script = #"""
        import os, subprocess, sys
        root = os.path.realpath(sys.argv[1])
        stored = root + '/.git/modules/caf\u00e9'
        subprocess.run(['/usr/bin/git', 'init', '-q', '--bare', '--template=', stored], check=True)
        included = root + '/module-policy'
        with open(included, 'w') as f:
            f.write('[http]\nextraHeader = X-Fixture: unicode\n[core]\nfsmonitor = ' + root + '/monitor\n')
        subprocess.run(['/usr/bin/git', 'config', '--file', stored + '/config', 'includeIf.gitdir:' + stored + '.path', included], check=True)
        result = subprocess.check_output(['/usr/bin/git', '--git-dir=' + stored, 'config', '--get', 'http.extraHeader'])
        with open(root + '/module-header', 'wb') as f: f.write(result)
        """#
        try write("create-module.py", script)
        _ = try monitor()
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        generator.arguments = [root.appendingPathComponent("create-module.py").path, root.path]
        generator.environment = environment; generator.standardInput = FileHandle.nullDevice
        generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit(); XCTAssertEqual(generator.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("module-header")), Data("X-Fixture: unicode\n".utf8))
        do {
            let policy = try GitConfiguration(in: root, environment: environment).redirectOptions()
            XCTAssertTrue(policy.protected, "The metadata context lost a Git-active conditional include")
        } catch is GitConfiguration.ConfinementRequired { }
        let process = Process(); process.currentDirectoryURL = root
        let read = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
        defer { read.remove() }
        XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testStoredModuleRelativeConfigRootsFailClosed() throws {
        let stored = root.appendingPathComponent(".git/modules/child")
        try git(["init", "-q", "--bare", "--template=", stored.path])
        environment["GIT_CONFIG_GLOBAL"] = "relative-global"
        XCTAssertThrowsError(try GitConfiguration(in: root, environment: environment).redirectOptions())
    }

    func testTrustedRepositoryPathEndingInCarriageReturn() async throws {
        let directory = root.appendingPathComponent("checkout\r")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "--template="], in: directory)
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("file"))
        try git(["add", "file"], in: directory)
        try git(["config", "core.fsmonitor", try monitor()], in: directory)
        let service = GitService(environment: environment, trusted: true)
        let found = await service.repositoryRoot(of: directory.path)
        XCTAssertEqual(found, String(decoding: try git(["rev-parse", "--show-toplevel"], in: directory).utf8.dropLast(), as: UTF8.self))
        do {
            let status = try await service.status(in: directory.path)
            XCTAssertTrue(status.entries.contains { $0.path == "file" })
        } catch { XCTFail("A trailing CR is part of the repository path: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testStashCommonDirectoryKeepsTrailingCarriageReturn() async throws {
        let directory = root.appendingPathComponent("separate"), storage = root.appendingPathComponent("storage\r")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "--separate-git-dir=" + storage.path], in: directory)
        // Git gitfiles trim CRLF themselves; explicit paths can retain CR.
        environment["GIT_DIR"] = storage.path; environment["GIT_WORK_TREE"] = directory.path
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("file"))
        try git(["add", "file"], in: directory); try git(["commit", "-qm", "Base"], in: directory)
        try Data("changed\n".utf8).write(to: directory.appendingPathComponent("file"))
        try git(["stash", "push", "-qm", "Fixture"], in: directory)
        try git(["config", "core.fsmonitor", try monitor()], in: directory)
        let records = try await GitService(environment: environment, trusted: true).stashRecords(in: directory.path)
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testPatchIndexKeepsTrailingCarriageReturn() async throws {
        let alternate = root.appendingPathComponent("index\r")
        try FileManager.default.copyItem(at: root.appendingPathComponent(".git/index"), to: alternate)
        environment["GIT_INDEX_FILE"] = alternate.path
        try write("file", "changed\n")
        try git(["config", "core.fsmonitor", try monitor()])
        do {
            let review = try await GitService(environment: environment, trusted: true).patchReview(in: root.path, path: "file", staged: false)
            XCTAssertEqual(review.patch.hunks.count, 1)
        } catch { XCTFail("A trailing CR is part of the index path: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testControlCharactersInGitdirRequireConfinement() throws {
        for character in ["\n", "\t", "\u{8}", "\r", "\u{7f}"] {
            try overridePathFixture("checkout" + character + "fixture", confined: true)
        }
    }

    func testQuotedGitdirConditionsKeepLocalProgramsDisabled() throws {
        for character in ["\"", "\\", "*?[]"] {
            try overridePathFixture("checkout" + character + "fixture", confined: false)
        }
    }

    func testCombiningMarksInGitdirKeepLocalProgramsDisabled() throws {
        for text in ["[\u{301}x]", "\\\u{301}", "\"\u{301}", "*\u{301}", "?\u{301}", "]\u{301}"] {
            try overridePathFixture("checkout" + text + "fixture", confined: false)
        }
    }

    func testCombiningMarksInOverridesRoundTripThroughGitParsing() throws {
        let gitDirectory = String(try git(["rev-parse", "--absolute-git-dir"]).dropLast())
        for (name, value) in [("filter.quote\"\u{301}.clean", "value"), ("filter.slash\\\u{301}.clean", "value"),
                              ("filter.safe.clean", "\"\u{301}"), ("filter.safe.clean", "\\\u{301}")] {
            let overrides = try GitReadOverrides(gitDirectory: gitDirectory, options: ["-c", name + "=" + value])
            defer { withExtendedLifetime(overrides) {} }
            let file = overrides.directory.appendingPathComponent("config").path
            let parsed = try GitConfiguration.query(["config", "--file", file, "--no-includes", "--null", "--list"],
                                                    in: root, environment: environment)
            XCTAssertEqual(parsed.status, 0)
            XCTAssertEqual(parsed.data, Data((name + "\n" + value + "\0").utf8))
            let effective = try GitConfiguration.query(["-c", overrides.argument, "config", "--includes", "--null",
                                                        "--show-origin", "--get-regexp", "^filter\\."],
                                                       in: root, environment: environment)
            XCTAssertEqual(effective.status, 0)
            XCTAssertEqual(effective.data, Data(("file:" + file + "\0" + name + "\n" + value + "\0").utf8))
        }
    }

    private func overridePathFixture(_ name: String, confined: Bool) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q", "--template="], in: directory)
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("file"))
        try git(["add", "file"], in: directory)
        try git(["config", "core.fsmonitor", try monitor()], in: directory)
        let marker = root.appendingPathComponent("hostile-ran")
        for _ in 0..<2 {
            let process = Process(); process.currentDirectoryURL = directory
            do {
                let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
                defer { policy.remove() }
                XCTAssertEqual(process.executableURL?.lastPathComponent, confined ? "sandbox-exec" : "git", name.debugDescription)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, name.debugDescription)
            } catch { XCTFail("Path still needs a safe read: \(name.debugDescription): \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), name.debugDescription)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testGeneratedOverridesRoundTripThroughGitParsing() throws {
        let values = [("filter.quote\"slash\\literal.clean", " \"quoted\" \\literal # ; = "),
                      ("credential.helper", ""), ("credential.helper", "!printf '%s' \"a\\\\b\""),
                      ("core.fsmonitor", "false")]
        let gitDirectory = String(try git(["rev-parse", "--absolute-git-dir"]).dropLast())
        let overrides = try GitReadOverrides(gitDirectory: gitDirectory,
                                            options: values.flatMap { ["-c", $0.0 + "=" + $0.1] })
        defer { withExtendedLifetime(overrides) {} }
        let file = overrides.directory.appendingPathComponent("config").path
        let parsed = try GitConfiguration.query(["config", "--file", file, "--no-includes", "--null", "--list"],
                                                in: root, environment: environment)
        XCTAssertEqual(parsed.status, 0)
        XCTAssertEqual(parsed.data, Data(values.map { $0.0 + "\n" + $0.1 + "\0" }.joined().utf8))
        let include = try GitConfiguration.query(["config", "--file", overrides.directory.appendingPathComponent("include").path,
                                                  "--no-includes", "--null", "--list"], in: root, environment: environment)
        XCTAssertEqual(include.status, 0)
        XCTAssertEqual(include.data, Data("includeif.gitdir:\(gitDirectory).path\n\(file)\0".utf8))
        let effective = try git(["-c", overrides.argument, "config", "--includes", "--null", "--show-origin",
                                 "--get-regexp", "^(filter\\.|credential\\.|core\\.fsmonitor$)"])
        XCTAssertEqual(Data(effective.utf8), Data(values.map { "file:" + file + "\0" + $0.0 + "\n" + $0.1 + "\0" }.joined().utf8))
    }

    func testUnsafeGeneratedSubsectionsAndValuesRequireConfinement() throws {
        for character in ["\n", "\t", "\u{8}", "\r", "\0", "\u{7f}"] {
            for option in ["filter.bad" + character + ".clean=", "core.fsmonitor=bad" + character] {
                XCTAssertThrowsError(try GitReadOverrides(gitDirectory: root.appendingPathComponent(".git").path, options: ["-c", option])) {
                    XCTAssertTrue($0 is GitConfiguration.ConfinementRequired, "\($0)")
                }
            }
        }
    }

    func testInvalidConfigBytesRequireConfinedReads() throws {
        let file = root.appendingPathComponent(".git/config")
        let original = try Data(contentsOf: file), command = try monitor()
        let variants = [Data("[filter \"unsafe".utf8) + Data([0xff]) + Data("\"]\nclean = \(command)\n".utf8),
                        Data("[include]\npath = ../invalid-".utf8) + Data([0xff]) + Data("\n".utf8)]
        for bytes in variants {
            try (original + Data("\n[core]\nfsmonitor = \(command)\n".utf8) + bytes).write(to: file)
            let process = Process(); process.currentDirectoryURL = root
            do {
                let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
                defer { policy.remove() }
                XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec")
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
            } catch { XCTFail("Unrepresentable config must select confinement: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
        }
    }

    func testControlCharactersInRestoredValuesRequireConfinement() throws {
        let command = try monitor(), marker = root.appendingPathComponent("hostile-ran")
        try git(["config", "core.fsmonitor", command])
        for character in ["\n", "\t", "\u{8}", "\r"] {
            try git(["config", "--file", environment["GIT_CONFIG_GLOBAL"]!, "core.fsmonitor", command + " #" + character])
            let process = Process(); process.currentDirectoryURL = root
            do {
                let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
                defer { policy.remove() }
                XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec", character.debugDescription)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            } catch { XCTFail("Unsafe restored value must select confinement: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), character.debugDescription)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testStdinIncludesCannotExecuteBlameContents() async throws {
        let contents = Data("[core]\nfsmonitor = \(try monitor())\n".utf8)
        for source in ["/dev/stdin", "/dev/fd/0"] {
            try git(["config", "include.path", source])
            do {
                let result = try await GitService(environment: environment, trusted: true).blame(path: "file", contents: contents, in: root.path)
                XCTAssertEqual(result.lines.count, 2, source)
            } catch { XCTFail("Blame must still read the displayed snapshot: \(source): \(error)") }
            let marker = root.appendingPathComponent("hostile-ran")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), source)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testDynamicIncludeSourcesAlwaysUseConfinement() throws {
        let config = root.appendingPathComponent(".git/config"), original = try Data(contentsOf: config)
        try write("inner", "[include]\npath = /dev/fd/0\n")
        try write("outer", "[include]\npath = inner\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "/dev/stdin")
        for (name, section, target) in [
            ("stdin", "include", "/dev/stdin"), ("fd", "include", "/dev/fd/0"),
            ("missing fd", "include", "/dev/fd/999"), ("null include", "include", "/dev/null"),
            ("alias", "include", "../alias"), ("nested", "include", "../outer"),
            ("conditional", "includeIf \"onbranch:main\"", "../outer"),
            ("inactive conditional", "includeIf \"onbranch:absent\"", "../outer")
        ] {
            try (original + Data("\n[\(section)]\npath = \(target)\n".utf8)).write(to: config)
            let process = Process(); process.currentDirectoryURL = root
            do {
                let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
                defer { policy.remove() }
                XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec", name)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, name == "missing fd" ? 128 : 0, name)
            } catch { XCTFail("Cannot prepare a confined read: \(name): \(error)") }
        }
    }

    func testFIFOIncludeUsesConfinementForChangingContent() throws {
        let fifo = root.appendingPathComponent("config-pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let producer = ConfigPipe(fifo.path)
        defer { producer.stop() }
        try write("inner", "[include]\npath = config-pipe\n")
        try git(["config", "include.path", "../inner"])
        let process = Process(); process.currentDirectoryURL = root
        let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment,
                                        trusted: true, invocation: GitInvocation(timeout: 5))
        defer { policy.remove() }
        XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec")
        XCTAssertEqual(producer.writes, 0, "Inventory must not consume a live config stream")
        producer.set("[core]\nfsmonitor = \(try monitor())\n")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testWarmRegularIncludeRetargetedToStdinLosesExecutionPermission() throws {
        let include = root.appendingPathComponent("included"), marker = root.appendingPathComponent("hostile-ran")
        try write("included", "# regular fixture\n")
        try write("global", "[core]\nfsmonitor = \(try monitor())\n")
        try git(["config", "include.path", "../included"])
        for dynamic in [false, true] {
            if dynamic {
                try FileManager.default.removeItem(at: include)
                try FileManager.default.createSymbolicLink(atPath: include.path, withDestinationPath: "/dev/stdin")
            }
            let process = Process(); process.currentDirectoryURL = root
            let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
            defer { policy.remove() }
            XCTAssertEqual(process.executableURL?.lastPathComponent, dynamic ? "sandbox-exec" : "git")
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), !dynamic)
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testSocketIncludeUsesConfinementEvenWhenInactive() throws {
        let path = "/tmp/bello-config-socket-" + UUID().uuidString
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor); try? FileManager.default.removeItem(atPath: path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        try git(["config", "includeIf.onbranch:absent.path", path])
        let process = Process(); process.currentDirectoryURL = root
        let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
        defer { policy.remove() }
        XCTAssertEqual(process.executableURL?.lastPathComponent, "sandbox-exec")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testUnicodeIncludePathsKeepReadPolicy() throws {
        let name = "caf\u{e9}", path = root.path + "/" + name
        let config = root.appendingPathComponent(".git/config"), original = try Data(contentsOf: config)
        let marker = root.appendingPathComponent("hostile-ran"), command = try monitor()
        for inactive in [false, true] {
            try write(name, inactive ? "[include]\npath = /dev/stdin\n" : "[core]\nfsmonitor = \(command)\n")
            try write("global", inactive ? "[core]\nfsmonitor = \(command)\n" : "[include]\npath = \(path)\n")
            if inactive {
                try (original + Data("\n[includeIf \"onbranch:absent\"]\npath = \(path)\n".utf8)).write(to: config)
            }
            let process = Process(); process.currentDirectoryURL = root
            do {
                let policy = try GitReadProcess(process, arguments: ["status", "--porcelain=v2"], environment: environment, trusted: true)
                defer { policy.remove() }
                XCTAssertEqual(process.executableURL?.lastPathComponent, inactive ? "sandbox-exec" : "git")
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), !inactive)
                try? FileManager.default.removeItem(at: marker)
            } catch { XCTFail("Unicode include must preserve the read policy (inactive: \(inactive)): \(error)") }
        }
    }

    private final class ConfigPipe: @unchecked Sendable {
        private let lock = NSLock(), finished = DispatchSemaphore(value: 0)
        private var content = Data("# fixture\n".utf8), stopped = false, count = 0
        var writes: Int { lock.withLock { count } }
        init(_ path: String) {
            DispatchQueue.global().async { [self] in
                defer { finished.signal() }
                while true {
                    let (done, bytes) = lock.withLock { (stopped, content) }
                    if done { return }
                    let descriptor = open(path, O_WRONLY | O_NONBLOCK)
                    if descriptor >= 0 {
                        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                        if written > 0 { lock.withLock { count += 1 } }
                        close(descriptor)
                    }
                    usleep(5_000)
                }
            }
        }
        func set(_ text: String) { lock.withLock { content = Data(text.utf8) } }
        func stop() { lock.withLock { stopped = true }; finished.wait() }
    }

    func testPrivateIndexesDoNotInvalidateOrInterruptInventory() async throws {
        try git(["config", "core.fsmonitor", try monitor()])
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let warm = GitConfiguration.queryCount
        let snapshot = try GitIndexSnapshot.read(at: root.appendingPathComponent(".git/index").path)
        let copy = try snapshot.copyForGit()
        defer { copy.remove() }
        _ = try await service.status(in: root.path)
        XCTAssertEqual(GitConfiguration.queryCount, warm, "A private hunk index does not change repository identity or config")
        GitConfiguration.invalidate()
        let before = GitConfiguration.queryCount
        let edit = Task.detached {
            while GitConfiguration.queryCount < before + 3 { try await Task.sleep(for: .milliseconds(1)) }
            return try snapshot.copyForGit()
        }
        do { _ = try await service.status(in: root.path) }
        catch { XCTFail("A concurrent hunk review must not interrupt the inventory: \(error)") }
        let concurrent = try await edit.value
        concurrent.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    @MainActor func testHunkReadsReuseScopedConfiguration() async throws {
        let previous = GitService.resolveTrust, path = root.path
        defer { GitService.resolveTrust = previous }
        GitService.resolveTrust = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path }
        try git(["config", "core.fsmonitor", try monitor()])
        try write("file", "edit\n")
        let service = GitService(environment: environment)
        _ = try await service.patchReview(in: root.path, path: "file", staged: false)
        let warm = GitConfiguration.queryCount
        _ = try await service.patchReview(in: root.path, path: "file", staged: false)
        XCTAssertEqual(GitConfiguration.queryCount, warm, "A new private index must not rebuild the repository's scoped config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    private func splitRepository(activate: Bool) throws -> URL {
        let child = root.appendingPathComponent("nested"), pending = root.appendingPathComponent("common-pending")
        try FileManager.default.createDirectory(at: child.appendingPathComponent("deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try write("nested/.git/HEAD", "ref: refs/heads/main\n")
        try write("nested/.git/commondir", root.appendingPathComponent("common").path + "\n")
        try FileManager.default.copyItem(at: root.appendingPathComponent(".git/index"), to: child.appendingPathComponent(".git/index"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("file"), to: child.appendingPathComponent("file"))
        try FileManager.default.copyItem(at: root.appendingPathComponent(".git"), to: pending)
        if activate { try FileManager.default.moveItem(at: pending, to: root.appendingPathComponent("common")) }
        return child.appendingPathComponent("deep")
    }

    func testIncompleteGitDirectoryCannotHideLaterDiscovery() async throws {
        let directory = try splitRepository(activate: false)
        try git(["config", "--file", root.appendingPathComponent("common-pending/config").path, "core.fsmonitor", try monitor()])
        let first = try GitConfiguration(in: directory, environment: environment)
        XCTAssertFalse(first.cacheable, "An unrecognized .git candidate can become valid through an external commondir")
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: directory.path)
        try FileManager.default.moveItem(at: root.appendingPathComponent("common-pending"), to: root.appendingPathComponent("common"))
        _ = try await service.status(in: directory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testCommonDirectoryValidityChangesRevalidateDiscovery() async throws {
        try git(["config", "core.fsmonitor", try monitor()])
        let directory = try splitRepository(activate: true)
        let service = GitService(environment: environment, trusted: true)
        for name in ["objects", "refs"] {
            _ = try await service.status(in: directory.path)
            let warm = GitConfiguration.queryCount
            let file = root.appendingPathComponent("common/" + name), moved = root.appendingPathComponent("common/held-" + name)
            try FileManager.default.moveItem(at: file, to: moved)
            _ = try await service.status(in: directory.path)
            XCTAssertGreaterThan(GitConfiguration.queryCount, warm, name)
            let marker = root.appendingPathComponent("hostile-ran")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), name)
            try? FileManager.default.removeItem(at: marker)
            try FileManager.default.moveItem(at: moved, to: file)
        }
    }

    func testHistoricalSubmoduleDiffNeverRunsChildPrograms() async throws {
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try git(["init", "-q", "--template=", "-b", "main"], in: child)
        try write("child/file", "base\n"); try write("child/.gitattributes", "file diff=hostile\n")
        try git(["add", "."], in: child); try git(["commit", "-qm", "Child base"], in: child)
        for change in [false, true] {
            if change { try write("child/file", "edit\n"); try git(["commit", "-qam", "Child change"], in: child) }
            let hash = try git(["rev-parse", "HEAD"], in: child).trimmingCharacters(in: .newlines)
            try git(["update-index", "--add", "--cacheinfo", "160000,\(hash),child"])
            try git(["commit", "-qm", change ? "New child" : "Initial child"])
        }
        try write("driver", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\ncat \"$1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("driver").path)
        try git(["config", "diff.hostile.textconv", root.appendingPathComponent("driver").path], in: child)
        try git(["config", "diff.submodule", "diff"])
        let service = GitService(environment: environment, trusted: true)
        let commits = try await service.log(in: root.path, limit: 1)
        _ = try await service.commitDiffFiles(in: root.path, commit: XCTUnwrap(commits.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path), "History spawned a child's local textconv")
        try git(["config", "status.submoduleSummary", "true"])
        try git(["config", "submodule.recurse", "true"])
        try git(["config", "core.fsmonitor", root.appendingPathComponent("driver").path], in: child)
        for arguments in [["show", "--format=", "--no-ext-diff", "--no-textconv", "HEAD"],
                          ["log", "-p", "-1", "--no-ext-diff", "--no-textconv"],
                          ["diff", "--no-ext-diff", "--no-textconv", "HEAD^", "HEAD"],
                          ["diff", "--no-ext-diff", "--no-textconv", "HEAD"],
                          ["status", "--porcelain=v2"],
                          ["blame", "--no-textconv", "--", "file"],
                          ["ls-files", "-z"], ["stash", "list"]] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("hostile-ran"))
            let output = try await service.run(arguments, in: root.path)
            XCTAssertEqual(output.status, 0, arguments.joined(separator: " "))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path), arguments.joined(separator: " "))
            if ["show", "log"].contains(arguments[0]) { XCTAssertTrue(output.text.contains("Subproject commit")) }
        }
        try git(["-c", "core.fsmonitor=false", "commit", "--allow-empty", "-qm", "New gitlink"], in: child)
        let status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.contains { $0.path == "child" }, "Read gitlink changes without inspecting the child's worktree")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testRepositoryCreationInvalidatesDiscovery() async throws {
        // Neither a previously absent repository nor a new nested repository
        // may inherit a warm inventory for the old discovery result.
        for nested in [false, true] {
            let directory = root.appendingPathComponent(nested ? "nested" : "plain")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !nested { try FileManager.default.removeItem(at: root.appendingPathComponent(".git")) }
            let service = GitService(environment: environment, trusted: true)
            let query = nested ? directory.appendingPathComponent("deep") : directory
            try FileManager.default.createDirectory(at: query, withIntermediateDirectories: true)
            _ = try await service.run(["status", "--porcelain=v2"], in: query.path)
            try git(["init", "-q", "--template=", "-b", "main"], in: directory)
            try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("README"))
            try git(["add", "README"], in: directory)
            try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("monitor").path)
            try git(["config", "core.fsmonitor", root.appendingPathComponent("monitor").path], in: directory)
            _ = try await service.status(in: query.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path), "New repository, nested=\(nested)")
            try? FileManager.default.removeItem(at: root.appendingPathComponent("hostile-ran"))
            if !nested { try git(["init", "-q", "--template=", "-b", "main"]) }
        }
    }

    func testNamedUserIncludeIsStampedBeforeItExists() async throws {
        let account = try XCTUnwrap(getpwuid(getuid()))
        let user = String(cString: account.pointee.pw_name), home = String(cString: account.pointee.pw_dir)
        // Traverse from the account home to a generated temp file. Never read
        // or write that account's real Git configuration or other user data.
        let up = String(repeating: "../", count: home.split(separator: "/").count)
        let target = "~\(user)/" + up + root.path.dropFirst() + "/late-include"
        try git(["config", "include.path", target])
        try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("monitor").path)
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        try write("late-include", "[core]\nfsmonitor = \(root.path)/monitor\n")
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"]), root.appendingPathComponent("monitor").path + "\n")
        _ = try await service.status(in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path), "A populated ~user include escaped the warm inventory")
    }

    func testRelativeIncludeOriginsUseRepositoryRootFromDeepDirectory() async throws {
        let deep = root.appendingPathComponent("deep/nested")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try git(["config", "include.path", "late-include"])
        try write(".git/late-include", "")
        try await lateInclude(".git/late-include", querying: deep)
    }

    func testIncludePathsPreserveSymlinkDotDotTraversal() async throws {
        let leaf = root.appendingPathComponent("outside/leaf")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git/bridge"), withDestinationURL: leaf)
        try git(["config", "include.path", "bridge/../late-include"])
        try await lateInclude("outside/late-include", querying: root)
    }

    func testConditionalIncludesAreStampedBeforeTheyExist() async throws {
        for (index, condition) in ["onbranch:main", "gitdir:**/\(root.lastPathComponent)/.git", "gitdir/i:**/\(root.lastPathComponent.uppercased())/.GIT"].enumerated() {
            try git(["config", "includeIf.\(condition).path", "../conditional-\(index)"])
            try await lateInclude("conditional-\(index)", querying: root)
        }
    }

    func testOnBranchIncludeObservesSymbolicRefChainChanges() async throws {
        try git(["branch", "other"])
        try git(["symbolic-ref", "refs/heads/alias", "refs/heads/other"])
        try git(["symbolic-ref", "HEAD", "refs/heads/alias"])
        try git(["config", "includeIf.onbranch:main.path", "../conditional"])
        try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("monitor").path)
        try write("conditional", "[core]\nfsmonitor = \(root.path)/monitor\n")
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))
        try git(["symbolic-ref", "refs/heads/alias", "refs/heads/main"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), head)
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"]), root.appendingPathComponent("monitor").path + "\n")
        _ = try await service.status(in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testConditionalIncludeObservesOriginDirectorySymlinkChanges() async throws {
        let away = root.appendingPathComponent("away"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try write("away/config", "[includeIf \"gitdir:./.git\"]\npath = \(root.path)/conditional\n")
        try FileManager.default.linkItem(at: away.appendingPathComponent("config"), to: root.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: away)
        try git(["config", "include.path", "../link/config"])
        try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("monitor").path)
        try write("conditional", "[core]\nfsmonitor = \(root.path)/monitor\n")
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"]), root.appendingPathComponent("monitor").path + "\n")
        _ = try await service.status(in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testConditionalIncludeObservesSymlinksInsideOriginTarget() async throws {
        let external = root.appendingPathComponent("external"), away = root.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try write("away/config", "[includeIf \"gitdir:./.git\"]\npath = \(root.path)/conditional\n")
        try FileManager.default.linkItem(at: away.appendingPathComponent("config"), to: root.appendingPathComponent("config"))
        let current = external.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: away)
        try FileManager.default.createSymbolicLink(atPath: external.appendingPathComponent("config").path, withDestinationPath: "current/config")
        try git(["config", "include.path", "../external/config"])
        try write("conditional", "[core]\nfsmonitor = \(try monitor())\n")
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let warm = GitConfiguration.queryCount
        // The spelled origin and its final inode stay identical; only a
        // symlink inside that origin's target chain changes Git's condition.
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: root)
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"]), root.appendingPathComponent("monitor").path + "\n")
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    @MainActor func testNewlineOnlyHeaderDoesNotPermitRedirects() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        try git(["config", "remote.origin.url", address + "/repo"])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: newline"])
        try git(["config", "--add", "http.extraHeader", "\n"])
        try git(["config", "http.followRedirects", "false"])
        source.answer([307], location: other + "/collect")
        do { try await GitService(environment: environment).fetch(in: root.path); XCTFail("Redirected newline header") }
        catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(error)") }
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertTrue(source.requests.first?.head.lowercased().contains("x-fixture-secret: newline") == true)
        XCTAssertEqual(destination.requests.count, 0)
    }

    @MainActor func testURLLessLegacyDefaultRemoteCannotForwardHeaders() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        try git(["config", "remote.backup.fetch", "+refs/heads/*:refs/remotes/backup/*"])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: legacy-default"])
        try git(["config", "http.followRedirects", "false"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/remotes"), withIntermediateDirectories: true)
        try write(".git/remotes/backup", "URL: \(address)/backup\nFetch: refs/heads/main:refs/remotes/backup/main\nPush: refs/heads/main:refs/heads/main\n")
        for command in ["fetch", "pull", "push"] {
            source.answer([308], location: other + "/collect"); destination.answer([])
            let service = GitService(environment: environment)
            do {
                switch command {
                case "fetch": try await service.fetch(in: root.path)
                case "pull": try await service.pull(in: root.path)
                default: try await service.push(in: root.path)
                }
                XCTFail("Redirected legacy default: \(command)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(command): \(error)") }
            XCTAssertEqual(source.requests.count, 1, command)
            XCTAssertTrue(source.requests.first?.head.lowercased().contains("x-fixture-secret: legacy-default") == true, command)
            XCTAssertEqual(destination.requests.count, 0, command)
        }
    }

    @MainActor func testAnyHeaderKeyProtectsEveryDestinationRegardlessOfValue() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        try git(["config", "remote.origin.url", address + "/repo"])
        try git(["config", "http.\(address)/repo.followRedirects", "true"])
        try git(["config", "http.http://127.0.*.1/.followRedirects", "initial"])
        let config = root.appendingPathComponent(".git/config"), original = try Data(contentsOf: config)
        for (key, value) in [("HTTP.ExTrAhEaDeR", ""), ("http.extraHeader", "\n"),
                             ("HTTP.https://unrelated.invalid/.EXTRAHEADER", ""),
                             ("http.https://*.unrelated.invalid/.extraHeader", "X-Unrelated: fixture")] {
            try original.write(to: config)
            // Empty and newline values count even after a real header.
            try git(["config", "--add", key, "X-Fixture-Secret: previous"])
            try git(["config", "--add", key, value])
            source.answer([307], location: other + "/collect"); destination.answer([])
            do { try await GitService(environment: environment).fetch(in: root.path); XCTFail("Redirected: \(key)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("this repository has http.extraHeader"), "\(key): \(error)") }
            XCTAssertEqual(source.requests.count, 1, key)
            XCTAssertEqual(destination.requests.count, 0, key)
        }
        try original.write(to: config)
        let ordinary = try GitConfiguration(in: root, environment: environment).redirectOptions()
        XCTAssertFalse(ordinary.protected, "Removing all header keys restores ordinary redirects")
        XCTAssertTrue(stride(from: 1, to: ordinary.options.count, by: 2).allSatisfy { ordinary.options[$0].hasSuffix("=initial") })
    }

    func testSubmoduleAliasRetargetRechecksConfiguration() throws {
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for child in [first, second] {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try git(["init", "-q", "--template="], in: child)
        }
        try git(["config", "http.extraHeader", "X-Fixture-Secret: child"], in: second)
        let link = root.appendingPathComponent("child")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let commit = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try git(["update-index", "--add", "--cacheinfo", "160000,\(commit),child"])
        XCTAssertFalse(try GitConfiguration(in: root, environment: environment).redirectOptions().protected)
        let warm = GitConfiguration.queryCount
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        XCTAssertTrue(try GitConfiguration(in: root, environment: environment).redirectOptions().protected)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
    }

    private func lateInclude(_ file: String, querying directory: URL) async throws {
        try write("monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("monitor").path)
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: directory.path)
        let warm = GitConfiguration.queryCount
        try write(file, "[core]\nfsmonitor = \(root.path)/monitor\n")
        XCTAssertEqual(try git(["config", "--get", "core.fsmonitor"], in: directory), root.appendingPathComponent("monitor").path + "\n")
        _ = try await service.status(in: directory.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm, file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path), file)
        // Give each conditional include an independent absent-to-present test.
        try write(file, "")
    }

    func testUnresolvableInactiveIncludeDisablesCache() throws {
        let user = "bello-fixture-" + UUID().uuidString
        XCTAssertNil(getpwnam(user))
        try git(["config", "includeIf.onbranch:never.path", "~\(user)/missing"])
        let first = try GitConfiguration(in: root, environment: environment)
        let warm = GitConfiguration.queryCount
        _ = try GitConfiguration(in: root, environment: environment)
        XCTAssertFalse(first.cacheable)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm, "An unresolved include must never enter the cache")
    }

    func testUnreadableDiscoveryOrIncludeStampDisablesCache() throws {
        let loop = root.appendingPathComponent("loop"), blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        XCTAssertFalse(GitFileStamp(loop.path).cacheable)
        XCTAssertFalse(GitFileStamp(loop.path).unchanged)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try git(["config", "includeIf.onbranch:never.path", "../blocked/missing"])
        _ = try GitConfiguration(in: root, environment: environment)
        let readable = GitConfiguration.queryCount
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let first = try GitConfiguration(in: root, environment: environment), warm = GitConfiguration.queryCount
        _ = try GitConfiguration(in: root, environment: environment)
        XCTAssertFalse(first.cacheable)
        XCTAssertGreaterThan(warm, readable, "Permission failure is not proof that an absent file is unchanged")
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
    }

    @MainActor func testTrustChangeDuringInventoryCannotRepopulateCache() async throws {
        let previous = GitService.resolveTrust
        defer { GitService.resolveTrust = previous }
        GitService.resolveTrust = { _ in true }
        let service = GitService(environment: environment), path = root.path, before = GitConfiguration.queryCount
        let read = Task { try await service.status(in: path) }
        while GitConfiguration.queryCount < before + 3 { try await Task.sleep(for: .milliseconds(1)) }
        GitService.resolveTrust = { _ in false }
        GitService.resolveTrust = { _ in true }
        _ = try await read.value
        let warm = GitConfiguration.queryCount
        _ = try await service.status(in: path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm, "A pre-invalidation builder must not publish into the new cache")
    }

    @MainActor func testPushDestinationsUsePushRewritesAndDefaults() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        try git(["config", "push.default", "current"])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: push-rewrite"])
        try git(["config", "http.followRedirects", "false"])
        try git(["config", "url.\(address)/.pushInsteadOf", "fixture:"])
        try git(["config", "remote.origin.url", "fixture:origin"])
        try git(["config", "url.\(other)/fetch-only/.insteadOf", "fixture:"])
        let base = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        for (key, value, path) in [("remote.pushDefault", "fixture:default", "default"),
                                  ("branch.main.pushRemote", "fixture:branch", "branch"),
                                  ("branch.main.remote", "fixture:upstream", "upstream"),
                                  ("remote.origin.pushurl", address + "/pushurl", "pushurl"),
                                  ("remote.pushDefault", "origin", "origin")] {
            try base.write(to: root.appendingPathComponent(".git/config"))
            try git(["config", key, value])
            if key == "branch.main.pushRemote" { try git(["config", "remote.pushDefault", "fixture:overridden"]) }
            source.answer([307], location: other + "/collect"); destination.answer([])
            do { try await GitService(environment: environment).push(in: root.path); XCTFail("Redirected \(key)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(key): \(error)") }
            XCTAssertEqual(source.requests.count, 1, key)
            XCTAssertTrue(source.requests.first?.head.contains("/\(path)/info/refs") == true, key)
            XCTAssertEqual(destination.requests.count, 0, "Private header escaped via \(key)")
        }
    }

    @MainActor func testWildcardScopesNeverNeedDestinationResolution() async throws {
        let receiver = try GitRedirectReceiver(); defer { receiver.stop() }
        let address = try await receiver.start()
        try git(["config", "remote.origin.url", address + "/old"])
        try git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try git(["config", "http.https://*.example.com/.followRedirects", "true"])
        receiver.answer([301, 200], location: address + "/new/info/refs?service=git-upload-pack",
                        responseBody: "001e# service=git-upload-pack\n00000000", contentType: "application/x-git-upload-pack-advertisement")
        do { try await GitService(environment: environment).fetch(in: root.path) }
        catch { XCTFail("Unrelated wildcard is valid Git config: \(error)") }
        XCTAssertEqual(receiver.requests.count, 2)
        let other = try GitRedirectReceiver(); defer { other.stop() }
        let otherAddress = try await other.start()
        let pattern = address.replacingOccurrences(of: "127.0.0.1", with: "127.0.*.1") + "/"
        try git(["config", "http.\(pattern).extraHeader", "X-Fixture-Secret: wildcard"])
        try git(["config", "http.\(pattern).followRedirects", "true"])
        XCTAssertEqual(try git(["config", "--get-urlmatch", "http.extraHeader", address + "/old"]), "X-Fixture-Secret: wildcard\n")
        receiver.answer([308], location: otherAddress + "/collect")
        do { try await GitService(environment: environment).fetch(in: root.path); XCTFail("Wildcard header followed redirect") }
        catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(error)") }
        XCTAssertEqual(other.requests.count, 0)
    }

    @MainActor func testLegacyOriginUsesPushRewrites() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        try git(["config", "push.default", "current"])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: legacy"])
        try git(["config", "url.\(address)/.pushInsteadOf", "fixture:"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/remotes"), withIntermediateDirectories: true)
        try write(".git/remotes/origin", "URL: fixture:legacy\nPush: refs/heads/main:refs/heads/main\n")
        source.answer([307], location: other + "/collect")
        do { try await GitService(environment: environment).push(in: root.path); XCTFail("Redirected legacy push") }
        catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(error)") }
        XCTAssertTrue(source.requests.first?.head.contains("/legacy/info/refs") == true)
        XCTAssertEqual(destination.requests.count, 0)
    }

    @MainActor func testEquivalentURLScopesCannotOverrideProtectedDestination() async throws {
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        let url = "HTTP" + address.dropFirst(4) + "/repo"
        try git(["config", "remote.origin.url", url])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: equivalent-scope"])
        try git(["config", "http.\(address)/repo.followRedirects", "true"])
        source.answer([307], location: other + "/collect")
        do { try await GitService(environment: environment).fetch(in: root.path); XCTFail("Redirected equivalent scope") }
        catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(error)") }
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(destination.requests.count, 0)
    }

    func testSubmoduleKeepsItsOwnConditionalGlobalFilter() async throws {
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try git(["init", "-q", "--template="], in: child)
        try write("child/file", "base\n"); try write("child/.gitattributes", "file filter=foo\n")
        try git(["add", "."], in: child); try git(["commit", "-qm", "Child"], in: child)
        let hash = try git(["rev-parse", "HEAD"], in: child).trimmingCharacters(in: .newlines)
        try git(["update-index", "--add", "--cacheinfo", "160000,\(hash),child"])
        try write("global", "[includeIf \"gitdir:**/\(root.lastPathComponent)/child/.git\"]\npath = child-global\n")
        try write("child-global", "[filter \"foo\"]\nclean = \(root.path)/allowed\nrequired = true\n")
        try write("allowed", "#!/bin/sh\n: > '\(root.path)/allowed-ran'\ncat\n")
        try write("hostile", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\ncat\n")
        for name in ["allowed", "hostile"] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(name).path) }
        XCTAssertEqual(try git(["config", "--get", "filter.foo.clean"], in: child), root.appendingPathComponent("allowed").path + "\n")
        try git(["config", "filter.foo.clean", root.appendingPathComponent("hostile").path])
        try git(["config", "core.fsmonitor", root.appendingPathComponent("hostile").path], in: child)
        // Equal sizes force content conversion instead of Git's size shortcut.
        try write(".gitattributes", "file filter=foo\n"); try write("file", "edit\n"); try write("child/file", "edit\n")
        do { _ = try await GitService(environment: environment, trusted: true).status(in: root.path) }
        catch { XCTFail("Parent must not recurse into child filters: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("allowed-ran").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
        do { _ = try await GitService(environment: environment, trusted: true).status(in: child.path) }
        catch { XCTFail("An explicit child read must retain its own global filter: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("allowed-ran").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testConditionalPoliciesPreserveGitDirectoryMetacharacters() async throws {
        let renamed = root.appendingPathExtension("=[?]*\\fixture\n")
        try FileManager.default.moveItem(at: root, to: renamed); root = renamed
        try write(".git/monitor", "#!/bin/sh\n: > '\(root.path)/hostile-ran'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/monitor").path)
        try git(["config", "core.fsmonitor", root.appendingPathComponent(".git/monitor").path])
        do { _ = try await GitService(environment: environment, trusted: true).status(in: root.path) }
        catch { XCTFail("A valid repository path must retain its conditional policy: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hostile-ran").path))
    }

    func testInventorySharesReadDeadline() async throws { try await blockedInventory(cancel: false) }
    func testCancellingReadStopsInventory() async throws { try await blockedInventory(cancel: true) }
    func testCancellingCacheRebuildStopsInventory() async throws {
        _ = try await GitService(environment: environment, trusted: true).status(in: root.path)
        try await blockedInventory(cancel: true)
    }
    private func blockedInventory(cancel: Bool) async throws {
        let fifo = root.appendingPathComponent("slow-config")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try git(["config", "include.path", fifo.path])
        // Open both ends so Git can enter read(), then release after one second.
        let descriptor = open(fifo.path, O_RDWR | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            try? FileManager.default.removeItem(at: fifo)
            close(descriptor)
        }
        let service = GitService(environment: environment, trusted: true), path = root.path
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { try await service.run(["status", "--porcelain=v2"], in: path, timeout: cancel ? 20 : 0.15) }
        if cancel { try await Task.sleep(for: .milliseconds(100)); task.cancel() }
        do { _ = try await task.value; XCTFail("Read must stop") }
        catch {
            if cancel { XCTAssertTrue(error is CancellationError, "\(error)") }
            else { XCTAssertTrue(error.localizedDescription.lowercased().contains("timed out"), "\(error)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.7, "Inventory outlived its read")
        let running = await service.processesRunning; XCTAssertEqual(running, 0)
    }

    func testWarmReadsReuseInventoryAndObserveConfigChanges() async throws {
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let warm = GitConfiguration.queryCount
        _ = try await service.status(in: root.path)
        XCTAssertEqual(GitConfiguration.queryCount, warm, "Warm reads must reuse config and submodule inventory")
        try write(".git/included", "[core]\nfsmonitor = false\n")
        try git(["config", "include.path", "included"])
        _ = try await service.status(in: root.path)
        let included = GitConfiguration.queryCount
        try write(".git/included", "[core]\nfsmonitor = /does-not-exist\n")
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, included, "Included config edits must invalidate")
    }

    func testNullGlobalConfigIgnoresDeviceWrites() async throws {
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let warm = GitConfiguration.queryCount
        try await Task.sleep(for: .milliseconds(1_100))
        let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        try sink.write(contentsOf: Data("generated fixture diagnostic\n".utf8)); try sink.close()
        _ = try await service.status(in: root.path)
        XCTAssertEqual(GitConfiguration.queryCount, warm)
    }

    @MainActor func testTrustChangesDiscardWarmInventory() async throws {
        let previous = GitService.resolveTrust
        defer { GitService.resolveTrust = previous }
        GitService.resolveTrust = { _ in true }
        let service = GitService(environment: environment)
        _ = try await service.status(in: root.path)
        let warm = GitConfiguration.queryCount
        GitService.resolveTrust = { _ in false }
        GitService.resolveTrust = { _ in true }
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
    }

    @MainActor func testWatcherInvalidatesConfigButNotWorkingFileSaves() async throws {
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        let watcher = GitWorkingTreeWatcher(root: root.path, onChange: {})
        watcher.start(); defer { watcher.stop() }
        let warm = GitConfiguration.queryCount
        watcher.bridge?.deliver([root.appendingPathComponent("file").path], [0])
        _ = try await service.status(in: root.path)
        XCTAssertEqual(GitConfiguration.queryCount, warm)
        watcher.bridge?.deliver([root.appendingPathComponent(".git/config").path], [0])
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
    }

    func testGlobalSystemWorktreeAndMissingIncludesInvalidateInventory() async throws {
        environment.removeValue(forKey: "GIT_CONFIG_NOSYSTEM")
        environment["GIT_CONFIG_SYSTEM"] = root.appendingPathComponent("system").path
        try git(["config", "extensions.worktreeConfig", "true"])
        try write("global", "[include]\npath = missing-include\n")
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        for file in ["system", "global", ".git/config.worktree", "missing-include"] {
            let warm = GitConfiguration.queryCount
            try write(file, "[core]\nfsmonitor = false\n[include]\npath = \(root.path)/missing-include\n")
            if file == "missing-include" { try write(file, "[core]\nfsmonitor = false\n") }
            _ = try await service.status(in: root.path)
            XCTAssertGreaterThan(GitConfiguration.queryCount, warm, file)
        }
    }

    func testAlreadyCancelledReadDoesNotStartInventory() async throws {
        let service = GitService(environment: environment, trusted: true), path = root.path
        let warm = GitConfiguration.queryCount
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.status(in: path)
        }
        do { _ = try await task.value; XCTFail("Cancelled read completed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(GitConfiguration.queryCount, warm)
    }

    func testHeadGitmodulesAndAlternateIndexInvalidateSubmoduleInventory() async throws {
        let alternate = root.appendingPathComponent("alternate-index")
        try FileManager.default.copyItem(at: root.appendingPathComponent(".git/index"), to: alternate)
        environment["GIT_INDEX_FILE"] = alternate.path
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.status(in: root.path)
        var warm = GitConfiguration.queryCount
        try write(".gitmodules", "# generated module inventory\n")
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
        warm = GitConfiguration.queryCount
        try git(["symbolic-ref", "HEAD", "refs/heads/fixture"])
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
        // Transport inventories still use the caller's index for gitlinks.
        _ = try GitConfiguration(in: root, environment: environment)
        warm = GitConfiguration.queryCount
        // An in-place change only to the alternate index: the normal index,
        // HEAD and git-directory stamps all remain unchanged.
        let bytes = try Data(contentsOf: alternate)
        let handle = try FileHandle(forWritingTo: alternate)
        try handle.write(contentsOf: bytes); try handle.close()
        _ = try GitConfiguration(in: root, environment: environment)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
        try git(["symbolic-ref", "HEAD", "refs/heads/main"])
        let normal = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try write("file", "alternate\n"); try git(["add", "file"]); try write("file", "base\n")
        let status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.contains { $0.path == "file" && $0.staged && $0.indexState == "M" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), normal)
    }

    func testConfigEditDuringInventoryCannotBecomeAWarmUnsafeEntry() async throws {
        let config = root.appendingPathComponent(".git/config"), marker = root.appendingPathComponent("hostile-ran")
        let program = root.appendingPathComponent("monitor")
        try write("monitor", "#!/bin/sh\n: > '\(marker.path)'\nprintf 'token\\000'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let count = GitConfiguration.queryCount
        let edit = Task.detached {
            // The two config reads have finished when the gitdir probe begins.
            while GitConfiguration.queryCount < count + 3 { try await Task.sleep(for: .milliseconds(1)) }
            let bytes = try Data(contentsOf: config)
            try (bytes + Data("\n[core]\nfsmonitor = \(program.path)\n".utf8)).write(to: config)
        }
        let service = GitService(environment: environment, trusted: true)
        do { _ = try await service.status(in: root.path) }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed"), "\(error)") }
        try await edit.value
        _ = try await service.status(in: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
