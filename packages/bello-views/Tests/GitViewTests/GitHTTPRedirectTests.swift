import XCTest
import Network
@testable import GitView

final class GitHTTPRedirectTests: ViewsTestCase {
    @MainActor func testAlternativeHTTPURLFormsNeverForwardPrivateHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-http-forms-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        let service = GitService(environment: environment)
        _ = try await service.run(["init", "-q", "--template="], in: root.path, readOnly: false)
        _ = try await service.run(["config", "http.extraHeader", "X-Fixture-Secret: alternate-url"], in: root.path, readOnly: false)
        for prefix in ["HTTP", "hTtP", "http::http", "https::http", "ftp::http"] {
            let url = prefix + address.dropFirst(4) + "/repo"
            _ = try await service.run(["config", "remote.origin.url", url], in: root.path, readOnly: false)
            source.answer([307], location: other + "/collect"); destination.answer([])
            do { try await service.fetch(in: root.path); XCTFail("Redirected: \(prefix)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(prefix): \(error.localizedDescription)") }
            XCTAssertEqual(source.requests.count, 1, prefix)
            XCTAssertTrue(source.requests.first?.head.lowercased().contains("x-fixture-secret: alternate-url") == true, prefix)
            XCTAssertEqual(destination.requests.count, 0, "Private header reached another origin: \(prefix)")
        }
    }

    @MainActor func testCanonicallyEquivalentRemoteNamesBothProtectTheirHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-http-unicode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
        defer { source.stop(); destination.stop() }
        let address = try await source.start(), other = try await destination.start()
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let service = GitService(environment: environment)
        _ = try await service.run(["init", "-q", "--template=", "-b", "main"], in: root.path, readOnly: false)
        let config = root.appendingPathComponent(".git/config")
        let base = try Data(contentsOf: config)
        let remotes = "\n[remote \"caf\u{00e9}\"]\nurl = \(address)/first\n[remote \"cafe\u{0301}\"]\nurl = \(address)/second\n[http]\nextraHeader = X-Fixture-Secret: unicode-remote\n"
        for (name, path) in [("caf\u{00e9}", "first"), ("cafe\u{0301}", "second")] {
            try (base + Data((remotes + "[branch \"main\"]\nremote = \(name)\n").utf8)).write(to: config)
            source.answer([307], location: other + "/collect"); destination.answer([])
            do { try await service.fetch(in: root.path); XCTFail("Redirected") }
            catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader") || error.localizedDescription.contains("configuration"), error.localizedDescription) }
            if let request = source.requests.first { XCTAssertTrue(request.head.contains("/\(path)/info/refs"), request.head) }
            XCTAssertEqual(destination.requests.count, 0, "Both byte-distinct remote names need protection")
        }
    }

    @MainActor func testHeadersAtEveryScopeAndURLScopePreventRedirects() async throws {
        for scope in ["system", "global", "local", "worktree", "include"] {
            for scopedHeader in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-http-scope-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let source = try GitRedirectReceiver(), destination = try GitRedirectReceiver()
                defer { source.stop(); destination.stop() }
                let address = try await source.start(), other = try await destination.start()
                let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_SYSTEM": root.appendingPathComponent("system").path,
                    "GIT_CONFIG_GLOBAL": root.appendingPathComponent("global").path, "GIT_TERMINAL_PROMPT": "0"]
                func git(_ arguments: [String]) throws {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.currentDirectoryURL = root; process.environment = environment; process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
                }
                try git(["init", "-q", "--template=", "-b", "main"])
                // Git still resolves a non-origin default and insteadOf.
                try git(["config", "remote.renamed.url", "fixture:repo"])
                try git(["config", "branch.main.remote", "renamed"])
                try git(["config", "url.\(address)/.insteadOf", "fixture:"])
                let key = scopedHeader ? "http.\(address)/.extraHeader" : "http.extraHeader"
                let target: [String]
                switch scope {
                case "system": target = ["--system"]
                case "global": target = ["--global"]
                case "worktree":
                    try git(["config", "extensions.worktreeConfig", "true"]); target = ["--worktree"]
                case "include":
                    let file = root.appendingPathComponent("included").path
                    try git(["config", "includeIf.gitdir:**/\(root.lastPathComponent)/.git.path", file]); target = ["--file", file]
                default: target = ["--local"]
                }
                try git(["config"] + target + [key, "X-Fixture-Secret: scoped-private-header"])
                try git(["config", "--global", "http.\(address)/repo.followRedirects", "initial"])
                source.answer([307], location: other + "/collect")
                do { try await GitService(environment: environment).fetch(in: root.path); XCTFail("Redirected") }
                catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), "\(scope): \(error)") }
                XCTAssertTrue(source.requests.first?.head.lowercased().contains("x-fixture-secret: scoped-private-header") == true, scope)
                XCTAssertEqual(destination.requests.count, 0, "\(scope), URL scoped: \(scopedHeader)")
                if scope == "local", scopedHeader {
                    // Git accepts a literal URL as the branch's default remote.
                    try git(["config", "branch.main.remote", address + "/literal"])
                    try git(["config", "http.\(address)/literal.followRedirects", "true"])
                    source.answer([308], location: other + "/collect")
                    do { try await GitService(environment: environment).pull(in: root.path); XCTFail("Redirected") }
                    catch { XCTAssertTrue(error.localizedDescription.contains("http.extraHeader"), error.localizedDescription) }
                    XCTAssertEqual(destination.requests.count, 0)
                }
            }
        }
    }

    @MainActor func testGitFetchNeverForwardsPrivateHeadersAcrossOrigins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-redirect-" + UUID().uuidString)
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
        let destination = try GitRedirectReceiver(); defer { destination.stop() }
        let other = try await destination.start(), service = GitService(environment: environment)
        for code in [301, 302, 303, 307, 308] {
            let source = try GitRedirectReceiver(); defer { source.stop() }
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-redirect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receiver = try GitRedirectReceiver(); defer { receiver.stop() }
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

}

