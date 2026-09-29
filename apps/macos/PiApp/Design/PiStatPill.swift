import SwiftUI

/// One row of a stat dialog: a name, its figure, and — when the gateway did
/// not report every request — the coverage that makes the figure honest.
struct PiStatRow: Identifiable, Equatable, Sendable {
    var name: String
    var value: String
    /// A quieter figure under the value, such as "12,400 reasoning".
    var detail: String? = nil
    /// "3/5 requests reported"; shown in warning ink so partial coverage reads
    /// as partial rather than as a total.
    var coverage: String? = nil
    var id: String { name }

    /// One line of the same row, for a copy action or an accessibility value.
    var line: String {
        ([name + ": " + value, detail, coverage].compactMap { $0 }).joined(separator: " · ")
    }
}

/// What a stat pill looks like: the glyph or ring, the reading, and a soft
/// fill while the pointer is on it or its dialog is open. Shared by the
/// composer's pills (`PiStatButton`) and `PiStatPopoverPill`, so the pills
/// under the composer read as one row whatever each one opens.
struct PiStatPillFace: View {
    let symbol: String
    var ring: Double?? = nil
    let label: String
    var highlighted = false
    /// A last figure that needs attention, such as a chat's spend near its
    /// cost limit, in warning ink after the rest of the reading.
    var warningTail: String? = nil
    /// Words that end in "…" where they are given less room than they need
    /// (a `PiFlowFillsRow` item at the end of a full row). A figure is never
    /// cut: false, the reading always takes its whole width.
    var truncates = false

    private var reading: Text {
        guard let warningTail else { return Text(label) }
        let tail = Text(warningTail).foregroundColor(.piWarning)
        return label.isEmpty ? tail : Text(label) + Text(" · ") + tail
    }
    var body: some View {
        HStack(spacing: 5) {
            Group {
                if let ring { ContextRing(fraction: ring, size: 14) }
                else { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary) }
            }.frame(width: 16, height: 16)
            reading.font(PiFont.caption).monospacedDigit().lineLimit(1).truncationMode(.tail).fixedSize(horizontal: !truncates, vertical: true)
                .contentTransition(.numericText()).piAnimation(PiMotion.base, value: label + (warningTail ?? ""))
        }
        .foregroundStyle(Color.piInkSecondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(highlighted ? Color.piFill : Color.clear, in: Capsule())
        .piAnimation(PiMotion.quick, value: highlighted)
    }
}
