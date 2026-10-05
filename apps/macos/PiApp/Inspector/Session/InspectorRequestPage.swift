import AppKit

/// Fixed request chrome above a reused native outline, response, or raw view.
@MainActor final class InspectorRequestPage: DashView {
    let inspector: SessionInspectorModel
    let request: InspectorRequestModel
    var compact: Bool { didSet { if compact != oldValue { forceHeader = true; refresh() } } }
    private var more = false, evidence = false, events = false
    private var shownRow: InspectorRequestRow?
    private var shownMetadata: [String: WireValue] = [:]
    private var shownHeaderIdentity = ""
    private var header: NSView?
    private var tabs: InspectorInset?
    private lazy var tabControl = PiKit.Tabs(selection: request.tab, items: [(InspectorRequestModel.Tab.conversation, "Conversation"), (.response, "Response"), (.raw, "Raw")]) { [weak request] in request?.tab = $0 }
    private lazy var eventToggle = PiKit.Button("Event log", symbol: "list.bullet.rectangle", style: .ghost) { [weak self] in self?.events.toggle(); self?.refresh() }
    private lazy var tabRow = inspectorRow([.view(tabControl), .spacer(0), .view(eventToggle)], spacing: PiSpacing.sm)
    private lazy var tabStrip = padded(tabRow, bottom: 10)
    private let rule = InspectorRule()
    private let conversationOutline = InspectorItemsOutline()
    private let responseOutline = InspectorItemsOutline()
    private lazy var conversationHost = InspectorContentHost(content: conversationOutline)
    private lazy var responseHost = InspectorContentHost(content: responseOutline)
    private var content: NSView?
    private var summary: NSView?
    private var eventBody: CapturedBodyView?
    private var eventKey: String?
    private var eventHost: InspectorInset?
    private lazy var raw = InspectorRawTab(inspector: inspector, request: request, compact: compact)
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private var forceHeader = true

    init(inspector: SessionInspectorModel, request: InspectorRequestModel, compact: Bool) {
        self.inspector = inspector; self.request = request; self.compact = compact
        super.init(frame: .zero)
        setAccessibilityIdentifier("inspector-request")
        observer.observe(inspector); observer.observe(request); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        guard let row = request.row else {
            showContent(InspectorPlaceholder(symbol: "arrow.up.arrow.down", title: "Choose a request", message: "Every request of this session is in the list on the left."))
            header?.removeFromSuperview(); header = nil; tabs?.removeFromSuperview(); tabs = nil; rule.removeFromSuperview(); summary?.removeFromSuperview(); summary = nil
            needsLayout = true; return
        }
        if shownRow?.id != row.id { events = false; eventBody = nil; eventKey = nil; eventHost = nil; forceHeader = true }
        let position = inspector.index.position(of: row.id)
        let headerIdentity = [position.map { "\($0.index):\($0.count)" } ?? "", inspector.summaryLabel(row.id) ?? "", inspector.index.kind(of: row.id), inspector.workspace?.canForkFromReply(inspector.scope.sessionID) == true ? "fork" : ""].joined(separator: "|")
        if forceHeader || shownRow != row || shownMetadata != request.metadata || shownHeaderIdentity != headerIdentity {
            header?.removeFromSuperview(); header = buildHeader(row); addSubview(header!)
            shownRow = row; shownMetadata = request.metadata; shownHeaderIdentity = headerIdentity; forceHeader = false
        }
        summary?.removeFromSuperview(); summary = nil
        if row.source == .record {
            tabs?.removeFromSuperview(); tabs = nil; rule.removeFromSuperview()
            showContent(InspectorPlaceholder(symbol: "doc.text.magnifyingglass", title: "Known from the chat's own record", message: (row.logMissing == .expired ? "This request's row has expired from the request log" : "The request log never had this request") + ", so its body and headers are not available. The figures above are the ones its reply recorded."))
        } else {
            tabs = buildTabs(); shellAdd([tabs!, rule])
            switch request.tab {
            case .conversation: showConversation(row)
            case .response: showResponse(row)
            case .raw: raw.compact = compact; raw.refresh(); showContent(raw)
            }
        }
        needsLayout = true
    }
    private func showContent(_ view: NSView) {
        if content !== view { content?.removeFromSuperview(); content = view; addSubview(view) }
    }
    private var inset: CGFloat { compact ? PiSpacing.lg : PiSpacing.xl }
    private func padded(_ view: NSView, top: CGFloat = 0, bottom: CGFloat = 0) -> InspectorInset {
        InspectorInset(view, insets: NSEdgeInsets(top: top, left: inset, bottom: bottom, right: inset))
    }
    private func invalidateHeader() { forceHeader = true; refresh() }

