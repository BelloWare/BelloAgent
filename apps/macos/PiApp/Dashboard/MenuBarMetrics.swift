import Foundation

enum MenuBarPeriod: String, CaseIterable, Identifiable, Hashable, Sendable {
    case day, week, retained
    var id: String { rawValue }
    var title: String {
        switch self { case .day: "Last 24h"; case .week: "Last 7 days"; case .retained: "Retained" }
    }
    func start(until: Date) -> Date? {
        switch self {
        case .day: until.addingTimeInterval(-86400)
        case .week: until.addingTimeInterval(-7 * 86400)
        case .retained: nil
        }
    }
    /// Hourly for a day, six-hourly for a week, and 24 even slices of everything retained.
    var bucketCount: Int { self == .week ? 28 : 24 }
}

/// One time slice of the status-bar charts: requests, reported cost and the
/// historical output rate of the attempts dispatched inside it.
struct MenuBarBucket: Sendable, Identifiable, Equatable {
    let id: Int
    let start: Date
    let end: Date
    var gateway = GatewayTotals()
    var historicalRate = HistoricalOutputRate()
    var requests: Int { gateway.requests }
}

/// Output throughput from completed requests with both reported usage and an
/// observed dispatch-to-model-completion interval. This includes time before
/// first content (such as opaque reasoning and buffered JSON responses).
/// Summing durations weights long requests fairly; individual rates are not averaged.
struct HistoricalOutputRate: Sendable, Equatable {
    var outputTokens: Double = 0
    var generationMilliseconds: Double = 0
    var samples: Int = 0

    var tokensPerSecond: Double? {
        guard samples > 0, outputTokens.isFinite, outputTokens >= 0,
              generationMilliseconds.isFinite, generationMilliseconds > 0 else { return nil }
        let rate = outputTokens / (generationMilliseconds / 1_000)
        return rate.isFinite ? rate : nil
    }
}

struct MenuBarModelDistribution: Sendable, Identifiable, Equatable {
    struct ID: Hashable, Sendable {
        let api: String
        let alias: String
        let model: String?
        let status: String
    }
    let api: String
    let requestedAlias: String
    let resolvedModel: String?
    let identityStatus: String
    let gateway: GatewayTotals
    let allRequests: Int
    var historicalRate = HistoricalOutputRate()
    /// Share of all gateway-reported cost in the scope, including other pages.
    /// Missing model cost or a zero/unknown scope total has no meaningful share.
    var costShare: Double? = nil
    /// Nearest-rank medians of this route's own requests, so a slow model
    /// never hides behind a fast one in a blended figure.
    var ttftP50: Double? = nil
    var ttftSamples = 0
    var httpP50: Double? = nil
    var id: ID { ID(api: api, alias: requestedAlias, model: resolvedModel, status: identityStatus) }
    var requestShare: Double { allRequests > 0 ? Double(gateway.requests) / Double(allRequests) : 0 }
    var resolutionLabel: String {
        if let resolvedModel { return resolvedModel }
        switch identityStatus {
        case "conflict": return "Conflicting model reports"
        case "incomplete": return "Incomplete model evidence"
        default: return "Model not reported"
        }
    }
}

struct MenuBarSnapshot: Sendable, Equatable {
    static let pageSize = 24
    let period: MenuBarPeriod
    let from: Date?
    let until: Date
    let counts: DashboardCounts
    let gateway: GatewayTotals
    let workspaces: Int
    let sessions: Int
    let compactionRequests: Int
    let costUnreported: Int
    let costInvalid: Int
    let costConflicts: Int
    let models: [MenuBarModelDistribution]
    let modelGroups: Int
    let offset: Int
    var historicalRate = HistoricalOutputRate()
    var buckets: [MenuBarBucket] = []
    /// Paging can read newer route rows than the retained summary. Keep both
    /// observations explicit rather than claiming one atomic snapshot.
    var summaryReadAt: Date? = nil
    var modelPageReadAt: Date? = nil
    var observationHelp: String {
        guard let summaryReadAt, let modelPageReadAt else { return "Retained metadata observations" }
        return "Summary and charts read at " + summaryReadAt.formatted(date: .omitted, time: .standard)
            + "; model page read at " + modelPageReadAt.formatted(date: .omitted, time: .standard)
            + ". A paged distribution can be newer than the cached summary."
    }
    var hasNext: Bool { offset + models.count < modelGroups }
}

