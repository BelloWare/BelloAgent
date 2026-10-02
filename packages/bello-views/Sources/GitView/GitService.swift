import Foundation
import Darwin

/// One line of `git status --porcelain=v2`: a tracked change, rename or
/// untracked file. Index and worktree states are git's single-letter codes.
public struct GitStatusEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexState: Character
    public let worktreeState: Character
    public let untracked: Bool
    public var id: String { path }
    public var staged: Bool { !untracked && indexState != "." }
    public var unstaged: Bool { untracked || worktreeState != "." }
    public var renamed: Bool { originalPath != nil }
    /// A rename in the index or in the working tree. Git shows it as one row
    /// with both names, and to git it is still two paths: the old name's
    /// removal and the new name's addition. A copy is not one: its source is
    /// still there, changed, in a row of its own.
    public var isRename: Bool { originalPath != nil && (indexState == "R" || worktreeState == "R") }
    /// One letter for the row badge: the worktree change, else the index change.
    public var badge: String {
        if untracked { return "U" }
        let state = worktreeState != "." ? worktreeState : indexState
        return String(state)
    }
    public var summary: String {
        switch badge {
        case "U": "Untracked"
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        default: "Changed"
        }
    }
}

public struct GitRepositoryStatus: Equatable, Sendable {
    public var branch = ""
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var head: String?
    public var entries: [GitStatusEntry] = []
    public var stagedCount: Int { entries.filter(\.staged).count }
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let date: Date
    public let subject: String
    public let parents: [String]
    /// Branch and tag names pointing at this commit ("HEAD -> main", "origin/main", "tag: v1").
    public var refs: [String] = []
    public var id: String { hash }
}

public struct GitStashEntry: Identifiable, Equatable, Sendable {
    public let name: String
    public let subject: String
    public var id: String { name }
}

public struct GitLogFilter: Equatable, Sendable {
    public var allBranches = false
    public var text = ""
    public var author = ""
    /// History of one path only ("file history"), cleared from the chip above the list.
    public var path: String?
    public init(allBranches: Bool = false, text: String = "", author: String = "", path: String? = nil) {
        self.allBranches = allBranches; self.text = text; self.author = author; self.path = path
    }
}

/// Line counts for one changed path, from `--numstat`. A binary file reports no counts.
public struct GitDiffStat: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let binary: Bool
}

/// What a commit changed, without its patch: the message, the changed paths and
/// their line counts. The patch is read separately and only when it is shown,
/// so selecting a commit never waits for megabytes of diff text.
public struct GitCommitDetail: Equatable, Sendable {
    public let commit: GitCommit
    public let message: String
    public let files: [GitStatusEntry]
    public var stats: [String: GitDiffStat] = [:]
    public var insertions: Int { stats.values.reduce(0) { $0 + $1.added } }
    public var deletions: Int { stats.values.reduce(0) { $0 + $1.removed } }
    /// Big commits keep their patch off screen until it is asked for.
    public var isLarge: Bool { files.count > 30 || insertions + deletions > 3_000 }
    public var summary: String {
        let files = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(files) · +\(insertions) −\(deletions)"
    }
}

/// What one commit takes: the checked files' working-tree state, or the index
/// as staged. Always said, never inferred from an empty path list.
public enum GitCommitContent: Sendable, Equatable {
    case files(paths: [String], staging: [String])
    case staged
}

