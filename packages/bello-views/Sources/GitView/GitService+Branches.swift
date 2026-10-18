import Foundation
import CryptoKit

public struct GitBranchReference: Equatable, Sendable, Identifiable {
    public let ref: String, name: String, oid: String
    public let current: Bool
    public let remote: String?
    public let upstream: String?
    public let tracking: GitBranchTracking?
    public var id: String { ref }
}

public struct GitBranchTracking: Equatable, Sendable {
    public let upstream: String
    /// Nil when Git reports a missing upstream or an unfamiliar status.
    public let ahead: Int?, behind: Int?
    public let gone: Bool

    init(upstream: String, description: String) {
        self.upstream = upstream; gone = description == "[gone]"
        let counts = Self.counts(description)
        ahead = counts?.0; behind = counts?.1
    }
    private static func counts(_ value: String) -> (Int, Int)? {
        if value.isEmpty { return (0, 0) }
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        var counts: [String: Int] = [:]
        for part in value.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false) {
            let fields = part.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "ahead" || fields[0] == "behind",
                  counts[String(fields[0])] == nil, let count = Int(fields[1]), count >= 0 else { return nil }
            counts[String(fields[0])] = count
        }
        guard !counts.isEmpty else { return nil }
        return (counts["ahead"] ?? 0, counts["behind"] ?? 0)
    }
}

public struct GitBranchHead: Equatable, Sendable {
    /// Empty only when HEAD is a symbolic reference with no initial commit.
    public let oid: String
    public let ref: String?
    public var isUnborn: Bool { oid.isEmpty }
}

public struct GitBranchCatalog: Sendable {
    public let branches: [GitBranchReference]
    public let recent: [String]
    public let head: GitBranchHead
}

public struct GitBranchComparison: Sendable {
    public let current: GitBranchHead, target: GitBranchReference
    public let onlyCurrent: [GitCommit], onlyTarget: [GitCommit]
    public let currentCount: Int, targetCount: Int
}

public struct GitBranchDeletion: Sendable {
    public let branch: GitBranchReference, head: GitBranchHead
    public let unmergedCount: Int
    public let commits: [GitCommit]
}

public struct GitCheckoutObstruction: Sendable {
    public let reason: String
    public let branch: GitBranchReference, head: GitBranchHead
    public let newName: String?
    let fingerprint: String
}
public enum GitBranchCheckoutResult: Sendable {
    case switched
    case needsStash(GitCheckoutObstruction)
}

