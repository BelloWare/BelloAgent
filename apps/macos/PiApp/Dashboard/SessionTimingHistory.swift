import Foundation

/// A single completed HTTP request, not a session average. Missing usage and
/// timings stay missing; a reported zero is a valid observation.
struct SessionTimingSample: Sendable, Equatable, Identifiable {
    let id: String
    let wall: Date
    let ttftMilliseconds: Double?
    let streamingMilliseconds: Double?
    /// Dispatch through model completion, independent of visible first content.
    let requestMilliseconds: Double?
    let outputTokens: Double?
    /// Gateway-reported cost of this request, when reported.
    let costUSD: Double?
    /// What the ledger names the request: its outcome, the API it went out on
    /// and the model the response reported (else the requested alias).
    let outcome: String
    let api: String
    let model: String?
    /// Prompt-side usage as reported: input already includes cached input.
    let inputTokens: Double?
    let cacheReadTokens: Double?
    let cacheWriteTokens: Double?
    let reasoningTokens: Double?
    /// The turn (the user message id) the request served, and why it was
    /// sent: "turn", "compaction" and so on. Nil where the read had neither.
    let turn: String?
    let purpose: String?

    init(id: String, wall: Date, ttftMilliseconds: Double?, streamingMilliseconds: Double?, outputTokens: Double?, costUSD: Double? = nil, requestMilliseconds: Double? = nil,
         outcome: String = "completed", api: String = "", model: String? = nil,
         inputTokens: Double? = nil, cacheReadTokens: Double? = nil, cacheWriteTokens: Double? = nil, reasoningTokens: Double? = nil,
         turn: String? = nil, purpose: String? = nil) {
        self.id = id; self.wall = wall
        self.ttftMilliseconds = Self.observed(ttftMilliseconds)
        self.streamingMilliseconds = Self.observed(streamingMilliseconds)
        self.requestMilliseconds = Self.observed(requestMilliseconds)
        self.outputTokens = Self.observed(outputTokens)
        self.costUSD = Self.observed(costUSD)
        self.outcome = outcome; self.api = api; self.model = model
        self.inputTokens = Self.observed(inputTokens); self.cacheReadTokens = Self.observed(cacheReadTokens)
        self.cacheWriteTokens = Self.observed(cacheWriteTokens); self.reasoningTokens = Self.observed(reasoningTokens)
        self.turn = turn.flatMap { $0.isEmpty ? nil : $0 }; self.purpose = purpose.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The settled rate of this one request: its output tokens after the first
    /// over its decode span (first to last output). Nil unless it completed
    /// with two or more tokens over a span past the floor.
    var settledTokensPerSecond: Double? {
        guard outcome == "completed" else { return nil }
        var fold = SettledThroughput()
        fold.add(decodeMilliseconds: streamingMilliseconds, outputTokens: outputTokens)
        return fold.tokensPerSecond
    }
    /// Input that was not served from cache, only when both halves were reported.
    var uncachedInputTokens: Double? {
        guard let inputTokens, let cacheReadTokens, cacheReadTokens <= inputTokens else { return nil }
        return inputTokens - cacheReadTokens
    }

    private static func observed(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// Only the latest completed request supplies the current figure. A running
/// request does not replace it, and a completion lacking usage stays missing.
struct SessionRatePresentation: Equatable {
    static let explanation = SettledThroughput.explanation + " The latest completed request stays visible while the next one runs."
    let latest: Double?
    let average: Double?
    let hasCompletion: Bool
    init(history: SessionTimingHistory) {
        latest = history.latest?.settledTokensPerSecond
        average = (history.historicalSettledThroughput ?? history.settledThroughput).tokensPerSecond
        hasCompletion = history.latest != nil
    }
    var label: String {
        latest.map { "Latest " + Self.compactRate($0) } ?? (hasCompletion ? "Usage unavailable" : "Awaiting usage")
    }
    /// The sidebar gives this label a fixed 108-point slot. A fast route
    /// reporting five or six digits ran past it and was cut mid-number
    /// ("Latest 126397 to…"), which reads as a broken figure rather than a
    /// fast one. Four digits and up are abbreviated so the number always
    /// finishes; the exact rate stays in Session info and in the help.
    static func compactRate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return SessionTimingMetric.rate.label(value) }
        // Each unit starts where the one below would round up to a thousand
        // of itself: 999,600 tok/s is "1M", never "1000k".
        if value >= 999_500 { return String(format: "%.1fM tok/s", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 10_000 { return String(format: "%.0fk tok/s", value / 1_000) }
        if value >= 999.5 { return String(format: "%.1fk tok/s", value / 1_000).replacingOccurrences(of: ".0k", with: "k") }
        return SessionTimingMetric.rate.label(value)
    }
}

struct SessionTimingHistory: Sendable, Equatable {
    static let limit = 128
    /// Chronological request order. Kept small even for very long sessions.
    var samples: [SessionTimingSample] = []
    var hasOlderRequests = false
    /// The session figure and its coverage include every retained completed
    /// request in this session, not only the bounded chart samples.
    var completedRequests = 0
    var historicalSettledThroughput: SettledThroughput? = nil
    /// Ledger includes failed/interrupted requests; timing charts remain completed-only.
    var ledgerSamples: [SessionTimingSample]? = nil
    var hasOlderLedgerRequests: Bool? = nil
    var latest: SessionTimingSample? { samples.last }

    /// The settled rate over the retained samples. The whole-log figure comes
    /// from the session's `GatewayTotals`; this one covers what the ledger
    /// actually lists, so the table and its footnote cannot disagree.
    var settledThroughput: SettledThroughput {
        var fold = SettledThroughput()
        for sample in samples { fold.add(decodeMilliseconds: sample.streamingMilliseconds, outputTokens: sample.outputTokens) }
        return fold
    }

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
        case .rate: "Output tokens per second (decode)"
        case .output: "Output tokens per request"
        case .cost: "Reported cost per request"
        }
    }
    var unit: String { switch self { case .ttft: "ms"; case .rate: "tok/s"; case .output: "tokens"; case .cost: "USD" } }
    var symbol: String { switch self { case .ttft: "timer"; case .rate: "speedometer"; case .output: "number"; case .cost: "dollarsign.circle" } }
    func value(in sample: SessionTimingSample) -> Double? {
        switch self {
        case .ttft: sample.ttftMilliseconds
        case .rate: sample.settledTokensPerSecond
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
    /// What every per-request read selects, so Session info, its ledger and
    /// the statistics popovers decode one request the same way.
    static let sessionRequestColumns = "id,wall,turn,purpose,ttft_ms,stream_ms,request_ms,output_tokens,cost_usd,outcome,api,alias,model,response_model,input_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens"

    /// One retained request, as the charts and the ledger read it. The
    /// response body's name when there is one, else the alias the request
    /// asked for. A malformed archive never reaches a chart.
    static func sessionRequestSample(_ row: [String: CaptureSQLValue]) throws -> SessionTimingSample {
        guard let id = row["id"]?.string, let wall = row["wall"]?.double, wall.isFinite, wall >= 0 else { throw CaptureFailure.corrupt }
        let model = GatewayModelIdentity.modelName(row["response_model"]?.string) ?? GatewayModelIdentity.modelName(row["model"]?.string) ?? GatewayModelIdentity.modelName(row["alias"]?.string)
        return SessionTimingSample(id: id, wall: Date(timeIntervalSince1970: wall), ttftMilliseconds: row["ttft_ms"]?.double,
                                   streamingMilliseconds: row["stream_ms"]?.double, outputTokens: row["output_tokens"]?.double, costUSD: row["cost_usd"]?.double,
                                   requestMilliseconds: row["request_ms"]?.double,
                                   outcome: row["outcome"]?.string ?? "", api: row["api"]?.string ?? "", model: model,
                                   inputTokens: row["input_tokens"]?.double, cacheReadTokens: row["cache_read_tokens"]?.double,
                                   cacheWriteTokens: row["cache_write_tokens"]?.double, reasoningTokens: row["reasoning_tokens"]?.double,
                                   turn: row["turn"]?.string, purpose: row["purpose"]?.string)
    }

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
        let retainedScope = "session=? AND workspace=? AND metrics_retained=1 AND wall<? AND dispatch IS NOT NULL"
        let scope = retainedScope + " AND outcome='completed'"
        let values: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID), .real(until.timeIntervalSince1970)]
        let summary = try db.rows("SELECT \(Self.settledThroughputSQL),COUNT(*) AS completed_requests FROM attempts WHERE \(scope)", values).first ?? [:]
        try Task.checkCancellation()
        func requestRows(_ scope: String) throws -> [[String: CaptureSQLValue]] {
            try db.rows("""
            SELECT \(Self.sessionRequestColumns) FROM attempts
            WHERE \(scope)
            ORDER BY wall DESC,id DESC LIMIT ?
            """, values + [.integer(Int64(SessionTimingHistory.limit + 1))])
        }
        let rows = try requestRows(scope)
        let ledgerRows = try requestRows(retainedScope)
        try Task.checkCancellation()
        let samples = try rows.prefix(SessionTimingHistory.limit).reversed().map(Self.sessionRequestSample)
        let ledger = try ledgerRows.prefix(SessionTimingHistory.limit).reversed().map(Self.sessionRequestSample)
        let settled = SettledThroughput(decodeMilliseconds: summary["decode_ms"]?.double ?? 0,
                                        outputTokens: summary["decode_output_tokens"]?.double ?? 0,
                                        samples: Int(summary["decode_samples"]?.number ?? 0),
                                        requests: Int(summary["completed_requests"]?.number ?? 0))
        return SessionTimingHistory(samples: samples, hasOlderRequests: rows.count > SessionTimingHistory.limit,
                                    completedRequests: Int(summary["completed_requests"]?.number ?? 0),
                                    historicalSettledThroughput: settled, ledgerSamples: ledger,
                                    hasOlderLedgerRequests: ledgerRows.count > SessionTimingHistory.limit)
    }
}
