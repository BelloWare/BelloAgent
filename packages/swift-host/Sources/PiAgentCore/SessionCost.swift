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
    static let recordType = "pi-app.cost.v1"
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

/// The last identities seen, oldest forgotten first: a bounded guard against
/// counting one attempt twice, whatever a long chat's attempt count.
struct BoundedIdentitySet: Sendable {
    let limit: Int
    private var order: [String] = [], members = Set<String>()
    init(limit: Int) { self.limit = max(1, limit) }
    /// False when the identity was already present.
    mutating func insert(_ identity: String) -> Bool {
        guard members.insert(identity).inserted else { return false }
        order.append(identity)
        if order.count > limit { members.remove(order.removeFirst()) }
        return true
    }
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
    /// Dollars as the stop notice says them: cents, or the digits a
    /// sub-cent amount needs so it never reads as $0.00.
    static func costText(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "$0.00" }
        if usd >= 0.01 { return String(format: "$%.2f", usd) }
        var text = String(format: "%.6f", usd)
        while text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }

    /// Takes the chat's limit, nil for none. It applies from the next model
    /// request on, also to a run that is going: a request already sent is
    /// never cut, and nothing else about the run changes.
    public func setCostLimit(_ usd: Double?) {
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
        let outcome = observation.monitoring["outcome"].text
        guard let outcome, outcome != "running", !closed, countedAttempts.insert(observation.attemptID) else { return }
        let cost = observation.monitoring["gateway"]["cost"]
        var data: JSON = ["attemptId": JSON(observation.attemptID), "purpose": JSON(observation.purpose), "outcome": JSON(outcome)]
        if cost["status"].text == "reported", let usd = cost["usd"].double, usd.isFinite, usd >= 0 {
            spend.usd += usd; spend.reported += 1
            data["usd"] = JSON(usd); data["reported"] = 1
        } else {
            spend.unreported += 1
            data["usd"] = 0; data["unreported"] = 1; data["status"] = JSON(cost["status"].text ?? "unreported")
        }
        spendTracked = true
        // Written with the run's records: an attempt's cost is as durable as
        // the reply it paid for. A failed write leaves the figure in memory.
        _ = try? journal?.append(["type":"custom","customType":JSON(SessionSpend.recordType),"data":data], flush: journalFlushesEachRecord)
    }
    /// Whether the next model request may go: never once the spend the
    /// gateway reported reaches the limit. Unreported attempts are unknown,
    /// so they cannot bring a chat to its limit.
    var costLimitReached: Bool { costLimitUSD.map { spend.usd >= $0 } ?? false }
    func enforceCostLimit() throws {
        guard let limit = costLimitUSD, spend.usd >= limit else { return }
        throw AgentError(Self.costLimitCode, "This chat reached its \(Self.costText(limit)) cost limit (\(Self.costText(spend.usd)) spent). Raise the limit to continue.")
    }
    /// The limit and the spend, as the snapshot carries them.
    var costSnapshot: JSON {
        ["limitUSD": costLimitUSD.map { JSON($0) } ?? .null, "spentUSD": JSON(spend.usd),
         "reportedRequests": JSON(spend.reported), "unreportedRequests": JSON(spend.unreported),
         "reached": JSON(costLimitReached)]
    }
    /// A kept side's journal starts with the spend its unkept runtime counted.
    func carriedSpendRecord() -> JSON {
        var data = spend.record; data["source"] = "carried"
        return ["type":"custom","customType":JSON(SessionSpend.recordType),"data":data]
    }
}
