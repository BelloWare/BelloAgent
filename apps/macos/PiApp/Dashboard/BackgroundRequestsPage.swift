import SwiftUI

/// Every request the app asked a mini model on its own — chat titles, the
/// rename sheet's title suggestions and webhook notifications — newest first,
/// as a page inside the main window beside the usage report. Selecting one
/// shows what it sent and got back; its captured requests are in the Session
/// Inspector. The rows are worked out by `BackgroundRequestsController`
/// when the records change; this view only lays them out.
@MainActor
struct BackgroundRequestsPage: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var requests: BackgroundRequestsController
    @Namespace private var selectionGlide
    init(model: WorkspaceModel) { self.model = model; self.requests = model.backgroundRequests }

    private var selectedRow: BackgroundRequestRow? { requests.selectedID.flatMap { id in requests.rows.first { $0.id == id } } }

    var body: some View {
        GeometryReader { geometry in
            // Wide enough, the details sit beside the list; narrower, they
            // take the page and the list waits under them, where it was.
            let sideBySide = geometry.size.width >= 900
            VStack(spacing: 0) {
                header(compact: geometry.size.width < 760)
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(spacing: 0) {
                    ZStack {
                        list.opacity(!sideBySide && selectedRow != nil ? 0 : 1).allowsHitTesting(sideBySide || selectedRow == nil)
                        if !sideBySide, let row = selectedRow { detail(row) }
                    }
                    if sideBySide, let row = selectedRow {
                        Rectangle().fill(Color.piHairline).frame(width: 1)
                        detail(row).frame(width: geometry.size.width >= 1100 ? 440 : 360)
                    }
                }
            }
        }
        .background(Color.piContent)
        .onAppear { requests.prepare(model) }
        .onDisappear { requests.suspend() }
        .onChange(of: model.chatsRevision) { _, _ in requests.recordsChanged() }
        .onChange(of: model.workspacesRevision) { _, _ in requests.recordsChanged() }
        .onExitCommand { model.closeReport() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background requests")
    }

    private func detail(_ row: BackgroundRequestRow) -> some View {
        BackgroundRequestDetailPane(row: row, detail: requests.detail, loading: requests.detailLoading,
                                    openSource: { model.openBackgroundRequestSource(row.id) },
                                    inspect: { model.inspectBackgroundRequest(row.id) },
                                    close: { requests.selectedID = nil })
            .transition(.identity)
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.md) {
                Button { model.closeReport() } label: { Label("Chats", systemImage: "chevron.left") }
                    .buttonStyle(.piGhost).help("Back to chats (Esc)").accessibilityIdentifier("backgroundRequestsBack")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background requests").font(PiFont.title(17)).foregroundStyle(Color.piInk)
                    Text(caption).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                        .lineLimit(1).truncationMode(.tail).help(caption)
                }
                Spacer(minLength: PiSpacing.sm)
                if !compact { filterTabs }
            }
            if compact { filterTabs }
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 12).padding(.bottom, 10)
    }

    private var filterTabs: some View {
        PiTabs(selection: $requests.filter, items: BackgroundRequestFilter.allCases.map { ($0, $0.title) })
            .fixedSize().accessibilityLabel("Kind of request").accessibilityIdentifier("backgroundRequestsFilter")
    }

    /// What the mini model was asked in the background, and what the listed requests add up to.
    private var caption: String {
        let summary = requests.summary
        var parts = ["Asked of the mini model in the background · \(summary.requests) request\(summary.requests == 1 ? "" : "s")"]
        if summary.running > 0 { parts.append("\(summary.running) running") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if let tokens = summary.tokens { parts.append(compactTokens(tokens) + " tokens") }
        if let cost = summary.cost { parts.append(compactGatewayUSD(cost)) }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(requests.rows) { row in
                        BackgroundRequestRowView(row: row, selected: requests.selectedID == row.id,
                                                 select: { requests.selectedID = row.id },
                                                 openSource: { model.openBackgroundRequestSource(row.id) })
                            .equatable()
                            .id(row.id)
                    }
                }
                .padding(.horizontal, PiSpacing.md).padding(.vertical, PiSpacing.sm)
                .environment(\.piSelectionNamespace, selectionGlide)
            }
            .modifier(SidebarMinuteClock())
            .overlay { if requests.rows.isEmpty { emptyState } }
            .onAppear {
                // Opened on a request (the menu bar's running one, the report's row): show it.
                guard let id = requests.selectedID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PiIconBadge(symbol: "sparkles.rectangle.stack", tone: .accent, size: 36)
            Text(requests.filter == .all ? "No background requests yet" : "No \(requests.filter.title.lowercased()) yet")
                .font(PiFont.heading).foregroundStyle(Color.piInk)
            Text("Chat titles, title suggestions and webhook notifications appear here as the mini model writes them.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(PiSpacing.xl)
    }
}

