import SwiftUI

/// One request: a header that stays put (which request, how it went, what
/// answered, the figures), then what the model received, what it answered,
/// and the raw bytes, one tab each.
struct InspectorRequestPage: View {
    @ObservedObject var inspector: SessionInspectorModel
    @ObservedObject var request: InspectorRequestModel
    let compact: Bool
    @State private var more = false
    @State private var evidence = false
    @State private var events = false
    @StateObject private var full = InspectorFullText()

    var body: some View {
        if let row = request.row {
            VStack(spacing: 0) {
                header(row)
                if row.source == .record {
                    recordOnly(row)
                } else {
                    tabs
                    Rectangle().fill(Color.piHairline).frame(height: 1)
                    switch request.tab {
                    case .conversation: conversation(row)
                    case .response: response(row)
                    case .raw: InspectorRawTab(inspector: inspector, request: request, compact: compact)
                    }
                }
                InspectorFullTextPane(full: full)
            }
            .onChange(of: row.id) { _, _ in full.close(); events = false }
            .onChange(of: request.tab) { _, _ in full.close() }
            .accessibilityIdentifier("inspector-request")
        } else {
            InspectorPlaceholder(symbol: "arrow.up.arrow.down", title: "Choose a request", message: "Every request of this session is in the list on the left.")
        }
    }

    // MARK: Header

