import XCTest
@testable import PiApp
@testable import GitView
import GitProcessSafety

final class GitRepositoryPermissionTests: XCTestCase {
    @MainActor func testTrustSnapshotsRefuseRenamesDuringPathResolution() async throws {
        let root = scratchRoot("git-trust-spelling").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, names) in [("Denied", "denied"), ("cafe\u{301}", "caf\u{e9}")].enumerated() {
            let parent = root.appendingPathComponent("fixture-\(index)")
            let denied = parent.appendingPathComponent(names.0), renamed = parent.appendingPathComponent(names.1)
            let queried = denied.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: queried, withIntermediateDirectories: true)
            let model = makeWorkspaceModel(stateRoot: parent.appendingPathComponent("state"))
            defer { model.shutdown() }
            model.tabs.showsWindows = false
            model.workspaces = [WorkspaceRecord(id: "parent", path: parent.path, trusted: true),
                                WorkspaceRecord(id: "denied", path: denied.path, trusted: false)]
            let gate = TrustPathGate(path: queried.path)
            model.gitTrustPath = { gate.resolve($0) }
            defer { gate.release() }
            let read = Task { try await GitReadProcess.isTrusted(queried.path) }
            try await eventually("Query path is held while project roots resolve") { gate.isWaiting }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(rename(denied.path, renamed.path), 0)
            gate.release()
            let trusted = try await read.value
            XCTAssertFalse(trusted, "A renamed untrusted boundary must not inherit its ancestor's trust")
            let next = try await GitReadProcess.isTrusted(queried.path)
            XCTAssertFalse(next, "The next read resolves the current spelling too")
        }
    }

    @MainActor func testWriteAdmissionDoesNotResolveProjectPaths() async throws {
        let root = scratchRoot("git-write-admission")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = VaultConfiguration()
        config.workspaces = [WorkspaceRecord(id: "fixture", path: root.path, trusted: true)]
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let tab = ChangesTab(projectID: "fixture", name: "fixture", roots: [root.path])
        let resolver = FileTab.resolveProject
        var resolutions = 0
        FileTab.resolveProject = { id in resolutions += 1; return resolver(id) }
        defer { FileTab.resolveProject = resolver; tab.controller.letGo() }
        XCTAssertTrue(tab.controller.mayWrite())
        XCTAssertEqual(resolutions, 0, "Admission needs only in-memory trust, never the filesystem-backed project resolver")
        model.workspaces[0].trusted = false
        resolutions = 0
        XCTAssertFalse(tab.controller.mayWrite())
        XCTAssertEqual(resolutions, 0)
    }

    @MainActor func testSlowTrustPathDoesNotBlockMainActorOrOtherGitReads() async throws {
        let root = scratchRoot("git-slow-trust").resolvingSymlinksInPath()
        let local = root.appendingPathComponent("local"), slow = root.appendingPathComponent("slow")
        for path in [local, slow] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        for path in [local, slow] { _ = try await service.run(["init", "-q", "--template="], in: path.path, readOnly: false) }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        defer { model.shutdown() }
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "slow", path: slow.path, trusted: true), WorkspaceRecord(id: "local", path: local.path, trusted: true)]
        let gate = TrustPathGate(path: slow.path)
        model.gitTrustPath = { gate.resolve($0) }
        // The timer releases even a main-actor regression, keeping this test bounded.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        defer { gate.release() }
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                if gate.isWaiting { heartbeats += 1 }
            }
        }
        defer { heartbeat.cancel() }
        let blocked = Task { try await service.run(["status", "--porcelain=v2"], in: slow.path) }
        try await eventually("The resolver reached the slow volume") { gate.started }
        let localRead = try await service.run(["status", "--porcelain=v2"], in: local.path, timeout: 1)
        XCTAssertEqual(localRead.status, 0)
        XCTAssertTrue(gate.isWaiting, "An unrelated read finishes before the slow path is released")
        XCTAssertGreaterThan(heartbeats, 0, "Main-actor work keeps running during path resolution")
        gate.release(); _ = try await blocked.value
    }

    @MainActor func testTrustRevokedDuringPathResolutionConfinesTheRead() async throws {
        let root = scratchRoot("git-stale-trust").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo"), marker = root.appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global"), program = root.appendingPathComponent("monitor")
        try Data("#!/bin/sh\n: > '\(marker.path)'\nprintf 'token\\000'\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        try Data("[core]\nfsmonitor = \(program.path)\n".utf8).write(to: global)
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"])
        _ = try await service.run(["-c", "core.fsmonitor=false", "init", "-q", "--template="], in: repo.path, readOnly: false)
        try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("README"))
        _ = try await service.run(["-c", "core.fsmonitor=false", "add", "README"], in: repo.path, readOnly: false)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        defer { model.shutdown() }
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "repo", path: repo.path, trusted: true)]
        let gate = TrustPathGate(path: repo.path)
        model.gitTrustPath = { gate.resolve($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        defer { gate.release() }
        let read = Task { try await service.run(["status", "--porcelain=v2"], in: repo.path) }
        try await eventually("Trust resolution is suspended") { gate.started }
        model.workspaces[0].trusted = false
        gate.release()
        _ = try await read.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A stale trusted snapshot cannot run the global marker file program")
    }

    @MainActor func testTrustPathResolutionUsesReadCancellationAndDeadline() async throws {
        let root = scratchRoot("git-trust-deadline").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GitService(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        _ = try await service.run(["init", "-q", "--template="], in: root.path, readOnly: false)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        defer { model.shutdown() }
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "repo", path: root.path, trusted: true)]
        let gate = TrustPathGate(path: root.path)
        model.gitTrustPath = { gate.resolve($0) }
        defer { gate.release() }
        for cancel in [false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let read = Task { try await service.run(["status", "--porcelain=v2"], in: root.path, timeout: cancel ? 10 : 0.06) }
            if cancel { try await Task.sleep(for: .milliseconds(20)); read.cancel() }
            do { _ = try await read.value; XCTFail("A stopped resolution must not launch Git") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError, "\(error)") }
                else { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)") }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
            XCTAssertTrue(gate.isWaiting, "The read stops without waiting for the filesystem call")
            let processes = await service.processesRunning
            XCTAssertEqual(processes, 0)
        }
        XCTAssertEqual(gate.invocations, 1, "Concurrent or repeated reads coalesce a pending path lookup")
    }

    @MainActor func testTrustResolutionRechecksSymlinkRootsWithoutAWorkspaceRevision() async throws {
        let root = scratchRoot("git-trust-alias").resolvingSymlinksInPath()
        let child = root.appendingPathComponent("parent/child"), other = root.appendingPathComponent("other"), alias = root.appendingPathComponent("alias")
        for path in [child, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        defer { model.shutdown() }
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "parent", path: child.deletingLastPathComponent().path, trusted: true),
                            WorkspaceRecord(id: "denied", path: alias.path, trusted: false)]
        let revision = model.workspacesRevision
        let before = try await GitReadProcess.isTrusted(child.path)
        XCTAssertTrue(before)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let after = try await GitReadProcess.isTrusted(child.path)
        XCTAssertFalse(after)
        XCTAssertEqual(model.workspacesRevision, revision)
    }

    @MainActor func testNewWorkspaceRevisionDoesNotReusePendingCanonicalPaths() async throws {
        let root = scratchRoot("git-trust-pending-revision").resolvingSymlinksInPath()
        let child = root.appendingPathComponent("parent/child"), other = root.appendingPathComponent("other"), alias = root.appendingPathComponent("alias")
        for path in [child, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        defer { model.shutdown() }
        model.tabs.showsWindows = false
        model.workspaces = [WorkspaceRecord(id: "parent", path: child.deletingLastPathComponent().path, trusted: true),
                            WorkspaceRecord(id: "alias", path: alias.path, trusted: true)]
        let gate = TrustPathGate(path: alias.path, snapshotBeforeWait: true)
        model.gitTrustPath = { gate.resolve($0) }
        defer { gate.release() }
        let oldRead = Task { try await GitReadProcess.isTrusted(child.path) }
        try await eventually("The old revision has read the alias") { gate.started }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        model.workspaces[1].trusted = false
        let newRead = Task { try await GitReadProcess.isTrusted(child.path) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(gate.invocations, 1, "A new revision confines instead of repeating a blocked path lookup")
        gate.release()
        let oldTrust = try await oldRead.value, newTrust = try await newRead.value
        XCTAssertFalse(oldTrust, "The original snapshot is stale")
        XCTAssertFalse(newTrust, "The new revision must not inherit the old alias destination")
    }

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
        let siblingTrust = try await GitReadProcess.isTrusted(outer.appendingPathComponent("inner-sibling").path)
        XCTAssertTrue(siblingTrust)
        let outsideTrust = try await GitReadProcess.isTrusted(root.appendingPathComponent("outer-sibling").path)
        XCTAssertFalse(outsideTrust)
        for (index, extender) in ["\u{301}", "\u{200d}", "\u{fe0f}", "\u{1f1f8}\u{1f1ec}"].enumerated() {
            let name = extender + "repo-\(index)", repo = inner.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await service.run(["-c", "core.fsmonitor=false", "init", "-q", "--template="], in: repo.path, readOnly: false)
            try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("file"))
            _ = try await service.run(["-c", "core.fsmonitor=false", "add", "file"], in: repo.path, readOnly: false)
            let repositoryTrust = try await GitReadProcess.isTrusted(repo.path)
            let aliasTrust = try await GitReadProcess.isTrusted(alias.appendingPathComponent(name).path)
            XCTAssertFalse(repositoryTrust, name.debugDescription)
            XCTAssertFalse(aliasTrust, "A symlink retains its destination's trust")
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
        let duplicateTrust = try await GitReadProcess.isTrusted(plain.path)
        XCTAssertFalse(duplicateTrust)
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
        let surroundingTrust = try await GitReadProcess.isTrusted(root.path)
        XCTAssertFalse(surroundingTrust, "The surrounding folder is outside this project")
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

private final class TrustPathGate: @unchecked Sendable {
    let path: String
    private let snapshotBeforeWait: Bool
    private let condition = NSCondition()
    private var entered = false, released = false, calls = 0
    init(path: String, snapshotBeforeWait: Bool = false) { self.path = path; self.snapshotBeforeWait = snapshotBeforeWait }
    var invocations: Int { condition.lock(); defer { condition.unlock() }; return calls }
    var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return entered && !released }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func resolve(_ value: String) -> String {
        let snapshot = snapshotBeforeWait && value == path ? FileTab.key(for: URL(fileURLWithPath: value)) : nil
        if value == path {
            condition.lock(); entered = true; calls += 1
            while !released { condition.wait() }
            condition.unlock()
        }
        return snapshot ?? FileTab.key(for: URL(fileURLWithPath: value))
    }
}
