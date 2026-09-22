import SwiftUI

// The rows and cells of the report's grids, split out of `ReportPage.swift`.
// The types the page itself places are internal because the page is now a
// sibling file; the cells only these rows build stay private to this one.

/// Column widths shared by the header and rows of the request grid.
enum ReportColumns {
    static let started: CGFloat = 112
    static let session: CGFloat = 150
    static let status: CGFloat = 96
    static let cost: CGFloat = 128
    static let tokens: CGFloat = 150
    /// Extra leading inset for requests listed under their session.
    static let nestedIndent: CGFloat = 32
    static let duration: CGFloat = 78
    static let cache: CGFloat = 116
    static let widths: [CGFloat?] = [started, session, nil, status, cost, tokens, duration, cache]
    static let sessionWidths: [CGFloat?] = [started, nil, 112, cost, tokens, 96, 110, 132]
    static let modelRequests: CGFloat = 132
    static let modelRate: CGFloat = 116
    static let modelFirstToken: CGFloat = 176
    static let modelWidths: [CGFloat?] = [nil, modelRequests, cost, tokens, 96, modelRate, modelFirstToken]
}

/// Row cost without the currency suffix; the column header and help text carry the unit.
private func reportUSD(_ value: Double?) -> String {
    guard value != nil else { return "—" }
    return gatewayUSD(value).replacingOccurrences(of: " USD", with: "")
}

/// Short token counts for tiles and rows: 1.2k, 340k, 2.1M.
func reportTokens(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1000) }
    return String(format: "%.0f", value)
}

/// Reasoning is a reported subset of output and cost, never a second charge.
func reportReasoningDetail(_ totals: GatewayTotals) -> String {
    "Reasoning \(reportTokens(totals.tokens?.reasoning)) tokens (\(totals.tokens?.reasoningSamples ?? 0)/\(totals.requests) reported) are counted within output. Reasoning cost \(gatewayUSD(totals.reasoningCostUSD)) (\(totals.reasoningCostSamples ?? 0)/\(totals.requests) reported) is the gateway's reported share and is never added to the total; the two are summed over different requests."
}

struct ReportGridRow: View {
    let cells: [String]
    var header = false
    var widths: [CGFloat?] = ReportColumns.widths
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let width = widths[index]
                Text(cell).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).lineLimit(1)
                    .frame(width: width, alignment: .leading).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
        }.padding(.horizontal, PiSpacing.md).padding(.vertical, 8).background(Color.piSurfaceSunken)
    }
}

