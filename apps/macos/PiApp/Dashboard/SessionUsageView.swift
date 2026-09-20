import SwiftUI

struct SessionUsageScope: Hashable, Sendable {
    let sessionID: String
    let workspaceID: String
}

typealias SessionUsageLoader = @MainActor (SessionUsageScope, Date, Int) async throws -> MenuBarSnapshot

/// Only an open usage window queries retained metadata. Scope/page revisions prevent
/// a late result from displaying another session's distribution.
@MainActor final class SessionUsageController: ObservableObject {
    @Published private(set) var scope: SessionUsageScope
    @Published private(set) var snapshot: MenuBarSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published private(set) var offset = 0
    @Published var breakdown = SessionUsageBreakdown.models
    /// Per-request timing and cost of this session, fed by the chat's footer.
    @Published var timing = SessionTimingHistory()
    /// The helper's session and last-turn model/tool clocks, fed by the chat's footer.
    @Published var work: [String: WireValue] = [:]
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
    func previousPage() {
        guard offset > 0, !loading else { return }
        offset = max(0, offset - MenuBarSnapshot.pageSize); snapshot = nil; restart()
    }
    func nextPage() {
        guard snapshot?.hasNext == true, !loading else { return }
        offset += MenuBarSnapshot.pageSize; snapshot = nil; restart()
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
                        self.offset = 0; self.snapshot = nil; self.restart(); return
                    }
                    // The fallback poll re-reads the same archive rows; only a
                    // change may redraw the charts and the model table.
                    if self.snapshot != value { self.snapshot = value }
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

enum SessionUsageBreakdown: String, CaseIterable, Hashable {
    case models, costs, timing
    var title: String { rawValue.capitalized }
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
        latestRate = history.latest?.outputTokensPerSecond
        averageRate = history.historicalRate.tokensPerSecond
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

/// Available from the conversation header and its cost total, including child
/// sessions. The archive scope is the session's own attempts, not inherited text.
struct SessionUsageButton: View {
    let model: WorkspaceModel
    let chat: ChatRecord
    @ObservedObject var footer: SessionMetrics
    var costLabel: String? = nil

    private func showWindow() {
        SessionUsageWindows.shared.show(model: model, chat: chat, footer: footer,
                                       initialBreakdown: costLabel == nil ? .models : .costs)
    }

    var body: some View {
        Group {
            if let costLabel {
                Button(action: showWindow) {
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle").font(.system(size: 10))
                        Text(costLabel).lineLimit(1).monospacedDigit().fixedSize()
                    }
                }.buttonStyle(.plain).piPointer()
            } else {
                PiIconButton(symbol: "chart.pie", label: "Session info: timing, tokens, cache, models and costs", action: showWindow)
            }
        }
        .help("Open the Session info window: first-token time, output rate, model and tool time, tokens, cache, model distribution and costs")
        .accessibilityLabel("Session info: timing, tokens, cache, models and costs")
        .accessibilityIdentifier(costLabel == nil ? "sessionUsageButton" : "sessionUsageCostButton")
    }
}

struct SessionUsageView: View {
    let title: String
    @ObservedObject var controller: SessionUsageController
    @State private var showingDetails = false
    @Environment(\.piReduceMotion) private var reduceMotion

