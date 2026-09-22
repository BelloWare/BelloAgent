import SwiftUI
import AppKit

/// Render the same reported observations inline, in the live dock, and in its
/// details table. Missing reports stay distinct from a reported zero.
enum TurnInfoPresentation {
    static func workingLabel(_ turn: TurnSummary, state: String = "running") -> String {
        switch state == "stopping" ? "stopping" : turn.phase ?? state {
        case "queued", "preparing": return "Preparing response…"
        case "stopping": return "Stopping…"
        case "compacting": return "Compacting context…"
        case "retrying": return "Waiting to retry…"
        case "tools": return "Running " + (turn.current?.name ?? "tools") + "…"
        case "model": return "Generating response…"
        default: return "Reconciling task status…"
        }
    }
    static func live(_ turn: TurnSummary, at date: Date, uptimeMs: Double = ProcessInfo.processInfo.systemUptime * 1000) -> TurnSummary {
        guard turn.live else { return turn }
        var current = turn
        if let start = turn.liveStartedUptimeMs { current.elapsedMs = DurationObservation.valid(uptimeMs - start) }
        else if let start = turn.startedAt { current.elapsedMs = DurationObservation.valid(date.timeIntervalSince1970 * 1000 - start) }
        return current
    }
    struct Row: Identifiable, Equatable {
        var name: String
        var value: String
        var coverage = ""
        var id: String { name }
    }
    static func outcome(_ turn: TurnSummary) -> String {
        switch turn.outcome {
        case "completed": return "Completed"
        case "cancelled": return "Stopped"
        case "output-limited": return "Output limit reached"
        case .some(let value): return value.capitalized
        case nil: return turn.live ? "In progress" : "Outcome unavailable"
        }
    }
    static func tokenLabel(_ turn: TurnSummary) -> String {
        TranscriptActivity.tokens(of:turn.accounting).map(TranscriptActivity.formatTokenCount) ?? (turn.live ? "Pending" : "Unreported")
    }
    static func costLabel(_ turn: TurnSummary) -> String {
        guard let cost = turn.accounting.costUSD, cost.isFinite, cost >= 0 else { return turn.live ? "Pending" : "Unreported" }
        return "$" + MetricFormat.preciseDecimal(cost)
    }
    static func inlineFigures(_ turn: TurnSummary) -> [String] {
        var parts = ["\(tokenLabel(turn)) tokens", "Cost \(costLabel(turn))"]
        let a = turn.accounting
        func add(_ value: Double?, _ label: String, _ samples: Int) {
            if let value { parts.append("\(label) \(TranscriptActivity.formatTokenCount(value))" + (samples < a.requests ? " (\(samples)/\(a.requests))" : "")) }
        }
        add(a.input,"In",a.inputSamples); add(a.output,"Out",a.outputSamples)
        add(a.cached,"Cached",a.cachedSamples); add(a.reasoning,"Reasoning",a.reasoningSamples)
        if a.costSamples > 0 && a.costSamples < a.requests { parts[1] += " (\(a.costSamples)/\(a.requests) reported)" }
        if turn.modelMs > 0 { parts.append("Model " + TranscriptActivity.formatDuration(turn.modelMs)) }
        if turn.toolMs > 0 { parts.append("Tools " + TranscriptActivity.formatDuration(turn.toolMs)) }
        if let model = a.model { parts.append(model) }
        if turn.partial { parts.append("Partial history") }
        return parts
    }
    static func rows(_ turn: TurnSummary) -> [Row] {
        var rows = [Row(name:"Status",value:outcome(turn)), Row(name:"Replies / tool calls",value:"\(turn.replies) / \(turn.tools)"),
                    Row(name:"Files changed",value:String(turn.files))]
        if let start = turn.startedAt { rows.append(Row(name:"Started",value:TranscriptActivity.formatClock(start))) }
        if let end = turn.endedAt { rows.append(Row(name:"Finished",value:TranscriptActivity.formatClock(end))) }
        rows.append(Row(name:"Duration",value:turn.elapsedMs.map(TranscriptActivity.formatDuration) ?? (turn.live ? "In progress" : "Unavailable")))
        rows.append(Row(name:"Model request time",value:TranscriptActivity.formatDuration(turn.modelMs)))
        rows.append(Row(name:"Tool time",value:TranscriptActivity.formatDuration(turn.toolMs)))
        rows += usageRows(turn.accounting)
        return rows
    }
    static func usageRows(_ a: TurnAccounting) -> [Row] {
        func observation(_ name: String, _ value: Double?, _ samples: Int, cost: Bool = false) -> Row {
            Row(name:name, value:value.map { cost ? gatewayUSD($0) : TranscriptActivity.grouped($0) } ?? "Unreported",
                coverage:"\(samples)/\(a.requests) requests")
        }
        return [
            Row(name:"Requests with records",value:String(a.requests)),
            observation("Total tokens",a.total,a.totalSamples),
            observation("Input tokens",a.input,a.inputSamples),
            observation("Cached input tokens",a.cached,a.cachedSamples),
            observation("Uncached input tokens",a.uncached,a.uncachedSamples),
            observation("Cache-write tokens",a.cacheWrite,a.cacheWriteSamples),
            observation("Output tokens",a.output,a.outputSamples),
            observation("Reasoning tokens (in output)",a.reasoning,a.reasoningSamples),
            observation("Total cost",a.costUSD,a.costSamples,cost:true),
            observation("Reasoning cost (in total)",a.reasoningCostUSD,a.reasoningCostSamples,cost:true),
            Row(name:"Response cache",value:"\(a.cacheHits) hit · \(a.cacheMisses) miss · \(a.cacheUnreported) unreported · \(a.cacheConflicts) invalid/conflicting"),
            Row(name:"Requested models",value:a.requestedModels.isEmpty ? "Unreported" : a.requestedModels.joined(separator: ", ")),
            Row(name:"Response models",value:a.reportedModels.isEmpty ? "Unreported" : a.reportedModels.joined(separator: ", ")),
            Row(name:"Model routes",value:a.modelRoutes.isEmpty ? "Unreported" : a.modelRoutes.map(\.label).joined(separator: "\n"))
        ]
    }
}

