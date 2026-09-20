import SwiftUI
import Charts
import AppKit
import Combine

enum MenuBarTab: String, CaseIterable { case live = "Live", usage = "Usage" }
enum LiveChartMode: String, CaseIterable { case activity = "Activity", tps = "TPS" }
enum LiveChartWindow: Int, CaseIterable { case minute = 60, fiveMinutes = 300
    var title: String { self == .minute ? "60s" : "5m" }
}
private struct MenuBarHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 720 }
extension EnvironmentValues {
    var menuBarHeight: CGFloat { get { self[MenuBarHeightKey.self] } set { self[MenuBarHeightKey.self] = newValue } }
}
@MainActor final class MenuBarPanelLayout: ObservableObject {
    @Published var height: CGFloat = 720
    static func height(available: CGFloat) -> CGFloat { max(1, min(720, available - 24)) }
}
@MainActor struct MenuBarPanelFrame<Content: View>: View {
    @ObservedObject var layout: MenuBarPanelLayout
    let content: Content
    var body: some View { content.environment(\.menuBarHeight, layout.height).frame(width: 428, height: layout.height) }
}

@MainActor struct MenuBarMetricsView: View {
    @StateObject private var controller: MenuBarMetricsController
    private let live: LiveActivityStore
    @State private var tab: MenuBarTab
    @State private var liveScroll: String?
    @State private var usageScroll: String?
    @Environment(\.menuBarHeight) private var height
    private let openApp: () -> Void, openReport: () -> Void, quit: () -> Void
    private let openSession: (String) -> Void
    init(load: @escaping MenuBarMetricsLoader, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, live: LiveActivityStore? = nil, initialTab: MenuBarTab = .live, openApp: @escaping () -> Void, openReport: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in }, quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        _controller = StateObject(wrappedValue: MenuBarMetricsController(load: load, activeSessions: activeSessions, activity: activity, activityChanges: activityChanges))
        self.live = live ?? LiveActivityStore(); _tab = State(initialValue: initialTab)
        self.openApp = openApp; self.openReport = openReport; self.openSession = openSession; self.quit = quit
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PiSpacing.sm) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                LivePopupHeader(live: live)
                Spacer(minLength: 4)
                PiIconButton(symbol: "arrow.clockwise", label: "Refresh retained usage", size: 28) { controller.refresh() }
            }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.md).padding(.bottom, PiSpacing.sm)
            PiTabs(selection: $tab, items: MenuBarTab.allCases.map { ($0, $0.rawValue) }).padding(.horizontal, PiSpacing.lg).padding(.bottom, PiSpacing.md)
            Divider()
            ZStack {
                // Stable tab owners preserve disclosures, chart selection and
                // scroll anchors. Hidden panes are removed from hit testing and
                // accessibility; only the Live pane observes 1 Hz publications.
                ScrollView {
                    LivePopupContent(live: live, controller: controller, openSession: openSession, openApp: openApp)
                        .padding(PiSpacing.lg)
                }.scrollPosition(id: $liveScroll).opacity(tab == .live ? 1 : 0).allowsHitTesting(tab == .live).accessibilityHidden(tab != .live)
                ScrollView { MenuBarUsageView(controller: controller).padding(PiSpacing.lg) }
                    .scrollPosition(id: $usageScroll).opacity(tab == .usage ? 1 : 0).allowsHitTesting(tab == .usage).accessibilityHidden(tab != .usage)
            }.frame(maxHeight: .infinity).clipped()
            Divider()
            HStack(spacing: PiSpacing.sm) {
                Button("Open Bello Agent", action: openApp).buttonStyle(.piPrimaryCompact)
                Button("Report", action: openReport).buttonStyle(.piSecondaryCompact)
                Spacer(minLength: 0)
                Button("Quit", action: quit).buttonStyle(.piGhost).accessibilityLabel("Quit Bello Agent").accessibilityIdentifier("menu-bar-quit")
            }.padding(PiSpacing.md)
        }.frame(width: 428, height: height).background(Color.piContent).tint(Color.piAccent)
            .piAnimation(PiMotion.quick, value: tab)
            .background(WindowVisibilityReader { visible in controller.setVisible(visible); live.setVisible(visible) })
            .onDisappear { controller.setVisible(false); live.setVisible(false) }
            .accessibilityIdentifier("menu-bar-metrics")
    }
}