/// How a request stands, as a badge: a spinner while it runs.
struct BackgroundRequestStatusBadge: View {
    let status: BackgroundRequestStatus
    var body: some View {
        switch status {
        case .running: PiBadge(text: status.label, tone: .warning, spinning: true)
        case .completed: PiBadge(text: status.label, tone: .success, dot: true)
        case .failed: PiBadge(text: status.label, tone: .danger, dot: true)
        case .interrupted: PiBadge(text: status.label, tone: .neutral, dot: true)
        }
    }
}

/// One request: what it was for and what it produced or why it did not,
/// how it stands and how long it took; then when, for which chat and project,
/// on which connection and model, and what it cost.
struct BackgroundRequestRowView: View, Equatable {
    nonisolated static func == (lhs: BackgroundRequestRowView, rhs: BackgroundRequestRowView) -> Bool {
        lhs.row == rhs.row && lhs.selected == rhs.selected
    }
    let row: BackgroundRequestRow
    let selected: Bool
    let select: () -> Void
    let openSource: () -> Void
    @Environment(\.sidebarMinute) private var minute

    /// The line the row leads with: the result, or what stands in its place.
    private var headline: (text: String, color: Color) {
        switch row.status {
        case .running: return ("Waiting for the mini model…", .piInkSecondary)
        case .completed: return row.resultLine.map { ($0, Color.piInk) } ?? ("No result was kept", .piInkSecondary)
        case .failed(let why): return (why, .piDanger)
        case .interrupted(let why): return (row.resultLine ?? why, .piInkSecondary)
        }
    }

    var body: some View {
        PiSelectableRow(selected: selected, action: select) {
            HStack(alignment: .top, spacing: PiSpacing.md) {
                PiIconBadge(symbol: row.kind.symbol, tone: .accent, size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    // Centred, not on the text's baseline: the running badge's
                    // spinner has none, and pulled the badge below the line.
                    HStack(alignment: .center, spacing: PiSpacing.sm) {
                        Text(row.kind.label).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInkSecondary)
                            .lineLimit(1).fixedSize()
                        Text(headline.text).font(PiFont.body).foregroundStyle(headline.color)
                            .lineLimit(1).truncationMode(.tail).help(row.result ?? row.status.reason ?? "")
                        Spacer(minLength: PiSpacing.sm)
                        if let duration = row.durationMs {
                            Text(TranscriptActivity.formatDuration(duration)).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                                .fixedSize().help("From sent to answered")
                        }
                        BackgroundRequestStatusBadge(status: row.status).fixedSize()
                    }
                    metadata
                }
            }
        }
        .accessibilityIdentifier("backgroundRequest-" + row.id)
    }

    /// When, for which chat and project, on which connection and model, and
    /// what it cost. A narrow row leaves out the connection, then the
    /// project, then the model, whole: never half of each.
    private var metadata: some View {
        HStack(spacing: 5) {
            ViewThatFits(in: .horizontal) {
                context(project: true, connection: true, model: true)
                context(project: true, connection: false, model: true)
                context(project: false, connection: false, model: true)
                context(project: false, connection: false, model: false)
            }
            Spacer(minLength: PiSpacing.sm)
            if let totals = row.totals {
                if let tokens = totals.billedTotalTokens {
                    Text(compactTokens(tokens) + " tok").fixedSize()
                        .help("Input \(menuBarTokens(totals.tokens?.input)) · output \(menuBarTokens(totals.tokens?.output)) tokens, as the gateway reported them")
                }
                if totals.costSamples > 0 {
                    if totals.billedTotalTokens != nil { separator }
                    Text(compactGatewayUSD(totals.costUSD)).fixedSize().help(gatewayUSD(totals.costUSD))
                }
            }
        }
        .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
    }
    private func context(project: Bool, connection: Bool, model: Bool) -> some View {
        // The shortest form fits by truncating the chat's title; the others
        // fit whole or not at all.
        let whole = project || connection || model
        return HStack(spacing: 5) {
            if let started = row.startedAt {
                Text(ChatRowStats.relative(started, now: minute ?? Date())).fixedSize()
                    .help(started.formatted(date: .complete, time: .standard))
                separator
            }
            if let title = row.sourceTitle {
                Button(action: openSource) {
                    Text(title).foregroundStyle(Color.piAccent).lineLimit(1).truncationMode(.tail).fixedSize(horizontal: whole, vertical: false)
                }
                .buttonStyle(.plain).piPointer().help("Open “\(title)”").accessibilityIdentifier("backgroundRequestSource-" + row.id)
            } else {
                Text("Deleted chat").foregroundStyle(Color.piInkTertiary).fixedSize()
            }
            if project, let name = row.project { separator; Text(name).fixedSize() }
            if connection, let name = row.connection { separator; Text(name).fixedSize() }
            if model, let name = row.model { separator; Text(name).fixedSize().help(name) }
        }
    }
    private var separator: some View { Text("·").foregroundStyle(Color.piInkTertiary) }
}

