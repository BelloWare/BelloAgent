import Foundation

/// Only gateway-reported monetary values are accumulated. Provider prompt-cache
/// tokens are separate from a LiteLLM response-cache hit.
struct GatewayObservation: Sendable, Equatable {
    var costUSD: Double?
    var costStatus = "unreported"
    var cacheStatus = "unreported"
    var cacheReadTokens: Double?
    var cacheWriteTokens: Double?
    var inputTokens: Double?
    var outputTokens: Double?
    var reasoningTokens: Double?
    var reasoningCostUSD: Double?
    var reasoningCostStatus = "unreported"

    /// A status the gateway sent, if it is one this build knows; anything else,
    /// a missing one included, reads as unreported rather than as itself.
    private static func reported(_ status: String?, among known: [String]) -> String {
        guard let status, known.contains(status) else { return "unreported" }
        return status
    }

    init(metadata: [String: WireValue]) {
        let gateway = metadata["gateway"]?.object ?? [:]
        let cost = gateway["cost"]?.object ?? [:]
        let cache = gateway["cache"]?.object ?? [:]
        if gateway["version"]?.number == 1 {
            costStatus = Self.reported(cost["status"]?.string, among: ["reported", "unreported", "invalid", "conflict"])
            if costStatus == "reported", let value = cost["usd"]?.number, value.isFinite, value >= 0, value <= 1_000_000_000_000 { costUSD = value }
            else if costStatus == "reported" { costStatus = "invalid" }
            cacheStatus = Self.reported(cache["status"]?.string, among: ["hit", "miss", "unreported", "invalid", "conflict"])
            let reasoning = gateway["costBreakdown"]?.object?["reasoning"]?.object ?? [:]
            reasoningCostStatus = Self.reported(reasoning["status"]?.string, among: ["reported", "unreported", "invalid", "conflict"])
            if reasoningCostStatus == "reported", let value = reasoning["usd"]?.number, value.isFinite, value >= 0, value <= 1_000_000_000_000 { reasoningCostUSD = value }
            else if reasoningCostStatus == "reported" { reasoningCostStatus = "invalid" }
        }
        let usage = metadata["usage"]?.object ?? [:]
        func tokens(_ key: String) -> Double? {
            guard let value = usage[key]?.number, value.isFinite, value >= 0, value <= 1_000_000_000_000, value.rounded() == value else { return nil }
            return value
        }
        cacheReadTokens = tokens("cacheRead"); cacheWriteTokens = tokens("cacheWrite")
        // Both native adapters supply this normalized input value. Responses
        // already includes cached input; Messages adds its separate cache
        // fields in the adapter. Adding cache again here would overcount.
        // Older/missing usage is unavailable, never inferred from raw bodies.
        inputTokens = tokens("inputIncludingCache"); outputTokens = tokens("output")
        reasoningTokens = tokens("reasoning")
        if let reasoningTokens, let outputTokens, reasoningTokens > outputTokens { self.reasoningTokens = nil }
        if let reasoningCostUSD, let costUSD, reasoningCostUSD > costUSD + max(1e-12, abs(costUSD) * 1e-9) { self.reasoningCostUSD = nil; reasoningCostStatus = "conflict" }
    }
}

struct GatewayTokenTotals: Codable, Sendable, Equatable {
    var input: Double?
    var output: Double?
    /// Only attempts reporting both components contribute to this total.
    var total: Double?
    var inputSamples = 0
    var outputSamples = 0
    var samples = 0
    /// A subset of output, never added to total. Optional for old snapshots.
    var reasoning: Double?
    var reasoningSamples: Int? = 0
}

/// Model labels follow sourced response-body reports. This presentation does
/// not alter the stricter identity used for replay or accounting diagnostics.
struct GatewayModelIdentity: Equatable {
    struct Report: Equatable {
        let name: String
        let source: String
    }
    let response: Report?
    let bodyReports: [Report]
    let headerReports: [Report]
    let legacyModel: String?

