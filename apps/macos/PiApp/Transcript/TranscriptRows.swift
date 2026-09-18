import SwiftUI
import AppKit

// The rows of the conversation, drawn natively: user bubbles, replies with
// their work line, tool cards with diffs, turn lines, and the status rows the
// host and app add. Every figure comes from TranscriptActivity; nothing here
// computes usage or timing itself.

/// What a row can ask the pane to do.
struct TranscriptActions {
    var inspect: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    var copyMessage: (String) -> Void = { _ in }
    var stop: () -> Void = {}
}

enum TranscriptMetrics {
    static let proseWidth: CGFloat = 640
    static let pageWidth: CGFloat = 840
}

/// The dots between figures on a work or turn line, as the stylesheet drew them.
private func dotted(_ parts: [Text]) -> Text {
    var result = Text("")
    for (index, part) in parts.enumerated() {
        if index > 0 { result = result + Text(" · ").foregroundColor(TranscriptPalette.faint) }
        result = result + part
    }
    return result
}
private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

/// One figure of a work or turn line: a text, or a control such as the model
/// link; a dot precedes every figure but the first unless it says otherwise.
struct FigureItem {
    var text: Text? = nil
    var view: AnyView? = nil
    var dotted = true
    static func text(_ text: Text) -> FigureItem { FigureItem(text: text) }
    static func view<V: View>(_ view: V, dotted: Bool = true) -> FigureItem { FigureItem(view: AnyView(view), dotted: dotted) }
}

/// Figures that flow like a sentence: a narrow pane wraps between them, never
/// after a dot, and a control keeps its place in the sentence.
struct FigureFlow: View {
    let items: [FigureItem]
    var font: Font = .system(size: 12.5, weight: .medium)
    var color: Color = TranscriptPalette.faint
    var body: some View {
        PiFlow(spacing: 0, rowSpacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                // The dot trails the figure it follows, so a wrapped line never starts with one.
                HStack(spacing: 0) {
                    if let text = item.text { text.font(font).foregroundStyle(color).monospacedDigit() }
                    if let view = item.view { view }
                    if index + 1 < items.count && items[index + 1].dotted { Text(" · ").font(font).foregroundStyle(TranscriptPalette.faint) }
                }
            }
        }
    }
}

/// A small ring that turns while something is under way.
struct SpinnerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8 * 360
            Circle().trim(from: 0.2, to: 1).stroke(TranscriptPalette.hairStrong, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .overlay(Circle().trim(from: 0, to: 0.22).stroke(TranscriptPalette.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
                .rotationEffect(.degrees(angle))
                .frame(width: 11, height: 11)
        }
        .accessibilityHidden(true)
    }
}

/// The pill buttons under a row: Edit (user rows), Copy and Details. They show on hover.
private struct RowActionsView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    let visible: Bool
    var body: some View {
        HStack(spacing: 4) {
            if message.role == "user" && message.kind == nil { pill("Edit", accent: true) { actions.edit(message.id) } }
            pill("Copy") { actions.copyMessage(message.id) }
            pill("Details") { actions.inspect(message.id) }
        }
        .opacity(visible ? 1 : 0).offset(y: visible ? 0 : 2)
        .animation(.easeOut(duration: 0.14), value: visible)
        .accessibilityElement(children: .contain).accessibilityLabel("Actions for \(message.role) message")
    }
    private func pill(_ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11, weight: .medium)) }
            .buttonStyle(TranscriptPillStyle(accent: accent))
    }
}

struct TranscriptPillStyle: ButtonStyle {
    var accent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? (accent ? TranscriptPalette.accent : TranscriptPalette.text) : TranscriptPalette.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.panelStrong : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(hovering && accent ? TranscriptPalette.accent : TranscriptPalette.hairStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .piPointer()
    }
}

// MARK: - Markdown body

