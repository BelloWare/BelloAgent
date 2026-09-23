import SwiftUI

struct SessionUsageScope: Hashable, Sendable {
    let sessionID: String
    let workspaceID: String
}

typealias SessionUsageLoader = @MainActor (SessionUsageScope, Date, Int) async throws -> MenuBarSnapshot

/// The Session Inspector's whole-log figures and model table. Only an open,
/// visible Inspector queries retained metadata. Scope/page revisions prevent
/// a late result from displaying another session's distribution.
@MainActor final class SessionUsageController: ObservableObject {
    @Published private(set) var scope: SessionUsageScope
    @Published private(set) var snapshot: MenuBarSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published private(set) var offset = 0
    private let load: SessionUsageLoader
    private let interval: Duration
    private let now: () -> Date
    private var visible = false
    private var generation = 0
    private var task: Task<Void, Never>?

    init(scope: SessionUsageScope, load: @escaping SessionUsageLoader, interval: Duration = .seconds(10), now: @escaping () -> Date = { Date() }) {
        self.scope = scope; self.load = load; self.interval = interval; self.now = now
    }
    deinit { task?.cancel() }

    func setScope(_ scope: SessionUsageScope) {
        guard self.scope != scope else { return }
        self.scope = scope; offset = 0; snapshot = nil
        restart()
    }
    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible; restart()
    }
    func refresh() { restart() }
    /// Paging keeps the current page on screen, pager disabled while it
    /// reads, and swaps in the requested page when it lands.
    func previousPage() {
        guard offset > 0, !loading else { return }
        offset = max(0, offset - MenuBarSnapshot.pageSize); restart()
    }
    func nextPage() {
        guard snapshot?.hasNext == true, !loading else { return }
        offset += MenuBarSnapshot.pageSize; restart()
    }
    /// Whether a poll read the same figures. `until`, the bucket bounds that
    /// follow it and the read stamps differ on every read; the Inspector shows
    /// none of them, so they must not redraw the window.
    static func sameFigures(_ a: MenuBarSnapshot, _ b: MenuBarSnapshot) -> Bool {
        a.period == b.period && a.from == b.from && a.counts == b.counts && a.gateway == b.gateway
            && a.workspaces == b.workspaces && a.sessions == b.sessions && a.compactionRequests == b.compactionRequests
            && a.costUnreported == b.costUnreported && a.costInvalid == b.costInvalid && a.costConflicts == b.costConflicts
            && a.models == b.models && a.modelGroups == b.modelGroups && a.offset == b.offset
    }
    private func restart() {
        task?.cancel(); task = nil; generation += 1; loading = false; notice = ""
        guard visible else { return }
        let generation = generation, scope = scope, offset = offset
        let load = load, interval = interval, now = now
        loading = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let value = try await load(scope, now(), offset)
                    try Task.checkCancellation()
                    guard let self, self.generation == generation else { return }
                    if offset > 0 && value.models.isEmpty {
                        self.offset = 0; self.restart(); return
                    }
                    // The fallback poll re-reads the same archive rows; only a
                    // change may redraw the charts and the model table.
                    if !(self.snapshot.map { Self.sameFigures($0, value) } ?? false) { self.snapshot = value }
                    if self.loading { self.loading = false }
                    if !self.notice.isEmpty { self.notice = "" }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    self.loading = false; self.notice = error.localizedDescription
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}

/// One bar for the session's tokens: cached input, uncached input and output
/// stacked in that order. A segment appears only when the gateway reported
/// it; output includes reasoning, which the legend names separately.
struct SessionTokenBar: Equatable {
    struct Segment: Equatable, Identifiable {
        let id: String; let title: String; let tokens: Double; let tone: PiTone
    }
    let segments: [Segment]
    let total: Double
    let reasoning: Double?
    let coverage: String

    init(_ totals: GatewayTotals) {
        let tokens = totals.tokens ?? GatewayTokenTotals()
        var segments: [Segment] = []
        let cached = totals.cacheReadSamples > 0 ? totals.cacheReadTokens : nil
        var uncached = totals.uncachedInputSampleCount > 0 ? totals.uncachedInputTokens : nil
        if uncached == nil, let input = tokens.input, tokens.inputSamples > 0, tokens.inputSamples == totals.requests, let cached, totals.cacheReadSamples == totals.requests, cached <= input {
            uncached = input - cached
        }
        if let cached { segments.append(Segment(id: "cached", title: "Cached input", tokens: cached, tone: .info)) }
        if let uncached { segments.append(Segment(id: "uncached", title: "Uncached input", tokens: uncached, tone: .accent)) }
        else if let input = tokens.input, tokens.inputSamples > 0, cached == nil { segments.append(Segment(id: "input", title: "Input", tokens: input, tone: .accent)) }
        if let output = tokens.output, tokens.outputSamples > 0 { segments.append(Segment(id: "output", title: "Output", tokens: output, tone: .success)) }
        self.segments = segments
        total = segments.reduce(0) { $0 + $1.tokens }
        reasoning = (tokens.reasoningSamples ?? 0) > 0 ? tokens.reasoning : nil
        let partial = [("input", tokens.inputSamples), ("cache", totals.cacheReadSamples), ("output", tokens.outputSamples)].filter { $0.1 < totals.requests }
        coverage = partial.isEmpty ? "cached input, uncached input and output, stacked" : partial.map { "\($0.0) \($0.1)/\(totals.requests)" }.joined(separator: " · ") + " requests reported"
    }
    func fraction(_ segment: Segment) -> Double { total > 0 ? segment.tokens / total : 0 }
}

