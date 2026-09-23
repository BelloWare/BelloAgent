import SwiftUI

/// The session at a glance: what it cost, what it used and how fast, the
/// charts behind those figures (a click on a bar opens its request), the
/// models that answered, every request, and how it was all counted.
struct InspectorOverviewPage: View {
    @ObservedObject var inspector: SessionInspectorModel
    @ObservedObject private var usage: SessionUsageController
    let compact: Bool
    @State private var methodology = false

    init(inspector: SessionInspectorModel, compact: Bool) {
        self.inspector = inspector; self.compact = compact; self.usage = inspector.usage
    }

    var body: some View {
        let _ = SessionStatsRenderCount.panelBuilt()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InspectorPageHeader("Overview", subtitle: subtitle) {
                    EmptyView()
                } actions: {
                    InspectorShowInChat { inspector.showInChat() }
                }
                figures
                if let display = inspector.display, let workspace = inspector.workspace { costLimit(display.footer, workspace) }
                charts
                if let snapshot = usage.snapshot { models(snapshot) }
                SessionRequestLedgerView(ledger: inspector.ledger, open: { inspector.select(.request($0)) }, limit: 40)
                    .accessibilityIdentifier("inspector-ledger")
                howCounted
            }
            .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.vertical, PiSpacing.lg)
            .frame(maxWidth: 1_100, alignment: .leading)
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
                            InspectorCostFigure(figure: figure, footer: footer)
                        } else {
                            PiFigure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial, large: true)
                                .accessibilityIdentifier("inspector-figure-" + figure.id)
                        }
                    }
                }
                Rectangle().fill(Color.piHairline).frame(height: 1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 110 : 130), spacing: PiSpacing.md, alignment: .topLeading)],
                          alignment: .leading, spacing: 12) {
                    ForEach(details) { figure in
                        PiFigure(value: figure.value, title: figure.title, caption: figure.caption, partial: figure.partial)
                            .accessibilityIdentifier("inspector-figure-" + figure.id)
                    }
                }
                if let coverage = inspector.tokenCharts.coverage {
                    Text(coverage).font(PiFont.micro).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("inspector-overview-figures")
    }

    /// The chat's spend against its cost limit ("$4.12 of $25.00"), and the
    /// chat's limit to change, which its next request is checked against.
    private func costLimit(_ footer: SessionMetrics, _ workspace: WorkspaceModel) -> some View {
        let id = inspector.scope.sessionID
        return PiCard(padding: PiSpacing.lg) {
            CostLimitLiveEditor(footer: footer, choose: { [weak workspace] limit in try await workspace?.setCostLimit(limit, for: id) })
        }
        .accessibilityIdentifier("inspector-cost-limit")
    }

    @ViewBuilder private var charts: some View {
        let time = inspector.timeCharts, tokens = inspector.tokenCharts
        let open: (String) -> Void = { [weak inspector] id in inspector?.select(.request(id)) }
        if time.historyLoaded {
            if let timeline = time.timeline {
                chartCard { SessionTimelineChart(timeline: timeline, selection: inspector.timelineSelection, open: open).equatable() }
            }
            let columns = [GridItem(.adaptive(minimum: compact ? 300 : 420), spacing: PiSpacing.md, alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: PiSpacing.md) {
                if let speed = time.speed { chartCard { SessionSpeedChart(speed: speed, selection: inspector.speedSelection, open: open).equatable() } }
                if let bars = tokens.perRequest { chartCard { SessionTokenBarsChart(bars: bars, selection: inspector.tokenSelection, open: open).equatable() } }
                if let cost = tokens.cost { chartCard { SessionCostChart(cost: cost, selection: inspector.costSelection, open: open).equatable() } }
                if let split = time.split { chartCard { SessionTimeSplitView(split: split).equatable() } }
                if let composition = tokens.composition { chartCard { SessionCompositionView(composition: composition).equatable() } }
            }
            if time.models.count > 1 || tokens.models.count > 1 {
                LazyVGrid(columns: columns, alignment: .leading, spacing: PiSpacing.md) {
                    if !time.models.isEmpty { chartCard { SessionModelTimeTable(rows: time.models).equatable() } }
                    if !tokens.models.isEmpty { chartCard { SessionModelTokenTable(rows: tokens.models).equatable() } }
                }
            }
        } else {
            PiCard(padding: PiSpacing.lg) { SessionStatsLoadingNote(loading: !inspector.indexLoaded, failure: inspector.failure) }
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
                        InspectorModelRow(item: item, compact: compact)
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
                    SessionStatsNotes(notes: inspector.timeCharts.notes + inspector.tokenCharts.notes)
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
private struct InspectorCostFigure: View {
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
private struct InspectorModelRow: View {
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
