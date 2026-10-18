import Foundation

/// Runtime-only fence, separate from durable pause/work records. Checking an
/// issuer through an actor await would itself allow Resume to overtake it.
/// A fresh runtime owns a fresh clock, so reopening never revives old messages.
final class CostPauseClock: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var pauses = 0, resumes = 0, stops = 0
    private var paused = false, live = true, closing = false, accepting = true
    func update(pauses: Int? = nil, resumes: Int? = nil, paused: Bool? = nil, stops: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let pauses { self.pauses = pauses }; if let resumes { self.resumes = resumes }
        if let paused { self.paused = paused }; if let stops { self.stops = stops }
    }
    var generation: CostPauseGeneration {
        lock.lock(); defer { lock.unlock() }
        return CostPauseGeneration(clock:self,pauses:pauses,resumes:resumes,stops:stops,paused:paused)
    }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    var acceptsMessages: Bool { lock.lock(); defer { lock.unlock() }; return live && !closing && accepting }
    var isClosing: Bool { lock.lock(); defer { lock.unlock() }; return closing }
    func acceptMessages(_ value: Bool) { lock.lock(); accepting = value; lock.unlock() }
    func beginClosing() { lock.lock(); closing = true; lock.unlock() }
    func retire() { lock.lock(); live = false; lock.unlock() }
    func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    /// Every pause-protocol receiver checks the issuing runtime/generation
    /// at its mutation, never by asking the issuer across another await.
    func current(_ generation: CostPauseGeneration, resumeOnly: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return live && generation.clock === self && generation.resumes == resumes && (resumeOnly || generation.pauses == pauses)
    }
    func installing(_ generation: CostPauseGeneration) -> Bool {
        lock.lock(); defer { lock.unlock() }; return current(generation) && generation.stops == stops
    }
    func parking(_ generation: CostPauseGeneration) -> Bool {
        // Prepare advances Resume, but draining still belongs to this open
        // pause. Commit closes it; a later pause has a different pause count.
        lock.lock(); defer { lock.unlock() }
        return live && generation.clock === self && generation.pauses == pauses && paused
    }
    /// Admission of an inherited pause and the issuer's Resume are ordered by
    /// this fence. The body is synchronous: never hold it over an actor/provider
    /// await. Resume then sees every side that actually took the old pause.
    @discardableResult func apply<T>(_ generation: CostPauseGeneration, resumeOnly: Bool = false, matchingPause: Bool = false, _ body: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard current(generation,resumeOnly:resumeOnly), !matchingPause || paused == generation.paused else { return nil }; return try body()
    }
    @discardableResult func applyPause<T>(_ generation: CostPauseGeneration, _ body: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard parking(generation) else { return nil }; return try body()
    }
}

struct CostPauseGeneration: Sendable, Equatable {
    let clock: CostPauseClock
    let pauses: Int, resumes: Int, stops: Int
    let paused: Bool
    var isCurrent: Bool { clock.current(self) }
    var isCurrentPause: Bool { clock.parking(self) }
    var isCurrentResume: Bool { clock.current(self,resumeOnly:true) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.clock === rhs.clock && lhs.pauses == rhs.pauses && lhs.resumes == rhs.resumes }
    /// Install also fences Stop. The owner repeats this after the last await,
    /// immediately before its synchronous durable commit.
    func check() throws { try Task.checkCancellation(); guard clock.installing(self) else { throw CancellationError() } }
}

/// The side's pause identity and the root Resume it was issued before. Root
/// pause counts may advance as concurrent sides join; its Resume count may not.
struct SidePausePublication: Sendable {
    let side: CostPauseGeneration, root: CostPauseGeneration
    var isCurrent: Bool { side.isCurrent && side.clock.isPaused == side.paused && root.isCurrentResume }
    /// Always root before descendant: no opposing lock order with inherited
    /// pause admission. These fences cover synchronous record writes only.
    func apply<T>(_ body: () throws -> T) rethrows -> T? {
        try root.clock.apply(root,resumeOnly:true) { try side.clock.apply(side,matchingPause:true,body) } ?? nil
    }
}

/// One desired membership state, saved with the pause/Resume that issued it.
/// Its identity fences acknowledgments across retries, replacement intents and
/// runtime replacement; it contains no conversation or capture content.
struct SidePauseIntent: Equatable, Sendable {
    let id: String, paused: Bool
    init(paused: Bool) { id = UUID().uuidString; self.paused = paused }
    init?(_ saved: JSON) {
        guard let id = saved["id"].text, !id.isEmpty, let paused = saved["paused"].flag else { return nil }
        self.id = id; self.paused = paused
    }
    var saved: JSON { ["id":JSON(id),"paused":JSON(paused)] }
}