final class GitRedirectReceiver: @unchecked Sendable {
    struct Request { let head: String; let body: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.GitRedirectReceiver")
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private var statuses: [Int] = []
    private var location: String?
    private var responseBody = ""
    private var contentType: String?
    var requests: [Request] { lock.withLock { captured } }
    func answer(_ statuses: [Int], location: String? = nil, responseBody: String = "", contentType: String? = nil) {
        lock.withLock { self.statuses = statuses; self.location = location; self.responseBody = responseBody; self.contentType = contentType; captured = [] }
    }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue); self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard error == nil else { connection.cancel(); return }
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)), let head = String(data: bytes[..<split.lowerBound], encoding: .utf8) {
                let length = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count >= split.upperBound + length {
                    let body = String(decoding: bytes[split.upperBound..<(split.upperBound + length)], as: UTF8.self)
                    let status = self.lock.withLock { () -> Int in
                        self.captured.append(Request(head: head, body: body))
                        return self.statuses.isEmpty ? 204 : self.statuses.removeFirst()
                    }
                    let (location, responseBody, contentType) = self.lock.withLock { (self.location, self.responseBody, self.contentType) }
                    let reply = Data((status == 204 ? "HTTP/1.1 204 No Content\r\n" : "HTTP/1.1 \(status) Fixture\r\nContent-Length: \(responseBody.utf8.count)\r\n") .utf8)
                        + Data((location.map { "Location: \($0)\r\n" } ?? "").utf8)
                        + Data((contentType.map { "Content-Type: \($0)\r\n" } ?? "").utf8)
                        + Data("Connection: close\r\n\r\n\(responseBody)".utf8)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if !complete { self.receive(connection, previous: bytes) } else { connection.cancel() }
        }
    }
}