/// A rendered markdown body: paragraphs, headings with copy controls, code
/// blocks with their toolbar, lists, quotes and tables.
struct MarkdownBodyView: View {
    let source: String
    var style: MarkdownStyle = .prose
    var capsWidth = true
    var streaming = false
    var copyTargets: [MarkdownCopyTarget] = []
    @State private var hovering = false
    var body: some View {
        let blocks = streaming ? TranscriptMarkdown.streamingBlocks(source, style: style) : TranscriptMarkdown.blocks(source, style: style)
        let headings = copyTargets.filter { if case .section = $0.kind { return true }; return false }
        let introduction = copyTargets.first { $0.kind == .introduction || $0.kind == .whole }
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty && streaming { WaitingDots() }
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let isLast = index == blocks.count - 1
                MarkdownBlockView(block: block, style: style, capsWidth: capsWidth, caret: streaming && isLast,
                                  headingTarget: headingTarget(block, headings: headings, blocks: blocks, index: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if let introduction, !streaming { CopyButton(target: introduction, visible: hovering).offset(y: -3) }
        }
        .onHover { hovering = $0 }
        .textSelection(.enabled)
    }
    /// The nth heading block copies the nth heading section the scanner found.
    private func headingTarget(_ block: MarkdownBlock, headings: [MarkdownCopyTarget], blocks: [MarkdownBlock], index: Int) -> MarkdownCopyTarget? {
        guard case .heading = block, !headings.isEmpty else { return nil }
        let position = blocks[...index].filter { if case .heading = $0 { return true }; return false }.count - 1
        return headings.indices.contains(position) ? headings[position] : nil
    }
}

/// Three pulsing dots before the first token arrives.
struct WaitingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let phase = reduceMotion ? 3 : Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(TranscriptPalette.muted).frame(width: 7, height: 7).opacity(phase == 0 ? 0.25 : index < phase ? 1 : 0.25)
                }
            }
        }
        .frame(height: 22).accessibilityLabel("Waiting for the reply")
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle
    let capsWidth: Bool
    var caret = false
    var headingTarget: MarkdownCopyTarget? = nil
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        switch block {
        case .paragraph(let text):
            proseText(text).frame(maxWidth: capsWidth ? TranscriptMetrics.proseWidth : .infinity, alignment: .leading)
        case .heading(_, let text, _):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                proseText(text)
                if let headingTarget { CopyButton(target: headingTarget, visible: hovering) }
            }
            .padding(.top, 6)
            .frame(maxWidth: capsWidth ? TranscriptMetrics.proseWidth : .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, size: style.baseSize * 0.86)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(start + index)." : "•").font(.system(size: style.baseSize)).foregroundStyle(style.textColor).frame(minWidth: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.enumerated()), id: \.offset) { _, nested in MarkdownBlockView(block: nested, style: style, capsWidth: false) }
                        }
                    }
                }
            }
            .padding(.leading, 4)
            .frame(maxWidth: capsWidth ? TranscriptMetrics.proseWidth : .infinity, alignment: .leading)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(TranscriptPalette.hairStrong).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, nested in MarkdownBlockView(block: nested, style: MarkdownStyle(id: style.id + ".quote", baseSize: style.baseSize, keepsSoftBreaks: style.keepsSoftBreaks, textColor: TranscriptPalette.muted, codeBackground: style.codeBackground, linkColor: style.linkColor), capsWidth: false) }
                }
            }
            .frame(maxWidth: capsWidth ? TranscriptMetrics.proseWidth : .infinity, alignment: .leading)
        case .table(let alignments, let header, let rows):
            MarkdownTableView(alignments: alignments, header: header, rows: rows)
        }
    }
    @ViewBuilder private func proseText(_ text: AttributedString) -> some View {
        if caret {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                Text(text) + Text(" ▍").foregroundColor(on ? TranscriptPalette.accent : .clear)
            }
            .lineSpacing(style.baseSize * 0.35)
        } else {
            Text(text).lineSpacing(style.baseSize * 0.35)
        }
    }
}

/// A code block: monospaced, wrapped, with the language and a copy control on hover.
struct CodeBlockView: View {
    let language: String?
    let code: String
    var size: CGFloat = 12.5
    @State private var hovering = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(SyntaxHighlighter.attributed(code, language: language, size: size))
                .lineSpacing(size * 0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 31).padding(.bottom, 10)
            HStack(spacing: 6) {
                if let language { Text(language.lowercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(TranscriptPalette.faint).opacity(hovering ? 1 : 0).accessibilityLabel("Language \(language)") }
                CopyButton(target: MarkdownCopyTarget(kind: .code, label: "Copy code", text: code), visible: hovering)
            }
            .padding(.trailing, 8).padding(.top, 5)
        }
        .background(TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Copies a markdown target to the clipboard and says so for two seconds.
struct CopyButton: View {
    let target: MarkdownCopyTarget
    let visible: Bool
    @State private var copied = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target.text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(copied && !reduceMotion ? 1.1 : 1).animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.6), value: copied)
                Text(copied ? "Copied" : "Copy").font(.system(size: 10.5, weight: .medium)).contentTransition(.opacity)
            }
            .foregroundStyle(copied ? TranscriptPalette.accent : hovering ? TranscriptPalette.text : TranscriptPalette.muted)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.panelStrong : TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(copied ? TranscriptPalette.accent.opacity(0.4) : hovering ? TranscriptPalette.hairStrong : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).piPointer()
        .opacity(visible || copied || hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: visible || copied || hovering)
        .onHover { hovering = $0 }
        .help(target.label).accessibilityLabel(target.label)
    }
}