extension AgentSession {
    nonisolated var pauseGeneration: CostPauseGeneration { costPauseClock.generation }
    /// A failed synchronous transition restores its counters before another
    /// actor can capture a temporary generation. Always root before side.
    func withCostPauseFence<T>(_ body: () throws -> T) rethrows -> T {
        let root = sideBudgetParents.last?.costPauseClock ?? costPauseClock
        return try root.synchronized { try costPauseClock.synchronized(body) }
    }
    func sidePausePublication() -> SidePausePublication? {
        guard let root = sideBudgetParents.last else { return nil }
        return SidePausePublication(side:pauseGeneration,root:root.pauseGeneration)
    }
    @discardableResult func receiveSidePause(_ reason: AgentError, generation: SidePausePublication) -> SidePausePublication {
        // Every pause message applies only in its issuing generation. In
        // particular an old callback cannot pause a side after root Resume.
        if !closed { generation.apply { stopFamilyAtLimit(reason) } }
        return SidePausePublication(side:pauseGeneration,root:generation.root)
    }
    func receiveChildPause(generation: CostPauseGeneration, halt: Bool) {
        generation.clock.apply(generation) {
            if halt {
                guard lastCostHalt != generation || lastCostHalt?.stops != generation.stops else { return }
                lastCostHalt = generation; stop()
            } else { abortModelRequests() }
        }
    }
    /// The caller saves this in the same state record as the local change,
    /// before scheduling any cross-actor delivery. A newer change supersedes
    /// the old desired state; its acknowledgment cannot clear the new intent.
    func rememberSideMembership(paused: Bool) {
        guard isSideChat else { return }
        if costPendingMembership?.paused != paused { costPendingMembership = SidePauseIntent(paused:paused) }
    }
    func forgetSidePause() {
        guard let publication = sidePausePublication(), let intent = costPendingMembership else { return }
        let before = beforeSidePauseForget
        Task {
            await before?()
            // This task drives a durable intent, rather than reviving an old
            // message. If the sender still owns it, issue fresh receiver stamps.
            guard publication.side.isCurrent, costPendingMembership == intent else { return }
            _ = await drainSidePauseIntent()
        }
    }
    /// Lifecycle drain bypasses a queued delivery, using the current runtime
    /// stamps. Reopening does the same after binding. Stale tasks remain no-ops.
    func drainSidePauseIntent() async -> Bool {
        while let intent = costPendingMembership {
            guard let publication = sidePausePublication() else { return true } // Orphan: no root to notify.
            if await deliverSidePauseIntent(intent,publication:publication,repair:true) { continue }
            // Automatic receiver retirement may advance its clock while
            // acknowledging this write. The intent is still durable: retry
            // under its new stamp, never revive the stale delivery task.
            guard costPendingMembership == intent, publication.side.isCurrent,
                  !publication.root.isCurrent, publication.root.clock.acceptsMessages else { return false }
        }
        return true
    }
    /// Admission is already closed and the registered clock rejects new
    /// fan-out. Take any earlier fan-out before handing the sender over;
    /// even an idle recipient must durably acknowledge its lack of work.
    func drainSidePauseChanges() async -> Bool {
        var incoming: [(AgentSession,SidePausePublication)] = []
        for ancestor in sideBudgetParents {
            if let generation = await ancestor.pendingSidePause(id) {
                generation.apply { stopFamilyAtLimit(Self.costHoldError) }
                incoming.append((ancestor,generation))
            }
        }
        do { if !incoming.isEmpty { try persistState(durable:true) } }
        catch { failFamilyAccounting(error); return false }
        guard await drainSidePauseIntent() else { return false }
        for (ancestor,generation) in incoming { await ancestor.acknowledgeSidePause(id,generation:generation) }
        return true
    }
    func deliverSidePauseIntent(_ intent: SidePauseIntent, publication: SidePausePublication, repair: Bool = false) async -> Bool {
        guard costPendingMembership == intent, intent.paused == costPaused,
              publication.isCurrent, let root = sideBudgetParents.last else { return false }
        let confirmed: Bool
        if intent.paused { confirmed = await root.notePausedMember(id,publication:publication,repair:repair) }
        else { confirmed = await root.forgetPausedMember(id,generation:publication.side,destination:publication.root) }
        guard confirmed else { return false }
        await beforeSidePauseAcknowledgment?()
        // The receipt acknowledges this source generation/intent, after the
        // receiver's durable mutation. The root may have advanced its clock
        // as part of that very retirement; it cannot revoke a durable ack.
        // A newer source change still rejects it, by both generation and ID.
        return publication.side.clock.apply(publication.side,matchingPause:true) {
            // A duplicate delivery may already have saved this same receipt
            // while we awaited the root. Its durable ack is still an ack.
            if costPendingMembership == nil { return true }
            guard costPendingMembership == intent else { return false }
            costPendingMembership = nil
            do { try persistState(durable:true); return true }
            catch { costPendingMembership = intent; failFamilyAccounting(error); return false }
        } ?? false
    }
}
