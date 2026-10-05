import SwiftUI
@testable import PiApp

// TEMPORARY: `NativeCodeEditorView` inside SwiftUI, for the views that are
// still SwiftUI (Settings' JSON fields, the Resource Inspector). It goes
// when they are AppKit.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Literal model configuration JSON"
    func makeNSView(context: Context) -> NativeCodeEditorView {
        NativeCodeEditorView(text: text, accessibilityLabel: accessibilityLabel)
    }
    func updateNSView(_ editor: NativeCodeEditorView, context: Context) {
        let binding = $text
        editor.onChange = { binding.wrappedValue = $0 }
        editor.text = text
    }
}
