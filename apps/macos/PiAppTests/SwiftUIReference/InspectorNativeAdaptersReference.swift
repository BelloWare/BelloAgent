import AppKit
import SwiftUI
@testable import PiApp

struct InspectorItemsOutlineReference: NSViewRepresentable {
    let content: InspectorOutlineContent
    let wholeText: (InspectorOutlineTarget) -> InspectorWholeText?
    func makeNSView(context: Context) -> InspectorItemsOutline { InspectorItemsOutline(content: content, wholeText: wholeText) }
    func updateNSView(_ view: InspectorItemsOutline, context: Context) { view.update(content: content, wholeText: wholeText) }
    static func dismantleNSView(_ view: InspectorItemsOutline, coordinator: ()) { view.close() }
}
struct InspectorTextBlockReference: NSViewRepresentable {
    @ObservedObject var expansion: InspectorExpansion
    func makeNSView(context: Context) -> InspectorTextBlockView { InspectorTextBlockView() }
    func updateNSView(_ view: InspectorTextBlockView, context: Context) { view.show(expansion) }
    static func dismantleNSView(_ view: InspectorTextBlockView, coordinator: ()) { view.show(nil) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorTextBlockView, context: Context) -> CGSize? {
        let width = proposal.width ?? expansion.layout?.width ?? 0
        return CGSize(width: width.isFinite ? width : expansion.layout?.width ?? 0, height: expansion.layout?.height ?? 0)
    }
}

/// Frozen fragments of the 59ef8e0d request header and raw search field.
/// Isolating them makes their baselines and small clear symbol measurable
/// without a large page diluting a visible shift in the pixel comparison.
struct InspectorRequestMetricsReference: View {
    let figures: [InspectorFigure]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            InspectorFigureStripReference(figures: figures)
                .frame(maxWidth: .infinity, alignment: .leading)
            disclosure("More")
            disclosure("Model evidence")
        }
    }
    private func disclosure(_ title: String) -> some View {
        Button {} label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold))
            }
        }
        .buttonStyle(.piGhost).fixedSize()
    }
}

struct InspectorSearchFieldReference: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
            TextField("Find in body and headers", text: .constant(text)).textFieldStyle(.plain).font(PiFont.caption)
                .accessibilityIdentifier("inspector-raw-search")
            if !text.isEmpty {
                Button {} label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.piInkTertiary) }
                    .buttonStyle(.plain).piPointer().accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
    }
}
