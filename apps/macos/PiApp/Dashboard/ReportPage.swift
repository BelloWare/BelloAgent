import SwiftUI
import Charts

/// The report's headline output rate and how it was measured.
/// It is the app's settled decode rate — provider output over first token to
/// completion — the figure each route's row, Session info and the pills show.
enum ReportThroughputTile {
    static func rate(_ snapshot: DashboardSnapshot) -> SettledThroughput { snapshot.gateway.settledThroughput }
    static func caption(_ snapshot: DashboardSnapshot) -> String {
        let rate = rate(snapshot)
        return "decode, first token to completion · \(rate.samples)/\(snapshot.gateway.requests) measured"
    }
}

/// Usage report as a page inside the main window. The default view is a
/// time range, reported metrics, routing and token splits. Request rows and
/// advanced filters remain available through progressive disclosure.
@MainActor
struct ReportPage: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var report: ReportController
    @Environment(\.piReduceMotion) private var reduceMotion
    @State private var inspected: DashboardRequest?
    @State private var messageLookup: Task<Void, Never>?
    @State private var routingPalette = MonitorModelPalette()
    @State private var requestListOpen = false
    init(model: WorkspaceModel) { self.model = model; self.report = model.report }
    /// A page over a controller with its own queries, for tests.
    init(model: WorkspaceModel, report: ReportController) { self.model = model; self.report = report }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
    private var chips: [ReportFilterChip] { report.activeFilters(workspaces: model.workspaces, chats: model.chats) }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            header(compact: geometry.size.width < 880)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.lg) {
                    if report.advancedOpen { advancedFilters.transition(disclosure) }
                    else if !chips.isEmpty || report.brush != nil { chipRow.transition(disclosure) }
                    if let failure = report.failure { failureState(failure) }
                    if let snapshot = report.snapshot {
                        let active = report.active ?? snapshot
                        if snapshot.scopeCounts.dispatched == 0 && snapshot.scopeCounts.unobservedDispatch == 0 && report.brush == nil { emptyState }
                        else {
                            summary(active, window: snapshot, compact: geometry.size.width < 880)
                            routingOverview(snapshot, active: active, wide: geometry.size.width >= 1050)
                            ReportActiveSessions(live: model.liveActivity, workspaceID: snapshot.filter.workspaceID,
                                activity: { model.menuBarActivity() }, openSession: { id in
                                    Task { if model.side(id) != nil { await model.selectSide(id) } else { await model.select(id) } }
                                })
                            DisclosureGroup("Requests and session details", isExpanded: $requestListOpen) {
                                requests(active, width: max(1100, min(1280, geometry.size.width) - 2 * PiSpacing.xl)).padding(.top, PiSpacing.md)
                            }.font(PiFont.heading).accessibilityIdentifier("analytics-request-details")
                        }
                        if report.detailsOpen { details(active, window: snapshot).transition(disclosure) }
                        detailsToggle
                    } else if report.failure == nil { loadingState }
                }
                .padding(.horizontal, PiSpacing.xl).padding(.vertical, PiSpacing.lg)
                .frame(maxWidth: 1280, alignment: .leading).frame(maxWidth: .infinity)
            }
            .animation(motion, value: report.advancedOpen)
            .animation(motion, value: report.detailsOpen)
            // Async query results replace chart/list data directly. Animating
            // the entire scroll document makes unrelated rows shift while a
            // filter response arrives. Only deliberate disclosures move.
        }
        .background(Color.piContent)
        .task { await report.prepare() }
        .onChange(of: report.modelSummaries, initial: true) { _, rows in routingPalette.include((rows ?? []).map(\.distributionID)) }
        .onChange(of: report.grouping) { _, _ in requestListOpen = true }
        .onDisappear { messageLookup?.cancel(); messageLookup = nil; report.suspend() }
        .onExitCommand { model.closeReport() }
        .sheet(item: $inspected) { request in InspectorView(model: model, sessionID: request.sessionID, initialAttemptID: request.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage report")
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    private var disclosure: AnyTransition {
        reduceMotion ? .opacity : AnyTransition.opacity.combined(with: .move(edge: .top))
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
        HStack(spacing: PiSpacing.md) {
            Button { model.closeReport() } label: { Label("Chats", systemImage: "chevron.left") }
                .buttonStyle(.piGhost).help("Back to chats (Esc)").accessibilityIdentifier("reportBack")
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage report").font(PiFont.title(17)).foregroundStyle(Color.piInk)
                Text(windowCaption).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    .lineLimit(1).truncationMode(.tail).help(windowCaption)
            }
            Spacer(minLength: PiSpacing.sm)
            if report.loading { ProgressView().controlSize(.small).transition(.opacity) }
            if !compact { timeRange }
            PiIconButton(symbol: "arrow.clockwise", label: "Refresh") { Task { await report.refresh() } }.disabled(report.loading)
            Button { report.advancedOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 11, weight: .semibold))
                    Text("Filters")
                    if report.activeFilterCount > 0 {
                        Text("\(report.activeFilterCount)").font(PiFont.micro).foregroundStyle(Color.piOnAccent)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.piAccent, in: Capsule())
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(report.advancedOpen ? 180 : 0))
                }
            }
            .buttonStyle(.piSecondaryCompact).help("Show or hide advanced filters").accessibilityIdentifier("reportFilters")
        }
        if compact { timeRange }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 12).padding(.bottom, 10)
        .animation(motion, value: report.loading)
        .animation(motion, value: report.activeFilterCount)
    }

    private var timeRange: some View {
        PiTabs(selection: Binding(get: { report.window.preset }, set: { report.setPreset($0); if $0 == .custom { report.advancedOpen = true } }), items: DashboardWindowPreset.allCases.map { ($0, $0.title) })
            .fixedSize().accessibilityLabel("Time range")
    }

    private var windowCaption: String {
        let window = report.appliedWindow
        let count = report.snapshot.map { " · \($0.filter.status == "all" ? "All statuses" : $0.filter.status.capitalized)" } ?? ""
        let pending = report.filtersPending ? " · Updating filters…" : ""
        if window.preset == .custom { return "\(window.from.formatted(date: .abbreviated, time: .shortened)) – \(window.until.formatted(date: .abbreviated, time: .shortened))" + count + pending }
        return "Last \(window.preset.title) · since \(window.from.formatted(date: .abbreviated, time: .shortened))" + count + pending
    }

    // MARK: Filters

    private var chipRow: some View {
        ReportFlow(spacing: 6) {
            ForEach(chips) { chip in
                PiChip(text: chip.label, icon: "line.3.horizontal.decrease", remove: { report.clear(chip) })
            }
            if let brush = report.brush, let active = report.focused {
                PiChip(text: "Selected \(brush.label) · \(active.selectedRequests) requests", icon: "selection.pin.in.out",
                       help: "Chart selection narrows the tiles and list. The saved filter is unchanged.", remove: { report.clearBrush() })
            }
            if chips.count > 1 { Button("Clear all") { report.reset() }.buttonStyle(.piGhost) }
        }
    }

    private var advancedFilters: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                if report.window.preset == .custom {
                    ReportFlow(spacing: PiSpacing.sm) {
                        datePill("From", anchorFrom: true)
                        datePill("Until", anchorFrom: false)
                    }
                }
                ReportFlow(spacing: PiSpacing.sm) {
                    ReportDropdown(selection: Binding(get: { report.preferences.workspaceID ?? "" }, set: { report.setWorkspace($0.isEmpty ? nil : $0) }),
                               items: projectFilterItems,
                               icon: "folder")
                    ReportDropdown(selection: Binding(get: { report.sessionEntry ? ReportController.manualSession : (report.preferences.sessionID ?? "") }, set: { report.chooseSession($0) }), items: sessionItems, icon: "bubble.left")
                    if report.sessionEntry {
                        PiTextField(placeholder: "Session id", text: optional(\.sessionID), icon: "number", mono: true).frame(width: 220).transition(.opacity)
                    }
                    ReportDropdown(selection: $report.preferences.status, items: [("completed", "Completed"), ("all", "All statuses"), ("failed", "Failed"), ("cancelled", "Cancelled"), ("running", "Running"), ("truncated", "Truncated"), ("interrupted", "Interrupted")], icon: "checkmark.circle")
                    ReportDropdown(selection: optional(\.api), items: [("", "All API history"), ("openai-responses", "Responses"), ("anthropic-messages", "Messages · history")], icon: "arrow.left.arrow.right")
                    ReportDropdown(selection: optional(\.purpose), items: valueItems(report.purposes, any: "Any purpose", current: report.preferences.purpose), icon: "tag")
                }
                ReportFlow(spacing: PiSpacing.sm) {
                    ReportDropdown(selection: optional(\.requestedAlias), items: valueItems(report.aliases, any: "Any requested model", current: report.preferences.requestedAlias), icon: "arrow.triangle.branch")
                    ReportDropdown(selection: optional(\.effectiveModel), items: valueItems(report.models, any: "Any final model", current: report.preferences.effectiveModel), icon: "cpu")
                        .disabled(report.unreportedOnly).opacity(report.unreportedOnly ? 0.5 : 1)
                    Toggle("Final model not reported", isOn: $report.unreportedOnly).toggleStyle(.checkbox).font(PiFont.caption)
                        .help("Includes unreported, conflicting or incomplete model evidence; the inspector preserves the distinct status and provenance.")
                    Button("Reset") { report.reset() }.buttonStyle(.piGhost).disabled(report.loading)
                    Button("Save as Default") { Task { await report.save() } }.buttonStyle(.piGhost).disabled(report.loading || !model.configurationLoaded)
                }
                Text("Filters apply as you change them. The summary, chart and list use the selected status. Details also show totals across all statuses.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
            }
        }
        .animation(motion, value: report.sessionEntry)
        .animation(motion, value: report.window.preset)
    }

    private var sessionItems: [(String, String)] {
        let chats = model.chats.filter { report.preferences.workspaceID == nil || $0.workspaceID == report.preferences.workspaceID }.prefix(200)
        var items: [(String, String)] = [("", "Any session")] + chats.map { ($0.id, $0.title.isEmpty ? String($0.id.prefix(8)) : $0.title) }
        if let id = report.preferences.sessionID, !report.sessionEntry, !chats.contains(where: { $0.id == id }) { items.append((id, "Retained: " + String(id.prefix(8)))) }
        items.append((ReportController.manualSession, "Enter id…"))
        return items
    }
    private func valueItems(_ values: [String], any: String, current: String?) -> [(String, String)] {
        var items = [("", any)] + values.map { ($0, $0) }
        if let current, !current.isEmpty, !values.contains(current) { items.append((current, current + " (not in window)")) }
        return items
    }
    private func optional(_ path: WritableKeyPath<DashboardPreferences, String?>) -> Binding<String> {
        Binding(get: { report.preferences[keyPath: path] ?? "" }, set: { report.preferences[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    /// The date-time picker is the one stock control here; it sits inside a pill.
    private func datePill(_ label: String, anchorFrom: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            DatePicker("", selection: Binding(get: { anchorFrom ? (report.preferences.customFrom ?? report.window.from) : (report.preferences.customUntil ?? report.window.until) },
                                              set: { report.setCustomBound($0, anchorFrom: anchorFrom) }), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field).labelsHidden().controlSize(.small).font(PiFont.caption).fixedSize()
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 3)
        .background(Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("Reading retained request metrics…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
        }.frame(maxWidth: .infinity, minHeight: 320)
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 28)).foregroundStyle(Color.piInkTertiary)
            Text("No requests in this range").font(PiFont.title(16)).foregroundStyle(Color.piInk)
            Text(chips.isEmpty ? "Send a message, or widen the time range." : "Widen the time range or clear a filter.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            HStack(spacing: PiSpacing.sm) {
                if report.window.preset != .month { Button("Last 30 days") { report.setPreset(.month) }.buttonStyle(.piSecondaryCompact) }
                if !chips.isEmpty { Button("Clear filters") { report.reset() }.buttonStyle(.piGhost) }
            }
        }.frame(maxWidth: .infinity, minHeight: 320)
    }
    private func failureState(_ message: String) -> some View {
        HStack(spacing: PiSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.piDanger)
            Text(message).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await report.refresh() } }.buttonStyle(.piSecondaryCompact)
        }
        .padding(PiSpacing.md)
        .background(Color.piDanger.opacity(0.10), in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
    }

    // MARK: Summary

    /// One view tree at every width: the layout changes, the cards do not, so
    /// the chart keeps its zoom and metric and the map its "Show all" when the
    /// page crosses the wide breakpoint.
    @ViewBuilder private func routingOverview(_ snapshot: DashboardSnapshot, active: DashboardSnapshot, wide: Bool) -> some View {
        let rows = report.modelSummaries ?? []
        let models = MonitorDistribution.report(rows, total: active.gateway)
        let loading = report.modelSummaries == nil
        let row = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: PiSpacing.md)) : AnyLayout(VStackLayout(alignment: .leading, spacing: PiSpacing.lg))
        row {
            chart(snapshot).frame(maxWidth: .infinity)
            ModelRoutingMap(rows: rows, palette: routingPalette, loading: loading).frame(width: wide ? 350 : nil).frame(maxWidth: wide ? nil : .infinity)
        }
        row {
            ModelCostBreakdown(models: models, total: active.gateway, palette: routingPalette, loading: loading).frame(maxWidth: .infinity)
            AnalyticsTokenBreakdown(gateway: active.gateway).frame(maxWidth: .infinity)
        }
    }

    private func summary(_ active: DashboardSnapshot, window: DashboardSnapshot, compact: Bool) -> some View {
        let counts = window.scopeCounts
        let problems = counts.failed + counts.cancelled + counts.truncated + counts.interrupted
        let statusCaption = report.brush != nil ? "\(active.filter.status.capitalized) · selected range" : active.filter.status != "all" ? "\(active.filter.status.capitalized) · \(counts.dispatched) across all statuses" : "\(counts.completed) completed" + (problems > 0 ? " · \(problems) not completed" : "") + (counts.running > 0 ? " · \(counts.running) running" : "")
        let tokens = active.gateway.tokens
        let tokenValue = tokens.map { "in \(reportTokens($0.input)) · out \(reportTokens($0.output))" } ?? "Not reported"
        let tokenCaption = tokens.map { t in
            // Input and output are summed over their own reporting requests; one
            // shared count would misstate whichever side has more samples.
            let total = active.gateway.requests
            // Coverage is named only where it is partial; "(6/6)" after every figure is noise.
            let cover: (Int) -> String = { $0 < total ? " (\($0)/\(total))" : "" }
            let reported = t.inputSamples == t.samples && t.outputSamples == t.samples ? (t.samples < total ? "\(t.samples)/\(total) reported" : "every request reported") : "in \(t.inputSamples)/\(total) · out \(t.outputSamples)/\(total) reported"
            return "cached \(reportTokens(active.gateway.cacheReadTokens))\(cover(active.gateway.cacheReadSamples)) · uncached \(reportTokens(active.gateway.uncachedInputTokens))\(cover(active.gateway.uncachedInputSampleCount)) · " + reported
        } ?? "The gateway reported no usage tokens"
        return LazyVGrid(columns: compact ? [GridItem(.adaptive(minimum: 172, maximum: 320), spacing: PiSpacing.md, alignment: .top)] : Array(repeating: GridItem(.flexible(), spacing: PiSpacing.md, alignment: .top), count: 6), alignment: .leading, spacing: PiSpacing.md) {
            PiStatTile(title: "Requests", value: "\(active.selectedRequests)", caption: statusCaption, symbol: "paperplane", tone: .accent)
            PiStatTile(title: "Reported cost", value: monitorCost(active.gateway.costUSD), caption: active.gateway.costSamples < active.gateway.requests ? "\(active.gateway.costSamples)/\(active.gateway.requests) requests reported" : "gateway-reported, every request", symbol: "dollarsign.circle", tone: .success)
                .help(active.gateway.costLabel + "\n" + reportReasoningDetail(active.gateway))
            PiStatTile(title: "Tokens", value: tokenValue, caption: tokenCaption, symbol: "number", tone: .accent)
                .help(reportReasoningDetail(active.gateway) + "\n" + active.gateway.promptCacheCoverageLabel)
            PiStatTile(title: "Input cache hit", value: monitorCacheShare(active.gateway), caption: active.gateway.promptCacheCoverageLabel, symbol: "memorychip", tone: .success)
            PiStatTile(title: "First token", value: "p50 " + milliseconds(active.ttft.p50), caption: "p99 \(milliseconds(active.ttft.p99)) · HTTP p50 \(milliseconds(active.http.p50))", symbol: "timer", tone: .info)
            PiStatTile(title: "Output tok/s", value: menuBarRate(ReportThroughputTile.rate(active).tokensPerSecond), caption: ReportThroughputTile.caption(active), symbol: "speedometer", tone: .info)
                .help(SettledThroughput.explanation + " Each route's rate is listed under By model.")
        }
        .animation(motion, value: report.brush)
    }

    // MARK: Chart

    @ViewBuilder private func chart(_ snapshot: DashboardSnapshot) -> some View {
        if report.chartMetric == "Output tok/s" {
            ReportThroughputPanel(live: model.liveActivity, snapshot: snapshot, window: report.appliedWindow, palette: routingPalette,
                controls: { AnyView(chartMetricPicker) }, registerModels: { routingPalette.include($0) }, selection: report.chartSelection,
                select: { range in
                    if let range, let brush = DashboardBrush(range.lowerBound, range.upperBound, in: snapshot.filter) { report.applyBrush(brush) }
                    else { report.clearBrush() }
                })
        } else { retainedChart(snapshot) }
    }

    private var chartMetricPicker: some View {
        PiDropdown(selection: $report.chartMetric, items: [("Output tok/s", "Output tok/s"), ("Requests", "Requests"), ("Cost", "Cost"), ("Latency", "Latency"), ("Ratio", "Cache")], compact: true).frame(width: 140)
    }

    private func retainedChart(_ snapshot: DashboardSnapshot) -> some View {
        let domain = snapshot.filter.from...snapshot.filter.until
        // A bare hour reads as a day of the month; keep the date on every tick.
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let axisFormat: Date.FormatStyle = span <= 3600 ? .dateTime.hour().minute()
            : span <= 36 * 3600 ? .dateTime.month(.abbreviated).day().hour() : .dateTime.month(.abbreviated).day()
        let metric = report.chartMetric
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Throughput & activity", subtitle: chartSubtitle) {
                    chartMetricPicker
                }
                Chart(snapshot.buckets) { bucket in
                    if metric == "Latency" {
                        let values = report.latencyMetric == "TTFT" ? bucket.ttft : report.latencyMetric == "Streaming" ? bucket.streaming : bucket.http
                        if let p50 = values.p50 {
                            LineMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p50), series: .value("Percentile", "p50")).foregroundStyle(by: .value("Percentile", "p50")).interpolationMethod(.monotone)
                            PointMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p50)).foregroundStyle(by: .value("Percentile", "p50")).symbolSize(26)
                                .accessibilityLabel("p50 at " + bucket.start.formatted()).accessibilityValue("\(p50) milliseconds, \(values.samples) samples")
                        }
                        if let p99 = values.p99 {
                            LineMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p99), series: .value("Percentile", "p99")).foregroundStyle(by: .value("Percentile", "p99")).interpolationMethod(.monotone)
                            PointMark(x: .value("Time", bucket.start), y: .value("Milliseconds", p99)).foregroundStyle(by: .value("Percentile", "p99")).symbolSize(26)
                                .accessibilityLabel("p99 at " + bucket.start.formatted()).accessibilityValue("\(p99) milliseconds, \(values.samples) samples")
                        }
                    } else if metric == "Ratio" {
                        if let ratio = bucket.gateway.cacheHitRatio {
                            LineMark(x: .value("Time", bucket.start), y: .value("Hit ratio", ratio * 100)).foregroundStyle(Color.piSuccess).interpolationMethod(.monotone)
                            PointMark(x: .value("Time", bucket.start), y: .value("Hit ratio", ratio * 100)).foregroundStyle(Color.piSuccess).symbolSize(26)
                                .accessibilityLabel(bucket.start.formatted()).accessibilityValue(String(format: "%.0f%% of %d reported", ratio * 100, bucket.gateway.cacheHits + bucket.gateway.cacheMisses))
                        }
                    } else if metric == "Cost" {
                        if let cost = bucket.gateway.costUSD {
                            RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("USD", 0), yEnd: .value("USD", cost))
                                .foregroundStyle(Color.piBrandOrange).cornerRadius(3)
                                .accessibilityLabel(bucket.start.formatted()).accessibilityValue(bucket.gateway.costLabel)
                        }
                    } else {
                        RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("Until", bucket.end), yStart: .value("Count", 0), yEnd: .value("Count", bucket.requests))
                            .foregroundStyle(Color.piBrandOrange).cornerRadius(3)
                            .accessibilityLabel(bucket.start.formatted()).accessibilityValue("\(bucket.requests) requests")
                    }
                }
                .chartXScale(domain: domain)
                .chartPercentScale(metric == "Ratio")
                .chartForegroundStyleScale(["p50": Color.piAccent, "p99": Color.piInfo])
                .chartLegend(metric == "Latency" ? .visible : .hidden)
                .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel().foregroundStyle(Color.piInkTertiary) } }
                .chartXAxis { AxisMarks(preset: .aligned) { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat, centered: false, anchor: .top).foregroundStyle(Color.piInkTertiary) } }
                .chartPlotStyle { $0.padding(.trailing, PiSpacing.sm) }
                .dashboardBrush(filter: snapshot.filter, committed: report.chartSelection, commit: { report.applyBrush($0) })
                .frame(height: 200)
                if report.brush != nil { Button("Reset selection") { report.clearBrush() }.buttonStyle(.piGhost) }
                if metric == "Latency" {
                    PiTabs(selection: $report.latencyMetric, items: [("TTFT", "First token"), ("Streaming", "Streaming"), ("HTTP", "Whole request")]).transition(.opacity)
                }
            }
        }
        .animation(motion, value: report.chartMetric)
    }
    /// "Bucket" is how the query groups rows; a reader sees a chart over time.
    private var chartSubtitle: String {
        switch report.chartMetric {
        case "Output tok/s": return "Output tokens / decode time · drag to select a range"
        case "Cost": return "Reported USD over time · drag to select a range"
        case "Latency": return "p50 and p99 over time, in milliseconds · drag to select a range"
        case "Ratio": return "Cache hit ratio over time, % of reported · drag to select a range"
        default: return "Requests over time · drag to select a range"
        }
    }

    // MARK: Requests

    private func requests(_ snapshot: DashboardSnapshot, width: CGFloat) -> some View {
        let titles = report.labels(for: model).titles
        return VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiSectionHeader(report.grouping == "sessions" ? "Sessions" : report.grouping == "models" ? "Models" : "Requests", subtitle: report.grouping == "sessions" ? "Per-chat totals and medians · expand a session for its requests" : report.grouping == "models" ? "Per route: requests, cost, tokens, output rate and first-token median · click a row to filter by it" : "Click a row for exact retained bytes and model evidence")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PiSpacing.sm) {
                    groupingTabs
                    Spacer(minLength: PiSpacing.sm)
                    requestPager(snapshot).fixedSize()
                }
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    groupingTabs
                    requestPager(snapshot).fixedSize()
                }
            }
            ScrollView(.horizontal) {
            VStack(spacing: 0) {
                if report.grouping == "sessions" {
                    sessionRows(titles: titles)
                } else if report.grouping == "models" {
                    modelRows(allRequests: snapshot.selectedRequests, allCost: snapshot.gateway.costUSD)
                } else {
                ReportGridRow(cells: ["Started", "Session", "Requested → final model", "Status", "Cost", "Tokens", "Duration", "Cache"], header: true)
                Rectangle().fill(Color.piHairline).frame(height: 1)
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.requests) { item in
                        ReportRequestRow(item: item, title: titles[item.sessionID], detailed: report.detailsOpen, inspect: { inspected = item }, message: { goToMessage(item) })
                        Rectangle().fill(Color.piHairline).frame(height: 1)
                    }
                }
                if snapshot.requests.isEmpty {
                    Text("No dispatched requests match these filters").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(maxWidth: .infinity).padding(PiSpacing.lg)
                }
                }
            }
            .frame(width: width).piInset()
            .animation(motion, value: report.grouping)
            .animation(motion, value: report.expandedSessions)
            }
        }
    }

    private var groupingTabs: some View {
        PiTabs(selection: $report.grouping, items: [("requests", "Requests"), ("sessions", "By session"), ("models", "By model")])
            .fixedSize().accessibilityIdentifier("reportGrouping")
    }

    @ViewBuilder private func requestPager(_ snapshot: DashboardSnapshot) -> some View {
        if report.grouping == "models" {
            Text(report.modelSummaries.map { $0.isEmpty ? "No routes" : "\($0.count) \($0.count == 1 ? "route" : "routes")" + ($0.count >= PayloadArchive.modelGroupLimit ? " · busiest shown" : "") } ?? "Grouping…")
                .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
        } else if report.grouping == "sessions", let page = report.sessions {
            PiPager(previous: { Task { await report.pageSessions(offset: max(0, page.offset - PayloadArchive.sessionPageSize)) } },
                    next: { Task { await report.pageSessions(offset: page.offset + PayloadArchive.sessionPageSize) } },
                    canPrevious: page.offset > 0 && !report.loading, canNext: page.hasNext && !report.loading, previousLabel: "Previous", nextLabel: "Next") {
                Text(page.sessions.isEmpty ? "No sessions" : "\(page.offset + 1)–\(page.offset + page.sessions.count) of \(page.total)")
            }
        } else {
            PiPager(previous: { Task { await report.page(offset: max(0, snapshot.offset - 128)) } },
                    next: { Task { await report.page(offset: snapshot.offset + 128) } },
                    canPrevious: snapshot.offset > 0 && !report.loading && !report.filtersPending, canNext: snapshot.hasNext && !report.loading && !report.filtersPending, previousLabel: "Previous", nextLabel: "Next") {
                Text(Self.requestPageLabel(snapshot))
            }
        }
    }
    /// "129–145 of 145": the rows on this page and the total they were read
    /// with. A paged read counts again; the report's own total may be older.
    static func requestPageLabel(_ snapshot: DashboardSnapshot) -> String {
        snapshot.requests.isEmpty ? "No rows" : "\(snapshot.offset + 1)–\(snapshot.offset + snapshot.requests.count) of \(snapshot.rowCount ?? snapshot.selectedRequests)"
    }

    /// Configured projects, the scratch group when it holds chats, and a
    /// retained id when the saved filter names a project that no longer exists.
    private var projectFilterItems: [(String, String)] {
        var items: [(String, String)] = [("", "All projects")]
        items += model.workspaces.map { ($0.id, URL(fileURLWithPath: $0.path).lastPathComponent) }
        if model.chats.contains(where: { $0.workspaceID == WorkspaceRecord.scratchID }) { items.append((WorkspaceRecord.scratchID, "No project")) }
        if let id = report.preferences.workspaceID, id != WorkspaceRecord.scratchID, !model.workspaces.contains(where: { $0.id == id }) { items.append((id, "Retained: " + id)) }
        return items
    }

    // MARK: Models

    /// One row per requested route and served model. The share bars are of the
    /// same filtered window as the tiles; clicking a row narrows the report to it.
    @ViewBuilder private func modelRows(allRequests: Int, allCost: Double?) -> some View {
        ReportGridRow(cells: ["Requested → final model", "Requests", "Cost", "Tokens", "Cache", "Output tok/s", "First token"], header: true, widths: ReportColumns.modelWidths)
        Rectangle().fill(Color.piHairline).frame(height: 1)
        if let summaries = report.modelSummaries {
            LazyVStack(spacing: 0) {
                ForEach(summaries) { summary in
                    ReportModelRow(summary: summary, allRequests: allRequests, allCost: allCost, detailed: report.detailsOpen) {
                        report.narrow(toRoute: summary)
                    }
                    Rectangle().fill(Color.piHairline).frame(height: 1)
                }
            }
            if summaries.isEmpty {
                Text("No routes match these filters").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(maxWidth: .infinity).padding(PiSpacing.lg)
            }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Grouping by model…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }.frame(maxWidth: .infinity).padding(PiSpacing.lg)
        }
    }

    // MARK: Sessions

    @ViewBuilder private func sessionRows(titles: [String: String]) -> some View {
        let workspaces = report.labels(for: model).workspaces
        ReportGridRow(cells: ["Last active", "Session", "Requests", "Cost", "Tokens", "Cache", "Latency p50", ""], header: true, widths: ReportColumns.sessionWidths)
        Rectangle().fill(Color.piHairline).frame(height: 1)
        if let page = report.sessions {
            LazyVStack(spacing: 0) {
                ForEach(page.sessions) { summary in
                    let expanded = report.expandedSessions.contains(summary.sessionID)
                    ReportSessionRow(summary: summary, title: titles[summary.sessionID], workspace: workspaces[summary.workspaceID], available: model.record(summary.sessionID) != nil, expanded: expanded, detailed: report.detailsOpen,
                                     toggle: { report.toggleSession(summary.sessionID) }, open: { Task { await model.revealMessage(sessionID: summary.sessionID, messageID: nil) } })
                    if expanded {
                        Group {
                            if let inner = report.sessionRequests[summary.sessionID] {
                                ForEach(inner.requests) { item in
                                    ReportRequestRow(item: item, title: nil, detailed: report.detailsOpen, inspect: { inspected = item }, message: { goToMessage(item) }, nested: true)
                                    Rectangle().fill(Color.piHairline).frame(height: 1)
                                }
                                if inner.hasNext { Text("Showing the first \(inner.requests.count) of \(inner.selectedRequests) requests · filter by this session for the rest").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).padding(.vertical, 6).padding(.leading, 44) }
                            } else {
                                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading requests…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }.padding(.vertical, 8).padding(.leading, 44)
                            }
                        }
                        .background(Color.piSurfaceSunken.opacity(0.6))
                        .transition(disclosure)
                    }
                    Rectangle().fill(Color.piHairline).frame(height: 1)
                }
            }
            if page.sessions.isEmpty {
                Text("No sessions match these filters").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(maxWidth: .infinity).padding(PiSpacing.lg)
            }
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Grouping by session…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }.frame(maxWidth: .infinity).padding(PiSpacing.lg)
        }
    }

    /// Jumps to the message a request produced (or last consumed). When the
    /// chat is gone or the message left the visible transcript, the model
    /// explains that instead of failing silently.
    private func goToMessage(_ item: DashboardRequest) {
        messageLookup?.cancel()
        messageLookup = Task {
            let message = await report.linkedMessage(attemptID: item.id)
            guard !Task.isCancelled, model.page == .report else { return }
            // The lookup belongs to Report; navigation now belongs to the
            // workspace and must survive Report disappearing during select.
            messageLookup = nil
            await model.revealMessage(sessionID: item.sessionID, messageID: message)
        }
    }

    // MARK: Details

    private var detailsToggle: some View {
        Button { report.detailsOpen.toggle() } label: {
            HStack(spacing: 5) {
                Text(report.detailsOpen ? "Hide details" : "Details · timings, coverage and methodology")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(report.detailsOpen ? 180 : 0))
            }
        }.buttonStyle(.piGhost).accessibilityIdentifier("reportDetails")
    }
    private func details(_ active: DashboardSnapshot, window: DashboardSnapshot) -> some View {
        let c = window.scopeCounts
        return VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack(spacing: PiSpacing.md) {
                latencyTile("Time to first token", symbol: "timer", value: active.ttft)
                latencyTile("Streaming span", symbol: "waveform.path.ecg", value: active.streaming)
                latencyTile("Whole request", symbol: "network", value: active.http)
            }
            PiCard(padding: PiSpacing.md) {
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Coverage", subtitle: "Every status in the window; the list and metrics above use the selected status. Metrics older than \(model.configuration.dashboard.metricRetentionDays) days have expired and are not counted in any range.")
                    ReportFlow(spacing: 6) {
                        PiBadge(text: "\(c.completed) completed", tone: .success, dot: true)
                        PiBadge(text: "\(c.failed) failed", tone: c.failed > 0 ? .danger : .neutral, dot: true)
                        PiBadge(text: "\(c.cancelled) cancelled", dot: true)
                        PiBadge(text: "\(c.running) running", tone: c.running > 0 ? .warning : .neutral, dot: true)
                        PiBadge(text: "\(c.truncated) truncated", dot: true)
                        PiBadge(text: "\(c.interrupted) interrupted", dot: true)
                        PiBadge(text: "\(c.unobservedDispatch) without observed dispatch", tone: c.unobservedDispatch > 0 ? .warning : .neutral)
                    }
                    Text("Applied status: \(window.filter.status) · \(window.selectedRequests) requests" + (report.brush == nil ? "" : " · \(active.selectedRequests) in the chart selection"))
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Text(active.gateway.tokenCacheLabel).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Text(reportReasoningDetail(active.gateway)).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                    PiStatusLine(text: report.notice)
                    Text("Nearest-rank percentiles: sort n observed values; select rank ceil(p × n). Missing values are excluded, never zero. TTFT = first nonempty model content − dispatch. Streaming span = model terminal − first content. Whole request = EOF/error/cancellation − dispatch. Gateway retries and tool calls are not local HTTP attempts.")
                        .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func latencyTile(_ title: String, symbol: String, value: DashboardPercentiles) -> some View {
        PiStatTile(title: title, value: "p50 " + milliseconds(value.p50), caption: "p99 \(milliseconds(value.p99)) · \(value.samples) observed samples", symbol: symbol)
    }
    private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
}
