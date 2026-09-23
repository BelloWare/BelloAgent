import Foundation

struct MonitorProject: Identifiable, Equatable {
    let id: String
    let title: String
}

struct MonitorModelPalette: Equatable {
    private var indices: [String: Int] = [:]
    mutating func include(_ names: [String]) {
        for name in names.sorted() where indices[name] == nil {
            guard indices.count < 128 else { return }
            let lower = name.lowercased()
            let preferred = lower.contains("mini") ? 0 : lower.contains("claude") ? 1 : lower.contains("gpt") ? 2 : indices.count % 6
            let used = Set(indices.values)
            indices[name] = (0..<6).map { (preferred + $0) % 6 }.first { !used.contains($0) } ?? preferred
        }
    }
    func index(_ model: String) -> Int {
        if model == "Other models" { return 6 }
        return indices[model] ?? model.utf8.reduce(0) { ($0 * 31 + Int($1)) % 6 }
    }
}

/// Brush coordinates are captured against the domain at mouse-down. A live
/// tick cannot move the selection underneath the pointer. No work is queried
/// until the drag ends, and a click/vertical scroll is not a zoom.
struct MonitorChartZoom: Equatable {
    private(set) var range: ClosedRange<Date>?
    private(set) var brush: ClosedRange<Date>?
    private var dragDomain: ClosedRange<Date>?

    mutating func update(startX: Double, x: Double, width: Double, domain: ClosedRange<Date>) {
        guard width.isFinite, width > 0, startX.isFinite, x.isFinite else { return }
        let held = dragDomain ?? domain
        dragDomain = held
        let a = Self.date(x: startX, width: width, domain: held)
        let b = Self.date(x: x, width: width, domain: held)
        brush = min(a, b)...max(a, b)
    }
    @discardableResult mutating func finish(horizontal: Double, vertical: Double) -> Bool {
        defer { brush = nil; dragDomain = nil }
        guard abs(horizontal) >= 8, abs(horizontal) > abs(vertical),
              let brush, brush.upperBound.timeIntervalSince(brush.lowerBound) >= 1 else { return false }
        range = brush
        return true
    }
    mutating func cancel() { brush = nil; dragDomain = nil }
    mutating func reset() { range = nil; cancel() }
    /// Shows a range chosen elsewhere (the report's selection) without
    /// touching a drag in progress.
    mutating func show(_ selected: ClosedRange<Date>?) { if range != selected { range = selected } }
    func domain(following: ClosedRange<Date>) -> ClosedRange<Date> { dragDomain ?? range ?? following }
    static func date(x: Double, width: Double, domain: ClosedRange<Date>) -> Date {
        domain.lowerBound.addingTimeInterval(min(1, max(0, x / width)) * domain.upperBound.timeIntervalSince(domain.lowerBound))
    }
}

struct LiveRateKey: Hashable, Sendable {
    let workspace: String
    let model: String
}

/// One observed second, or a minute of older observed seconds. Missing
/// counters do not become zeros. Rates are averages of observed intervals;
/// they are not token totals and must never be used for billing.
struct LiveRateSample: Identifiable, Equatable, Sendable {
    let id: Int
    var end: Int
    var rates: [LiveRateKey: Double]
    var active: Int
    var reported: Int
    var gap: Bool
    var samples = 1
    var missingWorkspaces: Set<String> = []
    var date: Date { Date(timeIntervalSince1970: Double(id)) }
    func hasGap(workspace: String?) -> Bool {
        if gap { return true }
        guard reported < active else { return false }
        return workspace.map { missingWorkspaces.isEmpty || missingWorkspaces.contains($0) } ?? true
    }
    func models(workspace: String?) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, value) in rates where workspace == nil || key.workspace == workspace {
            result[key.model, default: 0] += value / Double(max(1, samples))
        }
        return result
    }
}

/// Fifteen minutes at one-second resolution plus one-minute aggregates up to
/// 24h. Maximum memory and chart work are independent of app uptime. Only live
/// numerical observations enter here; retained request summaries stay in SQL.
struct LiveRateHistory: Equatable, Sendable {
    static let recentLimit = 900, minuteLimit = 1440, seriesLimit = 64
    private(set) var recent: [LiveRateSample] = []
    private(set) var minutes: [LiveRateSample] = []
    private(set) var modelNames: Set<String> = []