/// A rate is meaningful only among explicit hit/miss observations. Prompt
/// caching and unknown/invalid gateway reports never enter this denominator.
struct SessionUsageResponseCache {
    let hits: Int
    let known: Int
    init(_ totals: GatewayTotals) {
        hits = totals.cacheHits
        known = totals.cacheHits + totals.cacheMisses
    }
    var rate: Double? { known > 0 ? Double(hits) / Double(known) : nil }
    var rateLabel: String { rate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "Unavailable" }
}

enum SessionUsagePresentation {
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "n/a" }
        return value < 1_000 ? String(format: "%.0f ms", value) : String(format: "%.2f s", value / 1_000)
    }
    /// The line under the per-request charts for the request the pointer is
    /// on. Each figure is the one its chart plots: the rate is the settled
    /// decode rate, not output over the whole request.
    static func requestCaption(index: Int, sample: SessionTimingSample) -> String { caption("Request \(index)", sample) }
    /// The line for the request under the pointer, else for the latest
    /// request, as the timing popover reads it. Empty only with no requests.
    static func requestCaption(selected: Int?, in history: SessionTimingHistory) -> String {
        if let selected, history.samples.indices.contains(selected - 1) { return requestCaption(index: selected, sample: history.samples[selected - 1]) }
        return history.latest.map { caption("Latest", $0) } ?? ""
    }
    private static func caption(_ title: String, _ sample: SessionTimingSample) -> String {
        func figure(_ metric: SessionTimingMetric) -> String { metric.label(metric.value(in: sample)) }
        let when = sample.wall.formatted(date: .abbreviated, time: .standard)
        let parts: [String] = [title, when, figure(.ttft) + " TTFT", figure(.rate) + " decode", figure(.output) + " out", figure(.cost)]
        return parts.joined(separator: " · ")
    }
}

/// The header figures of the Session info window: first-token latency, output
/// rate and the session's model-versus-tool clocks. Missing observations stay
/// missing; nothing is averaged over an absent measurement.
struct SessionInfoTiming: Equatable {
    var latestTTFT: Double?
    var medianTTFT: Double?
    var latestDurationMs: Double?
    var latestRate: Double?
    var averageRate: Double?
    var ttftSamples = 0
    var sessionModelMs: Double?
    var sessionToolMs: Double?
    var turnModelMs: Double?
    var turnToolMs: Double?

    init(history: SessionTimingHistory, work: [String: WireValue]) {
        let ttfts = history.samples.compactMap(\.ttftMilliseconds)
        latestTTFT = history.latest?.ttftMilliseconds
        medianTTFT = Self.median(ttfts); ttftSamples = ttfts.count
        latestDurationMs = history.latest?.requestMilliseconds
        latestRate = history.latest?.settledTokensPerSecond
        averageRate = (history.historicalSettledThroughput ?? history.settledThroughput).tokensPerSecond
        if let split = WorkSplit(timing: work) {
            sessionModelMs = split.sessionModelMs; sessionToolMs = split.sessionToolMs
            if let model = split.turnModelMs, let tools = split.turnToolMs, model + tools > 0 { turnModelMs = model; turnToolMs = tools }
        }
    }
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    var firstTokenCaption: String {
        var parts = ["median \(SessionUsagePresentation.milliseconds(medianTTFT)) · \(ttftSamples) measured"]
        if let latestDurationMs { parts.append("last request \(workDuration(latestDurationMs))") }
        return parts.joined(separator: " · ")
    }
    var modelCaption: String { turnModelMs.map { "last turn \(workDuration($0))" } ?? "waiting on the model, whole session" }
    var toolCaption: String { turnToolMs.map { "last turn \(workDuration($0))" } ?? "running tools, whole session" }
}

/// The composer bar's pie button: the chat's Session Inspector, at its Overview.
struct SessionUsageButton: View {
    let model: WorkspaceModel
    let chat: ChatRecord
    @ObservedObject var footer: SessionMetrics
    var costLabel: String? = nil

    @State private var hovering = false

    private func showWindow() { model.openInspector(session: chat.id, focus: .overview) }

    /// The face is SwiftUI; an AppKit press target over it takes the press,
    /// as over the pills under the composer.
    var body: some View {
        face
            .accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: "Session Inspector: cost, tokens, time and every request",
                                 identifier: costLabel == nil ? "sessionUsageButton" : "sessionUsageCostButton",
                                 help: "Open the Session Inspector: what this chat cost and used, how fast it ran, and every request it made",
                                 onHover: { inside in if hovering != inside { hovering = inside } }, onPress: { _ in showWindow() })
            }
    }

    @ViewBuilder private var face: some View {
        if let costLabel {
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle").font(.system(size: 10))
                Text(costLabel).lineLimit(1).monospacedDigit().fixedSize()
            }
            .foregroundStyle(hovering ? Color.piInk : Color.piInkSecondary)
        } else {
            Image(systemName: "chart.pie")
                .font(.system(size: 28 * 0.46, weight: .medium)).foregroundStyle(Color.piInkSecondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Color.piFillStrong : Color.clear, in: Circle())
                .piAnimation(PiMotion.quick, value: hovering)
        }
    }
}