@MainActor private struct LivePopupHeader: View {
    @ObservedObject var live: LiveActivityStore
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Bello Agent").font(PiFont.title(17)).foregroundStyle(Color.piInk)
                Spacer(minLength: 4)
                Text(live.snapshot.freshnessLabel).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).minimumScaleFactor(0.8)
                    .help("Local observations, not a gateway health check. Quiet tools and first-content waits can be normal.")
            }
            let c = live.snapshot.counts
            Text("\(c.total) working · \(c.model) in model · \(c.tools) in tools\(c.other > 0 ? " · \(c.other) other" : "")")
                .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit().accessibilityIdentifier("menu-bar-running-count")
        }.piStableLayout()
    }
}

@MainActor private struct LivePopupContent: View {
    @ObservedObject var live: LiveActivityStore
    @ObservedObject var controller: MenuBarMetricsController
    let openSession: (String) -> Void, openApp: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.lg) {
            overview.id("overview")
            LivePopupChart(snapshot: live.snapshot).id("trend")
            LivePopupRows(activity: controller.activity, snapshot: live.snapshot, openSession: openSession, openApp: openApp).id("sessions")
        }.scrollTargetLayout().piStableLayout().accessibilityIdentifier("menu-bar-activity")
    }
    private var overview: some View {
        let s = live.snapshot, input = s.total(\.input), output = s.total(\.output), cost = s.total(\.cost)
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                HStack {
                    Text("\(s.activeRequests) active requests").font(PiFont.heading)
                    Spacer()
                    Text("\(controller.activity.attentionRows.count) need attention").font(PiFont.caption).foregroundStyle(controller.activity.attentionRows.isEmpty ? Color.piInkSecondary : Color.piWarning)
                }
                HStack(alignment: .top) {
                    figure("Request input", value: menuBarTokens(input.value), coverage: input.samples, total: s.activeRequests)
                    Spacer(minLength: 8)
                    figure("Request output", value: menuBarTokens(output.value), coverage: output.samples, total: s.activeRequests)
                }
                Text("Active reported cost: \(gatewayUSD(cost.value)) · \(cost.samples)/\(s.activeRequests) reported")
                    .font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                Text("\(s.utilityRequests) utility requests (titles, compaction or connection tests). Active totals are separate from retained Usage.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                if s.gaps > 0 {
                    Text("\(s.gaps) observation gaps since launch. Report retains the durable request history.").font(PiFont.micro).foregroundStyle(Color.piWarning)
                }
            }
        }
    }
    private func figure(_ title: String, value: String, coverage: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            Text(value == "Unavailable" ? "Awaiting usage" : value).font(PiFont.heading).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text("\(coverage)/\(total) reported").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LivePhasePoint: Identifiable {
    let bucket: LiveActivityBucket, category: Int, segment: Int
    var id: String { "\(bucket.id):\(category)" }
    var label: String { ["Model", "Tools", "Other"][category] }
    var value: Int { [bucket.peak.model, bucket.peak.tools, bucket.peak.other][category] }
}
@MainActor struct LivePopupChart: View {
    let snapshot: LivePopupSnapshot
    @State private var window = LiveChartWindow.minute
    @State private var mode = LiveChartMode.activity
    @State private var selectedTime: Date?
    private var buckets: [LiveActivityBucket] { Array(snapshot.buckets.suffix(window.rawValue)) }
    private var selected: LiveActivityBucket? {
        guard let selectedTime else { return nil }
        guard let first = buckets.first, let last = buckets.last,
              selectedTime >= first.wall.addingTimeInterval(-0.5), selectedTime <= last.wall.addingTimeInterval(0.5) else { return nil }
        return buckets.min { abs($0.wall.timeIntervalSince(selectedTime)) < abs($1.wall.timeIntervalSince(selectedTime)) }
    }
    private var points: [LivePhasePoint] {
        var segment = 0
        return buckets.flatMap { bucket -> [LivePhasePoint] in
            if bucket.gap { segment += 1; return [] }
            return (0..<3).map { LivePhasePoint(bucket: bucket, category: $0, segment: segment) }
        }
    }
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                HStack {
                    Text("Observed work").font(PiFont.heading)
                    Spacer()
                    PiTabs(selection: $window, items: LiveChartWindow.allCases.map { ($0, $0.title) }).frame(width: 112)
                }
                PiTabs(selection: $mode, items: LiveChartMode.allCases.map { ($0, $0.rawValue) })
                chart.frame(height: 125).accessibilityIdentifier("menu-bar-live-chart")
                    .chartXSelection(value: $selectedTime)
                    .chartXAxis { AxisMarks(values: [domain.lowerBound.addingTimeInterval(Double(window.rawValue) / 6), domain.lowerBound.addingTimeInterval(Double(window.rawValue) / 2), domain.upperBound.addingTimeInterval(-Double(window.rawValue) / 6)]) { AxisValueLabel(format: .dateTime.hour().minute().second()).foregroundStyle(Color.piInkTertiary) } }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(Color.piHairline); AxisValueLabel().foregroundStyle(Color.piInkTertiary) } }
                    .chartXScale(domain: domain)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle().fill(Color.clear).contentShape(Rectangle()).onContinuousHover { phase in
                                if case .active(let point) = phase, let anchor = proxy.plotFrame {
                                    let frame = geometry[anchor]
                                    if frame.contains(point) { selectedTime = proxy.value(atX: point.x - frame.minX, as: Date.self) }
                                }
                            }
                        }
                    }
                    .focusable().onMoveCommand { direction in move(direction == .left ? -1 : direction == .right ? 1 : 0) }
                    .accessibilityLabel(mode == .activity ? "Observed session activity" : "Reported request speed")
                    .accessibilityValue(summary)
                HStack(spacing: 8) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous chart sample")
                    Text(selected?.wall.formatted(date: .omitted, time: .standard) ?? "Latest observations").font(PiFont.micro).monospacedDigit()
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next chart sample")
                    Spacer()
                    if selectedTime != nil { Button("Latest") { selectedTime = nil }.font(PiFont.micro) }
                }.buttonStyle(.plain)
                Text(summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 64, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
                Text(mode == .activity ? "Peak observed sessions per phase in each second. Gaps mean unobserved work; phase peaks are not added together." : "Dots: completed-request averages. Diamonds: peak observed interim interval for a single request. No global live TPS is inferred.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                if let selected, mode == .tps {
                    DisclosureGroup("Request details · \(selected.completions) completions") {
                        ForEach(Array(snapshot.completions.filter { $0.bucket == selected.id }.suffix(8))) { item in
                            Text("\(item.request.alias) → \(item.request.model ?? item.request.identityStatus)\n\(menuBarTokens(item.request.output)) output · \(menuBarRate(item.request.duration)) s · TTFT \(menuBarRate(item.request.ttft)) ms · \(item.request.purpose)")
                                .font(PiFont.micro).textSelection(.enabled)
                        }
                        Text("Latest eight retained details; numerical buckets include all observed completions. Open Report for full history.").font(PiFont.micro)
                    }.font(PiFont.caption)
                }
            }
        }
    }
    private var domain: ClosedRange<Date> {
        let end = snapshot.buckets.last?.wall ?? snapshot.observedAt
        return end.addingTimeInterval(-Double(window.rawValue))...end.addingTimeInterval(1)
    }
    private var summary: String {
        if selectedTime != nil, selected == nil { return "Selected observation is outside this window. Choose Latest to follow current observations." }
        guard let b = selected ?? buckets.last else { return "No observations yet. Activity is available without usage counters." }
        if b.gap { return "Observation gap. This interval must not be read as idle or zero output." }
        if mode == .activity { return "Peak: \(b.peak.model) model · \(b.peak.tools) tools · \(b.peak.other) other sessions. Last: \(b.last.total) working." }
        if b.rateSamples == 0, b.interimSamples == 0 { return "Awaiting reported usage. Routes with only terminal usage add a completed-request point when they finish." }
        return "\(b.completions) completions · \(b.rateSamples) timed with final reported output. Average \(menuBarRate(b.averageRate)) tok/s · range \(menuBarRate(b.minimumRate))–\(menuBarRate(b.maximumRate)). \(b.interimSamples) interim intervals."
    }
    private func move(_ delta: Int) {
        guard delta != 0, !buckets.isEmpty else { return }
        let index = selected.flatMap { b in buckets.firstIndex { $0.id == b.id } } ?? buckets.count - 1
        selectedTime = buckets[max(0, min(buckets.count - 1, index + delta))].wall
    }
    private var chart: some View {
        Chart {
            if mode == .activity {
                ForEach(points) { point in
                    LineMark(x: .value("Time", point.bucket.wall), y: .value("Sessions", point.value), series: .value("Segment", "\(point.category):\(point.segment)"))
                        .foregroundStyle(by: .value("Phase", point.label)).interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: point.category == 2 ? [3, 2] : []))
                    if point.bucket.id == buckets.last?.id {
                        PointMark(x: .value("Time", point.bucket.wall), y: .value("Sessions", point.value))
                            .foregroundStyle(by: .value("Phase", point.label)).symbolSize(22)
                    }
                }
            } else {
                ForEach(buckets) { b in
                    if let rate = b.averageRate {
                        PointMark(x: .value("Completion", b.wall), y: .value("tok/s", rate)).foregroundStyle(Color.piAccent).symbol(.circle).symbolSize(26)
                        if let low = b.minimumRate, let high = b.maximumRate { RuleMark(x: .value("Completion", b.wall), yStart: .value("Minimum", low), yEnd: .value("Maximum", high)).foregroundStyle(Color.piAccent.opacity(0.5)) }
                    }
                    if let rate = b.intervalPeak, !b.gap {
                        PointMark(x: .value("Observation", b.wall), y: .value("tok/s", rate)).foregroundStyle(Color.piInkSecondary).symbol(.diamond).symbolSize(22)
                    }
                }
            }
            if let selected { RuleMark(x: .value("Selected", selected.wall)).foregroundStyle(Color.piInkTertiary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])) }
        }.chartForegroundStyleScale(["Model": Color.piAccent, "Tools": Color.piInkSecondary, "Other": Color.piWarning])
    }
}

