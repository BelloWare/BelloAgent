import XCTest
import AppKit
@testable import PiApp
@testable import GitView

@MainActor final class GitBranchesFixture {
    let folder: URL, root: URL
    let service = GitService()
    var path: String { root.path }
    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bello-branches-fixture-" + UUID().uuidString)
        root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--template=", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Branch Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("credential.helper", ""), ("core.hooksPath", folder.appendingPathComponent("empty-hooks").path), ("core.fsmonitor", "false"), ("core.excludesFile", "/dev/null")] { try git(["config", key, value]) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty-hooks"), withIntermediateDirectories: true)
        try write("f.txt", "base\n"); try commit("Base")
    }
    func close() { try? FileManager.default.removeItem(at: folder) }
    @discardableResult func git(_ args: [String]) throws -> String {
        let (code, output) = try command(args)
        guard code == 0 else { throw NSError(domain: "Fixture Git: \(args.joined(separator: " ")) \(output)", code: Int(code)) }
        return output
    }
    func gitStatus(_ args: [String]) throws -> Int32 { try command(args).0 }
    private func command(_ args: [String]) throws -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = root
        p.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
    func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func commit(_ message: String) throws { try git(["add", "-A"]); try git(["commit", "-q", "-m", message]) }
    func branch(_ name: String) async throws -> GitBranchReference { let list = try await service.branchCatalog(in: path); return try XCTUnwrap(list.branches.first { $0.name == name }) }
    func divergedBranch() async throws -> GitBranchReference {
        try git(["switch", "-c", "topic"]); try write("f.txt", "topic\n"); try commit("Topic only"); try git(["switch", "main"])
        return try await branch("topic")
    }
    func snapshot() throws -> [String] { [try git(["rev-parse", "HEAD"]), try git(["ls-files", "--stage"]), try git(["diff", "--binary"]), try git(["diff", "--cached", "--binary"]), try read("f.txt")] }
    func origin(branch: String) throws {
        let bare = folder.appendingPathComponent("origin.git").path
        try git(["init", "--bare", "--template=", bare]); try git(["remote", "add", "origin", bare]); try git(["push", "origin", branch])
    }
}