    init(metadata: [String: WireValue]) {
        let identity = metadata["identity"]?.object ?? [:]
        var body: [Report] = [], headers: [Report] = []
        var preferred: Report?, preferredRank = -1
        for value in (identity["evidence"]?.array ?? []).prefix(32) {
            guard let item = value.object, item["kind"]?.string == "model",
                  let name = Self.modelName(item["value"]?.string),
                  let source = item["source"]?.string else { continue }
            let report = Report(name: name, source: source)
            if let rank = Self.bodyRank(source) {
                if !body.contains(report) { body.append(report) }
                // Evidence is ordered as observed. Within one source class,
                // use its most recent report, never a lexical/shortest name.
                if rank >= preferredRank { preferred = report; preferredRank = rank }
            } else if source.hasPrefix("header:"), source.utf8.count <= 135,
                      source.dropFirst(7).range(of: "^[a-z0-9-]{1,128}$", options: .regularExpression) != nil {
                if !headers.contains(report) { headers.append(report) }
            }
        }
        response = preferred; bodyReports = body; headerReports = headers
        let status = identity["status"]?.string ?? (identity["effectiveModel"]?.string == nil ? "unreported" : "reported")
        if status == "reported",
           let value = Self.modelName(identity["effectiveModel"]?.string), value != metadata["requestedModel"]?.string {
            legacyModel = value
        } else { legacyModel = nil }
    }

    var displayName: String? { response?.name ?? legacyModel }

    static func modelName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 256, !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
        return value
    }

    private static func bodyRank(_ source: String) -> Int? {
        switch source {
        case "body.router_model_name", "response.completed.response.router_model_name", "response.incomplete.response.router_model_name", "response.failed.response.router_model_name": return 60
        case "response.in_progress.response.router_model_name": return 51
        case "response.created.response.router_model_name": return 50
        case "body.model", "response.completed.response.model", "response.incomplete.response.model", "response.failed.response.model": return 40
        case "response.in_progress.response.model", "message_delta.delta.model": return 31
        case "response.created.response.model", "message_start.message.model": return 30
        default: return nil
        }
    }
}

/// A bounded display projection, never raw routing evidence. Names prefer the
/// literal response body; identity coverage retains its independent meaning.
struct GatewayModelRoute: Codable, Sendable, Equatable {
    var requested: String?
    var responded: String?
    var latestWall: Double = 0
    var label: String {
        if let requested, let responded { return requested == responded ? responded : requested + " → " + responded }
        return requested.map { $0 + " → —" } ?? responded ?? "Model unreported"
    }
    var detail: String { "Requested: \(requested ?? "unreported"); response: \(responded ?? "unreported")" }
    var valid: Bool {
        latestWall.isFinite && latestWall >= 0 && (requested != nil || responded != nil)
            && [requested, responded].allSatisfy { $0 == nil || GatewayModelIdentity.modelName($0) != nil }
    }
}

struct GatewayModelSummary: Codable, Sendable, Equatable {
    var names: [String] = []
    var nameCount = 0
    var reportedRequests = 0
    var unreportedRequests = 0
    var conflictingRequests = 0
    var incompleteRequests = 0
    /// Attempts with a displayable body/legacy name, including disagreements.
    /// Optional so older transcript snapshots keep their original semantics.
    var displayRequests: Int?
    /// Actual dispatch aliases paired with their response reports. Optional
    /// for old cached snapshots; never inferred from today's session picker.
    var routes: [GatewayModelRoute]?
}

struct GatewayTotals: Codable, Sendable, Equatable {
    var requests = 0
    var costSamples = 0
    var costUSD: Double?
    var cacheHits = 0
    var cacheMisses = 0
    var cacheUnreported = 0
    var cacheConflicts = 0
    var cacheReadTokens: Double?
    var cacheWriteTokens: Double?
    var cacheReadSamples = 0
    var cacheWriteSamples = 0
    var expiredRecords = 0
    // Optional keeps older serialized transcript projections decodable.
    var tokens: GatewayTokenTotals?
    /// A reported portion of output cost, never added to costUSD.
    var reasoningCostUSD: Double?
    var reasoningCostSamples: Int? = 0
    /// Populated only for inline message accounting. Old snapshots omit it.
    var models: GatewayModelSummary?
    /// Paired input/cache observations only. Optional for older snapshots.
    var uncachedInputReportedTokens: Double?
    var uncachedInputSamples: Int?
    /// Decode time and output tokens of the completed requests that reported
    /// both, for the settled throughput. Optional for older snapshots.
    var decodeMilliseconds: Double?
    var decodeOutputTokens: Double?
    var decodeSamples: Int?
    /// First-token latency of the requests that recorded it.
    var ttftMilliseconds: Double?
    var ttftSamples: Int?
    /// Distinct turns these requests belong to. Optional for older snapshots;
    /// requests with no turn (a title, a suggestion) are not counted.
    var turnCount: Int?
    /// Wall time of the latest retained request, seconds since 1970, for the sidebar's recency stamp.
    var lastActivity: Double?

