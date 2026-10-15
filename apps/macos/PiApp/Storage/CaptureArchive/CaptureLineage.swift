import Foundation

/// Capture lineage is identity, not a display hint. It is immutable for the
/// physical attempt and never changes the session used to read its body.
enum CaptureLineage {
    static func scope(_ metadata: [String: WireValue]) throws -> RequestScope? {
        guard let value = metadata["requestScope"], value != .null else { return nil }
        let scope = try JSONDecoder().decode(RequestScope.self, from: JSONEncoder().encode(value))
        guard scope.valid, scope.sourceSessionID == metadata["sessionId"]?.string,
              scope.turnID == metadata["turnId"]?.string, scope.purpose == metadata["purpose"]?.string else { throw CaptureFailure.sequence }
        return scope
    }
    static func validate(_ metadata: [String: WireValue], existing: [String: CaptureSQLValue]) throws {
        guard let data = existing["metadata"]?.data else { throw CaptureFailure.corrupt }
        let previous = try JSONDecoder().decode([String: WireValue].self, from: data)
        guard try scope(metadata) == scope(previous) else { throw CaptureFailure.sequence }
    }
    static func project(_ scope: RequestScope?, id: String, session: String, savedParents: [String]?, db: CaptureDatabase) throws {
        guard let scope else {
            if let savedParents { try projectSides(savedParents, localOwner: session, id: id, db: db) }
            return
        }
        let link = scope.delegation
        let fields = [scope.chargeOwnerSessionID, link?.call.parentSessionID, link?.parentAttemptID,
                      link?.call.assistantMessageID, link?.call.toolCallID, link?.delegationID]
        try db.execute("UPDATE attempts SET budget_owner=?,parent_session=?,parent_attempt=?,parent_assistant=?,parent_tool_call=?,delegation=?,child_turn=?,parent_execution=? WHERE id=?",
                       fields.map { $0.map(CaptureSQLValue.text) ?? .null } + [scope.childTurn.map { .integer(Int64($0)) } ?? .null, scope.parentExecutionID.map(CaptureSQLValue.text) ?? .null, .text(id)])
        try db.execute("UPDATE attempts SET local_owner=?,side_session=? WHERE id=?", [.text(scope.budgetOwnerSessionID), scope.sideParents.map { .text($0.count == 1 ? scope.budgetOwnerSessionID : $0[$0.count - 2]) } ?? .null, .text(id)])
        if scope.budgetOwnerSessionID != scope.sourceSessionID {
            try db.execute("INSERT OR IGNORE INTO family_recipients(attempt,owner,kind,child) VALUES(?,?,'subagent',?)", [.text(id),.text(scope.budgetOwnerSessionID),.text(scope.sourceSessionID)])
        }
        if let parents = savedParents ?? scope.sideParents {
            try projectSides(parents, localOwner: scope.budgetOwnerSessionID, id: id, db: db)
        }
        if let events = scope.agentDeliveryIDs {
            try db.execute("UPDATE attempts SET agent_delivery_ids=? WHERE id=?", [.text(String(decoding: try JSONEncoder().encode(events), as: UTF8.self)), .text(id)])
            for event in events {
                guard !event.isEmpty, event.utf8.count <= 512 else { throw CaptureFailure.sequence }
                try db.execute("INSERT OR IGNORE INTO agent_delivery_links(attempt,event) VALUES(?,?)", [.text(id), .text(event)])
            }
        }
    }
    static func savedSideBudgets(_ db: CaptureDatabase) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in try db.rows("SELECT workspace,side,parents FROM side_budgets") {
            guard let workspace = row["workspace"]?.string, let side = row["side"]?.string,
                  let bytes = row["parents"]?.data else { throw CaptureFailure.corrupt }
            result[workspace + "\u{0}" + side] = try JSONDecoder().decode([String].self, from: bytes)
        }
        return result
    }
    static func projectSides(_ parents: [String], localOwner: String, id: String, db: CaptureDatabase) throws {
        let owner = parents.last ?? localOwner
        try db.execute("DELETE FROM family_recipients WHERE attempt=? AND kind='side'", [.text(id)])
        let side: CaptureSQLValue = parents.isEmpty ? .null : .text(parents.count == 1 ? localOwner : parents[parents.count - 2])
        try db.execute("UPDATE attempts SET budget_owner=?,local_owner=?,side_session=? WHERE id=?", [.text(owner),.text(localOwner),side,.text(id)])
        var child = localOwner
        for parent in parents {
            try db.execute("INSERT OR IGNORE INTO family_recipients(attempt,owner,kind,child) VALUES(?,?,'side',?)", [.text(id),.text(parent),.text(child)])
            child = parent
        }
    }
    static func prepare(_ db: CaptureDatabase, migrate: Bool) throws {
        try db.transaction {
            let columns = Set(try db.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string })
            for column in ["local_owner", "side_session", "budget_owner", "parent_session", "parent_attempt", "parent_assistant", "parent_tool_call", "delegation"] where !columns.contains(column) {
                try db.execute("ALTER TABLE attempts ADD COLUMN \(column) TEXT")
            }
            if !columns.contains("child_turn") { try db.execute("ALTER TABLE attempts ADD COLUMN child_turn INTEGER") }
            if !columns.contains("parent_execution") { try db.execute("ALTER TABLE attempts ADD COLUMN parent_execution TEXT") }
            if !columns.contains("agent_delivery_ids") { try db.execute("ALTER TABLE attempts ADD COLUMN agent_delivery_ids TEXT") }
            try db.execute("CREATE TABLE IF NOT EXISTS agent_delivery_links(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,event TEXT NOT NULL,PRIMARY KEY(attempt,event))")
            try db.execute("CREATE INDEX IF NOT EXISTS agent_delivery_lookup ON agent_delivery_links(event,attempt)")
            try db.execute("CREATE TABLE IF NOT EXISTS side_budgets(workspace TEXT NOT NULL,side TEXT NOT NULL,parents BLOB NOT NULL,PRIMARY KEY(workspace,side))")
            try db.execute("CREATE TABLE IF NOT EXISTS family_recipients(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,owner TEXT NOT NULL,kind TEXT NOT NULL,child TEXT NOT NULL,PRIMARY KEY(attempt,owner))")
            try db.execute("CREATE INDEX IF NOT EXISTS family_recipients_owner ON family_recipients(owner,attempt)")
            if !columns.contains("side_session") || migrate || !columns.contains("child_turn") || !columns.contains("agent_delivery_ids") {
                let sides = try savedSideBudgets(db)
                var cursor = ""
                while true {
                    let page = try db.rows("SELECT id,session,workspace,metadata FROM attempts WHERE id>? ORDER BY id LIMIT 256", [.text(cursor)])
                    guard !page.isEmpty else { break }
                    for row in page {
                        guard let id = row["id"]?.string, let session = row["session"]?.string,
                              let workspace = row["workspace"]?.string, let data = row["metadata"]?.data else { throw CaptureFailure.corrupt }
                        let metadata = try JSONDecoder().decode([String: WireValue].self, from: data)
                        let scope = try scope(metadata)
                        try project(scope, id: id, session: session, savedParents: sides[workspace + "\u{0}" + (scope?.budgetOwnerSessionID ?? session)], db: db)
                        cursor = id
                    }
                }
            }
            try db.execute("CREATE INDEX IF NOT EXISTS attempts_family ON attempts(workspace,budget_owner,wall)")
            try db.execute("CREATE INDEX IF NOT EXISTS attempts_delegation ON attempts(workspace,parent_session,parent_assistant,parent_tool_call,wall)")
        }
    }
}
