// Header, request row and its model/cache cells frozen from v0.1.119.
// Shared data models, column widths and formatting functions are unchanged.
import SwiftUI
@testable import PiApp

struct ReportGridRowReference: View {
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

struct ReportRequestRowReference: View {
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
                ReportModelRouteCellReference(requested: item.alias, final: item.effectiveModel, reported: item.reportedModels, status: item.identityStatus).frame(maxWidth: .infinity, alignment: .leading)
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
                    ReportRequestCacheBadgeReference(status: item.gateway.cacheStatus)
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

struct ReportModelRouteCellReference: View {
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
                    ReportFinalModelLabelReference(final: nil, reported: reported, status: status)
                }
            }
        }
        .help(final.map { "Requested \(requested); the gateway served \($0)." } ?? "Requested \(requested); the gateway did not report one model that served it (\(status)).")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Requested \(requested)")
    }
}

struct ReportFinalModelLabelReference: View {
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

struct ReportRequestCacheBadgeReference: View {
    let status: String
    private var tone: PiTone {
        switch status {
        case "hit": .success
        case "miss": .neutral
        case "unreported": .warning
        default: .danger
        }
    }
    var body: some View { PiBadge(text: status, tone: tone, dot: true) }
}

/// A resolved table fixture: eager measurement of the unchanged frozen rows
/// avoids confusing a LazyVStack's unrendered-row estimates with geometry.
struct ReportResolvedTableReference: View {
    let rows: [DashboardRequest]
    let labels: [String]
    let detailed: Bool
    var body: some View {
        VStack(spacing: 0) {
            ReportGridRowReference(cells: labels, header: true)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            ForEach(rows) { row in
                ReportRequestRowReference(item: row, title: "Retry loop", detailed: detailed, inspect: {})
                Rectangle().fill(Color.piHairline).frame(height: 1)
            }
        }.piInset()
    }
}

/// The old Report column's padding, width limits, spacing and actual footer;
/// cards above the table have identical explicit heights in this fixture.
struct ReportResolvedColumnReference: View {
    let rows: [DashboardRequest]
    let labels: [String]
    let above: CGFloat
    let gridWidth: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.lg) {
            Color.clear.frame(height: above)
            ScrollView(.horizontal) {
                ReportResolvedTableReference(rows: rows, labels: labels, detailed: false).frame(width: gridWidth)
            }
            Button {} label: {
                HStack(spacing: 5) {
                    Text("Details · timings, coverage and methodology")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }.buttonStyle(.piGhost)
        }
        .padding(.horizontal, PiSpacing.xl).padding(.vertical, PiSpacing.lg)
        .frame(maxWidth: 1280, alignment: .leading).frame(maxWidth: .infinity)
    }
}