    mutating func record(at wall: Date, rates: [LiveRateKey: Double], active: Int, reported: Int, gap: Bool, missingWorkspaces: Set<String> = []) {
        let time = wall.timeIntervalSince1970
        guard time.isFinite, time >= 0, time < Double(Int.max - 60) else { return }
        let second = Int(time.rounded(.down))
        // Never connect across a backwards wall clock change.
        if let last = recent.last, second < last.id { recent.removeAll(); minutes.removeAll() }
        var bounded: [LiveRateKey: Double] = [:]
        for key in rates.keys.sorted(by: { ($0.workspace, $0.model) < ($1.workspace, $1.model) }).prefix(Self.seriesLimit) {
            if let rate = rates[key], rate.isFinite, rate >= 0 {
                bounded[key] = rate
                if modelNames.count < 128 { modelNames.insert(key.model) }
            }
        }
        // The stacked history represents all concurrent requests. Partial
        // counters remain useful in the headline (with n/N coverage), but
        // cannot create a misleading smaller total area in the history.
        let sample = LiveRateSample(id: second, end: second + 1, rates: bounded, active: active, reported: reported, gap: gap || rates.count > Self.seriesLimit || missingWorkspaces.count > Self.seriesLimit, missingWorkspaces: Set(missingWorkspaces.sorted().prefix(Self.seriesLimit)))
        if recent.last?.id == second { recent[recent.count - 1] = sample }
        else { recent.append(sample) }
        let cutoff = second - Self.recentLimit
        let count = recent.prefix { $0.id <= cutoff }.count
        if count > 0 {
            for old in recent.prefix(count) { merge(old) }
            recent.removeFirst(count)
        }
        minutes.removeAll { $0.end <= second - 86_400 }
        if minutes.count > Self.minuteLimit { minutes.removeFirst(minutes.count - Self.minuteLimit) }
    }
    private mutating func merge(_ sample: LiveRateSample) {
        let minute = sample.id / 60 * 60
        if minutes.last?.id != minute {
            minutes.append(LiveRateSample(id: minute, end: sample.end, rates: sample.rates, active: sample.active, reported: sample.reported, gap: sample.gap, missingWorkspaces: sample.missingWorkspaces))
        } else {
            let i = minutes.count - 1
            minutes[i].end = sample.end; minutes[i].samples += 1
            minutes[i].active += sample.active; minutes[i].reported += sample.reported
            minutes[i].gap = minutes[i].gap || sample.gap
            minutes[i].missingWorkspaces.formUnion(sample.missingWorkspaces)
            if minutes[i].missingWorkspaces.count > Self.seriesLimit {
                minutes[i].gap = true
                minutes[i].missingWorkspaces = Set(minutes[i].missingWorkspaces.sorted().prefix(Self.seriesLimit))
            }
            for (key, value) in sample.rates {
                if minutes[i].rates[key] != nil || minutes[i].rates.count < Self.seriesLimit { minutes[i].rates[key, default: 0] += value }
                else { minutes[i].gap = true }
            }
        }
    }
    func samples(in range: ClosedRange<Date>) -> [LiveRateSample] {
        (minutes + recent).filter { $0.date >= range.lowerBound && $0.date <= range.upperBound }
    }
}

extension LivePopupSnapshot {
    func currentRates(workspace: String?) -> (rate: Double?, reported: Int, active: Int) {
        let requests = requests.filter { workspace == nil || $0.id.session.workspace == workspace }
        let valid = requests.compactMap(\.intervalRate)
        let sum = valid.reduce(0, +)
        return (valid.isEmpty || !sum.isFinite ? nil : sum, valid.count, requests.count)
    }
}

/// Same response model gets one distribution bar even when several requested
/// aliases route to it. Unknown/conflicting identities remain clearly separate.
struct MonitorDistribution: Identifiable, Equatable {
    let id: String
    var aliases: Set<String>
    var tokens: Double?
    var cost: Double?
    var tokenShare: Double?
    var costShare: Double?
    var requests: Int
    static func make(_ models: [MenuBarModelDistribution]) -> [Self] {
        var result: [String: Self] = [:]
        for model in models {
            let label = model.resolvedModel ?? "\(model.requestedAlias) · \(model.identityStatus)"
            var row = result[label] ?? Self(id: label, aliases: [], requests: 0)
            row.aliases.insert(model.requestedAlias); row.requests += model.gateway.requests
            if let tokens = model.gateway.tokens?.output { row.tokens = (row.tokens ?? 0) + tokens }
            if let cost = model.gateway.costUSD { row.cost = (row.cost ?? 0) + cost }
            if let share = model.outputShare { row.tokenShare = (row.tokenShare ?? 0) + share }
            if let share = model.costShare { row.costShare = (row.costShare ?? 0) + share }
            result[label] = row
        }
        return result.values.sorted {
            if ($0.tokens ?? -1) != ($1.tokens ?? -1) { return ($0.tokens ?? -1) > ($1.tokens ?? -1) }
            return $0.id < $1.id
        }
    }
}
