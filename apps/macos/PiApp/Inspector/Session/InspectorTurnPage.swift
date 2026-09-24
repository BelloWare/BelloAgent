import SwiftUI

/// One turn: what was asked, how it ended, what it used, and every request it
/// made, including the ones only the replies recorded.
struct InspectorTurnPage: View {
    @ObservedObject var inspector: SessionInspectorModel
    let turnID: String
    let compact: Bool
    @StateObject private var prompt = InspectorPromptExpansion()
    private static let promptID = "inspector-turn-prompt"

    private var turn: InspectorTurn? { inspector.index.turn(turnID) }
    private var summary: TurnSummary? { inspector.summaries[turnID] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let turn {
                        header(turn)
                        if !turn.isOther {
                            // "Show less" at the foot of a long prompt brings the card back into view.
                            InspectorPromptCard(preview: inspector.prompts[turn.id], model: prompt, showAll: { showPrompt(turn.id) },
                                                folded: { DispatchQueue.main.async { proxy.scrollTo(Self.promptID, anchor: nil) } })
                                .id(Self.promptID)
                        }
                        usage(turn)
                        requests(turn)
                    } else {
                        InspectorPlaceholder(symbol: "text.bubble", title: "This turn has no retained requests",
                                             message: "Its requests may have expired from the request log, or capture was off.")
                    }
                }
                .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.vertical, PiSpacing.lg)
                .frame(maxWidth: 1_100, alignment: .leading)
            }
        }
        .onChange(of: turnID) { _, _ in prompt.collapse() }
        .onDisappear { prompt.collapse() }
        .accessibilityIdentifier("inspector-turn")
    }

    private func header(_ turn: InspectorTurn) -> some View {
        let outcome = summary.map(TurnInfoPresentation.outcome) ?? (turn.running ? "In progress" : turn.requests.contains(where: \.failed) ? "Some requests failed" : "Completed")
        var parts: [String] = []
        if let started = turn.started { parts.append("Started " + Date(timeIntervalSince1970: started).formatted(date: .omitted, time: .standard)) }
        if let elapsed = summary?.elapsedMs ?? turn.span { parts.append(SessionStatsFormat.duration(elapsed)) }
        parts.append(turn.summary)
        let tone: PiTone = turn.running ? .warning : outcome == "Completed" ? .success : .warning
        return InspectorPageHeader(turn.isOther ? "Other requests" : "Turn \(turn.number)", subtitle: parts.joined(separator: " · ")) {
            if !turn.isOther { PiBadge(text: outcome, tone: tone, dot: true) }
        } actions: {
            InspectorShowInChat { inspector.showInChat() }
        }
    }

    /// The whole prompt, in the card, read from the chat's journal.
    private func showPrompt(_ id: String) {
        guard let workspace = inspector.workspace else { return }
        let sessionID = inspector.scope.sessionID
        prompt.show {
            var text = "", offset = 0, total = 0
            repeat {
                let page = try await workspace.messagePage(id: id, field: "text", offset: offset, sessionID: sessionID)
                text += page.0; offset += (page.0 as NSString).length; total = max(total, page.1)
                if page.0.isEmpty { break }
                if offset >= page.1 { break }
            } while offset < InspectorPromptExpansion.readLimit
            return (text, offset, total)
        }
    }

    /// Input and output of the whole turn, split as the turn report splits them.
    private func usage(_ turn: InspectorTurn) -> some View {
        let accounting = summary?.accounting ?? turn.accounting
        let running = turn.running
        return PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 10) {
                // Input and output as the turn report splits them; the clocks
                // are in the header and the figures below, rounded to read.
                HStack(alignment: .top, spacing: 24) {
                    TurnTokenBar(partition: TurnTokenPartition(accounting, input: true, running: running)).frame(maxWidth: .infinity, alignment: .leading)
                    TurnTokenBar(partition: TurnTokenPartition(accounting, input: false, running: running)).frame(maxWidth: .infinity, alignment: .leading)
                }
                InspectorFigureStrip(figures: turnFigures(accounting))
                if let summary, let notice = TurnInfoPresentation.coverageNotice(summary) {
                    Text(notice).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = summary?.notice, !notice.isEmpty {
                    Text(notice).font(PiFont.caption).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("inspector-turn-usage")
    }

    private func turnFigures(_ a: TurnAccounting) -> [InspectorFigure] {
        var figures: [InspectorFigure] = []
        if let cost = a.costUSD { figures.append(InspectorFigure(label: "Cost", value: compactGatewayUSD(cost), detail: a.costSamples < a.requests ? "(\(a.costSamples)/\(a.requests))" : nil)) }
        if let summary {
            if summary.modelMs > 0 { figures.append(InspectorFigure(label: "Model", value: SessionStatsFormat.duration(summary.modelMs))) }
            if summary.toolMs > 0 { figures.append(InspectorFigure(label: "Tools", value: SessionStatsFormat.duration(summary.toolMs))) }
            figures.append(InspectorFigure(label: "Replies", value: "\(summary.replies)"))
            if summary.tools > 0 { figures.append(InspectorFigure(label: "Tool calls", value: "\(summary.tools)")) }
            if summary.files > 0 { figures.append(InspectorFigure(label: "Files changed", value: "\(summary.files)")) }
        }
        if let rate = a.throughput.tokensPerSecond { figures.append(InspectorFigure(label: "Speed", value: MetricFormat.throughput(rate))) }
        return figures
    }

    /// Every request of the turn, in order: a click opens it.
    private func requests(_ turn: InspectorTurn) -> some View {
        let lines = turn.requests.map(TurnRequestLine.init(row:))
        let subtotals = TurnInfoPresentation.subtotals(lines)
        let models = Set(lines.compactMap(\.model)).count
        return VStack(alignment: .leading, spacing: 8) {
            InspectorSectionTitle("Requests", subtitle: "\(turn.requests.count) in this turn" + (models > 1 ? " · \(models) models" : "") + " · a row opens its request")
            PiCard(padding: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turn.requests.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 { Rectangle().fill(Color.piHairline).frame(height: 1).padding(.horizontal, 8) }
                        InspectorTurnRequestRow(row: row, line: lines[offset], number: offset + 1, kind: inspector.index.kind(of: row.id), compact: compact) {
                            inspector.select(.request(row.id))
                        }
                    }
                    if subtotals.count > 1 {
                        Rectangle().fill(Color.piHairline).frame(height: 1).padding(.horizontal, 8)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(subtotals) { subtotal in
                                Text(TurnInfoPresentation.subtotalLabel(subtotal)).font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .accessibilityIdentifier("inspector-turn-subtotals")
                    }
                }
            }
        }
        .accessibilityIdentifier("inspector-turn-requests")
    }
}