/// Own the payload popover at the AppKit boundary. SwiftUI's popover sizing
/// can feed back into a virtualized transcript row's NSHostingView when the
/// asynchronous body arrives, repeatedly updating window constraints. An
/// explicitly sized popover keeps payload layout independent of that row.
struct TurnInfoButton: NSViewRepresentable {
    let turn: TurnSummary
    let actions: TranscriptActions
    func makeCoordinator() -> Coordinator { Coordinator(turn: turn, actions: actions) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Show turn info")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.target = context.coordinator; button.action = #selector(Coordinator.toggle(_:))
        button.isBordered = false; button.imagePosition = .imageOnly; button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "Show turn info"; button.setAccessibilityLabel("Show turn info")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.update(turn: turn, actions: actions) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 20, height: 20) }
    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) {
        // Teardown publishes the body reader's final state. Do not trigger it
        // from inside SwiftUI's dismantling transaction.
        DispatchQueue.main.async { coordinator.close() }
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        private var turn: TurnSummary
        private var actions: TranscriptActions
        private(set) var popover: NSPopover?
        private var content: NSHostingController<TurnInfoView>?
        init(turn: TurnSummary, actions: TranscriptActions) { self.turn = turn; self.actions = actions }
        func update(turn: TurnSummary, actions: TranscriptActions) {
            self.actions = actions
            guard self.turn != turn else { return }
            self.turn = turn
            if content != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let content = self.content else { return }
                    content.rootView = self.rootView()
                }
            }
        }
        private func rootView() -> TurnInfoView {
            TurnInfoView(turn: turn, actions: actions, close: { [weak self] in self?.close() })
        }
        @objc func toggle(_ button: NSButton) {
            if popover?.isShown == true { close(); return }
            let popup = NSPopover(), content = NSHostingController(rootView: rootView())
            popup.behavior = .transient; popup.animates = true; popup.delegate = self
            popup.contentViewController = content; popup.contentSize = NSSize(width: 680, height: 640)
            self.popover = popup; self.content = content
            popup.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            content.view.window?.title = "Turn details"
            content.view.window?.makeKey()
        }
        func close() { popover?.close(); popover = nil; content = nil }
        func popoverDidClose(_ notification: Notification) {
            // AppKit can close the popup while SwiftUI removes its anchor at
            // turn completion. Release its observed content after that update.
            let closed = notification.object as? NSPopover
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover === closed else { return }
                self.popover = nil; self.content = nil
            }
        }
    }
}