private struct MarkdownTableView: View {
    let alignments: [MarkdownAlignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]
    private func alignment(_ column: Int) -> Alignment {
        guard alignments.indices.contains(column) else { return .leading }
        switch alignments[column] { case .center: return .center; case .right: return .trailing; case .left: return .leading }
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !header.isEmpty {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { index, cell in cellView(cell, column: index, header: true) } }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { index, cell in cellView(cell, column: index, header: false) } }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(TranscriptPalette.hair, lineWidth: 1))
        }
        .padding(.vertical, 2)
    }
    private func cellView(_ cell: AttributedString, column: Int, header: Bool) -> some View {
        Text(header ? bolded(cell) : cell)
            .frame(maxWidth: .infinity, alignment: alignment(column))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(header ? TranscriptPalette.panel : Color.clear)
            .overlay(Rectangle().stroke(TranscriptPalette.hair, lineWidth: 0.5))
    }
    private func bolded(_ text: AttributedString) -> AttributedString {
        var copy = text
        copy.font = .system(size: 13, weight: .semibold)
        return copy
    }
}

// MARK: - Per-request accounting line

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

// MARK: - Message rows

/// A message row: user bubble, reply prose, status pill, or one of the marker rows.
struct MessageRowView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    var inlineAccounting = true
    @State private var hovering = false
    var body: some View {
        switch message.kind {
        case "compaction": CompactionRowView(message: message, actions: actions)
        case "branch": BranchRowView(message: message)
        case "failure": FailureRowView(message: message)
        case "notice": NoticeRowView(message: message)
        default: plain
        }
    }
    private var failed: Bool { ["error", "aborted"].contains(message.state ?? "") }
    @ViewBuilder private var plain: some View {
        let copyTargets = message.role == "assistant" && !message.isStreaming ? TranscriptCopy.targets(in: message.text) : []
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
            if message.role == "system" || failed {
                HStack(spacing: 8) {
                    if message.role == "system" { Text("Status").font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptPalette.muted) }
                    if failed { Text(message.state ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.danger) }
                }.frame(maxWidth: .infinity, alignment: message.role == "system" ? .center : .leading)
            }
            if message.role == "user" {
                HStack(spacing: 0) {
                    Spacer(minLength: 40)
                    MarkdownBodyView(source: message.text, style: .user, capsWidth: false)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(TranscriptPalette.userBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: TranscriptMetrics.proseWidth, alignment: .trailing)
                }
            } else if message.role == "system" {
                Text(message.text).font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(TranscriptPalette.statusBackground, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if !(message.role == "assistant" && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(message.tools ?? []).isEmpty) {
                // A reply that only called tools keeps its row for anchors and receipts, but shows no body.
                MarkdownBodyView(source: message.text, streaming: message.isStreaming, copyTargets: copyTargets)
            }
            if message.truncated == true {
                Text("Display preview truncated. Full retained content is available in the native message viewer.").font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted)
            }
            // One quiet band under the row for its time, usage and actions; the
            // actions appear on hover without moving anything.
            HStack(alignment: .center, spacing: 10) {
                if inlineAccounting, let accounting = message.accounting, message.role != "user" { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }) }
                if message.role != "user" { Spacer(minLength: 0) }
                if message.role == "user", let at = message.at {
                    Text(TranscriptActivity.formatClock(at)).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.faint).monospacedDigit()
                        .opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.14), value: hovering)
                        .accessibilityLabel("Sent at \(TranscriptActivity.formatClock(at))")
                }
                RowActionsView(message: message, actions: actions, visible: hovering)
                if message.role == "user", inlineAccounting, let accounting = message.accounting { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }, trailing: true) }
            }
            .frame(height: 22)
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.role) message")
    }
}