    private func buildHeader(_ row: InspectorRequestRow) -> NSView {
        let position = inspector.index.position(of: row.id)
        let title = position.map { "Request \($0.index) of \($0.count)" } ?? "Request"
        let turn = inspector.index.turn(containing: row.id)
        var context = [row.route.label]
        if let turn, !turn.isOther { context.append("Turn \(turn.number)") }
        if row.wall > 0 { context.append(Date(timeIntervalSince1970: row.wall).formatted(date: .omitted, time: .standard)) }
        let kind = PiKit.Badge(text: inspector.summaryLabel(row.id).map { "compaction · " + $0 } ?? inspector.index.kind(of: row.id), tone: .neutral)
        kind.setAccessibilityIdentifier("inspector-request-kind")
        var badges: [NSView] = [kind]
        if let status = request.metadata["status"]?.nonnegativeInteger { badges.append(PiKit.Badge(text: "HTTP \(status)", tone: status >= 400 ? .danger : .success)) }
        if row.running { badges.append(PiKit.ShimmerText((request.metadata["response"]?.object?["observedBytes"]?.number ?? 0) == 0 ? "Awaiting response…" : "Streaming…", size: 11)) }
        else if row.outcome != "completed" { badges.append(PiKit.Badge(text: row.outcomeLabel, tone: row.outcomeTone, dot: true)) }
        let previous = PiKit.IconButton(symbol: "chevron.left", label: "Previous request (⌘[)", size: 26) { [weak inspector] in inspector?.step(-1) }
        previous.isEnabled = inspector.index.adjacent(to: row.id, step: -1) != nil
        let next = PiKit.IconButton(symbol: "chevron.right", label: "Next request (⌘])", size: 26) { [weak inspector] in inspector?.step(1) }
        next.isEnabled = inspector.index.adjacent(to: row.id, step: 1) != nil
        var actions: [NSView] = [previous, next, InspectorShowInChat { [weak inspector] in inspector?.showInChat() }]
        if row.purpose == "turn", !row.running, inspector.workspace?.canForkFromReply(inspector.scope.sessionID) == true { actions.append(InspectorForkFromHere { [weak inspector] in inspector?.forkFromRequest(row.id) }) }
        let heading = InspectorPageHeader(title, subtitle: context.joined(separator: " · "), badges: badges, actions: actions)
        var metrics: [ShellItem] = [.view(InspectorFigureStrip(figures: row.figures), .fill)]
        if row.source != .record {
            metrics.append(.view(disclosure("More", open: more) { [weak self] in self?.more.toggle(); self?.invalidateHeader() }))
            metrics.append(.view(disclosure("Model evidence", open: evidence) { [weak self] in self?.evidence.toggle(); self?.invalidateHeader() }))
        }
        var views: [NSView] = [heading, inspectorRow(metrics, spacing: 12, alignment: .firstBaseline)]
        if more { views.append(moreDetails(row)) }
        if evidence { views.append(PiKit.card(MessageModelReports(attempt: request.metadata), padding: PiSpacing.md, sunken: true)) }
        let column = inspectorColumn(views, spacing: 10)
        let result = padded(column, top: PiSpacing.lg, bottom: PiSpacing.md)
        result.setAccessibilityIdentifier("inspector-request-header")
        return result
    }
    private func disclosure(_ title: String, open: Bool, action: @escaping () -> Void) -> InspectorInlineDisclosure {
        InspectorInlineDisclosure(title, expanded: open, action: action)
    }
    private func moreDetails(_ row: InspectorRequestRow) -> NSView {
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
        let grid = GridView(columns: .adaptive(minimum: 250, maximum: .greatestFiniteMagnitude), spacing: PiSpacing.lg, rowSpacing: 6)
        grid.items = rows.map { name, value in
            let reading = inspectorSelectableText(value, truncation: .byTruncatingMiddle)
            return inspectorRow([.view(inspectorText(name, color: .piInkTertiary), .fixed(104)), .view(reading, .flexible)], spacing: 8, alignment: .firstBaseline)
        }
        let card = PiKit.card(grid, padding: PiSpacing.md, sunken: true); card.setAccessibilityIdentifier("inspector-request-more"); return card
    }
    private func buildTabs() -> InspectorInset {
        tabControl.selection = request.tab
        tabControl.setAccessibilityIdentifier("inspector-request-tabs")
        let title = events ? "Hide event log" : "Event log"
        if eventToggle.title != title { eventToggle.title = title }
        eventToggle.setAccessibilityIdentifier("inspector-event-log")
        let hidden = request.tab != .response
        if eventToggle.isHidden != hidden { eventToggle.isHidden = hidden; tabRow.changed() }
        tabStrip.insets = NSEdgeInsets(top: 0, left: inset, bottom: 10, right: inset)
        return tabStrip
    }

