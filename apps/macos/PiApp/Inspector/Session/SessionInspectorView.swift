import SwiftUI

/// The Session Inspector: a navigator of the session's turns and requests on
/// the left, the page it has open on the right.
struct SessionInspectorView: View {
    @ObservedObject var inspector: SessionInspectorModel
    /// Narrower than this, the navigator narrows and the pages stack.
    static let compactWidth: CGFloat = 900

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Self.compactWidth
            VStack(spacing: 0) {
                InspectorTitleBar(inspector: inspector)
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(spacing: 0) {
                    InspectorNavigator(inspector: inspector, compact: compact)
                        .frame(width: compact ? 214 : 262)
                        .background(Color.piWindow)
                    Rectangle().fill(Color.piHairline).frame(width: 1)
                    InspectorPageView(inspector: inspector, compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.piContent)
                }
            }
        }
        .frame(minWidth: SessionInspectorWindowController.minimumSize.width, minHeight: SessionInspectorWindowController.minimumSize.height)
        .background(Color.piContent)
        .background(InspectorShortcuts(inspector: inspector))
        .tint(Color.piAccent)
        .accessibilityIdentifier("session-inspector")
    }
}

/// The window's own title bar: it drags and zooms the window, names the
/// session, and leaves the traffic lights their room.
private struct InspectorTitleBar: View {
    @ObservedObject var inspector: SessionInspectorModel
    var body: some View {
        ZStack(alignment: .leading) {
            PiWindowBar()
            HStack(spacing: PiSpacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Session Inspector").font(PiFont.title(14)).foregroundStyle(Color.piInk)
                    Text(inspector.title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle)
                }.allowsHitTesting(false)
                Spacer(minLength: 8)
                PiIconButton(symbol: "arrow.clockwise", label: "Read this session's requests again", size: 24) { inspector.refresh() }
                    .accessibilityIdentifier("inspector-refresh")
            }
            .padding(.leading, PiWindowBar.trafficLightInset).padding(.trailing, PiSpacing.md)
        }
        .frame(height: 48).background(Color.piWindow)
    }
}