private struct CompactionRowView: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    @State private var open = false
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 24, height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("⇣").font(.system(size: 12, weight: .semibold)).foregroundStyle(TranscriptPalette.accent).frame(width: 20, height: 20).background(TranscriptPalette.accentSoft, in: Circle())
                    Text("Context compacted").font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(TranscriptPalette.text)
                    if let detail = message.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted).lineLimit(1).monospacedDigit() }
                    Spacer(minLength: 0)
                    RowActionsView(message: message, actions: actions, visible: hovering)
                }
                if !message.text.isEmpty {
                    DisclosureGroup(isExpanded: $open) {
                        MarkdownBodyView(source: message.text, style: .summary, capsWidth: false).padding(.top, 6)
                    } label: { Text("Summary kept in context").font(.system(size: 11.5, weight: .medium)).foregroundStyle(TranscriptPalette.faint) }
                    .padding(.top, 6).overlay(alignment: .top) { Rectangle().fill(TranscriptPalette.hair).frame(height: 1) }
                }
                if let accounting = message.accounting { MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(message.id) }) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 620)
            .background(TranscriptPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 24, height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .onHover { hovering = $0 }
        .accessibilityLabel("Context compacted")
    }
}

private struct DashedLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in path.move(to: CGPoint(x: 0, y: 0.5)); path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5)) }
                .stroke(TranscriptPalette.hairStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }.frame(height: 1)
    }
}

private struct BranchRowView: View {
    let message: TranscriptMessage
    var body: some View {
        HStack(spacing: 8) {
            DashedLine()
            Text("Edited from here").font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).fixedSize()
            if let detail = message.detail ?? (message.text.isEmpty ? nil : message.text) { Text(detail).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).lineLimit(2) }
            DashedLine()
        }
        .padding(.vertical, 8)
        .accessibilityLabel("Edited from here")
    }
}

/// A run failure, shown where the conversation stopped rather than in a fixed strip above it.
private struct FailureRowView: View {
    let message: TranscriptMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 18, height: 18).background(TranscriptPalette.danger, in: Circle())
                Text("Something went wrong").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(TranscriptPalette.danger)
            }
            Text(message.text).font(.system(size: 13)).foregroundStyle(TranscriptPalette.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let detail = message.detail { Text(detail).font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TranscriptPalette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TranscriptPalette.danger.opacity(0.35), lineWidth: 1))
        .padding(.vertical, 8)
        .accessibilityLabel("Error: \(message.text)")
    }
}

/// A transient status line inside the conversation, such as a retry in progress; it turns while it waits.
private struct NoticeRowView: View {
    let message: TranscriptMessage
    var body: some View {
        HStack(spacing: 8) {
            DashedLine()
            SpinnerView()
            Text(message.text).font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.muted).fixedSize()
            DashedLine()
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Status: \(message.text)")
    }
}

// MARK: - Work: action rows, diffs, reasoning

private func actionSymbol(_ kind: ActionKind) -> String {
    switch kind {
    case .command: return "terminal"
    case .write: return "pencil"
    case .read: return "doc.text"
    case .list: return "folder"
    case .search: return "magnifyingglass"
    case .mcp: return "point.3.connected.trianglepath.dotted"
    case .other: return "circle"
    }
}

/// What the model asked a file tool to change, as tinted rows. It is the
/// request, not proof of what is on disk, and the label says so.
struct EditDiffView: View {
    let before: String
    let after: String
    let path: String?
    let mode: String            // "edit" or "write"
    let outcome: ActionOutcome
    let created: Bool
    var body: some View {
        let rows: [DiffRow] = mode == "edit" || (created && outcome == .done) ? TranscriptActivity.lineDiff(before, after) : after.components(separatedBy: "\n").map { DiffRow(kind: .context, text: $0) }
        let shown = rows.prefix(400)
        let label = (mode == "edit" ? "Requested edit" : "Requested content") + (outcome == .done ? "" : outcome == .running ? " · in progress" : mode == "edit" ? " · not applied" : " · not written")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(outcome == .done ? TranscriptPalette.muted : outcome == .running ? TranscriptPalette.warning : TranscriptPalette.danger)
                Spacer(minLength: 0)
                if let path { Text(path).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).lineLimit(1).truncationMode(.middle) }
            }
            .padding(.horizontal, 10).padding(.vertical, 4).background(TranscriptPalette.panel)
            Rectangle().fill(TranscriptPalette.hair).frame(height: 1)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ").foregroundStyle(row.kind == .added ? TranscriptPalette.diffAddedMark : row.kind == .removed ? TranscriptPalette.danger : TranscriptPalette.faint).frame(width: 10, alignment: .leading)
                            Text(row.text.isEmpty ? " " : row.text).foregroundStyle(TranscriptPalette.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .background(row.kind == .added ? TranscriptPalette.diffAdded : row.kind == .removed ? TranscriptPalette.danger.opacity(0.1) : Color.clear)
                    }
                    if rows.count > shown.count { Text("… \(rows.count - shown.count) more lines").font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.faint).padding(.horizontal, 28) }
                }
                .textSelection(.enabled)
            }
            .frame(maxHeight: 420)
            .opacity(outcome == .failed || outcome == .cancelled ? 0.72 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
        .padding(.vertical, 6)
    }
}

