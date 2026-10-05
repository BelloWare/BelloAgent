import SwiftUI
@testable import PiApp

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
    /// What the figures are of, such as one chat's metrics. A figure that
    /// changes rolls to its new value; figures of another scope replace the
    /// old ones at once. Rolling a whole pill from one chat's figures to
    /// another's, on every switch, drew it again on the CPU for some twenty
    /// frames, the main thread's largest drawing cost in a switch.
    var scope: AnyHashable? = nil

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
                .id(scope).transition(.identity)
        }
        .foregroundStyle(Color.piInkSecondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(highlighted ? Color.piFill : Color.clear, in: Capsule())
        .piAnimation(PiMotion.quick, value: highlighted)
    }
}

// The SwiftUI ring still used by the remaining Inspector and design references.
struct ContextRing: View {
    let fraction: Double?
    /// 23 pt in the inspector's header; 14 pt as a pill's glyph.
    var size: CGFloat = 23
    private var bounded: Double { min(1, max(0, fraction.map { $0.isFinite ? $0 : 0 } ?? 0)) }
    private var tint: Color { bounded >= 0.95 ? .piDanger : bounded >= 0.8 ? .piWarning : .piAccent }
    private var stroke: CGFloat { size < 18 ? 2 : 2.5 }
    var body: some View {
        ZStack {
            Circle().stroke(Color.piHairlineStrong, lineWidth: stroke)
            Circle().trim(from: 0, to: bounded).stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round)).rotationEffect(.degrees(-90))
                .piAnimation(PiMotion.base, value: bounded)
            // The glyph only fits at the inspector's size; the pill's ring is
            // the reading, and its percentage is right beside it.
            if size >= 18 { Image(systemName: "square.stack.3d.up").font(.system(size: 9, weight: .medium)).foregroundStyle(tint) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
