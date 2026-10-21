import XCTest
@testable import PiApp
@testable import GitView

final class GitRepositoryPermissionTests: XCTestCase {
    @MainActor func testNestedProjectTrustKeepsBytePathBoundaries() async throws {
        let root = scratchRoot("git-nested-trust").resolvingSymlinksInPath()
        let outer = root.appendingPathComponent("outer"), inner = outer.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker"), program = root.appendingPathComponent("monitor"), global = root.appendingPathComponent("global")
        try Data("#!/bin/sh\n: > '\(marker.path)'\nprintf 'token\\000'\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        try Data("[core]\nfsmonitor = \(program.path)\n".utf8).write(to: global)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
        let service = GitService(environment: environment)
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "outer", path: outer.path, trusted: true),
                                    WorkspaceRecord(id: "inner", path: inner.path, trusted: false)]
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        defer { model.shutdown() }
        model.tabs.showsWindows = false; try await model.reloadConfiguration()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inner)
        XCTAssertTrue(GitService.resolveTrust(outer.appendingPathComponent("inner-sibling").path))
        XCTAssertFalse(GitService.resolveTrust(root.appendingPathComponent("outer-sibling").path))
        for (index, extender) in ["\u{301}", "\u{200d}", "\u{fe0f}", "\u{1f1f8}\u{1f1ec}"].enumerated() {
            let name = extender + "repo-\(index)", repo = inner.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await service.run(["-c", "core.fsmonitor=false", "init", "-q", "--template="], in: repo.path, readOnly: false)
            try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("file"))
            _ = try await service.run(["-c", "core.fsmonitor=false", "add", "file"], in: repo.path, readOnly: false)
            XCTAssertFalse(GitService.resolveTrust(repo.path), name.debugDescription)
            XCTAssertFalse(GitService.resolveTrust(alias.appendingPathComponent(name).path), "A symlink retains its destination's trust")
            XCTAssertEqual(model.projectID(holding: repo.appendingPathComponent("file").path), "inner")
            XCTAssertEqual(model.projectID(holding: alias.appendingPathComponent(name + "/file").path), "inner")
            let reply = await model.replyFileResolver.resolve(repo.appendingPathComponent("file").path,
                in: .init(roots: [outer.path], projects: [.init(path: outer.path, trusted: true), .init(path: inner.path, trusted: false)]))
            XCTAssertNil(reply, "Reply links must select the same nested trust boundary")
            _ = try await service.status(in: repo.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The untrusted nested project cannot run a global marker program")
            try? FileManager.default.removeItem(at: marker)
            if index == 0 {
                model.workspaces[1].trusted = true
                _ = try await service.status(in: repo.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The fixture exercises allowed global fsmonitor execution")
                try? FileManager.default.removeItem(at: marker)
                model.workspaces[1].path = alias.path
                let file = model.openFile(repo.appendingPathComponent("file"), project: "inner")
                XCTAssertEqual(file.containingFolderRoot?()?.path, inner.path)
                model.workspaces[1].trusted = false
                _ = try await service.status(in: repo.path)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Revocation must not reuse the trusted inventory")
                try? FileManager.default.removeItem(at: marker)
            }
        }
        let plain = inner.appendingPathComponent("plain")
        try Data("fixture\n".utf8).write(to: plain)
        model.workspaces[1].trusted = true
        model.workspaces.append(WorkspaceRecord(id: "denied-alias", path: inner.path, trusted: false))
        XCTAssertFalse(GitService.resolveTrust(plain.path))
        XCTAssertEqual(model.projectID(holding: plain.path), "denied-alias", "Equally specific canonical roots must not override a denial")
        let reply = await model.replyFileResolver.resolve(plain.path,
            in: .init(roots: [outer.path], projects: [.init(path: inner.path, trusted: false), .init(path: alias.path, trusted: true)]))
        XCTAssertNil(reply)
    }

    @MainActor func testReadProgramsUseTheCurrentProjectsTrust() async throws {
        let root = scratchRoot("git-read-trust"), repo = root.appendingPathComponent("repo"), marker = root.appendingPathComponent("ran")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global"), program = root.appendingPathComponent("filter")
        try Data("#!/bin/sh\n: > '\(marker.path)'\ncat\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        try Data("[filter \"fixture\"]\nclean = \(program.path)\n".utf8).write(to: global)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
        let service = GitService(environment: env)
        _ = try await service.run(["init", "-q", "--template="], in: repo.path, readOnly: false)
        try Data("before\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        _ = try await service.run(["add", "file.txt"], in: repo.path, readOnly: false)
        try Data("file.txt filter=fixture\n".utf8).write(to: repo.appendingPathComponent(".gitattributes"))
        try Data("after!\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        var config = VaultConfiguration(); config.workspaces = [WorkspaceRecord(id: "fixture", path: repo.path, trusted: true)]
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        XCTAssertFalse(GitService.resolveTrust(root.path), "The surrounding folder is outside this project")
        _ = try await service.run(["status", "--porcelain=v2"], in: repo.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        model.workspaces[0].trusted = false
        do { _ = try await service.run(["status", "--porcelain=v2"], in: repo.path) }
        catch { XCTAssertTrue(error.localizedDescription.contains("repository programs"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Revoking trust must confine the next read")
    }

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
            try git(["config", "http.\(address)/repo.followRedirects", code == 307 ? "initial" : "true"])
            source.answer([code], location: other + "/collect"); destination.answer([])
            do { try await service.fetch(in: root.path); XCTFail("The configured endpoint redirected") }
            catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), error.localizedDescription) }
            XCTAssertEqual(source.requests.count, 1)
            XCTAssertTrue(try XCTUnwrap(source.requests.first).head.lowercased().contains("x-fixture-secret: synthetic-git-header"))
            XCTAssertEqual(destination.requests.count, 0, "Git forwarded a private header after HTTP \(code)")
        }
    }

    @MainActor func testGitFetchKeepsSameHostRedirectsWithoutPrivateHeaders() async throws {
        let root = scratchRoot("git-http-ordinary-redirect")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = try WebhookReceiver(); defer { receiver.stop() }
        let address = try await receiver.start()
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root; process.environment = environment; process.arguments = ["init", "-q", "--template="]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let service = GitService(environment: environment)
        _ = try await service.run(["config", "remote.origin.url", address + "/old"], in: root.path, readOnly: false)
        _ = try await service.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: root.path, readOnly: false)
        // An empty smart-HTTP advertisement is sufficient for a real fetch.
        receiver.answer([301, 200], location: address + "/renamed/info/refs?service=git-upload-pack",
                        responseBody: "001e# service=git-upload-pack\n00000000", contentType: "application/x-git-upload-pack-advertisement")
        try await service.fetch(in: root.path)
        XCTAssertEqual(receiver.requests.count, 2)
        XCTAssertTrue(receiver.requests.last?.head.contains("/renamed/info/refs") == true)
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
