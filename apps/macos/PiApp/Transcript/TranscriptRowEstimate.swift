import CoreGraphics
import Foundation

/// What a row is likely to be worth in points before anything has measured it.
///
/// Opening a long chat used to mean laying every one of its rows out through
/// SwiftUI before the reader saw a single word. The page now measures only the
/// rows it is about to draw and stands the rest at these estimates, so the
/// document has a height, the scroller has a thumb and the reader can scroll.
/// An estimate is never drawn: a row standing at one is not in the view tree,
/// and the page measures it for real before it can reach the viewport.
///
/// The arithmetic deliberately mirrors the rows' own typography rather than
/// their view code. It is a guess about a scroll bar, not a layout.
enum TranscriptRowEstimate {
    /// Points of line box for one point of font size.
    private static let lineFactor: CGFloat = 1.5
    /// Roughly how wide one character of the transcript's face is, as a
    /// fraction of the font size. Measured against SF Text at 13-14.5 pt.
    private static let characterFactor: CGFloat = 0.52

    /// How tall a run of prose wraps to at this width.
    static func prose(_ text: String, width: CGFloat, size: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let columns = max(20.0, Double(width / (size * characterFactor)))
        var lines = 0.0
        var run = 0
        var blanks = 0
        for character in text.unicodeScalars {
            if character == "\n" {
                lines += max(1, (Double(run) / columns).rounded(.up))
                if run == 0 { blanks += 1 }
                run = 0
            } else {
                run += 1
            }
        }
        if run > 0 { lines += max(1, (Double(run) / columns).rounded(.up)) }
        // Blank lines separate Markdown blocks; each pair costs a block gap
        // rather than a line box.
        return CGFloat(lines) * size * lineFactor + CGFloat(blanks) * 4
    }

    /// One tool call's collapsed card: the line every piece of work shares.
    static let toolRow: CGFloat = TranscriptRowChrome.height
    /// A work header, a reasoning header, a turn line, a figures line.
    static let line: CGFloat = 22

    static func height(of item: TranscriptItem, width: CGFloat) -> CGFloat {
        switch item {
        case .message(let message): return height(of: message, width: width, inline: true)
        case .block(let block):
            if block.presentation == .work { return 30 }
            // A turn's fold control is one line and a rule, whatever it hides.
            if block.presentation == .turnFold { return 33 }
            // A card at the position its call was made: one closed row.
            if block.part != nil, block.message?.tools?.isEmpty == false { return toolRow + 4 }
            // A response's header line is one line, whatever the response
            // holds. What the reader folded is not an estimate's business:
            // a row standing at one is measured before it can be drawn.
            if block.presentation == .response { return line + 6 }
            // A turn's terminal slot: its outcome on one line, then the two
            // pills, which wrap between themselves in a narrow pane, then any
            // notice. A pill is its text plus a 16 pt glyph and its padding;
            // the info and copy buttons take another 44 pt of the row.
            if block.presentation == .summary, let turn = block.turn {
                let stats = TurnPillsPresentation(turn)
                let pills = [stats.usageLabel, stats.timeLabel].compactMap { $0 }
                    .reduce(CGFloat(44)) { $0 + CGFloat($1.count) * 11.5 * characterFactor + 34 }
                let rows = max(1, (pills / max(40, width)).rounded(.up))
                return 6 + line + 4 + rows * 22 + (rows - 1) * 3 + 10
                    + (turn.notice.map { prose($0, width: width, size: 12) } ?? 0)
            }
            var total: CGFloat = 10
            let reasoned = block.replies.contains { !($0.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !block.tools.isEmpty || reasoned {
                total += line
                total += CGFloat(block.tools.count) * toolRow
                total += CGFloat(block.replies.filter { !($0.thinking ?? "").isEmpty }.count) * line
            }
            if let message = block.message { total += height(of: message, width: width, inline: false) }
            if block.turn != nil { total += line }
            return max(24, total)
        }
    }

    private static func height(of message: TranscriptMessage, width: CGFloat, inline: Bool) -> CGFloat {
        switch message.kind {
        case "compaction", "failure": return 64
        case "branch", "notice": return 40
        default: break
        }
        if message.role == "system" { return 40 }
        if message.role == "user" {
            let body = min(width, TranscriptMetrics.proseWidth) - 28
            return prose(message.text, width: max(40, body), size: MarkdownStyle.user.baseSize) + 18 + 14 + 4 + 22
        }
        let body = min(width, TranscriptMetrics.proseWidth)
        var total = prose(message.text, width: max(40, body), size: MarkdownStyle.prose.baseSize)
        if message.truncated == true { total += line }
        if message.stopReason == "length" { total += line }
        total += 22 + 4 + 10
        return max(24, total)
    }
}
