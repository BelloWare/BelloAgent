import Foundation

/// Untrusted folders run only Git, with no network or writes outside scratch.
/// Trusted projects keep user-configured programs; local/worktree program
/// settings are overridden using Git's stamp-checked scope/origin inventory.
public struct GitReadProcess {
    @MainActor public static var resolveTrust: (String) -> Bool = { _ in false } {
        didSet { GitConfiguration.invalidate(); trust.removeAll() }
    }
    @MainActor private static var trust: [String: Bool] = [:]
    @MainActor public static func isTrusted(_ directory: String) -> Bool {
        let value = resolveTrust(directory)
        if let previous = trust[directory], previous != value { GitConfiguration.invalidate() }
        trust[directory] = value
        return value
    }
    private let scratch: URL?
    private let configuration: GitConfiguration?
    public init(_ process: Process, arguments: [String], environment: [String: String], trusted: Bool = false,
                invocation: GitInvocation = GitInvocation()) throws {
        try self.init(process, arguments: arguments, environment: environment, trusted: trusted, regularFilesOnly: false, invocation: invocation)
    }
    init(_ process: Process, arguments: [String], environment: [String: String], trusted: Bool = false,
         regularFilesOnly: Bool, invocation: GitInvocation = GitInvocation()) throws {
        let git = try Self.git.get()
        let arguments = Self.nonrecursive(arguments)
        var environment = environment
        var checked: GitConfiguration?
        var configurationEnvironment = environment
        configurationEnvironment.removeValue(forKey: "GIT_INDEX_FILE")
        if trusted, let directory = process.currentDirectoryURL {
            // Non-recursive read policy depends on config, not the private
            // index a hunk review supplies. The Git command keeps that index.
            do {
                let value = try GitConfiguration(in: directory, environment: configurationEnvironment, invocation: invocation)
                if value.permitsUnconfinedRead { checked = value }
            } catch is GitConfiguration.ConfinementRequired {
                // A stream/device can return different config to this command.
                // An uncached inventory alone is not permission to execute.
            }
        }
        configuration = checked
        if let configuration = checked, let directory = process.currentDirectoryURL {
            let options = try configuration.readOptions(in: directory, environment: configurationEnvironment, submodules: false, invocation: invocation)
            scratch = nil
            process.executableURL = git
            process.arguments = ["--no-pager"] + options + arguments
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bello-git-read-" + UUID().uuidString).resolvingSymlinksInPath()
            self.scratch = scratch
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            let profile = Self.profile + (regularFilesOnly ? Self.regularFileProfile : "")
            process.arguments = ["-D", "GIT=" + git.path, "-D", "TEMP=" + scratch.path, "-p", profile, git.path,
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
    public func remove() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        // An invalidation may evict the cache while a child Git is still about
        // to read its conditional override file.
        withExtendedLifetime(configuration) {}
    }

    private static func nonrecursive(_ arguments: [String]) -> [String] {
        var arguments = arguments, command = 0
        while command < arguments.count, arguments[command].hasPrefix("-") {
            command += arguments[command] == "-c" ? 2 : 1
        }
        if command < arguments.count {
            switch arguments[command] {
            case "diff", "show", "log":
                arguments.insert(contentsOf: ["--submodule=short", "--ignore-submodules=dirty"], at: command + 1)
            case "status":
                arguments.insert("--ignore-submodules=dirty", at: command + 1)
            default: break
            }
        }
        // Inline submodule diffs and dirty-worktree inspection start child
        // Git commands without the parent's diff safety flags. Read gitlink
        // hashes only; an explicitly opened submodule gets its own policy.
        return ["-c", "diff.submodule=short", "-c", "diff.ignoreSubmodules=dirty",
                "-c", "submodule.recurse=false", "-c", "status.submoduleSummary=false"] + arguments
    }

    private static let profile = """
    (version 1)
    (allow default)
    (deny process-exec)
    (allow process-exec (literal "/usr/bin/git") (literal (param "GIT")))
    (deny network*)
    (deny file-write*)
    (allow file-write* (literal "/dev/null") (subpath (param "TEMP")))
    """

    // Inventory must not consume a FIFO or a process-specific device before
    // deciding whether the eventual command needs confinement.
    private static let regularFileProfile = """

    (deny file-read-data
        (require-not (require-any (vnode-type REGULAR-FILE)
                                 (vnode-type DIRECTORY) (literal "/dev/null"))))
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