/// Opened lazily over the report. One request at a time, using the same body
/// viewer as the inspector; the transcript never loads payloads while closed.
struct TurnInfoView: View {
    let turn: TurnSummary
    let actions: TranscriptActions
    var close: (() -> Void)? = nil
    @StateObject private var controller = TurnRequestController()
    @State private var tab = "response"
    @State private var query = ""
    @State private var headersOpen = false
    @State private var copySource: CapturedBodyCopySource?
    @State private var onScreen = true
    @State private var copyNotice = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(turn: TurnSummary, actions: TranscriptActions, close: (() -> Void)? = nil, initialTab: String = "response", initialQuery: String = "") {
        self.turn = turn; self.actions = actions; self.close = close
        _tab = State(initialValue: initialTab); _query = State(initialValue: initialQuery)
    }
    private struct Refresh: Equatable { let scope: TurnRequestScope; let live: Bool }
    private var refresh: Refresh { Refresh(scope: TurnRequestScope(turn), live: turn.live) }
    private var source: TurnRequestSource? { actions.turnRequestSource?() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Turn details").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { copyTurn() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.piGhost).help("Copy Turn Info").accessibilityLabel("Copy Turn Info")
                Button { if let close { close() } else { dismiss() } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.piGhost).help("Close turn details").accessibilityLabel("Close turn details")
                    .keyboardShortcut(.cancelAction)
            }
            overview
            if let notice = turn.notice, !notice.isEmpty {
                Text(notice).font(PiFont.caption).foregroundStyle(Color.piWarning).textSelection(.enabled)
            }
            if let record = controller.selected, let source {
                requestPicker(record)
                HStack(spacing: 12) {
                    PiTabs(selection: $tab, items: [("request", "Request"), ("response", "Response")])
                        .accessibilityIdentifier("turn-payload-tabs")
                        .help("Request: ⌘1 · Response: ⌘2")
                    Spacer(minLength: 12)
                    searchField
                }
                requestStatus(record)
                if query.isEmpty {
                    DisclosureGroup(isExpanded: $headersOpen) {
                        CapturedHeadersView(headers: record.metadata[tab + "Headers"]?.object ?? [:])
                            .padding(.top, 5)
                    } label: {
                        Text("Headers · \(record.metadata[tab + "Headers"]?.object?.count ?? 0)")
                            .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }.accessibilityIdentifier("turn-payload-headers")
                }
                GeometryReader { bounds in
                    CapturedBodyView(source: source.body(record, tab), sessionID: record.sessionID, attemptID: record.id,
                                     kind: tab, retained: record.retained(tab), revision: record.revision(tab),
                                     copySource: $copySource, initialFormat: tab == "response" ? .combined : .json,
                                     searchQuery: query, searchHeaders: record.metadata[tab + "Headers"]?.object ?? [:])
                        .id(record.id + ":" + tab)
                        .frame(width: bounds.size.width, height: bounds.size.height)
                }
                HStack {
                    Text(turn.live ? "Turn in progress · reported usage so far"
                         : "\(turn.replies) \(turn.replies == 1 ? "reply" : "replies") · \(turn.tools) \(turn.tools == 1 ? "tool call" : "tool calls")")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    Spacer()
                    Button { copyBody() } label: { Label(query.isEmpty ? "Copy view" : "Copy body", systemImage: "doc.on.doc") }
                        .buttonStyle(.piGhost).disabled(copySource == nil)
                }
            } else {
                VStack(spacing: 10) {
                    if controller.loading { ProgressView().controlSize(.small) }
                    Text(controller.loading ? "Loading this turn’s requests…" : "No captured requests for this turn")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    if !controller.loading { Text("Usage remains available above. Request bodies may have expired or capture may have been off.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary).multilineTextAlignment(.center) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !controller.notice.isEmpty { Text(controller.notice).font(PiFont.caption).foregroundStyle(Color.piWarning).textSelection(.enabled) }
            if !copyNotice.isEmpty { Text(copyNotice).font(PiFont.micro).foregroundStyle(Color.piInkSecondary) }
        }
        .padding(16).frame(width: 680, height: 640)
        .background(Color.piSurface).foregroundStyle(Color.piInk)
        .accessibilityIdentifier("turn-details-popup")
        .piWindowVisibility { onScreen = $0 }
        .background {
            VStack {
                Button("Find in turn details") { searchFocused = true }.keyboardShortcut("f")
                Button("Show request") { tab = "request" }.keyboardShortcut("1")
                Button("Show response") { tab = "response" }.keyboardShortcut("2")
            }.hidden()
        }
        .task(id: refresh) {
            guard let source else { return }
            await controller.load(refresh.scope, source: source)
            while turn.live && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if onScreen { await controller.load(refresh.scope, source: source) }
            }
        }
        .onDisappear { controller.cancel() }
        .onChange(of: controller.selectedID) { _, _ in copySource = nil; copyNotice = "" }
        .onChange(of: tab) { _, _ in copySource = nil; copyNotice = "" }
    }

    @ViewBuilder private var overview: some View {
        if turn.live {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                CompactTurnReport(turn: TurnInfoPresentation.live(turn, at: clock.date),
                                  status: TurnInfoPresentation.workingLabel(turn), showsInfo: false)
            }
        } else { CompactTurnReport(turn: turn, showsInfo: false) }
    }

