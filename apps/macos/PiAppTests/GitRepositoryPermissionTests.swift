import XCTest
@testable import PiApp
@testable import GitView

final class GitRepositoryPermissionTests: XCTestCase {
    @MainActor func testGitFetchNeverForwardsPrivateHeadersAcrossOrigins() async throws {
        let root = scratchRoot("git-http-redirect")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root; process.arguments = arguments; process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q", "--template="])
        try git(["config", "http.extraHeader", "X-Fixture-Secret: synthetic-git-header"])
        let destination = try WebhookReceiver(); defer { destination.stop() }
        let other = try await destination.start(), service = GitService(environment: environment)
        for code in [301, 302, 303, 307, 308] {
            let source = try WebhookReceiver(); defer { source.stop() }
            let address = try await source.start()
            try git(["config", "remote.origin.url", address + "/repo"])
            source.answer([code], location: other + "/collect"); destination.answer([])
            do { try await service.fetch(in: root.path); XCTFail("The configured endpoint redirected") }
            catch { }
            XCTAssertEqual(source.requests.count, 1)
            XCTAssertTrue(try XCTUnwrap(source.requests.first).head.lowercased().contains("x-fixture-secret: synthetic-git-header"))
            XCTAssertEqual(destination.requests.count, 0, "Git forwarded a private header after HTTP \(code)")
        }
    }

    @MainActor func testOnlyATrustedProjectsExplicitWritesCanRunRepositoryHooks() async throws {
        let root = scratchRoot("git-permission"), repo = root.appendingPathComponent("repo"), marker = root.appendingPathComponent("ran")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = repo
            process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }
        _ = try git(["init", "-q", "--template=", "-b", "main"])
        try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("README"))
        _ = try git(["add", "."]); _ = try git(["commit", "-qm", "Fixture"])
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try Data("#!/bin/sh\n: > '\(marker.path)'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try git(["config", "core.hooksPath", hooks.path])
        var config = VaultConfiguration()
        config.workspaces = [WorkspaceRecord(id: "fixture", path: repo.path, trusted: false)]
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        defer { model.shutdown() }
        model.tabs.showsWindows = false; try await model.reloadConfiguration()
        let tab = try XCTUnwrap(model.showChanges(in: "fixture")), controller = tab.controller
        defer { controller.letGo() }
        try await eventually("Read-only history remains available") { controller.repositoryIdentity != nil && controller.statusRead && !controller.loading }
        await controller.createBranch("untrusted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try git(["branch", "--show-current"]), "main\n")
        XCTAssertTrue(controller.notice.contains("Trust"))

        model.workspaces[0].trusted = true
        await controller.createBranch("trusted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "An explicit trusted action keeps normal hooks")
        XCTAssertEqual(try git(["branch", "--show-current"]), "trusted\n")
        try? FileManager.default.removeItem(at: marker)
        let reviewed = try XCTUnwrap(controller.repositoryIdentity)
        model.workspaces[0].trusted = false
        do {
            try await controller.performRepositoryWrite(repository: reviewed) { root in
                try await GitService.shared.createBranch("revoked", in: root)
            }
            XCTFail("A previously reviewed action must recheck current trust")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Trust"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try git(["branch", "--show-current"]), "trusted\n")
    }
}
