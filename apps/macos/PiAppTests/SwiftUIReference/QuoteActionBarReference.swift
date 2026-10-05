import SwiftUI
@testable import PiApp

// The SwiftUI face of the quote bar before it was AppKit, kept as it was
// (no longer private) for the parity tests to draw against.

/// The bar's face: the bubble glyph in the accent, the action in the app's
/// ink, and a quiet key hint. The press, the pointer, the tooltip and the
/// accessibility action belong to the app's AppKit press target over it.
struct QuoteActionBar: View {
    let ask: () -> Void
    @State private var hovering = false
    @State private var arrived = false
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.piAccent)
            Text("Ask in side chat").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.piInk)
            Text("↩").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.piFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovering ? Color.piFillStrong : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(3)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
        .shadow(color: Color.piShadow, radius: 10, y: 3)
        .overlay {
            PiPopoverTrigger(label: "Ask in side chat", identifier: "quoteInSideChat",
                             help: "Ask about the selected text in a side chat (Return)",
                             onHover: { hovering = $0 }, onPress: { _ in ask() })
        }
        .piAnimation(PiMotion.quick, value: hovering)
        .scaleEffect(arrived || reduceMotion ? 1 : 0.96)
        .opacity(arrived || reduceMotion ? 1 : 0)
        .onAppear { if reduceMotion { arrived = true } else { withAnimation(PiMotion.quick) { arrived = true } } }
    }
}
