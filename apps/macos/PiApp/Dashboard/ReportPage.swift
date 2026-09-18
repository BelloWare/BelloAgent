import SwiftUI
import Charts

/// Usage report as a page inside the main window. The default view is a
/// time range, four summary tiles, one chart and the request list; advanced
/// filters, detailed timings and coverage sit behind progressive disclosure.
@MainActor
struct ReportPage: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var report: ReportController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspected: DashboardRequest?
    @State private var messageLookup: Task<Void, Never>?
    init(model: WorkspaceModel) { self.model = model; self.report = model.report }

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
                            chart(snapshot)
                            requests(active, width: max(1100, min(1280, geometry.size.width) - 2 * PiSpacing.xl))
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
            .animation(motion, value: chips)
            .animation(motion, value: report.brush)
            .animation(motion, value: report.snapshot?.filter)
        }
        .background(Color.piContent)
        .task { await report.prepare() }
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
            PiStatTile(title: "Reported cost", value: gatewayUSD(active.gateway.costUSD), caption: active.gateway.costSamples < active.gateway.requests ? "\(active.gateway.costSamples)/\(active.gateway.requests) requests reported" : "gateway-reported, every request", symbol: "dollarsign.circle", tone: .success)
                .help(active.gateway.costLabel + "\n" + reportReasoningDetail(active.gateway))
            PiStatTile(title: "Tokens", value: tokenValue, caption: tokenCaption, symbol: "number", tone: .accent)
                .help(reportReasoningDetail(active.gateway) + "\n" + active.gateway.promptCacheCoverageLabel)
            PiStatTile(title: "Response cache", value: active.gateway.cacheHitRatio.map { String(format: "%.0f%% hit", $0 * 100) } ?? "Not reported", caption: "\(active.gateway.cacheHits) hit · \(active.gateway.cacheMisses) miss · \(active.gateway.cacheUnreported) unreported" + (active.gateway.cacheConflicts > 0 ? " · \(active.gateway.cacheConflicts) conflicting" : ""), symbol: "memorychip", tone: .info)
            PiStatTile(title: "First token", value: "p50 " + milliseconds(active.ttft.p50), caption: "p99 \(milliseconds(active.ttft.p99)) · HTTP p50 \(milliseconds(active.http.p50))", symbol: "timer", tone: .info)
            PiStatTile(title: "Output tok/s", value: SessionUsagePresentation.rate(active.historicalRate.tokensPerSecond), caption: "\(active.historicalRate.samples)/\(active.gateway.requests) measured" + ((report.modelSummaries?.count ?? 0) > 1 ? " · per model below" : ", duration-weighted"), symbol: "speedometer", tone: .info)
                .help("Output tokens divided by their combined dispatch-to-completion time, including first-token latency. A window with several models blends them here; the By model table keeps each route apart.")
        }
        .animation(motion, value: report.brush)
    }

    // MARK: Chart

    private func chart(_ snapshot: DashboardSnapshot) -> some View {
        let domain = snapshot.filter.from...snapshot.filter.until
        // A bare hour reads as a day of the month; keep the date on every tick.
        let axisFormat: Date.FormatStyle = domain.upperBound.timeIntervalSince(domain.lowerBound) <= 36 * 3600
            ? .dateTime.month(.abbreviated).day().hour() : .dateTime.month(.abbreviated).day()
        let metric = report.chartMetric
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Activity", subtitle: chartSubtitle) {
                    PiTabs(selection: $report.chartMetric, items: [("Requests", "Requests"), ("Cost", "Cost"), ("Latency", "Latency"), ("Ratio", "Cache")])
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
                .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel(format: axisFormat).foregroundStyle(Color.piInkTertiary) } }
                .dashboardBrush(filter: snapshot.filter, preview: $report.brushPreview, committed: report.brush, commit: { report.applyBrush($0) })
                .frame(height: 160)
                if metric == "Latency" {
                    PiTabs(selection: $report.latencyMetric, items: [("TTFT", "First token"), ("Streaming", "Streaming"), ("HTTP", "Whole request")]).transition(.opacity)
                }
            }
        }
        .animation(motion, value: report.chartMetric)
    }
    private var chartSubtitle: String {
        switch report.chartMetric {
        case "Cost": return "Reported USD per bucket · drag to select a range"
        case "Latency": return "p50 and p99 per bucket, milliseconds · drag to select a range"
        case "Ratio": return "Cache hit ratio per bucket, % of reported · drag to select a range"
        default: return "Requests per bucket · drag to select a range"
        }
    }

    // MARK: Requests

    private func requests(_ snapshot: DashboardSnapshot, width: CGFloat) -> some View {
        let titles = Dictionary(model.chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
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
                Text(snapshot.requests.isEmpty ? "No rows" : "\(snapshot.offset + 1)–\(snapshot.offset + snapshot.requests.count) of \(snapshot.selectedRequests)")
            }
        }
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
                        report.preferences.requestedAlias = summary.alias
                        report.preferences.effectiveModel = summary.model
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
        let workspaces = Dictionary(model.workspaces.map { ($0.id, WorkspaceLabel.name($0)) } + [(WorkspaceRecord.scratchID, "No project")], uniquingKeysWith: { first, _ in first })
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

