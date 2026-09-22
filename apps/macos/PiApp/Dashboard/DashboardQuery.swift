import Foundation

struct DashboardFilter: Sendable, Equatable {
    var from: Date
    var until: Date
    var workspaceID: String?
    var sessionID: String?
    var purpose: String?
    var status = "completed"
    var api: String?
    var requestedAlias: String?
    var effectiveModel: String?
    var unreportedModelOnly = false
    var bucketCount = 24

    func validated() throws {
        // Windows share the preset limits: at least one second (a chart brush
        // never narrows below that) and at most the ten-year custom span.
        guard from.timeIntervalSince1970.isFinite, until.timeIntervalSince1970.isFinite, from < until,
              until.timeIntervalSince(from) >= 1, until.timeIntervalSince(from) <= DashboardWindowPreset.maximumSpan, (1...60).contains(bucketCount),
              ["all", "completed", "truncated", "failed", "cancelled", "interrupted", "running"].contains(status),
              [workspaceID, sessionID, purpose, api, requestedAlias, effectiveModel].allSatisfy({ value in
                  value.map { !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) } ?? true
              }), !(unreportedModelOnly && effectiveModel != nil) else { throw CaptureFailure.unavailable }
    }
}

struct DashboardPercentiles: Sendable, Equatable {
    var samples = 0
    var p50: Double?
    var p99: Double?
}

struct DashboardCounts: Sendable, Equatable {
    var dispatched = 0
    var completed = 0
    var failed = 0
    var cancelled = 0
    var running = 0
    var truncated = 0
    var interrupted = 0
    var unobservedDispatch = 0
}

struct DashboardBucket: Sendable, Identifiable {
    let id: Int
    let start: Date
    let end: Date
    var requests = 0
    var ttft = DashboardPercentiles()
    var streaming = DashboardPercentiles()
    var http = DashboardPercentiles()
    var gateway = GatewayTotals()
    var historicalRate = HistoricalOutputRate()
}

struct DashboardRequest: Sendable, Identifiable {
    let id: String
    let sessionID: String
    let workspaceID: String
    let wall: Date
    let purpose: String
    let api: String
    let alias: String
    let effectiveModel: String?
    let identityStatus: String
    /// Every distinct model name the gateway reported when the reports conflict; empty otherwise.
    var reportedModels: [String] = []
    /// The name shown by default: the verified model, or the shortest conflicting name.
    var displayModel: String? { effectiveModel ?? dashboardPrimaryModel(reportedModels) }
    let outcome: String
    let ttft: Double?
    let streaming: Double?
    let http: Double?
    var gateway = GatewayObservation(metadata: [:])
}

extension GatewayTotals {
    /// Response-cache hits over reported outcomes. Unreported, invalid and
    /// conflicting rows are excluded from both sides; nil when nothing was reported.
    var cacheHitRatio: Double? {
        let reported = cacheHits + cacheMisses
        return reported > 0 ? Double(cacheHits) / Double(reported) : nil
    }
}

/// One session's aggregate inside a report window. Rows come from the
/// existing attempts table (already keyed by session), so no extra table is
/// needed; message navigation uses the message_links table.
struct DashboardSessionSummary: Sendable, Identifiable, Equatable {
    let sessionID: String
    let workspaceID: String
    var requests = 0
    var completed = 0
    var problems = 0
    var running = 0
    var first: Date
    var last: Date
    var ttftP50: Double?
    var httpP50: Double?
    var gateway = GatewayTotals()
    var id: String { sessionID }
}

/// One requested route inside a report window, split by the model the
/// gateway served, with its own throughput and latency medians so mixed
/// routes never average into one figure.
struct DashboardModelSummary: Sendable, Identifiable, Equatable {
    let api: String
    let alias: String
    let model: String?
    let status: String
    var requests = 0
    var completed = 0
    var problems = 0
    var gateway = GatewayTotals()
    var rate = HistoricalOutputRate()
    var ttftP50: Double?
    var ttftSamples = 0
    var httpP50: Double?
    var id: String { [api, alias, model ?? "", status].joined(separator: "\u{1}") }
    var resolutionLabel: String {
        if let model { return model }
        switch status {
        case "conflict": return "Conflicting model reports"
        case "incomplete": return "Incomplete model evidence"
        default: return "Model not reported"
        }
    }
}

