import SwiftUI
import AppKit

// The small pieces every Inspector page is built from. None of them reads or
// formats a body: the strings arrive prepared.

/// A page's heading: what it is, a quiet line of context, badges, and the
/// page's own actions on the right. The actions say their names while the row
/// has room for them and show their symbols when it does not, each named on
/// hover; the badges never truncate, and the title gives way first.
struct InspectorPageHeader<Badges: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var badges: Badges
    @ViewBuilder var actions: Actions
    init(_ title: String, subtitle: String? = nil, @ViewBuilder badges: () -> Badges = { EmptyView() }, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.badges = badges(); self.actions = actions()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                row(named: true)
                row(named: false)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func row(named: Bool) -> some View {
        HStack(alignment: .center, spacing: PiSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(PiFont.title(18)).foregroundStyle(Color.piInk).lineLimit(1).layoutPriority(1)
                badges.fixedSize()
            }
            Spacer(minLength: PiSpacing.sm)
            HStack(spacing: 6) { actions }.fixedSize()
                .environment(\.inspectorActionNames, named)
        }
    }
}

private struct InspectorActionNamesKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// Whether a page header's actions say their names, or show only their
    /// symbols on a narrow page.
    var inspectorActionNames: Bool {
        get { self[InspectorActionNamesKey.self] }
        set { self[InspectorActionNamesKey.self] = newValue }
    }
}

/// A page header's action: its name and symbol, or its symbol alone on a
/// narrow page, named on hover and to VoiceOver either way.
struct InspectorHeaderAction: View {
    let title: String
    let symbol: String
    let help: String
    let identifier: String
    let action: () -> Void
    @Environment(\.inspectorActionNames) private var named
    var body: some View {
        if named {
            Button(action: action) { Label(title, systemImage: symbol).lineLimit(1) }
                .buttonStyle(.piGhost).fixedSize().help(help)
                .accessibilityIdentifier(identifier)
        } else {
            PiIconButton(symbol: symbol, label: title, size: 26, action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// "Show in chat": the one action every page has.
struct InspectorShowInChat: View {
    let action: () -> Void
    var body: some View {
        InspectorHeaderAction(title: "Show in chat", symbol: "arrow.uturn.left.circle", help: "Bring the chat forward, scrolled to what this page is about",
                              identifier: "inspector-show-in-chat", action: action)
    }
}

/// "Fork from here": a new chat that ends at the reply this request produced.
struct InspectorForkFromHere: View {
    let action: () -> Void
    var body: some View {
        InspectorHeaderAction(title: "Fork from here", symbol: "arrow.triangle.branch", help: "A new chat, nested under this one, that ends at the reply this request produced",
                              identifier: "inspector-fork-from-here", action: action)
    }
}

/// A heading inside a page: a title and what it covers.
struct InspectorSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(PiFont.heading).foregroundStyle(Color.piInk)
            if let subtitle { Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// One figure of a strip: a quiet label and its value in ink.
struct InspectorFigure: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var detail: String? = nil
    var tone: PiTone = .neutral
}

/// A strip of figures that wraps like a sentence on a narrow page.
struct InspectorFigureStrip: View {
    let figures: [InspectorFigure]
    var body: some View {
        PiFlow(spacing: 16, rowSpacing: 6) {
            ForEach(figures) { figure in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(figure.label).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                    Text(figure.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(figure.tone == .neutral ? Color.piInk : figure.tone.color)
                    if let detail = figure.detail {
                        Text(detail).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A banner over a list: what changed, in accent or warning ink.
struct InspectorBanner: View {
    let symbol: String
    let text: String
    var notes: [String] = []
    var tone: PiTone = .accent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk).fixedSize(horizontal: false, vertical: true)
                ForEach(notes, id: \.self) { note in
                    Text(note).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tone == .accent ? Color.piAccentSoft : tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector-banner")
    }
}

/// A calm, centered message where a page has nothing to show yet.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var progress: Double? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Color.piInkTertiary)
            Text(title).font(PiFont.heading).foregroundStyle(Color.piInkSecondary).multilineTextAlignment(.center)
            // Drawn by SwiftUI: an AppKit progress bar would size itself on every update.
            if let progress { UsageShareBar(fraction: progress, tone: .piBrandOrange).frame(width: 220, height: 4) }
            if let message {
                Text(message).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PiSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A small status mark: a dot or a shimmer for a request still running.
struct InspectorStatusMark: View {
    let outcome: String
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay { if running { Circle().stroke(color.opacity(0.35), lineWidth: 3) } }
            .accessibilityLabel(outcome)
    }
    private var running: Bool { ["running", "streaming"].contains(outcome) }
    private var color: Color {
        switch outcome {
        case "completed", "truncated": return .piSuccess
        case "running", "streaming": return .piBrandOrange
        case "failed", "interrupted", "error": return .piDanger
        case "cancelled": return .piWarning
        default: return .piInkTertiary
        }
    }
}

extension InspectorRequestRow {
    /// `Completed`, `Running`, `Failed`.
    var outcomeLabel: String {
        switch outcome {
        case "completed": return "Completed"
        case "truncated": return "Output limit"
        case "running", "streaming": return "Running"
        case "interrupted": return "Interrupted"
        case "cancelled": return "Stopped"
        case "failed", "error": return "Failed"
        default: return outcome.isEmpty ? "Unknown" : outcome.prefix(1).uppercased() + outcome.dropFirst()
        }
    }
    var outcomeTone: PiTone {
        switch outcome {
        case "completed": return .success
        case "running", "streaming", "truncated", "cancelled": return .warning
        case "failed", "interrupted", "error": return .danger
        default: return .neutral
        }
    }
    /// `In 18,240 (15,112 cached) · Out 1,104 · reasoning 640 · $0.0213 · TTFT 820 ms · 96 tok/s · 3.4 s`
    var figures: [InspectorFigure] {
        var figures: [InspectorFigure] = []
        if let input { figures.append(InspectorFigure(label: "In", value: MetricFormat.exactTokens(input), detail: cached.map { "(" + MetricFormat.exactTokens($0) + " cached)" })) }
        if let output { figures.append(InspectorFigure(label: "Out", value: MetricFormat.exactTokens(output))) }
        if let reasoning { figures.append(InspectorFigure(label: "reasoning", value: MetricFormat.exactTokens(reasoning))) }
        if let cost { figures.append(InspectorFigure(label: "Cost", value: compactGatewayUSD(cost))) }
        if let ttft { figures.append(InspectorFigure(label: "TTFT", value: MetricFormat.latency(ttft))) }
        if let settledRate { figures.append(InspectorFigure(label: "Speed", value: MetricFormat.throughput(settledRate))) }
        if let duration = duration ?? http { figures.append(InspectorFigure(label: "Time", value: SessionStatsFormat.duration(duration))) }
        return figures
    }
}
