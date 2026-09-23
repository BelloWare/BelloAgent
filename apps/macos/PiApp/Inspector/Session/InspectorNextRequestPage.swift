import SwiftUI

/// What the model receives next: the helper's prepared request, read like any
/// request, with how full the context is, the budgets and the draft.
struct InspectorNextRequestPage: View {
    @ObservedObject var inspector: SessionInspectorModel
    @ObservedObject var next: NextRequestModel
    let compact: Bool
    @StateObject private var full = InspectorFullText()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                InspectorPageHeader("Next request", subtitle: "As the helper would send it now, with your draft. Nothing is sent to the model.") {
                    EmptyView()
                } actions: {
                    PiIconButton(symbol: "arrow.clockwise", label: "Prepare it again", size: 26) {
                        let latest = inspector.index.latestRequestID.flatMap(inspector.index.request)
                        next.refresh(previous: latest, previousLabel: latest.map { inspector.label(of: $0, from: nil) })
                    }
                    InspectorShowInChat { inspector.showInChat() }
                }
                if let display = inspector.display { InspectorContextSummary(workspace: inspector.workspace, display: display, preview: next.summary) }
            }
            .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.top, PiSpacing.lg).padding(.bottom, PiSpacing.sm)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            content
            InspectorFullTextPane(full: full)
        }
        .accessibilityIdentifier("inspector-next-request")
    }

    @ViewBuilder private var content: some View {
        switch next.document {
        case .idle:
            InspectorPlaceholder(symbol: "square.stack.3d.up", title: "Preparing the next request…")
        case .loading(let loaded, let total):
            InspectorPlaceholder(symbol: "square.stack.3d.up", title: "Preparing the next request",
                                 message: total > 0 ? RequestDocument.charactersLabel(loaded) + " of " + RequestDocument.charactersLabel(total) : nil,
                                 progress: total > 0 ? Double(loaded) / Double(total) : nil)
        case .failed(let message):
            InspectorPlaceholder(symbol: "exclamationmark.circle", title: "The next request could not be prepared", message: message)
        case .ready(let document):
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let delta = next.delta {
                        InspectorBanner(symbol: delta.rewritten ? "arrow.triangle.2.circlepath" : "plus.circle",
                                        text: delta.banner(previous: delta.first ? nil : next.previousLabel, cachedShare: nil), notes: delta.notes,
                                        tone: delta.rewritten ? .warning : .accent)
                    } else if let note = next.deltaNote {
                        InspectorBanner(symbol: "info.circle", text: "\(document.items.count) items, " + RequestDocument.charactersLabel(document.totalCharacters), notes: [note], tone: .neutral)
                    }
                }
                .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.top, 12).padding(.bottom, 8)
                let grouped = next.delta.map { !$0.first } ?? false
                InspectorItemsOutline(content: InspectorOutlineContent(key: "next:\(document.bytes):\(document.items.count)", sections: document.sections, items: document.items,
                                                                       shared: grouped ? next.delta?.shared : nil, marksNew: grouped,
                                                                       openLast: grouped ? min(next.delta?.added ?? 0, 8) : 2)) { target, title in
                    switch target {
                    case .item(let index): full.open(title: title, render: { try document.fullText(item: index) })
                    case .section(let kind): full.open(title: title, render: { try document.fullText(section: kind) })
                    }
                }
                .padding(.horizontal, compact ? PiSpacing.sm : PiSpacing.md)
            }
        }
    }
}

/// How full the context is and how it was counted, the budgets, and the
/// draft's rough size: what the footer's details panel used to hold.
private struct InspectorContextSummary: View {
    weak var workspace: WorkspaceModel?
    @ObservedObject var display: SessionDisplay
    @ObservedObject var draft: ComposerDraft
    let preview: [String: WireValue]
    init(workspace: WorkspaceModel?, display: SessionDisplay, preview: [String: WireValue]) {
        self.workspace = workspace; self.display = display; self.draft = display.composerDraft; self.preview = preview
    }
    private var meter: ContextMeterPresentation {
        ContextMeterPresentation(context: PreparedContextMetrics.context(from: preview) ?? workspace?.displayedContext(display) ?? display.context)
    }
    var body: some View {
        let meter = meter
        HStack(alignment: .top, spacing: 18) {
            HStack(spacing: 10) {
                ContextRing(fraction: meter.fraction, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meter.fraction.flatMap(MetricFormat.occupancyPercent).map { $0 + "% of the context" } ?? meter.compactLabel)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.piInk)
                    Text(meter.compactFigures + " · " + meter.methodLabel + (meter.estimated ? " · estimated" : ""))
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
                }
            }
            .help(meter.detailLabel)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(meter.budgetParts, id: \.name) { part in
                    HStack(spacing: 6) {
                        Text(part.name).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        Text(part.value).font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                Text("≈\(max(0, (draft.text as NSString).length / 4)) tokens").font(PiFont.caption).monospacedDigit().foregroundStyle(Color.piInkSecondary)
                    .help("Characters ÷ 4: a rough size, not the context count")
            }
            Spacer(minLength: 0)
        }
        .padding(PiSpacing.md)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .accessibilityIdentifier("inspector-context-summary")
    }
}
