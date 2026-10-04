import AppKit

// The rows of the conversation, drawn natively: user bubbles, replies with
// their work line, tool cards with diffs, turn lines, and the status rows the
// host and app add. Every figure comes from TranscriptActivity; nothing here
// computes usage or timing itself.

enum TranscriptMetrics {
    static let proseWidth: CGFloat = 640
    static let pageWidth: CGFloat = 840
    /// The room above a page's first row and below its last.
    static let pageTopInset: CGFloat = 12
    static let pageBottomInset: CGFloat = 13
    /// How much narrower than its pane a page's rows are, both sides together.
    static let pageGutter: CGFloat = 48
}
private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

/// One of a row's actions as assistive technology offers it: a name and
/// what it does.
struct TranscriptRowAction: Identifiable {
    let name: String
    let perform: () -> Void
    var id: String { name }
    /// The row's actions, for readers who never hover: VoiceOver reaches Edit,
    /// Copy, a reply's View raw, Details and Fork from here through the row
    /// itself rather than through pills that only a pointer can reveal. A
    /// message still being sent can only be copied.
    static func all(_ message: TranscriptMessage, _ actions: TranscriptActions, forks: Bool = false,
                    source: ReplySourceToggle? = nil) -> [TranscriptRowAction] {
        let id = message.id
        let copy = TranscriptRowAction(name: "Copy") { actions.copyMessage(id) }
        if message.isSending { return [copy] }
        var all: [TranscriptRowAction] = []
        let editable = TranscriptMessageRows.editable(message)
        if editable { all.append(TranscriptRowAction(name: "Edit") { actions.edit(id) }) }
        all.append(copy)
        if let source { all.append(TranscriptRowAction(name: ReplySource.title(raw: source.raw), perform: source.toggle)) }
        all.append(TranscriptRowAction(name: "Details") { actions.inspect(id) })
        if !editable, ReplyMenu.forks(message, enabled: forks), let fork = actions.fork {
            all.append(TranscriptRowAction(name: "Fork from here") { fork(id) })
        }
        return all
    }
}

// MARK: - Work: action rows, diffs, reasoning

nonisolated func actionSymbol(_ kind: ActionKind) -> String {
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

/// Bounded full-code sections use UTF-8 source offsets, never truncated stored
/// code. Page switches are deliberate; streaming retains its existing leaf.
enum CodeBlockSections {
    static func ranges(_ source: String, enabled: Bool = true) -> [Range<Int>] {
        // A fence still arriving is one continuous leaf, asked about on every
        // token: it has nothing to split, so nothing of it is copied.
        guard enabled, source.utf8.count > 32_768 else { return [] }
        let bytes = Array(source.utf8)
        var ranges: [Range<Int>] = [], start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + 8192)
            if end < bytes.count {
                if let newline = bytes[start..<end].lastIndex(of: 10), newline > start { end = newline + 1 }
                else { while end > start && bytes[end] & 0xC0 == 0x80 { end -= 1 } }
            }
            ranges.append(start..<end); start = end
        }
        return ranges
    }
    /// One section's code, taken from the source's own bytes rather than a
    /// copy of all of them.
    static func section(_ source: String, _ range: Range<Int>) -> String {
        let utf8 = source.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound), upper = utf8.index(lower, offsetBy: range.count)
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }
}
