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

/// The parent and subset from the SAME requests. Missing observations on a
/// later request must not erase a previously reported token split.
struct GatewayTokenSplit: Codable, Sendable, Equatable {
    var total: Double
    var part: Double
    var samples: Int
    var valid: Bool { samples > 0 && total.isFinite && part.isFinite && part >= 0 && total >= part }
    func adding(_ other: Self) -> Self {
        Self(total: total + other.total, part: part + other.part, samples: samples + other.samples)
    }
    static func reported(_ gateway: GatewayTotals, input: Bool) -> Self? {
        if let pair = input ? gateway.inputSplit : gateway.outputSplit { return pair.valid ? pair : nil }
        // Compatibility for older snapshots: only full, matching coverage can
        // establish that these independently stored totals share a population.
        let samples = input ? gateway.tokens?.inputSamples : gateway.tokens?.outputSamples
        let partSamples = input ? gateway.cacheReadSamples : gateway.tokens?.reasoningSamples
        guard gateway.requests > 0, samples == gateway.requests, partSamples == gateway.requests,
              let total = input ? gateway.tokens?.input : gateway.tokens?.output,
              let part = input ? gateway.cacheReadTokens : gateway.tokens?.reasoning else { return nil }
        let result = Self(total: total, part: part, samples: gateway.requests)
        return result.valid ? result : nil
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

    /// What answered, from sourced reports: the response body's name by the
    /// same ranking, else the gateway header's when every header names one
    /// model. A header that disagrees with the body is the route the gateway
    /// reported (`routedVia`); the body still says what answered.
    static func answered(_ reports: [Report]) -> String? {
        var preferred: Report?, rank = -1
        for report in reports { if let r = bodyRank(report.source), r >= rank { preferred = report; rank = r } }
        if let preferred { return preferred.name }
        let headers = Set(reports.filter { $0.source.hasPrefix("header:") }.map(\.name))
        return headers.count == 1 ? headers.first : nil
    }
    /// The first other model name reported for the same request, when the
    /// reports disagree with what answered. `openai/x` and `x` agree, and
    /// read as `x`, as the log keeps them.
    static func routedVia(_ names: [String], answered: String?) -> String? {
        guard let answered else { return nil }
        return names.first { comparable($0) != comparable(answered) }.map(comparable)
    }
    static func comparable(_ name: String) -> String { name.hasPrefix("openai/") ? String(name.dropFirst(7)) : name }

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

/// A message's requests that reported neither input nor output, by what
/// became of them: still running, ended before finishing, or completed with
/// no usage from the gateway. Counted in the same pass as the totals.
/// What the request log holds of the request a reply's own record names.
enum ReplyLog: String, Sendable {
    /// No row: the capture never reached the log.
    case absent
    /// Its row's metrics expired.
    case expired
    /// A row the page does not count: it cannot say more, and neither does the report.
    case elsewhere
    /// Counted on this page, with usage, or by another row of the turn.
    case counted
    /// Counted on this reply, still without usage.
    case running, failed, noUsage
    /// Counted on this reply, which was stopped before its usage came.
    case stopped
    init(outcome: String?) {
        switch outcome {
        case "running"?, "streaming"?: self = .running
        case "completed"?, "truncated"?: self = .noUsage
        case "cancelled"?: self = .stopped
        default: self = .failed
        }
    }
}

struct GatewayMissingUsage: Codable, Sendable, Equatable {
    var running = 0, failed = 0, noUsage = 0
    /// Requests the user stopped (outcome `cancelled`), counted apart from
    /// failures since 0.1.107.
    var stopped = 0
    var total: Int { running + failed + noUsage + stopped }
    init(running: Int = 0, failed: Int = 0, noUsage: Int = 0, stopped: Int = 0) {
        self.running = running; self.failed = failed; self.noUsage = noUsage; self.stopped = stopped
    }
    /// `PayloadArchive.missingUsageSQL`'s sums: no usage, then failed, then
    /// running, each in its own 20 bits (fewer than a million per message),
    /// and the stopped ones in a column of their own.
    init(packed value: CaptureSQLValue?, stopped: CaptureSQLValue? = nil) {
        func integer(_ value: CaptureSQLValue?) -> Int64 {
            switch value { case .integer(let n)?: return n; case .real(let n)?: return Int64(exactly: n) ?? 0; default: return 0 }
        }
        let bits = integer(value)
        self.init(running: Int((bits >> 40) & 0xFFFFF), failed: Int((bits >> 20) & 0xFFFFF), noUsage: Int(bits & 0xFFFFF),
                  stopped: Int(clamping: integer(stopped)))
    }
    private enum CodingKeys: String, CodingKey { case running, failed, noUsage, stopped }
    /// Accounting kept from before 0.1.107 has no stopped count.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        running = try values.decodeIfPresent(Int.self, forKey: .running) ?? 0
        failed = try values.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        noUsage = try values.decodeIfPresent(Int.self, forKey: .noUsage) ?? 0
        stopped = try values.decodeIfPresent(Int.self, forKey: .stopped) ?? 0
    }
}

struct GatewayTotals: Codable, Sendable, Equatable {
    var inputSplit: GatewayTokenSplit?
    var outputSplit: GatewayTokenSplit?
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
    /// Inline message accounting only. Nil in older snapshots.
    var missingUsage: GatewayMissingUsage?
    /// A reply only: what the log holds of the request its own record names
    /// (`ReplyLog`); a reply whose request the log does not count on this page
    /// then has totals with no requests of their own.
    var replyLog: String?
    /// Paired input/cache observations only. Optional for older snapshots.
    var uncachedInputReportedTokens: Double?
    var uncachedInputSamples: Int?
    /// The settled throughput's sums over the requests it counts: their
    /// decode spans (first to last output) and their output tokens after the
    /// first (N − 1, not a token total to show). Optional for older snapshots.
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

    /// Output tokens after the first over first → last output for this
    /// scope, whether that is one reply, a turn or the whole session's log. A
    /// snapshot saved before the app recorded decode time reports no samples
    /// rather than a zero rate.
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
    /// The cache-hit share of prompt-side input, honestly rounded, over the
    /// requests that reported both their input and their cache reads. A
    /// request that reported input but no cache counter is not a miss: summing
    /// every reported read over every reported input divided two different
    /// populations, diluting the share (or, when reads came from requests
    /// whose input went unreported, hiding it).
    /// Two decimal places, as the session pill and the Inspector show it.
    var cacheHitPercent: String? {
        guard let split = GatewayTokenSplit.reported(self, input: true) else { return nil }
        return MetricFormat.paddedCacheHitPercent(read: split.part, prompt: split.total)
    }
    /// The requests the cache hit covers.
    var cacheHitSamples: Int { GatewayTokenSplit.reported(self, input: true)?.samples ?? 0 }
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

/// A cost in full, `$0.00042188 USD` (`MetricFormat.exactUSD`).
func gatewayUSD(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Cost unavailable" }
    return MetricFormat.exactUSD(value)
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