enum LivePopupSection: CaseIterable { case working, attention, unread }
struct LivePopupRowOrder {
    private(set) var rows: [MenuBarActivityRow] = []
    private(set) var sections: [String: LivePopupSection] = [:]
    mutating func reconcile(_ snapshot: MenuBarActivitySnapshot, held: Set<String>) {
        let candidates = Array(snapshot.runningRows.prefix(12)) + Array(snapshot.attentionRows.prefix(12)) + Array(snapshot.unreadRows.prefix(12))
        let fresh = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        var next: [MenuBarActivityRow] = []
        var locations: [String: LivePopupSection] = [:]
        for old in rows {
            if let row = fresh[old.id] {
                next.append(row); locations[row.id] = held.contains(row.id) ? sections[row.id] : Self.section(row)
            } else if held.contains(old.id) {
                var row = MenuBarActivityRow(id: old.id, title: old.title, workspace: old.workspace, phase: "idle", model: old.model, resolvedModel: old.resolvedModel, tools: [], followUps: 0, steering: 0, unread: 0)
                row.actionable = false
                next.append(row); locations[row.id] = sections[row.id]
            }
        }
        for row in candidates where locations[row.id] == nil { next.append(row); locations[row.id] = Self.section(row) }
        rows = []; sections = [:]
        for section in LivePopupSection.allCases {
            let group = next.filter { locations[$0.id] == section }
            // Keep interacted rows even when new attention arrives; overflow
            // never changes execution admission or hides the navigation action.
            let remaining = max(0, 12 - group.filter { held.contains($0.id) }.count)
            let retained = Set(group.filter { !held.contains($0.id) }.prefix(remaining).map(\.id)).union(held)
            for row in group where retained.contains(row.id) {
                rows.append(row); sections[row.id] = section
            }
        }
    }
    func rows(in section: LivePopupSection) -> [MenuBarActivityRow] { rows.filter { sections[$0.id] == section } }
    private static func section(_ row: MenuBarActivityRow) -> LivePopupSection { row.running ? .working : row.needsAttention ? .attention : .unread }
}