/// One tool call: a row that opens its card with the command or requested change, the output and the outcome.
struct ActionRowView: View {
    let tool: ToolView
    @State private var open = false
    @State private var hovering = false
    var body: some View {
        let description = TranscriptActivity.describe(tool)
        let outcome = TranscriptActivity.outcome(of: tool)
        let running = outcome == .running, failed = outcome == .failed || outcome == .cancelled
        let status = running ? "Running" : failed ? (outcome == .cancelled ? "Cancelled" : "Failed") : "Success"
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: actionSymbol(description.kind)).font(.system(size: 11, weight: .medium)).foregroundStyle(TranscriptPalette.faint).frame(width: 16)
                        .symbolEffect(.bounce.down, value: running)
                    Text(description.verb).font(.system(size: 13)).foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted).fixedSize()
                    Text(description.object).font(description.kind == .command ? .system(size: 12, design: .monospaced) : .system(size: 13)).foregroundStyle(description.kind == .write ? TranscriptPalette.accent : description.kind == .command ? TranscriptPalette.muted : TranscriptPalette.text).lineLimit(1).truncationMode(.middle)
                        .help(description.path ?? description.object)
                    if tool.added != nil || tool.removed != nil {
                        (Text("+\(tool.added ?? 0)").foregroundColor(TranscriptPalette.success) + Text(" -\(tool.removed ?? 0)").foregroundColor(TranscriptPalette.danger)).font(.system(size: 12)).monospacedDigit().fixedSize()
                    }
                    if failed { Text(status).font(.system(size: 11)).foregroundStyle(TranscriptPalette.danger).padding(.horizontal, 7).padding(.vertical, 1).background(TranscriptPalette.danger.opacity(0.12), in: Capsule()).fixedSize() }
                    if running { Text("Running…").font(.system(size: 11)).foregroundStyle(TranscriptPalette.warning).padding(.horizontal, 7).padding(.vertical, 1).background(TranscriptPalette.warning.opacity(0.14), in: Capsule()).fixedSize() }
                    Spacer(minLength: 0)
                    if let duration = tool.durationMs, !running {
                        Text(TranscriptActivity.formatDuration(duration)).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).monospacedDigit().fixedSize()
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .piAnimation(PiMotion.base, value: running)
                .piAnimation(PiMotion.base, value: failed)
                .padding(.horizontal, 4).padding(.vertical, 5)
                .background(hovering ? TranscriptPalette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).piPointer()
            .onHover { hovering = $0 }
            .accessibilityLabel("\(description.verb) \(description.object), \(status)")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(description.kind == .command ? "Shell" : tool.name).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted)
                    if description.kind == .command {
                        Text("$ " + (TranscriptActivity.parseCommand(tool.input) ?? description.object)).font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if let edit = TranscriptActivity.editTexts(tool) {
                        EditDiffView(before: edit.before, after: edit.after, path: description.path, mode: tool.name == "write" ? "write" : "edit", outcome: outcome, created: tool.added != nil && (tool.removed ?? 0) == 0)
                    } else {
                        ScrollView(.vertical) { Text(tool.input).font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320)
                            .accessibilityLabel("Tool input")
                    }
                    if tool.output.isEmpty {
                        Text("No output").font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.faint)
                    } else {
                        ScrollView(.vertical) { Text(tool.output).font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320)
                            .accessibilityLabel("Tool output")
                    }
                    if tool.truncated { Text("Preview truncated. The full result is retained in context.").font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted) }
                    Text((running ? "⟳ " : failed ? "✕ " : "✓ ") + status).font(.system(size: 12)).foregroundStyle(running ? TranscriptPalette.warning : failed ? TranscriptPalette.danger : TranscriptPalette.success).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
                .background(TranscriptPalette.toolBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
                .padding(.leading, 28).padding(.top, 4).padding(.bottom, 8)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: open)
    }
}

