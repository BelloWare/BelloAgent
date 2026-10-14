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
    static func project(_ scope: RequestScope?, id: String, db: CaptureDatabase) throws {
        guard let scope else { return }
        let link = scope.delegation
        let fields = [scope.budgetOwnerSessionID, link?.call.parentSessionID, link?.parentAttemptID,
                      link?.call.assistantMessageID, link?.call.toolCallID, link?.delegationID]
        try db.execute("UPDATE attempts SET budget_owner=?,parent_session=?,parent_attempt=?,parent_assistant=?,parent_tool_call=?,delegation=?,child_turn=?,parent_execution=? WHERE id=?",
                       fields.map { $0.map(CaptureSQLValue.text) ?? .null } + [scope.childTurn.map { .integer(Int64($0)) } ?? .null, scope.parentExecutionID.map(CaptureSQLValue.text) ?? .null, .text(id)])
        if let events = scope.agentDeliveryIDs {
            try db.execute("UPDATE attempts SET agent_delivery_ids=? WHERE id=?", [.text(String(decoding: try JSONEncoder().encode(events), as: UTF8.self)), .text(id)])
            for event in events {
                guard !event.isEmpty, event.utf8.count <= 512 else { throw CaptureFailure.sequence }
                try db.execute("INSERT OR IGNORE INTO agent_delivery_links(attempt,event) VALUES(?,?)", [.text(id), .text(event)])
            }
        }
    }
    static func prepare(_ db: CaptureDatabase, migrate: Bool) throws {
        try db.transaction {
            let columns = Set(try db.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string })
            for column in ["budget_owner", "parent_session", "parent_attempt", "parent_assistant", "parent_tool_call", "delegation"] where !columns.contains(column) {
                try db.execute("ALTER TABLE attempts ADD COLUMN \(column) TEXT")
            }
            if !columns.contains("child_turn") { try db.execute("ALTER TABLE attempts ADD COLUMN child_turn INTEGER") }
            if !columns.contains("parent_execution") { try db.execute("ALTER TABLE attempts ADD COLUMN parent_execution TEXT") }
            if !columns.contains("agent_delivery_ids") { try db.execute("ALTER TABLE attempts ADD COLUMN agent_delivery_ids TEXT") }
            try db.execute("CREATE TABLE IF NOT EXISTS agent_delivery_links(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,event TEXT NOT NULL,PRIMARY KEY(attempt,event))")
            try db.execute("CREATE INDEX IF NOT EXISTS agent_delivery_lookup ON agent_delivery_links(event,attempt)")
            if migrate || !columns.contains("child_turn") || !columns.contains("agent_delivery_ids") {
                var cursor = ""
                while true {
                    let page = try db.rows("SELECT id,metadata FROM attempts WHERE id>? ORDER BY id LIMIT 256", [.text(cursor)])
                    guard !page.isEmpty else { break }
                    for row in page {
                        guard let id = row["id"]?.string, let data = row["metadata"]?.data else { throw CaptureFailure.corrupt }
                        let metadata = try JSONDecoder().decode([String: WireValue].self, from: data)
                        try project(scope(metadata), id: id, db: db); cursor = id
                    }
                }
            }
            try db.execute("CREATE INDEX IF NOT EXISTS attempts_family ON attempts(workspace,budget_owner,wall)")
            try db.execute("CREATE INDEX IF NOT EXISTS attempts_delegation ON attempts(workspace,parent_session,parent_assistant,parent_tool_call,wall)")
        }
    }
}
