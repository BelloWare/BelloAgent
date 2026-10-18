import Foundation

/// Untrusted folders run only Git, with no network or writes outside scratch.
/// Trusted projects keep user-configured programs; local/worktree program
/// settings are overridden using Git's scope/origin inventory before each read.
public struct GitReadProcess {
    @MainActor public static var resolveTrust: (String) -> Bool = { _ in false }
    @MainActor public static func isTrusted(_ directory: String) -> Bool { resolveTrust(directory) }
    private let scratch: URL?
    public init(_ process: Process, arguments: [String], environment: [String: String], trusted: Bool = false) throws {
        let git = try Self.git.get()
        var environment = environment
        if trusted, let directory = process.currentDirectoryURL {
            let configuration = try GitConfiguration(in: directory, environment: environment)
            let options = try configuration.readOptions(in: directory, environment: environment, submodules: arguments.contains("status") || arguments.contains("diff"))
            scratch = nil
            process.executableURL = git
            process.arguments = ["--no-pager"] + options + arguments
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bello-git-read-" + UUID().uuidString).resolvingSymlinksInPath()
            self.scratch = scratch
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-D", "GIT=" + git.path, "-D", "TEMP=" + scratch.path, "-p", Self.profile, git.path,
                                 "--no-pager", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false"] + arguments
            environment["TMPDIR"] = scratch.path + "/"
        }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // Also cover Git versions without GIT_NO_LAZY_FETCH: this overrides
        // even named protocol allowances before a missing object starts a helper.
        environment["GIT_ALLOW_PROTOCOL"] = ""
        process.environment = environment
        guard (process.arguments?.count ?? 0) <= 4_000 else {
            remove()
            throw GitConfiguration.Failure("Git has too many program settings for a safe read-only query.")
        }
    }
    public func remove() { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

    private static let profile = """
    (version 1)
    (allow default)
    (deny process-exec)
    (allow process-exec (literal "/usr/bin/git") (literal (param "GIT")))
    (deny network*)
    (deny file-write*)
    (allow file-write* (literal "/dev/null") (subpath (param "TEMP")))
    """

    /// xcrun uses the selected developer tools, never PATH or repository config.
    /// Resolve before sandboxing: /usr/bin/git is only Apple's toolchain shim.
    private static let git: Result<URL, Error> = Result {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "git"]; process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        var path = String(decoding: data, as: UTF8.self)
        if path.hasSuffix("\n") { path.removeLast() }
        guard process.terminationStatus == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw Failure()
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The system Git could not be located for a read-only query." }
    }
}