    /// Provider output tokens over decode time for this scope, whether that is
    /// one reply, a turn or the whole session's log. A snapshot saved before
    /// the app recorded decode time reports no samples rather than a zero rate.
    var settledThroughput: SettledThroughput {
        SettledThroughput(decodeMilliseconds: decodeMilliseconds ?? 0, outputTokens: decodeOutputTokens ?? 0,
                          samples: decodeSamples ?? 0, requests: requests)
    }
    var settledLatency: SettledLatency {
        SettledLatency(milliseconds: ttftMilliseconds ?? 0, samples: ttftSamples ?? 0, requests: requests)
    }
    /// Reported input plus output, without adding their cache/reasoning
    /// breakdowns again. The session and turn pills use the same definition.
    var billedTotalTokens: Double? {
        var total: Double?, any = false
        func add(_ value: Double?, _ samples: Int) {
            guard samples > 0, let value, value.isFinite, value >= 0 else { return }
            total = (total ?? 0) + value; any = true
        }
        // Responses input already includes cache reads and cache writes.
        add(tokens?.input, tokens?.inputSamples ?? 0)
        add(tokens?.output, tokens?.outputSamples ?? 0)
        return any ? total : nil
    }
    /// The cache-hit share of prompt-side input, honestly rounded.
    var cacheHitPercent: String? {
        guard cacheReadSamples > 0, let read = cacheReadTokens,
              let tokens, tokens.inputSamples > 0, let input = tokens.input else { return nil }
        return MetricFormat.cacheHitPercent(read: read, prompt: input)
    }
    var costLabel: String { gatewayUSD(costUSD) + " · \(costSamples)/\(requests) requests reported" }
    var cacheLabel: String {
        "Cache \(cacheHits) hit · \(cacheMisses) miss · \(cacheUnreported) unreported" + (cacheConflicts > 0 ? " · \(cacheConflicts) invalid/conflicting" : "")
    }
    var tokenCacheLabel: String {
        "Prompt cache read \(cacheReadTokens.map { String(format: "%.0f", $0) } ?? "—") tokens (\(cacheReadSamples)/\(requests) reported) · write \(cacheWriteTokens.map { String(format: "%.0f", $0) } ?? "—") tokens (\(cacheWriteSamples)/\(requests) reported)"
    }
}

struct SessionGatewayAccounting: Sendable {
    var session = GatewayTotals()
    var messages: [String: GatewayTotals] = [:]
    /// Only requested for a loaded chat; sidebar totals do not load chart data.
    var timing: SessionTimingHistory?
}

func gatewayUSD(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Cost unavailable" }
    if value == 0 { return "$0 USD" }
    if value < 0.00000001 { return String(format: "$%.3g USD", value) }
    var text = String(format: "%.8f", value)
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return "$" + text + " USD"
}

/// Turn/footer amount. Retain useful reported precision even in a small
/// label; a micro-cost must never round into zero or a different amount.
func compactGatewayUSD(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "cost n/a" }
    if value == 0 { return "$0" }
    var text = MetricFormat.preciseDecimal(value)
    if value >= 1 {
        if !text.contains(".") { text += ".00" }
        else if text.split(separator: ".").last?.count == 1 { text += "0" }
    }
    return "$" + text
}

