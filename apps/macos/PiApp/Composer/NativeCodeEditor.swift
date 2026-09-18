import SwiftUI
import AppKit

// Configuration is literal source text. macOS smart quotes/dashes would corrupt JSON.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Literal model configuration JSON"
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let editor = NSTextView(); editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator; editor.string = text; scroll.documentView = editor
        editor.setAccessibilityLabel(accessibilityLabel)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? NSTextView, !editor.hasMarkedText(), editor.string != text { editor.string = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
