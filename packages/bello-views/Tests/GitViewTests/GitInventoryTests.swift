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

    @MainActor func testWildcardScopesMatchConcreteDestinations() async throws {
        let receiver = try GitRedirectReceiver(); defer { receiver.stop() }
        let address = try await receiver.start()
        try git(["config", "remote.origin.url", address + "/old"])
        try git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try git(["config", "http.https://*.example.com/.followRedirects", "true"])
        try git(["config", "http.https://*.example.com/.extraHeader", "X-Unrelated: fixture"])
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
        catch { XCTFail("Child must retain its own global filter: \(error)") }
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
        warm = GitConfiguration.queryCount
        // An in-place change only to the alternate index: the normal index,
        // HEAD and git-directory stamps all remain unchanged.
        let bytes = try Data(contentsOf: alternate)
        let handle = try FileHandle(forWritingTo: alternate)
        try handle.write(contentsOf: bytes); try handle.close()
        _ = try await service.status(in: root.path)
        XCTAssertGreaterThan(GitConfiguration.queryCount, warm)
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
