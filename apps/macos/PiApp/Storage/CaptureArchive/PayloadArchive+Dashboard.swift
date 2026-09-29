import Foundation

// The Usage Report's part of the archive: the columns it adds to `attempts`,
// the projection that fills them from each request's metadata, and the
// report's reads, run on its own connection (`DashboardReader`,
// `DashboardQueryEngine`, Dashboard/).

extension PayloadArchive {
    static func prepareDashboardSchema(_ db: CaptureDatabase, migrate: Bool) throws {
        let names = Set(try db.rows("PRAGMA table_info(attempts)").compactMap { $0["name"]?.string })
        let required: Set<String> = ["dispatch", "ttft_ms", "stream_ms", "request_ms", "http_ms", "cost_usd", "cache_read_tokens", "cache_write_tokens", "input_tokens", "output_tokens", "reasoning_tokens", "reasoning_cost_usd", "identity_status", "cost_status", "cache_status", "reasoning_cost_status", "reported_models", "response_model"]
        let projectionVersion = Data([7])
        let savedProjection = try db.rows("SELECT value FROM archive_info WHERE name='dashboard-projection'").first?["value"]?.data
        let needsProjection = migrate || !required.isSubset(of: names) || savedProjection != projectionVersion
        // Invalidate before the first ALTER. A process loss after the final
        // column or any committed batch must resume projection on next open.
        if needsProjection { try db.execute("DELETE FROM archive_info WHERE name='dashboard-projection'") }
        var added = false
        for name in ["dispatch", "ttft_ms", "stream_ms", "request_ms", "http_ms", "cost_usd", "cache_read_tokens", "cache_write_tokens", "input_tokens", "output_tokens", "reasoning_tokens", "reasoning_cost_usd"] where !names.contains(name) {
            try db.execute("ALTER TABLE attempts ADD COLUMN \(name) REAL"); added = true
        }
        if !names.contains("identity_status") {
            try db.execute("ALTER TABLE attempts ADD COLUMN identity_status TEXT NOT NULL DEFAULT 'unreported'"); added = true
        }
        for name in ["cost_status", "cache_status", "reasoning_cost_status"] where !names.contains(name) {
            try db.execute("ALTER TABLE attempts ADD COLUMN \(name) TEXT NOT NULL DEFAULT 'unreported'"); added = true
        }
        if !names.contains("reported_models") {
            try db.execute("ALTER TABLE attempts ADD COLUMN reported_models TEXT"); added = true
        }
        if !names.contains("response_model") {
            try db.execute("ALTER TABLE attempts ADD COLUMN response_model TEXT"); added = true
        }
        try db.execute("CREATE INDEX IF NOT EXISTS dashboard_window ON attempts(metrics_retained,wall,dispatch,outcome)")
        try db.execute("CREATE INDEX IF NOT EXISTS accounting_session ON attempts(session,workspace,metrics_retained,dispatch)")
        // Session distributions also bound wall time. Without this index SQLite
        // prefers the global time window and visits unrelated sessions.
        try db.execute("CREATE INDEX IF NOT EXISTS usage_session ON attempts(session,workspace,metrics_retained,wall,dispatch)")
        try db.execute("CREATE INDEX IF NOT EXISTS accounting_turn ON attempts(workspace,session,turn,metrics_retained,dispatch)")
        // A bounded migration never loads every retained metadata blob. Old
        // timing contracts stay unobserved; we do not reinterpret their clocks.
        if added || needsProjection {
            var after = ""
            while true {
                let rows = try db.rows("SELECT id,metadata FROM attempts WHERE metrics_retained=1 AND id>? ORDER BY id LIMIT 32", [.text(after)])
                guard !rows.isEmpty else { break }
                try db.transaction {
                    for row in rows {
                        guard let id = row["id"]?.string, let data = row["metadata"]?.data else { throw CaptureFailure.corrupt }
                        let value = try JSONDecoder().decode([String: WireValue].self, from: data)
                        try projectDashboard(value, id: id, db: db)
                    }
                }
                guard let next = rows.last?["id"]?.string else { throw CaptureFailure.corrupt }
                after = next
            }
            try db.execute("INSERT OR REPLACE INTO archive_info(name,value) VALUES('dashboard-projection',?)", [.blob(projectionVersion)])
        }
    }

    /// Distinct non-alias model names the gateway reported: the host's list,
    /// or for older metadata the model evidence minus alias echoes.
    static func reportedModels(_ metadata: [String: WireValue]) -> [String] {
        let identity = metadata["identity"]?.object ?? [:]
        if let names = identity["reportedModels"]?.array?.compactMap(\.string), !names.isEmpty { return names }
        let alias = metadata["requestedModel"]?.string
        let evidence = (identity["evidence"]?.array ?? []).compactMap(\.object).filter { $0["kind"]?.string == "model" }
        return Array(Set(evidence.compactMap { $0["value"]?.string }.filter { !$0.isEmpty && $0 != alias })).sorted()
    }

