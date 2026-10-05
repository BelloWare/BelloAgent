// Test-only geometry instrumentation of the frozen 59ef8e0d Overview.
// Original children, lazy containers, spacing and padding are preserved.
// Only transparent frame probes and ScrollViewReader targets are added.
import AppKit
import Combine
import SwiftUI
@testable import PiApp

/// The session at a glance: what it cost, what it used and how fast, the
/// charts behind those figures (a click on a bar opens its request), the
/// models that answered, every request, and how it was all counted.
struct InspectorOverviewGeometryReference: View {
    @ObservedObject var inspector: SessionInspectorModel
    @ObservedObject private var usage: SessionUsageController
    let compact: Bool
    @ObservedObject var geometry: InspectorOverviewReferenceGeometry
    @State private var methodology = false

    init(inspector: SessionInspectorModel, compact: Bool, geometry: InspectorOverviewReferenceGeometry) {
        self.inspector = inspector; self.compact = compact; self.usage = inspector.usage; self.geometry = geometry
    }

    var body: some View {
        let _ = SessionStatsRenderCount.panelBuilt()
        ScrollViewReader { reader in
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorPageHeaderReference("Overview", subtitle: subtitle) {
                    EmptyView()
                } actions: {
                    InspectorShowInChatReference { inspector.showInChat() }
                }
                .overviewMeasured("header", geometry)
                figures
                if let display = inspector.display, let workspace = inspector.workspace { costLimit(display.footer, workspace) }
                charts
                if let snapshot = usage.snapshot { models(snapshot) }
                OverviewGeometryLedgerReference(ledger: inspector.ledger, geometry: geometry, open: { inspector.select(.request($0)) }, limit: 40)
                    .accessibilityIdentifier("inspector-ledger")
                howCounted.overviewMeasured("how-counted", geometry)
            }
            .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.vertical, PiSpacing.lg)
            .frame(maxWidth: 1_100, alignment: .leading)
            .overviewMeasured("document", geometry)
            .coordinateSpace(name: InspectorOverviewReferenceGeometry.coordinateSpace)
          }
          .onChange(of: geometry.target) { _, target in
              if let target { reader.scrollTo(target, anchor: .top) }
          }
        }
        .accessibilityIdentifier("inspector-overview")
    }

    private var subtitle: String {
        let gateway = inspector.inputs.gateway.requests > 0 ? inspector.inputs.gateway : usage.snapshot?.gateway ?? GatewayTotals()
        var parts: [String] = []
        let turns = inspector.index.turns.filter { !$0.isOther }.count
        if gateway.requests > 0 || turns > 0 {
            parts.append("\(turns) turn" + (turns == 1 ? "" : "s") + " · \(gateway.requests) request" + (gateway.requests == 1 ? "" : "s"))
        }
        if let started = inspector.index.requests.first(where: { $0.wall > 0 })?.wall {
            parts.append("since " + Date(timeIntervalSince1970: started).formatted(date: .abbreviated, time: .shortened))
        }
        if let snapshot = usage.snapshot, snapshot.modelGroups > 1 { parts.append("\(snapshot.modelGroups) routes") }
        return parts.isEmpty ? "No requests yet" : parts.joined(separator: " · ")
    }

    /// The headline figures, then the quieter ones under them.
    private var figures: some View {
        let hero = inspector.tokenCharts.hero + inspector.timeCharts.hero.filter { $0.id == "speed" } + inspector.timeCharts.details.filter { $0.id == "ttft" }
        let details = inspector.timeCharts.hero.filter { $0.id != "speed" } + inspector.timeCharts.details.filter { $0.id != "ttft" }
        return PiCard(padding: PiSpacing.lg) {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 120 : 150), spacing: PiSpacing.md, alignment: .topLeading)],
                          alignment: .leading, spacing: 14) {
                    ForEach(hero) { figure in
                        if figure.id == "cost", let footer = inspector.display?.footer {
                            OverviewGeometryCostFigureReference(figure: figure, footer: footer).overviewMeasured("hero-" + figure.id, geometry)
                        } else {
                            PiFigure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial, large: true)
                                .accessibilityIdentifier("inspector-figure-" + figure.id)
                                .overviewMeasured("hero-" + figure.id, geometry)
                        }
                    }
                }
                Rectangle().fill(Color.piHairline).frame(height: 1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 110 : 130), spacing: PiSpacing.md, alignment: .topLeading)],
                          alignment: .leading, spacing: 12) {
                    ForEach(details) { figure in
                        PiFigure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial)
                            .accessibilityIdentifier("inspector-figure-" + figure.id)
                            .overviewMeasured("detail-" + figure.id, geometry)
                    }
                }
                if let coverage = inspector.tokenCharts.coverage {
                    Text(coverage).font(PiFont.micro).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("inspector-overview-figures")
        .overviewMeasured("figures", geometry)
    }

    /// The chat's spend against its cost limit ("$4.12 of $25.00"), and the
    /// chat's limit to change, which its next request is checked against.
    private func costLimit(_ footer: SessionMetrics, _ workspace: WorkspaceModel) -> some View {
        let id = inspector.scope.sessionID
        return PiCard(padding: PiSpacing.lg) {
            OverviewGeometryCostLimitEditorHostReference(footer: footer, choose: { [weak workspace] limit in try await workspace?.setCostLimit(limit, for: id) })
        }
        .accessibilityIdentifier("inspector-cost-limit")
        .overviewMeasured("cost-limit", geometry)
    }

    @ViewBuilder private var charts: some View {
        let time = inspector.timeCharts, tokens = inspector.tokenCharts
        let open: (String) -> Void = { [weak inspector] id in inspector?.select(.request(id)) }
        if time.historyLoaded {
            if let timeline = time.timeline {
                chartCard { SessionTimelineChartReference(timeline: timeline, selection: inspector.timelineSelection, open: open).equatable() }.overviewMeasured("timeline", geometry)
            }
            let columns = [GridItem(.adaptive(minimum: compact ? 300 : 420), spacing: PiSpacing.md, alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: PiSpacing.md) {
                if let speed = time.speed { chartCard { SessionSpeedChartReference(speed: speed, selection: inspector.speedSelection, open: open).equatable() }.overviewMeasured("chart-speed", geometry) }
                if let bars = tokens.perRequest { chartCard { SessionTokenBarsChartReference(bars: bars, selection: inspector.tokenSelection, open: open).equatable() }.overviewMeasured("chart-tokens", geometry) }
                if let cost = tokens.cost { chartCard { SessionCostChartReference(cost: cost, selection: inspector.costSelection, open: open).equatable() }.overviewMeasured("chart-cost", geometry) }
                if let split = time.split { chartCard { SessionTimeSplitViewReference(split: split).equatable() }.overviewMeasured("chart-time-split", geometry) }
                if let composition = tokens.composition { chartCard { SessionCompositionViewReference(composition: composition).equatable() }.overviewMeasured("chart-composition", geometry) }
            }.overviewMeasured("chart-grid", geometry)
            if time.models.count > 1 || tokens.models.count > 1 {
                LazyVGrid(columns: columns, alignment: .leading, spacing: PiSpacing.md) {
                    if !time.models.isEmpty { chartCard { SessionModelTimeTableReference(rows: time.models).equatable() }.overviewMeasured("model-time", geometry) }
                    if !tokens.models.isEmpty { chartCard { SessionModelTokenTableReference(rows: tokens.models).equatable() }.overviewMeasured("model-tokens", geometry) }
                }.overviewMeasured("model-grid", geometry)
            }
        } else {
            PiCard(padding: PiSpacing.lg) { SessionStatsLoadingNoteReference(loading: !inspector.indexLoaded, failure: inspector.failure) }
        }
    }

    private func chartCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        PiCard(padding: PiSpacing.md) { content() }
    }

    /// One row per requested route and served model, as Session info had it.
    private func models(_ snapshot: MenuBarSnapshot) -> some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Models", subtitle: snapshot.modelGroups > 1 ? "\(snapshot.modelGroups) routes · speed and first token per model" : "One route · its speed and first-token time")
                if snapshot.models.isEmpty {
                    Text("No retained requests for this session yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                } else {
                    ForEach(snapshot.models) { item in
                        Rectangle().fill(Color.piHairline).frame(height: 1)
                        OverviewGeometryModelRowReference(item: item, compact: compact)
                            .overviewMeasured(InspectorOverviewReferenceGeometry.modelID(item), geometry)
                    }
                }
                if snapshot.modelGroups > MenuBarSnapshot.pageSize {
                    PiPager(previous: usage.previousPage, next: usage.nextPage,
                            canPrevious: usage.offset > 0 && !usage.loading, canNext: snapshot.hasNext && !usage.loading) {
                        Text("\(snapshot.offset + 1)–\(snapshot.offset + snapshot.models.count) of \(snapshot.modelGroups)")
                    }
                }
            }
        }
        .help(snapshot.observationHelp)
        .accessibilityIdentifier("inspector-models")
        .overviewMeasured("models", geometry)
    }

    private var howCounted: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { methodology.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(methodology ? 90 : 0))
                    Text("How these figures are counted").font(PiFont.caption.weight(.medium))
                }.foregroundStyle(Color.piInkSecondary)
            }
            .buttonStyle(.plain).piPointer().accessibilityIdentifier("inspector-how-counted")
            if methodology {
                VStack(alignment: .leading, spacing: 6) {
                    SessionStatsNotesReference(notes: inspector.timeCharts.notes + inspector.tokenCharts.notes)
                    Text("Each dispatched request counts once, tool rounds included. Only this session's own requests count; inherited parent messages add no cost. Reasoning is part of output and of the total cost; cached input is part of input. A missing figure stays missing, never a zero.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                    Text(SettledThroughput.explanation).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 15)
            }
        }
    }
}