/// A request in a turn's table: number, kind, route, tokens, cost, time.
private struct InspectorTurnRequestRow: View {
    let row: InspectorRequestRow
    let line: TurnRequestLine
    let number: Int
    let kind: String
    let compact: Bool
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                InspectorStatusMark(outcome: row.outcome)
                Text("\(number)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Color.piInkSecondary).frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.prefix(1).uppercased() + kind.dropFirst()).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk)
                    Text(TurnInfoPresentation.routeLabel(line)).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let flow = row.tokenFlow {
                    Text(flow).font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).fixedSize()
                } else {
                    Text(missing).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize()
                }
                if !compact {
                    Text(row.cost.map(compactGatewayUSD) ?? "—").font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).frame(width: 74, alignment: .trailing)
                    Text((row.duration ?? row.http).map(SessionStatsFormat.duration) ?? "—").font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary).frame(width: 58, alignment: .trailing)
                }
                Text(source).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).frame(width: compact ? 86 : 124, alignment: .trailing).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hovering ? Color.piFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .onHover { hovering = $0 }
        .accessibilityLabel("Request \(number), \(kind), \(row.route.label), " + (row.tokenFlow ?? missing))
        .accessibilityIdentifier("inspector-turn-request")
    }
    private var missing: String { TurnInfoPresentation.lineFigures(line) }
    private var source: String { TurnInfoPresentation.lineSource(line) }
}

