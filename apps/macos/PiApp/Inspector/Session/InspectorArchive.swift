import Foundation

extension PayloadArchive {
    /// A session and project the Inspector may query: short, printable ids.
    nonisolated static func inspectorScope(_ values: String...) -> Bool {
        values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }
    }

    /// The session's requests for the Inspector's navigator and Overview: the
    /// newest `limit` rows' typed columns, oldest first, read on the report
    /// reader's own connection. No metadata blob is decoded.
    func inspectorRows(sessionID: String, workspaceID: String, limit: Int = 5_000) async throws -> (rows: [InspectorRequestRow], older: Int) {
        guard Self.inspectorScope(sessionID, workspaceID), limit > 0 else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "inspector") { engine in
            let db = engine.db, scope: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID)]
            try Task.checkCancellation()
            let total = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE session=? AND workspace=?", scope).first?["n"]?.number ?? 0)
            try Task.checkCancellation()
            let rows = try db.rows("SELECT \(InspectorRequestRow.columns) FROM attempts WHERE session=? AND workspace=? ORDER BY wall DESC,id DESC LIMIT ?",
                                   scope + [.integer(Int64(limit))])
            let decoded = try rows.reversed().map(InspectorRequestRow.archived)
            return (decoded, max(0, total - decoded.count))
        }
    }

    /// Changes whenever a request of the session is added or updated: the
    /// count, the latest update, the records' sizes and how many still run.
    func inspectorSignature(sessionID: String, workspaceID: String) async throws -> String {
        guard Self.inspectorScope(sessionID, workspaceID) else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "inspector") { engine in
            let row = try engine.db.rows("SELECT COUNT(*) AS n, MAX(updated) AS updated, TOTAL(length(metadata)) AS size, SUM(outcome='running') AS running FROM attempts WHERE session=? AND workspace=?",
                                         [.text(sessionID), .text(workspaceID)]).first ?? [:]
            return "\(row["n"]?.number ?? 0):\(row["updated"]?.double ?? 0):\(row["size"]?.double ?? 0):\(row["running"]?.number ?? 0)"
        }
    }

    /// Requests linked to a message in a project: the ones that produced it, newest first.
    func attempts(producing messageID: String, workspaceID: String) async throws -> [String] {
        guard Self.inspectorScope(workspaceID), !messageID.isEmpty, messageID.utf8.count <= 128 else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "inspector") { engine in
            try engine.db.rows("SELECT attempts.id AS id FROM message_links JOIN attempts ON attempts.id=message_links.attempt WHERE message_links.message=? AND message_links.role='output' AND attempts.workspace=? ORDER BY attempts.wall DESC,attempts.id DESC LIMIT 16",
                               [.text(messageID), .text(workspaceID)]).compactMap { $0["id"]?.string }
        }
    }
}
