import SwiftUI

/// What a work row opens: the call's request and its result, drawn as one card
/// rather than as a column of labelled paragraphs. Four shapes cover every
/// call we make — a file change is a diff, a file read is a numbered window, a
/// command is a terminal, and everything else is the IN/OUT card.
///
/// Every card is bounded the same way: a long section scrolls on its own so a
/// long request never buries a short result, and a long list of lines shows its
/// head and its tail with the count of what is between them, rather than its
/// first N lines and silence.
enum TranscriptCardMetrics {
    /// How tall one section of the IN/OUT card grows before it scrolls.
    static let sectionCap: CGFloat = 150
    /// A command's output before it scrolls.
    static let terminalCap: CGFloat = 224
    /// Lines of a diff before the middle collapses.
    static let diffLines = 12
    /// Lines of a read window before the middle collapses.
    static let readLines = 12
    /// The gutter the IN/OUT labels sit in.
    static let gutter: CGFloat = 30

    /// The head/tail split for a capped list: how many rows are hidden,
    /// whether it caps at all, and how the visible rows divide.
    /// A list one line over its cap is drawn whole: the line saying "1 more"
    /// would take the room of the line it hides, and hide it for nothing.
    static func headTail(total: Int, maxLines: Int, expanded: Bool) -> (hidden: Int, capped: Bool, head: Int, tail: Int) {
        let hidden = total - maxLines
        let head = Int((Double(maxLines) / 2).rounded(.up))
        return (hidden, collapses(hidden: hidden) && !expanded, head, maxLines - head)
    }
    /// Whether a list hides enough to be worth collapsing at all.
    static func collapses(hidden: Int) -> Bool { hidden > 1 }
    /// "… 12 more lines", in the singular for one.
    static func moreLines(_ hidden: Int) -> String { "… \(hidden) more line\(hidden == 1 ? "" : "s")" }
}

extension String {
    /// Nothing rather than an empty line, for the card notes that are only
    /// drawn when there is something to say.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The frame every card shares: a rounded panel with one hairline.
private struct CardFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
            .padding(.leading, TranscriptRowChrome.indent).padding(.top, 2).padding(.bottom, 8)
    }
}

/// The middle of a capped list: how many lines it is not showing, and the way
/// to see them.
private struct CardMoreLines: View {
    let hidden: Int
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Text(expanded ? "Show fewer lines" : TranscriptCardMetrics.moreLines(hidden))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(TranscriptPalette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).piPointer()
        .accessibilityLabel(expanded ? "Show fewer lines" : "Show \(hidden) more lines")
    }
}

/// The request and the result of one call, each in its own capped, scrolling
/// section under a gutter label that stays put while its payload scrolls.
struct TranscriptIOCard: View {
    var input: String? = nil
    var output: String? = nil
    var failed = false
    /// What the card says when what it holds is short of the whole request.
    var note: String? = nil
    var body: some View {
        CardFrame {
            VStack(alignment: .leading, spacing: 0) {
                if let input, !input.isEmpty { section(label: "IN", text: input, error: false) }
                if let input, !input.isEmpty, let output, !output.isEmpty {
                    Rectangle().fill(TranscriptPalette.hair).frame(height: 1)
                }
                if let output, !output.isEmpty { section(label: "OUT", text: output, error: failed) }
                if let note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                        .accessibilityIdentifier("tool-card-note")
                }
            }
        }
    }
    /// The label is outside the scroll, so it stays readable while its payload
    /// moves under it; the payload alone is what the cap bounds.
    private func section(label: String, text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TranscriptPalette.faint)
                .frame(width: TranscriptCardMetrics.gutter, alignment: .leading)
                .accessibilityHidden(true)
            ScrollView(.vertical) {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(error ? TranscriptPalette.danger : TranscriptPalette.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: TranscriptCardMetrics.sectionCap)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label == "IN" ? "Tool input" : "Tool output")
    }
}