/// The session's cost against the chat's limit: the spend, "of $25.00 limit"
/// under it, in warning ink from 80% of the limit as the usage pill reads it,
/// and the requests that reported no cost. It follows the chat's footer, so a
/// request settling or a limit changed shows at once.
private struct OverviewGeometryCostFigureReference: View {
    let figure: SessionStatsFigure
    @ObservedObject var footer: SessionMetrics
    var body: some View {
        let reading = footer.cost
        let presentation = SessionStatsPresentation(gateway: footer.gateway, work: nil, cost: reading)
        var value = figure.value, caption: [String] = []
        if let cap = reading.limit.usd {
            // The spend the limit counts: the pill's figure, less its "of $…".
            if let spent = presentation.costFigure?.components(separatedBy: " of ").first { value = spent }
            caption.append("of " + CostLimit.dollars(cap) + " limit")
        } else if let own = figure.caption { caption.append(own) }
        if let unreported = reading.unreportedNote { caption.append(unreported) }
        return PiFigure(value: value, title: figure.title, caption: caption.joined(separator: " · "),
                        partial: figure.partial || presentation.costWarning || reading.unreportedNote != nil, large: true,
                        warning: presentation.costWarning)
            .accessibilityIdentifier("inspector-figure-cost")
    }
}

/// A route: what was asked for, what answered, its share, speed and first token.
private struct OverviewGeometryModelRowReference: View {
    let item: MenuBarModelDistribution
    let compact: Bool
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.requestedAlias.isEmpty ? "Alias unavailable" : item.requestedAlias).font(PiFont.caption.weight(.medium))
                    .foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).help(item.requestedAlias)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(PiFont.micro)
                    Text(item.resolutionLabel).font(PiFont.caption).lineLimit(1).truncationMode(.middle).help(item.resolutionLabel)
                }.foregroundStyle(item.resolvedModel == nil ? Color.piWarning : Color.piInkSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            share("\(item.gateway.requests) req", item.requestShare, .piAccent)
            share(compactGatewayUSD(item.gateway.costUSD), item.costShare ?? 0, .piSuccess)
            if !compact {
                figure(SessionUsagePresentation.rate(item.gateway.settledThroughput.tokensPerSecond) + " tok/s",
                       "\(item.gateway.settledThroughput.samples)/\(item.gateway.requests) measured")
                figure(SessionUsagePresentation.milliseconds(item.ttftP50), item.ttftSamples > 0 ? "first token, median" : "not measured")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
    private func share(_ value: String, _ fraction: Double, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            UsageShareBar(fraction: fraction, tone: tone).frame(height: 4)
        }.frame(width: 96, alignment: .leading)
    }
    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            Text(caption).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        }.frame(width: 118, alignment: .leading)
    }
}

