import AppKit
import SwiftUI
@testable import PiApp

struct PayloadEditorReference: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Literal model configuration JSON"
    func makeNSView(context: Context) -> NativeCodeEditorView {
        let current = $text
        return NativeCodeEditorView(text: text, accessibilityLabel: accessibilityLabel) { current.wrappedValue = $0 }
    }
    func updateNSView(_ editor: NativeCodeEditorView, context: Context) {
        let current = $text; editor.text = text; editor.onChange = { current.wrappedValue = $0 }
    }
}