extension PayloadArchive {
    static let gatewayAggregateSQL = """
    COUNT(*) AS requests,COUNT(DISTINCT turn) AS turn_count,COUNT(cost_usd) AS cost_samples,SUM(cost_usd) AS cost_usd,
    SUM(cache_status='hit') AS cache_hits,SUM(cache_status='miss') AS cache_misses,
    SUM(cache_status='unreported') AS cache_unreported,SUM(cache_status IN ('invalid','conflict')) AS cache_conflicts,
    SUM(cache_read_tokens) AS cache_read_tokens,SUM(cache_write_tokens) AS cache_write_tokens,
    COUNT(cache_read_tokens) AS cache_read_samples,COUNT(cache_write_tokens) AS cache_write_samples,
    SUM(CASE WHEN input_tokens>=cache_read_tokens THEN input_tokens-cache_read_tokens END) AS uncached_input_tokens,
    COUNT(CASE WHEN input_tokens>=cache_read_tokens THEN 1 END) AS uncached_input_samples,
    SUM(input_tokens) AS input_tokens,SUM(output_tokens) AS output_tokens,
    COUNT(input_tokens) AS input_samples,COUNT(output_tokens) AS output_samples,
    SUM(input_tokens+output_tokens) AS total_tokens,COUNT(input_tokens+output_tokens) AS token_samples,
    SUM(reasoning_tokens) AS reasoning_tokens,COUNT(reasoning_tokens) AS reasoning_samples,
    SUM(reasoning_cost_usd) AS reasoning_cost_usd,COUNT(reasoning_cost_usd) AS reasoning_cost_samples,
    \(settledThroughputSQL),
    SUM(ttft_ms) AS ttft_ms,COUNT(ttft_ms) AS ttft_samples,
    MAX(wall) AS last_wall
    """

    /// The settled rate's population: a completed request that reported both
    /// its decode span (first content to model completion) and its provider
    /// output tokens. Anything else contributes nothing — never a zero.
    static let settledThroughputSQL: String = {
        let sample = "outcome='completed' AND stream_ms>0 AND stream_ms<=1.7976931348623157e308 AND output_tokens>=0 AND output_tokens<=1.7976931348623157e308"
        return "SUM(CASE WHEN \(sample) THEN stream_ms END) AS decode_ms,SUM(CASE WHEN \(sample) THEN output_tokens END) AS decode_output_tokens,COUNT(CASE WHEN \(sample) THEN 1 END) AS decode_samples"
    }()