    private func header(_ row: InspectorRequestRow) -> some View {
        let position = inspector.index.position(of: row.id)
        let title = position.map { "Request \($0.index) of \($0.count)" } ?? "Request"
        let turn = inspector.index.turn(containing: row.id)
        var context: [String] = [row.route.label]
        if let turn, !turn.isOther { context.append("Turn \(turn.number)") }
        if row.wall > 0 { context.append(Date(timeIntervalSince1970: row.wall).formatted(date: .omitted, time: .standard)) }
        return VStack(alignment: .leading, spacing: 10) {
            InspectorPageHeader(title, subtitle: context.joined(separator: " · ")) {
                PiBadge(text: inspector.index.kind(of: row.id), tone: .neutral)
                if let status = request.metadata["status"]?.nonnegativeInteger {
                    PiBadge(text: "HTTP \(status)", tone: status >= 400 ? .danger : .success)
                }
                if row.running {
                    PiShimmerText(text: streamingLabel, size: 11)
                } else if row.outcome != "completed" {
                    PiBadge(text: row.outcomeLabel, tone: row.outcomeTone, dot: true)
                }
            } actions: {
                PiIconButton(symbol: "chevron.left", label: "Previous request (⌘[)", size: 26) { inspector.step(-1) }
                    .disabled(inspector.index.adjacent(to: row.id, step: -1) == nil)
                PiIconButton(symbol: "chevron.right", label: "Next request (⌘])", size: 26) { inspector.step(1) }
                    .disabled(inspector.index.adjacent(to: row.id, step: 1) == nil)
                InspectorShowInChat { inspector.showInChat() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                InspectorFigureStrip(figures: row.figures)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.source != .record {
                    disclosure("More", open: $more)
                    disclosure("Model evidence", open: $evidence)
                }
            }
            if more { moreDetails(row).transition(.opacity) }
            if evidence {
                PiCard(padding: PiSpacing.md, sunken: true) { MessageModelReports(attempt: request.metadata) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.top, PiSpacing.lg).padding(.bottom, PiSpacing.md)
        .piAnimation(PiMotion.quick, value: more)
        .piAnimation(PiMotion.quick, value: evidence)
        .accessibilityIdentifier("inspector-request-header")
    }

    private var streamingLabel: String {
        let observed = request.metadata["response"]?.object?["observedBytes"]?.number ?? 0
        return observed == 0 ? "Awaiting response…" : "Streaming…"
    }

    private func disclosure(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
            }
        }
        .buttonStyle(.piGhost).fixedSize()
    }

    /// The figures the strip leaves out: caches, reasoning cost, clocks, identity.
    private func moreDetails(_ row: InspectorRequestRow) -> some View {
        let gateway = GatewayObservation(metadata: request.metadata)
        let metrics = request.metadata["metrics"]?.object ?? [:]
        var rows: [(String, String)] = []
        if let write = row.cacheWrite { rows.append(("Cache write", MetricFormat.exactTokens(write) + " tokens")) }
        rows.append(("Response cache", gateway.cacheStatus))
        if gateway.reasoningCostStatus == "reported", let value = gateway.reasoningCostUSD { rows.append(("Reasoning cost", gatewayUSD(value) + " · included")) }
        if let decode = row.decode { rows.append(("Generation", SessionStatsFormat.duration(decode) + " first to last token")) }
        if let http = DurationObservation.valid(metrics["httpDurationMs"]?.number) ?? row.http { rows.append(("Whole request", MetricFormat.detailedDuration(http))) }
        rows.append(("Purpose", row.purpose))
        if !row.api.isEmpty { rows.append(("API", row.api)) }
        if let url = request.metadata["url"]?.string { rows.append(("Endpoint", (request.metadata["method"]?.string ?? "POST") + " " + (URL(string: url)?.path ?? url))) }
        rows.append(("Attempt", row.id))
        return PiCard(padding: PiSpacing.md, sunken: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: PiSpacing.lg, alignment: .topLeading)], alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { name, value in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).frame(width: 104, alignment: .leading)
                        Text(value).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }
        }
        .accessibilityIdentifier("inspector-request-more")
    }

    private var tabs: some View {
        HStack(spacing: PiSpacing.sm) {
            PiTabs(selection: $request.tab, items: [(.conversation, "Conversation"), (.response, "Response"), (.raw, "Raw")])
                .accessibilityIdentifier("inspector-request-tabs")
            Spacer(minLength: 0)
            if request.tab == .response {
                Button { events.toggle() } label: { Label(events ? "Hide event log" : "Event log", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(.piGhost).accessibilityIdentifier("inspector-event-log")
            }
        }
        .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.bottom, 10)
    }

    private func recordOnly(_ row: InspectorRequestRow) -> some View {
        InspectorPlaceholder(symbol: "doc.text.magnifyingglass", title: "Known from the chat's own record",
                             message: (row.logMissing == .expired ? "This request's row has expired from the request log" : "The request log never had this request")
                                + ", so its body and headers are not available. The figures above are the ones its reply recorded.")
    }

    // MARK: Conversation

    /// The outline stays mounted while a body loads: the placeholder covers
    /// it, and a document that arrives fills the same native view rather than
    /// building a new one in the step that shows it.
    @ViewBuilder private func conversation(_ row: InspectorRequestRow) -> some View {
        let document = request.conversation.value
        VStack(alignment: .leading, spacing: 0) {
            if let document {
                banner(document, row: row)
                    .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.top, 12).padding(.bottom, 8)
            }
            ZStack {
                InspectorItemsOutline(content: document.map { outlineContent($0, row: row) } ?? .empty) { target, title in
                    if let document { open(target, title: title, request: document) }
                }
                .padding(.horizontal, compact ? PiSpacing.sm : PiSpacing.md)
                .opacity(document == nil || document?.notice != nil ? 0 : 1)
                switch request.conversation {
                case .idle:
                    InspectorPlaceholder(symbol: "text.bubble", title: request.metadataLoaded ? "Preparing the request…" : "Reading the request…")
                case .loading(let loaded, let total):
                    InspectorPlaceholder(symbol: "text.bubble", title: "Reading the request",
                                         message: total > 0 ? RequestDocument.byteLabel(loaded) + " of " + RequestDocument.byteLabel(total) : nil,
                                         progress: total > 0 ? Double(loaded) / Double(total) : nil)
                case .failed(let message):
                    InspectorPlaceholder(symbol: "exclamationmark.circle", title: "The request body is not available", message: message)
                case .ready(let document):
                    if let notice = document.notice { InspectorPlaceholder(symbol: "curlybraces", title: notice) }
                }
            }
        }
    }

    @ViewBuilder private func banner(_ document: RequestDocument, row: InspectorRequestRow) -> some View {
        if let delta = request.delta {
            InspectorBanner(symbol: delta.rewritten ? "arrow.triangle.2.circlepath" : delta.first ? "sparkles" : "plus.circle",
                            text: delta.banner(previous: delta.first ? nil : request.previousLabel, cachedShare: row.cachedShare),
                            notes: delta.notes, tone: delta.rewritten ? .warning : .accent)
        } else if let note = request.deltaNote {
            InspectorBanner(symbol: "info.circle", text: "\(document.items.count) items, " + RequestDocument.charactersLabel(document.totalCharacters),
                            notes: [note], tone: .neutral)
        } else {
            HStack(spacing: 6) {
                PiSpinner(size: 12)
                Text("Comparing with " + (request.previousLabel ?? "the request before") + "…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
            }
            .frame(height: 34)
        }
    }

    private func outlineContent(_ document: RequestDocument, row: InspectorRequestRow) -> InspectorOutlineContent {
        let delta = request.delta
        let grouped = delta.map { !$0.first } ?? false
        return InspectorOutlineContent(key: row.id + ":request:\(document.bytes)", sections: document.sections, items: document.items,
                                       shared: grouped ? delta?.shared : nil, marksNew: grouped,
                                       openLast: grouped ? min(delta?.added ?? 0, 8) : 2)
    }

    private func open(_ target: InspectorOutlineTarget, title: String, request document: RequestDocument) {
        switch target {
        case .item(let index): full.open(title: title, render: { try document.fullText(item: index) })
        case .section(let kind): full.open(title: title, render: { try document.fullText(section: kind) })
        }
    }

    // MARK: Response

    @ViewBuilder private func response(_ row: InspectorRequestRow) -> some View {
        if events {
            CapturedBodyView(source: responseSource(row), sessionID: inspector.scope.sessionID, attemptID: row.id, kind: "response",
                             retained: row.source != .live, initialFormat: .json, growingBytes: request.growingBytes)
                .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.vertical, 12)
                .id(row.id + ":events")
        } else {
            let document = request.response.value
            VStack(alignment: .leading, spacing: 0) {
                if let document {
                    responseSummary(document, row: row)
                        .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.top, 12).padding(.bottom, 8)
                }
                ZStack {
                    InspectorItemsOutline(content: document.map { InspectorOutlineContent(key: row.id + ":response:\(request.responseBytes)", sections: [], items: $0.items,
                                                                                           shared: nil, marksNew: false, openLast: min($0.items.count, 6)) } ?? .empty) { target, title in
                        if let document, case .item(let index) = target { full.open(title: title, render: { try document.fullText(item: index) }) }
                    }
                    .padding(.horizontal, compact ? PiSpacing.sm : PiSpacing.md)
                    .opacity(document?.items.isEmpty == false ? 1 : 0)
                    switch request.response {
                    case .idle:
                        InspectorPlaceholder(symbol: "sparkle", title: request.metadataLoaded ? "Preparing the response…" : "Reading the response…")
                    case .loading(let loaded, let total):
                        InspectorPlaceholder(symbol: "sparkle", title: "Reading the response",
                                             message: total > 0 ? RequestDocument.byteLabel(loaded) + " of " + RequestDocument.byteLabel(total) : nil,
                                             progress: total > 0 ? Double(loaded) / Double(total) : nil)
                    case .failed(let message):
                        InspectorPlaceholder(symbol: "exclamationmark.circle", title: row.running ? "No response yet" : "The response is not available", message: message)
                    case .ready(let document):
                        if document.items.isEmpty { InspectorPlaceholder(symbol: "sparkle", title: "The response has no output items yet") }
                    }
                }
            }
        }
    }

    private func responseSummary(_ document: ResponseDocument, row: InspectorRequestRow) -> some View {
        // A response still arriving says so plainly; how a partial capture was
        // put together matters only once the request has settled without its end.
        let streaming = row.running && document.partial
        let arrived = document.items.reduce(0) { $0 + $1.characters }
        return VStack(alignment: .leading, spacing: 8) {
            InspectorBanner(symbol: document.partial ? "ellipsis.circle" : document.status == "completed" ? "checkmark.circle" : "exclamationmark.circle",
                            text: streaming ? "Streaming · " + RequestDocument.charactersLabel(arrived) + " so far" : document.summary,
                            notes: streaming ? [] : document.notice.map { [$0] } ?? [],
                            tone: streaming ? .accent : document.status == "completed" && !document.partial ? .success : .warning)
            if !document.usage.isEmpty {
                InspectorFigureStrip(figures: document.usage.map { InspectorFigure(label: $0.name, value: $0.value) })
            }
            if let grown = request.growingBytes, grown > request.responseBytes {
                HStack(spacing: 8) {
                    Text(RequestDocument.byteLabel(grown) + " so far · showing the first " + RequestDocument.byteLabel(request.responseBytes))
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    Button("Load latest") { request.loadLatest() }.buttonStyle(.piSecondaryCompact).accessibilityIdentifier("inspector-load-latest")
                }
            }
        }
    }

    private func responseSource(_ row: InspectorRequestRow) -> CapturedBodySource {
        let state = request.metadata["response"]?.object?["state"]?.string ?? ""
        if row.source != .live, MessageBodyReader.canReadRetained(state) || inspector.workspace == nil { return .archive(inspector.archive, attemptID: row.id, kind: "response") }
        if let workspace = inspector.workspace { return .live(workspace, sessionID: inspector.scope.sessionID, attemptID: row.id, kind: "response") }
        return .archive(inspector.archive, attemptID: row.id, kind: "response")
    }
}
