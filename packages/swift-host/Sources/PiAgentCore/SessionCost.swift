import Foundation

// A chat's cost limit: what the gateway reported the session has spent, and
// the check that stops a run before its next model request once that spend
// reaches the limit the app set.

/// What one session has spent, as the gateway reported it: the sum of every
/// attempt's reported cost — turn requests, their retries, context recovery
/// and compaction summaries — and how many attempts reported one. An attempt
/// whose gateway reported no cost, or an invalid or conflicting one, cannot be
/// counted: it is `unreported`, never a zero. Title and name suggestions run
/// in sessions of their own and are not part of a chat's spend.
struct SessionSpend: Sendable, Equatable {
    /// The journal record that carries spend: one per counted attempt, and
    /// one for spend a chat brings with it (the app's figure for a chat
    /// written before these records existed, or a kept side's spend so far).
    static let recordType = JournalRecordKind.cost
    /// A record whose data has this true starts the spend again from its own
    /// figures: a fork's first, after the records of the chat it was cloned
    /// from (`clonedFork`).
    static let resetKey = "reset"
    var usd = 0.0
    var reported = 0
    var unreported = 0

    mutating func add(record data: JSON) {
        if let amount = data["usd"].double, amount.isFinite, amount >= 0, amount <= 1_000_000_000_000 { usd += amount }
        reported += max(0, min(data["reported"].int ?? 0, 1_000_000_000))
        unreported += max(0, min(data["unreported"].int ?? 0, 1_000_000_000))
    }
    /// The spend as a journal record's data.
    var record: JSON { ["usd": JSON(usd), "reported": JSON(reported), "unreported": JSON(unreported)] }
}

extension AgentSession {
    static let costLimitCode = "cost_limit"
    /// The most a limit may be: a guard on the wire value, not a policy.
    static let maximumCostLimitUSD = 1_000_000.0

    /// A `costLimit` wire field: absent leaves the limit as it is (nil),
    /// `{"usd": 5}` sets five dollars and `{"usd": null}` removes it.
    static func costLimit(_ value: JSON) throws -> Double?? {
        guard !value.isNull else { return nil }
        guard value.isObject else { throw AgentError("invalid_params", "costLimit must be an object with a usd amount or null") }
        if value["usd"].isNull { return .some(nil) }
        guard let usd = value["usd"].double, usd.isFinite, usd > 0, usd <= maximumCostLimitUSD else {
            throw AgentError("invalid_params", "A cost limit must be a positive amount of US dollars")
        }
        return .some(usd)
    }
    /// A `costSeed` wire field: the spend the app's request log holds for a
    /// chat whose journal predates cost records.
    static func costSeed(_ value: JSON) throws -> SessionSpend? {
        guard !value.isNull else { return nil }
        guard value.isObject, let usd = value["usd"].double, usd.isFinite, usd >= 0, usd <= 1_000_000_000_000,
              (value["reported"].int ?? 0) >= 0, (value["unreported"].int ?? 0) >= 0 else {
            throw AgentError("invalid_params", "costSeed must carry a non-negative usd amount and request counts")
        }
        var seed = SessionSpend(); seed.add(record: value); return seed
    }
    /// Dollars as the stop notice says them, and as the app writes a limit
    /// (`CostLimit.dollars`, through `MetricFormat.centsUSD`): cents, or
    /// under a cent the digits it needs, up to six, so it never reads as
    /// $0.00, and `<$0.000001` for less. Rounded half-up in decimal, as the
    /// app rounds every amount: $2.675 is $2.68, never the $2.67 that
    /// rounding its binary value gives. The helper cannot import the app, so
    /// the rule is written again here and pinned by the app's values.
    static func costText(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "$0.00" }
        let places = 6, small = roundedDecimal(usd, places: places)
        if small >= Decimal(sign: .plus, exponent: -2, significand: 1) { return "$" + fixed(roundedDecimal(usd, places: 2), places: 2) }
        if small == 0 { return "<$" + fixed(Decimal(sign: .plus, exponent: -places, significand: 1), places: places) }
        return "$" + NSDecimalNumber(decimal: small).stringValue
    }
    /// `value` as the decimal it is written as, rounded half-up at `places`.
    private static func roundedDecimal(_ value: Double, places: Int) -> Decimal {
        var decimal = Decimal(string: "\(value)") ?? Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, places, .plain)
        return rounded
    }
    /// A rounded amount with exactly `places` decimals: `4.10`, `0.000001`.
    private static func fixed(_ value: Decimal, places: Int) -> String {
        let parts = NSDecimalNumber(decimal: value).stringValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: max(0, places - fraction.count))
    }

    /// Takes the chat's limit, nil for none. It applies from the next model
    /// request on, also to a run that is going: a request already sent is
    /// never cut, and nothing else about the run changes.
    public func setCostLimit(_ usd: Double?) {
        guard !isSubagent else { return }
        guard costLimitUSD != usd else { return }
        costLimitUSD = usd
        event("cost.limit", costSnapshot)
    }
    /// Adopts the spend the app counted for this chat before its journal
    /// recorded costs, once: a journal that records them never takes another.
    func adoptSpendSeed(_ seed: SessionSpend) {
        guard !spendTracked, !closed else { return }
        spend.usd += seed.usd; spend.reported += seed.reported; spend.unreported += seed.unreported
        spendTracked = true
        var data = seed.record; data["source"] = "app-request-log"
        _ = try? journal?.append(["type":"custom","customType":JSON(SessionSpend.recordType),"data":data], flush: journalFlushesEachRecord)
        event("cost.spend", costSnapshot)
    }
    /// Counts an attempt once it has ended: its reported cost, or one more
    /// request that reported none. Every attempt of this session passes
    /// here, whatever its purpose, before its request returns or throws.
    func countAttempt(_ observation: RequestObservation) {
        guard let outcome = observation.monitoring["outcome"].text, outcome != "running", observation.sessionID == id,
              !closed || runTask != nil, accounting.attempts[observation.attemptID]?.contribution == nil else { return }
        // The throwing lifecycle settles managed requests. This compatibility
        // path counts clients without lifecycle hooks and older ordinary runs.
        do { try appendAccounting(kind: JournalRecordKind.cost, data: contribution(observation, owner: id)) }
        catch { accountingFailure = error as? AgentError }
    }
    /// Whether the next model request may go: never once the spend the
    /// gateway reported reaches the limit. Unreported attempts are unknown,
    /// so they cannot bring a chat to its limit.
    var costLimitReached: Bool { costLimitUSD.map { spend.usd >= $0 } ?? false }
    func enforceCostLimit() throws {
        if let accountingFailure { throw accountingFailure }
        guard let limit = costLimitUSD, spend.usd >= limit else { return }
        throw AgentError(Self.costLimitCode, "This chat reached its \(Self.costText(limit)) cost limit (\(Self.costText(spend.usd)) spent). Raise the limit to continue.")
    }
    /// The limit and the spend, as the snapshot carries them.
    var costSnapshot: JSON {
        ["limitUSD": costLimitUSD.map { JSON($0) } ?? .null, "spentUSD": JSON(spend.usd),
         "reportedRequests": JSON(spend.reported), "unreportedRequests": JSON(spend.unreported),
         "reached": JSON(costLimitReached), "accountingRevision":JSON(accounting.revision), "familyUsage":familyUsage]
    }
    /// A kept side's journal starts with the spend its unkept runtime counted.
    func carriedSpendRecord() -> JSON {
        var data = spend.record; data["source"] = "carried"
        return ["type":"custom","customType":JSON(SessionSpend.recordType),"data":data]
    }
}