struct DashboardSessionPage: Sendable, Equatable {
    let filter: DashboardFilter
    let sessions: [DashboardSessionSummary]
    let total: Int
    let offset: Int
    var hasNext: Bool { offset + sessions.count < total }
}

extension GatewayObservation {
    /// Input tokens not served from the provider prompt cache, when both values are known.
    var uncachedInputTokens: Double? {
        guard let inputTokens, let cacheReadTokens, cacheReadTokens <= inputTokens else { return nil }
        return inputTokens - cacheReadTokens
    }
}
extension GatewayTotals {
    /// Subtract per request, then aggregate only those paired observations.
    /// Old snapshots lack paired sums and require complete coverage instead.
    var uncachedInputTokens: Double? {
        if uncachedInputSamples != nil { return uncachedInputReportedTokens }
        guard let tokens, tokens.inputSamples == requests, cacheReadSamples == requests,
              let input = tokens.input, let cacheReadTokens, cacheReadTokens <= input else { return nil }
        return input - cacheReadTokens
    }
    var uncachedInputSampleCount: Int {
        uncachedInputSamples ?? (uncachedInputTokens == nil ? 0 : requests)
    }
    var promptCacheCoverageLabel: String {
        "Cached input \(cacheReadSamples)/\(requests) requests reported; uncached input \(uncachedInputSampleCount)/\(requests) requests reported both input and cache reads."
    }
}

struct DashboardRequestPage: Sendable {
    let filter: DashboardFilter
    let selectedRequests: Int
    let requests: [DashboardRequest]
    let offset: Int
    var asOf = Date()
    var hasNext: Bool { offset + requests.count < selectedRequests }
}

