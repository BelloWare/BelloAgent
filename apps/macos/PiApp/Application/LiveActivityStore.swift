import Foundation
import Combine
import AppKit

struct LiveSessionKey: Hashable, Sendable { let workspace: String; let session: String }
struct LiveAttemptKey: Hashable, Sendable {
    let session: LiveSessionKey
    let epoch: String
    let generation: Int
    let attempt: String
}
struct LiveWorkCounts: Equatable, Sendable {
    var model = 0, tools = 0, other = 0
    var total: Int { model + tools + other }
    mutating func add(_ phase: String, by amount: Int) {
        switch phase {
        case "model", "compacting": model += amount
        case "tool": tools += amount
        case "starting", "stopping": other += amount
        default: break
        }
    }
    mutating func includePeak(_ value: Self) {
        model = max(model, value.model); tools = max(tools, value.tools); other = max(other, value.other)
    }
}
struct LiveActivityBucket: Identifiable, Equatable, Sendable {
    let id: Int
    let wall: Date
    var peak = LiveWorkCounts(), last = LiveWorkCounts()
    var gap = false
    var completions = 0, rateSamples = 0, interimSamples = 0
    var output = 0.0, duration = 0.0
    var minimumRate: Double?, maximumRate: Double?, intervalPeak: Double?
    var averageRate: Double? { rateSamples > 0 && duration > 0 ? output / duration : nil }
}
struct LiveRequestState: Equatable, Sendable, Identifiable {
    let id: LiveAttemptKey
    var purpose: String, alias: String, phase: String
    var model: String?, identityStatus = "unreported"
    var input: Double?, output: Double?, cached: Double?, reasoning: Double?, cost: Double?
    var costStatus = "unreported"
    var dispatch: Double?, complete: Double?, firstContent: Double?, httpEnd: Double?
    var receivedAt: Double?
    var baselineOutput: Double?, baselineAt: Double?
    var intervalRate: Double?, intervalObserved: Double?, intervalDuration: Double?
    var correction = false
    var finalOutput = false
    var terminal: Bool { phase == "final" || phase == "interrupted" }
    var dispatched: Bool { dispatch != nil && phase != "preparing" }
    var utility: Bool { purpose != "turn" }
    var duration: Double? {
        guard let dispatch, let complete, complete > dispatch else { return nil }
        return (complete - dispatch) / 1_000
    }
    var rate: Double? {
        guard phase == "final", finalOutput, let output, let duration, duration > 0 else { return nil }
        let value = output / duration; return value.isFinite ? value : nil
    }
    var ttft: Double? { guard let dispatch, let firstContent, firstContent >= dispatch else { return nil }; return firstContent - dispatch }
    func currentRate(at now: Double) -> Double? {
        guard !terminal, let intervalObserved, let intervalDuration,
              now - intervalObserved <= min(5, max(1, intervalDuration)), now >= intervalObserved else { return nil }
        return intervalRate
    }
}
struct LiveCompletion: Identifiable, Equatable, Sendable {
    let id: LiveAttemptKey
    var wall: Date
    var request: LiveRequestState
    let bucket: Int
}
struct LivePopupSnapshot: Equatable, Sendable {
    var observedAt = Date()
    var lastObservationAt: Date?
    var counts = LiveWorkCounts()
    var requests: [LiveRequestState] = []
    var completions: [LiveCompletion] = []
    var buckets: [LiveActivityBucket] = []
    var disconnected = false
    var gaps = 0
    var activeRequests: Int { requests.count }
    var utilityRequests: Int { requests.filter(\.utility).count }
    var freshnessLabel: String {
        if disconnected { return "Disconnected" }
        guard let lastObservationAt else { return "No live observations" }
        let age = max(0, observedAt.timeIntervalSince(lastObservationAt))
        return age < 5 ? "Observed just now" : "Last observed \(Int(min(age, 86_400)))s ago"
    }
    func total(_ key: KeyPath<LiveRequestState, Double?>) -> (value: Double?, samples: Int) {
        let values = requests.compactMap { $0[keyPath: key] }
        let sum = values.reduce(0, +)
        return (values.isEmpty || !sum.isFinite ? nil : sum, values.count)
    }
}