struct ReportRequestRow: View {
    let item: DashboardRequest
    let title: String?
    let detailed: Bool
    let inspect: () -> Void
    var message: () -> Void = {}
    var nested = false
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    private var tone: PiTone { item.outcome == "completed" ? .success : item.outcome == "failed" ? .danger : item.outcome == "running" ? .warning : .neutral }
    private func tokens(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private var purpose: String { (item.api == "openai-responses" ? "Responses" : "Messages") + " · " + item.purpose }
    var body: some View {
        Button(action: inspect) {
            HStack(spacing: PiSpacing.sm) {
                Text(item.wall, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary).frame(width: ReportColumns.started, alignment: .leading)
                if nested {
                    // The parent session row already names the chat; keep the
                    // remaining columns aligned with the top-level request grid.
                    Text(purpose).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1)
                        .frame(width: ReportColumns.session - ReportColumns.nestedIndent, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        if let title, !title.isEmpty { Text(title).font(PiFont.caption).foregroundStyle(Color.piInk) }
                        else { Text(String(item.sessionID.prefix(8)) + "…").font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                        Text(purpose).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                    }
                    .lineLimit(1).truncationMode(.middle).frame(width: ReportColumns.session, alignment: .leading)
                    .help("Session " + item.sessionID + (title == nil ? " (no chat title known)" : ""))
                }
                ModelRouteCell(requested: item.alias, final: item.effectiveModel, reported: item.reportedModels, status: item.identityStatus).frame(maxWidth: .infinity, alignment: .leading)
                PiBadge(text: item.outcome, tone: tone, dot: true).frame(width: ReportColumns.status, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.gateway.costUSD == nil ? item.gateway.costStatus : reportUSD(item.gateway.costUSD)).foregroundStyle(Color.piInk)
                    if detailed { Text("reasoning " + reportUSD(item.gateway.reasoningCostUSD)).foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.cost, alignment: .leading)
                    .help("LiteLLM-reported USD cost (\(item.gateway.costStatus)); includes reasoning \(gatewayUSD(item.gateway.reasoningCostUSD)) (\(item.gateway.reasoningCostStatus)). Provider prompt-cache tokens read \(tokens(item.gateway.cacheReadTokens)), write \(tokens(item.gateway.cacheWriteTokens)).")
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.gateway.inputTokens == nil && item.gateway.outputTokens == nil ? "—" : "↓\(reportTokens(item.gateway.inputTokens)) ↑\(reportTokens(item.gateway.outputTokens))").foregroundStyle(Color.piInk)
                    if item.gateway.reasoningTokens != nil { Text("\(reportTokens(item.gateway.reasoningTokens)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(item.gateway.cacheReadTokens)) · uncached \(reportTokens(item.gateway.uncachedInputTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help("Input \(tokens(item.gateway.inputTokens)) tokens (cached \(tokens(item.gateway.cacheReadTokens)), not cached \(tokens(item.gateway.uncachedInputTokens))) · output \(tokens(item.gateway.outputTokens)) tokens including \(tokens(item.gateway.reasoningTokens)) reasoning tokens, as reported by the gateway. Reasoning is not added again.")
                VStack(alignment: .leading, spacing: 1) {
                    Text(ms(item.http)).foregroundStyle(Color.piInk)
                    if detailed { Text("ttft \(ms(item.ttft))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.duration, alignment: .leading)
                    .help("Whole request \(ms(item.http)) · first token \(ms(item.ttft)) · streaming \(ms(item.streaming))")
                HStack(spacing: 4) {
                    DashboardCacheBadge(status: item.gateway.cacheStatus)
                    Spacer(minLength: 0)
                    PiIconButton(symbol: "text.bubble", label: "Go to the linked message", size: 22, action: message).opacity(hovering ? 1 : 0.35)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary).opacity(hovering ? 1 : 0)
                }.frame(width: ReportColumns.cache, alignment: .leading)
                    .help("LiteLLM response-cache state: " + item.gateway.cacheStatus + ". Separate from provider prompt-cache tokens.")
            }
            .padding(.leading, nested ? PiSpacing.md + ReportColumns.nestedIndent : PiSpacing.md).padding(.trailing, PiSpacing.md).padding(.vertical, 7)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityIdentifier("inspectRequest-" + item.id)
        .accessibilityLabel("Inspect request from " + item.wall.formatted())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

/// One requested route in the By model table, with its share of the window's
/// requests and cost, and its own output rate and first-token median.
struct ReportModelRow: View {
    let summary: DashboardModelSummary
    let allRequests: Int
    let allCost: Double?
    let detailed: Bool
    let filter: () -> Void
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    private var requestShare: Double { allRequests > 0 ? Double(summary.requests) / Double(allRequests) : 0 }
    private var costShare: Double? {
        guard let cost = summary.gateway.costUSD, let allCost, allCost > 0 else { return nil }
        return cost / allCost
    }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
    var body: some View {
        Button(action: filter) {
            HStack(alignment: .top, spacing: PiSpacing.sm) {
                ModelRouteCell(requested: summary.alias, final: summary.model, reported: [], status: summary.status).frame(maxWidth: .infinity, alignment: .leading)
                shareCell("\(summary.requests)", detail: percent(requestShare) + " of requests" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : ""), share: requestShare, tone: .piAccent)
                    .frame(width: ReportColumns.modelRequests, alignment: .leading)
                shareCell(summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD), detail: costShare.map { percent($0) + " of cost" } ?? (summary.gateway.costSamples < summary.requests ? "\(summary.gateway.costSamples)/\(summary.requests) reported" : "no cost reported"), share: costShare, tone: .piSuccess)
                    .frame(width: ReportColumns.cost, alignment: .leading)
                    .help(summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—").foregroundStyle(Color.piInk)
                    if summary.gateway.tokens?.reasoning != nil { Text("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(summary.gateway.cacheReadTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help(summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway))
                HStack(spacing: 5) {
                    if let ratio = summary.gateway.cacheHitRatio { PiRing(fraction: ratio, size: 10); Text(String(format: "%.0f%%", ratio * 100)) }
                    else { Text("—") }
                }.font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).frame(width: 96, alignment: .leading).help(summary.gateway.cacheLabel)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SessionUsagePresentation.rate(summary.gateway.settledThroughput.tokensPerSecond)).foregroundStyle(Color.piInk)
                    Text("\(summary.gateway.settledThroughput.samples)/\(summary.requests) measured").foregroundStyle(Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.modelRate, alignment: .leading)
                    .help(SettledThroughput.explanation)
                VStack(alignment: .leading, spacing: 1) {
                    Text("p50 " + ms(summary.ttftP50)).foregroundStyle(Color.piInk)
                    Text(summary.ttftSamples > 0 ? "HTTP \(ms(summary.httpP50)) · \(summary.ttftSamples) measured" : "not measured").foregroundStyle(Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.modelFirstToken, alignment: .leading)
                    .help("Nearest-rank medians for this route: first token and whole request.")
            }
            .padding(.horizontal, PiSpacing.md).padding(.vertical, 8)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityLabel("Route \(summary.alias), \(summary.resolutionLabel), \(summary.requests) requests")
        .accessibilityIdentifier("reportModelRow-" + summary.alias)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
    private func shareCell(_ value: String, detail: String, share: Double?, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).lineLimit(1)
            UsageShareBar(fraction: share ?? 0, tone: tone).frame(height: 4)
            Text(detail).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).lineLimit(1)
        }
    }
}

/// Requested alias over the model the gateway actually served, so routing is
/// readable at a glance: the same model, a different route, or no report.
private struct ModelRouteCell: View {
    let requested: String
    let final: String?
    let reported: [String]
    let status: String
    private var routed: Bool { final != nil && final != requested }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("requested").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).frame(width: 58, alignment: .leading)
                Text(requested).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 5) {
                Text("final").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).frame(width: 58, alignment: .leading)
                if routed { Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piAccent) }
                if let final {
                    Text(final == requested ? "same model" : final).font(PiFont.caption).foregroundStyle(routed ? Color.piInk : Color.piInkSecondary).lineLimit(1).truncationMode(.middle)
                } else {
                    FinalModelLabel(final: nil, reported: reported, status: status)
                }
            }
        }
        .help(final.map { "Requested \(requested); the gateway served \($0)." } ?? "Requested \(requested); the gateway did not report one model that served it (\(status)).")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Requested \(requested)")
    }
}

