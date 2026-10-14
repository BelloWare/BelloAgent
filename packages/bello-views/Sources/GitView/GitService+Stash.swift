import Foundation
import CryptoKit

public struct GitStashRecord: Equatable, Sendable, Identifiable {
    public let selector: String, oid: String, message: String, branch: String
    public let date: Date
    let logFingerprint: String
    public var id: String { selector + ":" + oid }
}
public struct GitStashFile: Equatable, Sendable, Identifiable {
    public let path: String
    public let status: String
    public let untracked: Bool
    public let staged: Bool
    public var id: String { (untracked ? "untracked:" : staged ? "index:" : "worktree:") + path }
}
public struct GitStashApplyResult: Sendable {
    public let applied: Bool
    public let removed: Bool
    public let message: String
}

extension GitService {
    private func stashDirectory(in root: String) async throws -> String {
        let storage = try await run(["config", "--get", "extensions.refStorage"], in: root)
        guard storage.status == 1 || (storage.status == 0 && storage.text.trimmingCharacters(in: .newlines) == "files") else {
            throw GitFailure(message: "This stash ref store is unsupported. Manage stashes in the terminal.")
        }
        return try await branchCommand(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root).text.trimmingCharacters(in: .newlines)
    }
    static func stashFingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func stashRecords(in root: String) async throws -> [GitStashRecord] {
        let directory = try await stashDirectory(in: root)
        let before = try GitStashStore.readLog(in: directory)
        guard !before.isEmpty else { return [] }
        let output = try await branchCommand(["stash", "list", "-z", "--format=%gd%x00%H%x00%ct%x00%gs"], in: root)
        guard try GitStashStore.readLog(in: directory) == before else { throw GitFailure(message: "The stash list changed while reading. Refresh it again.") }
        let fingerprint = Self.stashFingerprint(before)
        let fields = output.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: max(0, fields.count - 3), by: 4).compactMap { index in
            let subject = fields[index + 3]
            let prefix = subject.hasPrefix("On ") ? 3 : subject.hasPrefix("WIP on ") ? 7 : 0
            let colon = subject.firstIndex(of: ":")
            let branch = prefix > 0 && colon != nil ? String(subject[subject.index(subject.startIndex, offsetBy: prefix)..<colon!]) : "Unknown branch"
            let message = prefix > 0 && colon != nil ? String(subject[subject.index(after: colon!)...]).trimmingCharacters(in: .whitespaces) : subject
            guard fields[index].hasPrefix("stash@{") else { return nil }
            return GitStashRecord(selector: fields[index], oid: fields[index + 1], message: message, branch: branch,
                                  date: Date(timeIntervalSince1970: Double(fields[index + 2]) ?? 0), logFingerprint: fingerprint)
        }
    }

    public func createStash(message: String, includeUntracked: Bool, keepIndex: Bool, in root: String) async throws -> String {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if keepIndex { arguments.append("--keep-index") }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { arguments += ["--message", message] }
        return try await branchCommand(arguments, in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stashFiles(_ stash: GitStashRecord, in root: String) async throws -> [GitStashFile] {
        try validStashOID(stash)
        let tracked = try await branchCommand(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", stash.oid + "^1", stash.oid, "--"], in: root)
        var files = Self.parseNameStatus(tracked.stdout).map { GitStashFile(path: $0.path, status: $0.badge, untracked: false, staged: false) }
        let indexed = try await branchCommand(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", stash.oid + "^1", stash.oid + "^2", "--"], in: root)
        files += Self.parseNameStatus(indexed.stdout).map { GitStashFile(path: $0.path, status: $0.badge, untracked: false, staged: true) }
        let third = try await run(["rev-parse", "--verify", stash.oid + "^3"], in: root,
                                  environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"])
        if third.status == 0 {
            let untracked = try await branchCommand(["ls-tree", "-r", "--name-only", "-z", stash.oid + "^3"], in: root)
            files += untracked.text.split(separator: "\0").map { GitStashFile(path: String($0), status: "A", untracked: true, staged: false) }
        }
        return files
    }
    public func stashDiff(_ stash: GitStashRecord, file: GitStashFile, in root: String) async throws -> [GitDiffFile] {
        try validStashOID(stash)
        var args: [String]
        if file.untracked { args = ["show", "--format=", "--root", stash.oid + "^3"] }
        else { args = ["diff", stash.oid + "^1", stash.oid + (file.staged ? "^2" : "")] }
        args += ["--src-prefix=a/", "--dst-prefix=b/", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3", "--"] + Self.literal([file.path])
        let output = try await branchCommand(args, in: root)
        // This actor is not the main actor; no parser work reaches view layout.
        return GitDiffParser.parse(output.text)
    }
    private func validStashOID(_ stash: GitStashRecord) throws {
        guard [40, 64].contains(stash.oid.count), stash.oid.allSatisfy(\.isHexDigit) else { throw GitFailure(message: "Choose the stash again.") }
    }

    public func applyStash(_ stash: GitStashRecord, pop: Bool = false, in root: String) async throws -> GitStashApplyResult {
        try validStashOID(stash)
        // Apply the immutable commit, never a moving stash@{n}. A failed apply
        // (conflicts included) does not even enter the removal transaction.
        let output = try await run(["stash", "apply", "--index", stash.oid], in: root, environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"])
        let detail = [output.text, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0 else { return GitStashApplyResult(applied: false, removed: false, message: "Git could not apply the stash cleanly. The stash was kept.\n" + detail) }
        guard pop else { return GitStashApplyResult(applied: true, removed: false, message: "Stash applied; the stash was kept.\n" + detail) }
        do {
            try await dropStash(stash, in: root)
            return GitStashApplyResult(applied: true, removed: true, message: "Stash applied and removed.\n" + detail)
        } catch {
            return GitStashApplyResult(applied: true, removed: false, message: "Stash applied, but it was kept: " + error.localizedDescription)
        }
    }

    public func dropStash(_ stash: GitStashRecord, in root: String) async throws {
        try validStashOID(stash)
        let directory = try await stashDirectory(in: root)
        try Task.checkCancellation()
        try GitStashStore.drop(stash, in: directory)
    }
}