public struct GitFailure: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs the system git for a project folder. Reads never touch the index;
/// stage, unstage and commit are the only writes, each an explicit action.
public actor GitService {
    public static let shared = GitService()
    private let executable = URL(fileURLWithPath: "/usr/bin/git")

    struct Output: Sendable { let stdout: Data; let stderr: String; let status: Int32
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static let ordinaryOutputLimit = 4 * 1024 * 1024
    static let patchOutputLimit = 16 * 1024 * 1024
    static let diagnosticOutputLimit = 65_536

    /// The running process, so a read whose result is no longer wanted is
    /// actually stopped. Clicking through history must not leave a queue of
    /// `git show` processes computing patches nobody will read.
    private final class RunningProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false
        private var signalled = false
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        /// False when the read was already cancelled, so nothing is launched.
        func adopt(_ value: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            process = value; return true
        }
        func stop() {
            lock.lock(); stopped = true
            guard !signalled, let running = process, running.isRunning else { lock.unlock(); return }
            signalled = true; lock.unlock()
            if running.isRunning {
                let pid = running.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { running.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if running.isRunning {
                        if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
                    }
                }
            }
        }
    }

    private static let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                                      "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]

    private nonisolated static func execute(_ executable: URL, _ arguments: [String], in root: String,
                                            timeout: TimeInterval, handle: RunningProcess,
                                            environment extra: [String: String] = [:], input: Data? = nil, gitOptions: Bool = true) throws -> Output {
        let process = Process()
        process.executableURL = executable
        let all = (gitOptions ? ["-c", "core.quotepath=off", "-c", "color.ui=never"] : []) + arguments
        // Foundation raises an uncaught Objective-C exception past its own
        // 4096-argument limit, which no `catch` can stop: refuse first.
        guard all.count <= 4_000 else { throw GitFailure(message: "Too many paths for one git command.") }
        process.arguments = all
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.environment = environment.merging(extra) { $1 }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        // A hook that reads its input (post-rewrite) is handed it on stdin;
        // everything else reads nothing.
        var stdin: Pipe?
        if input != nil { stdin = Pipe(); process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        defer { try? out.close(); try? err.close() }
        guard handle.adopt(process) else { throw CancellationError() }
        do { try process.run() } catch { throw GitFailure(message: "git could not start: \(error.localizedDescription)") }
        if let stdin, let input {
            // Written on a thread of its own while this one drains the
            // output: a long input written first would block on a full pipe
            // while git blocks on its full output, and neither would move.
            // Closed when written, so git sees the input's end.
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async { try? writer.write(contentsOf: input); try? writer.close() }
        }
        let outputLimit = arguments.contains("diff") || arguments.contains("show") ? patchOutputLimit : ordinaryOutputLimit
        let fds = [out.fileDescriptor, err.fileDescriptor]
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var streams = [Data(), Data()], eof = [false, false]
        var failure: String?, exitedAt: TimeInterval?
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + (timeout.isFinite ? min(600, max(0.01, timeout)) : 20)
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline, failure == nil { failure = "Git timed out; no partial output was applied."; handle.stop() }
            if handle.isStopped, process.isRunning { handle.stop() }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if eof.allSatisfy({ $0 }) { break }
                if now - (exitedAt ?? now) >= 0.25 {
                    failure = failure ?? "Git exited before its output pipes closed; incomplete output was not applied."; break
                }
            }
            // Both pipes drain on this dedicated worker. Neither may deadlock
            // the other, and only this worker reads or closes the descriptors.
            for index in 0..<2 where !eof[index] {
                let count = read(fds[index], &scratch, scratch.count)
                if count > 0 {
                    let limit = index == 0 ? outputLimit : diagnosticOutputLimit
                    if count > limit - streams[index].count {
                        if failure == nil {
                            failure = index == 0 ? "Git output exceeded the \(limit / 1_048_576) MiB limit. Select a smaller diff or inspect it in the terminal. No partial result was applied." : "Git diagnostics exceeded 64 KiB. No partial result was applied."
                            handle.stop()
                        }
                    } else if failure == nil { streams[index].append(contentsOf: scratch.prefix(count)) }
                } else if count == 0 { eof[index] = true }
                else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    eof[index] = true; failure = failure ?? "Git output could not be read. No partial result was applied."; handle.stop()
                }
            }
            var polls = fds.enumerated().map { pollfd(fd: eof[$0.offset] ? -1 : $0.element, events: Int16(POLLIN), revents: 0) }
            _ = poll(&polls, nfds_t(polls.count), 20)
        }
        process.waitUntilExit()
        if let failure { throw GitFailure(message: failure) }
        if handle.isStopped { throw CancellationError() }
        return Output(stdout: streams[0], stderr: String(decoding: streams[1], as: UTF8.self), status: process.terminationStatus)
    }

    /// Git's own threads. Waiting for a process is a blocking call, and a
    /// blocking call on Swift's cooperative pool takes one of its few threads
    /// out of circulation: a handful of concurrent reads would stall every
    /// other task in the app, the gateway and the transcript included. These
    /// waits happen on a queue of their own, where blocking is expected.
    private static let processQueue = DispatchQueue(label: "BelloViews.git", qos: .userInitiated, attributes: .concurrent)

    /// How many git processes may run at once. Reads are cancelled when they
    /// are superseded, but a panel in a bad state — a repository that answers
    /// slowly, a reader clicking faster than git replies — must not be able to
    /// fork without bound. Waiting for a place is asynchronous, so a task that
    /// waits holds no thread.
    static let concurrentProcesses = 8
    private var runningProcesses = 0
    private var waitingForProcess: [CheckedContinuation<Void, Never>] = []
    /// Processes running now, for the test that holds the gate shut.
    var processesRunning: Int { runningProcesses }
    private func acquireProcess() async {
        if runningProcesses < Self.concurrentProcesses { runningProcesses += 1; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitingForProcess.append(continuation)
        }
    }
    private func releaseProcess() {
        if waitingForProcess.isEmpty { runningProcesses -= 1 }
        else { waitingForProcess.removeFirst().resume() }
    }

    /// Runs git off the actor and turns its output into `T` on that same
    /// background thread, so a large patch is parsed before it crosses back and
    /// never as text on the main thread.
    private func detached<T: Sendable>(_ arguments: [String], in root: String, timeout: TimeInterval,
                                       environment: [String: String] = [:], input: Data? = nil, executable override: URL? = nil,
                                       _ transform: @escaping @Sendable (Output) throws -> T) async throws -> T {
        let executable = override ?? executable, gitOptions = override == nil, handle = RunningProcess()
        await acquireProcess()
        defer { releaseProcess() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                Self.processQueue.async {
                    do { continuation.resume(returning: try transform(try Self.execute(executable, arguments, in: root, timeout: timeout, handle: handle, environment: environment, input: input, gitOptions: gitOptions))) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { handle.stop() }
    }

    /// Foundation raises an uncaught Objective-C exception above 4096 arguments
    /// and fails the spawn above ARG_MAX bytes, so a path list is always split
    /// into runs git can actually be given. "Stage all" in a repository with
    /// thousands of changed files must not take the app down with it.
    static func batches(of paths: [String], prefix: [String]) -> [[String]] {
        let countLimit = 512, byteLimit = 128 * 1024
        var batches: [[String]] = [], current: [String] = [], bytes = prefix.reduce(0) { $0 + $1.utf8.count + 1 }
        let base = bytes
        for path in paths {
            let size = path.utf8.count + 1
            if !current.isEmpty, current.count >= countLimit || bytes + size > byteLimit {
                batches.append(current); current = []; bytes = base
            }
            current.append(path); bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
    /// Git reads every path after `--` as a pattern: "[id].txt" also names
    /// "i.txt", "*.md" every Markdown file, and a leading ":" is magic. Each
    /// path is marked literal on its own, at the command line: the global
    /// `--literal-pathspecs` would reach a commit's hooks and their patterns.
    static func literal(_ paths: [String]) -> [String] { paths.map { ":(literal)" + $0 } }
    /// A NUL-separated pathspec file for the commands that cannot be split.
    static func writePathspec(_ paths: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("pi-pathspec-" + UUID().uuidString)
        var data = Data()
        for path in paths { data.append(contentsOf: path.utf8); data.append(0) }
        try data.write(to: url, options: .atomic)
        return url
    }
    /// Runs one git command per batch of paths, stopping at the first failure.
    private func runBatched(_ prefix: [String], paths: [String], in root: String, _ what: String) async throws {
        for batch in Self.batches(of: Self.literal(paths), prefix: prefix) {
            _ = try require(await run(prefix + batch, in: root), what)
        }
    }

    func run(_ arguments: [String], in root: String, timeout: TimeInterval = 20, environment: [String: String] = [:]) async throws -> Output {
        try await detached(arguments, in: root, timeout: timeout, environment: environment) { $0 }
    }

    private func require(_ output: Output, _ what: String) throws -> Output {
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure(message: detail.isEmpty ? "\(what) failed (git exit \(output.status))." : detail)
        }
        return output
    }

    /// The repository's top level, or nil when the folder is not inside one.
    func repositoryRoot(of folder: String) async -> String? {
        guard let output = try? await run(["rev-parse", "--show-toplevel"], in: folder), output.status == 0 else { return nil }
        let top = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    func status(in root: String) async throws -> GitRepositoryStatus {
        let output = try require(await run(["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"], in: root), "Reading status")
        return Self.parseStatus(output.stdout)
    }

    static func parseStatus(_ data: Data) -> GitRepositoryStatus {
        var status = GitRepositoryStatus()
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        func next() -> String? { guard index < fields.count else { return nil }; defer { index += 1 }; return fields[index] }
        while let line = next() {
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head": status.branch = parts[1]
                case "branch.oid": status.head = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    status.ahead = Int(counts.first?.dropFirst() ?? "") ?? 0
                    status.behind = Int(counts.last?.dropFirst() ?? "") ?? 0
                default: break
                }
                continue
            }
            let columns = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            switch columns.first {
            case "1" where columns.count >= 9:
                let xy = Array(columns[1]); let path = columns[8...].joined(separator: " ")
                status.entries.append(GitStatusEntry(path: path, originalPath: nil, indexState: xy[0], worktreeState: xy[1], untracked: false))
            case "2" where columns.count >= 10:
                let xy = Array(columns[1]); let path = columns[9...].joined(separator: " ")
                let original = next() ?? ""
                status.entries.append(GitStatusEntry(path: path, originalPath: original, indexState: xy[0], worktreeState: xy[1], untracked: false))
            case "u" where columns.count >= 11:
                let path = columns[10...].joined(separator: " ")
                status.entries.append(GitStatusEntry(path: path, originalPath: nil, indexState: "U", worktreeState: "U", untracked: false))
            case "?":
                status.entries.append(GitStatusEntry(path: String(line.dropFirst(2)), originalPath: nil, indexState: ".", worktreeState: ".", untracked: true))
            default: break
            }
        }
        fields.removeAll()
        status.entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    func log(in root: String, limit: Int = 50, skip: Int = 0, path: String? = nil, filter: GitLogFilter = GitLogFilter()) async throws -> [GitCommit] {
        var arguments = ["log", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P%x00%D%x1e", "-n", String(limit), "--skip", String(skip)]
        if filter.allBranches { arguments.append("--all") }
        let text = filter.text.trimmingCharacters(in: .whitespaces), author = filter.author.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { arguments += ["-i", "--grep=" + text] }
        if !author.isEmpty { arguments += ["-i", "--author=" + author] }
        // One path's history follows renames, so a file keeps its story.
        let path = path ?? filter.path
        if path != nil { arguments.append("--follow") }
        if let path { arguments += ["--"] + Self.literal([path]) }
        let output = try await run(arguments, in: root)
        if output.status != 0 {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("does not have any commits") || detail.contains("bad default revision") { return [] }
            throw GitFailure(message: detail.isEmpty ? "Reading history failed." : detail)
        }
        var commits = Self.parseLog(output.text)
        // A hex filter is also tried as a hash prefix, on the first page only.
        if skip == 0, text.count >= 4, text.count <= 40, text.allSatisfy(\.isHexDigit), !commits.contains(where: { $0.hash.hasPrefix(text.lowercased()) }) {
            let byHash = try await run(["log", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P%x00%D%x1e", "-n", "1", text + "^{commit}", "--"] + Self.literal(path.map { [$0] } ?? []), in: root)
            if byHash.status == 0, let match = Self.parseLog(byHash.text).first {
                var show = filter.allBranches
                if !show { show = (try? await run(["merge-base", "--is-ancestor", match.hash, "HEAD"], in: root))?.status == 0 }
                if show { commits.insert(match, at: 0) }
            }
        }
        return commits
    }

    static func parseLog(_ text: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            let refs = fields.count >= 7 ? fields[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
            return GitCommit(hash: fields[0], shortHash: fields[1], author: fields[2], date: formatter.date(from: fields[3]) ?? Date(timeIntervalSince1970: 0),
                             subject: fields[4], parents: fields[5].split(separator: " ").map(String.init), refs: refs)
        }
    }

    /// The message, the changed paths and their line counts. Both reads are
    /// cheap and run together: neither asks git to produce any patch text.
    func commitDetail(in root: String, commit: GitCommit) async throws -> GitCommitDetail {
        async let named = run(["show", "--format=%B", "--name-status", "-z", "--find-renames", "-m", "--first-parent", commit.hash], in: root)
        async let counted = run(["show", "--format=", "--numstat", "-z", "--find-renames", "-m", "--first-parent", commit.hash], in: root)
        let names = try require(await named, "Reading the commit")
        let numbers = try? require(await counted, "Reading the commit stats")
        let (message, files) = Self.parseMessageAndNameStatus(names.stdout)
        return GitCommitDetail(commit: commit, message: message, files: files,
                               stats: numbers.map { Self.parseNumstat($0.stdout) } ?? [:])
    }

    /// `%B` followed by the NUL-separated name-status records of one `git show`.
    static func parseMessageAndNameStatus(_ data: Data) -> (String, [GitStatusEntry]) {
        guard let separator = data.firstIndex(of: 0) else {
            return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let message = String(decoding: data[..<separator], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (message, parseNameStatus(Data(data[data.index(after: separator)...])))
    }

    /// `--numstat -z`: "added\tremoved\tpath" per record, and for a rename the
    /// counts field ends after its tabs with the old and new paths following.
    static func parseNumstat(_ data: Data) -> [String: GitDiffStat] {
        var stats: [String: GitDiffStat] = [:]
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < fields.count {
            var record = fields[index]; index += 1
            while record.first == "\n" || record.first == "\r" { record.removeFirst() }
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let binary = parts[0] == "-" || parts[1] == "-"
            var path = parts.count >= 3 ? parts[2...].joined(separator: "\t") : ""
            if path.isEmpty {
                guard index + 1 < fields.count else { break }
                index += 1                      // the old path of a rename or copy
                path = fields[index]; index += 1
            }
            guard !path.isEmpty else { continue }
            stats[path] = GitDiffStat(added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0, binary: binary)
        }
        return stats
    }

    /// The patch of one commit, or of one path inside it, already parsed.
    func commitDiffFiles(in root: String, commit: GitCommit, path: String? = nil) async throws -> [GitDiffFile] {
        var arguments = ["show", "--format=", "--no-ext-diff", "-U3", "--find-renames", "-m", "--first-parent", commit.hash]
        if let path { arguments += ["--"] + Self.literal([path]) }
        return try await detached(arguments, in: root, timeout: 20) { output in
            guard output.status == 0 else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitFailure(message: detail.isEmpty ? "Reading the commit diff failed." : detail)
            }
            return GitDiffParser.parse(output.text)
        }
    }

    /// The working-tree or staged patch of one path, already parsed. A renamed
    /// file is asked for under both its names: given only the new one, git has
    /// nothing to match against and reports the whole file as added.
    func diffFiles(in root: String, paths: [String] = [], staged: Bool, untracked: Bool = false) async throws -> [GitDiffFile] {
        var arguments: [String]
        if untracked, let path = paths.last { arguments = ["diff", "--no-index", "--no-ext-diff", "-U3", "--", "/dev/null", path] }
        else {
            arguments = ["diff", "--no-ext-diff", "-U3", "--find-renames"]
            if staged { arguments.append("--cached") }
            if !paths.isEmpty { arguments += ["--"] + Self.literal(paths) }
        }
        let allowed: Int32 = untracked ? 1 : 0
        return try await detached(arguments, in: root, timeout: 20) { output in
            guard output.status <= allowed else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitFailure(message: detail.isEmpty ? "Reading the diff failed." : detail)
            }
            return GitDiffParser.parse(output.text)
        }
    }

    static func parseNameStatus(_ data: Data) -> [GitStatusEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < fields.count {
            // `git show` writes a newline between its header and the records.
            let code = fields[index].trimmingCharacters(in: .newlines); index += 1
            guard let state = code.first, index < fields.count else { break }
            if state == "R" || state == "C" {
                let original = fields[index]; index += 1
                guard index < fields.count else { break }
                entries.append(GitStatusEntry(path: fields[index], originalPath: original, indexState: state, worktreeState: ".", untracked: false))
            } else {
                entries.append(GitStatusEntry(path: fields[index], originalPath: nil, indexState: state, worktreeState: ".", untracked: false))
            }
            index += 1
        }
        return entries
    }

    /// What the repository ignores, relative to its top: an ignored directory
    /// is one entry ending in "/" (`--directory` does not descend into it), so
    /// even a large `node_modules` costs one line.
    func ignoredPaths(in root: String) async throws -> [String] {
        let output = try require(await run(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: root), "Listing ignored paths")
        return output.text.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }
    func branches(in root: String) async throws -> [String] {
        let output = try require(await run(["branch", "--list", "--format=%(refname:short)"], in: root), "Listing branches")
        return output.text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func checkout(_ branch: String, in root: String) async throws {
        _ = try require(await run(["switch", branch], in: root), "Switching branch")
    }
    func createBranch(_ name: String, in root: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw GitFailure(message: "Enter a branch name without spaces.") }
        _ = try require(await run(["switch", "-c", trimmed], in: root), "Creating the branch")
    }
    func stashes(in root: String) async throws -> [GitStashEntry] {
        let output = try require(await run(["stash", "list", "--format=%gd%x00%s"], in: root), "Listing stashes")
        return output.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            return GitStashEntry(name: parts[0], subject: parts[1])
        }
    }
    func stashPush(message: String, in root: String) async throws {
        var arguments = ["stash", "push", "--include-untracked"]
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-m", trimmed] }
        _ = try require(await run(arguments, in: root), "Stashing")
    }
    func stashPop(_ name: String? = nil, in root: String) async throws {
        _ = try require(await run(["stash", "pop"] + (name.map { [$0] } ?? []), in: root), "Applying the stash")
    }
    func fetch(in root: String) async throws { _ = try require(await run(["fetch", "--prune"], in: root, timeout: 120), "Fetching") }
    func pull(in root: String) async throws { _ = try require(await run(["pull", "--ff-only"], in: root, timeout: 180), "Pulling") }
    func push(in root: String) async throws { _ = try require(await run(["push"], in: root, timeout: 180), "Pushing") }
    func headMessage(in root: String) async throws -> String {
        try require(await run(["log", "-1", "--format=%B"], in: root), "Reading HEAD").text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// What an action on some rows asks of git, for `paths(_:renames:for:held:)`.
    enum PathUse { case stage, unstage, commit, discard }

    /// The paths git has to be given to act on these rows. Naming only a
    /// rename's new name commits a copy and leaves the old name's removal
    /// staged, discards into a deletion, and stages or unstages half of the
    /// rename; so the old name comes along — to an unstage while the rename is
    /// in the index, to a stage only while it is not (once the removal is
    /// staged git has the old name nowhere, and naming it is fatal), and to a
    /// commit or a discard unless `held` names it: a row of its own the action
    /// leaves alone, a new file saved where the old one was, which is not the
    /// action's to commit or overwrite. `renames` is any list holding the rows.
    static func paths(_ paths: [String], renames rows: [GitStatusEntry], for use: PathUse, held: Set<String> = []) -> [String] {
        var renames: [String: GitStatusEntry] = [:]
        for row in rows where row.isRename { renames[row.path] = row }
        guard !renames.isEmpty else { return paths }
        return paths.flatMap { path -> [String] in
            guard let row = renames[path], let old = row.originalPath else { return [path] }
            let joins = switch use {
            case .stage: row.indexState != "R"
            case .unstage: row.indexState == "R"
            case .commit, .discard: !held.contains(old)
            }
            return joins ? [old, path] : [path]
        }
    }

    /// Throws away the working-tree and index changes of the given rows;
    /// untracked files are deleted. A rename goes back to its old name; when
    /// another row, one this discard leaves alone, is `held` at that name now,
    /// only the index goes back, and the file saved there stays as it is.
    func discard(_ entries: [GitStatusEntry], in root: String, held: Set<String> = []) async throws {
        let rows = entries.filter { !$0.untracked }, untracked = entries.filter(\.untracked).map(\.path)
        let tracked = Self.paths(rows.map(\.path), renames: rows, for: .discard, held: held)
        let indexOnly = rows.compactMap { $0.isRename && $0.indexState == "R" ? $0.originalPath : nil }.filter(held.contains)
        if !indexOnly.isEmpty { try await runBatched(["restore", "--staged", "--"], paths: indexOnly, in: root, "Discarding changes") }
        if !tracked.isEmpty { try await runBatched(["restore", "--staged", "--worktree", "--"], paths: tracked, in: root, "Discarding changes") }
        if !untracked.isEmpty { try await runBatched(["clean", "-f", "--"], paths: untracked, in: root, "Removing untracked files") }
    }
    func stage(_ paths: [String], in root: String) async throws {
        guard !paths.isEmpty else { return }
        try await runBatched(["add", "-A", "--"], paths: paths, in: root, "Staging")
    }
    func unstage(_ paths: [String], in root: String) async throws {
        guard !paths.isEmpty else { return }
        for batch in Self.batches(of: Self.literal(paths), prefix: ["restore", "--staged", "--"]) {
            let output = try await run(["restore", "--staged", "--"] + batch, in: root)
            if output.status != 0 { _ = try require(await run(["reset", "-q", "HEAD", "--"] + batch, in: root), "Unstaging") }
        }
    }
    /// Commits exactly one scope, optionally amending HEAD:
    /// - `.files`: the given paths' working-tree state (IntelliJ's checked
    ///   files), whatever else is staged staying staged. `staging` is what has
    ///   to be staged first so git knows every path: the untracked ones.
    /// - `.staged`: the index as it is staged; unstaged edits stay.
    /// Neither falls back to the other: an empty path list is refused, never
    /// read as "commit the index".
    func commit(message: String, in root: String, content: GitCommitContent, amend: Bool = false) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitFailure(message: "Enter a commit message.") }
        var arguments = ["commit", "-q", "-m", trimmed]
        if amend {
            guard try await headCommit(in: root) != nil else { throw GitFailure(message: "There is no commit to amend yet.") }
            arguments.append("--amend")
        }
        var pathspecFile: URL?
        defer { if let pathspecFile { try? FileManager.default.removeItem(at: pathspecFile) } }
        switch content {
        case .files(let paths, let staging):
            guard !paths.isEmpty else { throw GitFailure(message: "Tick the files to commit.") }
            if !staging.isEmpty { try await stage(staging, in: root) }
            // One commit cannot be split, so a path list too long for argv is
            // handed to git in a file instead.
            let pathspecs = Self.literal(paths)
            if Self.batches(of: pathspecs, prefix: arguments + ["--only", "--"]).count > 1, let file = try? Self.writePathspec(pathspecs) {
                pathspecFile = file
                arguments += ["--only", "--pathspec-from-file=" + file.path, "--pathspec-file-nul"]
            } else {
                arguments += ["--only", "--"] + pathspecs
            }
        case .staged:
            // The index against HEAD (or the empty tree before the first
            // commit). An amend of an unchanged index would only reword: that
            // is Reword Last Commit's job, and it is refused here.
            let compared = try await run(["diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv"], in: root)
            guard compared.status == 1 else {
                if compared.status == 0 { throw GitFailure(message: "Nothing to commit: nothing is staged.") }
                _ = try require(compared, "Reading the index"); throw GitFailure(message: "Reading the index failed.")
            }
        }
        let committed = try await run(arguments, in: root)
        // Git refuses a commit that would change nothing with its status on
        // stdout and nothing on stderr, which read as "git exit 1".
        if committed.status != 0, ["nothing to commit", "nothing added to commit", "no changes added to commit"].contains(where: committed.text.contains) {
            if case .staged = content { throw GitFailure(message: "Nothing to commit: nothing is staged.") }
            throw GitFailure(message: "Nothing to commit: the chosen files on disk match HEAD.")
        }
        _ = try require(committed, "Committing")
        return try require(await run(["rev-parse", "--short", "HEAD"], in: root), "Reading HEAD").text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HEAD's full commit id, or nil before the first commit.
    func headCommit(in root: String) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: root)
        guard output.status == 0 else { return nil }
        let head = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }

    /// Git's "whitespace" message cleanup, as `git commit -m` applies it:
    /// trailing spaces off each line, runs of blank lines folded into one, no
    /// blank lines at either end, one final newline. Comment lines stay.
    static func cleanedMessage(_ message: String) -> String {
        var lines: [String] = []
        var blank = false
        for raw in message.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if line.isEmpty { blank = !lines.isEmpty; continue }
            if blank { lines.append("") ; blank = false }
            lines.append(line)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Changes the last commit's message and nothing else. The new commit has
    /// HEAD's tree, parents (as recorded, a shallow boundary's included) and
    /// author; the index and the working tree are never written by the
    /// reword, so staged and unstaged work stays exactly as it was. HEAD moves
    /// only if it still names `expectedHead` (the commit the reader saw), on
    /// the same branch, at that moment: a commit made or a branch switched to
    /// meanwhile is never reworded in its place.
    ///
    /// The hooks `git commit --amend` runs still run. Before the commit they
    /// see an index of the commit's own tree, not the reader's: pre-commit
    /// (a hook that changes the commit's files refuses the reword),
    /// prepare-commit-msg and commit-msg (which may edit or reject the
    /// message). A hook that changes the working tree's files refuses it too:
    /// what the hook wrote stays, and the reword says so rather than
    /// publishing over it. post-commit and post-rewrite run after.
    func reword(message: String, in root: String, expectedHead: String?) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure(message: "Enter a commit message.") }
        guard let head = try await headCommit(in: root) else { throw GitFailure(message: "There is no commit to reword yet.") }
        if let expectedHead, expectedHead != head {
            throw GitFailure(message: "The last commit changed since this panel read it. Review it and reword again.")
        }
        try await refuseDuringOperation(in: root)
        // The commit's own header: its tree and every recorded parent, also
        // where a shallow clone stops (rev-list would report none there and
        // the reword would become a new root).
        let header = try require(await run(["cat-file", "commit", head], in: root), "Reading the last commit").text
            .components(separatedBy: "\n\n").first ?? ""
        let fields = header.split(separator: "\n").map(String.init)
        guard let tree = fields.first(where: { $0.hasPrefix("tree ") }).map({ String($0.dropFirst(5)) }) else { throw GitFailure(message: "The last commit could not be read.") }
        let parents = fields.filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
        // A commit cannot be written over a parent git does not have (a
        // shallow clone's edge): refused, never rewritten as a new root.
        for parent in parents where try await run(["cat-file", "-e", parent + "^{commit}"], in: root).status != 0 {
            throw GitFailure(message: "The last commit's parent is not in this clone (it is shallow). Reword it in a full clone.")
        }
        let author = try require(await run(["log", "-1", "--format=%an%x00%ae%x00%ad", "--date=raw", head], in: root), "Reading the last commit").text
            .trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard author.count == 3 else { throw GitFailure(message: "The last commit's author could not be read.") }
        let branch = try await symbolicHead(in: root)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("pi-reword-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Hooks before the commit see an index holding exactly the commit's
        // tree: their checks run on what the commit holds, and a `git add` in
        // one lands there, never in the reader's index.
        let index = scratch.appendingPathComponent("index").path
        let hookEnvironment = ["GIT_INDEX_FILE": index, "GIT_EDITOR": ":"]
        _ = try require(await run(["read-tree", tree], in: root, environment: hookEnvironment), "Preparing the reword")
        let worktree = try await worktreeSnapshot(in: root)

        _ = try require(await run(["hook", "run", "--ignore-missing", "pre-commit"], in: root, timeout: 120, environment: hookEnvironment), "The pre-commit hook")
        let messageFile = scratch.appendingPathComponent("COMMIT_EDITMSG")
        try Data(Self.cleanedMessage(message).utf8).write(to: messageFile)
        // As git commit --amend -m calls it: a message given, amending HEAD.
        _ = try require(await run(["hook", "run", "--ignore-missing", "prepare-commit-msg", "--", messageFile.path, "message"], in: root, timeout: 120, environment: hookEnvironment), "The prepare-commit-msg hook")
        _ = try require(await run(["hook", "run", "--ignore-missing", "commit-msg", "--", messageFile.path], in: root, timeout: 120, environment: hookEnvironment), "The commit-msg hook")
        // The working tree first: a hook that wrote files and staged them
        // has done both, and the reader is told about the files on disk.
        guard try await worktreeSnapshot(in: root) == worktree else {
            throw GitFailure(message: "A hook changed files in the working tree, so the last commit was not reworded. Check what it changed.")
        }
        let after = try require(await run(["write-tree"], in: root, environment: hookEnvironment), "Preparing the reword").text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard after == tree else { throw GitFailure(message: "A hook changed the commit's files, so the last commit was not reworded.") }
        let finalMessage = Self.cleanedMessage(String(decoding: try Data(contentsOf: messageFile), as: UTF8.self))
        guard !finalMessage.isEmpty else { throw GitFailure(message: "The commit message is empty after the commit hooks.") }
        try Data(finalMessage.utf8).write(to: messageFile)

        var commitTree = ["commit-tree", tree]
        for parent in parents { commitTree += ["-p", parent] }
        // git commit signs when commit.gpgSign asks it to; commit-tree only
        // when told, so it is told the same. A setting git cannot read stops
        // the reword rather than quietly leaving the commit unsigned.
        let sign = try await run(["config", "--type=bool", "--get", "commit.gpgSign"], in: root)
        switch sign.status {
        case 0: if sign.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" { commitTree.append("-S") }
        case 1: break
        default: _ = try require(sign, "Reading commit.gpgSign")
        }
        commitTree += ["-F", messageFile.path]
        let authorEnvironment = ["GIT_AUTHOR_NAME": author[0], "GIT_AUTHOR_EMAIL": author[1], "GIT_AUTHOR_DATE": author[2]]
        let created = try require(await run(commitTree, in: root, timeout: 120, environment: authorEnvironment), "Rewording").text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hooks can take their time: HEAD must still be on the same branch,
        // with no operation begun, before anything moves.
        guard try await symbolicHead(in: root) == branch else { throw GitFailure(message: "HEAD moved to another branch while rewording, so the last commit was not reworded.") }
        try await refuseDuringOperation(in: root)
        let subject = finalMessage.split(separator: "\n").first.map(String.init) ?? ""
        let reflog = "commit (amend): " + subject
        // Compare-and-swap through HEAD itself: git locks HEAD and the branch
        // it names together, and moves that branch (or a detached HEAD) only
        // from the commit read above. Whatever HEAD names at that instant is
        // what moves; a branch HEAD has left is never rewritten behind it.
        let moved = try await run(["update-ref", "-m", reflog, "HEAD", created, head], in: root)
        guard moved.status == 0 else { throw GitFailure(message: "The last commit changed while rewording, so it was not reworded.") }

        // As after git commit --amend; their failures do not undo the commit.
        _ = try? await run(["hook", "run", "--ignore-missing", "post-commit"], in: root, timeout: 120, environment: ["GIT_EDITOR": ":"])
        try? await runPostRewrite(in: root, old: head, new: created)
        return String(created.prefix(7))
    }

    /// The branch HEAD is on (its full ref name), or nil when detached.
    private func symbolicHead(in root: String) async throws -> String? {
        let symbolic = try await run(["symbolic-ref", "-q", "HEAD"], in: root)
        return symbolic.status == 0 ? symbolic.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The files on disk, as something to compare: every tracked file and
    /// every untracked, not ignored one, as its own `lstat` — type, size,
    /// inode and change time (any write moves it, whatever git would make of
    /// the bytes), and a link's text. Nothing is opened or followed, so
    /// links, odd names and big files cost the same.
    private func worktreeSnapshot(in root: String) async throws -> String {
        let names = try require(await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root, timeout: 120), "Reading the working tree").stdout
            .split(separator: 0)
        var lines: [String] = []
        lines.reserveCapacity(names.count)
        for name in names {
            let path = (root as NSString).appendingPathComponent(String(decoding: name, as: UTF8.self))
            var info = stat()
            guard lstat(path, &info) == 0 else { lines.append("\(Array(name))|gone"); continue }
            var link = ""
            if info.st_mode & S_IFMT == S_IFLNK, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { link = target }
            lines.append("\(Array(name))|\(info.st_mode)|\(info.st_size)|\(info.st_ino)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)|\(link)")
        }
        return lines.joined(separator: "\n")
    }

    /// Git refuses to amend in the middle of a merge or a cherry-pick; a
    /// reword also waits for a rebase, a revert, a sequence or conflicts.
    private func refuseDuringOperation(in root: String) async throws {
        let states = [("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"),
                      ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"), ("sequencer", "a cherry-pick or revert sequence")]
        let paths = try require(await run(["rev-parse", "--path-format=absolute"] + states.flatMap { ["--git-path", $0.0] }, in: root), "Reading the repository").text
            .split(separator: "\n").map(String.init)
        for (path, state) in zip(paths, states) where FileManager.default.fileExists(atPath: path) {
            throw GitFailure(message: "Finish or abort \(state.1) before rewording the last commit.")
        }
        let unmerged = try require(await run(["ls-files", "-u"], in: root), "Reading the index").text
        guard unmerged.isEmpty else { throw GitFailure(message: "Resolve the conflicts before rewording the last commit.") }
    }

    /// post-rewrite reads "old new" lines on stdin, which `git hook run` in
    /// the git this app finds cannot pass on, so the hook is run directly,
    /// from the folder git would run it from.
    private func runPostRewrite(in root: String, old: String, new: String) async throws {
        let configured = try await run(["config", "--path", "--get", "core.hooksPath"], in: root)
        var folder: String
        if configured.status == 0, case let value = configured.text.trimmingCharacters(in: .newlines), !value.isEmpty {
            folder = value.hasPrefix("/") ? value : (root as NSString).appendingPathComponent(value)
        } else {
            folder = try require(await run(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], in: root), "Reading the repository").text.trimmingCharacters(in: .newlines)
        }
        let hook = (folder as NSString).appendingPathComponent("post-rewrite")
        guard FileManager.default.isExecutableFile(atPath: hook) else { return }
        _ = try await detached(["amend"], in: root, timeout: 120, input: Data("\(old) \(new)\n".utf8), executable: URL(fileURLWithPath: hook)) { $0 }
    }
}
