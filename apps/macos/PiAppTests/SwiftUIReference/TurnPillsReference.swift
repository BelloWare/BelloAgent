import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TurnPills.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

// MARK: - Per-request accounting line

/// The quiet receipt under one reply: which model answered, and what that
/// request reported. The turn's pills sum these; this line is the evidence.
struct MessageAccountingView: View {
    let accounting: GatewayTotals
    let onInspect: () -> Void
    var trailing = false
    var body: some View {
        let presentation = TranscriptActivity.accountingPresentation(accounting)
        if !presentation.summary.isEmpty {
            HStack(spacing: 0) {
                if let model = presentation.modelLabel {
                    Button(action: onInspect) { Text(model).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted).underline(true, color: .clear) }
                        .buttonStyle(.plain).piPointer().help("View response-body and header models").accessibilityLabel("View model reports: \(model)")
                    if !presentation.usage.isEmpty { Text(" · ").font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted) }
                }
                Text(presentation.usage).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .help(presentation.detail)
            .accessibilityLabel("\(presentation.summary). \(presentation.detail)")
        }
    }
}

// MARK: - The turn's pills

/// Compact turn receipt shared with the live dock. Detail stays available
/// through Info and Copy, while the token split is readable without a click.
struct TurnPillRow: View {
    let turn: TurnSummary
    var actions = TranscriptActions()
    var model: String? = nil
    var showsInfo = false

    var body: some View {
        CompactTurnReport(turn: turn, actions: actions, model: model, showsInfo: showsInfo)
            .accessibilityIdentifier("turn-pills")
    }
}

/// How a turn ends: the compact report over a hairline. A turn that has just
/// settled glows for a moment, as the old turn line did, and hovering it still
/// says when the turn started and finished.
struct TurnLineView: View {
    let turn: TurnSummary
    var settled = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    var actions = TranscriptActions()
    var model: String? = nil
    var modelMessageID: String? = nil

    var body: some View {
        let stamps = [turn.startedAt.map { "Started " + TranscriptActivity.formatClock($0) },
                      turn.isRunning ? nil : turn.endedAt.map { "finished " + TranscriptActivity.formatClock($0) }].compactMap { $0 }.joined(separator: " · ")
        return TurnPillRow(turn: turn, actions: actions, model: model, showsInfo: true)
            .help(stamps)
            .padding(.top, 6)
            .overlay(alignment: .top) { Rectangle().fill(settled ? TranscriptPalette.accent.opacity(0.55) : TranscriptPalette.hair).frame(height: 1) }
            .background(settled ? TranscriptPalette.accent.opacity(0.07) : Color.clear)
            .padding(.top, 8)
            .accessibilityLabel("Turn: \(TurnLineView.counts(turn))")
    }

    /// `requests`: the turn's request list, when Turn Info has loaded it.
    nonisolated static func copyText(_ turn: TurnSummary, model: String? = nil, requests: [TurnRequestLine] = []) -> String {
        var lines = [turn.partial ? "Turn (partial loaded history)" : "Turn", counts(turn)]
        if let outcome = turn.outcome { lines.append("Outcome: " + outcome) }
        else if !turn.isRunning { lines.append("Task outcome unavailable; retained figures may be incomplete.") }
        if let notice = turn.notice { lines.append(notice) }
        if let started = turn.startedAt { lines.append("Started: " + TranscriptActivity.formatClock(started)) }
        if let ended = turn.endedAt { lines.append("Finished: " + TranscriptActivity.formatClock(ended)) }
        if let elapsed = turn.elapsedMs { lines.append("Duration: " + TranscriptActivity.formatDuration(elapsed)) }
        lines.append("Model time: " + TranscriptActivity.formatDuration(turn.modelMs) + " · Tool time: " + TranscriptActivity.formatDuration(turn.toolMs))
        if let rate = turn.accounting.throughput.tokensPerSecond {
            lines.append("Output speed: " + MetricFormat.throughput(rate) + (turn.accounting.throughput.coverage.map { " (" + $0 + ")" } ?? ""))
        }
        let usage = TranscriptActivity.usageBreakdown(turn.accounting)
        if !usage.isEmpty { lines.append("Gateway-reported usage: " + usage) }
        if let coverage = TurnInfoPresentation.coverageNotice(turn) { lines.append(coverage) }
        let names = turn.accounting.reportedModels
        if !names.isEmpty { lines.append("Models: " + names.joined(separator: ", ")) }
        else if let model { lines.append("Model: " + model) }
        if !turn.accounting.requestedModels.isEmpty { lines.append("Requested models: " + turn.accounting.requestedModels.joined(separator: ", ")) }
        for route in turn.accounting.modelRoutes { lines.append(route.detail) }
        if turn.isRunning { lines.append("Still running; figures are incomplete.") }
        if !requests.isEmpty {
            lines.append("\nRequests:")
            for (index, line) in requests.enumerated() {
                lines.append("\(index + 1). " + TurnInfoPresentation.routeLabel(line) + " · " + TurnInfoPresentation.lineFigures(line) + " · " + TurnInfoPresentation.lineSource(line))
            }
            let subtotals = TurnInfoPresentation.subtotals(requests)
            if subtotals.count > 1 { for subtotal in subtotals { lines.append("  " + TurnInfoPresentation.subtotalLabel(subtotal)) } }
        }
        for (index, request) in turn.requests.enumerated() {
            guard let accounting = request.accounting, accounting.requests > 0 else { continue }
            let figures = TranscriptActivity.accountingPresentation(accounting)
            lines.append("\nRequest \(index + 1) · message \(request.id)\n" + figures.summary + "\n" + figures.detail)
        }
        return lines.joined(separator: "\n")
    }
    nonisolated static func counts(_ turn: TurnSummary, includeTools: Bool = true) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        return plural(turn.replies, "reply", "replies")
            + (includeTools && turn.tools > 0 ? ", " + (turn.toolCountPartial ? "at least " : "") + plural(turn.tools, "tool call", "tool calls") : "")
            + (turn.files > 0 ? ", " + plural(turn.files, "file changed", "files changed") : "")
    }
}

/// A terminal slot independent of the prose above it: the turn's outcome, then
/// the same compact report the transcript's own turns end with, then any notice.
struct StableTurnSummaryView: View {
    let turn: TurnSummary
    let actions: TranscriptActions
    /// The notice under the report: a failed turn's error is left to the
    /// run's failure card when that card is on the page, and a stopped
    /// turn's advice is in the report's own note.
    static func shownNotice(_ turn: TurnSummary) -> String? { TurnInfoPresentation.noticeBelowCard(turn) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TurnPillRow(turn: turn, actions: actions, showsInfo: true)
            if let notice = Self.shownNotice(turn) {
                Text(notice).font(.system(size: 12)).foregroundStyle(TranscriptPalette.warning).textSelection(.enabled)
            }
        }.padding(.top, 6).padding(.bottom, 10).fixedSize(horizontal: false, vertical: true)
    }
}
