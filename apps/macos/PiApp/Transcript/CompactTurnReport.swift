import SwiftUI
import AppKit

/// A turn's input or output: every token the turn's requests reported, as the
/// headline, and the share of it that was cached (or reasoning), drawn from
/// the requests that reported both counters. Those two need not be the same
/// requests — a request can report its input and no cache counter — so the
/// headline says how many requests it covers, and the colours keep the last
/// matched split while later requests are pending or never report one.
struct TurnTokenPartition: Equatable {
    enum Fill: Equatable { case empty, reported, split(Double) }
    let title: String
    /// Every reported token of this kind, whichever requests reported it.
    let total: Double?
    /// The requests `total` covers, of the turn's `requests`.
    let totalSamples: Int
    let requests: Int
    /// The parent of the split: the same requests as `part`.
    let splitTotal: Double?
    let splitSamples: Int?
    let part: Double?
    let remainder: Double?
    let partName: String
    let remainderName: String
    let fraction: Double?
    let partial: Bool
    /// A running turn has requests whose counters may still arrive.
    let running: Bool

    init(_ a: TurnAccounting, input: Bool, running: Bool = false) {
        title = input ? "Input" : "Output"
        partName = input ? "Cached" : "Reasoning"
        remainderName = input ? "Uncached" : "Other"
        requests = a.requests
        self.running = running
        let samples = input ? a.inputSamples : a.outputSamples
        let partSamples = input ? a.cachedSamples : a.reasoningSamples
        func valid(_ value: Double?, _ count: Int) -> Double? {
            guard count > 0, let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let paired = a.split(input: input)
        let reported = valid(input ? a.input : a.output, samples)
        total = reported ?? paired?.total
        totalSamples = reported != nil ? samples : paired?.samples ?? 0
        part = paired?.part ?? valid(input ? a.cached : a.reasoning, partSamples)
        splitTotal = paired?.total; splitSamples = paired?.samples
        if let paired {
            remainder = paired.total - paired.part
            fraction = paired.total > 0 ? paired.part / paired.total : nil
        } else {
            remainder = input ? valid(a.uncached, a.uncachedSamples) : nil
            fraction = nil
        }
        partial = a.requests > 0 && (paired.map { $0.samples < a.requests } ?? (samples < a.requests || partSamples < a.requests))
    }

    /// `11,800`, and `11,800 (2/3)` when some requests have not reported it.
    var totalLabel: String {
        guard let total else { return "—" }
        return MetricFormat.exactTokens(total) + (requests > 0 && totalSamples < requests ? " (\(totalSamples)/\(requests))" : "")
    }
    /// The track represents reported tokens, not reporting completeness.
    /// Keep it filled when a breakdown is missing, without inventing a split.
    var fill: Fill {
        if let fraction { return .split(fraction) }
        return [total, part, remainder].contains { ($0 ?? 0) > 0 } ? .reported : .empty
    }
    /// A share is of the split's own parent, never of the larger headline.
    func label(part first: Bool) -> String {
        let name = first ? partName : remainderName
        let value = first ? part : remainder
        var text = name + " " + (value.map(MetricFormat.exactTokens) ?? "—")
        if let splitTotal, fraction != nil, let value,
           let percent = MetricFormat.cacheHitPercent(read: value, prompt: splitTotal, decimals: 2) {
            text += " · " + percent + "%"
        }
        return text
    }
    var help: String {
        let count: (Double?) -> String = { $0.map(MetricFormat.exactTokens) ?? "unreported" }
        let coverage = requests > 0 && total != nil && totalSamples < requests ? " from \(totalSamples) of \(requests) requests" : ""
        var text = "\(title): \(count(total)) tokens\(coverage). \(partName): \(count(part)); \(remainderName): \(count(remainder)). "
        if partial {
            if fraction != nil, let splitSamples {
                text += "The split covers the \(splitSamples) of \(requests) requests that reported both counters"
                    + (running ? "; newer requests may still be pending. " : ". ")
            } else {
                text += "Some requests have not reported both counters. "
            }
        }
        if fill == .reported { text += "The filled bar represents reported tokens; the percentage breakdown is unavailable. " }
        return text + (title == "Input" ? "Cached tokens are included in input." : "Reasoning tokens are included in output.")
    }
}

/// Shared by a completed turn and the live dock. A small header and three
/// compact readings replace the large four-tile mockup. Only the clock ticks;
/// token shares always use gateway observations, never streamed text length.
struct CompactTurnReport: View {
    let turn: TurnSummary
    var actions = TranscriptActions()
    var model: String? = nil
    var status: String? = nil
    var showsInfo = true

