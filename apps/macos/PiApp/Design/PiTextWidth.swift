import AppKit

/// How wide a piece of text or a symbol draws, measured once and remembered.
///
/// Two rows in this app used to answer "which form fits?" by laying every
/// candidate out. The sidebar's metrics line tried four variants per row on
/// every layout pass — about 170 microseconds a row, four milliseconds of a
/// frame in a workspace where every chat has billed requests — and the
/// composer bar nested two `ViewThatFits`, three run-control variants inside
/// three pill variants, which is nine trial layouts of the most expensive row
/// in the window for one answer.
///
/// Both now measure their strings and add them up. The strings are few, short
/// and repeat across rows and panes — a cost, a token count, "3m ago", a
/// connection name, a model alias, one of nine effort labels — so one table
/// serves both.
@MainActor enum PiTextWidth {
    /// A string, the font it is drawn in, and whether it is a symbol name
    /// rather than text.
    private struct Key: Hashable {
        let text: String
        let size: CGFloat
        let weight: CGFloat
        let kind: Kind
    }
    private enum Kind: Hashable { case text, monospacedDigits, symbol }

    /// A bound against a pathological title or alias, not a working limit.
    static let limit = 4_096
    private static var widths: [Key: CGFloat] = [:]
    /// Measurements are only valid for the system font they were taken with;
    /// a change to it empties the table.
    private static var measuredAt = NSFont.systemFontSize

    /// The width `Text(_).font(.system(size:weight:))` takes.
    static func text(_ value: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        return remembered(Key(text: value, size: size, weight: weight.rawValue, kind: .text)) {
            (value as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
        }
    }

    /// The width a figure takes in the monospaced-digit caption font, rounded
    /// up. Whole points here: the metrics line adds at most four pieces, and
    /// a row that truncates is worse than a row with a spare point.
    static func figure(_ value: String, medium: Bool = false) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        let weight: NSFont.Weight = medium ? .medium : .regular
        return remembered(Key(text: value, size: PiFont.captionSize, weight: weight.rawValue, kind: .monospacedDigits)) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: PiFont.captionSize, weight: weight)
            return (value as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
    }

    /// The width `Image(systemName:).font(.system(size:weight:))` takes.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        remembered(Key(text: name, size: size, weight: weight.rawValue, kind: .symbol)) {
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight.symbolWeight)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return size }
            return image.size.width
        }
    }

    private static func remembered(_ key: Key, _ measure: () -> CGFloat) -> CGFloat {
        if measuredAt != NSFont.systemFontSize { widths.removeAll(keepingCapacity: true); measuredAt = NSFont.systemFontSize }
        if let known = widths[key] { return known }
        // The composer bar's pieces are not rounded: three pills of three
        // pieces each would accumulate nine points of pessimism, enough to
        // give up a label the bar had room for. Its safety margin covers the
        // difference in one place instead.
        let measured = measure()
        if widths.count >= limit { widths.removeAll(keepingCapacity: true) }
        widths[key] = measured
        return measured
    }

    // MARK: Test seams

    /// How many distinct strings and symbols have been measured. The tests
    /// that pin "measured once, not once per row" count with it.
    static var measuredCount: Int { widths.count }
    /// Empties the table, so a test can count from zero.
    static func forget() { widths.removeAll(keepingCapacity: true) }
}

extension NSFont.Weight {
    /// The symbol weight that matches a font weight, for measuring an SF Symbol
    /// at the same weight as the text beside it.
    var symbolWeight: NSFont.Weight { self }
}