/// The gateway's final model. Agreeing reports show one name; conflicting
/// reports show the shortest name by default and reveal every reported name
/// on click, since the longer ones are usually the same model with a
/// provider prefix or date suffix.
struct FinalModelLabel: View {
    let final: String?
    let reported: [String]
    let status: String
    var font: Font = PiFont.caption
    @State private var revealed = false
    private var conflict: Bool { final == nil && reported.count > 1 }
    private var text: String {
        if let final { return final }
        if let primary = dashboardPrimaryModel(reported) { return primary }
        switch status {
        case "conflict": return "conflicting reports"
        case "incomplete": return "partial report"
        default: return "—"
        }
    }
    /// A gateway that echoed no final model is routine, so the dash is quiet; only conflicts are warnings.
    private var routineUnreported: Bool { final == nil && !conflict && !["conflict", "incomplete"].contains(status) && reported.isEmpty }
    private var tone: Color {
        if routineUnreported { return Color.piInkTertiary }
        if final != nil || conflict { return Color.piInk }
        return status == "conflict" ? Color.piDanger : Color.piWarning
    }
    var body: some View {
        if conflict {
            Button { revealed.toggle() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(text).font(font).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                        Text(revealed ? "hide" : "+\(reported.count - 1)").font(PiFont.micro).foregroundStyle(Color.piWarning)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.piWarning.opacity(0.14), in: Capsule())
                    }
                    if revealed {
                        ForEach(reported.filter { $0 != text }, id: \.self) { name in
                            Text(name).font(font).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer()
            .animation(.easeInOut(duration: 0.16), value: revealed)
            .help("The gateway reported \(reported.count) model names for this request: \(reported.joined(separator: ", ")). Click to show or hide all of them.")
            .accessibilityLabel("Final model \(text), \(reported.count) reported names")
            .accessibilityHint("Shows every reported name")
            .accessibilityIdentifier("finalModelReveal")
        } else {
            Text(text).font(font).foregroundStyle(tone).lineLimit(1).truncationMode(.middle)
                .accessibilityLabel("Final model \(text)")
        }
    }
}

/// Wrap filter controls and chips instead of allowing a narrow window to hide them.
struct ReportFlow: Layout {
    var spacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [CGPoint] = [], sizes: [CGSize] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, 320), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y)); sizes.append(size)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: max(1, proposal.width ?? 1280)).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: max(1, bounds.width))
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                                  anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}

