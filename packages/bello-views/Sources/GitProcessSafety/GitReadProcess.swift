import Foundation

/// Untrusted folders run only Git, with no network or writes outside scratch.
/// Trusted projects keep user-configured programs; local/worktree program
/// settings are overridden using Git's stamp-checked scope/origin inventory.
public struct GitReadProcess {
    /// Snapshot app state on the main actor; resolve filesystem paths elsewhere
    /// and include that work in the invocation's cancellation and deadline.
    public typealias TrustResolver = @MainActor @Sendable (String, GitInvocation) async throws -> Bool
    @MainActor public static var resolveTrust: TrustResolver = { _, _ in false } {
        didSet { GitConfiguration.invalidate(); trust.removeAll(); trustRevision &+= 1 }
    }
    @MainActor private static var trustRevision = 0
    @MainActor private static var trust: [String: Bool] = [:]
    @MainActor public static func isTrusted(_ directory: String, invocation: GitInvocation = GitInvocation()) async throws -> Bool {
        try Task.checkCancellation(); try invocation.check()
        let revision = trustRevision
        let value = try await resolveTrust(directory, invocation)
        try Task.checkCancellation(); try invocation.check()
        guard revision == trustRevision else { return false }
        if let previous = trust[directory], previous != value { GitConfiguration.invalidate() }
        trust[directory] = value
        return value
    }
    private let scratch: URL?
    private let configuration: GitConfiguration?
    public init(_ process: Process, arguments: [String], environment: [String: String], trusted: Bool = false,
                repository: URL? = nil, invocation: GitInvocation = GitInvocation()) throws {
        try self.init(process, arguments: arguments, environment: environment, trusted: trusted, regularFilesOnly: false, repository: repository, invocation: invocation)
    }
    init(_ process: Process, arguments: [String], environment: [String: String], trusted: Bool = false,
         regularFilesOnly: Bool, repository: URL? = nil, invocation: GitInvocation = GitInvocation()) throws {
        let git = try Self.git.get()
        let arguments = Self.nonrecursive(arguments)
        var environment = environment
        var checked: GitConfiguration?
        var options: [String]?
        var configurationEnvironment = environment
        configurationEnvironment.removeValue(forKey: "GIT_INDEX_FILE")
        if trusted, let directory = repository ?? process.currentDirectoryURL {
            // Non-recursive read policy depends on config, not the private
            // index a hunk review supplies. The Git command keeps that index.
            do {
                let value = try GitConfiguration(in: directory, environment: configurationEnvironment, invocation: invocation)
                if value.permitsUnconfinedRead {
                    options = try value.readOptions(in: directory, environment: configurationEnvironment, submodules: false, invocation: invocation)
                    checked = value
                }
            } catch is GitConfiguration.ConfinementRequired {
                // Dynamic sources and unrepresentable overrides cannot prove
                // this command's config. Neither permits unconfined execution.
            }
        }
        configuration = checked
        if let options {
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
        while command < arguments.count, arguments[command].gitHasPrefix("-") {
            command += arguments[command] == "-c" ? 2 : 1
        }
        if command < arguments.count {
            // Keep the read boundary after caller-supplied display options,
            // but before path operands, so a later option cannot re-enable it.
            let end = arguments[(command + 1)...].firstIndex { $0 == "--" || $0 == "--end-of-options" } ?? arguments.endIndex
            switch arguments[command] {
            case "diff", "show", "log":
                arguments.insert(contentsOf: ["--submodule=short", "--ignore-submodules=dirty"], at: end)
            case "status":
                arguments.insert("--ignore-submodules=dirty", at: end)
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
        let bytes = data.last == 10 ? data.dropLast() : data
        let path = String(decoding: bytes, as: UTF8.self)
        guard process.terminationStatus == 0, path.gitHasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw Failure()
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The system Git could not be located for a read-only query." }
    }
}