struct DashboardSnapshot: Sendable {
    let filter: DashboardFilter
    let scopeCounts: DashboardCounts
    let selectedRequests: Int
    let ttft: DashboardPercentiles
    let streaming: DashboardPercentiles
    let http: DashboardPercentiles
    let buckets: [DashboardBucket]
    var requests: [DashboardRequest]
    var offset: Int
    var summaryAsOf = Date()
    var rowsAsOf = Date()
    var rowCount: Int?
    var gateway = GatewayTotals()
    /// Output throughput of the window's completed, measured requests, duration-weighted.
    var historicalRate = HistoricalOutputRate()
    var hasNext: Bool { offset + requests.count < (rowCount ?? selectedRequests) }
    mutating func replaceRows(_ page: DashboardRequestPage) {
        guard filter == page.filter else { return }
        requests = page.requests; offset = page.offset; rowsAsOf = page.asOf; rowCount = page.selectedRequests
    }
}

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
        try db.execute("UPDATE attempts SET dispatch=?,ttft_ms=?,stream_ms=?,request_ms=?,http_ms=?,wall=COALESCE(?,wall),identity_status=?,reported_models=?,response_model=? WHERE id=? AND metrics_retained=1", [
            dispatch.map(CaptureSQLValue.real) ?? .null, span(dispatch, observed("firstContent")), span(observed("firstContent"), observed("modelComplete")),
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
}

/// Executes only inside a short read transaction on the report worker.
struct DashboardQueryEngine {
    let db: CaptureDatabase
    func dashboard(_ filter: DashboardFilter, offset: Int = 0) throws -> DashboardSnapshot {
        try filter.validated()
        guard (0...100_000).contains(offset) else { throw CaptureFailure.unavailable }
        let scope = dashboardPredicate(filter, status: false)
        let selected = dashboardPredicate(filter, status: true)
        let baseCounts = try db.rows("SELECT COUNT(dispatch) AS dispatched,SUM(dispatch IS NULL) AS unobserved FROM attempts WHERE \(scope.sql)", scope.values).first ?? [:]
        var counts = DashboardCounts(dispatched: Int(baseCounts["dispatched"]?.number ?? 0), unobservedDispatch: Int(baseCounts["unobserved"]?.number ?? 0))
        for row in try db.rows("SELECT outcome,COUNT(*) AS n FROM attempts WHERE \(scope.sql) AND dispatch IS NOT NULL GROUP BY outcome", scope.values) {
            let n = Int(row["n"]?.number ?? 0)
            switch row["outcome"]?.string {
            case "completed": counts.completed = n
            case "failed": counts.failed = n
            case "cancelled": counts.cancelled = n
            case "running": counts.running = n
            case "truncated": counts.truncated = n
            case "interrupted": counts.interrupted = n
            default: break
            }
        }
        let requestCount = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL", selected.values).first?["n"]?.number ?? 0)
        let summaryRow = try db.rows("SELECT \(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL) FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL", selected.values).first ?? [:]
        let gateway = PayloadArchive.gatewayTotals(summaryRow)
        let ttft = try percentile(db, column: "ttft_ms", predicate: selected)
        let streaming = try percentile(db, column: "stream_ms", predicate: selected)
        let http = try percentile(db, column: "http_ms", predicate: selected)
        let width = filter.until.timeIntervalSince(filter.from) / Double(filter.bucketCount)
        var buckets = (0..<filter.bucketCount).map { DashboardBucket(id: $0, start: filter.from.addingTimeInterval(Double($0) * width), end: filter.from.addingTimeInterval(Double($0 + 1) * width)) }
        let bucketSQL = "CAST((wall-?)/? AS INTEGER)"
        let bucketArgs: [CaptureSQLValue] = [.real(filter.from.timeIntervalSince1970), .real(width)]
        for row in try db.rows("SELECT \(bucketSQL) AS bucket,COUNT(*) AS n FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL GROUP BY bucket", bucketArgs + selected.values) {
            if let i = row["bucket"]?.number.map(Int.init), buckets.indices.contains(i) { buckets[i].requests = Int(row["n"]?.number ?? 0) }
        }
        for row in try db.rows("SELECT \(bucketSQL) AS bucket,\(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL) FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL GROUP BY bucket", bucketArgs + selected.values) {
            if let i = row["bucket"]?.number.map(Int.init), buckets.indices.contains(i) {
                buckets[i].gateway = PayloadArchive.gatewayTotals(row)
                buckets[i].historicalRate = PayloadArchive.historicalOutputRate(row)
            }
        }
        for column in ["ttft_ms", "stream_ms", "http_ms"] {
            // Compute each bucket from raw samples. A global percentile above
            // is computed separately; bucket p99 values are never averaged.
            let sql = """
            WITH samples AS (SELECT \(bucketSQL) AS bucket,\(column) AS value FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL AND \(column) IS NOT NULL),
            ranked AS (SELECT bucket,value,ROW_NUMBER() OVER(PARTITION BY bucket ORDER BY value) AS rank,COUNT(*) OVER(PARTITION BY bucket) AS n FROM samples)
            SELECT bucket,MAX(n) AS n,MAX(CASE WHEN rank=(n+1)/2 THEN value END) AS p50,MAX(CASE WHEN rank=(n*99+99)/100 THEN value END) AS p99 FROM ranked GROUP BY bucket
            """
            for row in try db.rows(sql, bucketArgs + selected.values) {
                guard let i = row["bucket"]?.number.map(Int.init), buckets.indices.contains(i) else { continue }
                let value = percentiles(row)
                if column == "ttft_ms" { buckets[i].ttft = value } else if column == "stream_ms" { buckets[i].streaming = value } else { buckets[i].http = value }
            }
        }
        let requests = try requestRows(selected, offset: offset)
        return DashboardSnapshot(filter: filter, scopeCounts: counts, selectedRequests: requestCount, ttft: ttft, streaming: streaming, http: http, buckets: buckets, requests: requests, offset: offset, gateway: gateway, historicalRate: PayloadArchive.historicalOutputRate(summaryRow))
    }

    func requestPage(_ filter: DashboardFilter, offset: Int = 0) throws -> DashboardRequestPage {
        try filter.validated()
        guard (0...100_000).contains(offset) else { throw CaptureFailure.unavailable }
        let selected = dashboardPredicate(filter, status: true)
        let total = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL", selected.values).first?["n"]?.number ?? 0)
        return DashboardRequestPage(filter: filter, selectedRequests: total, requests: try requestRows(selected, offset: offset), offset: offset)
    }
    private func requestRows(_ selected: (sql: String, values: [CaptureSQLValue]), offset: Int) throws -> [DashboardRequest] {
        let rows = try db.rows("SELECT id,session,workspace,wall,purpose,api,alias,model,identity_status,reported_models,outcome,ttft_ms,stream_ms,http_ms,cost_usd,cost_status,cache_status,cache_read_tokens,cache_write_tokens,input_tokens,output_tokens,reasoning_tokens,reasoning_cost_usd,reasoning_cost_status FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL ORDER BY wall DESC,id DESC LIMIT 128 OFFSET ?", selected.values + [.integer(Int64(offset))])
        let requests = try rows.map { row -> DashboardRequest in
            guard let id = row["id"]?.string, let session = row["session"]?.string, let workspace = row["workspace"]?.string, let wall = row["wall"]?.double else { throw CaptureFailure.corrupt }
            var observation = GatewayObservation(metadata: [:])
            observation.costUSD = row["cost_usd"]?.double; observation.costStatus = row["cost_status"]?.string ?? "unreported"
            observation.cacheStatus = row["cache_status"]?.string ?? "unreported"
            observation.cacheReadTokens = row["cache_read_tokens"]?.double; observation.cacheWriteTokens = row["cache_write_tokens"]?.double
            observation.inputTokens = row["input_tokens"]?.double; observation.outputTokens = row["output_tokens"]?.double
            observation.reasoningTokens = row["reasoning_tokens"]?.double; observation.reasoningCostUSD = row["reasoning_cost_usd"]?.double
            observation.reasoningCostStatus = row["reasoning_cost_status"]?.string ?? "unreported"
            return DashboardRequest(id: id, sessionID: session, workspaceID: workspace, wall: Date(timeIntervalSince1970: wall), purpose: row["purpose"]?.string ?? "", api: row["api"]?.string ?? "", alias: row["alias"]?.string ?? "", effectiveModel: row["model"]?.string, identityStatus: row["identity_status"]?.string ?? "unreported", reportedModels: row["reported_models"]?.string.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [], outcome: row["outcome"]?.string ?? "", ttft: row["ttft_ms"]?.double, streaming: row["stream_ms"]?.double, http: row["http_ms"]?.double, gateway: observation)
        }
        return requests
    }

    static let modelGroupLimit = 64
    /// Per-route aggregates inside the window: each requested alias split by
    /// the model the gateway served, with its own duration-weighted output rate
    /// and nearest-rank medians. Bounded to the busiest routes.
    func modelSummaries(_ filter: DashboardFilter) throws -> [DashboardModelSummary] {
        try filter.validated()
        let selected = dashboardPredicate(filter, status: true)
        let reported = "identity_status='reported' AND model IS NOT NULL AND LENGTH(TRIM(model))>0 AND model<>alias"
        let normalized = """
        WITH selected AS (
          SELECT *,CASE WHEN \(reported) THEN model ELSE NULL END AS resolved_model,
            CASE WHEN identity_status IN ('conflict','incomplete') THEN identity_status WHEN \(reported) THEN 'reported' ELSE 'unreported' END AS resolution_status
          FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL
        )
        """
        let key = "api,alias,resolved_model,resolution_status"
        let rows = try db.rows("""
        \(normalized)
        SELECT \(key),SUM(outcome='completed') AS completed,SUM(outcome IN ('failed','cancelled','truncated','interrupted')) AS problems,
          \(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL)
        FROM selected GROUP BY \(key)
        ORDER BY requests DESC,alias COLLATE BINARY,api COLLATE BINARY,resolution_status COLLATE BINARY,resolved_model COLLATE BINARY LIMIT ?
        """, selected.values + [.integer(Int64(Self.modelGroupLimit))])
        var summaries = try rows.map { row -> DashboardModelSummary in
            guard let api = row["api"]?.string, let alias = row["alias"]?.string, let status = row["resolution_status"]?.string else { throw CaptureFailure.corrupt }
            var summary = DashboardModelSummary(api: api, alias: alias, model: row["resolved_model"]?.string, status: status)
            summary.requests = Int(row["requests"]?.number ?? 0); summary.completed = Int(row["completed"]?.number ?? 0); summary.problems = Int(row["problems"]?.number ?? 0)
            summary.gateway = PayloadArchive.gatewayTotals(row); summary.rate = PayloadArchive.historicalOutputRate(row)
            return summary
        }
        for column in ["ttft_ms", "http_ms"] where !summaries.isEmpty {
            let sql = """
            \(normalized), ranked AS (SELECT \(key),\(column) AS value,ROW_NUMBER() OVER(PARTITION BY \(key) ORDER BY \(column)) AS rank,COUNT(*) OVER(PARTITION BY \(key)) AS n FROM selected WHERE \(column) IS NOT NULL)
            SELECT \(key),MAX(n) AS n,MAX(CASE WHEN rank=(n+1)/2 THEN value END) AS p50 FROM ranked GROUP BY \(key)
            """
            for row in try db.rows(sql, selected.values) {
                guard let index = summaries.firstIndex(where: { $0.api == row["api"]?.string && $0.alias == row["alias"]?.string && $0.model == row["resolved_model"]?.string && $0.status == row["resolution_status"]?.string }) else { continue }
                if column == "ttft_ms" { summaries[index].ttftP50 = row["p50"]?.double; summaries[index].ttftSamples = Int(row["n"]?.number ?? 0) }
                else { summaries[index].httpP50 = row["p50"]?.double }
            }
        }
        return summaries
    }

    static let sessionPageSize = 64
    /// Per-session aggregates inside the window, most recently active first.
    /// Latency medians are nearest-rank per session, never averaged.
    func sessionSummaries(_ filter: DashboardFilter, offset: Int = 0) throws -> DashboardSessionPage {
        try filter.validated()
        guard (0...100_000).contains(offset) else { throw CaptureFailure.unavailable }
        let selected = dashboardPredicate(filter, status: true)
        let total = Int(try db.rows("SELECT COUNT(DISTINCT session) AS n FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL", selected.values).first?["n"]?.number ?? 0)
        let rows = try db.rows("""
        SELECT session,MIN(workspace) AS workspace,MIN(wall) AS first_wall,MAX(wall) AS last_wall,
        SUM(outcome='completed') AS completed,SUM(outcome IN ('failed','cancelled','truncated','interrupted')) AS problems,SUM(outcome='running') AS running,
        \(PayloadArchive.gatewayAggregateSQL)
        FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL GROUP BY session ORDER BY last_wall DESC,session LIMIT ? OFFSET ?
        """, selected.values + [.integer(Int64(Self.sessionPageSize)), .integer(Int64(offset))])
        var sessions = try rows.map { row -> DashboardSessionSummary in
            guard let session = row["session"]?.string, let first = row["first_wall"]?.double, let last = row["last_wall"]?.double else { throw CaptureFailure.corrupt }
            var summary = DashboardSessionSummary(sessionID: session, workspaceID: row["workspace"]?.string ?? "", first: Date(timeIntervalSince1970: first), last: Date(timeIntervalSince1970: last))
            summary.requests = Int(row["requests"]?.number ?? 0); summary.completed = Int(row["completed"]?.number ?? 0)
            summary.problems = Int(row["problems"]?.number ?? 0); summary.running = Int(row["running"]?.number ?? 0)
            summary.gateway = PayloadArchive.gatewayTotals(row)
            return summary
        }
        guard !sessions.isEmpty else { return DashboardSessionPage(filter: filter, sessions: [], total: total, offset: offset) }
        let ids = sessions.map(\.sessionID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        for column in ["ttft_ms", "http_ms"] {
            let sql = """
            WITH samples AS (SELECT session,\(column) AS value FROM attempts WHERE \(selected.sql) AND dispatch IS NOT NULL AND \(column) IS NOT NULL AND session IN (\(placeholders))),
            ranked AS (SELECT session,value,ROW_NUMBER() OVER(PARTITION BY session ORDER BY value) AS rank,COUNT(*) OVER(PARTITION BY session) AS n FROM samples)
            SELECT session,MAX(CASE WHEN rank=(n+1)/2 THEN value END) AS p50 FROM ranked GROUP BY session
            """
            for row in try db.rows(sql, selected.values + ids.map(CaptureSQLValue.text)) {
                guard let session = row["session"]?.string, let index = sessions.firstIndex(where: { $0.sessionID == session }) else { continue }
                if column == "ttft_ms" { sessions[index].ttftP50 = row["p50"]?.double } else { sessions[index].httpP50 = row["p50"]?.double }
            }
        }
        return DashboardSessionPage(filter: filter, sessions: sessions, total: total, offset: offset)
    }

    /// Distinct requested aliases dispatched inside the filter window. The
    /// alias clause itself is ignored so a picker can offer every alternative.
    func distinctAliases(_ filter: DashboardFilter) throws -> [String] { try distinct(column: "alias", filter) }
    /// Distinct gateway-reported models inside the window; unreported rows are
    /// skipped and the model/unreported clauses are ignored for the same reason.
    func distinctModels(_ filter: DashboardFilter) throws -> [String] { try distinct(column: "model", filter) }
    /// Distinct request purposes inside the window (purpose clause ignored).
    func distinctPurposes(_ filter: DashboardFilter) throws -> [String] { try distinct(column: "purpose", filter) }

    static let distinctLimit = 256
    private func distinct(column: String, _ filter: DashboardFilter) throws -> [String] {
        try filter.validated()
        let predicate = dashboardPredicate(filter, status: true, excluding: column)
        let rows = try db.rows("SELECT DISTINCT \(column) AS value FROM attempts WHERE \(predicate.sql) AND dispatch IS NOT NULL AND \(column) IS NOT NULL ORDER BY \(column) LIMIT ?", predicate.values + [.integer(Int64(Self.distinctLimit))])
        return rows.compactMap { $0["value"]?.string }.filter { !$0.isEmpty }
    }

    private func dashboardPredicate(_ filter: DashboardFilter, status: Bool, excluding excluded: String? = nil) -> (sql: String, values: [CaptureSQLValue]) {
        var clauses = ["metrics_retained=1", "wall>=?", "wall<?"]
        var values: [CaptureSQLValue] = [.real(filter.from.timeIntervalSince1970), .real(filter.until.timeIntervalSince1970)]
        for (column, value) in [("workspace", filter.workspaceID), ("session", filter.sessionID), ("purpose", filter.purpose), ("api", filter.api), ("alias", filter.requestedAlias), ("model", filter.effectiveModel)] where column != excluded {
            if let value { clauses.append(column + "=?"); values.append(.text(value)) }
        }
        if filter.unreportedModelOnly && excluded != "model" { clauses.append("model IS NULL") }
        if status && filter.status != "all" { clauses.append("outcome=?"); values.append(.text(filter.status)) }
        return (clauses.joined(separator: " AND "), values)
    }

    private func percentile(_ db: CaptureDatabase, column: String, predicate: (sql: String, values: [CaptureSQLValue])) throws -> DashboardPercentiles {
        let sql = """
        WITH ranked AS (SELECT \(column) AS value,ROW_NUMBER() OVER(ORDER BY \(column)) AS rank,COUNT(*) OVER() AS n FROM attempts WHERE \(predicate.sql) AND dispatch IS NOT NULL AND \(column) IS NOT NULL)
        SELECT MAX(n) AS n,MAX(CASE WHEN rank=(n+1)/2 THEN value END) AS p50,MAX(CASE WHEN rank=(n*99+99)/100 THEN value END) AS p99 FROM ranked
        """
        return percentiles(try db.rows(sql, predicate.values).first ?? [:])
    }
    private func percentiles(_ row: [String: CaptureSQLValue]) -> DashboardPercentiles {
        DashboardPercentiles(samples: Int(row["n"]?.number ?? 0), p50: row["p50"]?.double, p99: row["p99"]?.double)
    }
}

/// The name to show first when several were reported: the shortest one, since
/// the longer names are usually the same model with a provider or date suffix.
func dashboardPrimaryModel(_ names: [String]) -> String? {
    names.min { ($0.count, $0) < ($1.count, $1) }
}