    private func showConversation(_ row: InspectorRequestRow) {
        let document = request.conversation.value
        conversationOutline.update(content: document.map { outlineContent($0, row: row) } ?? .empty) { target in document.map { Self.wholeText(target, of: $0) } }
        if let document { summary = padded(banner(document, row: row), top: 12, bottom: 8); addSubview(summary!) }
        let placeholder: NSView?
        switch request.conversation {
        case .idle: placeholder = InspectorPlaceholder(symbol: "text.bubble", title: request.metadataLoaded ? "Preparing the request…" : "Reading the request…")
        case .loading(let loaded, let total): placeholder = InspectorPlaceholder(symbol: "text.bubble", title: "Reading the request", message: total > 0 ? RequestDocument.byteLabel(loaded) + " of " + RequestDocument.byteLabel(total) : nil, progress: total > 0 ? Double(loaded) / Double(total) : nil)
        case .failed(let message): placeholder = InspectorPlaceholder(symbol: "exclamationmark.circle", title: "The request body is not available", message: message)
        case .ready(let document): placeholder = document.notice.map { InspectorPlaceholder(symbol: "curlybraces", title: $0) }
        }
        conversationHost.cover(placeholder); showContent(conversationHost)
    }
    private func banner(_ document: RequestDocument, row: InspectorRequestRow) -> NSView {
        if let delta = request.delta { return InspectorBanner(symbol: delta.rewritten ? "arrow.triangle.2.circlepath" : delta.first ? "sparkles" : "plus.circle", text: delta.banner(previous: delta.first ? nil : request.previousLabel, cachedShare: row.cachedShare), notes: delta.notes, tone: delta.rewritten ? .warning : .accent) }
        if let note = request.deltaNote { return InspectorBanner(symbol: "info.circle", text: "\(document.items.count) items, " + RequestDocument.charactersLabel(document.totalCharacters), notes: [note], tone: .neutral) }
        return InspectorFixedSize(inspectorRow([.view(PiKit.spinner(controlSize: .small)), .view(inspectorText("Comparing with " + (request.previousLabel ?? "the request before") + "…", color: .piInkTertiary), .flexible)], spacing: 6), width: 0, height: 34)
    }
    private func outlineContent(_ document: RequestDocument, row: InspectorRequestRow) -> InspectorOutlineContent {
        let delta = request.delta, grouped = delta.map { !$0.first } ?? false
        return InspectorOutlineContent(key: row.id + ":request:\(document.bytes)", sections: document.sections, items: document.items, shared: grouped ? delta?.shared : nil, marksNew: grouped, openLast: grouped ? min(delta?.added ?? 0, 8) : 2, summary: document.summary.map { InspectorSummaryHeading($0, label: inspector.summaryLabel(row.id)) })
    }

    /// Reads a request item's or section's whole text on the capture worker.
    static func wholeText(_ target: InspectorOutlineTarget, of document: RequestDocument) -> InspectorWholeText {
        switch target {
        case .item(let index): return { try document.fullText(item: index) }
        case .section(let kind): return { try document.fullText(section: kind) }
        case .instruction:
            // All of it, from the prompt: the heading keeps its first characters.
            let kept = document.summary?.instruction ?? ""
            guard let item = document.summary?.item else { return { kept } }
            return { try SummaryRequestInfo.read(prompt: document.fullText(item: item), limit: .max)?.instruction ?? kept }
        }
    }