/// Column widths shared by the header and rows of the request grid.
private enum ReportColumns {
    static let started: CGFloat = 112
    static let session: CGFloat = 150
    static let status: CGFloat = 96
    static let cost: CGFloat = 128
    static let tokens: CGFloat = 150
    /// Extra leading inset for requests listed under their session.
    static let nestedIndent: CGFloat = 32
    static let duration: CGFloat = 78
    static let cache: CGFloat = 116
    static let widths: [CGFloat?] = [started, session, nil, status, cost, tokens, duration, cache]
    static let sessionWidths: [CGFloat?] = [started, nil, 112, cost, tokens, 96, 110, 132]
    static let modelRequests: CGFloat = 132
    static let modelRate: CGFloat = 116
    static let modelFirstToken: CGFloat = 176
    static let modelWidths: [CGFloat?] = [nil, modelRequests, cost, tokens, 96, modelRate, modelFirstToken]
}

/// Row cost without the currency suffix; the column header and help text carry the unit.
private func reportUSD(_ value: Double?) -> String {
    guard value != nil else { return "—" }
    return gatewayUSD(value).replacingOccurrences(of: " USD", with: "")
}

/// Short token counts for tiles and rows: 1.2k, 340k, 2.1M.
func reportTokens(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1000) }
    return String(format: "%.0f", value)
}

/// Reasoning is a reported subset of output and cost, never a second charge.
func reportReasoningDetail(_ totals: GatewayTotals) -> String {
    "Reasoning \(reportTokens(totals.tokens?.reasoning)) tokens (\(totals.tokens?.reasoningSamples ?? 0)/\(totals.requests) reported) are counted within output. Reasoning cost \(gatewayUSD(totals.reasoningCostUSD)) (\(totals.reasoningCostSamples ?? 0)/\(totals.requests) reported) is the gateway's reported share and is never added to the total; the two are summed over different requests."
}

private struct ReportGridRow: View {
    let cells: [String]
    var header = false
    var widths: [CGFloat?] = ReportColumns.widths
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let width = widths[index]
                Text(cell).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).lineLimit(1)
                    .frame(width: width, alignment: .leading).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
        }.padding(.horizontal, PiSpacing.md).padding(.vertical, 8).background(Color.piSurfaceSunken)
    }
}

