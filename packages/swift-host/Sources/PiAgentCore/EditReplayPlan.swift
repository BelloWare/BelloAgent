import Foundation
import CryptoKit

/// Metadata-only rollback contract compiled by the helper and native retained
/// reader. It never opens a runtime, reads credentials, or invokes a tool.
struct ReplayNode: Sendable {
    var id: String
    var role: String
    var eligible = true
    var summary = false
    var dependencies: [String]?
    var summarized: [String]?
    var calls: [String] = []
    var result: String?
}
struct ReplayPlanError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason + " History is preserved; no edit was applied." }
}
struct HistoricalEditPlan: Equatable, Sendable {
    var replay: [String]
    var displayPrefix: [String]
    var sourceTimeline: String
}
struct HistoricalBranch: Codable, Sendable {
    var nativeBranchVersion = 2
    var fromMessageId: String
    var keptIds: [String]
    var selectedTimelinePrefix: [String]
    var sourceTimelineDigest: String
    var sourceJournalHead: String?
    var targetDigest: String?
}
enum EditReplayPlan {
    static func digest(_ ids: [String]) -> String {
        SHA256.hash(data: Data(ids.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func validateGroups(_ ids: [String], nodes: [String: ReplayNode]) throws {
        guard ids.count <= 100_000, Set(ids).count == ids.count else { throw ReplayPlanError(reason: "Duplicate or excessive replay identities.") }
        var pending = Set<String>()
        for id in ids {
            guard let node = nodes[id], node.eligible else { throw ReplayPlanError(reason: "Missing replay source: \(id).") }
            if node.role == "toolResult" {
                guard let result = node.result, pending.remove(result) != nil else { throw ReplayPlanError(reason: "Orphan or duplicate tool result.") }
            } else {
                guard pending.isEmpty else { throw ReplayPlanError(reason: "Incomplete assistant/tool group.") }
                guard Set(node.calls).count == node.calls.count, !node.calls.contains("") else { throw ReplayPlanError(reason: "Invalid tool call identities.") }
                pending = Set(node.calls)
            }
        }
        guard pending.isEmpty else { throw ReplayPlanError(reason: "Incomplete assistant/tool group.") }
    }
    static func prepare(target: String, nodes: [String: ReplayNode], visible: [String], context: [String]) throws -> HistoricalEditPlan {
        guard nodes.count <= 100_000, Set(visible).count == visible.count,
              let position = visible.firstIndex(of: target), nodes[target]?.role == "user", nodes[target]?.eligible == true else {
            throw ReplayPlanError(reason: "The user message is unavailable or belongs to an abandoned branch.")
        }
        let prefix = Array(visible.prefix(position))
        var replay = try prefix.compactMap { id -> String? in
            guard let node = nodes[id] else { throw ReplayPlanError(reason: "Missing historical source: \(id).") }
            return node.eligible && !node.summary ? id : nil
        }
        let safe = Set(replay)
        // Dependencies and summarized inputs have different meanings: protected
        // inputs may be dependencies without being replaced by the summary.
        var traversalBudget = 250_000
        func leaves(_ roots: [String], dependencies: Bool) -> Set<String>? {
            var active = Set<String>(), done = Set<String>(), result = Set<String>()
            var pending = roots.map { ($0, false) }
            while let (id, exiting) = pending.popLast() {
                traversalBudget -= 1; guard traversalBudget >= 0 else { return nil }
                if exiting { active.remove(id); done.insert(id); continue }
                if done.contains(id) { continue }
                guard active.insert(id).inserted, let node = nodes[id] else { return nil }
                pending.append((id, true))
                if node.summary {
                    guard let children = dependencies ? node.dependencies : node.summarized, !children.isEmpty else { return nil }
                    pending += children.map { ($0, false) }
                } else { result.insert(id) }
            }
            return result
        }
        var replaced = Set<String>()
        for id in context {
            guard let node = nodes[id], node.summary, let dependencies = node.dependencies, let summarized = node.summarized,
                  let required = leaves(dependencies, dependencies: true), let sources = leaves(summarized, dependencies: false),
                  !required.isEmpty, !sources.isEmpty, required.isSubset(of: safe), sources.isSubset(of: required),
                  sources.isDisjoint(with: replaced), let insertion = replay.firstIndex(where: { sources.contains($0) }) else { continue }
            traversalBudget -= replay.count; guard traversalBudget >= 0 else { continue }
            var candidate = replay; candidate.removeAll { sources.contains($0) }
            candidate.insert(id, at: min(insertion, candidate.count))
            // If a checkpoint would split a protocol group, use the raw prefix.
            guard (try? validateGroups(candidate, nodes: nodes)) != nil else { continue }
            replay = candidate; replaced.formUnion(sources)
        }
        try validateGroups(replay, nodes: nodes)
        let replaySet = Set(replay)
        return HistoricalEditPlan(replay: replay, displayPrefix: prefix.filter { id in
            nodes[id]?.summary != true || replaySet.contains(id)
        }, sourceTimeline: digest(visible))
    }
    static func restore(_ branch: HistoricalBranch, nodes: [String: ReplayNode], visible: [String], context: [String]) throws -> HistoricalEditPlan {
        guard branch.nativeBranchVersion == 2 else { throw ReplayPlanError(reason: "Unsupported native branch version. Update Bello Agent to read this conversation.") }
        let plan = try prepare(target: branch.fromMessageId, nodes: nodes, visible: visible, context: context)
        guard plan.replay == branch.keptIds, plan.displayPrefix == branch.selectedTimelinePrefix, plan.sourceTimeline == branch.sourceTimelineDigest else {
            throw ReplayPlanError(reason: "The branch checkpoint does not match its historical sources.")
        }
        return plan
    }
    /// A fork's visible branch ends at its latest complete replay boundary.
    /// Later physical records remain inspectable, never implicitly replayable.
    static func forkTimeline(visible: [String], boundary: [String]) -> [String] {
        let ids = Set(boundary)
        guard let end = visible.lastIndex(where: { ids.contains($0) }) else { return [] }
        return Array(visible[...end])
    }
}