/// Numerical, deterministic reducer. No transcripts, SQL, networking, raw
/// bodies, retained history or execution limits. Only active attempts are kept
/// without a UI cap; settled details are bounded and older totals remain in bins.
struct LiveActivityAccumulator {
    static let bucketLimit = 900, completionLimit = 1_000
    private(set) var counts = LiveWorkCounts()
    private(set) var phases: [LiveSessionKey: String] = [:]
    private(set) var active: [LiveAttemptKey: LiveRequestState] = [:]
    private(set) var completions: [LiveCompletion] = []
    private(set) var buckets: [LiveActivityBucket] = []
    private var cursors: [LiveSessionKey: (epoch: String, sequence: Int)] = [:]
    private var settledGenerations: [LiveSessionKey: Int] = [:]
    private var interrupted = false
    private var disconnected: Set<String> = []
    private var lastTime: Double?, lastWall: Date?
    private var lastObservationAt: Date?
    private(set) var gaps = 0
    var hasWork: Bool { counts.total > 0 || !active.isEmpty }

    mutating func advance(at now: Double, wall: Date) {
        guard now.isFinite, now >= 0, now < Double(Int.max - 1), wall.timeIntervalSince1970.isFinite else { return }
        let id = Int(now.rounded(.down))
        var missing = interrupted
        if let previous = lastTime, let previousWall = lastWall,
           now < previous || abs(wall.timeIntervalSince(previousWall) - (now - previous)) > 3 || now - previous > 5 && hasWork {
            gap(at: now, wall: wall)
            missing = true
        }
        if let last = buckets.last, last.id < id {
            let start = max(last.id + 1, id - Self.bucketLimit + 1)
            for second in start...id {
                buckets.append(LiveActivityBucket(id: second, wall: wall.addingTimeInterval(Double(second) - now), peak: counts, last: counts, gap: missing || !disconnected.isEmpty))
            }
        } else if buckets.last?.id != id {
            buckets.append(LiveActivityBucket(id: id, wall: wall.addingTimeInterval(Double(id) - now), peak: counts, last: counts, gap: missing || !disconnected.isEmpty))
        }
        trim(); lastTime = now; lastWall = wall; interrupted = false
    }
    mutating func phase(_ phase: String, session: LiveSessionKey, at now: Double, wall: Date) {
        advance(at: now, wall: wall)
        let previous = phases[session] ?? "idle"
        guard phase != previous else { return }
        lastObservationAt = wall
        counts.add(previous, by: -1); counts.add(phase, by: 1)
        if ["idle", "error", "paused", "interrupted"].contains(phase) { phases[session] = nil } else { phases[session] = phase }
        if !buckets.isEmpty { buckets[buckets.count - 1].last = counts; buckets[buckets.count - 1].peak.includePeak(counts) }
    }
    mutating func gap(at now: Double, wall: Date, workspace: String? = nil) {
        gaps += 1
        interrupted = true
        if let workspace { disconnected.insert(workspace) }
        for key in active.keys where workspace == nil || key.session.workspace == workspace {
            active[key]?.baselineAt = nil; active[key]?.baselineOutput = nil; active[key]?.intervalRate = nil
        }
        if !buckets.isEmpty { buckets[buckets.count - 1].gap = true }
        lastTime = now; lastWall = wall
    }
    mutating func disconnect(_ workspace: String, at now: Double, wall: Date) {
        let hadWork = phases.keys.contains { $0.workspace == workspace } || active.keys.contains { $0.session.workspace == workspace }
        advance(at: now, wall: wall)
        if hadWork { gap(at: now, wall: wall, workspace: workspace) }
        for key in Array(phases.keys) where key.workspace == workspace { phase("interrupted", session: key, at: now, wall: wall) }
        active = active.filter { $0.key.session.workspace != workspace }
    }
    mutating func ingest(_ page: [String: WireValue], session: LiveSessionKey, connectionTest: Bool = false, at now: Double, wall: Date) {
        guard let epoch = page["epoch"]?.string, !epoch.isEmpty, epoch.utf8.count <= 128 else { return }
        // A successfully polled unchanged page is still a local observation;
        // the display/sampling timer alone is not.
        lastObservationAt = wall
        if let held = cursors[session], held.epoch == epoch, let cursor = Self.integer(page["cursor"]), cursor <= held.sequence { return }
        advance(at: now, wall: wall)
        let held = cursors[session]
        if let held, held.epoch != epoch {
            gap(at: now, wall: wall)
            active = active.filter { $0.key.session != session }
            settledGenerations[session] = nil
        }
        disconnected.remove(session.workspace)
        var cursor = held?.epoch == epoch ? held!.sequence : 0
        if page["gap"]?.bool == true { gap(at: now, wall: wall); active = active.filter { $0.key.session != session } }
        for raw in (page["events"]?.array ?? []).prefix(96) {
            guard let event = raw.object, let sequence = Self.integer(event["seq"]), sequence > cursor else { continue }
            cursor = sequence
            if event["kind"]?.string == "phase", let phase = event["phase"]?.string {
                self.phase(phase, session: session, at: now, wall: wall)
            } else if event["kind"]?.string == "request" {
                observe(event, session: session, epoch: epoch, connectionTest: connectionTest, at: now, wall: wall)
            }
        }
        cursors[session] = (epoch, max(cursor, Self.integer(page["cursor"]) ?? cursor))
    }
    private mutating func observe(_ event: [String: WireValue], session: LiveSessionKey, epoch: String, connectionTest: Bool, at now: Double, wall: Date) {
        guard let attempt = event["attemptID"]?.string, !attempt.isEmpty, attempt.utf8.count <= 128,
              let generation = Self.integer(event["generation"]) else { return }
        let key = LiveAttemptKey(session: session, epoch: epoch, generation: generation, attempt: attempt)
        let settled = completions.firstIndex { $0.id == key }
        guard settled != nil || active[key] != nil || generation > (settledGenerations[session] ?? -1) else { return }
        var value = active[key] ?? settled.map { completions[$0].request } ?? LiveRequestState(id: key, purpose: "turn", alias: "", phase: "preparing")
        let phase = event["phase"]?.string ?? "awaiting"
        guard !value.terminal || ["final", "interrupted"].contains(phase) else { return }
        let received = Self.number(event["receivedAt"])
        guard received == nil || value.receivedAt == nil || received! >= value.receivedAt! else { return }
        value.purpose = connectionTest ? "connection-test" : String((event["purpose"]?.string ?? "turn").prefix(64))
        value.alias = String((event["requestedModel"]?.string ?? "").prefix(512)); value.phase = phase
        let usage = event["usage"]?.object ?? [:], status = event["status"]?.object ?? [:]
        func token(_ name: String) -> Double? {
            guard status[name]?.string == "reported", let n = Self.number(usage[name]), n <= 1_000_000_000_000, n.rounded() == n else { return nil }
            return n
        }
        value.input = token("input"); value.output = token("output"); value.cached = token("cacheRead"); value.reasoning = token("reasoning")
        value.finalOutput = event["fieldPhase"]?.object?["output"]?.string == "final"
        let telemetry = event["telemetry"]?.object ?? [:], identity = telemetry["identity"]?.object ?? [:]
        value.identityStatus = identity["status"]?.string ?? "unreported"
        let model = identity["effectiveModel"]?.string
        value.model = value.identityStatus == "reported" && model != value.alias ? model.map { String($0.prefix(512)) } : nil
        let gateway = GatewayObservation(metadata: telemetry)
        value.cost = gateway.costUSD; value.costStatus = gateway.costStatus
        value.dispatch = Self.number(telemetry["dispatch"]); value.complete = Self.number(telemetry["modelComplete"])
        value.firstContent = Self.number(telemetry["firstContent"]); value.httpEnd = Self.number(telemetry["httpEnd"])
        if received != value.receivedAt || value.output != value.baselineOutput {
            value.intervalRate = nil
            if !value.terminal, let output = value.output, let received {
                if let previous = value.baselineOutput, let began = value.baselineAt, received > began {
                    let duration = (received - began) / 1_000, rate = (output - previous) / duration
                    if output >= previous, rate.isFinite {
                        value.intervalRate = rate; value.intervalObserved = now; value.intervalDuration = duration
                        if !buckets.isEmpty {
                            buckets[buckets.count - 1].interimSamples += 1
                            buckets[buckets.count - 1].intervalPeak = max(buckets.last?.intervalPeak ?? 0, rate)
                        }
                    } else { value.correction = true }
                }
                value.baselineAt = received; value.baselineOutput = output
            } else { value.baselineAt = nil; value.baselineOutput = nil }
        }
        value.receivedAt = received
        if value.terminal {
            settledGenerations[session] = max(generation, settledGenerations[session] ?? -1)
            active[key] = nil
            guard value.dispatched else { return }
            if let index = settled {
                // A final HTTP observation may enrich identity/cost/timing. It
                // replaces the same completion; it never adds another request.
                amendBucket(completions[index].bucket, request: completions[index].request, by: -1)
                completions[index].request = value
                amendBucket(completions[index].bucket, request: value, by: 1)
            } else {
                let bucket = buckets.last?.id ?? Int(now)
                completions.append(LiveCompletion(id: key, wall: wall, request: value, bucket: bucket))
                amendBucket(bucket, request: value, by: 1)
            }
        } else if value.dispatched { active[key] = value }
        trim()
    }
    private mutating func amendBucket(_ id: Int, request: LiveRequestState, by sign: Int) {
        guard let index = buckets.firstIndex(where: { $0.id == id }) else { return }
        buckets[index].completions += sign
        if let rate = request.rate, let output = request.output, let duration = request.duration {
            buckets[index].rateSamples += sign; buckets[index].output += Double(sign) * output; buckets[index].duration += Double(sign) * duration
            if sign > 0 { buckets[index].minimumRate = min(buckets[index].minimumRate ?? rate, rate); buckets[index].maximumRate = max(buckets[index].maximumRate ?? rate, rate) }
        }
    }
    private mutating func trim() {
        if buckets.count > Self.bucketLimit { buckets.removeFirst(buckets.count - Self.bucketLimit) }
        if completions.count > Self.completionLimit { completions.removeFirst(completions.count - Self.completionLimit) }
        // Cursors only need to survive for displayed sessions/recent records;
        // workspace integration explicitly retires evicted display cursors.
    }
    mutating func forget(_ key: LiveSessionKey, at now: Double, wall: Date) {
        phase("idle", session: key, at: now, wall: wall); cursors[key] = nil; settledGenerations[key] = nil
        active = active.filter { $0.key.session != key }
    }
    func snapshot(at now: Double, wall: Date) -> LivePopupSnapshot {
        var requests = Array(active.values)
        for i in requests.indices where requests[i].currentRate(at: now) == nil { requests[i].intervalRate = nil }
        requests.sort { $0.id.attempt < $1.id.attempt }
        return LivePopupSnapshot(observedAt: wall, lastObservationAt: lastObservationAt, counts: counts, requests: requests, completions: completions, buckets: buckets, disconnected: !disconnected.isEmpty, gaps: gaps)
    }
    static func number(_ value: WireValue?) -> Double? { value?.number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    static func integer(_ value: WireValue?) -> Int? {
        guard let n = number(value), n < Double(Int.max), n.rounded() == n else { return nil }; return Int(n)
    }
}

/// One application-owned sampler. Main-actor ownership serializes small numeric
/// events without a Task per counter; it never observes transcript changes.
@MainActor final class LiveActivityStore: ObservableObject {
    @Published private(set) var snapshot = LivePopupSnapshot()
    private(set) var accumulator = LiveActivityAccumulator()
    private(set) var visible = false
    private(set) var publications = 0
    private var ticker: Task<Void, Never>?, publication: Task<Void, Never>?
    // Registered only on MainActor; deinit removes tokens after ownership ends.
    nonisolated(unsafe) private var sleepObservers: [NSObjectProtocol] = []
    private let now: () -> Double, wall: () -> Date
    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, wall: @escaping () -> Date = { Date() }, observeSleep: Bool = true) {
        self.now = now; self.wall = wall
        if observeSleep {
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
                sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.discontinuity() }
                })
            }
        }
    }
    deinit { ticker?.cancel(); publication?.cancel(); for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func setVisible(_ value: Bool) {
        guard value != visible else { return }; visible = value
        publication?.cancel(); publication = nil
        if value { tick() }; schedule()
    }
    func ingest(_ page: [String: WireValue], workspace: String, session: String, connectionTest: Bool = false) {
        accumulator.ingest(page, session: LiveSessionKey(workspace: workspace, session: session), connectionTest: connectionTest, at: now(), wall: wall()); changed()
    }
    func phase(_ phase: String, workspace: String, session: String) {
        accumulator.phase(phase, session: LiveSessionKey(workspace: workspace, session: session), at: now(), wall: wall()); changed()
    }
    func forget(workspace: String, session: String) { accumulator.forget(LiveSessionKey(workspace: workspace, session: session), at: now(), wall: wall()); changed() }
    func disconnect(_ workspace: String) { accumulator.disconnect(workspace, at: now(), wall: wall()); changed(immediate: true) }
    func discontinuity() { accumulator.gap(at: now(), wall: wall()); changed(immediate: true) }
    private func changed(immediate: Bool = false) {
        schedule()
        guard visible else { return }
        if immediate { publication?.cancel(); publication = nil; publish(); return }
        guard publication == nil else { return }
        publication = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.visible else { return }; self.publication = nil; self.publish()
        }
    }
    private func publish() { let next = accumulator.snapshot(at: now(), wall: wall()); if next != snapshot { snapshot = next; publications += 1 } }
    func tick() { accumulator.advance(at: now(), wall: wall()); if visible { publish() } }
    private func schedule() {
        guard visible || accumulator.hasWork else { ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }; self.tick()
            }
        }
    }
    func shutdown() { visible = false; ticker?.cancel(); ticker = nil; publication?.cancel(); publication = nil }
}
