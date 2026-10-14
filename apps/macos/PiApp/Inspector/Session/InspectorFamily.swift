import Foundation

enum InspectorFamilyFilter: Equatable {
    case chat, family, child(String)
}

struct InspectorSubagentGroup: Equatable {
    var summary: SubagentSummary
    var requests = 0
    var cost: Double?
    var costSamples = 0
    var id: String { summary.link.delegationID }
    var title: String { summary.description.isEmpty ? "Sub-agent" : summary.description }
    var detail: String {
        let coverage = costSamples < requests ? (costSamples == 0 ? " · cost unreported" : " · cost partly unreported") : ""
        return summary.status.label + " · \(requests) request" + (requests == 1 ? "" : "s") + (cost.map { " · " + compactGatewayUSD($0) } ?? "") + coverage
    }
}

extension SubagentStatus {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .stopping: "Stopping"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .outputLimited: "Output limit reached"
        case .notExecuted: "Not executed"
        }
    }
}

/// Rebuildable Inspector relationships, including delegations with no HTTP
/// request. The helper's parent journal remains the authority for task state.
enum CaptureSubagents {
    static func prepare(_ db: CaptureDatabase) throws {
        let existed = !(try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_groups'")).isEmpty
        try db.execute("CREATE TABLE IF NOT EXISTS subagent_groups(workspace TEXT NOT NULL,owner TEXT NOT NULL,delegation TEXT NOT NULL,child TEXT NOT NULL,summary BLOB NOT NULL,updated REAL NOT NULL,PRIMARY KEY(workspace,owner,delegation),UNIQUE(workspace,child))")
        try db.execute("CREATE TABLE IF NOT EXISTS subagent_deleted(workspace TEXT NOT NULL,session TEXT NOT NULL,PRIMARY KEY(workspace,session))")
        if !existed {
            var cursor = ""
            while true {
                let page = try db.rows("SELECT id,workspace,metadata FROM attempts WHERE delegation IS NOT NULL AND id>? ORDER BY id LIMIT 256", [.text(cursor)])
                guard !page.isEmpty else { break }
                for row in page {
                    guard let id = row["id"]?.string, let workspace = row["workspace"]?.string, let bytes = row["metadata"]?.data else { throw CaptureFailure.corrupt }
                    let metadata = try JSONDecoder().decode([String: WireValue].self, from: bytes)
                    try record(scope: CaptureLineage.scope(metadata), metadata: metadata, workspace: workspace, db: db); cursor = id
                }
            }
        }
    }
    static func record(scope: RequestScope?, metadata: [String: WireValue], workspace: String, db: CaptureDatabase) throws {
        guard let link = scope?.delegation else { return }
        // Capture establishes identity when it arrives before group discovery.
        let summary = SubagentSummary(link: link, description: "", model: metadata["requestedModel"]?.string ?? "", status: .running, revision: 0)
        try record(summary, workspace: workspace, db: db, identityOnly: true)
    }
    static func record(_ summary: SubagentSummary, workspace: String, db: CaptureDatabase, identityOnly: Bool = false) throws {
        let link = summary.link
        guard link.valid, PayloadArchive.inspectorScope(workspace, link.budgetOwnerSessionID, link.childSessionID),
              summary.description.utf8.count <= 4096, summary.model.utf8.count <= 512, summary.revision >= 0 else { throw CaptureFailure.sequence }
        if !(try db.rows("SELECT session FROM subagent_deleted WHERE workspace=? AND session IN (?,?)", [.text(workspace), .text(link.budgetOwnerSessionID), .text(link.childSessionID)])).isEmpty { return }
        if let bytes = try db.rows("SELECT summary FROM subagent_groups WHERE workspace=? AND (child=? OR (owner=? AND delegation=?))", [.text(workspace),.text(link.childSessionID),.text(link.budgetOwnerSessionID),.text(link.delegationID)]).first?["summary"]?.data {
            let previous = try JSONDecoder().decode(SubagentSummary.self, from: bytes)
            guard previous.link == link else { throw CaptureFailure.sequence }
            if identityOnly || previous == summary || !summary.supersedes(previous) { return }
        }
        try db.execute("INSERT INTO subagent_groups(workspace,owner,delegation,child,summary,updated) VALUES(?,?,?,?,?,?) ON CONFLICT(workspace,owner,delegation) DO UPDATE SET summary=excluded.summary,updated=excluded.updated",
                       [.text(workspace),.text(link.budgetOwnerSessionID),.text(link.delegationID),.text(link.childSessionID),.blob(try JSONEncoder().encode(summary)),.real(Date().timeIntervalSince1970)])
    }
}

extension PayloadArchive {
    func forgetSubagentRelationships(sessionID: String, workspaceID: String) throws {
        let db = try dashboardDatabase()
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO subagent_deleted(workspace,session) VALUES(?,?)", [.text(workspaceID), .text(sessionID)])
            try db.execute("DELETE FROM subagent_groups WHERE workspace=? AND (owner=? OR child=?)", [.text(workspaceID), .text(sessionID), .text(sessionID)])
        }
    }
    func recordSubagent(_ summary: SubagentSummary, workspaceID: String) throws {
        try CaptureSubagents.record(summary, workspace: workspaceID, db: dashboardDatabase())
    }
    func inspectorSubagents(owner: String, workspaceID: String) async throws -> [InspectorSubagentGroup] {
        guard Self.inspectorScope(owner, workspaceID) else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "inspector") { engine in
            let args: [CaptureSQLValue] = [.text(owner),.text(workspaceID)]
            let stats = try engine.db.rows("SELECT delegation,COUNT(*) AS requests,COUNT(cost_usd) AS samples,SUM(cost_usd) AS cost FROM attempts WHERE budget_owner=? AND workspace=? AND metrics_retained=1 GROUP BY delegation", args)
            let byID = Dictionary(uniqueKeysWithValues: stats.compactMap { row in row["delegation"]?.string.map { ($0,row) } })
            return try engine.db.rows("SELECT summary FROM subagent_groups WHERE owner=? AND workspace=? ORDER BY rowid", args).map { row in
                guard let bytes = row["summary"]?.data else { throw CaptureFailure.corrupt }
                let summary = try JSONDecoder().decode(SubagentSummary.self, from: bytes), figures = byID[summary.link.delegationID] ?? [:]
                return InspectorSubagentGroup(summary: summary, requests: Int(figures["requests"]?.number ?? 0), cost: figures["cost"]?.double, costSamples: Int(figures["samples"]?.number ?? 0))
            }
        }
    }
}

extension SubagentSummary {
    /// Revisions order updates inside a turn. A later turn can start after an
    /// immutable terminal, while packets from older turns cannot revive it.
    func supersedes(_ previous: SubagentSummary) -> Bool {
        guard link == previous.link else { return false }
        let nextTurn = turn ?? 1, oldTurn = previous.turn ?? 1
        if nextTurn != oldTurn { return nextTurn > oldTurn }
        guard revision >= previous.revision else { return false }
        return !previous.status.terminal || status.terminal || (previous.status == .interrupted && previous.revision == 0 && revision > 0)
    }
    var presentationLabel: String {
        guard let turn else { return status.label }
        let state: String
        if deliveryState == "held" { state = "Pending for parent Resume" }
        else if parentWaiting == true && !status.terminal { state = "Waiting for sub-agent" }
        else if status == .running { state = "Running in background" }
        else if status.terminal && deliveryState == "delivered" { state = status == .completed ? "Delivered to parent" : status.label + " · delivered to parent" }
        else if status.terminal && deliveryState == "pending" { state = status.label + " · pending delivery" }
        else { state = status.label }
        return state + " · turn \(turn)"
    }
}