    private func showResponse(_ row: InspectorRequestRow) {
        if events {
            let key = row.id + ":events"
            if eventKey != key {
                eventKey = key
                eventBody = CapturedBodyView(source: responseSource(row), sessionID: inspector.scope.sessionID, attemptID: row.id, kind: "response", retained: row.source != .live, initialFormat: .json, growingBytes: request.growingBytes)
            } else { eventBody?.update(growingBytes: request.growingBytes) }
            if let eventBody {
                if eventHost == nil { eventHost = InspectorInset(eventBody, insets: NSEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)) }
                eventHost?.insets = NSEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
                if let eventHost { showContent(eventHost) }
            }; return
        }
        let document = request.response.value
        responseOutline.update(content: document.map { InspectorOutlineContent(key: row.id + ":response:\(request.responseBytes)", sections: [], items: $0.items, shared: nil, marksNew: false, openLast: min($0.items.count, 6)) } ?? .empty) { target in
            guard let document, case .item(let index) = target else { return nil }; return { try document.fullText(item: index) }
        }
        if let document { summary = padded(responseSummary(document, row: row), top: 12, bottom: 8); addSubview(summary!) }
        let placeholder: NSView?
        switch request.response {
        case .idle: placeholder = InspectorPlaceholder(symbol: "sparkle", title: request.metadataLoaded ? "Preparing the response…" : "Reading the response…")
        case .loading(let loaded, let total): placeholder = InspectorPlaceholder(symbol: "sparkle", title: "Reading the response", message: total > 0 ? RequestDocument.byteLabel(loaded) + " of " + RequestDocument.byteLabel(total) : nil, progress: total > 0 ? Double(loaded) / Double(total) : nil)
        case .failed(let message): placeholder = InspectorPlaceholder(symbol: "exclamationmark.circle", title: row.running ? "No response yet" : "The response is not available", message: message)
        case .ready(let document): placeholder = document.items.isEmpty ? InspectorPlaceholder(symbol: "sparkle", title: "The response has no output items yet") : nil
        }
        responseHost.cover(placeholder); showContent(responseHost)
    }
    private func responseSummary(_ document: ResponseDocument, row: InspectorRequestRow) -> NSView {
        let streaming = row.running && document.partial
        let arrived = document.items.reduce(0) { $0 + $1.characters }
        var views: [NSView] = [InspectorBanner(symbol: document.partial ? "ellipsis.circle" : document.status == "completed" ? "checkmark.circle" : "exclamationmark.circle", text: streaming ? "Streaming · " + RequestDocument.charactersLabel(arrived) + " so far" : document.summary, notes: streaming ? [] : document.notice.map { [$0] } ?? [], tone: streaming ? .accent : document.status == "completed" && !document.partial ? .success : .warning)]
        if !document.usage.isEmpty { views.append(InspectorFigureStrip(figures: document.usage.map { InspectorFigure(label: $0.name, value: $0.value) })) }
        if let grown = request.growingBytes, grown > request.responseBytes {
            let button = PiKit.Button("Load latest", style: .secondary, compact: true) { [weak request] in request?.loadLatest() }; button.setAccessibilityIdentifier("inspector-load-latest")
            views.append(inspectorRow([.view(inspectorText(RequestDocument.byteLabel(grown) + " so far · showing the first " + RequestDocument.byteLabel(request.responseBytes), font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary), .flexible), .view(button)], spacing: 8))
        }
        return inspectorColumn(views, spacing: 8)
    }
    private func responseSource(_ row: InspectorRequestRow) -> CapturedBodySource {
        let state = request.metadata["response"]?.object?["state"]?.string ?? ""
        if row.source != .live, MessageBodyReader.canReadRetained(state) || inspector.workspace == nil { return .archive(inspector.archive, attemptID: row.id, kind: "response") }
        if let workspace = inspector.workspace { return .live(workspace, sessionID: inspector.scope.sessionID, attemptID: row.id, kind: "response") }
        return .archive(inspector.archive, attemptID: row.id, kind: "response")
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let header { let height = PiKit.height(of: header, width: bounds.width); header.frame = CGRect(x: 0, y: y, width: bounds.width, height: height); y += height }
        if let tabs { let height = PiKit.height(of: tabs, width: bounds.width); tabs.frame = CGRect(x: 0, y: y, width: bounds.width, height: height); y += height; rule.frame = CGRect(x: 0, y: y, width: bounds.width, height: 1); y += 1 }
        if let summary { let height = PiKit.height(of: summary, width: bounds.width); summary.frame = CGRect(x: 0, y: y, width: bounds.width, height: height); y += height }
        let horizontal: CGFloat = request.tab == .raw || events || shownRow?.source == .record ? 0 : compact ? PiSpacing.sm : PiSpacing.md
        content?.frame = CGRect(x: horizontal, y: y, width: max(0, bounds.width - 2 * horizontal), height: max(0, bounds.height - y))
    }
}