/// The expanded list of one run of tool calls; each row opens its own card.
struct ActivityGroupView: View {
    let tools: [ToolView]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { ForEach(tools) { ActionRowView(tool: $0) } }
            .padding(.leading, 4).padding(.vertical, 2)
            .accessibilityLabel("Tool activity")
    }
}

private struct ReasoningView: View {
    let message: TranscriptMessage
    @State private var open = false
    var body: some View {
        if let thinking = message.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup(isExpanded: $open) {
                MarkdownBodyView(source: thinking, style: .reasoning, capsWidth: false).padding(.top, 6)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            } label: { Text("Exposed reasoning").font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.faint) }
            .animation(.easeOut(duration: 0.22), value: open)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Blocks and turns

/// A reply in the order it happened: first what the model did before
/// answering (its exposed reasoning, one row per tool call, the figures of
/// each request), then the reply, then the figures of the turn. The work rows
/// stay in view; the chevron on their header folds them.
struct BlockRowView: View {
    let block: TranscriptBlock
    let actions: TranscriptActions
    var fresh = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    @State private var open = true
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let reasoned = TranscriptActivity.blockReasoned(block)
        let hasWork = !block.tools.isEmpty || reasoned
        let summary = TranscriptActivity.summarizeWork(block.tools, reasoned: reasoned)
        let accounting = block.accounting
        let tokens = TranscriptActivity.tokens(of: accounting)
        let hasUsage = tokens != nil || accounting.costUSD != nil || accounting.model != nil
        let merged = block.turn != nil && block.turn!.replies == 1
        let trail = block.live && !open ? Array(block.tools.suffix(3)) : []
        let settled = fresh && !block.live
        VStack(alignment: .leading, spacing: 4) {
            if hasWork {
                VStack(alignment: .leading, spacing: 2) {
                    workHeader(summary: summary)
                    if reasoned && !open, let teaser = TranscriptActivity.reasoningTeaser(block.replies.compactMap(\.thinking).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.last ?? "") {
                        Text(teaser).font(.system(size: 12).italic()).foregroundStyle(TranscriptPalette.muted).lineLimit(1)
                            .help("The reply's exposed reasoning begins like this; expand the line for all of it")
                    }
                    if !trail.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(trail) { tool in
                                let description = TranscriptActivity.describe(tool), outcome = TranscriptActivity.outcome(of: tool)
                                HStack(spacing: 6) {
                                    if outcome == .running { SpinnerView() } else { Text(outcome == .done ? "✓" : "✕").font(.system(size: 11)).foregroundStyle(outcome == .done ? TranscriptPalette.muted : TranscriptPalette.danger).frame(width: 11) }
                                    Text(description.verb).font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.text)
                                    Text(description.object).font(description.kind == .command ? .system(size: 11.5, design: .monospaced) : .system(size: 12)).foregroundStyle(TranscriptPalette.muted).lineLimit(1).truncationMode(.middle)
                                }
                                .transition(.opacity.combined(with: .offset(y: 6)))
                            }
                        }
                        .padding(.vertical, 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: trail.map(\.id))
                        .accessibilityLabel("Recent actions")
                    }
                    if open {
                        // Every request of the block in order: reasoning, its tool calls, its figures.
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(block.replies) { reply in
                                VStack(alignment: .leading, spacing: 2) {
                                    ReasoningView(message: reply)
                                    if let tools = reply.tools, !tools.isEmpty { ActivityGroupView(tools: tools) }
                                    if let accounting = reply.accounting, !(reply.tools ?? []).isEmpty || !(reply.thinking ?? "").isEmpty || reply.id != block.message?.id {
                                        MessageAccountingView(accounting: accounting, onInspect: { actions.inspect(reply.id) })
                                    }
                                }
                            }
                        }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(TranscriptPalette.hairStrong).frame(width: 2) }
                        .padding(.top, 2).padding(.leading, 2).padding(.bottom, 4)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: open)
                .onHover { hovering = $0 }
            }
            if let message = block.message { MessageRowView(message: message, actions: actions, inlineAccounting: false) }
            // A reply inside a multi-reply turn keeps its own figures; the turn line closes the turn.
            if !block.live, !merged, hasUsage { replyFigures(tokens: tokens) }
            if let turn = block.turn, !turn.live { TurnLineView(turn: turn, settled: settled, now: now, actions: actions, model: accounting.model, modelMessageID: accounting.modelMessageID) }
        }
        .padding(.bottom, 10)
    }
    /// The header of the work rows: what the reply did, and the chevron that folds the rows.
    private func workHeader(summary: String?) -> some View {
        HStack(spacing: 4) {
            if block.live && block.tools.contains(where: { TranscriptActivity.outcome(of: $0) == .running }) { SpinnerView() }
            Text(summary ?? "Working").font(.system(size: 12.5, weight: .medium)).foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted)
            Button { open.toggle() } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.faint)
                    .rotationEffect(.degrees(open ? 0 : -90)).frame(width: 20, height: 18)
                    .background(hovering ? TranscriptPalette.panel : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain).piPointer()
            .help(open ? "Hide the tool calls and request details" : "Show the tool calls and request details")
            .accessibilityLabel(open ? "Hide work" : "Show work")
        }
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
    /// Under a reply of a multi-reply turn: how long it took, its tokens, cost and model.
    private func replyFigures(tokens: Double?) -> some View {
        let accounting = block.accounting
        let elapsed: Double? = { if let s = block.startedAt, let e = block.endedAt, e >= s { return e - s }; return nil }()
        var items: [FigureItem] = []
        if let elapsed { items.append(.text(Text(TranscriptActivity.formatDuration(elapsed)))) }
        if let tokens { items.append(.text(Text("\(TranscriptActivity.formatTokenCount(tokens)) tokens"))) }
        if let cost = accounting.costUSD { items.append(.text(Text(TranscriptActivity.formatTurnCost(cost) + (accounting.costSamples < accounting.requests ? " (\(accounting.costSamples)/\(accounting.requests))" : "")))) }
        if let model = accounting.model {
            items.append(.view(Button { actions.inspect(accounting.modelMessageID ?? block.id) } label: {
                HStack(spacing: 3) { Text(model).font(.system(size: 12, weight: .medium)); Image(systemName: "info.circle").font(.system(size: 11)) }.foregroundStyle(TranscriptPalette.faint)
            }.buttonStyle(.plain).piPointer().help("View response-body and header models").accessibilityLabel("View model reports: \(model)")))
        }
        return FigureFlow(items: items, font: .system(size: 12, weight: .medium), color: TranscriptPalette.faint)
            .help(accounting.requests > 0 ? TranscriptActivity.usageBreakdown(accounting) : "")
    }
}

