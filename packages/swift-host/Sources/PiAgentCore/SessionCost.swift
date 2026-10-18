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
        // A side shares its family's pause as it shares its spend: the
        // latched pause of any ancestor holds it, whatever the limit now says.
        for parent in sideBudgetParents where await parent.costPaused { throw Self.costHoldError }
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
    /// A root's own pause is over (its Resume accepted) but sides it names
    /// still wait: the family's Resume is not done. Shown as the family's
    /// pause, with Resume offered; it holds nothing of the root's own.
    var membersPendingResume: Bool { !isSubagent && !costPaused && !costPausedMembers.isEmpty && runTask == nil }
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
    /// A tool card's state for a call the pause held before it began.
    static let heldToolState = "queued"
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
        if costPaused || membersPendingResume { value["paused"] = true }
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
        !costPendingCalls.isEmpty || costPendingCompaction || !queue.isEmpty || !steering.isEmpty || !costPausedMembers.isEmpty || !costPendingSidePauses.isEmpty || hasPendingAgentEvents ||
        subagents.family?.turns.values.contains { !$0.status.terminal } == true ||
        continuationTail.map { Self.continues(from: $0) } ?? false
    }
    /// A pause with nothing left to resume ends by itself; the coordinator's
    /// hold (and its fence against the pause's late hold) is released too.
    @discardableResult func clearCostPauseWithoutWork() -> Bool {
        withCostPauseFence { clearCurrentCostPauseWithoutWork() }
    }
    private func clearCurrentCostPauseWithoutWork() -> Bool {
        let saved = costPauseState, previous = (queuePaused,state,runStatus)
        // An idle side may acknowledge fan-out, then acquire work and pause
        // before its own publication runs. Account for every applied pause
        // under the root fence before retiring this generation, not only the
        // outstanding fan-out. Resume uses the same census before its reply.
        rememberAppliedSidePauses()
        if !costPausedMembers.isEmpty {
            do { try persistState(durable:true); return true }
            catch { restoreCostPause(saved); failFamilyAccounting(error); return false }
        }
        costPaused = false; queuePaused = false; costResumeCount &+= 1
        rememberSideMembership(paused:false)
        if errorCode == Self.costLimitCode { errorCode = nil; errorMessage = nil }
        if state != .error, runTask == nil || state == .paused { state = .idle; runStatus = .idle }
        do { try persistState(durable:true) }
        catch {
            restoreCostPause(saved); (queuePaused,state,runStatus) = previous
            failFamilyAccounting(error); return false
        }
        if !isSubagent, let coordinator = agentCoordinator { let generation = pauseGeneration; Task { await coordinator.activateResume(owner:self,generation:generation) } }
        forgetSidePause()
        return true
    }
    /// The family reached its limit: pause at once, durably, before anything
    /// is cancelled. Called only through `stopFamilyAtLimit`. A chat with no
    /// unfinished work only closes its gates; a side that pauses tells its
    /// root, which then shows the family's pause and fans Resume out to it.
    func pauseAtCostLimit(_ reason: AgentError) {
        guard !isSubagent, !budgetStopIssued else { return }
        budgetStopIssued = true; familyStopReason = reason
        rememberSidePauses()
        let supersedes = supersedeCostResume()
        let pauses = !costPaused && hasCostPausableWork
        if pauses || supersedes {
            costPaused = true; queuePaused = true
            if pauses { costPauseCount &+= 1 }
            errorCode = Self.costLimitCode; errorMessage = costPausedMessage
            markCutCompaction()
        }
        if pauses { rememberSideMembership(paused:true) }
        if pauses || supersedes || !costPendingSidePauses.isEmpty {
            do { try persistState(durable:true) } catch { failFamilyAccounting(error); return }
        }
        // Owner, 2026-10-17: only model requests are cut, as Stop cuts them
        // (an aborted reply is never replayed). Running tools finish with
        // their real results; the gates (`enforceCostHold`) start nothing
        // new. Children are held by their coordinator the same way.
        abortModelRequests()
        if costPaused, let coordinator = agentCoordinator {
            let generation = pauseGeneration
            Task { await coordinator.pause(owner:self,generation:generation) }
        }
        if costPaused, runTask == nil { state = .paused; runStatus = .cancelled }
        if pauses, let publication = sidePausePublication() { Task { await self.publishSidePause(publication) } }
        notifySidesOfPause(reason)
        event("state")
    }
    /// Sides retain their ancestors, so callbacks hold only weak runtimes.
    func notifySidesOfPause(_ reason: AgentError) {
        let generation = SidePausePublication(side:pauseGeneration,root:sideBudgetParents.last?.pauseGeneration ?? pauseGeneration)
        for notify in sideBudgetStops.values { Task { await notify(reason, generation) } }
    }
    /// Save the fan-out in the same record as the pause, even when only
    /// sides have work. A side acknowledges only after its own pause and
    /// root membership are durable; idle sides never become paused members.
    func rememberAppliedSidePauses() {
        guard sideBudgetParents.isEmpty else { return }
        for side in sideBudgetPauseClocks.keys.sorted() {
            guard let clock = sideBudgetPauseClocks[side], clock.isPaused, !clock.isClosing else { continue }
            if !costPausedMembers.contains(side) { costPausedMembers.append(side) }
        }
    }
    func rememberSidePauses() {
        for side in sideBudgetStops.keys.sorted() where sideBudgetPauseClocks[side]?.acceptsMessages == true && !costPendingSidePauses.contains(side) { costPendingSidePauses.append(side) }
    }
    func acknowledgeSidePause(_ side: String, generation: SidePausePublication) {
        // An acknowledgment retires only the intent generation it observed.
        guard generation.side.clock === costPauseClock else { return }
        generation.apply { acknowledgeCurrentSidePause(side) }
    }
    private func acknowledgeCurrentSidePause(_ side: String) {
        guard costPendingSidePauses.contains(side) else { return }
        let pending = costPendingSidePauses
        costPendingSidePauses.removeAll { $0 == side }
        // Pending fan-out keeps this generation open even after our own
        // final reply. Retire it only once every side confirmed its state.
        if costPaused, runTask == nil, !hasWorkAfterCostPause {
            if !clearCostPauseWithoutWork() { costPendingSidePauses = pending }
        } else {
            do { try persistState(durable:true) } catch { costPendingSidePauses = pending; failFamilyAccounting(error) }
        }
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
    @discardableResult func notePausedMember(_ side: String, publication: SidePausePublication, repair: Bool = false) -> Bool {
        // No await between this generation check and the local durable write.
        // Duplicates of a covered generation cannot undo an accepted Resume.
        guard publication.root.clock === costPauseClock else { return false }
        return publication.apply { noteCurrentPausedMember(side,publication:publication,repair:repair) } ?? false
    }
    private func noteCurrentPausedMember(_ side: String, publication: SidePausePublication, repair: Bool) -> Bool {
        guard !closed, ephemeral || journal != nil, !isSubagent, side != id else { return false }
        let previous = costMemberGenerations[side]
        let known = costPausedMembers.contains(side), duplicate = previous == publication.side
        let newPause = previous?.clock === publication.side.clock && previous?.pauses != publication.side.pauses
        if duplicate, !known { return true } // A durable retirement already consumed this publication.
        // A known in-memory member may come from a failed save. Confirm it
        // again before another writer retires its only durable copy.
        let covered = known && (duplicate || repair && !newPause)
        let first = !costPaused && !covered
        let supersedes = !covered && supersedeCostResume()
        if !known { costPausedMembers.append(side) }
        if first || supersedes {
            // The family's pause, as at the limit itself: saved, then every
            // model request in flight cut, the children held and the other
            // sides paused, under a new pause generation.
            costPaused = true; queuePaused = true
            if first { costPauseCount &+= 1 }
            budgetStopIssued = true; familyStopReason = Self.costHoldError
            errorCode = Self.costLimitCode; errorMessage = costPausedMessage
            markCutCompaction()
            rememberSidePauses()
            if runTask == nil { state = .paused; runStatus = .cancelled }
        }
        do { try persistState(durable:true) } catch { failFamilyAccounting(error); return false }
        if first || supersedes {
            abortModelRequests()
            if let coordinator = agentCoordinator { let generation = pauseGeneration; Task { await coordinator.pause(owner:self,generation:generation) } }
            notifySidesOfPause(Self.costHoldError)
        }
        costMemberGenerations[side] = publication.side
        event("state"); return journal != nil
    }
    /// The side resumed by itself: the root no longer needs to hand it out.
    @discardableResult func forgetPausedMember(_ side: String, generation: CostPauseGeneration, destination: CostPauseGeneration) -> Bool {
        // A late retirement cannot erase a newer pause. A replayed retirement
        // removes membership only: a newer fan-out still needs its own ack.
        guard destination.clock === costPauseClock, !closed else { return false }
        return destination.clock.apply(destination) {
            generation.clock.apply(generation) { retirePausedMember(side,fanout:false) } ?? false
        } ?? false
    }
    func forgetClosedSide(_ side: String, generation: CostPauseGeneration) {
        // Unlike Resume retirement, close ends all work of the issuing
        // runtime. Check that generation and its registered clock, so a late
        // close cannot retire a replacement runtime of the same side.
        // An intermediate's no-work retirement can also notify the root.
        // Take that root fence first, as publication/admission do.
        let root = sideBudgetParents.last?.costPauseClock ?? costPauseClock
        root.synchronized {
            costPauseClock.apply(pauseGeneration) {
                generation.clock.apply(generation) {
                    guard generation.clock.isClosing, sideBudgetPauseClocks[side] === generation.clock else { return }
                    retirePausedMember(side)
                    if !costPausedMembers.contains(side), !costPendingSidePauses.contains(side) {
                        sideBudgetStops.removeValue(forKey:side); sideBudgetPauseClocks.removeValue(forKey:side)
                    }
                }
            }
        }
    }
    @discardableResult private func retirePausedMember(_ side: String, fanout: Bool = true) -> Bool {
        guard ephemeral || journal != nil else { return false }
        guard costPausedMembers.contains(side) || fanout && costPendingSidePauses.contains(side) else { return true }
        let members = costPausedMembers, pending = costPendingSidePauses
        costPausedMembers.removeAll { $0 == side }
        if fanout { costPendingSidePauses.removeAll { $0 == side } }
        // The local retirement is durable before releasing an ancestor or
        // coordinator hold. A failed removal stays available for retry.
        if costPaused, runTask == nil, !hasWorkAfterCostPause {
            if !clearCostPauseWithoutWork() { costPausedMembers = members; costPendingSidePauses = pending; return false }
        } else {
            do { try persistState(durable:true) }
            catch { costPausedMembers = members; costPendingSidePauses = pending; failFamilyAccounting(error); return false }
        }
        event("state"); return true
    }
    /// Sides deleted (with their descendants): none of them waits for a
    /// Resume any more, and a root paused only for them is not paused.
    func forgetDeletedMembers(_ ids: Set<String>) {
        for side in ids { sideBudgetStops.removeValue(forKey:side); sideBudgetPauseClocks.removeValue(forKey:side) }
        for side in Set(costPausedMembers + costPendingSidePauses) where ids.contains(side) { retirePausedMember(side) }
    }
    /// Listed sides whose journal is gone (deleted while this root was not
    /// loaded, or an unkept side that ended with its runtime) are dropped
    /// when the root reopens; a pause held only for them ends.
    func dropMissingPausedMembers() throws {
        // State records are decoded lazily by the replay consumer. Its raw
        // accumulator can still name a checkpoint or nil; use the final state.
        let saved = try durable?.finished().stateRecord
        // Initialization assigns stored fields without their observers. This
        // existing isolated recovery step publishes the final recovered clock,
        // without adding nonisolated initializer reads of actor state.
        defer { costPauseClock.update(pauses:costPauseCount,resumes:costResumeCount,paused:costPaused,stops:stopCount) }
        try retireTerminalAgentPause(); boundary = context
        costPendingMembership = saved.flatMap { SidePauseIntent($0["costPendingMembership"]) }
        if costPaused || costPendingMembership != nil { rememberSideMembership(paused:costPaused) }
        // Pruning a completed recipient is the recovered fan-out ack. It
        // must also retire an otherwise empty hold, just as a live ack does.
        var repaired = costPendingSidePauses != (saved?["costPendingSidePauses"].list.compactMap(\.text) ?? [])
        // A sender can die before its task runs, or after a receiver write but
        // before its ack. Inspect only validated family metadata off-host, as
        // the rest of this initializer's recovery does. Binding later replays
        // and acknowledges the intent under the new runtime's generation.
        let parent = isSideChat ? parentInfo["parentSessionId"].text : nil
        let ownsFamily = try parent.map { try !SideBudgetRecovery.parentExists($0,directory:directory) } ?? true
        var sideStates: [String:JSON] = [:], sideWork: [String:Bool] = [:]
        for side in sideBudgetMembers.keys.sorted() where ownsFamily {
            if let file = try SideBudgetRecovery.journalURL(side,directory:directory) {
                let pause = try SideBudgetRecovery.pauseState(file,id:side)
                sideStates[side] = pause.state; sideWork[side] = pause.hasWork
            }
        }
        var additions = Set<String>(), retirements = Set<String>()
        for (side, state) in sideStates {
            if state["costPaused"].flag == true { additions.insert(side) } // Includes pre-intent journals.
            if let intent = SidePauseIntent(state["costPendingMembership"]), !intent.paused,
               state["costPaused"].flag != true, !costPendingSidePauses.contains(side) { retirements.insert(side) }
            // An intermediate's retained transfer/fan-out is also a durable
            // intent. A descendant that already resumed must not be revived
            // by a source acknowledgment that failed before that Resume.
            for member in state["costPendingSidePauses"].list.compactMap(\.text) where sideBudgetMembers[member]?.contains(side) == true {
                if sideWork[member] == true { additions.insert(member) }
            }
        }
        for side in additions.sorted() where !costPausedMembers.contains(side) {
            costPausedMembers.append(side); repaired = true
            costPaused = true; queuePaused = true; statePauseAfterRecovery()
        }
        for side in retirements where !additions.contains(side) && costPausedMembers.contains(side) {
            costPausedMembers.removeAll { $0 == side }; repaired = true
        }
        let kept = costPausedMembers.filter { side in ((try? SideBudgetRecovery.journalURL(side, directory: directory)) ?? nil) != nil }
        if kept != costPausedMembers || repaired {
            costPausedMembers = kept
            if costPaused, runTask == nil, !hasWorkAfterCostPause {
                costPaused = false; queuePaused = !queue.isEmpty || !steering.isEmpty
                rememberSideMembership(paused:false)
                if errorCode == Self.costLimitCode { errorCode = nil; errorMessage = nil }
                if state == .paused { state = queuePaused ? .paused : .idle; runStatus = queuePaused ? .cancelled : .idle }
            }
        }
        // Recovery is durable before any binding can acknowledge a sender.
        if costPaused != (saved?["costPaused"].flag == true) ||
            costPausedMembers != (saved?["costPausedMembers"].list.compactMap(\.text) ?? []) ||
            costPendingSidePauses != (saved?["costPendingSidePauses"].list.compactMap(\.text) ?? []) ||
            costPendingMembership != saved.flatMap({ SidePauseIntent($0["costPendingMembership"]) }) { try persistState(durable:true) }
    }
    private func statePauseAfterRecovery() {
        state = .paused; runStatus = .cancelled
        errorCode = Self.costLimitCode; errorMessage = costPausedMessage
    }
    /// A kept side's journal starts with the spend its unkept runtime counted.
    func carriedSpendRecord() -> JSON {
        var data = spend.record; data["source"] = "carried"
        return ["type":"custom","customType":JSON(SessionSpend.recordType),"data":data]
    }
}
