import SwiftUI
import AppKit

struct PagedTextView: NSViewRepresentable {
    let text: String
    var accessibilityLabel = "Read-only payload text"
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let editor = NSTextView(); editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(accessibilityLabel); scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        DispatchQueue.main.async { [weak editor] in editor?.scrollToBeginningOfDocument(nil) }
    }
}