/// Under the last reply of a turn: how long the whole turn took, its replies,
/// tool calls and files changed, model versus tool time, its usage, and the
/// model as a link to the request. A turn that has just settled glows for a moment.
struct TurnLineView: View {
    let turn: TurnSummary
    var settled = false
    var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    var actions = TranscriptActions()
    var model: String? = nil
    var modelMessageID: String? = nil
    @State private var hovering = false
    var body: some View {
        let stamps = [turn.startedAt.map { "Started " + TranscriptActivity.formatClock($0) }, turn.live ? nil : turn.endedAt.map { "finished " + TranscriptActivity.formatClock($0) }].compactMap { $0 }.joined(separator: " · ")
        let usage = TranscriptActivity.usageBreakdown(turn.accounting)
        var items: [FigureItem] = [.text(Text(turn.partial ? "Turn (partial)" : "Turn").fontWeight(.semibold).foregroundColor(TranscriptPalette.muted))]
        if let elapsed = turn.elapsedMs { items.append(.text(Text(TranscriptActivity.formatDuration(elapsed)))) }
        items.append(.text(Text(TurnLineView.counts(turn))))
        if turn.modelMs > 0 || turn.toolMs > 0 { items.append(.text(Text("model \(TranscriptActivity.formatDuration(turn.modelMs)) · tools \(TranscriptActivity.formatDuration(turn.toolMs))"))) }
        if !usage.isEmpty { items.append(.text(Text(usage).foregroundColor(TranscriptPalette.muted))) }
        if let model = model ?? turn.accounting.model {
            let target = modelMessageID ?? turn.accounting.modelMessageID
            items.append(.view(Button { if let target { actions.inspect(target) } } label: {
                HStack(spacing: 3) { Text(model).font(.system(size: 12, weight: .medium)); if target != nil { Image(systemName: "info.circle").font(.system(size: 11)) } }.foregroundStyle(TranscriptPalette.faint)
            }.buttonStyle(.plain).piPointer().help("View response-body and header models").accessibilityLabel("View model reports: \(model)")))
        }
        return FigureFlow(items: items, font: .system(size: 12, weight: .medium), color: TranscriptPalette.faint)
            .overlay(alignment: .topTrailing) {
                if hovering, !stamps.isEmpty {
                    Text(stamps).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).monospacedDigit().fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(TranscriptPalette.canvas, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .transition(.opacity)
                }
            }
            .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(settled ? TranscriptPalette.accent.opacity(0.55) : TranscriptPalette.hair).frame(height: 1) }
        .background(settled ? TranscriptPalette.accent.opacity(0.07) : Color.clear)
        .padding(.top, 8)
        .onHover { hovering = $0 }
        .help(turn.partial ? "Earlier replies of this turn are above the loaded history" : "The whole turn: every reply since your message")
        .accessibilityLabel("Turn: \(TurnLineView.counts(turn))")
    }
    static func counts(_ turn: TurnSummary) -> String {
        plural(turn.replies, "reply", "replies") + (turn.tools > 0 ? ", " + plural(turn.tools, "tool call", "tool calls") : "") + (turn.files > 0 ? ", " + plural(turn.files, "file changed", "files changed") : "")
    }
}

