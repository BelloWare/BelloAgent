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
    func observeChildCosts(_ sink: @escaping @Sendable (JSON) -> Void) {
        guard isSubagent else { return }
        childCostObserver = sink
        sink(costSnapshot)
    }
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
        guard !isSubagent, sideBudgetIDs.isEmpty else { return }
        guard costLimitUSD != usd else { return }
        costLimitUSD = usd
        // Sides can resume without launching their budget owner. Rearm its
        // next exhaustion as soon as the new limit permits work, keeping the
        // old run/permits cancelled and any accounting failure intact.
        if !costLimitReached, accountingFailure == nil {
            if familyStopReason?.code == Self.costLimitCode { familyStopReason = nil }
            budgetStopIssued = false
        }
        event("cost.limit", costSnapshot)
        stopFamilyAtLimit()
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
        // A side can join while an ordinary parent request is already on
        // the wire. That pre-ledger attempt still owns its terminal charge;
        // admitted attempts settle through RequestLifecycle instead.
        guard !isSubagent, accounting.attempts[observation.attemptID]?.admission == nil else { return }
        let outcome = observation.monitoring["outcome"].text
        // Closing refuses new work, but the admitted run can still receive
        // its terminal charge while cancellation settles. close() keeps the
        // journal attached until that run has returned.
        guard let outcome, outcome != "running", !closed || runTask != nil, countedAttempts.insert(observation.attemptID) else { return }
        if familyBudgetEnabled {
            do { try appendAccounting(kind: JournalRecordKind.cost, data: contribution(observation, owner: id)) }
            catch { failFamilyAccounting(error) }
            return
        }
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
        // Every chat pauses at its limit (owner, 2026-10-17), not only families.
        stopFamilyAtLimit()
    }
    /// Cuts every model request this session has in flight (and a retry's
    /// back-off): request permits cancel their streams; the run's request
    /// task covers a chat that has none. The crossing request has already
    /// returned its reply by the time it is counted.
    func abortModelRequests() {
        for permit in requestPermits.values { permit.cancel() }
        modelRequestAbort?()
    }
    /// The gate before every model request and tool batch: nothing starts
    /// while this chat, or a child's owner, waits at the cost limit, even
    /// after the limit is raised and before Resume.
    func enforceCostHold() async throws {
        if costPaused { throw Self.costHoldError }
        // A child also waits for its coordinator to release the hold: the
        // owner's Resume first parks it, then resumes it under its execution.
        if isSubagent, let budgetOwner {
            if await budgetOwner.costPaused { throw Self.costHoldError }
            if let agentCoordinator, await agentCoordinator.paused.contains(budgetOwner.id) { throw Self.costHoldError }
        }
    }
    /// Work a cost-limit pause holds for Resume, which belongs to the run
    /// as it stands: an edit cannot abandon it.
    var holdsCostPausedWork: Bool {
        costPaused || costResumePending || !costPendingCalls.isEmpty || costPendingCompaction || hasParkedAgentTurns
    }
    /// Whether a call that failed before it began failed because of the
    /// pause: the hold itself, or an admission the pause closed (delegation
    /// unavailable once the queue paused, a parent execution no longer
    /// accepting agent commands). Such a call is held for Resume, never
    /// given a permanent failure; one that is really unavailable fails then.
    static let pauseClosedAdmissionCodes: Set<String> = ["tool_unavailable", "subagent_closed"]
    func failedByCostPause(_ error: Error) async -> Bool {
        guard let code = (error as? AgentError)?.code else { return false }
        if code == Self.costLimitCode { return true }
        guard Self.pauseClosedAdmissionCodes.contains(code) else { return false }
        do { try await enforceCostHold(); return false } catch { return true }
    }
    static var costHoldError: AgentError { AgentError(costLimitCode, "Paused at the cost limit; Resume goes on from here.") }
    /// Whether the next model request may go: never once the spend the
    /// gateway reported reaches the limit. Unreported attempts are unknown,
    /// so they cannot bring a chat to its limit.
    var costLimitReached: Bool { costLimitUSD.map { spend.usd >= $0 } ?? false }
    func enforceCostLimit() throws {
        if let accountingFailure { throw accountingFailure }
        guard let limit = costLimitUSD, spend.usd >= limit else { return }
        throw AgentError(Self.costLimitCode, "This chat reached its \(Self.costText(limit)) cost limit (\(Self.costText(spend.usd)) spent). Raise the limit to continue.")
    }
    /// The limit and the spend, as the snapshot carries them. `paused`: work
    /// in this chat stopped at the family's limit and waits for Resume.
    var costSnapshot: JSON {
        var value: JSON = ["limitUSD": costLimitUSD.map { JSON($0) } ?? .null, "spentUSD": JSON(spend.usd),
         "reportedRequests": JSON(spend.reported), "unreportedRequests": JSON(spend.unreported),
         "reached": JSON(costLimitReached), "accountingRevision":JSON(accounting.revision), "familyUsage":familyUsage]
        if costPaused { value["paused"] = true }
        // Sides still waiting for the family's Resume, also after the root's own.
        if !costPausedMembers.isEmpty { value["pausedMembers"] = .array(costPausedMembers.map(JSON.string)) }
        return value
    }
    /// What a chat paused at its family's limit says until Resume. The app
    /// draws live figures; these are the figures at the pause.
    var costPausedMessage: String {
        guard sideBudgetIDs.isEmpty, let limit = costLimitUSD else {
            return "Paused at the shared cost limit. Raise the main chat’s limit above the spend, then choose Resume."
        }
        return "Paused at the cost limit: \(Self.costText(spend.usd)) spent of \(Self.costText(limit)). Raise the limit above the spend, then choose Resume."
    }
    /// Unfinished work that a cost-limit pause must hold for Resume: a run,
    /// pending messages, or an unsealed sub-agent turn.
    var hasCostPausableWork: Bool {
        runTask != nil || !queue.isEmpty || !steering.isEmpty || delivering != nil ||
        subagents.family?.turns.values.contains { !$0.status.terminal } == true
    }
    /// What a Resume would go on with once a paused run has ended.
    var hasWorkAfterCostPause: Bool {
        !costPendingCalls.isEmpty || costPendingCompaction || !queue.isEmpty || !steering.isEmpty || !costPausedMembers.isEmpty || hasPendingAgentEvents ||
        subagents.family?.turns.values.contains { !$0.status.terminal } == true ||
        continuationTail.map { Self.continues(from: $0) } ?? false
    }
    /// A pause with nothing left to resume ends by itself; the coordinator's
    /// hold (and its fence against the pause's late hold) is released too.
    func clearCostPauseWithoutWork() {
        costPaused = false; queuePaused = false
        if errorCode == Self.costLimitCode { errorCode = nil; errorMessage = nil }
        if state != .error, runTask == nil || state == .paused { state = .idle; runStatus = .idle }
        if !isSubagent, let coordinator = agentCoordinator { let generation = costPauseCount; Task { try? await coordinator.resumeParked(owner:self,generation:generation) } }
        if let root = sideBudgetParents.last { let side = id; Task { await root.forgetPausedMember(side) } }
    }
    /// The family reached its limit: pause at once, durably, before anything
    /// is cancelled. Called only through `stopFamilyAtLimit`. A chat with no
    /// unfinished work only closes its gates; a side that pauses tells its
    /// root, which then shows the family's pause and fans Resume out to it.
    func pauseAtCostLimit(_ reason: AgentError) {
        guard !isSubagent, !budgetStopIssued else { return }
        budgetStopIssued = true; familyStopReason = reason
        let pauses = !costPaused && hasCostPausableWork
        if pauses {
            costPaused = true; queuePaused = true; costPauseCount &+= 1
            errorCode = Self.costLimitCode; errorMessage = costPausedMessage
            markCutCompaction()
            do { try persistState(durable:true) } catch { failFamilyAccounting(error); return }
        }
        // Owner, 2026-10-17: only model requests are cut, as Stop cuts them
        // (an aborted reply is never replayed). Running tools finish with
        // their real results; the gates (`enforceCostHold`) start nothing
        // new. Children are held by their coordinator the same way.
        abortModelRequests()
        if costPaused, let coordinator = agentCoordinator {
            let generation = costPauseCount
            Task { await coordinator.pause(owner:self,generation:generation) }
        }
        if costPaused, runTask == nil { state = .paused; runStatus = .cancelled }
        if pauses, let root = sideBudgetParents.last {
            let member = id
            Task { await root.notePausedMember(member) }
        }
        // Sides retain their ancestors, so callbacks hold only weak runtimes.
        for notify in sideBudgetStops.values { Task { await notify() } }
        event("state")
    }
    /// The manual compaction under way is cut by this pause: it is pending,
    /// with its focus, in the same record as the pause, so no crash between
    /// the two can lose it.
    func markCutCompaction() {
        guard manualCompactionInFlight, !costPendingCompaction else { return }
        costPendingCompaction = true; costPendingCompactionFocus = manualCompactionInFlightFocus
    }
    /// A side of this root paused: the root now shows the family's pause and
    /// its Resume returns this side for the app to resume too. A `repair`
    /// (the side binding again with its own durable pause) only restores a
    /// missing membership: a side the root still lists is one its Resume
    /// already covers (the app resumes it next), so the root is not paused
    /// again.
    func notePausedMember(_ side: String, repair: Bool = false) {
        guard !closed, !isSubagent, side != id else { return }
        let known = costPausedMembers.contains(side)
        if repair, known { return }
        let first = !costPaused
        if !known { costPausedMembers.append(side) }
        if first {
            costPaused = true; queuePaused = true
            errorCode = Self.costLimitCode; errorMessage = costPausedMessage
            markCutCompaction()
            if runTask == nil { state = .paused; runStatus = .cancelled }
        }
        do { try persistState(durable:true) } catch { failFamilyAccounting(error); return }
        event("state")
    }
    /// The side resumed by itself: the root no longer needs to hand it out.
    func forgetPausedMember(_ side: String) {
        guard let index = costPausedMembers.firstIndex(of: side) else { return }
        costPausedMembers.remove(at: index)
        // Paused only for that side, with nothing of its own: no longer paused.
        if costPaused, runTask == nil, !hasWorkAfterCostPause {
            clearCostPauseWithoutWork()
            event("state")
        }
        try? persistState(durable:true)
    }
    /// A kept side's journal starts with the spend its unkept runtime counted.
    func carriedSpendRecord() -> JSON {
        var data = spend.record; data["source"] = "carried"
        return ["type":"custom","customType":JSON(SessionSpend.recordType),"data":data]
    }
}