    private var models: [String] {
        let names = turn.accounting.answeredModels
        return names.isEmpty ? model.map { [$0] } ?? [] : names
    }
    private var modelLabel: String { TurnInfoPresentation.modelLabel(turn, fallback: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TurnReportHeaderLayout { state; identityAndActions }
            TurnReportMetrics(turn: turn)
            if let notice = TurnInfoPresentation.coverageNotice(turn) {
                // Live, one line whatever it says: a dock that reflowed as
                // requests finished would move the conversation above it.
                Text(notice).font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.faint)
                    .lineLimit(turn.isRunning ? 1 : 3).truncationMode(.tail).fixedSize(horizontal: false, vertical: !turn.isRunning)
                    .help(notice).accessibilityIdentifier("turn-coverage-notice")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(TranscriptPalette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TranscriptPalette.hair, lineWidth: 1))
        .contextMenu { Button("Copy Turn Info") { copy() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compact-turn-report")
    }

    private var state: some View {
        HStack(spacing: 6) {
            if turn.isRunning { PiShimmerText(text: status ?? "Working…").accessibilityIdentifier("workingIndicator") }
            else {
                Image(systemName: turn.outcome == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(turn.outcome == "completed" ? Color.piSuccess : Color.piWarning)
                Text("Turn · " + TurnInfoPresentation.outcome(turn))
            }
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(TranscriptPalette.muted)
            .lineLimit(1).truncationMode(.tail)
    }

    private var identityAndActions: some View {
        HStack(spacing: 7) {
            Text(modelLabel).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted)
                .lineLimit(1).truncationMode(.middle)
                .help(turn.accounting.modelRoutes.isEmpty ? models.joined(separator: "\n") : turn.accounting.modelRoutes.map(\.detail).joined(separator: "\n"))
                .accessibilityIdentifier("turn-report-model")
            Text(TurnInfoPresentation.costLabel(turn)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(TranscriptPalette.text).monospacedDigit().fixedSize()
                .help("Gateway-reported cost" + (turn.isRunning ? " so far" : ""))
            if showsInfo {
                TurnInfoButton(turn: turn, actions: actions)
                Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 18, height: 18) }
                    .buttonStyle(.plain).piPointer().help("Copy Turn Info").accessibilityLabel("Copy Turn Info")
            }
        }.font(.system(size: 11)).foregroundStyle(TranscriptPalette.faint)
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TurnLineView.copyText(TurnInfoPresentation.live(turn, at: .now), model: model), forType: .string)
    }
}

struct TurnReportMetrics: View {
    let turn: TurnSummary
    var body: some View {
        TurnReportMetricsLayout { duration; input; output }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var input: some View { TurnTokenBar(partition: TurnTokenPartition(turn.accounting, input: true, running: turn.isRunning)) }
    private var output: some View { TurnTokenBar(partition: TurnTokenPartition(turn.accounting, input: false, running: turn.isRunning)) }
    private var duration: some View { TurnDurationMetrics(turn: turn) }
}

/// The report's header: its state on the left; the model, the cost and the
/// actions on the right. Whether that is one line or two is decided by the
/// width the report is offered and never by what the labels say. A status,
/// a model or a cost that changes while the turn runs is new text in the
/// same line — the model name gives way first — because a header that
/// reflowed to a second line moved everything under it, and in the live
/// dock that is the whole conversation above the composer.
private struct TurnReportHeaderLayout: Layout {
    /// Narrower than this, the header takes two lines whatever it says.
    static let oneLineWidth: CGFloat = 420
    /// What the state keeps of a shared line before the identity may narrow it.
    static let stateMinimum: CGFloat = 130
    private let spacing: CGFloat = 8, lineSpacing: CGFloat = 3