    static func projectDashboard(_ metadata: [String: WireValue], id: String, db: CaptureDatabase) throws {
        let timings = metadata["timings"]?.object ?? [:]
        func observed(_ key: String) -> Double? {
            guard metadata["timingVersion"]?.number == 2, let n = timings[key]?.number, n.isFinite, n >= 0 else { return nil }; return n
        }
        func span(_ start: Double?, _ end: Double?) -> CaptureSQLValue {
            guard let start, let end, end >= start else { return .null }; return .real(end - start)
        }
        let dispatch = observed("dispatch")
        let wall = metadata["dispatchWallTimestamp"]?.number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let identity = metadata["identity"]?.object ?? [:]
        let identityStatus = identity["status"]?.string ?? (identity["effectiveModel"]?.string == nil ? "unreported" : "reported")
        guard ["reported", "unreported", "conflict", "incomplete"].contains(identityStatus) else { throw CaptureFailure.sequence }
        // Conflicting reports keep every name, so the report can show one by
        // default and reveal the rest instead of hiding the model entirely.
        let reported = identityStatus == "conflict" ? reportedModels(metadata) : []
        let reportedColumn: CaptureSQLValue = reported.count > 1 ? .text(String(decoding: try JSONEncoder().encode(reported), as: UTF8.self)) : .null
        // Keep a source-aware display column alongside the stricter identity.
        // Reusing existing bounded metadata also restores labels after body
        // expiry, without rereading or reconstructing HTTP payloads per refresh.
        let responseModel = GatewayModelIdentity(metadata: metadata).response?.name
        // The decode span: first output → last output. The terminal event
        // carries no token, and a gateway can hold it while it computes usage
        // and cost. Records written before the helper stamped `lastContent`
        // (Bello Agent 0.1.85 and earlier) have no last output; the terminal
        // event is the only end they have, so they keep it. Like the helper's
        // `metrics.streamDurationMs`, the span exists once the terminal event
        // was observed, so the Inspector's Stream, the report's Streaming and
        // the ledger's Generation agree. A migration re-projects every row
        // through here, by the same rule.
        let decodeEnd = observed("modelComplete").map { observed("lastContent") ?? $0 }
        try db.execute("UPDATE attempts SET dispatch=?,ttft_ms=?,stream_ms=?,request_ms=?,http_ms=?,wall=COALESCE(?,wall),identity_status=?,reported_models=?,response_model=? WHERE id=? AND metrics_retained=1", [
            dispatch.map(CaptureSQLValue.real) ?? .null, span(dispatch, observed("firstContent")), span(observed("firstContent"), decodeEnd),
            span(dispatch, observed("modelComplete")),
            span(dispatch, observed("httpEnd")), dispatch != nil ? wall.map(CaptureSQLValue.real) ?? .null : .null, .text(identityStatus), reportedColumn,
            responseModel.map(CaptureSQLValue.text) ?? .null, .text(id)
        ])
        let gateway = GatewayObservation(metadata: metadata)
        try db.execute("UPDATE attempts SET cost_usd=?,cost_status=?,cache_status=?,cache_read_tokens=?,cache_write_tokens=?,input_tokens=?,output_tokens=?,reasoning_tokens=?,reasoning_cost_usd=?,reasoning_cost_status=? WHERE id=? AND metrics_retained=1", [
            gateway.costUSD.map(CaptureSQLValue.real) ?? .null, .text(gateway.costStatus), .text(gateway.cacheStatus),
            gateway.cacheReadTokens.map(CaptureSQLValue.real) ?? .null, gateway.cacheWriteTokens.map(CaptureSQLValue.real) ?? .null,
            gateway.inputTokens.map(CaptureSQLValue.real) ?? .null, gateway.outputTokens.map(CaptureSQLValue.real) ?? .null,
            gateway.reasoningTokens.map(CaptureSQLValue.real) ?? .null, gateway.reasoningCostUSD.map(CaptureSQLValue.real) ?? .null, .text(gateway.reasoningCostStatus), .text(id)
        ])
    }

    static let modelGroupLimit = 64, sessionPageSize = 64, distinctLimit = 256
    func dashboard(_ filter: DashboardFilter, offset: Int = 0) async throws -> DashboardSnapshot {
        try await dashboardReader().run { try $0.dashboard(filter, offset: offset) }
    }
    func requestPage(_ filter: DashboardFilter, offset: Int = 0) async throws -> DashboardRequestPage {
        try await dashboardReader().run { try $0.requestPage(filter, offset: offset) }
    }
    func modelSummaries(_ filter: DashboardFilter) async throws -> [DashboardModelSummary] {
        try await dashboardReader().run { try $0.modelSummaries(filter) }
    }
    func sessionSummaries(_ filter: DashboardFilter, offset: Int = 0) async throws -> DashboardSessionPage {
        try await dashboardReader().run { try $0.sessionSummaries(filter, offset: offset) }
    }
    func distinctAliases(_ filter: DashboardFilter) async throws -> [String] {
        try await dashboardReader().run { try $0.distinctAliases(filter) }
    }
    func distinctModels(_ filter: DashboardFilter) async throws -> [String] {
        try await dashboardReader().run { try $0.distinctModels(filter) }
    }
    func distinctPurposes(_ filter: DashboardFilter) async throws -> [String] {
        try await dashboardReader().run { try $0.distinctPurposes(filter) }
    }
    /// Statements one report snapshot read executes, and its result (tests only).
    func dashboardStatements(_ filter: DashboardFilter) throws -> (snapshot: DashboardSnapshot, statements: Int) {
        let db = try dashboardDatabase(), before = db.statements
        let snapshot = try DashboardQueryEngine(db: db).dashboard(filter)
        return (snapshot, db.statements - before)
    }
}
