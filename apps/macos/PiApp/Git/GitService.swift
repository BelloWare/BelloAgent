import Foundation
import Darwin

/// One line of `git status --porcelain=v2`: a tracked change, rename or
/// untracked file. Index and worktree states are git's single-letter codes.
struct GitStatusEntry: Identifiable, Equatable, Sendable {
    let path: String
    let originalPath: String?
    let indexState: Character
    let worktreeState: Character
    let untracked: Bool
    var id: String { path }
    var staged: Bool { !untracked && indexState != "." }
    var unstaged: Bool { untracked || worktreeState != "." }
    var renamed: Bool { originalPath != nil }
    /// A rename in the index or in the working tree. Git shows it as one row
    /// with both names, and to git it is still two paths: the old name's
    /// removal and the new name's addition. A copy is not one: its source is
    /// still there, changed, in a row of its own.
    var isRename: Bool { originalPath != nil && (indexState == "R" || worktreeState == "R") }
    /// One letter for the row badge: the worktree change, else the index change.
    var badge: String {
        if untracked { return "U" }
        let state = worktreeState != "." ? worktreeState : indexState
        return String(state)
    }
    var summary: String {
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

struct GitRepositoryStatus: Equatable, Sendable {
    var branch = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var head: String?
    var entries: [GitStatusEntry] = []
    var stagedCount: Int { entries.filter(\.staged).count }
}

struct GitCommit: Identifiable, Equatable, Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    let subject: String
    let parents: [String]
    /// Branch and tag names pointing at this commit ("HEAD -> main", "origin/main", "tag: v1").
    var refs: [String] = []
    var id: String { hash }
}

struct GitStashEntry: Identifiable, Equatable, Sendable {
    let name: String
    let subject: String
    var id: String { name }
}

struct GitLogFilter: Equatable, Sendable {
    var allBranches = false
    var text = ""
    var author = ""
    /// History of one path only ("file history"), cleared from the chip above the list.
    var path: String?
}

/// Line counts for one changed path, from `--numstat`. A binary file reports no counts.
struct GitDiffStat: Equatable, Sendable {
    let added: Int
    let removed: Int
    let binary: Bool
}

/// What a commit changed, without its patch: the message, the changed paths and
/// their line counts. The patch is read separately and only when it is shown,
/// so selecting a commit never waits for megabytes of diff text.
struct GitCommitDetail: Equatable, Sendable {
    let commit: GitCommit
    let message: String
    let files: [GitStatusEntry]
    var stats: [String: GitDiffStat] = [:]
    var insertions: Int { stats.values.reduce(0) { $0 + $1.added } }
    var deletions: Int { stats.values.reduce(0) { $0 + $1.removed } }
    /// Big commits keep their patch off screen until it is asked for.
    var isLarge: Bool { files.count > 30 || insertions + deletions > 3_000 }
    var summary: String {
        let files = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(files) · +\(insertions) −\(deletions)"
    }
}

struct GitFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the system git for a project folder. Reads never touch the index;
/// stage, unstage and commit are the only writes, each an explicit action.
actor GitService {
    static let shared = GitService()
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
                                            timeout: TimeInterval, handle: RunningProcess) throws -> Output {
        let process = Process()
        process.executableURL = executable
        let all = ["-c", "core.quotepath=off", "-c", "color.ui=never"] + arguments
        // Foundation raises an uncaught Objective-C exception past its own
        // 4096-argument limit, which no `catch` can stop: refuse first.
        guard all.count <= 4_000 else { throw GitFailure(message: "Too many paths for one git command.") }
        process.arguments = all
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        defer { try? out.close(); try? err.close() }
        guard handle.adopt(process) else { throw CancellationError() }
        do { try process.run() } catch { throw GitFailure(message: "git could not start: \(error.localizedDescription)") }
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
    private static let processQueue = DispatchQueue(label: "com.belloware.PiApp.git", qos: .userInitiated, attributes: .concurrent)

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
                                       _ transform: @escaping @Sendable (Output) throws -> T) async throws -> T {
        let executable = executable, handle = RunningProcess()
        await acquireProcess()
        defer { releaseProcess() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                Self.processQueue.async {
                    do { continuation.resume(returning: try transform(try Self.execute(executable, arguments, in: root, timeout: timeout, handle: handle))) }
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
        for batch in Self.batches(of: paths, prefix: prefix) {
            _ = try require(await run(prefix + batch, in: root), what)
        }
    }

    func run(_ arguments: [String], in root: String, timeout: TimeInterval = 20) async throws -> Output {
        try await detached(arguments, in: root, timeout: timeout) { $0 }
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
        if let path { arguments += ["--", path] }
        let output = try await run(arguments, in: root)
        if output.status != 0 {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("does not have any commits") || detail.contains("bad default revision") { return [] }
            throw GitFailure(message: detail.isEmpty ? "Reading history failed." : detail)
        }
        var commits = Self.parseLog(output.text)
        // A hex filter is also tried as a hash prefix, on the first page only.
        if skip == 0, text.count >= 4, text.count <= 40, text.allSatisfy(\.isHexDigit), !commits.contains(where: { $0.hash.hasPrefix(text.lowercased()) }) {
            let byHash = try await run(["log", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P%x00%D%x1e", "-n", "1", text + "^{commit}", "--"] + (path.map { [$0] } ?? []), in: root)
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
        if let path { arguments += ["--", path] }
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
            if !paths.isEmpty { arguments += ["--"] + paths }
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
        for batch in Self.batches(of: paths, prefix: ["restore", "--staged", "--"]) {
            let output = try await run(["restore", "--staged", "--"] + batch, in: root)
            if output.status != 0 { _ = try require(await run(["reset", "-q", "HEAD", "--"] + batch, in: root), "Unstaging") }
        }
    }
    /// Commits the staged index, or only the given paths (their working-tree
    /// state, as IntelliJ's checked files), optionally amending HEAD.
    /// `staging` is what has to be staged first so git knows every path: the
    /// untracked ones. Left nil, every path is staged first, which fails for a
    /// path git has only in the index that is gone from disk, and for a staged
    /// rename's old name, which git has nowhere.
    func commit(message: String, in root: String, paths: [String] = [], staging: [String]? = nil, amend: Bool = false) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitFailure(message: "Enter a commit message.") }
        var arguments = ["commit", "-q", "-m", trimmed]
        if amend { arguments.append("--amend") }
        var pathspecFile: URL?
        defer { if let pathspecFile { try? FileManager.default.removeItem(at: pathspecFile) } }
        if !paths.isEmpty {
            try await stage(staging ?? paths, in: root)
            // One commit cannot be split, so a path list too long for argv is
            // handed to git in a file instead.
            if Self.batches(of: paths, prefix: arguments + ["--only", "--"]).count > 1, let file = try? Self.writePathspec(paths) {
                pathspecFile = file
                arguments += ["--only", "--pathspec-from-file=" + file.path, "--pathspec-file-nul"]
            } else {
                arguments += ["--only", "--"] + paths
            }
        }
        let committed = try await run(arguments, in: root)
        // Git refuses a commit that would change nothing with its status on
        // stdout and nothing on stderr, which read as "git exit 1".
        if committed.status != 0, ["nothing to commit", "nothing added to commit", "no changes added to commit"].contains(where: committed.text.contains) {
            throw GitFailure(message: paths.isEmpty ? "Nothing to commit: nothing is staged." : "Nothing to commit: the chosen files on disk match HEAD.")
        }
        _ = try require(committed, "Committing")
        return try require(await run(["rev-parse", "--short", "HEAD"], in: root), "Reading HEAD").text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
