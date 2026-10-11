// App-side oracle: Swift 0.1.122's unchanged MetricFormats.swift,
// GatewayAccounting.swift, SessionStatsPills.swift, SessionTimingHistory.swift,
// MenuBarMetrics.swift, TranscriptActivity.swift and SessionReference.swift.
// The archive's own SQL (gateway-aggregate.sql) sums each session's requests
// in SQLite; `totals(_:)` below repeats `PayloadArchive.gatewayTotals(row)`
// line for line.
import Foundation
import SQLite3

func load(_ path: String) -> Any { try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: path)!, options: [.fragmentsAllowed]) }
func wire(_ value: Any) -> WireValue {
    switch value {
    case let v as String: return .string(v)
    case let v as NSNumber:
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
        return .number(v.doubleValue)
    case let v as [Any]: return .array(v.map(wire))
    case let v as [String: Any]: return .object(v.mapValues(wire))
    default: return .null
    }
}
func opt(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
func opt(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

// MARK: Usage and cost of one request (GatewayObservation)
let helper = load(CommandLine.arguments[1]) as! [[String: Any]]
var observations: [[String: Any]] = []
for c in helper {
    let o = GatewayObservation(metadata: ["usage": wire(c["usage"]!), "gateway": wire(c["gateway"]!)])
    observations.append(["name": c["name"]!, "input": opt(o.inputTokens), "output": opt(o.outputTokens), "cacheRead": opt(o.cacheReadTokens),
                         "cacheWrite": opt(o.cacheWriteTokens), "reasoning": opt(o.reasoningTokens), "costStatus": o.costStatus, "costUSD": opt(o.costUSD)])
}

// MARK: Formats
let formats = load(CommandLine.arguments[2]) as! [String: Any]
var formatOut: [String: Any] = [:]
formatOut["tokens"] = (formats["numbers"] as! [Double]).map { ["value": $0, "tokens": MetricFormat.tokens($0), "tokenCount": MetricFormat.tokenCount($0),
    "rowTokenCount": MetricFormat.rowTokenCount($0), "compactTokens": compactTokens($0), "menuBarTokens": menuBarTokens($0),
    "latency": MetricFormat.latency($0), "throughput": MetricFormat.throughput($0), "compactRate": SessionRatePresentation.compactRate($0)] as [String: Any] }
formatOut["money"] = (formats["money"] as! [Double]).map { ["value": $0, "exactUSD": MetricFormat.exactUSD($0), "gatewayUSD": gatewayUSD($0),
    "compactGatewayUSD": compactGatewayUSD($0), "preciseDecimal": MetricFormat.preciseDecimal($0),
    "centsUSD": $0 > 0 ? MetricFormat.centsUSD($0, places: 4, padded: true) : NSNull()] as [String: Any] }
formatOut["cacheHit"] = (formats["cacheHit"] as! [[Double]]).map { ["read": $0[0], "prompt": $0[1],
    "percent": opt(MetricFormat.cacheHitPercent(read: $0[0], prompt: $0[1])), "padded": opt(MetricFormat.paddedCacheHitPercent(read: $0[0], prompt: $0[1]))] as [String: Any] }
formatOut["occupancy"] = (formats["occupancy"] as! [Double]).map { ["fraction": $0, "percent": opt(MetricFormat.occupancyPercent($0)),
    "detail": opt(MetricFormat.occupancyPercent($0, decimals: 1))] as [String: Any] }

// MARK: Sessions: the archive's SQL, then the pills and the reference
let sql = String(decoding: FileManager.default.contents(atPath: CommandLine.arguments[4])!, as: UTF8.self)
func aggregate(_ records: [[String: Any]]) -> [String: CaptureSQLValue] {
    var db: OpaquePointer?
    sqlite3_open(":memory:", &db)
    sqlite3_exec(db, "CREATE TABLE attempts(outcome TEXT,turn TEXT,cost_usd REAL,cache_status TEXT,cache_read_tokens INTEGER,cache_write_tokens INTEGER,input_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER,reasoning_cost_usd REAL,stream_ms REAL,ttft_ms REAL,wall REAL)", nil, nil, nil)
    for r in records {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO attempts VALUES(?,?,?,'unreported',?,?,?,?,?,NULL,?,?,?)", -1, &stmt, nil)
        let usage = r["usage"] as? [String: Any] ?? [:], cost = r["cost"] as? [String: Any] ?? [:]
        func text(_ i: Int32, _ v: Any?) { if let s = v as? String { sqlite3_bind_text(stmt, i, strdup(s), -1, free) } else { sqlite3_bind_null(stmt, i) } }
        func int(_ i: Int32, _ v: Any?) { if let n = v as? NSNumber { sqlite3_bind_int64(stmt, i, n.int64Value) } else { sqlite3_bind_null(stmt, i) } }
        func real(_ i: Int32, _ v: Any?) { if let n = v as? NSNumber { sqlite3_bind_double(stmt, i, n.doubleValue) } else { sqlite3_bind_null(stmt, i) } }
        text(1, r["outcome"]); text(2, r["turn"]); real(3, (cost["status"] as? String) == "reported" ? cost["usd"] : nil)
        int(4, usage["cache_read"]); int(5, usage["cache_write"]); int(6, usage["input"]); int(7, usage["output"]); int(8, usage["reasoning"])
        real(9, r["stream_ms"]); real(10, r["ttft_ms"]); real(11, r["wall"])
        sqlite3_step(stmt); sqlite3_finalize(stmt)
    }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    var row: [String: CaptureSQLValue] = [:]
    if sqlite3_step(stmt) == SQLITE_ROW {
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
            default: row[name] = .null
            }
        }
    }
    sqlite3_finalize(stmt); sqlite3_close(db)
    return row
}
/// `PayloadArchive.gatewayTotals(row)`, line for line.
func totals(_ row: [String: CaptureSQLValue]) -> GatewayTotals {
    func count(_ key: String) -> Int { Int(row[key]?.number ?? 0) }
    func value(_ key: String) -> Double? { row[key]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    var totals = GatewayTotals(requests: count("requests"), costSamples: count("cost_samples"), costUSD: value("cost_usd"), cacheHits: count("cache_hits"), cacheMisses: count("cache_misses"), cacheUnreported: count("cache_unreported"), cacheConflicts: count("cache_conflicts"), cacheReadTokens: value("cache_read_tokens"), cacheWriteTokens: value("cache_write_tokens"), cacheReadSamples: count("cache_read_samples"), cacheWriteSamples: count("cache_write_samples"))
    totals.reasoningCostUSD = value("reasoning_cost_usd"); totals.reasoningCostSamples = count("reasoning_cost_samples")
    totals.uncachedInputReportedTokens = value("uncached_input_tokens"); totals.uncachedInputSamples = count("uncached_input_samples")
    if let total = value("split_input_total"), let part = value("split_input_part") {
        totals.inputSplit = GatewayTokenSplit(total: total, part: part, samples: count("uncached_input_samples"))
    }
    if let total = value("split_output_total"), let part = value("split_output_part") {
        totals.outputSplit = GatewayTokenSplit(total: total, part: part, samples: count("split_output_samples"))
    }
    totals.decodeMilliseconds = value("decode_ms"); totals.decodeOutputTokens = value("decode_output_tokens"); totals.decodeSamples = count("decode_samples")
    totals.ttftMilliseconds = value("ttft_ms"); totals.ttftSamples = count("ttft_samples")
    totals.turnCount = count("turn_count")
    totals.lastActivity = value("last_wall")
    if count("input_samples") > 0 || count("output_samples") > 0 || count("reasoning_samples") > 0 {
        totals.tokens = GatewayTokenTotals(input: value("input_tokens"), output: value("output_tokens"), total: value("total_tokens"), inputSamples: count("input_samples"), outputSamples: count("output_samples"), samples: count("token_samples"))
        totals.tokens?.reasoning = value("reasoning_tokens"); totals.tokens?.reasoningSamples = count("reasoning_samples")
    }
    return totals
}
let sessions = load(CommandLine.arguments[3]) as! [[String: Any]]
var sessionOut: [[String: Any]] = []
for s in sessions {
    let records = s["records"] as! [[String: Any]]
    let g = totals(aggregate(records))
    let stats = SessionStatsPresentation(gateway: g, work: Optional<WorkSplit>.none)
    let reference = SessionReference(chat: ChatRecord(), usage: g).text.components(separatedBy: "\n")
    let usageLines = Array(reference.dropFirst(4).prefix { !$0.isEmpty })
    // `SessionRatePresentation` over the completed requests, in order.
    let samples = records.filter { ($0["outcome"] as? String) == "completed" }.enumerated().map { i, r in
        SessionTimingSample(id: "\(i)", wall: Date(timeIntervalSince1970: (r["wall"] as? Double) ?? 0), ttftMilliseconds: r["ttft_ms"] as? Double,
                            streamingMilliseconds: r["stream_ms"] as? Double, outputTokens: ((r["usage"] as? [String: Any])?["output"] as? NSNumber)?.doubleValue)
    }
    let rate = SessionRatePresentation(history: SessionTimingHistory(samples: samples))
    sessionOut.append(["name": s["name"]!, "requests": g.requests, "turns": stats.turns, "billedTotal": opt(g.billedTotalTokens),
        "cacheHit": opt(g.cacheHitPercent), "throughput": opt(g.settledThroughput.tokensPerSecond), "ttft": opt(g.settledLatency.average),
        "gauge": stats.gaugeLabel, "usage": stats.usageLabel, "usageFace": stats.usageFace.label, "compactUsageFace": stats.compactUsageFace.label,
        "hasUsage": stats.hasUsage, "costFigure": opt(stats.costFigure), "referenceUsage": usageLines, "latestRate": opt(rate.label),
        "lastActivity": opt(g.lastActivity)])
}
let out: [String: Any] = ["observations": observations, "formats": formatOut, "sessions": sessionOut]
print(String(decoding: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]), as: UTF8.self))
