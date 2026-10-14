import Foundation

/// One visible review owns bounded patch/index/blob snapshots, never a history
/// cache. Closing or changing selection releases them.
public struct GitPatchReview: Sendable {
    public let id = UUID()
    public let root: String, path: String
    public let staged: Bool
    public let patch: GitPatch
    public let files: [GitDiffFile]
    let index: GitIndexSnapshot
    let head: String
    let blob: String
    let worktree: Data
}

extension GitService {
    func patchCommand(_ arguments: [String], in root: String, index: String? = nil) async throws -> Output {
        let output = try await run(["-c", "core.fsmonitor=false"] + arguments, in: root,
                                   environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"].merging(index.map { ["GIT_INDEX_FILE": $0] } ?? [:]) { $1 })
        guard output.status == 0 else {
            throw GitFailure(message: output.stderr.isEmpty ? "Git could not read or update this hunk." : output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try Task.checkCancellation()
        return output
    }

    public func patchReview(in root: String, path: String, staged: Bool) async throws -> GitPatchReview {
        let top = try await patchCommand(["rev-parse", "--show-toplevel"], in: root).text.trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath() == URL(fileURLWithPath: root).resolvingSymlinksInPath() else { throw GitFailure(message: "The repository changed. Refresh and review it again.") }
        let location = try await patchIndexPath(in: root)
        let snapshot = try GitIndexSnapshot.read(at: location)
        let head = try await patchCommand(["rev-parse", "--verify", "HEAD"], in: root).text.trimmingCharacters(in: .newlines)
        let privateIndex = try snapshot.copyForGit()
        defer { privateIndex.remove() }
        try await checkPatchAttributes(in: root, path: path)
        let flags = try await patchCommand(["ls-files", "-v", "-z", "--"] + Self.literal([path]), in: root, index: privateIndex.path).stdout
        guard flags.first == 72 else { throw GitFailure(message: "Use whole-file staging for sparse, assume-unchanged or untracked files.") }
        let indexed = try await patchCommand(["ls-files", "--stage", "-z", "--"] + Self.literal([path]), in: root, index: privateIndex.path).stdout
        let entry = try patchEntry(indexed, path: path, index: true)
        let committed = try await patchCommand(["ls-tree", "-z", head, "--"] + Self.literal([path]), in: root).stdout
        let base = try patchEntry(committed, path: path, index: false)
        guard entry.mode == base.mode else { throw GitFailure(message: "Use whole-file staging for mode changes.") }
        // Compare only objects here. Repository-wide status can invoke clean
        // filters on unrelated working files, so it is never used by this path.
        let names = try await patchCommand(["diff", "--cached", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", head, "--"], in: root, index: privateIndex.path)
        if let change = Self.parseNameStatus(names.stdout).first(where: { Data($0.path.utf8) == Data(path.utf8) }), change.indexState != "M" {
            throw GitFailure(message: "Use whole-file staging for additions, deletions and renames.")
        }
        let working = try GitPatchFile.read(in: root, path: path)
        guard working.mode == entry.mode else { throw GitFailure(message: "Use whole-file staging for mode changes.") }
        let old = try await patchCommand(["cat-file", "blob", staged ? base.oid : entry.oid], in: root).stdout
        let new = staged ? try await patchCommand(["cat-file", "blob", entry.oid], in: root).stdout : working.bytes
        guard !old.contains(0), !new.contains(0) else { throw GitFailure(message: "Use whole-file staging for binary files.") }
        let raw = try await makeRawPatch(before: old, after: new, path: path, mode: entry.mode)
        let patch = try GitPatch(raw: raw, path: path)
        guard patch.mode == entry.mode, try GitIndexSnapshot.read(at: location).bytes == snapshot.bytes,
              try await patchCommand(["rev-parse", "HEAD"], in: root).text.trimmingCharacters(in: .newlines) == head else {
            throw GitFailure(message: "The index or HEAD changed while reading. Refresh and review it again.")
        }
        try Task.checkCancellation()
        return GitPatchReview(root: root, path: path, staged: staged, patch: patch,
                              files: GitDiffParser.parse(String(decoding: raw, as: UTF8.self)), index: snapshot, head: head, blob: entry.oid, worktree: working.bytes)
    }

    private func patchIndexPath(in root: String) async throws -> String {
        try await patchCommand(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root).text.trimmingCharacters(in: .newlines)
    }
    private func patchEntry(_ data: Data, path: String, index: Bool) throws -> (mode: String, oid: String) {
        let entries = data.split(separator: 0)
        guard entries.count == 1, let tab = entries[0].firstIndex(of: 9), Data(entries[0][entries[0].index(after: tab)...]) == Data(path.utf8) else {
            throw GitFailure(message: "Use whole-file staging for added, deleted, renamed or conflicted files.")
        }
        let fields = String(decoding: entries[0][..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3, ["100644", "100755"].contains(fields[0]), index ? fields[2] == "0" : fields[1] == "blob" else {
            throw GitFailure(message: "Use whole-file staging for symlinks, submodules and conflicts.")
        }
        return (String(fields[0]), String(fields[index ? 1 : 2]))
    }
    private func checkPatchAttributes(in root: String, path: String) async throws {
        let attrs = try await patchCommand(["check-attr", "-z", "filter", "working-tree-encoding", "text", "eol", "ident", "diff", "--", path], in: root).stdout.split(separator: 0)
        guard attrs.count == 18, stride(from: 2, to: 15, by: 3).allSatisfy({ attrs[$0] == Data("unspecified".utf8) || attrs[$0] == Data("unset".utf8) }) else {
            throw GitFailure(message: "Use whole-file staging for files with content filters, encoding or line-ending attributes.")
        }
        guard attrs[17] == Data("unspecified".utf8) || attrs[17] == Data("set".utf8) else {
            throw GitFailure(message: "Use whole-file staging for binary files or custom diff attributes.")
        }
        let autoCRLF = try await run(["config", "--get", "core.autocrlf"], in: root)
        guard autoCRLF.status == 1 || (autoCRLF.status == 0 && ["false", "0", "no", "off"].contains(autoCRLF.text.trimmingCharacters(in: .newlines).lowercased())) else {
            throw GitFailure(message: "Use whole-file staging while automatic line-ending conversion is enabled.")
        }
    }

    /// Git compares two bounded snapshots in a private directory outside the
    /// repository, with no user configuration, attributes or executable diff
    /// drivers. Even an attribute/config change during review cannot execute a
    /// clean filter or write the working tree. The returned bytes are verbatim.
    private func makeRawPatch(before: Data, after: Data, path: String, mode: String) async throws -> Data {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bello-hunk-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        for (side, bytes) in [("a", before), ("b", after)] {
            let file = folder.appendingPathComponent(side).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode == "100755" ? 0o700 : 0o600], ofItemAtPath: file.path)
        }
        let args = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=", "--dst-prefix=", "--full-index",
                    "--diff-algorithm=myers", "--no-indent-heuristic", "--inter-hunk-context=0", "-U3", "--", "a/" + path, "b/" + path]
        let output = try await run(args, in: folder.path, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null"])
        guard output.status <= 1 else { throw GitFailure(message: "Could not read the complete raw patch. Use whole-file staging.") }
        try Task.checkCancellation()
        return output.stdout
    }

    /// Duplicate/concurrent activation cannot replay a mutation on a new index.
    public func applyHunk(_ hunk: Int, from review: GitPatchReview) async throws {
        try Task.checkCancellation()
        guard try await patchIndexPath(in: review.root) == review.index.path else {
            throw GitFailure(message: "The repository changed. Refresh and review it again.")
        }
        let transaction = try GitIndexTransaction(review.index)
        defer { transaction.finish() }
        try transaction.validate()
        let privateIndex = try review.index.copyForGit()
        defer { privateIndex.remove() }
        let head = try await patchCommand(["rev-parse", "HEAD"], in: review.root).text.trimmingCharacters(in: .newlines)
        guard head == review.head else { throw GitFailure(message: "HEAD changed since this review. Refresh and review it again.") }
        try await checkPatchAttributes(in: review.root, path: review.path)
        if !review.staged {
            let working = try GitPatchFile.read(in: review.root, path: review.path)
            guard working.bytes == review.worktree, working.mode == review.patch.mode else {
                throw GitFailure(message: "The file changed since this review. Refresh and review it again.")
            }
        }
        let blob = try await patchCommand(["cat-file", "blob", review.blob], in: review.root).stdout
        let result = try review.patch.applying(hunk: hunk, to: blob, reverse: review.staged)
        let blobFile = URL(fileURLWithPath: privateIndex.path + ".blob")
        defer { try? FileManager.default.removeItem(at: blobFile) }
        try GitPrivateIndex.write(result, to: blobFile.path)
        let oid = try await patchCommand(["hash-object", "-w", "--no-filters", "--", blobFile.path], in: review.root).text.trimmingCharacters(in: .newlines)
        _ = try await patchCommand(["-c", "core.splitIndex=false", "update-index", "--cacheinfo", review.patch.mode, oid, review.path], in: review.root, index: privateIndex.path)
        let next = try GitIndexSnapshot.read(at: privateIndex.path)
        guard try await patchCommand(["rev-parse", "HEAD"], in: review.root).text.trimmingCharacters(in: .newlines) == head else {
            throw GitFailure(message: "HEAD changed during this action. Refresh and review it again.")
        }
        try Task.checkCancellation()
        try transaction.publish(next.bytes)
    }
}