/// A turn's prompt read whole, for its card; nil while the card shows the
/// preview.
@MainActor final class InspectorPromptExpansion: ObservableObject {
    /// The most of a prompt read from the journal; the card says when a
    /// prompt is longer.
    static let readLimit = 8_388_608
    @Published private(set) var expansion: InspectorExpansion?

    func show(read: @escaping @MainActor () async throws -> (text: String, length: Int, total: Int)) {
        guard expansion == nil else { return }
        let expansion = InspectorExpansion(title: "Prompt", style: InspectorTextStyle(face: .body))
        expansion.showLess = { [weak self] in self?.collapse() }
        self.expansion = expansion
        expansion.load(read)
    }
    func collapse() {
        guard let expansion else { return }
        expansion.cancel()
        self.expansion = nil
    }
}

/// The prompt as the reader wrote it: its first lines, or all of it in place,
/// selectable, with "Show less" to fold it again.
struct InspectorPromptCard: View {
    let preview: String?
    @ObservedObject var model: InspectorPromptExpansion
    let showAll: () -> Void
    /// After "Show less" at the foot of the card.
    var folded: () -> Void = {}

    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInfo)
                    Text("Prompt").font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInkSecondary)
                    Spacer(minLength: 0)
                    Button(model.expansion == nil ? "Show all" : "Show less") {
                        if model.expansion == nil { showAll() } else { model.collapse() }
                    }
                    .buttonStyle(.piGhost).disabled(model.expansion == nil && (preview?.isEmpty ?? true))
                    .accessibilityIdentifier("inspector-prompt-toggle")
                }
                if let expansion = model.expansion {
                    InspectorPromptWhole(expansion: expansion, preview: preview) { model.collapse(); folded() }
                } else if let preview, !preview.isEmpty {
                    InspectorPromptPreview(text: preview)
                } else {
                    Text(preview == nil ? "Reading the prompt…" : "The prompt's text was not retained.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
            }
        }
        .accessibilityIdentifier("inspector-turn-prompt")
    }
}

private struct InspectorPromptPreview: View {
    let text: String
    var body: some View {
        Text(text).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(8).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole prompt: the preview until the text is laid out, then the text,
/// what of it is shown when it is long, and "Show less" at its foot.
private struct InspectorPromptWhole: View {
    @ObservedObject var expansion: InspectorExpansion
    let preview: String?
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                InspectorTextBlock(expansion: expansion)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if expansion.layout == nil, let preview, !preview.isEmpty { InspectorPromptPreview(text: preview) }
            }
            switch expansion.phase {
            case .loading:
                HStack(spacing: 6) {
                    PiSpinner(size: 11)
                    Text(expansion.loaded ? "Laying out the whole prompt…" : "Reading the whole prompt…").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
            case .failed(let message):
                Text("The whole prompt could not be read: " + message).font(PiFont.caption).foregroundStyle(Color.piWarning)
                    .fixedSize(horizontal: false, vertical: true)
            case .shown:
                EmptyView()
            }
            if expansion.capped {
                HStack(spacing: 8) {
                    Text("Showing the first \(MetricFormat.tokens(Double(expansion.shown))) of \(MetricFormat.tokens(Double(expansion.length))) characters")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    Button(expansion.laying ? "Laying out…" : "Show \(MetricFormat.tokens(Double(expansion.nextStep))) more") { expansion.reveal() }
                        .buttonStyle(.piGhost).disabled(expansion.laying)
                        .accessibilityIdentifier("inspector-prompt-reveal")
                }
            }
            if expansion.loaded, expansion.total > expansion.length {
                Text("The first \(MetricFormat.tokens(Double(expansion.length))) of the prompt's \(MetricFormat.tokens(Double(expansion.total))) characters were read.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
            }
            if (expansion.layout?.height ?? 0) > 320 {
                Button("Show less", action: collapse).buttonStyle(.piGhost).accessibilityIdentifier("inspector-prompt-less")
            }
        }
    }
}