/// ⌘[ and ⌘] step through the requests; ⌘F finds in the request on screen.
private struct InspectorShortcuts: View {
    @ObservedObject var inspector: SessionInspectorModel
    var body: some View {
        VStack {
            Button("Previous request") { inspector.step(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next request") { inspector.step(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Find in request") {
                if case .request = inspector.page {} else if let latest = inspector.index.latestRequestID { inspector.select(.request(latest)) }
                inspector.request.tab = .raw
                inspector.request.searchFocus &+= 1
            }.keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

// MARK: - Navigator

/// Overview, the next request, then every turn with its requests under it.
/// Rows are one height each and built as they scroll into view.
private struct InspectorNavigator: View {
    @ObservedObject var inspector: SessionInspectorModel
    let compact: Bool
    @Namespace private var selection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    InspectorNavRow(symbol: "chart.bar.xaxis", title: "Overview", subtitle: overviewSubtitle,
                                    selected: inspector.page == .overview) { inspector.select(.overview) }
                        .id("overview")
                    InspectorNavRow(symbol: "square.stack.3d.up", title: "Next request", subtitle: "What the model receives next",
                                    selected: inspector.page == .nextRequest) { inspector.select(.nextRequest) }
                        .id("next")
                    sectionLabel
                    if inspector.index.isEmpty {
                        Text(inspector.indexLoaded ? "No requests yet" : "Reading requests…")
                            .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    ForEach(inspector.index.turns) { turn in
                        InspectorTurnRow(turn: turn, prompt: inspector.prompts[turn.id], compact: compact,
                                         expanded: inspector.expanded.contains(turn.id),
                                         selected: inspector.page == .turn(turn.id),
                                         toggle: { inspector.toggle(turn.id) },
                                         open: { inspector.select(.turn(turn.id)) })
                            .id(turn.id)
                        if inspector.expanded.contains(turn.id) {
                            ForEach(Array(turn.requests.enumerated()), id: \.element.id) { offset, row in
                                InspectorRequestNavRow(row: row, number: offset + 1, kind: inspector.index.kind(of: row.id),
                                                       selected: inspector.page == .request(row.id)) { inspector.select(.request(row.id)) }
                                    .id(row.id)
                            }
                        }
                    }
                    if inspector.index.olderRequests > 0 {
                        Text("\(inspector.index.olderRequests) older requests are not listed")
                            .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
                .environment(\.piSelectionNamespace, selection)
            }
            .onChange(of: inspector.page) { _, page in scroll(proxy, to: page) }
            .onAppear { scroll(proxy, to: inspector.page) }
        }
        .accessibilityIdentifier("inspector-navigator")
    }

    private func scroll(_ proxy: ScrollViewProxy, to page: InspectorPage) {
        let target: String
        switch page {
        case .overview: target = "overview"
        case .nextRequest: target = "next"
        case .turn(let id), .request(let id): target = id
        }
        // A turn of requests at a time: after SwiftUI placed the rows.
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: nil) }
    }

    private var overviewSubtitle: String {
        let requests = inspector.index.requests.filter { $0.source != .record }.count
        let turns = inspector.index.turns.filter { !$0.isOther }.count
        guard requests > 0 else { return "Cost, tokens and time" }
        return "\(turns) turn" + (turns == 1 ? "" : "s") + " · \(requests) request" + (requests == 1 ? "" : "s")
    }

    private var sectionLabel: some View {
        HStack {
            Text("TURNS").font(PiFont.micro).tracking(0.6).foregroundStyle(Color.piInkTertiary)
            Spacer(minLength: 0)
            if inspector.indexLoaded, inspector.index.turns.contains(where: \.running) {
                PiShimmerText(text: "running", size: 10)
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row of the navigator: a tinted glyph, a title and a quieter line.
private struct InspectorNavRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        PiSelectableRow(selected: selected, action: action) {
            HStack(spacing: 10) {
                PiIconBadge(symbol: symbol, tone: selected ? .accent : .neutral, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk).lineLimit(1)
                    Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 46)
        .accessibilityLabel(title + ", " + subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A turn: its number, the first line of its prompt, what it cost.
private struct InspectorTurnRow: View {
    let turn: InspectorTurn
    let prompt: String?
    let compact: Bool
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void
    let open: () -> Void
    private var accessibility: String {
        let name = turn.isOther ? "Other requests" : "Turn \(turn.number)"
        return name + ": " + heading + ", " + turn.summary
    }
    private var heading: String {
        if turn.isOther { return "Other requests" }
        let line = prompt.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) }?
            .trimmingCharacters(in: .whitespaces)
        if let line, !line.isEmpty { return line }
        return turn.started.map { "Turn at " + Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "Turn \(turn.number)"
    }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 18, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer()
            .accessibilityLabel(expanded ? "Hide this turn's requests" : "Show this turn's requests")
            PiSelectableRow(selected: selected, action: open) {
                HStack(alignment: .center, spacing: 8) {
                    Text(turn.isOther ? "·" : "\(turn.number)")
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? Color.piAccent : Color.piInkSecondary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(selected ? Color.piAccentSoft : Color.piFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(heading).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk).lineLimit(1)
                        HStack(spacing: 5) {
                            if turn.running { InspectorStatusMark(outcome: "running") }
                            Text(turn.summary).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("inspector-turn-row")
    }
}

/// One request of a turn: its number, what kind of request it was, the model
/// that answered and what went in and out.
private struct InspectorRequestNavRow: View {
    let row: InspectorRequestRow
    let number: Int
    let kind: String
    let selected: Bool
    let action: () -> Void
    private var model: String { row.model ?? row.alias ?? "" }
    private var kindColor: Color { row.source == .record ? .piInkTertiary : .piInk }
    private var accessibility: String {
        let flow = row.tokenFlow.map { ", " + $0 } ?? ""
        return "Request \(number), \(kind), " + (model.isEmpty ? "model unreported" : model) + flow
    }
    var body: some View {
        PiSelectableRow(selected: selected, action: action) { content }
            .padding(.leading, 26)
            .frame(height: 30)
            .accessibilityLabel(accessibility)
            .accessibilityIdentifier("inspector-request-row")
    }
    /// The kind always reads whole; the tokens and the model follow only
    /// where they fit, the model first to go (the request page names it).
    private var content: some View {
        HStack(spacing: 7) {
            InspectorStatusMark(outcome: row.outcome)
            Text(String(number)).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(Color.piInkSecondary)
            ViewThatFits(in: .horizontal) {
                line(model: true, flow: true)
                line(model: false, flow: true)
                line(model: false, flow: false)
            }
        }
        .help(model.isEmpty ? kind : kind + " · " + model)
    }
    private func line(model showsModel: Bool, flow showsFlow: Bool) -> some View {
        HStack(spacing: 7) {
            Text(kind).font(.system(size: 12)).foregroundStyle(kindColor).lineLimit(1).fixedSize()
            if showsModel, !model.isEmpty {
                Text(model).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 4)
            if showsFlow, let flow = row.tokenFlow {
                Text(flow).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Color.piInkTertiary).lineLimit(1).fixedSize()
            }
        }
    }
}

// MARK: - Pages

private struct InspectorPageView: View {
    @ObservedObject var inspector: SessionInspectorModel
    let compact: Bool
    var body: some View {
        VStack(spacing: 0) {
            if let notice = inspector.focusNotice ?? inspector.failure {
                InspectorBanner(symbol: "exclamationmark.circle", text: notice, tone: .warning)
                    .padding(.horizontal, PiSpacing.xl).padding(.top, PiSpacing.md)
            }
            switch inspector.page {
            case .overview: InspectorOverviewPage(inspector: inspector, compact: compact)
            case .nextRequest: InspectorNextRequestPage(inspector: inspector, next: inspector.next, compact: compact)
            case .turn(let id): InspectorTurnPage(inspector: inspector, turnID: id, compact: compact)
            case .request: InspectorRequestPage(inspector: inspector, request: inspector.request, compact: compact)
            }
        }
    }
}