    private func frames(width: CGFloat, _ subviews: Subviews) -> (state: CGRect, identity: CGRect, height: CGFloat) {
        let state = subviews[0], identity = subviews[1]
        if width >= Self.oneLineWidth {
            let identityWidth = min(identity.sizeThatFits(.unspecified).width, width - Self.stateMinimum - spacing)
            let identitySize = identity.sizeThatFits(ProposedViewSize(width: identityWidth, height: nil))
            let stateSize = state.sizeThatFits(ProposedViewSize(width: max(0, width - identitySize.width - spacing), height: nil))
            let height = max(stateSize.height, identitySize.height)
            return (CGRect(x: 0, y: (height - stateSize.height) / 2, width: stateSize.width, height: stateSize.height),
                    CGRect(x: width - identitySize.width, y: (height - identitySize.height) / 2, width: identitySize.width, height: identitySize.height),
                    height)
        }
        let stateSize = state.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let identitySize = identity.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (CGRect(origin: .zero, size: stateSize),
                CGRect(x: 0, y: stateSize.height + lineSpacing, width: identitySize.width, height: identitySize.height),
                stateSize.height + lineSpacing + identitySize.height)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        guard let width = proposal.width else {
            let state = subviews[0].sizeThatFits(.unspecified), identity = subviews[1].sizeThatFits(.unspecified)
            return CGSize(width: state.width + spacing + identity.width, height: max(state.height, identity.height))
        }
        return CGSize(width: width, height: frames(width: width, subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let placed = frames(width: bounds.width, subviews)
        for (subview, frame) in zip(subviews, [placed.state, placed.identity]) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// The report's three readings — duration, input, output — as three columns,
/// as the duration over a pair, or as a stack, chosen from the width the
/// report is offered alone. The clock and the counters change while a turn
/// runs; the arrangement must not change with them, or the dock, and the
/// conversation over it, jumps by a row. Each reading gets a slot of its own
/// that depends on the width alone, so a figure gaining a digit moves nothing.
private struct TurnReportMetricsLayout: Layout {
    static let durationColumn: CGFloat = 150, tokenColumn: CGFloat = 185
    private let spacing: CGFloat = 14, rowSpacing: CGFloat = 6
    static var columnsWidth: CGFloat { durationColumn + 2 * tokenColumn + 2 * 14 }
    static var pairWidth: CGFloat { 2 * tokenColumn + 14 }

    private func frames(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        func size(_ index: Int, _ slot: CGFloat) -> CGSize { subviews[index].sizeThatFits(ProposedViewSize(width: slot, height: nil)) }
        if width >= Self.columnsWidth {
            let durationWidth = (width - 2 * spacing) * Self.durationColumn / (Self.durationColumn + 2 * Self.tokenColumn)
            let tokenWidth = (width - 2 * spacing - durationWidth) / 2
            let heights = [size(0, durationWidth).height, size(1, tokenWidth).height, size(2, tokenWidth).height]
            return ([CGRect(x: 0, y: 0, width: durationWidth, height: heights[0]),
                     CGRect(x: durationWidth + spacing, y: 0, width: tokenWidth, height: heights[1]),
                     CGRect(x: durationWidth + tokenWidth + 2 * spacing, y: 0, width: tokenWidth, height: heights[2])],
                    heights.max() ?? 0)
        }
        let duration = size(0, width).height
        if width >= Self.pairWidth {
            let tokenWidth = (width - spacing) / 2, top = duration + rowSpacing
            let heights = [size(1, tokenWidth).height, size(2, tokenWidth).height]
            return ([CGRect(x: 0, y: 0, width: width, height: duration),
                     CGRect(x: 0, y: top, width: tokenWidth, height: heights[0]),
                     CGRect(x: tokenWidth + spacing, y: top, width: tokenWidth, height: heights[1])],
                    top + (heights.max() ?? 0))
        }
        let input = size(1, width).height, output = size(2, width).height
        return ([CGRect(x: 0, y: 0, width: width, height: duration),
                 CGRect(x: 0, y: duration + rowSpacing, width: width, height: input),
                 CGRect(x: 0, y: duration + input + 2 * rowSpacing, width: width, height: output)],
                duration + input + output + 2 * rowSpacing)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? Self.columnsWidth
        return CGSize(width: width, height: frames(width: width, subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Two non-overlapping shares, or one filled track when only a reported total
/// is available. Zero and unreported counts stay empty. A tiny Canvas avoids a chart
/// engine and never animates the transcript's geometry while streaming.
struct TurnTokenBar: View {
    let partition: TurnTokenPartition
    private var primary: Color { partition.title == "Input" ? .piSuccess : .monitorModel(2) }
    private var secondary: Color { .piAccent }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(partition.title).foregroundStyle(TranscriptPalette.faint)
                Text(partition.totalLabel).foregroundStyle(TranscriptPalette.text)
            }.font(.system(size: 11, weight: .medium)).lineLimit(1)
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(Color.piFillStrong))
                switch partition.fill {
                case .empty: break
                case .reported:
                    context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(secondary.opacity(0.75)))
                case .split(let fraction):
                    context.clip(to: Path(roundedRect: bounds, cornerRadius: 2))
                    context.fill(Path(bounds), with: .color(secondary.opacity(0.75)))
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)), with: .color(primary))
                }
            }.frame(height: 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                legend(partition.label(part: true), primary)
                legend(partition.label(part: false), secondary)
            }.font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: true, vertical: false)
        }.monospacedDigit().help(partition.help)
            .accessibilityElement(children: .ignore).accessibilityLabel(partition.help)
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 4, height: 4); Text(text) }
    }
}