// TEMPORARY (until the Inspector is AppKit): the AppKit limit editor in this SwiftUI page.
private struct OverviewGeometryCostLimitEditorHostReference: NSViewRepresentable {
    let footer: SessionMetrics
    let choose: @MainActor (CostLimit?) async throws -> Void
    func makeNSView(context: Context) -> CostLimitLiveEditor { CostLimitLiveEditor(footer: footer, choose: choose) }
    func updateNSView(_ view: CostLimitLiveEditor, context: Context) { view.footer = footer }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CostLimitLiveEditor, context: Context) -> CGSize? {
        let width = proposal.width ?? 348
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}


/// Every retained request of the session, oldest first, in the order it ran.
/// The figures that the pills fold into one number, one row at a time. In the
/// Inspector a row opens its request.
struct OverviewGeometryLedgerReference: View {
    let ledger: SessionRequestLedger
    let geometry: InspectorOverviewReferenceGeometry
    /// Opens a row's request; nil where rows are read only.
    var open: ((String) -> Void)? = nil
    /// Shows only the latest rows, and says how many there are.
    var limit: Int? = nil
    private var shown: ArraySlice<SessionRequestLedgerRow> { limit.map { ledger.rows.suffix($0) } ?? ledger.rows[...] }

    private static let columns: [(String, CGFloat?)] = [
        ("#", 30), ("Status", 88), ("Model", nil), ("Input", 122), ("Output", 108),
        ("TTFT", 64), ("Generation", 82), ("Throughput", 86), ("Cost", 92),
    ]

    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiSectionHeader("Requests", subtitle: shown.count < ledger.rows.count ? "Latest \(shown.count) of \(ledger.rows.count) · every request is in the list on the left" : ledger.subtitle) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ledger.copyText, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.piSecondaryCompact).accessibilityIdentifier("session-ledger-copy")
                }
                if ledger.rows.isEmpty {
                    Text("No requests with retained metrics yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    header
                    // Built as they scroll into view. The ledger sits under the
                    // charts, off screen as the Overview opens, and building its
                    // forty rows was most of what opening the page cost.
                    LazyVStack(alignment: .leading, spacing: PiSpacing.sm) {
                        ForEach(shown) { row in
                            Rectangle().fill(Color.piHairline).frame(height: 1)
                            if let open {
                                Button { open(row.id) } label: { line(row).contentShape(Rectangle()) }
                                    .buttonStyle(OverviewGeometryLedgerRowStyleReference()).help("Open request \(row.number)")
                                    .overviewMeasured("ledger-row-" + row.id, geometry)
                            } else { line(row).overviewMeasured("ledger-row-" + row.id, geometry) }
                        }
                    }
                }
                Text(ledger.coverageNote).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("session-ledger-coverage")
            }
        }.accessibilityIdentifier("session-request-ledger")
            .overviewMeasured("ledger", geometry)
    }

    private var header: some View {
        HStack(spacing: PiSpacing.sm) {
            ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                Text(column.0).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).lineLimit(1)
                    .frame(width: column.1, alignment: .leading).frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }

    private func line(_ row: SessionRequestLedgerRow) -> some View {
        SessionStatsRenderCount.ledgerRowBuilt()
        return HStack(alignment: .top, spacing: PiSpacing.sm) {
            Text("\(row.number)").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.status).font(PiFont.caption).foregroundStyle(row.status == "completed" ? Color.piInk : Color.piWarning).lineLimit(1)
                Text(row.wall.formatted(date: .omitted, time: .standard)).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary)
            }.frame(width: 88, alignment: .leading)
            Text(row.model).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).help(row.model)
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(row.input, row.inputDetail, width: 122)
            cell(row.output, row.outputDetail, width: 108)
            cell(row.ttft, nil, width: 64)
            cell(row.generation, nil, width: 82)
            cell(row.throughput, row.unmeasured ? "not measured" : nil, width: 86)
            cell(row.cost, nil, width: 92)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.line)
    }

    private func cell(_ value: String, _ detail: String?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            if let detail { Text(detail).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary).lineLimit(2) }
        }.frame(width: width, alignment: .leading)
    }
}

/// A ledger row that opens its request: a soft fill under the pointer.
private struct OverviewGeometryLedgerRowStyleReference: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? Color.piFill : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .piPointer()
    }
}


@MainActor final class InspectorOverviewReferenceGeometry: ObservableObject {
    static let coordinateSpace = "inspector-overview-complete-document"
    @Published var target: String?
    var frames: [String: CGRect] = [:]
    static func modelID(_ item: MenuBarModelDistribution) -> String {
        "model-row-" + item.api + "|" + item.requestedAlias + "|" + (item.resolvedModel ?? "") + "|" + item.identityStatus
    }
}

@MainActor private struct OverviewGeometryFrameProbe: View {
    let id: String
    let geometry: InspectorOverviewReferenceGeometry
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(InspectorOverviewReferenceGeometry.coordinateSpace))
            Color.clear.onAppear { geometry.frames[id] = frame }
                .onChange(of: frame) { _, value in geometry.frames[id] = value }
        }
    }
}

private extension View {
    @MainActor func overviewMeasured(_ id: String, _ geometry: InspectorOverviewReferenceGeometry) -> some View {
        background(OverviewGeometryFrameProbe(id: id, geometry: geometry)).id(id)
    }
}
