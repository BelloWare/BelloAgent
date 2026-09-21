import SwiftUI
import AppKit
import Combine

enum MenuBarTab: String, CaseIterable { case live = "Live", usage = "Usage" }
private struct MenuBarHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 720 }
extension EnvironmentValues {
    var menuBarHeight: CGFloat { get { self[MenuBarHeightKey.self] } set { self[MenuBarHeightKey.self] = newValue } }
}
@MainActor final class MenuBarPanelLayout: ObservableObject {
    static let width: CGFloat = 480
    @Published var height: CGFloat = 720
    static func height(available: CGFloat) -> CGFloat { max(1, min(720, available - 24)) }
}
@MainActor struct MenuBarPanelFrame<Content: View>: View {
    @ObservedObject var layout: MenuBarPanelLayout
    let content: Content
    var body: some View { content.environment(\.menuBarHeight, layout.height).frame(width: MenuBarPanelLayout.width, height: layout.height) }
}

@MainActor struct MenuBarMetricsView: View {
    @StateObject private var controller: MenuBarMetricsController
    @StateObject private var monitor: MenuBarMetricsController
    private let live: LiveActivityStore
    private let readProjects: () -> [MonitorProject]
    @State private var projects: [MonitorProject] = []
    @State private var tab: MenuBarTab
    @State private var visible = false
    @State private var liveScroll: String?
    @State private var usageScroll: String?
    @Environment(\.menuBarHeight) private var height
    private let openApp: () -> Void, openReport: () -> Void, quit: () -> Void
    private let openSession: (String) -> Void
    init(load: @escaping MenuBarMetricsLoader, scopedLoad: MenuBarScopedMetricsLoader? = nil, projects: @escaping () -> [MonitorProject] = { [] }, activeSessions: @escaping @MainActor () -> Int = { 0 }, activity: (@MainActor () -> MenuBarActivitySnapshot)? = nil, activityChanges: (@MainActor () -> AnyPublisher<Void, Never>)? = nil, live: LiveActivityStore? = nil, monitorController: MenuBarMetricsController? = nil, usageController: MenuBarMetricsController? = nil, initialTab: MenuBarTab = .live, openApp: @escaping () -> Void, openReport: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in }, quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        _controller = StateObject(wrappedValue: usageController ?? MenuBarMetricsController(load: load))
        _monitor = StateObject(wrappedValue: monitorController ?? MenuBarMetricsController(load: load, scopedLoad: scopedLoad, period: .fifteenMinutes, activeSessions: activeSessions, activity: activity, activityChanges: activityChanges))
        self.live = live ?? LiveActivityStore(); _tab = State(initialValue: initialTab); self.readProjects = projects
        self.openApp = openApp; self.openReport = openReport; self.openSession = openSession; self.quit = quit
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                Text("Bello Agent").font(PiFont.title(18)).foregroundStyle(Color.piInk)
                if tab == .live { MonitorFreshness(live: live) }
                else { Text("Usage").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                Spacer(minLength: 4)
                Menu {
                    Button(tab == .live ? "Detailed usage" : "Live monitor") { tab = tab == .live ? .usage : .live }
                    Button("Refresh usage") { if tab == .live { monitor.refresh() } else { controller.refresh() } }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Quit Bello Agent", action: quit)
                } label: { Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(Color.piInkSecondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).accessibilityLabel("Monitor options")
            }.padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            ZStack {
                ScrollView {
                    LiveMonitorView(live: live, controller: monitor, projects: projects, openSession: openSession, openApp: openApp).padding(18)
                }.scrollPosition(id: $liveScroll).opacity(tab == .live ? 1 : 0).allowsHitTesting(tab == .live).accessibilityHidden(tab != .live)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button("Back to live monitor") { tab = .live }.buttonStyle(.piGhost)
                        MenuBarUsageView(controller: controller)
                    }.padding(18)
                }.scrollPosition(id: $usageScroll).opacity(tab == .usage ? 1 : 0).allowsHitTesting(tab == .usage).accessibilityHidden(tab != .usage)
            }.frame(maxHeight: .infinity).clipped()
            Divider()
            HStack(spacing: 12) {
                Button(action: openApp) { Label("Open app", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }.buttonStyle(.piSecondaryCompact)
                Button(action: openReport) { Label("Usage report", systemImage: "chart.bar").frame(maxWidth: .infinity) }.buttonStyle(.piSecondaryCompact)
            }.padding(14)
        }.frame(width: MenuBarPanelLayout.width, height: height).background(Color.monitorCanvas).tint(Color.piAccent)
            .piAnimation(PiMotion.quick, value: tab)
            .background(WindowVisibilityReader { value in visible = value; updateVisibility(); if value { projects = readProjects() } })
            .onChange(of: tab) { _, _ in updateVisibility() }
            .onDisappear { visible = false; updateVisibility() }
            .accessibilityIdentifier("menu-bar-metrics")
    }
    private func updateVisibility() {
        controller.setVisible(visible && tab == .usage)
        monitor.setVisible(visible && tab == .live)
        live.setVisible(visible && tab == .live)
    }
}

@MainActor private struct MonitorFreshness: View {
    @ObservedObject var live: LiveActivityStore
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(live.snapshot.disconnected ? Color.piWarning : live.snapshot.counts.total > 0 ? Color.piSuccess : Color.piInkSecondary).frame(width: 7, height: 7)
            Text(live.snapshot.disconnected ? "Disconnected" : live.snapshot.counts.total > 0 ? "Live" : "Idle").font(PiFont.caption)
                .foregroundStyle(live.snapshot.counts.total > 0 ? Color.piSuccess : Color.piInkSecondary)
        }.help(live.snapshot.freshnessLabel + ". Local observations, not a gateway health check.")
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
