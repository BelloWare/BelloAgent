import Foundation

/// A single completed HTTP request, not a session average. Missing usage and
/// timings stay missing; a reported zero is a valid observation.
struct SessionTimingSample: Sendable, Equatable, Identifiable {
    let id: String
    let wall: Date
    let ttftMilliseconds: Double?
    let streamingMilliseconds: Double?
    let outputTokens: Double?
    /// Gateway-reported cost of this request, when reported.
    let costUSD: Double?

    init(id: String, wall: Date, ttftMilliseconds: Double?, streamingMilliseconds: Double?, outputTokens: Double?, costUSD: Double? = nil) {
        self.id = id; self.wall = wall
        self.ttftMilliseconds = Self.observed(ttftMilliseconds)
        self.streamingMilliseconds = Self.observed(streamingMilliseconds)
        self.outputTokens = Self.observed(outputTokens)
        self.costUSD = Self.observed(costUSD)
    }

    var outputTokensPerSecond: Double? {
        guard let outputTokens, let ttftMilliseconds, let streamingMilliseconds else { return nil }
        let duration = ttftMilliseconds + streamingMilliseconds
        guard duration.isFinite, duration > 0 else { return nil }
        let rate = outputTokens / (duration / 1_000)
        return rate.isFinite ? rate : nil
    }

    private static func observed(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

struct SessionTimingHistory: Sendable, Equatable {
    static let limit = 128
    /// Chronological request order. Kept small even for very long sessions.
    var samples: [SessionTimingSample] = []
    var hasOlderRequests = false
    /// The weighted average and coverage include every retained completed
    /// request in this session, not only the bounded chart samples.
    var historicalRate = HistoricalOutputRate()
    var completedRequests = 0
    var latest: SessionTimingSample? { samples.last }

    func points(for metric: SessionTimingMetric) -> [SessionTimingPlotPoint] {
        var segment = 0
        return samples.enumerated().compactMap { index, sample in
            guard let value = metric.value(in: sample) else { segment += 1; return nil }
            return SessionTimingPlotPoint(id: sample.id, index: index + 1, segment: segment, value: value, wall: sample.wall)
        }
    }
}

enum SessionTimingMetric: String, CaseIterable {
    case ttft, rate, output, cost
    /// The footer popover shows the two response-speed metrics; the session
    /// usage window shows all four.
    static let footerMetrics: [SessionTimingMetric] = [.ttft, .rate]
    var title: String {
        switch self {
        case .ttft: "Time to first token"
        case .rate: "Output tokens per second"
        case .output: "Output tokens per request"
        case .cost: "Reported cost per request"
        }
    }
    var unit: String { switch self { case .ttft: "ms"; case .rate: "tok/s"; case .output: "tokens"; case .cost: "USD" } }
    var symbol: String { switch self { case .ttft: "timer"; case .rate: "speedometer"; case .output: "number"; case .cost: "dollarsign.circle" } }
    func value(in sample: SessionTimingSample) -> Double? {
        switch self {
        case .ttft: sample.ttftMilliseconds
        case .rate: sample.outputTokensPerSecond
        case .output: sample.outputTokens
        case .cost: sample.costUSD
        }
    }
    func label(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        if self == .cost { return gatewayUSD(value) }
        return String(format: value > 0 && value < 1 ? "%.2f %@" : "%.0f %@", value, unit)
    }
}

struct SessionTimingPlotPoint: Identifiable {
    let id: String
    let index: Int
    let segment: Int
    let value: Double
    let wall: Date
}

extension PayloadArchive {
    /// Reads typed retained metrics only. A fork or side chat does not inherit
    /// its parent's request history through transcript message links.
    func sessionTimingHistory(sessionID: String, workspaceID: String, until: Date = Date()) throws -> SessionTimingHistory {
        try reconcile()
        return try Self.sessionTimingHistory(sessionID: sessionID, workspaceID: workspaceID, until: until, db: dashboardDatabase())
    }

    static func sessionTimingHistory(sessionID: String, workspaceID: String, until: Date, db: CaptureDatabase) throws -> SessionTimingHistory {
        guard [sessionID, workspaceID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }),
              until.timeIntervalSince1970.isFinite, until.timeIntervalSince1970 >= 0 else { throw CaptureFailure.unavailable }
        try Task.checkCancellation()
        let scope = "session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL AND outcome='completed'"
        let values: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID), .real(until.timeIntervalSince1970)]
        let summary = try db.rows("SELECT \(Self.historicalOutputRateSQL),COUNT(*) AS completed_requests FROM attempts WHERE \(scope)", values).first ?? [:]
        try Task.checkCancellation()
        let rows = try db.rows("""
        SELECT id,wall,ttft_ms,stream_ms,output_tokens,cost_usd FROM attempts
        WHERE \(scope)
        ORDER BY wall DESC,id DESC LIMIT ?
        """, values + [.integer(Int64(SessionTimingHistory.limit + 1))])
        let samples = try rows.prefix(SessionTimingHistory.limit).reversed().map { row -> SessionTimingSample in
            guard let id = row["id"]?.string, let wall = row["wall"]?.double, wall.isFinite, wall >= 0 else { throw CaptureFailure.corrupt }
            return SessionTimingSample(id: id, wall: Date(timeIntervalSince1970: wall), ttftMilliseconds: row["ttft_ms"]?.double,
                                       streamingMilliseconds: row["stream_ms"]?.double, outputTokens: row["output_tokens"]?.double, costUSD: row["cost_usd"]?.double)
        }
        try Task.checkCancellation()
        return SessionTimingHistory(samples: samples, hasOlderRequests: rows.count > SessionTimingHistory.limit,
                                    historicalRate: Self.historicalOutputRate(summary), completedRequests: Int(summary["completed_requests"]?.number ?? 0))
    }
}
