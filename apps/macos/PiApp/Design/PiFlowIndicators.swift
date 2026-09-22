import SwiftUI

// What the reader sees while a turn is running, and how they get back to it:
// the shimmering line that says the app is working, and the floating circle
// that brings them back to the newest message. Both are pure paint — a
// gradient's offset and an opacity — so neither decides any layout and
// neither costs the conversation a thing per frame.

/// A line of text with a slow highlight travelling along it. It is the
/// working indicator: no spinner, no progress, just the words moving, which
/// is what says the run is alive without claiming to know how far it has got.
///
/// The travelling part is one offset on a gradient masked by the glyphs. The
/// words themselves never change, so a tick moves a mask and decides no
/// layout: the conversation above is not touched, and neither is the bar's
/// own height. Reduce Motion leaves the line still, and the words still say
/// what the run is doing.
struct PiShimmerText: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    /// How long the highlight takes to cross the line once.
    static let period: Double = 1.9
    /// How wide the highlight is, as a fraction of the line.
    static let band: CGFloat = 0.45
    @Environment(\.piReduceMotion) private var reduceMotion

    private var label: Text { Text(text).font(.system(size: size, weight: weight)) }

    var body: some View {
        label
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(TranscriptPalette.muted)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let width = max(24, proxy.size.width * Self.band)
                        // The same clock the rest of the design system's
                        // indicators run on, so the highlight advances in a
                        // detached row host and in a menu-bar popover too.
                        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Self.period) / Self.period
                            LinearGradient(colors: [.clear, TranscriptPalette.text.opacity(0.9), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: width)
                                .offset(x: -width + (proxy.size.width + width) * phase)
                        }
                    }
                    .mask(label.lineLimit(1).truncationMode(.tail))
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(text)
    }
}

/// The floating circle above the composer that takes the reader back to the
/// newest message. It is shown whenever they are not standing at the bottom,
/// whatever took them away from it — a wheel, a page key, a restored position,
/// a jump they abandoned.
struct PiBackToBottomPill: View {
    /// How big the circle is.
    static let diameter: CGFloat = 34
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            // A circle floating over the conversation has to read as an
            // object in both appearances. The surface alone is a shade away
            // from the canvas in the dark one, so the edge and the shadow are
            // what hold it off the page, and the arrow carries full weight.
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hovering ? TranscriptPalette.accent : TranscriptPalette.text)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(TranscriptPalette.surface, in: Circle())
                .overlay(Circle().stroke(hovering ? TranscriptPalette.muted.opacity(0.45) : TranscriptPalette.hairStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).piPointer()
        .onHover { hovering = $0 }
        .help("Jump to the latest message")
        .accessibilityLabel("Jump to the latest message")
        .accessibilityIdentifier("backToBottom")
    }
}