private struct ReportRequestRow: View {
    let item: DashboardRequest
    let title: String?
    let detailed: Bool
    let inspect: () -> Void
    var message: () -> Void = {}
    var nested = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tone: PiTone { item.outcome == "completed" ? .success : item.outcome == "failed" ? .danger : item.outcome == "running" ? .warning : .neutral }
    private func tokens(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private var purpose: String { (item.api == "openai-responses" ? "Responses" : "Messages") + " · " + item.purpose }
    var body: some View {
        Button(action: inspect) {
            HStack(spacing: PiSpacing.sm) {
                Text(item.wall, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary).frame(width: ReportColumns.started, alignment: .leading)
                if nested {
                    // The parent session row already names the chat; keep the
                    // remaining columns aligned with the top-level request grid.
                    Text(purpose).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
                        .frame(width: ReportColumns.session - ReportColumns.nestedIndent, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        if let title, !title.isEmpty { Text(title).font(PiFont.caption).foregroundStyle(Color.piInk) }
                        else { Text(String(item.sessionID.prefix(8)) + "…").font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                        Text(purpose).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                    }
                    .lineLimit(1).truncationMode(.middle).frame(width: ReportColumns.session, alignment: .leading)
                    .help("Session " + item.sessionID + (title == nil ? " (no chat title known)" : ""))
                }
                ModelRouteCell(requested: item.alias, final: item.effectiveModel, reported: item.reportedModels, status: item.identityStatus).frame(maxWidth: .infinity, alignment: .leading)
                PiBadge(text: item.outcome, tone: tone, dot: true).frame(width: ReportColumns.status, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.gateway.costUSD == nil ? item.gateway.costStatus : reportUSD(item.gateway.costUSD)).foregroundStyle(Color.piInk)
                    if detailed { Text("reasoning " + reportUSD(item.gateway.reasoningCostUSD)).foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.cost, alignment: .leading)
                    .help("LiteLLM-reported USD cost (\(item.gateway.costStatus)); includes reasoning \(gatewayUSD(item.gateway.reasoningCostUSD)) (\(item.gateway.reasoningCostStatus)). Provider prompt-cache tokens read \(tokens(item.gateway.cacheReadTokens)), write \(tokens(item.gateway.cacheWriteTokens)).")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.gateway.inputTokens == nil && item.gateway.outputTokens == nil ? "—" : "↓\(reportTokens(item.gateway.inputTokens)) ↑\(reportTokens(item.gateway.outputTokens))").foregroundStyle(Color.piInk)
                    if item.gateway.reasoningTokens != nil { Text("\(reportTokens(item.gateway.reasoningTokens)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(item.gateway.cacheReadTokens)) · uncached \(reportTokens(item.gateway.uncachedInputTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help("Input \(tokens(item.gateway.inputTokens)) tokens (cached \(tokens(item.gateway.cacheReadTokens)), not cached \(tokens(item.gateway.uncachedInputTokens))) · output \(tokens(item.gateway.outputTokens)) tokens including \(tokens(item.gateway.reasoningTokens)) reasoning tokens, as reported by the gateway. Reasoning is not added again.")
                VStack(alignment: .leading, spacing: 1) {
                    Text(ms(item.http)).foregroundStyle(Color.piInk)
                    if detailed { Text("ttft \(ms(item.ttft))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.duration, alignment: .leading)
                    .help("Whole request \(ms(item.http)) · first token \(ms(item.ttft)) · streaming \(ms(item.streaming))")
                HStack(spacing: 4) {
                    DashboardCacheBadge(status: item.gateway.cacheStatus)
                    Spacer(minLength: 0)
                    PiIconButton(symbol: "text.bubble", label: "Go to the linked message", size: 22, action: message).opacity(hovering ? 1 : 0.35)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary).opacity(hovering ? 1 : 0)
                }.frame(width: ReportColumns.cache, alignment: .leading)
                    .help("LiteLLM response-cache state: " + item.gateway.cacheStatus + ". Separate from provider prompt-cache tokens.")
            }
            .padding(.leading, nested ? PiSpacing.md + ReportColumns.nestedIndent : PiSpacing.md).padding(.trailing, PiSpacing.md).padding(.vertical, 7)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityIdentifier("inspectRequest-" + item.id)
        .accessibilityLabel("Inspect request from " + item.wall.formatted())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// One requested route in the By model table, with its share of the window's
/// requests and cost, and its own output rate and first-token median.
private struct ReportModelRow: View {
    let summary: DashboardModelSummary
    let allRequests: Int
    let allCost: Double?
    let detailed: Bool
    let filter: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private var requestShare: Double { allRequests > 0 ? Double(summary.requests) / Double(allRequests) : 0 }
    private var costShare: Double? {
        guard let cost = summary.gateway.costUSD, let allCost, allCost > 0 else { return nil }
        return cost / allCost
    }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
    var body: some View {
        Button(action: filter) {
            HStack(alignment: .top, spacing: PiSpacing.sm) {
                ModelRouteCell(requested: summary.alias, final: summary.model, reported: [], status: summary.status).frame(maxWidth: .infinity, alignment: .leading)
                shareCell("\(summary.requests)", detail: percent(requestShare) + " of requests" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : ""), share: requestShare, tone: .piAccent)
                    .frame(width: ReportColumns.modelRequests, alignment: .leading)
                shareCell(summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD), detail: costShare.map { percent($0) + " of cost" } ?? (summary.gateway.costSamples < summary.requests ? "\(summary.gateway.costSamples)/\(summary.requests) reported" : "no cost reported"), share: costShare, tone: .piSuccess)
                    .frame(width: ReportColumns.cost, alignment: .leading)
                    .help(summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—").foregroundStyle(Color.piInk)
                    if summary.gateway.tokens?.reasoning != nil { Text("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(summary.gateway.cacheReadTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help(summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway))
                HStack(spacing: 5) {
                    if let ratio = summary.gateway.cacheHitRatio { PiRing(fraction: ratio, size: 10); Text(String(format: "%.0f%%", ratio * 100)) }
                    else { Text("—") }
                }.font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).frame(width: 96, alignment: .leading).help(summary.gateway.cacheLabel)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SessionUsagePresentation.rate(summary.rate.tokensPerSecond)).foregroundStyle(Color.piInk)
                    Text("\(summary.rate.samples)/\(summary.requests) measured").foregroundStyle(Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.modelRate, alignment: .leading)
                    .help("Output tokens divided by dispatch-to-completion time over this route's completed requests with reported usage.")
                VStack(alignment: .leading, spacing: 1) {
                    Text("p50 " + ms(summary.ttftP50)).foregroundStyle(Color.piInk)
                    Text(summary.ttftSamples > 0 ? "HTTP \(ms(summary.httpP50)) · \(summary.ttftSamples) measured" : "not measured").foregroundStyle(Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.modelFirstToken, alignment: .leading)
                    .help("Nearest-rank medians for this route: first token and whole request.")
            }
            .padding(.horizontal, PiSpacing.md).padding(.vertical, 8)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityLabel("Route \(summary.alias), \(summary.resolutionLabel), \(summary.requests) requests")
        .accessibilityIdentifier("reportModelRow-" + summary.alias)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
    private func shareCell(_ value: String, detail: String, share: Double?, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            UsageShareBar(fraction: share ?? 0, tone: tone).frame(height: 4)
            Text(detail).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        }
    }
}

/// Requested alias over the model the gateway actually served, so routing is
/// readable at a glance: the same model, a different route, or no report.
private struct ModelRouteCell: View {
    let requested: String
    let final: String?
    let reported: [String]
    let status: String
    private var routed: Bool { final != nil && final != requested }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("requested").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).frame(width: 58, alignment: .leading)
                Text(requested).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 5) {
                Text("final").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).frame(width: 58, alignment: .leading)
                if routed { Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piAccent) }
                if let final {
                    Text(final == requested ? "same model" : final).font(PiFont.caption).foregroundStyle(routed ? Color.piInk : Color.piInkSecondary).lineLimit(1).truncationMode(.middle)
                } else {
                    FinalModelLabel(final: nil, reported: reported, status: status)
                }
            }
        }
        .help(final.map { "Requested \(requested); the gateway served \($0)." } ?? "Requested \(requested); the gateway did not report one model that served it (\(status)).")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Requested \(requested)")
    }
}

/// The gateway's final model. Agreeing reports show one name; conflicting
/// reports show the shortest name by default and reveal every reported name
/// on click, since the longer ones are usually the same model with a
/// provider prefix or date suffix.
struct FinalModelLabel: View {
    let final: String?
    let reported: [String]
    let status: String
    var font: Font = PiFont.caption
    @State private var revealed = false
    private var conflict: Bool { final == nil && reported.count > 1 }
    private var text: String {
        if let final { return final }
        if let primary = dashboardPrimaryModel(reported) { return primary }
        switch status {
        case "conflict": return "conflicting reports"
        case "incomplete": return "partial report"
        default: return "—"
        }
    }
    /// A gateway that echoed no final model is routine, so the dash is quiet; only conflicts are warnings.
    private var routineUnreported: Bool { final == nil && !conflict && !["conflict", "incomplete"].contains(status) && reported.isEmpty }
    private var tone: Color {
        if routineUnreported { return Color.piInkTertiary }
        if final != nil || conflict { return Color.piInk }
        return status == "conflict" ? Color.piDanger : Color.piWarning
    }
    var body: some View {
        if conflict {
            Button { revealed.toggle() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(text).font(font).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                        Text(revealed ? "hide" : "+\(reported.count - 1)").font(PiFont.micro).foregroundStyle(Color.piWarning)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.piWarning.opacity(0.14), in: Capsule())
                    }
                    if revealed {
                        ForEach(reported.filter { $0 != text }, id: \.self) { name in
                            Text(name).font(font).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer()
            .animation(.easeInOut(duration: 0.16), value: revealed)
            .help("The gateway reported \(reported.count) model names for this request: \(reported.joined(separator: ", ")). Click to show or hide all of them.")
            .accessibilityLabel("Final model \(text), \(reported.count) reported names")
            .accessibilityHint("Shows every reported name")
            .accessibilityIdentifier("finalModelReveal")
        } else {
            Text(text).font(font).foregroundStyle(tone).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Final model \(text)")
        }
    }
}

/// Wrap filter controls and chips instead of allowing a narrow window to hide them.
private struct ReportFlow: Layout {
    var spacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [CGPoint] = [], sizes: [CGSize] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, 320), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: max(1, proposal.width ?? 1280)).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: max(1, bounds.width))
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                                  anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}

/// Keep long aliases/session names inspectable without stretching the whole page.
private struct ReportDropdown: View {
    @Binding var selection: String
    let items: [(String, String)]
    let icon: String
    private var current: String { items.first { $0.0 == selection }?.1 ?? selection }
    var body: some View {
        Menu {
            ForEach(items, id: \.0) { item in Button(item.1) { selection = item.0 } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                Text(current).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInk)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 230)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.piSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer().help(current)
    }
}


/// One session (chat) aggregate with an expander for its requests.
private struct ReportSessionRow: View {
    let summary: DashboardSessionSummary
    let title: String?
    let workspace: String?
    let available: Bool
    let expanded: Bool
    let detailed: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var connectionCheck: Bool { !available && summary.sessionID.hasPrefix("connection-test-") }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: PiSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary.last, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                }.frame(width: ReportColumns.started, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if connectionCheck { Text("Connection check").font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk) }
                        else if let title, !title.isEmpty { Text(title).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk) }
                        else { Text(String(summary.sessionID.prefix(8)) + "…").font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                        if !available && !connectionCheck { PiBadge(text: "chat unavailable", tone: .warning, icon: "exclamationmark.triangle") }
                    }
                    Text((workspace ?? "unknown project") + " · " + summary.sessionID).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .help(connectionCheck ? "Onboarding tested the selected model without creating a chat. Expand to inspect its request." : available ? "Session " + summary.sessionID : "This chat was deleted or was an unkept side conversation; its retained requests remain here.")
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(summary.requests)").foregroundStyle(Color.piInk)
                    Text("\(summary.completed) ok" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : "") + (summary.running > 0 ? " · \(summary.running) running" : "")).foregroundStyle(summary.problems > 0 ? Color.piWarning : Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD)).foregroundStyle(Color.piInk)
                    if detailed { Text("reasoning " + reportUSD(summary.gateway.reasoningCostUSD)).foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.cost, alignment: .leading)
                    .help(summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—").foregroundStyle(Color.piInk)
                    if summary.gateway.tokens?.reasoning != nil { Text("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(summary.gateway.cacheReadTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help(summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway))
                HStack(spacing: 5) {
                    if let ratio = summary.gateway.cacheHitRatio { PiRing(fraction: ratio, size: 10); Text(String(format: "%.0f%%", ratio * 100)) }
                    else { Text("—") }
                }.font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).frame(width: 96, alignment: .leading).help(summary.gateway.cacheLabel)
                Text("ttft \(ms(summary.ttftP50)) · \(ms(summary.httpP50))").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary).lineLimit(1).frame(width: 120, alignment: .leading)
                    .help("Nearest-rank medians for this session: first token and whole request")
                HStack(spacing: 4) {
                    if connectionCheck { Text("Setup check").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                    else { Button(action: open) { Label("Open chat", systemImage: "arrow.right.circle") }.buttonStyle(.piSecondaryCompact).disabled(!available) }
                }.frame(width: 132, alignment: .trailing)
            }
            .padding(.horizontal, PiSpacing.md).padding(.vertical, 7)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityLabel((connectionCheck ? "Connection check" : "Session " + (title ?? summary.sessionID)) + ", \(summary.requests) requests")
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expanded)
    }
}
