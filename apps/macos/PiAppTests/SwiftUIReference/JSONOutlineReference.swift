// Frozen from 59ef8e0d for AppKit visual comparison only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import PiApp
struct JSONOutlineReference: NSViewRepresentable {
    let json: CapturedJSON
    @Binding var selection: String
    let expandRevision: Int
    let expandAll: Bool
    var command: JSONOutlineCommand? = nil
    /// What the outline shows: an attempt's body in one format. A new
    /// document under the same key is a newer read of what is on screen, and
    /// the reader's open sections, selection and scroll position carry over.
    var stateKey = ""
    func makeCoordinator() -> Coordinator { let selected = $selection; return Coordinator(selection: selection, onSelection: { selected.wrappedValue = $0 }) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let outline = NSOutlineView(); outline.headerView = nil; outline.backgroundColor = .clear
        outline.rowHeight = 24; outline.intercellSpacing = NSSize(width: 10, height: 2); outline.indentationPerLevel = 14
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")); key.width = 240; key.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")); value.width = 420; value.minWidth = 120
        outline.addTableColumn(key); outline.addTableColumn(value); outline.outlineTableColumn = key
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Expandable captured JSON")
        scroll.documentView = outline
        context.coordinator.observeViewport(scroll.contentView, outline: outline)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let coordinator = context.coordinator
        coordinator.selection = selection
        let selected = $selection; coordinator.onSelection = { selected.wrappedValue = $0 }
        // One controller document is immutable. Rebuild only after a new body,
        // not after selecting a row or changing the expanded state.
        if coordinator.documentID != json.id {
            let carried = !stateKey.isEmpty && coordinator.stateKey == stateKey ? coordinator.capture(outline) : nil
            coordinator.cancelPendingSelection()
            coordinator.documentID = json.id; coordinator.stateKey = stateKey
            coordinator.root = JSONOutlineNode(key: json.rootLabel, value: json.value, formattedDetail: json.eagerFormatted)
            coordinator.revision = expandRevision
            coordinator.commandID = command?.id
            outline.reloadData(); outline.expandItem(coordinator.root)
            if let carried { coordinator.restore(carried, in: outline) }
        }
        if coordinator.revision != expandRevision {
            coordinator.revision = expandRevision
            coordinator.expandEverything = expandAll
            if expandAll { coordinator.expandAll(in: outline) }
            else { coordinator.collapseAll(in: outline) }
        }
        if let command, coordinator.commandID != command.id {
            coordinator.commandID = command.id
            switch command.action {
            case .collapseSection: coordinator.collapseSection(in: outline)
            case .top: coordinator.scrollToTop(in: outline)
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        outline.delegate = nil; outline.dataSource = nil
    }
    typealias Coordinator = JSONOutlineView.Coordinator
}
