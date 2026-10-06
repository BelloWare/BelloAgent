import AppKit

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
