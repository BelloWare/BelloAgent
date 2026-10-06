import SwiftUI
@testable import PiApp

// The SwiftUI layout of the full-table window before it was AppKit, kept
// as it was (no longer private) for the parity tests to draw against.

/// The window's layout: its bar, the grid on a Pi surface, and the chosen
/// cell's whole text under it.
struct MarkdownTableWindowView: View {
    let rows: Int
    let grid: NSView, detail: NSView
    let copy: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                PiWindowBarReference()
                HStack(spacing: PiSpacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Table").font(PiFont.title(14)).foregroundStyle(Color.piInk)
                        Text("\(rows.formatted()) rows").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    }.allowsHitTesting(false)
                    Spacer(minLength: 8)
                    Button("Copy full table as TSV", action: copy).buttonStyle(.piSecondaryCompact)
                        .accessibilityIdentifier("table-window-copy")
                }
                .padding(.leading, PiWindowBar.trafficLightInset).padding(.trailing, PiSpacing.md)
            }
            .frame(height: 48)
            MarkdownTableHostedView(view: grid)
                .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).strokeBorder(Color.piHairline))
                .padding(.horizontal, PiSpacing.md)
            MarkdownTableHostedView(view: detail)
                .frame(height: 120)
                .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).strokeBorder(Color.piHairline))
                .padding(PiSpacing.md)
        }
        .background(Color.piWindow)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The window's own AppKit views, kept as they are: nothing here makes,
/// reloads or focuses them again.
struct MarkdownTableHostedView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