struct UsageSnapshotKey: Hashable, Sendable {
    let period: MenuBarPeriod
    let sessionID: String?
    let workspaceID: String?
}

extension PayloadArchive {
    func menuBarMetrics(period: MenuBarPeriod, until: Date = Date(), offset: Int = 0) async throws -> MenuBarSnapshot {
        try await readUsageMetrics(period: period, until: until, offset: offset)
    }
    func sessionMetrics(sessionID: String, workspaceID: String, until: Date = Date(), offset: Int = 0) async throws -> MenuBarSnapshot {
        guard [sessionID, workspaceID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else { throw CaptureFailure.unavailable }
        return try await readUsageMetrics(period: .retained, until: until, offset: offset, sessionID: sessionID, workspaceID: workspaceID)
    }
    private func readUsageMetrics(period: MenuBarPeriod, until: Date, offset: Int, sessionID: String? = nil, workspaceID: String? = nil) async throws -> MenuBarSnapshot {
        let key = UsageSnapshotKey(period: period, sessionID: sessionID, workspaceID: workspaceID)
        let previous = usageSnapshots[key]
        // Pages reuse a recent summary/chart observation. The normal refresh
        // interval still requests a fresh aggregate; the cache is bounded.
        let cached = offset > 0 ? previous.flatMap { until.timeIntervalSince($0.until) >= 0 && until.timeIntervalSince($0.until) < 10 ? $0 : nil } : nil
        let value = try await dashboardReader().run {
            try $0.usageMetrics(period: period, until: cached?.until ?? until, offset: offset,
                               sessionID: sessionID, workspaceID: workspaceID, cached: cached, includeLatency: sessionID != nil)
        }
        try Task.checkCancellation()
        if cached == nil {
            if usageSnapshots.count >= 16, usageSnapshots[key] == nil,
               let oldest = usageSnapshots.min(by: { $0.value.until < $1.value.until })?.key { usageSnapshots[oldest] = nil }
            if usageSnapshots[key].map({ $0.until <= value.until }) ?? true { usageSnapshots[key] = value }
        }
        return value
    }
}

extension DashboardQueryEngine {
    func usageMetrics(period: MenuBarPeriod, until: Date, offset: Int, sessionID: String? = nil, workspaceID: String? = nil, cached: MenuBarSnapshot? = nil, includeLatency: Bool = false) throws -> MenuBarSnapshot {
        guard until.timeIntervalSince1970.isFinite, until.timeIntervalSince1970 >= 0,
              (0...100_000).contains(offset), offset % MenuBarSnapshot.pageSize == 0 else { throw CaptureFailure.unavailable }
        try Task.checkCancellation()
        var timeAndIdentity = "wall<?"
        var values: [CaptureSQLValue] = [.real(until.timeIntervalSince1970)]
        if let start = period.start(until: until) { timeAndIdentity += " AND wall>=?"; values.append(.real(start.timeIntervalSince1970)) }
        if let sessionID { timeAndIdentity += " AND session=?"; values.append(.text(sessionID)) }
        if let workspaceID { timeAndIdentity += " AND workspace=?"; values.append(.text(workspaceID)) }
        let scope = "metrics_retained=1 AND " + timeAndIdentity
        let selected = scope + " AND dispatch IS NOT NULL"
        let summary: [String: CaptureSQLValue]
        let sessionCount: Int
        var totals: GatewayTotals
        var counts: DashboardCounts
        if let cached {
            summary = ["workspaces": .integer(Int64(cached.workspaces)), "compactions": .integer(Int64(cached.compactionRequests)), "cost_unreported": .integer(Int64(cached.costUnreported)), "cost_invalid": .integer(Int64(cached.costInvalid)), "cost_conflicts": .integer(Int64(cached.costConflicts))]
            sessionCount = cached.sessions; totals = cached.gateway; counts = cached.counts
        } else {
        summary = try db.rows("""
        SELECT \(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL),COUNT(DISTINCT workspace) AS workspaces,
          MIN(wall) AS first_wall,SUM(purpose='compaction') AS compactions,
          SUM(cost_status='unreported') AS cost_unreported,SUM(cost_status='invalid') AS cost_invalid,
          SUM(cost_status='conflict') AS cost_conflicts
        FROM attempts WHERE \(selected)
        """, values).first ?? [:]
        sessionCount = Int(try db.rows("SELECT COUNT(*) AS n FROM (SELECT workspace,session FROM attempts WHERE \(selected) GROUP BY workspace,session)", values).first?["n"]?.number ?? 0)
        totals = PayloadArchive.gatewayTotals(summary)
        totals.expiredRecords = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE metrics_retained=0 AND \(timeAndIdentity)", values).first?["n"]?.number ?? 0)
        counts = DashboardCounts(dispatched: totals.requests)
        counts.unobservedDispatch = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE \(scope) AND dispatch IS NULL", values).first?["n"]?.number ?? 0)
        for row in try db.rows("SELECT outcome,COUNT(*) AS n FROM attempts WHERE \(selected) GROUP BY outcome", values) {
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
        }
        func count(_ key: String) -> Int { Int(summary[key]?.number ?? 0) }
        try Task.checkCancellation()
        // Never manufacture actual-model resolution from an alias echo, even
        // for an older row that erroneously labels that echo as reported.
        // Group by API as well: identical aliases on the two native APIs need
        // not identify the same route. Conflict/incomplete groups stay visible.
        let reported = "identity_status='reported' AND model IS NOT NULL AND LENGTH(TRIM(model))>0 AND model<>alias"
        let normalized = """
        WITH selected AS (
          SELECT *,CASE WHEN \(reported) THEN model ELSE NULL END AS resolved_model,
            CASE WHEN identity_status IN ('conflict','incomplete') THEN identity_status
              WHEN \(reported) THEN 'reported' ELSE 'unreported' END AS resolution_status
          FROM attempts WHERE \(selected)
        )
        """
        let grouping = "GROUP BY api,alias,resolved_model,resolution_status"
        let groupCount = Int(try db.rows("\(normalized) SELECT COUNT(*) AS n FROM (SELECT 1 FROM selected \(grouping))", values).first?["n"]?.number ?? 0)
        let rows = try db.rows("""
        \(normalized)
        SELECT api,alias,resolved_model,resolution_status,\(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL)
        FROM selected \(grouping)
        ORDER BY requests DESC,alias COLLATE BINARY,api COLLATE BINARY,resolution_status COLLATE BINARY,resolved_model COLLATE BINARY
        LIMIT \(MenuBarSnapshot.pageSize) OFFSET ?
        """, values + [.integer(Int64(offset))])
        var models = try rows.map { row -> MenuBarModelDistribution in
            guard let api = row["api"]?.string, let alias = row["alias"]?.string, let status = row["resolution_status"]?.string else { throw CaptureFailure.corrupt }
            let gateway = PayloadArchive.gatewayTotals(row)
            let share: Double?
            if let cost = gateway.costUSD, let allCost = totals.costUSD, allCost > 0 { share = cost / allCost }
            else { share = nil }
            return MenuBarModelDistribution(api: api, requestedAlias: alias, resolvedModel: row["resolved_model"]?.string, identityStatus: status, gateway: gateway, allRequests: totals.requests,
                                            historicalRate: PayloadArchive.historicalOutputRate(row), costShare: share)
        }
        if includeLatency, !models.isEmpty {
            let key = "api,alias,resolved_model,resolution_status"
            let routePredicate = models.map { _ in "(api=? AND alias=? AND resolved_model IS ? AND resolution_status=?)" }.joined(separator: " OR ")
            let routeValues = models.flatMap { item -> [CaptureSQLValue] in [.text(item.api), .text(item.requestedAlias), item.resolvedModel.map(CaptureSQLValue.text) ?? .null, .text(item.identityStatus)] }
            for column in ["ttft_ms", "http_ms"] {
                let sql = """
                \(normalized), ranked AS (SELECT \(key),\(column) AS value,ROW_NUMBER() OVER(PARTITION BY \(key) ORDER BY \(column)) AS rank,COUNT(*) OVER(PARTITION BY \(key)) AS n FROM selected WHERE \(column) IS NOT NULL AND (\(routePredicate)))
                SELECT \(key),MAX(n) AS n,MAX(CASE WHEN rank=(n+1)/2 THEN value END) AS p50 FROM ranked GROUP BY \(key)
                """
                for row in try db.rows(sql, values + routeValues) {
                    guard let index = models.firstIndex(where: { $0.api == row["api"]?.string && $0.requestedAlias == row["alias"]?.string && $0.resolvedModel == row["resolved_model"]?.string && $0.identityStatus == row["resolution_status"]?.string }) else { continue }
                    if column == "ttft_ms" { models[index].ttftP50 = row["p50"]?.double; models[index].ttftSamples = Int(row["n"]?.number ?? 0) }
                    else { models[index].httpP50 = row["p50"]?.double }
                }
            }
        }
        try Task.checkCancellation()
        let from = cached?.from ?? period.start(until: until) ?? summary["first_wall"]?.double.map { Date(timeIntervalSince1970: $0) }
        var buckets: [MenuBarBucket] = cached?.buckets ?? []
        if cached == nil, let from, until.timeIntervalSince(from) >= 1 {
            let width = until.timeIntervalSince(from) / Double(period.bucketCount)
            buckets = (0..<period.bucketCount).map { MenuBarBucket(id: $0, start: from.addingTimeInterval(Double($0) * width), end: from.addingTimeInterval(Double($0 + 1) * width)) }
            let bucketArgs: [CaptureSQLValue] = [.real(from.timeIntervalSince1970), .real(width)]
            for row in try db.rows("SELECT CAST((wall-?)/? AS INTEGER) AS bucket,\(PayloadArchive.gatewayAggregateSQL),\(PayloadArchive.historicalOutputRateSQL) FROM attempts WHERE \(selected) GROUP BY bucket", bucketArgs + values) {
                // The final slice is closed at `until`; an attempt exactly on it lands in the last bucket.
                guard let raw = row["bucket"]?.number.map(Int.init) else { continue }
                let index = min(raw, buckets.count - 1)
                guard buckets.indices.contains(index) else { continue }
                buckets[index].gateway = PayloadArchive.gatewayTotals(row); buckets[index].historicalRate = PayloadArchive.historicalOutputRate(row)
            }
        }
        return MenuBarSnapshot(period: period, from: from, until: until, counts: counts, gateway: totals,
                               workspaces: count("workspaces"), sessions: sessionCount, compactionRequests: count("compactions"), costUnreported: count("cost_unreported"), costInvalid: count("cost_invalid"), costConflicts: count("cost_conflicts"),
                               models: models, modelGroups: groupCount, offset: offset, historicalRate: cached?.historicalRate ?? PayloadArchive.historicalOutputRate(summary), buckets: buckets, summaryReadAt: cached?.summaryReadAt ?? Date(), modelPageReadAt: Date())
    }

}

extension PayloadArchive {
    // Projection already validates ordinary metadata. Explicit finite bounds
    // also keep corrupt/legacy typed values out of the rate sample population.
    static let historicalOutputRateSQL: String = {
        let sample = "outcome='completed' AND dispatch IS NOT NULL AND output_tokens>=0 AND output_tokens<=1.7976931348623157e308 AND request_ms>0 AND request_ms<=1.7976931348623157e308"
        return "SUM(CASE WHEN \(sample) THEN output_tokens END) AS rate_output_tokens,SUM(CASE WHEN \(sample) THEN request_ms END) AS rate_generation_ms,COUNT(CASE WHEN \(sample) THEN 1 END) AS rate_samples"
    }()

    static func historicalOutputRate(_ row: [String: CaptureSQLValue]) -> HistoricalOutputRate {
        HistoricalOutputRate(outputTokens: row["rate_output_tokens"]?.double ?? 0, generationMilliseconds: row["rate_generation_ms"]?.double ?? 0, samples: Int(row["rate_samples"]?.number ?? 0))
    }
}

func menuBarTokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
    return value.formatted(.number.precision(.fractionLength(0)))
}

/// Sidebar-sized token figure: 812, 1.2k, 12k, 1.2M. Missing usage is n/a.
func compactTokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "n/a" }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1000).replacingOccurrences(of: ".0k", with: "k") }
    return String(format: "%.0f", value)
}