    init(title: String, controller: SessionUsageController) {
        self.title = title; self.controller = controller
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's own title bar: it drags and zooms the window, names
            // the session, and leaves the leading room the buttons need.
            ZStack(alignment: .leading) {
                PiWindowBar()
                HStack(spacing: PiSpacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Session info").font(PiFont.title(14)).foregroundStyle(Color.piInk)
                        Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
                    }.allowsHitTesting(false)
                    Spacer(minLength: 8)
                    if controller.loading { ProgressView().controlSize(.small) }
                    PiIconButton(symbol: "arrow.clockwise", label: "Refresh session info", size: 24) { controller.refresh() }
                }
                .padding(.leading, PiWindowBar.trafficLightInset).padding(.trailing, PiSpacing.md)
            }
            .frame(height: 48).background(Color.piWindow)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.md) {
                    if !controller.notice.isEmpty {
                        Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piDanger)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("session-usage-error")
                    }
                    if let snapshot = controller.snapshot {
                        // One page, top to bottom: latency and speed, then the
                        // per-model split those figures blend, then the request
                        // charts, then tokens, cost and cache.
                        summary(snapshot)
                        modelsTable(snapshot)
                        timingCharts
                        tokenBar(snapshot)
                        tokenAndCacheDetails(snapshot)
                        DisclosureGroup("Usage details", isExpanded: $showingDetails) {
                            methodology(snapshot).padding(.top, PiSpacing.sm)
                        }.font(PiFont.caption.weight(.medium))
                    } else {
                        Text(controller.loading ? "Reading session info…" : "Session info unavailable")
                            .font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }.padding(PiSpacing.lg)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color.piContent).tint(Color.piAccent)
        .accessibilityIdentifier("session-usage")
    }

    private func summary(_ snapshot: MenuBarSnapshot) -> some View {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            timingTiles(mixedRoutes: snapshot.modelGroups > 1)
            HStack(alignment: .top, spacing: PiSpacing.sm) {
                PiStatTile(title: "Output tok/s", value: SessionUsagePresentation.rate(snapshot.historicalRate.tokensPerSecond), caption: "\(snapshot.historicalRate.samples)/\(snapshot.counts.completed) completed requests", symbol: "speedometer", tone: .info)
                    .help("Historical output tokens divided by their combined dispatch-to-completion time, including first-token latency. Requests without reported output usage or completion timing are excluded.")
                    .accessibilityIdentifier("session-usage-historical-tps")
                PiStatTile(title: "Requests", value: "\(totals.requests)", caption: "\(snapshot.modelGroups) model \(snapshot.modelGroups == 1 ? "group" : "groups")", symbol: "arrow.up.arrow.down", tone: .accent)
                PiStatTile(title: "Tokens consumed", value: menuBarTokens(tokens.total), caption: coverageCaption(tokens.samples, totals.requests, complete: "input plus output, reported by every request"), symbol: "number", tone: .accent)
                PiStatTile(title: "Reported cost", value: headlineUSD(totals.costUSD), caption: (headlineUSDRounded(totals.costUSD) ? "exactly \(gatewayUSD(totals.costUSD).replacingOccurrences(of: " USD", with: "")) · " : "") + coverageCaption(totals.costSamples, totals.requests, complete: "gateway-reported, every request"), symbol: "dollarsign.circle", tone: .success)
            }
            if snapshot.costUnreported + snapshot.costInvalid + snapshot.costConflicts > 0 {
                Text("\(snapshot.costUnreported) costs unreported · \(snapshot.costInvalid) invalid · \(snapshot.costConflicts) conflicting")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("session-usage-summary")
    }

    /// Latency, output rate and where the session's clock went, from the
    /// footer's retained request history and the helper's session clocks.
    private func timingTiles(mixedRoutes: Bool) -> some View {
        let timing = SessionInfoTiming(history: controller.timing, work: controller.work)
        return HStack(alignment: .top, spacing: PiSpacing.sm) {
            PiStatTile(title: "First token", value: SessionUsagePresentation.milliseconds(timing.latestTTFT), caption: timing.firstTokenCaption, symbol: "timer", tone: .info)
                .help("Time from dispatch to the first model content of the latest request; the median covers every retained request with a measurement.")
                .accessibilityIdentifier("session-info-ttft")
            PiStatTile(title: "Latest tok/s", value: SessionUsagePresentation.rate(timing.latestRate), caption: "session average \(SessionUsagePresentation.rate(timing.averageRate))" + (mixedRoutes ? " · per model below" : ""), symbol: "gauge.with.dots.needle.67percent", tone: .info)
                .help("Output tokens per second of the latest completed request, including its first-token latency.")
                .accessibilityIdentifier("session-info-rate")
            PiStatTile(title: "Model time", value: timing.sessionModelMs.map(workDuration) ?? "n/a", caption: timing.modelCaption, symbol: "brain", tone: .accent)
                .help("Wall-clock time this session spent waiting on model responses, as recorded by the helper.")
                .accessibilityIdentifier("session-info-model-time")
            PiStatTile(title: "Tool time", value: timing.sessionToolMs.map(workDuration) ?? "n/a", caption: timing.toolCaption, symbol: "wrench.and.screwdriver", tone: .warning)
                .help("Wall-clock time this session spent running tool calls, as recorded by the helper.")
                .accessibilityIdentifier("session-info-tool-time")
        }
    }


    private func tokenAndCacheDetails(_ snapshot: MenuBarSnapshot) -> some View {
        let totals = snapshot.gateway, tokens = totals.tokens ?? GatewayTokenTotals()
        let cache = SessionUsageResponseCache(totals)
        return HStack(alignment: .top, spacing: PiSpacing.md) {
            PiCard(padding: PiSpacing.md) {
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Tokens", subtitle: "Reported amounts · coverage shown per request")
                    metricRow("Input", value: menuBarTokens(tokens.input), samples: tokens.inputSamples, total: totals.requests)
                    metricRow("Output", value: menuBarTokens(tokens.output), samples: tokens.outputSamples, total: totals.requests)
                    metricRow("Reasoning", value: menuBarTokens(tokens.reasoning), samples: tokens.reasoningSamples ?? 0, total: totals.requests)
                    Rectangle().fill(Color.piHairline).frame(height: 1)
                    metricRow("Prompt cache read", value: menuBarTokens(totals.cacheReadTokens), samples: totals.cacheReadSamples, total: totals.requests)
                    metricRow("Uncached input", value: menuBarTokens(totals.uncachedInputTokens), samples: totals.uncachedInputSampleCount, total: totals.requests)
                        .help(totals.promptCacheCoverageLabel)
                    metricRow("Prompt cache write", value: menuBarTokens(totals.cacheWriteTokens), samples: totals.cacheWriteSamples, total: totals.requests)
                    Text("Reasoning is included in output; cache reads are included in input. These components are not added again to the total.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("session-usage-tokens")
            PiCard(padding: PiSpacing.md) {
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Response cache", subtitle: cache.known < totals.requests ? "\(cache.known)/\(totals.requests) requests reported hit or miss" : "every request reported hit or miss")
                    HStack(alignment: .firstTextBaseline) {
                        Text(cache.rateLabel).font(PiFont.title(26)).foregroundStyle(Color.piInk).monospacedDigit()
                        Text("known hit rate").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }
                    Text("\(totals.cacheHits) hits · \(totals.cacheMisses) misses · \(totals.cacheUnreported) unreported")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                    if totals.cacheConflicts > 0 {
                        Text("\(totals.cacheConflicts) invalid or conflicting reports excluded")
                            .font(PiFont.micro).foregroundStyle(Color.piWarning)
                    }
                    Text("Response-cache hits are explicit gateway reports. Prompt-cache tokens alone do not indicate a response-cache hit.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(Color.piHairline).frame(height: 1)
                    metricRow("Reasoning cost", value: gatewayUSD(totals.reasoningCostUSD), samples: totals.reasoningCostSamples ?? 0, total: totals.requests)
                    Text("Included in the reported total cost.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                }
            }.accessibilityIdentifier("session-usage-response-cache")
        }
    }

    /// Coverage is worth a line only when it is partial; complete coverage says nothing.
    private func metricRow(_ title: String, value: String, samples: Int, total: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
            Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk).monospacedDigit()
                if samples < total { Text("\(samples)/\(total) reported").font(PiFont.micro).foregroundStyle(Color.piWarning) }
            }
        }
    }
    private func coverageCaption(_ samples: Int, _ total: Int, complete: String) -> String { samples < total ? "\(samples)/\(total) requests reported" : complete }

    /// Cached input, uncached input and output stacked in one bar.
    private func tokenBar(_ snapshot: MenuBarSnapshot) -> some View {
        let bar = SessionTokenBar(snapshot.gateway)
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Token mix", subtitle: bar.coverage)
                if bar.segments.isEmpty {
                    Text("No reported token usage yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(bar.segments) { segment in
                                Rectangle().fill(segment.tone.color).frame(width: max(3, (geometry.size.width - CGFloat(bar.segments.count - 1) * 2) * bar.fraction(segment)))
                                    .accessibilityLabel("\(segment.title) \(menuBarTokens(segment.tokens))")
                            }
                        }
                    }.frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    HStack(spacing: PiSpacing.lg) {
                        ForEach(bar.segments) { segment in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(segment.tone.color).frame(width: 9, height: 9)
                                Text(segment.title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                                Text(menuBarTokens(segment.tokens)).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk).monospacedDigit()
                                Text((bar.fraction(segment)).formatted(.percent.precision(.fractionLength(0)))).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).monospacedDigit()
                            }
                        }
                    }
                    if let reasoning = bar.reasoning {
                        Text("Output includes \(menuBarTokens(reasoning)) reasoning tokens; cached input is included in input, never added again.")
                            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.accessibilityIdentifier("session-token-bar")
    }

    /// One row per requested route and served model: requests and cost with
    /// their share of the session, tokens, and the route's own output rate and
    /// first-token median, so a fast model and a slow one never blend.
    private func modelsTable(_ snapshot: MenuBarSnapshot) -> some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Models", subtitle: snapshot.modelGroups > 1 ? "\(snapshot.modelGroups) routes · speed and first-token time per model, shares of this session" : "One route · its speed and first-token time")
                if snapshot.models.isEmpty {
                    Text("No retained requests for this session yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    modelsHeader
                    ForEach(snapshot.models) { item in
                        Rectangle().fill(Color.piHairline).frame(height: 1)
                        modelUsageRow(item)
                    }
                }
                if snapshot.modelGroups > MenuBarSnapshot.pageSize {
                    PiPager(previous: controller.previousPage, next: controller.nextPage,
                            canPrevious: controller.offset > 0 && !controller.loading,
                            canNext: snapshot.hasNext && !controller.loading) {
                        Text("\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)")
                    }
                }
            }
        }.accessibilityIdentifier("session-model-distribution")
    }
    private static let modelColumns: [(String, CGFloat?)] = [("Requested → final model", nil), ("Requests", 116), ("Cost", 116), ("Tokens", 124), ("Output tok/s", 100), ("First token", 104)]
    private var modelsHeader: some View {
        HStack(spacing: PiSpacing.sm) {
            ForEach(Array(Self.modelColumns.enumerated()), id: \.offset) { _, column in
                Text(column.0).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).lineLimit(1)
                    .frame(width: column.1, alignment: .leading).frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }
    private func modelUsageRow(_ item: MenuBarModelDistribution) -> some View {
        let percent: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }
        return HStack(alignment: .top, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).help(item.requestedAlias)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(PiFont.micro)
                    Text(item.resolutionLabel).font(PiFont.caption).lineLimit(1).truncationMode(.middle).help(item.resolutionLabel)
                }.foregroundStyle(item.resolvedModel == nil ? Color.piWarning : Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            shareCell("\(item.gateway.requests)", share: item.requestShare, detail: percent(item.requestShare) + " of requests", tone: .piAccent).frame(width: 116, alignment: .leading)
            shareCell(gatewayUSD(item.gateway.costUSD).replacingOccurrences(of: " USD", with: ""), share: item.costShare, detail: item.costShare.map { percent($0) + " of cost" } ?? "\(item.gateway.costSamples)/\(item.gateway.requests) reported", tone: .piSuccess).frame(width: 116, alignment: .leading)
                .help("\(gatewayUSD(item.gateway.costUSD)) · \(item.gateway.costSamples)/\(item.gateway.requests) costs reported" + ((item.gateway.reasoningCostSamples ?? 0) > 0 ? " · includes \(gatewayUSD(item.gateway.reasoningCostUSD)) reasoning" : ""))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk)
                if let reasoning = item.gateway.tokens?.reasoning, (item.gateway.tokens?.reasoningSamples ?? 0) > 0 { Text("\(reportTokens(reasoning)) reasoning").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
            }.frame(width: 124, alignment: .leading).help(item.gateway.tokenCacheLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionUsagePresentation.rate(item.historicalRate.tokensPerSecond)).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk)
                Text("\(item.historicalRate.samples)/\(item.gateway.requests) measured").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }.frame(width: 100, alignment: .leading).help("Output tokens divided by dispatch-to-completion time over this route's completed requests with reported usage.")
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionUsagePresentation.milliseconds(item.ttftP50)).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk)
                Text(item.ttftSamples > 0 ? "median of \(item.ttftSamples)" : "not measured").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }.frame(width: 104, alignment: .leading).help("Nearest-rank median time to first token for this route" + (item.httpP50.map { " · whole request median \(SessionUsagePresentation.milliseconds($0))" } ?? ""))
        }.padding(.vertical, 6)
    }
    private func shareCell(_ value: String, share: Double?, detail: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            UsageShareBar(fraction: share ?? 0, tone: tone).frame(height: 4)
            Text(detail).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        }
    }

    @State private var selectedRequest: Int?
    /// Every retained completed request of this session, oldest to newest.
    private var timingCharts: some View {
        let history = controller.timing
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiSectionHeader("Per-request timing and cost", subtitle: history.hasOlderRequests ? "Most recent \(history.samples.count) completed requests" : "\(history.samples.count) completed requests · hover a point for its figures")
            if history.samples.isEmpty {
                Text("No completed requests with retained metrics yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: PiSpacing.md), GridItem(.flexible(), spacing: PiSpacing.md)], alignment: .leading, spacing: PiSpacing.md) {
                    ForEach(SessionTimingMetric.allCases, id: \.rawValue) { metric in
                        PiCard(padding: PiSpacing.md) { SessionTimingChart(history: history, metric: metric, selectedRequest: $selectedRequest, height: 120) }
                    }
                }
                if let index = selectedRequest, history.samples.indices.contains(index - 1) {
                    let sample = history.samples[index - 1]
                    Text("Request \(index) · \(sample.wall.formatted(date: .abbreviated, time: .standard)) · \(SessionTimingMetric.ttft.label(sample.ttftMilliseconds)) TTFT · \(SessionTimingMetric.rate.label(sample.outputTokensPerSecond)) · \(SessionTimingMetric.output.label(sample.outputTokens)) out · \(SessionTimingMetric.cost.label(sample.costUSD))")
                        .font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInk).lineLimit(2)
                }
                Text("Rates include dispatch-to-completion time. Session average: \(SessionTimingMetric.rate.label(history.historicalRate.tokensPerSecond)) over \(history.historicalRate.samples)/\(history.completedRequests) retained completed requests. Gaps indicate missing measurements; costs are gateway-reported.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("session-timing-charts")
    }

    private func methodology(_ snapshot: MenuBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Retained session history · \(snapshot.compactionRequests) compaction requests included")
            Text("Each dispatched request counts once, including tool rounds. Only this session’s requests count; inherited parent messages do not add cost. Auto-router aliases and reported models stay separate.")
            Text("Reasoning is included in output and total cost. Unknown costs are excluded; $0 is a reported zero. \(snapshot.gateway.expiredRecords) expired records excluded. Refreshes while open.")
        }.font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
    }
}
