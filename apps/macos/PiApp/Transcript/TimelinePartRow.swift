import SwiftUI

/// One part of a response, at the position it arrived at: the reply's prose,
/// the reasoning it returned, or the card of the call it made. A call's card is
/// the same card a legacy reply shows in its work list — its label, its diff,
/// its output and its clock — drawn here rather than under the reply, because
/// this is where it happened.
struct TimelinePartRow: View {
    let part: ResponseTimeline.Segment
    let message: TranscriptMessage
    let actions: TranscriptActions
    let open: Bool
    let toggle: () -> Void
    /// The card of the call this part made, when the reply carries it.
    var card: ToolView? = nil
    /// Whether that card is open, and the full arguments fetched for it.
    var cardOpen = false
    var fetched: ToolInputDocument? = nil
    var toggleCard: () -> Void = {}
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
    private var reasoning: Bool { ["reasoningText","reasoningSummary"].contains(part.part.kind) }
    private var icon: String {
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
    private var state: TranscriptRowState {
        if part.state == "interrupted" { return .stopped }
        return source.isStreaming ? .running : .ok
    }
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
    var body: some View {
        if ["text","refusal"].contains(part.part.kind) {
            MessageRowView(message:source,actions:actions,inlineAccounting:false).equatable().padding(.bottom,10)
        } else if let card {
            // The call, where it was made. Its arguments are the card's own
            // details, so the raw document is not shown a second time.
            ActionRowView(tool:card, open:cardOpen, fetched:fetched, toggle:toggleCard).equatable()
                .padding(.leading,4)
        } else {
            let running = source.isStreaming
            TranscriptWorkRow(icon: icon, title: title,
                              summary: reasoning ? Self.thinkSummary(part.text, running: running)
                                                 : (part.part.kind == "status" ? "" : TranscriptActivity.firstLine(part.text)),
                              state: state, open: open, toggle: toggle,
                              follow: reasoning && running) {
                VStack(alignment:.leading,spacing:6) {
                    if part.part.kind == "toolArguments" {
                        CodeBlockView(language:"json",code:part.text,streaming:running)
                    } else if part.part.kind != "status" {
                        MarkdownBodyView(source:part.text,style:reasoning ? .reasoning : .prose,capsWidth:false,streaming:running).equatable()
                    }
                    Text(part.part.evidence == "observed" ? "Observed delivery order" : "\(part.part.evidence) · arrival timing unavailable").font(.system(size:10.5)).foregroundStyle(TranscriptPalette.faint)
                    if part.truncated { Text("This older timeline fragment was saved without its remaining text.").font(.system(size:11)).foregroundStyle(TranscriptPalette.warning) }
                    Button("Request details") { actions.inspect(message.id) }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(TranscriptPalette.faint)
                }
                .padding(.top,4).padding(.leading,TranscriptRowChrome.indent).padding(.bottom,4)
            }
            .padding(.leading,4)
        }
    }
}

/// The header line of one response: what it did, and the one control that
/// folds it down to this line. There is no longer a second control that hides
/// everything inside a response — the end-of-turn fold does that job for the
/// whole turn, and two fold buttons on one line was one more than the reader
/// ever had a reason to choose between. Folding forgets nothing: opening the
/// response again restores exactly the response that was folded.
struct ResponseHeaderRow: View {
    let line: ResponseLine
    let message: TranscriptMessage
    let actions: TranscriptActions
    let live: Bool
    /// Everything inside the response is folded — by the one-line fold, or by
    /// the Fold Response command.
    let folded: Bool
    /// The response itself is folded to this line.
    let collapsed: Bool
    var toggleCollapsed: () -> Void = {}
    @State private var hovering = false
    @Environment(\.transcriptForks) private var forks
    /// A response with nothing inside to fold keeps a short strip rather than
    /// a line of text: its words are the response, and a line naming them
    /// would be noise above every reply. The strip's height comes from the
    /// response, never from the pointer, so hovering it moves nothing.
    private var compact: Bool { !line.foldable && !collapsed }
    /// A plain answer says nothing until the pointer is over it.
    private var quiet: Bool { compact && !folded && !hovering }
    private var summary: String {
        guard !quiet else { return "" }
        var parts = [line.work]
        if let duration = line.duration, !duration.isEmpty { parts.append(duration) }
        if collapsed, line.parts > 0 { parts.append("\(line.parts) " + (line.parts == 1 ? "part" : "parts") + " folded") }
        if let figures = line.figures, folded { parts.append(figures) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 4) {
            if live { SpinnerView() }
            Text(summary).font(.system(size: compact ? 11 : 12.5, weight: .medium))
                .foregroundStyle(hovering || collapsed ? TranscriptPalette.muted : TranscriptPalette.faint)
                .lineLimit(1).truncationMode(.tail).monospacedDigit()
            Spacer(minLength: 0)
            Button(action: toggleCollapsed) {
                Image(systemName: collapsed ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .frame(width: 18, height: compact ? 14 : 16)
                    .background(hovering ? TranscriptPalette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain).piPointer()
            .opacity(hovering || collapsed ? 1 : 0)
            .help(collapsed ? "Show this response" : "Fold this response to one line")
            .accessibilityLabel(collapsed ? "Show this response" : "Fold this response to one line")
        }
        // A line with nothing to say takes the space of paragraph spacing,
        // not of a line of text: a plain answer must not be preceded by an
        // empty row. It is still the strip that reveals the fold control.
        .frame(height: compact ? 14 : 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleCollapsed)
        .onHover { hovering = $0 }
        .padding(.top, compact ? 0 : 4).padding(.bottom, collapsed ? 10 : compact ? 0 : 2)
        .contextMenu {
            PiMenuContent { [actions, message, collapsed, toggleCollapsed, forks] in
                ReplyMenu.entries(message, actions: actions, forks: forks, fold: (collapsed ? "Show This Response" : "Fold This Response to One Line", toggleCollapsed))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Response · \(summary)")
    }
}
struct RequestTimelineInfo: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if let accounting = message.accounting, accounting.requests > 0 { MessageAccountingView(accounting:accounting,onInspect:{ actions.inspect(message.id) }) }
            if let detail = message.detail { Text(detail).font(.system(size:11)).foregroundStyle(TranscriptPalette.faint) }
            // The partial answer already carries the Stopped chip.

            if let notice = TranscriptActivity.earlyEnd(message.stopReason) { Text(notice).font(.system(size:12)).foregroundStyle(TranscriptPalette.warning) }
        }.padding(.bottom,6)
    }
}
struct ToolResultTimelineRow: View {
    let message: TranscriptMessage
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Button(action:toggle) { Label(message.detail ?? "Tool result recorded",systemImage:open ? "chevron.down":"chevron.right").font(.system(size:12.5)) }.buttonStyle(.plain).foregroundStyle(TranscriptPalette.muted)
            if open { MarkdownBodyView(source:message.text).equatable() }
        }.padding(.vertical,6)
    }
}
struct ExecutionTimelineRow: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Button(action:toggle) {
                Label(message.detail ?? message.text,systemImage:open ? "chevron.down":"chevron.right").font(.system(size:12.5,weight:.medium))
            }.buttonStyle(.plain).foregroundStyle(TranscriptPalette.muted)
            if open, let timeline = message.responseTimeline, timeline.supported {
                ForEach(timeline.segments) { part in
                    TimelinePartRow(part:part,message:message,actions:actions,open:true,toggle:{})
                }
                if timeline.terminal == nil { Text("No terminal receipt yet").font(.system(size:11)).foregroundStyle(TranscriptPalette.warning) }
            }
        }.padding(.vertical,8)
    }
}
