import AppKit

// What the transcript's rows say and how they are built, as plain values:
// the native rows read them here. (The SwiftUI rows they replaced carried
// the same as statics of their views, which the parity tests' reference
// copies still do.)

/// A tool call's row (`ActionRowView`): its icon, title, summary and state,
/// and the card it opens.
enum TranscriptToolRow {
    /// Where the call stands, as a row state: a call the reader stopped is
    /// amber, not red — it did not fail, it was interrupted — whether it was
    /// skipped before it began or stopped while it ran.
    nonisolated static func state(of tool: ToolView) -> TranscriptRowState {
        switch TranscriptActivity.outcome(of: tool) {
        case .running: return .running
        case .cancelled, .unknown: return .stopped
        case .failed: return .failed
        case .done: return .ok
        }
    }
    /// What the row is called. The verb is not conjugated for the outcome —
    /// "Ran", never "Failed running" — because the dot in the leading box and
    /// the colour of the summary already say how the call went, and a line
    /// that says it twice reads as an apology.
    ///
    /// Except where "Ran" would claim work that did not happen: a call that
    /// was skipped never ran, so it is "Skipped running"; a call stopped while
    /// it ran is "Stopped running", and its suffix says the outcome is unknown.
    nonisolated static func title(of tool: ToolView) -> String {
        title(TranscriptActivity.actionParts(tool), outcome: TranscriptActivity.outcome(of: tool))
    }
    nonisolated private static func title(_ parts: TranscriptActivity.ActionParts, outcome: ActionOutcome) -> String {
        outcome == .unknown || outcome == .cancelled ? TranscriptActivity.describe(parts, outcome: outcome).verb : parts.done
    }
    /// The collapsed line's summary: a failure's first line replaces the
    /// argument summary outright, because a row cannot say both.
    nonisolated static func summary(of tool: ToolView) -> String { summary(of: tool, object: TranscriptActivity.actionParts(tool).object) }
    nonisolated private static func summary(of tool: ToolView, object: String) -> String {
        guard state(of: tool) == .failed, !tool.output.isEmpty else { return object }
        return TranscriptActivity.firstLine(tool.output)
    }
    /// The quiet trailing clock. A call that took less than a twentieth of a
    /// second says nothing rather than "0.0s": the figure exists to tell the
    /// reader what was slow.
    nonisolated static func elapsed(of tool: ToolView) -> String? {
        guard TranscriptActivity.outcome(of: tool) != .running, let ms = tool.durationMs, ms >= 50 else { return nil }
        return TranscriptActivity.formatDuration(ms)
    }
    /// The change size, already on the collapsed row, and — for a call stopped
    /// while it ran — that its outcome is unknown. It sits outside the
    /// ellipsized summary, so a long command never clips it.
    nonisolated static func suffix(of tool: ToolView) -> String? {
        let change = tool.added != nil || tool.removed != nil ? "+\(tool.added ?? 0) −\(tool.removed ?? 0)" : nil
        guard TranscriptActivity.outcome(of: tool) == .unknown else { return change }
        return [change, "· outcome unknown"].compactMap { $0 }.joined(separator: " ")
    }
    /// What one call's row says and opens, worked out once, for the SwiftUI
    /// row and the native one alike. The call's arguments are read once: while
    /// a write streams they are the whole file so far, and the title, the
    /// summary and the help each reading them again was three reads per delta.
    struct Model: Equatable {
        let icon: String
        let title: String
        let summary: String
        let suffix: String?
        let state: TranscriptRowState
        let trailing: String?
        let help: String
        /// Only a summary that is the path is its link: a failure's words are
        /// not, though the row opens the file.
        let linksSummary: Bool
        let description: ActionDescription
        let outcome: ActionOutcome
        /// The call's file, when it has one: what the link opens.
        let file: TranscriptActivity.FileLink?
    }
    nonisolated static func model(of tool: ToolView) -> Model {
        let parts = TranscriptActivity.actionParts(tool)
        let outcome = TranscriptActivity.outcome(of: tool)
        let description = TranscriptActivity.describe(parts, outcome: outcome)
        let summary = summary(of: tool, object: description.object)
        return Model(icon: actionSymbol(description.kind), title: title(parts, outcome: outcome), summary: summary,
                     suffix: suffix(of: tool), state: state(of: tool), trailing: elapsed(of: tool),
                     help: description.path ?? description.object, linksSummary: summary == description.object,
                     description: description, outcome: outcome, file: TranscriptActivity.fileLink(tool))
    }
    /// What an open row's card is: a diff for a change, a numbered window for
    /// a read, a terminal for a command, the IN/OUT card for everything else.
    enum Card: Equatable {
        case diff(TranscriptActivity.EditRequest, path: String?, outcome: ActionOutcome, added: Int?, removed: Int?)
        case terminal(command: String, output: String, failed: Bool)
        case read(text: String, firstLine: Int, path: String?, failed: Bool)
        /// `path` only when the card opens the file.
        case io(path: String?, input: String, output: String?, failed: Bool, note: String?)
    }
    /// The card for `tool`, from the fetched document when the host has
    /// answered for the call and the inline one until then: both parse, so a
    /// card is never a fragment of JSON. `linked`: whether the row opens a file.
    nonisolated static func card(of tool: ToolView, fetched: ToolInputDocument?, model: Model, linked: Bool) -> Card {
        let shown = requested(tool, fetched: fetched)
        let description = model.description, outcome = model.outcome
        let notes = [truncationNote(shown), tool.truncated ? "Preview truncated. The full result is retained in context." : nil]
            .compactMap { $0 }.joined(separator: " · ")
        if let edit = TranscriptActivity.editRequest(shown) {
            return .diff(edit, path: description.path, outcome: outcome, added: tool.added, removed: tool.removed)
        } else if description.kind == .command {
            return .terminal(command: TranscriptActivity.parseCommand(shown.input) ?? description.object,
                             output: tool.output, failed: outcome == .failed)
        } else if description.kind == .read, !tool.output.isEmpty {
            return .read(text: tool.output, firstLine: TranscriptReadCardText.firstLine(of: shown.input),
                         path: description.path, failed: outcome == .failed)
        }
        let arguments = TranscriptActivity.argumentsText(shown)
        // A file call whose arguments did not read as a request (a write
        // with no content, say) still opens its file from the card.
        return .io(path: linked ? description.path : nil,
                   input: arguments.text.isEmpty
                       ? "The host bounded this call's arguments and none of them could be read."
                       : arguments.text,
                   output: tool.output.isEmpty ? nil : tool.output,
                   failed: outcome == .failed,
                   note: [notes.isEmpty ? nil : notes,
                          arguments.complete ? nil : "The host bounded this call's arguments. This is the part that arrived, not the whole request."]
                       .compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
    }
    /// The call as the card should read it: the fetched document when one has
    /// arrived, otherwise the inline one.
    nonisolated private static func requested(_ tool: ToolView, fetched: ToolInputDocument?) -> ToolView {
        guard let fetched else { return tool }
        var copy = tool
        copy.input = fetched.input
        copy.inputTruncated = fetched.truncated ? true : nil
        copy.inputBytes = fetched.bytes
        return copy
    }
    /// What the card says when even what it is showing is short of the request.
    nonisolated private static func truncationNote(_ current: ToolView) -> String? {
        guard current.inputTruncated == true else { return nil }
        guard let bytes = current.inputBytes, bytes > 0 else { return "Preview truncated" }
        return "Preview truncated · \(ToolInputDisplay.shortSize(bytes))"
    }
}

/// A message row's hover pills (`RowActionsView`).
enum TranscriptRowPills {
    /// One pill: its label, whether it wears the accent, and what it does.
    struct Pill: Identifiable {
        let title: String
        var accent = false
        let perform: () -> Void
        var id: String { title }
    }
    /// The pills a hovered row shows, in order.
    static func pills(_ message: TranscriptMessage, actions: TranscriptActions, forks: Bool, source: ReplySourceToggle?) -> [Pill] {
        var pills: [Pill] = []
        if TranscriptMessageRows.editable(message) { pills.append(Pill(title: "Edit", accent: true) { actions.edit(message.id) }) }
        pills.append(Pill(title: "Copy") { actions.copyMessage(message.id) })
        if let source { pills.append(Pill(title: ReplySource.title(raw: source.raw), perform: source.toggle)) }
        pills.append(Pill(title: "Details") { actions.inspect(message.id) })
        if ReplyMenu.forks(message, enabled: forks), let fork = actions.fork { pills.append(Pill(title: "Fork from here") { fork(message.id) }) }
        return pills
    }
}

/// What a message row says beside its text (`MessageRowView`).
enum TranscriptMessageRows {
    /// Between a user bubble's skill pills and its text.
    nonisolated static let skillGap: CGFloat = 8
    /// The line under a reply that ended before its natural end: at the output
    /// limit it says what to do next; otherwise it names the provider's reason.
    nonisolated static func earlyEnd(_ stopReason: String?) -> String? {
        stopReason == "length" ? "The reply reached the output limit. Ask the model to continue." : TranscriptActivity.earlyEnd(stopReason)
    }
    /// Whether a row offers Edit: a message the reader sent, in the latest
    /// version. An earlier version on screen is read-only.
    nonisolated static func editable(_ message: TranscriptMessage) -> Bool {
        message.role == "user" && message.kind == nil && message.earlierVersion != true
    }
}

/// A read's card, as words (`TranscriptReadCard`).
enum TranscriptReadCardText {
    /// A read's result as the card reads it: its lines, and the host's note
    /// when the read stopped short of the file. The host ends a bounded read
    /// with "[Truncated. N total lines; read another range.]": a note about
    /// the file, not its next line.
    nonisolated static func window(of text: String) -> (lines: [String], note: String?) {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let last = lines.last, last.hasPrefix("[Truncated."), last.hasSuffix("]") {
            let note = String(last.dropFirst().dropLast())
            lines.removeLast()
            return (lines, note)
        }
        return (lines, nil)
    }
    /// The line a read started at, from its arguments: the host's `offset`, a
    /// 1-based line number, or the first line when the read named none.
    nonisolated static func firstLine(of input: String) -> Int {
        guard let offset = TranscriptActivity.parseInput(input)["offset"] as? NSNumber,
              CFGetTypeID(offset) != CFBooleanGetTypeID() else { return 1 }
        let value = offset.doubleValue
        guard value.isFinite, value >= 1, value.rounded() == value, value <= 10_000_000 else { return 1 }
        return Int(value)
    }
    /// "Showing 12 of 340 lines", and nothing at all when it is showing all
    /// of them: a card that is complete should not say so on every read.
    nonisolated static func window(shown: Int, total: Int) -> String {
        shown >= total ? "\(total) line\(total == 1 ? "" : "s")" : "Showing \(shown) of \(total) lines"
    }
}

/// A response part's closed line (`TimelinePartRow`).
enum TranscriptTimelineText {
    /// What a closed row says about the thought inside it: the newest line
    /// while it is still being written, and its first line once it settles.
    ///
    /// A streaming thought redraws this row on every delta, so the summary
    /// reads only the line it shows — back from the end to the newline before
    /// it, or on from the start to the newline after it. Trimming and
    /// splitting the whole thought made every delta cost the thought so far.
    nonisolated static func thinkSummary(_ text: String, running: Bool) -> String {
        let scalars = text.unicodeScalars
        let blank = CharacterSet.whitespacesAndNewlines
        let visible: (Unicode.Scalar) -> Bool = { !blank.contains($0) }
        let line: Substring.UnicodeScalarView
        if running {
            guard let last = scalars.lastIndex(where: visible) else { return "" }
            let start = scalars[..<last].lastIndex(of: "\n").map { scalars.index(after: $0) } ?? scalars.startIndex
            line = scalars[start...last]
        } else {
            guard let first = scalars.firstIndex(where: visible) else { return "" }
            line = scalars[first..<(scalars[first...].firstIndex(of: "\n") ?? scalars.endIndex)]
        }
        return String(Substring(line)).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A turn's duration as the report says it (`TurnDurationMetrics`).
enum TurnDurationText {
    /// A running clock counts whole seconds, as every running clock in the
    /// app does: a live reading with milliseconds changed its digits — and,
    /// trailing zeros trimmed, its width — on every tick. A settled reading
    /// is rounded too (`92 ms`, `19.7s`, `1m 05s`): three decimals of a
    /// millisecond said nothing a reader could use. The Session Inspector
    /// keeps each request's exact time.
    nonisolated static func label(_ milliseconds: Double, live: Bool) -> String {
        live ? MetricFormat.runDuration(milliseconds) : MetricFormat.turnDuration(milliseconds)
    }
}

extension TurnPillsPresentation {
    /// A turn's figures as Copy Turn Info copies them (`TurnLineView`).
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

/// A user bubble's skill pills (`TranscriptSkillPills`).
enum TranscriptSkillPillMetrics {
    /// Between two pills, and between their rows.
    nonisolated static let spacing: CGFloat = 6
}

/// One part of a response as its row reads it (`TimelinePartRow`): the
/// message it stands for, its title, icon and state.
struct TranscriptTimelinePart {
    let part: ResponseTimeline.Segment
    let message: TranscriptMessage
    var source: TranscriptMessage {
        var value = message
        value.kind = nil; value.role = "assistant"; value.text = part.text
        value.thinking = nil; value.tools = nil; value.responseTimeline = nil
        value.accounting = nil; value.truncated = part.truncated
        value.state = message.isStreaming && part.state == "streaming" ? "streaming" : "complete"
        return value
    }
    var title: String {
        switch part.part.kind {
        // Reasoning is one word on the line, whichever form the provider
        // returned it in: what the reader wants from a closed row is the
        // thought, not the name of the channel it arrived on.
        case "reasoningSummary", "reasoningText": return "Think"
        case "toolArguments": return "Preparing \(part.part.name ?? "tool")"
        case "opaque": return "Opaque provider item"
        case "correction": return "Corrected response content"
        case "status": return part.text
        default: return "Response part"
        }
    }
    var reasoning: Bool { ["reasoningText","reasoningSummary"].contains(part.part.kind) }
    var icon: String {
        switch part.part.kind {
        case "reasoningSummary", "reasoningText": return "brain"
        case "toolArguments": return "hammer"
        case "correction": return "arrow.uturn.backward"
        case "status": return "info.circle"
        default: return "circle"
        }
    }
    /// A part that was cut off is amber, not red: it did not fail, it was
    /// stopped. Anything still arriving shimmers.
    var state: TranscriptRowState {
        if part.state == "interrupted" { return .stopped }
        return source.isStreaming ? .running : .ok
    }
}