/// The selected request: how it stands, what it produced, where it came
/// from and what it cost, what it sent and got back, and the ways further in.
struct BackgroundRequestDetailPane: View {
    let row: BackgroundRequestRow
    let detail: BackgroundRequestDetail?
    let loading: Bool
    let openSource: () -> Void
    let inspect: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.lg) {
                HStack(alignment: .center, spacing: PiSpacing.sm) {
                    PiIconBadge(symbol: row.kind.symbol, tone: .accent, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.kind.label).font(PiFont.heading).foregroundStyle(Color.piInk)
                        if let started = row.startedAt {
                            Text(started.formatted(date: .abbreviated, time: .standard)).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        }
                    }
                    Spacer(minLength: PiSpacing.sm)
                    BackgroundRequestStatusBadge(status: row.status)
                    PiIconButton(symbol: "xmark", label: "Close the details", size: 24, action: close)
                }
                if let result = row.result {
                    Text(result).font(PiFont.body).foregroundStyle(Color.piInk).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
                        .accessibilityIdentifier("backgroundRequestResult")
                }
                if let reason = row.status.reason {
                    PiNote(reason, tone: row.status == .failed(reason) ? .danger : .neutral)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PiSpacing.sm) { actions }
                    VStack(alignment: .leading, spacing: PiSpacing.sm) { actions }
                }
                VStack(alignment: .leading, spacing: 6) {
                    PiKeyValue(key: "Chat", value: row.sourceTitle ?? "Deleted chat")
                    if let project = row.project { PiKeyValue(key: "Project", value: project) }
                    PiKeyValue(key: "Connection", value: row.connection ?? "Deleted connection")
                    if let model = row.model { PiKeyValue(key: "Model", value: model, mono: true) }
                    if let ended = row.endedAt { PiKeyValue(key: "Ended", value: ended.formatted(date: .abbreviated, time: .standard)) }
                    if let duration = row.durationMs { PiKeyValue(key: "Duration", value: TranscriptActivity.formatDuration(duration)) }
                    if let totals = row.totals, totals.requests > 0 {
                        PiKeyValue(key: "Tokens", value: totals.billedTotalTokens == nil ? "Not reported"
                                   : "in \(menuBarTokens(totals.tokens?.input)) · out \(menuBarTokens(totals.tokens?.output))")
                        PiKeyValue(key: "Cost", value: totals.costSamples > 0 ? gatewayUSD(totals.costUSD) : "Not reported")
                        PiKeyValue(key: "Requests", value: "\(totals.requests)")
                    } else {
                        PiKeyValue(key: "Usage", value: "Nothing captured for this request")
                    }
                }
                exchange
            }
            .padding(PiSpacing.lg)
        }
        .background(Color.piContent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background request details")
    }

    @ViewBuilder private var actions: some View {
        Button(action: openSource) { Label("Open Source Chat", systemImage: "bubble.left").fixedSize() }
            .buttonStyle(.piSecondaryCompact).disabled(row.sourceTitle == nil)
            .accessibilityIdentifier("backgroundRequestOpenSource")
        Button(action: inspect) { Label("Inspect Requests", systemImage: "ladybug").fixedSize() }
            .buttonStyle(.piSecondaryCompact).help("The Session Inspector: this request's captured bodies, usage and timing")
            .accessibilityIdentifier("backgroundRequestInspect")
    }

    @ViewBuilder private var exchange: some View {
        if loading {
            HStack(spacing: PiSpacing.sm) {
                PiSpinner(size: 12)
                Text("Reading the request's journal…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
        } else if let detail {
            if let unavailable = detail.unavailable { PiNote(unavailable) }
            if let prompt = detail.prompt { section("Prompt sent", text: prompt, identifier: "backgroundRequestPrompt") }
            if let reply = detail.reply { section("Reply", text: reply, identifier: "backgroundRequestReply") }
            else if detail.prompt != nil, row.status == .running { PiNote("The reply has not come yet.") }
        }
    }

    private func section(_ title: String, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            Text(text).font(PiFont.mono).foregroundStyle(Color.piInk).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
                .accessibilityIdentifier(identifier)
        }
    }
}
