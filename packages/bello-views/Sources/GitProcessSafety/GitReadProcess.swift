import Foundation

/// Git has no switch disabling every named clean/process filter. A read runs
/// only the selected system Git and its Git children, with no network or writes
/// outside private scratch space. Config/attribute changes cannot race this
/// boundary. Required executable filters fail closed; user actions keep Git's
/// normal hooks, filters, signing and transports.
public struct GitReadProcess {
    private let scratch: URL
    public init(_ process: Process, arguments: [String], environment: [String: String]) throws {
        let git = try Self.git.get()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bello-git-read-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "GIT=" + git.path, "-D", "TEMP=" + scratch.path, "-p", Self.profile, git.path,
                             "--no-pager", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false"] + arguments
        var environment = environment
        environment["TMPDIR"] = scratch.path + "/"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        process.environment = environment
    }
    public func remove() { try? FileManager.default.removeItem(at: scratch) }

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