/// Docked above the composer while a turn runs: one place that shows the
/// spinner, elapsed time, the action under way, a retry notice, the counts
/// and usage so far, when the turn started, and Stop.
struct LiveTurnBar: View {
    let turn: TurnSummary
    var state = "running"
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var label: String {
        switch state {
        case "queued": return "Waiting to start"
        case "stopping": return "Stopping"
        case "compacting": return "Compacting context"
        default: return "Working"
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed: Double? = turn.startedAt.map { max(turn.elapsedMs ?? 0, context.date.timeIntervalSince1970 * 1000 - $0) } ?? turn.elapsedMs
            let current = turn.current.map(TranscriptActivity.describe)
            let usage = TranscriptActivity.usageBreakdown(turn.accounting)
            var parts: [Text] = [Text(label).foregroundColor(TranscriptPalette.text)]
            if let elapsed { parts.append(Text(TranscriptActivity.formatDuration(elapsed)).fontWeight(.semibold).foregroundColor(TranscriptPalette.text)) }
            if let current { parts.append(Text(current.verb).fontWeight(.medium).foregroundColor(TranscriptPalette.text) + Text(" ") + Text(current.object).font(current.kind == .command ? .system(size: 11.5, design: .monospaced) : .system(size: 12))) }
            if let notice = turn.notice { parts.append(Text(notice).foregroundColor(TranscriptPalette.warning)) }
            if turn.replies > 0 || turn.tools > 0 { parts.append(Text(TurnLineView.counts(turn))) }
            if !usage.isEmpty { parts.append(Text(usage)) }
            if let started = turn.startedAt { parts.append(Text("since " + TranscriptActivity.formatClock(started)).foregroundColor(TranscriptPalette.faint)) }
            return HStack(alignment: .firstTextBaseline, spacing: 8) {
                SpinnerView().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                dotted(parts).font(.system(size: 12, weight: .medium)).foregroundStyle(TranscriptPalette.muted).monospacedDigit().lineSpacing(4)
                Spacer(minLength: 8)
                Button("Stop", action: onStop).buttonStyle(TranscriptStopStyle()).accessibilityLabel("Stop the current run")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(TranscriptPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

struct TranscriptStopStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(TranscriptPalette.danger)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.danger.opacity(0.1) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(TranscriptPalette.danger.opacity(0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }.piPointer()
    }
}

// Rows skip their body while their inputs are unchanged, so a streaming delta
// re-renders only the row that changed and settled rows never parse twice.
extension MessageRowView: Equatable {
    nonisolated static func == (a: MessageRowView, b: MessageRowView) -> Bool { a.message == b.message && a.inlineAccounting == b.inlineAccounting }
}
extension BlockRowView: Equatable {
    nonisolated static func == (a: BlockRowView, b: BlockRowView) -> Bool { a.block == b.block && a.fresh == b.fresh }
}
