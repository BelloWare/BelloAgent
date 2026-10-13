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
        try db.execute("UPDATE attempts SET budget_owner=?,parent_session=?,parent_attempt=?,parent_assistant=?,parent_tool_call=?,delegation=? WHERE id=?",
                       fields.map { $0.map(CaptureSQLValue.text) ?? .null } + [.text(id)])
    }
    static func prepare(_ db: CaptureDatabase, migrate: Bool) throws {
        try db.transaction {
            let columns = Set(try db.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string })
            for column in ["budget_owner", "parent_session", "parent_attempt", "parent_assistant", "parent_tool_call", "delegation"] where !columns.contains(column) {
                try db.execute("ALTER TABLE attempts ADD COLUMN \(column) TEXT")
            }
            if migrate {
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