/// Keep long aliases/session names inspectable without stretching the whole page.
struct ReportDropdown: View {
    @Binding var selection: String
    let items: [(String, String)]
    let icon: String
    private var current: String { items.first { $0.0 == selection }?.1 ?? selection }
    var body: some View {
        PiChoicePicker(title: "Filter", selection: selection,
                       choices: items.map { PiChoice(id: $0.0, title: $0.1) },
                       choose: { selection = $0 }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary)
                Text(current).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInk)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 230)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.piSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .fixedSize().help(current)
    }
}

/// One session (chat) aggregate with an expander for its requests.
struct ReportSessionRow: View {
    let summary: DashboardSessionSummary
    let title: String?
    let workspace: String?
    let available: Bool
    let expanded: Bool
    let detailed: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion
    private var connectionCheck: Bool { !available && summary.sessionID.hasPrefix("connection-test-") }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0) } ?? "—" }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: PiSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary.last, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()).font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary)
                }.frame(width: ReportColumns.started, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if connectionCheck { Text("Connection check").font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk) }
                        else if let title, !title.isEmpty { Text(title).font(PiFont.caption.weight(.medium)).foregroundStyle(Color.piInk) }
                        else { Text(String(summary.sessionID.prefix(8)) + "…").font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                        if !available && !connectionCheck { PiBadge(text: "chat unavailable", tone: .warning, icon: "exclamationmark.triangle") }
                    }
                    Text((workspace ?? "unknown project") + " · " + summary.sessionID).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .help(connectionCheck ? "Onboarding tested the selected model without creating a chat. Expand to inspect its request." : available ? "Session " + summary.sessionID : "This chat was deleted or was an unkept side conversation; its retained requests remain here.")
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(summary.requests)").foregroundStyle(Color.piInk)
                    Text("\(summary.completed) ok" + (summary.problems > 0 ? " · \(summary.problems) incomplete" : "") + (summary.running > 0 ? " · \(summary.running) running" : "")).foregroundStyle(summary.problems > 0 ? Color.piWarning : Color.piInkTertiary)
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.costUSD == nil ? "—" : reportUSD(summary.gateway.costUSD)).foregroundStyle(Color.piInk)
                    if detailed { Text("reasoning " + reportUSD(summary.gateway.reasoningCostUSD)).foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.cost, alignment: .leading)
                    .help(summary.gateway.costLabel + "\n" + reportReasoningDetail(summary.gateway))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.gateway.tokens.map { "↓\(reportTokens($0.input)) ↑\(reportTokens($0.output))" } ?? "—").foregroundStyle(Color.piInk)
                    if summary.gateway.tokens?.reasoning != nil { Text("\(reportTokens(summary.gateway.tokens?.reasoning)) reasoning").foregroundStyle(Color.piInkTertiary) }
                    if detailed { Text("cached \(reportTokens(summary.gateway.cacheReadTokens))").foregroundStyle(Color.piInkTertiary) }
                }.font(PiFont.caption.monospacedDigit()).lineLimit(1).frame(width: ReportColumns.tokens, alignment: .leading)
                    .help(summary.gateway.tokenCacheLabel + "\n" + reportReasoningDetail(summary.gateway))
                HStack(spacing: 5) {
                    if let ratio = summary.gateway.cacheHitRatio { PiRing(fraction: ratio, size: 10); Text(String(format: "%.0f%%", ratio * 100)) }
                    else { Text("—") }
                }.font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInk).frame(width: 96, alignment: .leading).help(summary.gateway.cacheLabel)
                Text("ttft \(ms(summary.ttftP50)) · \(ms(summary.httpP50))").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkSecondary).lineLimit(1).frame(width: 120, alignment: .leading)
                    .help("Nearest-rank medians for this session: first token and whole request")
                HStack(spacing: 4) {
                    if connectionCheck { Text("Setup check").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                    else { Button(action: open) { Label("Open chat", systemImage: "arrow.right.circle") }.buttonStyle(.piSecondaryCompact).disabled(!available) }
                }.frame(width: 132, alignment: .trailing)
            }
            .padding(.horizontal, PiSpacing.md).padding(.vertical, 7)
            .background(hovering ? Color.piFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityLabel((connectionCheck ? "Connection check" : "Session " + (title ?? summary.sessionID)) + ", \(summary.requests) requests")
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expanded)
    }
}
