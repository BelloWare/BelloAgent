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

/// A small figure under the composer or at the end of a turn: a 16 pt glyph
/// and a line of text, quiet until the pointer is on it. Clicking opens the
/// dialog that explains the figure; a pill with nothing to explain is drawn as
/// plain text instead of a button that opens an empty panel.
struct PiStatPill<Dialog: View>: View {
    let symbol: String
    /// Drawn in the glyph slot instead of the symbol: the context ring reads
    /// as its own figure, and the pill keeps one shape either way.
    var ring: Double?? = nil
    let label: String
    /// What a screen reader hears; the visible label when nil.
    var accessibility: String? = nil
    var identifier: String? = nil
    var help: String = ""
    /// Nil when the figure has no detail worth a dialog.
    var dialog: (() -> Dialog)?
    @Binding var open: Bool
    @State private var hovering = false

    init(symbol: String, ring: Double?? = nil, label: String, accessibility: String? = nil, identifier: String? = nil,
         help: String = "", open: Binding<Bool>, @ViewBuilder dialog: @escaping () -> Dialog) {
        self.symbol = symbol; self.ring = ring; self.label = label; self.accessibility = accessibility
        self.identifier = identifier; self.help = help; self._open = open; self.dialog = dialog
    }
    /// A reading with no dialog behind it.
    init(symbol: String, ring: Double?? = nil, label: String, accessibility: String? = nil, identifier: String? = nil, help: String = "") where Dialog == EmptyView {
        self.symbol = symbol; self.ring = ring; self.label = label; self.accessibility = accessibility
        self.identifier = identifier; self.help = help; self._open = .constant(false); self.dialog = nil
    }

    var body: some View {
        Group {
            if let dialog {
                Button { open.toggle() } label: { face }
                    .buttonStyle(.plain).piPointer()
                    .popover(isPresented: $open, arrowEdge: .top) { dialog() }
            } else {
                face
            }
        }
        .onHover { hovering = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(accessibility ?? label)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var face: some View {
        PiStatPillFace(symbol: symbol, ring: ring, label: label, highlighted: (hovering || open) && dialog != nil)
    }
}

/// What a stat pill looks like: the glyph or ring, the reading, and a soft
/// fill while the pointer is on it or its dialog is open. Shared by
/// `PiStatPill` and `PiStatPopoverPill`, so the pills under the composer read
/// as one row whichever kind of dialog each one opens.
struct PiStatPillFace: View {
    let symbol: String
    var ring: Double?? = nil
    let label: String
    var highlighted = false

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if let ring { ContextRing(fraction: ring, size: 14) }
                else { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary) }
            }.frame(width: 16, height: 16)
            Text(label).font(PiFont.caption).monospacedDigit().lineLimit(1).fixedSize()
                .contentTransition(.numericText()).piAnimation(PiMotion.base, value: label)
        }
        .foregroundStyle(Color.piInkSecondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(highlighted ? Color.piFill : Color.clear, in: Capsule())
        .piAnimation(PiMotion.quick, value: highlighted)
    }
}

/// The panel a stat pill opens: an icon and title, the headline figure on the
/// same line when there is one, a hairline, then the rows. Narrow on purpose —
/// it answers one question and gets out of the way.
struct PiStatDialog: View {
    let symbol: String
    let title: String
    var headline: String? = nil
    let rows: [PiStatRow]
    /// Sentences under the rows: what was measured, and what was not.
    var notes: [String] = []
    var identifier: String = "stat-dialog"
    var width: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
                Text(title).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
                Spacer(minLength: PiSpacing.sm)
                if let headline {
                    Text(headline).font(PiFont.caption.weight(.medium)).monospacedDigit().foregroundStyle(Color.piInk)
                        .lineLimit(1).fixedSize()
                }
            }
            Rectangle().fill(Color.piHairline).frame(height: 1)
            if rows.isEmpty {
                Text("Nothing reported yet.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
                            Text(row.name).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                            Spacer(minLength: PiSpacing.sm)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(row.value).font(PiFont.caption.weight(.medium)).monospacedDigit()
                                    .foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                                if let detail = row.detail {
                                    Text(detail).font(PiFont.micro).monospacedDigit().foregroundStyle(Color.piInkTertiary).lineLimit(1)
                                }
                                if let coverage = row.coverage {
                                    Text(coverage).font(PiFont.micro).foregroundStyle(Color.piWarning).lineLimit(1)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.line)
                    }
                }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PiSpacing.md)
        .frame(width: width, alignment: .leading)
        .accessibilityIdentifier(identifier)
        .accessibilityElement(children: .contain)
    }
}
