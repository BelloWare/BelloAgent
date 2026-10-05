import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/CompactTurnReport.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

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
            if let notice = TurnInfoPresentation.cardNote(turn) {
                // Live, one line whatever it says: a dock that reflowed as
                // requests finished would move the conversation above it.
                Text(notice).font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.faint)
                    .lineLimit(turn.isRunning ? 1 : 4).truncationMode(.tail).fixedSize(horizontal: false, vertical: !turn.isRunning)
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