    private func requestPicker(_ record: TurnRequestRecord) -> some View {
        HStack(spacing: 6) {
            Text(record.endpoint).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).textSelection(.enabled)
            Spacer(minLength: 8)
            Button { controller.move(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.piGhost).disabled((controller.index ?? 0) == 0).help("Previous request")
                .accessibilityLabel("Previous request")
            PiDropdown(selection: $controller.selectedID,
                       items: controller.records.enumerated().map { ($0.element.id, "Request \($0.offset + 1) of \(controller.records.count) · \($0.element.purpose)") },
                       placeholder: "Select request", compact: true)
                .frame(width: 205).accessibilityIdentifier("turn-request-picker")
            Button { controller.move(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.piGhost).disabled((controller.index ?? 0) >= controller.records.count - 1).help("Next request")
                .accessibilityLabel("Next request")
            Button { if let source { Task { await controller.load(refresh.scope, source: source) } } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.piGhost).disabled(controller.loading).help("Refresh captured request")
                .accessibilityLabel("Refresh captured request")
        }
    }
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.piInkTertiary)
            TextField("Search body and headers", text: $query).textFieldStyle(.plain)
                .focused($searchFocused).accessibilityIdentifier("turn-payload-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear payload search")
            }
        }.font(PiFont.caption).padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.piFill, in: RoundedRectangle(cornerRadius: 7)).frame(width: 285)
    }
    private func requestStatus(_ record: TurnRequestRecord) -> some View {
        let metrics = record.metadata["metrics"]?.object ?? [:]
        let status = record.metadata["status"]?.nonnegativeInteger
        return HStack(spacing: 8) {
            if let status { PiBadge(text: "HTTP \(status)", tone: status >= 400 ? .danger : .success) }
            if record.running {
                PiShimmerText(text: (record.metadata["response"]?.object?["observedBytes"]?.number ?? 0) == 0 ? "Awaiting response…"
                              : (record.metadata["responseHeaders"]?.object?["content-type"]?.string ?? "").contains("event-stream") ? "Streaming…" : "Receiving response…", size: 11)
            }
            else { Text((record.metadata["outcome"]?.string ?? "unreported").capitalized) }
            if let time = DurationObservation.valid(metrics["httpDurationMs"]?.number) { Text(MetricFormat.detailedDuration(time)).monospacedDigit() }
            if let ttft = DurationObservation.valid(metrics["observedTTFTms"]?.number) { Text("TTFT " + MetricFormat.detailedDuration(ttft)).monospacedDigit() }
            Spacer(minLength: 0)
            Text(record.route).lineLimit(1).truncationMode(.middle).help(record.route)
        }.font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
    }
    private func copyTurn() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TurnLineView.copyText(turn), forType: .string)
    }
    private func copyBody() {
        guard let copySource else { return }
        let id = controller.selectedID, kind = tab
        Task {
            do {
                let text = try await copySource.render()
                guard controller.selectedID == id, tab == kind else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copyNotice = "Copied \(kind) view."
            } catch { copyNotice = error.localizedDescription }
        }
    }
}
