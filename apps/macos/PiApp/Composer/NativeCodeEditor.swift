import AppKit

/// An editor for literal source text: configuration JSON, a handoff draft.
/// macOS's smart quotes and dashes would corrupt it, so they are off.
@MainActor final class NativeCodeEditorView: NSScrollView, NSTextViewDelegate {
    let editor = NSTextView()
    /// The reader changed the text: the new text.
    var onChange: ((String) -> Void)?
    /// The text as the model has it; setting it never calls `onChange`, and
    /// leaves text being composed (marked) alone.
    var text: String {
        get { editor.string }
        set { if !editor.hasMarkedText(), editor.string != newValue { editor.string = newValue } }
    }

    init(text: String = "", accessibilityLabel: String = "Literal model configuration JSON", onChange: ((String) -> Void)? = nil) {
        self.onChange = onChange
        super.init(frame: .zero)
        hasVerticalScroller = true; borderType = .noBorder; drawsBackground = false; autohidesScrollers = true
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.string = text; documentView = editor
        editor.setAccessibilityLabel(accessibilityLabel)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func textDidChange(_ notification: Notification) { onChange?(editor.string) }
}
