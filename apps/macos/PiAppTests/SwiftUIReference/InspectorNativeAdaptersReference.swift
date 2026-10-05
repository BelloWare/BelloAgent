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