extension GitService {
    // Reads stay local even in a partial clone. No diff driver or textconv is
    // allowed to turn a read-only preview into arbitrary executable work.
    func branchCommand(_ arguments: [String], in root: String, input: Data? = nil, readOnly: Bool = true) async throws -> Output {
        let output = try await run(arguments, in: root,
                                   environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"], input: input, readOnly: readOnly)
        guard output.status == 0 else { throw GitFailure(message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Git could not complete this action (exit \(output.status))." : output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }

    public func branchHead(in root: String) async throws -> GitBranchHead {
        let object = try await run(["rev-parse", "--verify", "-q", "HEAD"], in: root)
        let symbolic = try await run(["symbolic-ref", "-q", "HEAD"], in: root)
        guard object.status == 0 || (object.status == 1 && symbolic.status == 0) else { throw GitFailure(message: "HEAD could not be read. Refresh the repository and try again.") }
        return GitBranchHead(oid: object.status == 0 ? object.text.trimmingCharacters(in: .newlines) : "",
                             ref: symbolic.status == 0 ? symbolic.text.trimmingCharacters(in: .newlines) : nil)
    }

    public func branchCatalog(in root: String) async throws -> GitBranchCatalog {
        let head = try await branchHead(in: root)
        // One actor-side metadata read for all refs. Tracking travels with the
        // catalog, so filtering, keyboard selection and layout never query Git.
        let output = try await branchCommand(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream)%00%(upstream:short)%00%(upstream:track)", "refs/heads/", "refs/remotes/"], in: root)
        let remotes = try await branchCommand(["remote"], in: root).text.split(separator: "\n").map(String.init).sorted { $0.count > $1.count }
        let branches = output.text.split(separator: "\n").compactMap { line -> GitBranchReference? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[2].isEmpty else { return nil } // origin/HEAD is an alias, not a branch
            let local = fields[0].hasPrefix("refs/heads/")
            let name = String(fields[0].dropFirst(local ? 11 : 13))
            let remote = local ? nil : remotes.first { name.hasPrefix($0 + "/") } ?? name.split(separator: "/").first.map(String.init)
            return GitBranchReference(ref: fields[0], name: name, oid: fields[1], current: fields[0] == head.ref,
                                      remote: remote, upstream: fields[3].isEmpty ? nil : fields[3],
                                      tracking: local && !fields[4].isEmpty ? GitBranchTracking(upstream: fields[4], description: fields[5]) : nil)
        }
        let log = try await run(["reflog", "show", "-n", "80", "--format=%gs", "HEAD"], in: root)
        var recent: [String] = []
        for line in log.text.split(separator: "\n") where line.hasPrefix("checkout: moving from ") {
            guard let name = line.components(separatedBy: " to ").last,
                  let branch = branches.first(where: { $0.remote == nil && $0.name == name }), !recent.contains(branch.ref) else { continue }
            recent.append(branch.ref)
            if recent.count == 8 { break }
        }
        return GitBranchCatalog(branches: branches, recent: recent, head: head)
    }

    private func requireBranch(_ branch: GitBranchReference, head: GitBranchHead? = nil, in root: String) async throws {
        guard branch.ref.hasPrefix("refs/heads/") || branch.ref.hasPrefix("refs/remotes/") else { throw GitFailure(message: "Choose a branch again.") }
        let current = try await branchCommand(["rev-parse", "--verify", "--end-of-options", branch.ref + "^{commit}"], in: root).text.trimmingCharacters(in: .newlines)
        guard current == branch.oid else { throw GitFailure(message: "The branch moved. Refresh and review it again.") }
        if let head, try await branchHead(in: root) != head { throw GitFailure(message: "HEAD changed. Refresh and choose the action again.") }
    }
    private func branchName(_ name: String, in root: String) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-"), name != "HEAD", !name.contains("@{"), !name.contains("\0") else { throw GitFailure(message: "Enter a valid branch name.") }
        _ = try await branchCommand(["check-ref-format", "refs/heads/" + name], in: root)
        return name
    }

    private func checkoutFingerprint(in root: String) async throws -> String {
        let status = try await branchCommand(["status", "--porcelain=v2", "--untracked-files=all", "-z"], in: root).stdout
        let files = try await worktreeSnapshot(in: root)
        var hash = SHA256(); hash.update(data: status); hash.update(data: Data(files.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func checkoutBranch(_ branch: GitBranchReference, from head: GitBranchHead, newName: String? = nil, in root: String) async throws -> GitBranchCheckoutResult {
        try await requireBranch(branch, head: head, in: root)
        var arguments = ["switch", "--no-guess", "--no-recurse-submodules", "--no-overwrite-ignore"]
        if let newName {
            arguments += ["-c", try await branchName(newName, in: root)]
            if branch.remote != nil { arguments.append("--track") }
            arguments += ["--", branch.remote == nil ? branch.oid : branch.ref]
        } else {
            guard branch.remote == nil else { throw GitFailure(message: "Choose a name for the new tracking branch.") }
            arguments += ["--", branch.name]
        }
        let output = try await run(arguments, in: root, environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"], readOnly: false)
        guard output.status == 0 else {
            let reason = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // Native switch's refusal is authoritative. Recovery is an offer,
            // never an automatic stash or a force checkout.
            if reason.contains("would be overwritten"), try await branchHead(in: root) == head {
                return .needsStash(GitCheckoutObstruction(reason: reason, branch: branch, head: head, newName: newName,
                                                         fingerprint: try await checkoutFingerprint(in: root)))
            }
            throw GitFailure(message: reason.isEmpty ? "Git refused the checkout." : reason)
        }
        return .switched
    }

    public func stashAndCheckout(_ obstruction: GitCheckoutObstruction, in root: String) async throws -> GitBranchCheckoutResult {
        try await requireBranch(obstruction.branch, head: obstruction.head, in: root)
        // A later edit has not been reviewed for this recovery action.
        guard try await checkoutFingerprint(in: root) == obstruction.fingerprint else {
            throw GitFailure(message: "Local changes changed since the checkout failed. Review them and try Checkout again.")
        }
        _ = try await createStash(message: "Before checkout of " + obstruction.branch.name, includeUntracked: true, keepIndex: false, in: root)
        guard try await status(in: root).entries.isEmpty else { throw GitFailure(message: "Some local changes remain. The stash was kept and checkout was stopped.") }
        return try await checkoutBranch(obstruction.branch, from: obstruction.head, newName: obstruction.newName, in: root)
    }

    @discardableResult public func renameBranch(_ branch: GitBranchReference, to name: String, in root: String) async throws -> String {
        guard branch.remote == nil else { throw GitFailure(message: "Only local branches can be renamed.") }
        let name = try await branchName(name, in: root)
        try await requireBranch(branch, in: root)
        _ = try await branchCommand(["branch", "-m", "--", branch.name, name], in: root, readOnly: false)
        return "refs/heads/" + name
    }

    public func compareBranch(_ branch: GitBranchReference, in root: String, skip: Int = 0) async throws -> GitBranchComparison {
        let head = try await branchHead(in: root)
        try await requireBranch(branch, head: head, in: root)
        return try await compareBranch(branch, current: head, in: root, skip: skip)
    }
    public func compareBranch(_ branch: GitBranchReference, current: GitBranchHead, in root: String, skip: Int = 0) async throws -> GitBranchComparison {
        guard !current.isUnborn else { throw GitFailure(message: "Create the initial commit or check out a branch before comparing history.") }
        async let ours = branchCommits(from: branch.oid, to: current.oid, in: root, skip: skip)
        async let theirs = branchCommits(from: current.oid, to: branch.oid, in: root, skip: skip)
        let counts = try await branchCommand(["rev-list", "--left-right", "--count", current.oid + "..." + branch.oid, "--"], in: root).text.split(whereSeparator: \.isWhitespace)
        return try await GitBranchComparison(current: current, target: branch, onlyCurrent: ours, onlyTarget: theirs,
                                              currentCount: Int(counts.first ?? "0") ?? 0, targetCount: Int(counts.last ?? "0") ?? 0)
    }
    private func branchCommits(from: String, to: String, in root: String, skip: Int = 0, limit: Int = 50) async throws -> [GitCommit] {
        let output = try await branchCommand(["log", "--format=%H%x00%h%x00%an%x00%cI%x00%s%x00%P%x00%D%x1e", "--max-count=\(limit)", "--skip=\(max(0, skip))", from + ".." + to, "--"], in: root)
        return Self.parseLog(output.text)
    }

    private func requireNotCheckedOut(_ branch: GitBranchReference, in root: String) async throws {
        guard branch.remote == nil else { throw GitFailure(message: "Remote branch deletion is not offered.") }
        let worktrees = try await branchCommand(["worktree", "list", "--porcelain", "-z"], in: root).text.split(separator: "\0")
        guard !worktrees.contains(Substring("branch " + branch.ref)) else { throw GitFailure(message: "This branch is checked out in a worktree. Switch that worktree to another branch first.") }
    }
    public func reviewBranchDeletion(_ branch: GitBranchReference, in root: String) async throws -> GitBranchDeletion {
        try await requireNotCheckedOut(branch, in: root)
        let head = try await branchHead(in: root)
        guard !head.isUnborn else { throw GitFailure(message: "Check out a committed branch before reviewing another branch for deletion.") }
        try await requireBranch(branch, head: head, in: root)
        let count = try await branchCommand(["rev-list", "--count", head.oid + ".." + branch.oid, "--"], in: root).text.trimmingCharacters(in: .newlines)
        return try await GitBranchDeletion(branch: branch, head: head, unmergedCount: Int(count) ?? 0,
                                            commits: branchCommits(from: head.oid, to: branch.oid, in: root, limit: 8))
    }
    @discardableResult public func deleteBranch(_ review: GitBranchDeletion, allowUnmerged: Bool = false, in root: String) async throws -> String {
        try await deleteReviewedBranch(review, allowUnmerged: allowUnmerged, in: root)
    }
    /// An optional deletion-boundary hook supports real-worktree race tests.
    @discardableResult func deleteReviewedBranch(_ review: GitBranchDeletion, allowUnmerged: Bool, in root: String,
                              beforeDeletion: (@Sendable () async throws -> Void)? = nil) async throws -> String {
        try await requireNotCheckedOut(review.branch, in: root)
        guard review.unmergedCount == 0 || allowUnmerged else { throw GitFailure(message: "This branch has commits not merged into the reviewed HEAD. Explicitly confirm their removal first.") }
        try await beforeDeletion?()
        try await requireBranch(review.branch, head: review.head, in: root)
        // Native branch deletion also protects branches reserved by rebase or
        // bisect in detached worktrees and removes the branch configuration.
        // Only the separately confirmed unmerged case may use -D.
        let force = review.unmergedCount > 0 && allowUnmerged
        _ = try await branchCommand(["branch", force ? "-D" : "-d", "--", review.branch.name], in: root, readOnly: false)
        return "Deleted branch \(review.branch.name)."
    }

}
