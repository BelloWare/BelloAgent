import SwiftUI
import AppKit

/// A subset of a reported token count. Shares require matching, complete
/// observations; independently summed partial reports are not a denominator.
struct TurnTokenPartition: Equatable {
    let title: String
    let total: Double?
    let part: Double?
    let remainder: Double?
    let partName: String
    let remainderName: String
    let fraction: Double?
    let partial: Bool

    init(_ a: TurnAccounting, input: Bool) {
        title = input ? "Input" : "Output"
        partName = input ? "Cached" : "Reasoning"
        remainderName = input ? "Uncached" : "Other"
        let samples = input ? a.inputSamples : a.outputSamples
        let partSamples = input ? a.cachedSamples : a.reasoningSamples
        func valid(_ value: Double?, _ count: Int) -> Double? {
            guard count > 0, let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        total = valid(input ? a.input : a.output, samples)
        part = valid(input ? a.cached : a.reasoning, partSamples)
        let matched = a.requests > 0 && samples == a.requests && partSamples == a.requests
        if matched, let total, let part, part <= total {
            remainder = total - part
            fraction = total > 0 ? part / total : nil
        } else {
            remainder = input ? valid(a.uncached, a.uncachedSamples) : nil
            fraction = nil
        }
        partial = a.requests > 0 && (samples < a.requests || partSamples < a.requests)
    }

    var totalLabel: String { total.map(MetricFormat.tokens) ?? "—" }
    func label(part first: Bool) -> String {
        let name = first ? partName : remainderName
        let value = first ? part : remainder
        var text = name + " " + (value.map(MetricFormat.tokens) ?? "—")
        if let total, fraction != nil, let value,
           let percent = MetricFormat.cacheHitPercent(read: value, prompt: total) {
            text += " · " + (percent == "0" && value > 0 ? "<1" : percent) + "%"
        }
        return text
    }
    var help: String {
        let count: (Double?) -> String = { $0.map(MetricFormat.exactTokens) ?? "unreported" }
        return "\(title): \(count(total)) tokens. \(partName): \(count(part)); \(remainderName): \(count(remainder)). "
            + (partial ? "Partial reporting; no percentage is inferred from mismatched observations. " : "")
            + (title == "Input" ? "Cached tokens are included in input." : "Reasoning tokens are included in output.")
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
        let names = turn.accounting.reportedModels
        return names.isEmpty ? model.map { [$0] } ?? [] : names
    }
    private var modelLabel: String {
        if let route = turn.accounting.latestModelRoute {
            return route.label + (turn.accounting.modelRoutes.count > 1 ? " +\(turn.accounting.modelRoutes.count - 1)" : "")
        }
        guard let name = turn.accounting.model ?? models.last else { return turn.live ? "Model pending" : "Model unreported" }
        return name + (models.count > 1 ? " +\(models.count - 1)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { state; Spacer(minLength: 6); identityAndActions }
                VStack(alignment: .leading, spacing: 3) { state; identityAndActions }
            }
            TurnReportMetrics(turn: turn)
            if turn.live || turn.partial {
                Text(turn.partial ? "Partial history · retained request usage" : "Reported so far · updates as requests finish")
                    .font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.faint)
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
            if turn.live { PiShimmerText(text: status ?? "Working…").accessibilityIdentifier("workingIndicator") }
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
            Text(TurnInfoPresentation.costLabel(turn)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(TranscriptPalette.text).monospacedDigit().fixedSize()
                .help("Gateway-reported cost" + (turn.live ? " so far" : ""))
            if showsInfo {
                TurnInfoButton(turn: turn, actions: actions)
                Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 18, height: 18) }
                    .buttonStyle(.plain).piPointer().help("Copy Turn Info").accessibilityLabel("Copy Turn Info")
            }
        }.font(.system(size: 11)).foregroundStyle(TranscriptPalette.faint)
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TurnLineView.copyText(turn, model: model), forType: .string)
    }
}

struct TurnReportMetrics: View {
    let turn: TurnSummary
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                duration.frame(minWidth: 150)
                input.frame(minWidth: 185)
                output.frame(minWidth: 185)
            }
            VStack(alignment: .leading, spacing: 6) {
                duration
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { input.frame(minWidth: 185); output.frame(minWidth: 185) }
                    VStack(alignment: .leading, spacing: 6) { input; output }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var input: some View { TurnTokenBar(partition: TurnTokenPartition(turn.accounting, input: true)) }
    private var output: some View { TurnTokenBar(partition: TurnTokenPartition(turn.accounting, input: false)) }
    private var duration: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Duration").foregroundStyle(TranscriptPalette.faint)
                Text(turn.elapsedMs.map(workDuration) ?? "—").foregroundStyle(TranscriptPalette.text)
                    .accessibilityIdentifier("elapsedClock")
            }.font(.system(size: 11, weight: .medium))
            Text("AI \(workDuration(turn.modelMs)) · Tools \(workDuration(turn.toolMs))")
                .font(.system(size: 10)).foregroundStyle(TranscriptPalette.muted)
                .help("Recorded time waiting on AI requests versus running tools. Running phases are included when the helper reports them; elapsed time also includes other work.")
        }.monospacedDigit().fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two non-overlapping shares; a zero total or missing breakdown draws an
/// empty track, rather than a false 0% or 100%. A tiny Canvas avoids a chart
/// engine and never animates the transcript's geometry while streaming.
struct TurnTokenBar: View {
    let partition: TurnTokenPartition
    private var primary: Color { partition.title == "Input" ? .piSuccess : .piInfo }
    private var secondary: Color { .piAccent }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(partition.title).foregroundStyle(TranscriptPalette.faint)
                Text(partition.totalLabel).foregroundStyle(TranscriptPalette.text)
                if partition.partial { Text("partial").foregroundStyle(TranscriptPalette.warning).font(.system(size: 9)) }
            }.font(.system(size: 11, weight: .medium))
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(Color.piFillStrong))
                if let fraction = partition.fraction {
                    context.clip(to: Path(roundedRect: bounds, cornerRadius: 2))
                    context.fill(Path(bounds), with: .color(secondary.opacity(0.75)))
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)), with: .color(primary))
                }
            }.frame(height: 4).accessibilityHidden(true)
            HStack(spacing: 5) {
                legend(partition.label(part: true), primary)
                Spacer(minLength: 0)
                legend(partition.label(part: false), secondary)
            }.font(.system(size: 9.5)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: true, vertical: false)
        }.monospacedDigit().help(partition.help)
            .accessibilityElement(children: .ignore).accessibilityLabel(partition.help)
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 4, height: 4); Text(text) }
    }
}