/// A requested file change: the rows of the diff, capped head and tail, with
/// the total the collapsed row already showed repeated at its foot.
struct TranscriptDiffCard: View {
    let request: TranscriptActivity.EditRequest
    var path: String? = nil
    var outcome: ActionOutcome = .done
    var added: Int? = nil
    var removed: Int? = nil
    @State private var expanded = false
    var body: some View {
        let rows = request.rows
        let cap = TranscriptCardMetrics.headTail(total: rows.count, maxLines: TranscriptCardMetrics.diffLines, expanded: expanded)
        CardFrame {
            VStack(alignment: .leading, spacing: 0) {
                banner
                Rectangle().fill(TranscriptPalette.hair).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    if request.tooLarge {
                        Text("Diff preview unavailable — \(request.lines) lines. Full content is available below.")
                            .font(.system(size: 12)).foregroundStyle(TranscriptPalette.muted)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .accessibilityIdentifier("diff-too-large")
                        DisclosureGroup("View full content") {
                            if request.mode == "edit" { sourceSection("Before", text: request.before) }
                            sourceSection(request.mode == "edit" ? "After" : "Content", text: request.after)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    if cap.capped {
                        rowsView(Array(rows.prefix(cap.head)))
                        CardMoreLines(hidden: cap.hidden, expanded: false) { expanded = true }
                        rowsView(Array(rows.suffix(cap.tail)))
                    } else {
                        if expanded {
                            ScrollView { rowsView(rows) }
                                .frame(maxHeight: TranscriptCardMetrics.terminalCap)
                        } else {
                            rowsView(rows)
                        }
                        if TranscriptCardMetrics.collapses(hidden: cap.hidden) { CardMoreLines(hidden: cap.hidden, expanded: true) { expanded = false } }
                    }
                    if request.hiddenRows > 0 {
                        Text(TranscriptCardMetrics.moreLines(request.hiddenRows)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(TranscriptPalette.faint).padding(.horizontal, 16).padding(.vertical, 2)
                    }
                    if !request.complete {
                        Text("The host bounded this call's arguments. This is the part that arrived, not the whole request.")
                            .font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }
                .textSelection(.enabled)
                .opacity([.failed, .cancelled, .unknown].contains(outcome) ? 0.72 : 1)
                if !request.tooLarge || added != nil || removed != nil { footer }
            }
        }
    }
    private func sourceSection(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(TranscriptPalette.faint)
            ScrollView {
                Text(text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TranscriptPalette.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: TranscriptCardMetrics.terminalCap)
        }
    }
    private var banner: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(outcome == .done ? TranscriptPalette.muted : [.running, .unknown].contains(outcome) ? TranscriptPalette.warning : TranscriptPalette.danger)
            Spacer(minLength: 0)
            if let path { Text(path).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.faint).lineLimit(1).truncationMode(.middle) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    /// What became of the request. A call stopped while it ran may have
    /// written already, so it is never "not applied": its outcome is unknown.
    private var label: String {
        (request.mode == "edit" ? "Requested edit" : "Requested content")
            + (outcome == .done ? "" : outcome == .running ? " · in progress" : outcome == .unknown ? " · outcome unknown"
               : request.mode == "edit" ? " · not applied" : " · not written")
            + (request.complete ? "" : " · arguments truncated")
    }
    /// The same `+N −M` the collapsed row carried, so the card closes on the
    /// figure it opened with.
    private var footer: some View {
        let plus = added ?? request.rows.filter { $0.kind == .added }.count
        let minus = removed ?? request.rows.filter { $0.kind == .removed }.count
        return HStack(spacing: 0) {
            Text("└ ").font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.faint)
            Text("+\(plus)").font(.system(size: 12)).monospacedDigit().foregroundStyle(TranscriptPalette.success)
            Text(" −\(minus)").font(.system(size: 12)).monospacedDigit().foregroundStyle(TranscriptPalette.danger)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .accessibilityLabel("\(plus) lines added, \(minus) removed")
    }
    private func rowsView(_ rows: [DiffRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                        .foregroundStyle(row.kind == .added ? TranscriptPalette.diffAddedMark : row.kind == .removed ? TranscriptPalette.danger : TranscriptPalette.faint)
                        .frame(width: 10, alignment: .leading)
                    Text(row.text.isEmpty ? " " : row.text).foregroundStyle(TranscriptPalette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 16)
                .background(row.kind == .added ? TranscriptPalette.diffAdded : row.kind == .removed ? TranscriptPalette.danger.opacity(0.1) : Color.clear)
            }
        }
    }
}

/// A file read: the window that came back, numbered as the file numbers it,
/// and how much of the result the card is showing.
struct TranscriptReadCard: View {
    /// The file's line number of the window's first line: the read's offset.
    let firstLine: Int
    let path: String?
    let failed: Bool
    @State private var expanded = false
    /// The window's lines, and the host's note when the read stopped short of
    /// the file. Worked out once per result rather than on every redraw.
    private let lines: [String]
    private let note: String?

    init(text: String, firstLine: Int = 1, path: String? = nil, failed: Bool = false) {
        self.firstLine = max(1, firstLine); self.path = path; self.failed = failed
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        // The host ends a bounded read with "[Truncated. N total lines; read
        // another range.]". That is a note about the file, not its next line.
        if let last = lines.last, last.hasPrefix("[Truncated."), last.hasSuffix("]") {
            note = String(last.dropFirst().dropLast()); lines.removeLast()
        } else { note = nil }
        self.lines = lines
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
    var body: some View {
        let lines = self.lines
        let cap = TranscriptCardMetrics.headTail(total: lines.count, maxLines: TranscriptCardMetrics.readLines, expanded: expanded)
        let shown = cap.capped ? cap.head + cap.tail : lines.count
        CardFrame {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let path { Text(path).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted).lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 0)
                    Text(Self.window(shown: shown, total: lines.count))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(TranscriptPalette.faint)
                        .accessibilityIdentifier("read-card-window")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Rectangle().fill(TranscriptPalette.hair).frame(height: 1)
                if cap.capped {
                    numbered(Array(lines.prefix(cap.head)), from: firstLine)
                    CardMoreLines(hidden: cap.hidden, expanded: false) { expanded = true }
                    numbered(Array(lines.suffix(cap.tail)), from: firstLine + lines.count - cap.tail)
                } else {
                    numbered(lines, from: firstLine)
                    if TranscriptCardMetrics.collapses(hidden: cap.hidden) { CardMoreLines(hidden: cap.hidden, expanded: true) { expanded = false } }
                }
                if let note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(TranscriptPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityIdentifier("read-card-note")
                }
            }
            .textSelection(.enabled)
            .opacity(failed ? 0.72 : 1)
        }
    }
    /// "Showing 12 of 340 lines", and nothing at all when it is showing all
    /// of them: a card that is complete should not say so on every read.
    nonisolated static func window(shown: Int, total: Int) -> String {
        shown >= total ? "\(total) line\(total == 1 ? "" : "s")" : "Showing \(shown) of \(total) lines"
    }
    private func numbered(_ lines: [String], from start: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(start + offset)").font(.system(size: 11.5, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(TranscriptPalette.faint).frame(width: 34, alignment: .trailing)
                    Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TranscriptPalette.text).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// A command and what it printed.
struct TranscriptTerminalCard: View {
    let command: String
    var output: String = ""
    var failed = false
    var body: some View {
        CardFrame {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Text("$").font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.faint)
                    Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(TranscriptPalette.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if !output.isEmpty {
                    Rectangle().fill(TranscriptPalette.hair).frame(height: 1)
                    ScrollView(.vertical) {
                        Text(output).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(failed ? TranscriptPalette.danger : TranscriptPalette.muted)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: TranscriptCardMetrics.terminalCap)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .accessibilityLabel("Command output")
                }
            }
        }
    }
}
