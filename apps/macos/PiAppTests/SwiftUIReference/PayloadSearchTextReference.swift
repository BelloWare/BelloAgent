// Frozen from 59ef8e0d for AppKit visual comparison only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import PiApp
struct PayloadSearchTextReference: NSViewRepresentable {
    let result: PayloadSearchResult
    let selected: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = NSTextView()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.setAccessibilityLabel("Search results in complete body and headers")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if coordinator.id != result.id {
            coordinator.id = result.id; coordinator.selected = nil
            if coordinator.textID != result.textID {
                coordinator.textID = result.textID
                editor.string = result.text
            } else {
                // Same text, refined query: only the highlights change, and
                // the reader keeps their place in the text.
                editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
            }
            for range in result.matches {
                editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), forCharacterRange: range)
            }
        }
        guard coordinator.selected != selected, result.matches.indices.contains(selected) else { return }
        coordinator.selected = selected
        let range = result.matches[selected]
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }
    @MainActor final class Coordinator { var id: UUID?; var textID: UUID?; var selected: Int? }
}
