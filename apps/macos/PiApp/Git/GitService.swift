import Foundation

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
}

struct GitCommitDetail: Equatable, Sendable {
    let commit: GitCommit
    let message: String
    let files: [GitStatusEntry]
    let diff: String
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

    /// Collects a pipe's bytes from its readability handler under a lock.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ bytes: Data) { lock.lock(); data.append(bytes); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    func run(_ arguments: [String], in root: String, timeout: TimeInterval = 20) async throws -> Output {
        let executable = executable
        let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        return try await Task.detached(priority: .userInitiated) { () throws -> Output in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-c", "core.quotepath=off", "-c", "color.ui=never"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
            process.environment = environment
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
            let errors = Sink()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil } else { errors.append(bytes) }
            }
            do { try process.run() } catch { throw GitFailure(message: "git could not start: \(error.localizedDescription)") }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            stderr.fileHandleForReading.readabilityHandler = nil
            errors.append(stderr.fileHandleForReading.readDataToEndOfFile())
            return Output(stdout: output, stderr: String(decoding: errors.value, as: UTF8.self), status: process.terminationStatus)
        }.value
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

    /// Unified diff of one path (or everything) against the index or HEAD.
    /// Untracked files diff against nothing so they read as additions.
    func diff(in root: String, path: String? = nil, staged: Bool, untracked: Bool = false) async throws -> String {
        if untracked, let path {
            let output = try await run(["diff", "--no-index", "--no-ext-diff", "-U3", "--", "/dev/null", path], in: root)
            guard output.status <= 1 else { throw GitFailure(message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return output.text
        }
        var arguments = ["diff", "--no-ext-diff", "-U3", "--find-renames"]
        if staged { arguments.append("--cached") }
        if let path { arguments += ["--", path] }
        return try require(await run(arguments, in: root), "Reading the diff").text
    }

    func log(in root: String, limit: Int = 50, skip: Int = 0, path: String? = nil, filter: GitLogFilter = GitLogFilter()) async throws -> [GitCommit] {
        var arguments = ["log", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P%x00%D%x1e", "-n", String(limit), "--skip", String(skip)]
        if filter.allBranches { arguments.append("--all") }
        let text = filter.text.trimmingCharacters(in: .whitespaces), author = filter.author.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { arguments += ["-i", "--grep=" + text] }
        if !author.isEmpty { arguments += ["-i", "--author=" + author] }
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

    func commitDetail(in root: String, commit: GitCommit) async throws -> GitCommitDetail {
        let message = try require(await run(["show", "--no-patch", "--format=%B", commit.hash], in: root), "Reading the commit").text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = try require(await run(["show", "--format=", "--name-status", "-z", "--find-renames", "-m", "--first-parent", commit.hash], in: root), "Reading changed files").stdout
        let diff = try require(await run(["show", "--format=", "--no-ext-diff", "-U3", "--find-renames", "-m", "--first-parent", commit.hash], in: root), "Reading the commit diff").text
        return GitCommitDetail(commit: commit, message: message, files: Self.parseNameStatus(names), diff: diff)
    }

    static func parseNameStatus(_ data: Data) -> [GitStatusEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < fields.count {
            let code = fields[index]; index += 1
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
    /// Throws away the working-tree and index changes of the given paths; untracked files are deleted.
    func discard(_ entries: [GitStatusEntry], in root: String) async throws {
        let tracked = entries.filter { !$0.untracked }.map(\.path), untracked = entries.filter(\.untracked).map(\.path)
        if !tracked.isEmpty { _ = try require(await run(["restore", "--staged", "--worktree", "--"] + tracked, in: root), "Discarding changes") }
        if !untracked.isEmpty { _ = try require(await run(["clean", "-f", "--"] + untracked, in: root), "Removing untracked files") }
    }
    /// Per-file diff of one commit, for a selected file in its detail.
    func commitDiff(in root: String, commit: GitCommit, path: String) async throws -> String {
        try require(await run(["show", "--format=", "--no-ext-diff", "-U3", "--find-renames", "-m", "--first-parent", commit.hash, "--", path], in: root), "Reading the file diff").text
    }

    func stage(_ paths: [String], in root: String) async throws {
        guard !paths.isEmpty else { return }
        _ = try require(await run(["add", "-A", "--"] + paths, in: root), "Staging")
    }
    func unstage(_ paths: [String], in root: String) async throws {
        guard !paths.isEmpty else { return }
        let output = try await run(["restore", "--staged", "--"] + paths, in: root)
        if output.status != 0 { _ = try require(await run(["reset", "-q", "HEAD", "--"] + paths, in: root), "Unstaging") }
    }
    /// Commits the staged index, or only the given paths (their working-tree
    /// state, as IntelliJ's checked files), optionally amending HEAD.
    func commit(message: String, in root: String, paths: [String] = [], amend: Bool = false) async throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitFailure(message: "Enter a commit message.") }
        var arguments = ["commit", "-q", "-m", trimmed]
        if amend { arguments.append("--amend") }
        if !paths.isEmpty {
            _ = try require(await run(["add", "-A", "--"] + paths, in: root), "Staging")
            arguments += ["--only", "--"] + paths
        }
        _ = try require(await run(arguments, in: root), "Committing")
        return try require(await run(["rev-parse", "--short", "HEAD"], in: root), "Reading HEAD").text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
