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
        // (conflicts included) does not even attempt removal.
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
        try await dropReviewedStash(stash, in: root)
    }
    func dropReviewedStash(_ stash: GitStashRecord, in root: String,
                           beforeVerification: (@Sendable () async throws -> Void)? = nil,
                           afterVerification: (@Sendable () async throws -> Void)? = nil,
                           afterPublication: (@Sendable () async throws -> Void)? = nil) async throws {
        try validStashOID(stash)
        guard stash.selector.hasPrefix("stash@{"), stash.selector.hasSuffix("}"),
              !stash.selector.dropFirst(7).dropLast().isEmpty,
              stash.selector.dropFirst(7).dropLast().allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw GitFailure(message: "Choose the stash again.")
        }
        let directory = try await stashDirectory(in: root), reviewedLog = try GitStashStore.readLog(in: directory)
        // The fingerprint also distinguishes identical OIDs at different
        // reflog positions. Git owns all ref/reflog writes and their locks.
        guard Self.stashFingerprint(reviewedLog) == stash.logFingerprint else {
            throw GitFailure(message: "The stash list changed. Refresh and choose the stash again.")
        }
        try await beforeVerification?()
        let selected = try await run(["rev-parse", "--verify", "--end-of-options", stash.selector], in: root,
                                     environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"])
        guard selected.status == 0, selected.text.trimmingCharacters(in: .newlines) == stash.oid else {
            throw GitFailure(message: "The stash list changed. Refresh and choose the stash again.")
        }
        try Task.checkCancellation()
        try await afterVerification?()
        let dropped = try await branchCommand(["stash", "drop", "--", stash.selector], in: root)
        try await afterPublication?()
        try await confirmDropped(stash, reviewedLog: reviewedLog, output: dropped, directory: directory, in: root)
    }

    /// The checks above cannot hold Git's lock, so another writer can still
    /// save a stash before `stash drop` runs, and `stash@{n}` then names the
    /// newcomer. Afterwards Git says which commit it dropped and the reflog
    /// shows which entry went: anything but the reviewed entry is stored
    /// back (Git's own `stash store`) and the drop is refused. The reviewed
    /// stash is then still listed; nothing unreviewed is lost.
    private func confirmDropped(_ stash: GitStashRecord, reviewedLog: Data, output: Output, directory: String, in root: String) async throws {
        let entries = Self.stashLogEntries(reviewedLog), position = Int(stash.selector.dropFirst(7).dropLast()) ?? -1
        guard position >= 0, position < entries.count else { throw GitFailure(message: "The stash list changed while removing the stash. Refresh the list and check it.") }
        let reviewed = entries[entries.count - 1 - position]
        let remaining = Self.stashLogEntries((try? GitStashStore.readLog(in: directory)) ?? Data())
        let removed = remaining.filter { $0 == reviewed }.count < entries.filter { $0 == reviewed }.count
        let reported = Self.droppedOID(output.text + "\n" + output.stderr)
        if removed, reported == nil || reported == stash.oid { return }
        guard let reported, reported != stash.oid else {
            throw GitFailure(message: "The stash list changed while the stash was being removed, so Git's removal could not be matched to the stash you chose. Refresh the list and check it.")
        }
        let subject = try? await branchCommand(["show", "-s", "--format=%s", reported], in: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let restored = try? await branchCommand(["stash", "store", "-m", subject?.isEmpty == false ? subject! : "Restored stash", "--", reported], in: root)
        guard restored != nil else {
            throw GitFailure(message: "Another stash was saved while this one was being removed, and Git removed that one (\(reported)) instead. It could not be stored again; recover it in the terminal with `git stash store \(reported)`. The stash you chose was kept.")
        }
        throw GitFailure(message: "Another stash was saved while this one was being removed, and Git removed that one instead. It was stored again as the newest stash, and the stash you chose was kept. Refresh the list and choose again.")
    }
    /// Each reflog entry without its old-value field, which `--rewrite`
    /// changes on the entry after a removed one; oldest first.
    static func stashLogEntries(_ log: Data) -> [Data] {
        log.split(separator: UInt8(ascii: "\n")).map { line in
            guard let space = line.firstIndex(of: UInt8(ascii: " ")) else { return Data(line) }
            return Data(line[line.index(after: space)...])
        }
    }
    /// The commit in Git's "Dropped stash@{n} (<oid>)".
    static func droppedOID(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("Dropped ") }),
              line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
        let oid = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        return [40, 64].contains(oid.count) && oid.allSatisfy(\.isHexDigit) ? oid : nil
    }
}
