import Foundation

extension PayloadArchive {
    /// A session's retained requests for the session charts: every
    /// dispatched attempt, oldest first, read on the report reader's own
    /// connection so the capture writer never waits for a chart.
    func sessionStatsHistory(sessionID: String, workspaceID: String, until: Date = Date(),
                             limit: Int = SessionStatsHistory.limit) async throws -> SessionStatsHistory {
        guard [sessionID, workspaceID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }),
              until.timeIntervalSince1970.isFinite, until.timeIntervalSince1970 >= 0, limit > 0 else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "sessionStats") { engine in
            try Self.sessionStatsHistory(sessionID: sessionID, workspaceID: workspaceID, until: until, limit: limit, db: engine.db)
        }
    }

    static func sessionStatsHistory(sessionID: String, workspaceID: String, until: Date, limit: Int, db: CaptureDatabase) throws -> SessionStatsHistory {
        let scope = "session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL"
        let values: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID), .real(until.timeIntervalSince1970)]
        try Task.checkCancellation()
        let total = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE \(scope)", values).first?["n"]?.number ?? 0)
        try Task.checkCancellation()
        let rows = try db.rows("SELECT \(sessionRequestColumns) FROM attempts WHERE \(scope) ORDER BY wall DESC,id DESC LIMIT ?",
                               values + [.integer(Int64(limit))])
        let requests = try rows.reversed().map(sessionRequestSample)
        return SessionStatsHistory(requests: requests, olderRequests: max(0, total - requests.count))
    }
}

extension SessionStatsInputs {
    /// The footer's figures as they stand, and the tool calls of each turn
    /// in the loaded conversation. A walk over the loaded page's rows, made
    /// when the Inspector's charts are built — never from a view body.
    @MainActor init(footer: SessionMetrics, session: SessionDisplay) {
        gateway = footer.gateway
        work = WorkSplit(timing: footer.turnTiming)
        var calls: [String: Int] = [:]
        for message in session.messages where message.role == "assistant" {
            guard let turn = message.turn else { continue }
            calls[turn, default: 0] += message.toolCallCount ?? message.tools?.count ?? 0
        }
        toolCallsByTurn = calls
        conversationPartial = session.olderPage.available
    }
}