    static func gatewayTotals(_ row: [String: CaptureSQLValue]) -> GatewayTotals {
        func count(_ key: String) -> Int { Int(row[key]?.number ?? 0) }
        func value(_ key: String) -> Double? { row[key]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        var totals = GatewayTotals(requests: count("requests"), costSamples: count("cost_samples"), costUSD: value("cost_usd"), cacheHits: count("cache_hits"), cacheMisses: count("cache_misses"), cacheUnreported: count("cache_unreported"), cacheConflicts: count("cache_conflicts"), cacheReadTokens: value("cache_read_tokens"), cacheWriteTokens: value("cache_write_tokens"), cacheReadSamples: count("cache_read_samples"), cacheWriteSamples: count("cache_write_samples"))
        totals.reasoningCostUSD = value("reasoning_cost_usd"); totals.reasoningCostSamples = count("reasoning_cost_samples")
        totals.uncachedInputReportedTokens = value("uncached_input_tokens"); totals.uncachedInputSamples = count("uncached_input_samples")
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

    /// Session totals for every retained session at once, for the sidebar. One
    /// grouped query replaces one round trip per chat on restore and refresh.
    func allSessionTotals() throws -> [String: GatewayTotals] {
        try reconcile()
        let db = try dashboardDatabase()
        var totals: [String: GatewayTotals] = [:]
        for row in try db.rows("SELECT session,workspace,\(Self.gatewayAggregateSQL) FROM attempts WHERE metrics_retained=1 AND dispatch IS NOT NULL GROUP BY workspace,session") {
            guard let session = row["session"]?.string, let workspace = row["workspace"]?.string else { continue }
            totals[workspace + "\u{0}" + session] = Self.gatewayTotals(row)
        }
        for row in try db.rows("SELECT session,workspace,COUNT(*) AS n FROM attempts WHERE metrics_retained=0 GROUP BY workspace,session") {
            guard let session = row["session"]?.string, let workspace = row["workspace"]?.string else { continue }
            totals[workspace + "\u{0}" + session, default: GatewayTotals()].expiredRecords = Int(row["n"]?.number ?? 0)
        }
        return totals
    }

    /// A copy action reads fresh compact metadata without opening chats or
    /// scanning every session. Batches stay below older SQLite parameter limits.
    func sessionReferenceTotals(scopes: [SessionUsageScope]) throws -> [SessionUsageScope: GatewayTotals] {
        guard scopes.count <= TopicSessionDrag.maximumSessions,
              Set(scopes).count == scopes.count,
              scopes.allSatisfy({ !$0.sessionID.isEmpty && $0.sessionID.utf8.count <= 128 && !$0.workspaceID.isEmpty && $0.workspaceID.utf8.count <= 128 }) else { throw CaptureFailure.unavailable }
        guard !scopes.isEmpty else { return [:] }
        try Task.checkCancellation()
        try reconcile()
        let db = try dashboardDatabase()
        var totals = Dictionary(uniqueKeysWithValues: scopes.map { ($0, GatewayTotals()) })
        for start in stride(from: 0, to: scopes.count, by: 200) {
            try Task.checkCancellation()
            let batch = scopes[start..<min(start + 200, scopes.count)]
            let wanted = "WITH wanted(session,workspace) AS (VALUES " + batch.map { _ in "(?,?)" }.joined(separator: ",") + ") "
            let args = batch.flatMap { [CaptureSQLValue.text($0.sessionID), .text($0.workspaceID)] }
            let join = "FROM wanted CROSS JOIN attempts ON attempts.session=wanted.session AND attempts.workspace=wanted.workspace"
            for row in try db.rows("\(wanted) SELECT attempts.session,attempts.workspace,\(Self.gatewayAggregateSQL) \(join) WHERE metrics_retained=1 AND dispatch IS NOT NULL GROUP BY attempts.workspace,attempts.session", args) {
                guard let session = row["session"]?.string, let workspace = row["workspace"]?.string else { continue }
                totals[SessionUsageScope(sessionID: session, workspaceID: workspace)] = Self.gatewayTotals(row)
            }
            for row in try db.rows("\(wanted) SELECT attempts.session,attempts.workspace,COUNT(*) AS n \(join) WHERE metrics_retained=0 GROUP BY attempts.workspace,attempts.session", args) {
                guard let session = row["session"]?.string, let workspace = row["workspace"]?.string else { continue }
                totals[SessionUsageScope(sessionID: session, workspaceID: workspace), default: GatewayTotals()].expiredRecords = Int(row["n"]?.number ?? 0)
            }
        }
        return totals
    }

    func gatewayAccounting(sessionID: String, workspaceID: String, messages: [TranscriptMessage], includeTiming: Bool = false) throws -> SessionGatewayAccounting {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 128, !workspaceID.isEmpty, workspaceID.utf8.count <= 128,
              messages.count <= 500, Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }) else { throw CaptureFailure.unavailable }
        try reconcile()
        let db = try dashboardDatabase()
        let scope: [CaptureSQLValue] = [.text(sessionID), .text(workspaceID)]
        let row = try db.rows("SELECT \(Self.gatewayAggregateSQL) FROM attempts WHERE session=? AND workspace=? AND metrics_retained=1 AND dispatch IS NOT NULL", scope).first ?? [:]
        var result = SessionGatewayAccounting(session: Self.gatewayTotals(row))
        result.session.expiredRecords = Int(try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE session=? AND workspace=? AND metrics_retained=0", scope).first?["n"]?.number ?? 0)
        if includeTiming {
            result.timing = try Self.sessionTimingHistory(sessionID: sessionID, workspaceID: workspaceID, until: Date(), db: db)
        }
        guard !messages.isEmpty else { return result }
        // Each attempt has one inline owner on this page: a linked assistant,
        // the current streaming answer, or its user turn until an answer exists.
        // Details still uses the complete message_links table, including tools
        // and later context reuse. Presentation never rewrites those links.
        // Inherited side messages may show their origin, but session totals above
        // include only the selected session's own attempts. CROSS JOIN keeps
        // the bounded target page first: SQLite otherwise may scan all retained
        // attempts before matching the turn or output link. This order uses the
        // turn/output indexes; UNION removes duplicate attribution before summing.
        let values = messages.map { _ in "(?,?,?,?)" }.joined(separator: ",")
        var args: [CaptureSQLValue] = [], latestUser = ""
        for (index, message) in messages.enumerated() {
            if message.role == "user" { latestUser = message.id }
            let pendingTurn = message.role == "assistant" && message.state == "streaming" ? latestUser : ""
            // A compaction summary is a system row but is the visible output of
            // its own model request. It must retain that request's accounting.
            let accountingRole = message.kind == "compaction" ? "assistant" : message.role
            args += [.text(message.id), .text(accountingRole), .integer(Int64(index)), .text(pendingTurn)]
        }
        args += [.text(workspaceID), .text(sessionID), .text(workspaceID), .text(sessionID), .text(workspaceID)]
        let attribution = """
        WITH targets(message,role,position,pending_turn) AS (VALUES \(values)), candidates(message,id,priority,position) AS (
          SELECT t.message,a.id,2,t.position FROM targets t CROSS JOIN attempts a
          WHERE t.role='user' AND a.workspace=? AND a.session=? AND a.turn=t.message
            AND a.metrics_retained=1 AND a.dispatch IS NOT NULL
          UNION ALL
          SELECT t.message,a.id,1,t.position FROM targets t CROSS JOIN attempts a
          WHERE t.pending_turn!='' AND a.workspace=? AND a.session=? AND a.turn=t.pending_turn
            AND a.purpose='turn' AND a.metrics_retained=1 AND a.dispatch IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM message_links l WHERE l.attempt=a.id AND l.role='output')
          UNION ALL
          SELECT t.message,a.id,0,t.position FROM targets t CROSS JOIN message_links l CROSS JOIN attempts a
          WHERE t.role='assistant' AND l.message=t.message AND l.role='output'
            AND a.id=l.attempt AND a.workspace=? AND a.metrics_retained=1 AND a.dispatch IS NOT NULL
        ), attributed AS (
          SELECT message,id,ROW_NUMBER() OVER (PARTITION BY id ORDER BY priority,position) AS owner FROM candidates
        )
        """
        let sql = attribution + """

        SELECT attributed.message,\(Self.gatewayAggregateSQL)
        FROM attributed JOIN attempts a ON a.id=attributed.id
        WHERE attributed.owner=1
        GROUP BY attributed.message
        """
        for row in try db.rows(sql, args) {
            guard let id = row["message"]?.string else { throw CaptureFailure.corrupt }
            result.messages[id] = Self.gatewayTotals(row)
        }
        // Reuse exactly the accounting ownership relation. Body names are a
        // display preference, independent of strict routing identity coverage.
        // Legacy captures without sourced body evidence keep an already
        // verified effective model. No arbitrary header wins a disagreement.
        let resolution = """
        CASE WHEN a.identity_status IN ('conflict','incomplete') THEN a.identity_status
          WHEN a.identity_status='reported' AND a.model IS NOT NULL AND LENGTH(TRIM(a.model))>0 AND a.model<>a.alias THEN 'reported'
          ELSE 'unreported' END
        """
        let modelAttribution = attribution + """
        , model_requests AS (
          SELECT attributed.message,\(resolution) AS resolution,a.wall,a.alias AS requested_model,
            COALESCE(a.response_model,CASE WHEN (\(resolution))='reported' THEN a.model ELSE NULL END) AS display_model
          FROM attributed JOIN attempts a ON a.id=attributed.id
          WHERE attributed.owner=1
        )
        """
        let modelSQL = modelAttribution + """
        , model_groups AS (
          SELECT message,display_model,COUNT(*) AS requests,MAX(wall) AS latest_wall,
            SUM(resolution='reported') AS reported_requests,
            SUM(resolution='unreported') AS unreported_requests,
            SUM(resolution='conflict') AS conflicting_requests,
            SUM(resolution='incomplete') AS incomplete_requests
          FROM model_requests GROUP BY message,display_model
        ), ranked_models AS (
          SELECT *,
            SUM(display_model IS NOT NULL) OVER (PARTITION BY message) AS name_count,
            SUM(CASE WHEN display_model IS NOT NULL THEN requests ELSE 0 END) OVER (PARTITION BY message) AS display_requests,
            SUM(reported_requests) OVER (PARTITION BY message) AS reported_total,
            SUM(unreported_requests) OVER (PARTITION BY message) AS unreported_total,
            SUM(conflicting_requests) OVER (PARTITION BY message) AS conflicting_total,
            SUM(incomplete_requests) OVER (PARTITION BY message) AS incomplete_total,
            ROW_NUMBER() OVER (PARTITION BY message ORDER BY display_model IS NOT NULL DESC,latest_wall DESC,requests DESC,display_model COLLATE BINARY) AS position
          FROM model_groups
        )
        SELECT * FROM ranked_models WHERE position<=8 ORDER BY message,position
        """
        for row in try db.rows(modelSQL, args) {
            guard let id = row["message"]?.string, result.messages[id] != nil else { throw CaptureFailure.corrupt }
            if result.messages[id]?.models == nil {
                func count(_ key: String) -> Int { Int(row[key]?.number ?? 0) }
                result.messages[id]?.models = GatewayModelSummary(nameCount: count("name_count"), reportedRequests: count("reported_total"), unreportedRequests: count("unreported_total"), conflictingRequests: count("conflicting_total"), incompleteRequests: count("incomplete_total"), displayRequests: count("display_requests"))
            }
            if let name = row["display_model"]?.string {
                // The helper normally enforces these bounds. A malformed old
                // archive must not send arbitrary evidence into the transcript.
                guard !name.isEmpty, name.utf8.count <= 256, !name.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw CaptureFailure.corrupt }
                result.messages[id]?.models?.names.append(name)
            }
        }
        // Keep the two names from the same attempt. Independent lists would
        // falsely pair routes when the user changes models mid-turn.
        let routeSQL = modelAttribution + """
        , route_groups AS (
          SELECT message,requested_model,display_model,MAX(wall) AS latest_wall
          FROM model_requests GROUP BY message,requested_model,display_model
        ), ranked_routes AS (
          SELECT *,ROW_NUMBER() OVER (PARTITION BY message ORDER BY latest_wall DESC,display_model IS NOT NULL DESC,requested_model,display_model) AS position
          FROM route_groups
        )
        SELECT * FROM ranked_routes WHERE position<=8 ORDER BY message,position
        """
        for row in try db.rows(routeSQL, args) {
            guard let id = row["message"]?.string, result.messages[id]?.models != nil else { throw CaptureFailure.corrupt }
            let route = GatewayModelRoute(requested: GatewayModelIdentity.modelName(row["requested_model"]?.string),
                responded: GatewayModelIdentity.modelName(row["display_model"]?.string), latestWall: row["latest_wall"]?.double ?? 0)
            guard route.valid else { continue }
            if result.messages[id]?.models?.routes == nil { result.messages[id]?.models?.routes = [] }
            result.messages[id]?.models?.routes?.append(route)
        }
        return result
    }
}

/// The same cost, rounded for a headline. `gatewayUSD` keeps every reported
/// digit because the inspector, the per-request rows and the exports are
/// evidence; a stat tile is not. "$0.0101375 USD" as the biggest figure on the
/// report reads as noise, and the digits that matter — the leading ones — are
/// the hardest to find in it. The exact figure stays in the tile's caption.
func headlineUSD(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Cost unavailable" }
    if value == 0 { return "$0 USD" }
    if value >= 1 { return String(format: "$%.2f USD", value) }
    if value >= 0.0001 { return String(format: "$%.4f USD", value) }
    return gatewayUSD(value)
}
/// True when the headline actually dropped something. A figure the headline
/// can show in full — $0.005 — must not be captioned "exactly $0.005".
func headlineUSDRounded(_ value: Double?) -> Bool {
    guard let value, value.isFinite, value > 0 else { return false }
    let shown = value >= 1 ? (value * 100).rounded() / 100
        : value >= 0.0001 ? (value * 10_000).rounded() / 10_000 : value
    return abs(shown - value) > value * 1e-9
}