@MainActor private struct LivePopupRows: View {
    let activity: MenuBarActivitySnapshot, snapshot: LivePopupSnapshot
    let openSession: (String) -> Void, openApp: () -> Void
    @State private var order = LivePopupRowOrder()
    @State private var held: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            if !activity.attentionRows.isEmpty || !order.rows(in: .attention).isEmpty { section("Needs attention", rows: order.rows(in: .attention), count: activity.attentionRows.count) }
            section("Working", rows: order.rows(in: .working), count: activity.running)
            if !activity.unreadRows.isEmpty || !order.rows(in: .unread).isEmpty {
                DisclosureGroup("Unread replies · \(activity.unreadRows.count) sessions") { section("Unread", rows: order.rows(in: .unread), count: activity.unreadRows.count) }.font(PiFont.caption)
            }
        }.onAppear { reconcile() }.onChange(of: activity) { _, _ in reconcile() }.onChange(of: held) { _, _ in reconcile() }
    }
    private func reconcile() {
        order.reconcile(activity, held: held)
    }
    private func section(_ title: String, rows: [MenuBarActivityRow], count: Int) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiSectionHeader("\(title) · \(count)")
            ForEach(Array(rows.prefix(12))) { row in
                LivePopupSessionRow(row: row, requests: snapshot.requests.filter { $0.id.session.session == row.id }, observedAt: snapshot.observedAt, open: { openSession(row.id) }, hold: { value in if value { held.insert(row.id) } else { held.remove(row.id) } })
            }
            if count == 0 { Text("All quiet. No sessions are working.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
            if count > 12 { Button("Open all \(count) sessions", action: openApp).buttonStyle(.piGhost) }
        }
    }
}
@MainActor private struct LivePopupSessionRow: View {
    let row: MenuBarActivityRow, requests: [LiveRequestState], observedAt: Date
    let open: () -> Void, hold: (Bool) -> Void
    @State private var expanded = false
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).font(PiFont.body.weight(.medium)).foregroundStyle(Color.piInk).lineLimit(1)
                        Text(row.phaseLabel + (row.utility ? " · Utility" : "") + (row.elapsed(at: observedAt).map { " · " + TranscriptActivity.formatDuration($0) } ?? ""))
                            .font(PiFont.micro).foregroundStyle(row.needsAttention ? Color.piWarning : Color.piInkSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!row.actionable).focused($focused).accessibilityLabel("Open \(row.title), \(row.phaseLabel)").accessibilityIdentifier("menu-bar-running-session-\(row.id)")
                PiIconButton(symbol: expanded ? "chevron.up" : "chevron.down", label: "Request details for \(row.title)", size: 24) { expanded.toggle() }.focused($focused)
            }
            Text(route).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle).help(route)
            if row.needsAttention, let error = row.errorDetail {
                Text(error).font(PiFont.micro).foregroundStyle(Color.piDanger).lineLimit(2).help(error)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.workspace)
                    ForEach(requests) { request in
                        Text("\(request.purpose): input \(menuBarTokens(request.input)) · output \(menuBarTokens(request.output))\n\(request.intervalRate.map { "Observed interval " + menuBarRate($0) + " tok/s" } ?? "Awaiting usable live counter")\nCached input \(menuBarTokens(request.cached)) · reasoning \(menuBarTokens(request.reasoning)) (subsets)\nCost \(gatewayUSD(request.cost)) · \(request.costStatus)\(request.correction ? "\nOutput counter corrected; interval rebased." : "")")
                    }
                    Text("Last request: \(menuBarRate(row.latestRate)) tok/s · TTFT \(menuBarRate(row.ttft)) ms").help(SessionRatePresentation.explanation)
                    Text("Session: \(menuBarTokens(row.tokens)) tokens · \(gatewayUSD(row.costUSD))")
                    if row.followUps + row.steering > 0 { Text("\(row.followUps + row.steering) queued inputs") }
                }.font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textSelection(.enabled).transition(.opacity)
            }
        }.padding(PiSpacing.sm).piInset().piAnimation(PiMotion.quick, value: expanded)
            .onHover { hovered = $0; updateHold() }.onChange(of: expanded) { _, _ in updateHold() }.onChange(of: focused) { _, _ in updateHold() }
            .onDisappear { hold(false) }
    }
    private var route: String {
        if let request = requests.first { return request.alias + " → " + (request.model ?? (request.identityStatus == "unreported" ? "awaiting reported route" : request.identityStatus)) }
        return row.model + (row.resolvedModel.map { " · Last route: " + $0 } ?? "")
    }
    private func updateHold() { hold(hovered || expanded || focused) }
}
