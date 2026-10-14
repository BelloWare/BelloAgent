import Foundation

/// The HEAD and branch shown before a history rewrite. A detached HEAD is
/// explicit, so switching branches at the same commit invalidates consent too.
public struct GitCommitTarget: Equatable, Sendable {
    public let head: String
    public let branch: String
    public init(head: String, branch: String) { self.head = head; self.branch = branch }
    public var description: String { "\(branch == "(detached)" ? "Detached HEAD" : branch) · \(head.prefix(9))" }
}

/// Bounded diagnostics, prepared off the main actor. Warnings are advisory;
/// unresolved conflicts are blocking. These checks never run commit hooks.
public struct GitCommitPreflight: Equatable, Sendable {
    public let conflicts: Int
    public let whitespace: String
    public let diagnostics: String
    public let detail: String
    public var hasWarnings: Bool { !whitespace.isEmpty || !diagnostics.isEmpty }
    public var canCommit: Bool { conflicts == 0 }
    public var summary: String {
        if conflicts > 0 { return "Resolve \(conflicts) \(conflicts == 1 ? "conflict" : "conflicts") before committing." }
        if !whitespace.isEmpty { return "Whitespace warnings · review before committing" }
        return hasWarnings ? "Git warnings · review before committing" : "No conflicts or whitespace warnings"
    }
}

extension GitService {
    func commitTarget(in root: String) async throws -> GitCommitTarget? {
        guard let head = try await headCommit(in: root) else { return nil }
        let branch = try await run(["symbolic-ref", "--quiet", "HEAD"], in: root)
        guard branch.status == 0 || branch.status == 1 else { throw GitFailure(message: "The current branch could not be read.") }
        return GitCommitTarget(head: head, branch: branch.status == 0 ? String(branch.text.trimmingCharacters(in: .newlines).dropFirst("refs/heads/".count)) : "(detached)")
    }

    func validateCommitTarget(_ expected: GitCommitTarget, in root: String) async throws {
        guard try await commitTarget(in: root) == expected else {
            throw GitFailure(message: "The last commit or branch changed since you reviewed it. Review the target and try again.")
        }
    }

    func refuseConflicts(in root: String) async throws {
        let unmerged = try await run(["ls-files", "--unmerged", "-z"], in: root)
        guard unmerged.status == 0 else { throw GitFailure(message: "The index could not be checked for conflicts.") }
        guard unmerged.stdout.isEmpty else { throw GitFailure(message: "Resolve the conflicts before committing.") }
    }

    /// Check precisely the selected scope. Checked paths compare disk with
    /// HEAD; the index scope ignores later edits on disk. Untracked files and
    /// unborn repositories compare each file with the empty file. Git applies
    /// its configured whitespace rules; no display patch is parsed or retained.
    func preflight(in root: String, content: GitCommitContent?) async throws -> GitCommitPreflight {
        let state = try await status(in: root)
        let conflicts = state.entries.filter(\.conflicted)
        if !conflicts.isEmpty {
            return GitCommitPreflight(conflicts: conflicts.count, whitespace: "", diagnostics: "", detail: conflicts.prefix(8).map(\.path).joined(separator: "\n"))
        }
        var warnings = "", diagnostics = ""
        func record(_ output: Output, noIndex: Bool = false) throws {
            // --check exits nonzero for whitespace. A failed read instead of
            // diagnostics must not be reported as a clean check.
            guard (0...3).contains(output.status) else {
                throw GitFailure(message: output.stderr.isEmpty ? "The whitespace check failed." : output.stderr)
            }
            if output.status != 0, output.text.isEmpty, !noIndex || !output.stderr.isEmpty {
                throw GitFailure(message: output.stderr.isEmpty ? "The whitespace check could not finish." : output.stderr)
            }
            if !output.text.isEmpty, warnings.utf8.count < 4_096 {
                warnings += String(decoding: output.stdout.prefix(4_096 - warnings.utf8.count), as: UTF8.self)
            }
            // A successful diff can emit configured advisory warnings, for
            // example safecrlf=warn. Keep these visible without overriding
            // the repository's policy by turning them into a fatal error.
            if !output.stderr.isEmpty, diagnostics.utf8.count < 4_096 {
                diagnostics += String(decoding: output.stderr.utf8.prefix(4_096 - diagnostics.utf8.count), as: UTF8.self)
            }
        }
        switch content {
        case .staged:
            try record(await run(["diff", "--cached", "--check", "--no-ext-diff", "--no-textconv"], in: root))
        case .files(let paths, _):
            guard !paths.isEmpty else { throw GitFailure(message: "Tick the files to commit.") }
            if let head = state.head {
                for batch in Self.batches(of: Self.literal(paths), prefix: []) {
                    try Task.checkCancellation()
                    try record(await run(["diff", "--check", "--no-ext-diff", "--no-textconv", head, "--"] + batch, in: root))
                }
            }
            let untracked = Set(state.entries.filter(\.untracked).map(\.path))
            for path in paths where state.head == nil || untracked.contains(path) {
                try Task.checkCancellation()
                let file = URL(fileURLWithPath: root).appendingPathComponent(path)
                // Deleted paths and submodules have no new text to check.
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                try record(await run(["diff", "--no-index", "--check", "--no-ext-diff", "--no-textconv", "--", "/dev/null", file.path], in: root), noIndex: true)
            }
        case nil: break // Reword changes only the message.
        }
        return GitCommitPreflight(conflicts: 0, whitespace: warnings, diagnostics: diagnostics,
                                  detail: [warnings, diagnostics].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
