import Foundation

extension GitService {
    // NUL fields and records; subject punctuation (including record-separator
    // characters) cannot masquerade as another commit. %ct is the commit date.
    private static let historyFormat = "--format=%H%x00%h%x00%an%x00%ct%x00%s%x00%P%x00%D"
    public static let historyRefLimit = 2_000

    public func historyReferences(in root: String) async throws -> [GitHistoryRef] {
        let output = try await historyRun(["for-each-ref", "--sort=refname", "--count=\(Self.historyRefLimit + 1)",
                                          "--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes", "refs/tags"], in: root)
        let refs = output.text.split(separator: "\n").compactMap { line -> GitHistoryRef? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return GitHistoryRef(name: String(fields[0]), object: String(fields[1]))
        }
        guard refs.count <= Self.historyRefLimit else { throw GitFailure(message: "This repository has more than 2,000 refs. Use the current branch or all branches.") }
        return refs
    }

    public func historySnapshot(in root: String, query: GitHistoryQuery) async throws -> GitHistorySnapshot {
        _ = try query.dates.bounds()
        let tips: [String]
        switch query.scope {
        case .current:
            let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
            if head.status == 0 { tips = [head.text.trimmingCharacters(in: .whitespacesAndNewlines)] }
            else {
                // An unborn branch is empty; a missing/corrupt repository is
                // an error rather than a misleading empty history.
                _ = try await historyRun(["rev-parse", "--git-dir"], in: root)
                let symbolic = try await run(["symbolic-ref", "-q", "HEAD"], in: root)
                guard symbolic.status == 0 else { throw GitFailure(message: "The current commit could not be read.") }
                tips = []
            }
        case .all:
            let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
            let output = try await historyRun(["rev-list", "--no-walk", "--all"] + (head.status == 0 ? [head.text.trimmingCharacters(in: .whitespacesAndNewlines)] : []), in: root)
            tips = output.text.split(separator: "\n").map(String.init)
        case .reference(let name):
            guard name.hasPrefix("refs/"), !name.contains("\0"), !name.contains("\n") else { throw GitFailure(message: "Choose a branch or tag from the ref list.") }
            let output = try await historyRun(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], in: root)
            tips = [output.text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        guard tips.count <= Self.historyRefLimit else { throw GitFailure(message: "There are too many branch tips to read together. Choose one branch or tag.") }
        return GitHistorySnapshot(root: root, query: query, tips: tips)
    }

    public func historyPage(_ snapshot: GitHistorySnapshot, after cursor: GitHistoryCursor? = nil, limit: Int = 50) async throws -> GitHistoryPage {
        guard cursor == nil || (cursor?.snapshot == snapshot.id && (cursor?.offset ?? -1) >= 0) else {
            throw GitFailure(message: "The history changed. Reload before reading another page.")
        }
        guard !snapshot.tips.isEmpty else { return GitHistoryPage(commits: [], next: nil) }
        let limit = max(1, min(limit, 100_000)), skip = cursor?.offset ?? 0, query = snapshot.query
        var args = ["log", "-z", "--format=%H", "--date-order", "--no-show-signature", "--no-color", "--fixed-strings", "-i",
                    "-n", String((query.path == nil ? 0 : skip) + limit + 1)]
        // Git applies --skip before its --follow rename tracking. Walking
        // a prefix of object IDs preserves the path's old names. Full
        // subjects/authors are read for this page only, keeping each page
        // inside the existing output budget even after many long subjects.
        if query.path == nil { args += ["--skip", String(skip)] }
        if !query.message.isEmpty { args.append("--grep=" + query.message) }
        if !query.author.isEmpty { args.append("--author=" + query.author) }
        let dates = try query.dates.bounds()
        // --since alone stops a walk at an old committer timestamp and can
        // hide newer ancestors in a rebased or deliberately dated history.
        if let from = dates.from { args.append("--since-as-filter=@\(from)") }
        if let through = dates.through { args.append("--until=@\(through)") }
        if query.path != nil { args.append("--follow") }
        args += snapshot.tips
        args.append("--")
        if let path = query.path { args += Self.literal([path]) }
        let output = try await historyRun(args, in: snapshot.root)
        let ids = output.text.split(separator: "\0").dropFirst(query.path == nil ? 0 : skip).map(String.init)
        // A refresh can preserve thousands of loaded rows. Each subprocess
        // still reads at most one ordinary page's metadata, in ID order.
        // This bounds both argv and long-subject output, without retaining
        // another cache of commits or raw patches.
        var commits: [GitCommit] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let metadata = try await historyRun(["log", "--no-walk=unsorted", "-z", Self.historyFormat, "--no-show-signature", "--no-color"] + batch + ["--"], in: snapshot.root)
            commits += try Self.parseHistory(metadata.stdout)
        }
        return GitHistoryPage(commits: Array(commits.prefix(limit)),
                              next: commits.count > limit ? GitHistoryCursor(snapshot: snapshot.id, offset: skip + limit) : nil)
    }

    /// Only hexadecimal object IDs (or unambiguous abbreviations), never a
    /// revision expression and never `log <hash> -- <path>` walking backwards
    /// to a different commit. Opening a hash does not change the active filters.
    public func historyCommit(_ hash: String, in root: String) async throws -> GitCommit {
        let hash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...64).contains(hash.utf8.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw GitFailure(message: "Enter a commit hash (at least four hexadecimal characters).")
        }
        // rev-parse --verify also accepts refs named with hexadecimal text.
        // Disambiguation consults the object database only, never those refs.
        let resolved = try await historyRun(["rev-parse", "--disambiguate=" + hash.lowercased()], in: root)
        let objects = resolved.text.split(separator: "\n").map(String.init)
        guard objects.count == 1, let oid = objects.first else { throw GitFailure(message: "No unique object matches that hash. Enter more of the commit hash.") }
        let kind = try await historyRun(["cat-file", "-t", oid], in: root)
        guard kind.text.trimmingCharacters(in: .whitespacesAndNewlines) == "commit" else { throw GitFailure(message: "That hash names a Git object, not a commit.") }
        let output = try await historyRun(["show", "-s", "-z", "--no-show-signature", "--no-color", Self.historyFormat,
                                           oid, "--"], in: root)
        guard let commit = try Self.parseHistory(output.stdout).first else { throw GitFailure(message: "That commit could not be read.") }
        return commit
    }

    private func historyRun(_ args: [String], in root: String) async throws -> Output {
        let output = try await run(args, in: root)
        guard output.status == 0 else {
            throw GitFailure(message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func parseHistory(_ data: Data) throws -> [GitCommit] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 7 == 0 else { throw GitFailure(message: "Git returned incomplete history metadata. Reload to try again.") }
        return try stride(from: 0, to: fields.count, by: 7).map { index in
            let part = fields[index..<index + 7].map { String(decoding: $0, as: UTF8.self) }
            guard let seconds = TimeInterval(part[3]) else { throw GitFailure(message: "Git returned an invalid commit date.") }
            return GitCommit(hash: part[0], shortHash: part[1], author: part[2], date: Date(timeIntervalSince1970: seconds), subject: part[4],
                             parents: part[5].split(separator: " ").map(String.init),
                             refs: part[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }
}
