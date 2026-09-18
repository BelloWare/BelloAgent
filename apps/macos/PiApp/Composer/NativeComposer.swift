import SwiftUI
import AppKit

struct NativeComposer: NSViewRepresentable {
    @Binding var text: String
    var send: () -> Void
    /// The chat this composer belongs to, so typing anywhere in the window can find the right one.
    var sessionID = ""
    var completion: (String) -> Void = { _ in }
    var directSlash: () -> Void = {}
    var pasted: () -> Void = {}
    var completionKey: (UInt16) -> Bool = { _ in false }
    var focused: () -> Void = {}
    var accessibilityLabel = "Message composer"
    var inputRejected: (String) -> Void = { _ in }
    /// Image files dropped on or pasted into the composer.
    var attachFiles: ([URL]) -> Void = { _ in }
    var heightChanged: (CGFloat) -> Void = { _ in }
    /// A changed token moves keyboard focus into the editor once the view is in a window.
    var focusToken = 0
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 10, height: 9)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel); editor.setAccessibilityIdentifier("nativeComposer"); editor.sessionID = sessionID
        editor.send = { context.coordinator.parent.send() }
        editor.directSlash = { context.coordinator.parent.directSlash() }
        editor.pasted = { context.coordinator.parent.pasted() }
        editor.attachFiles = { context.coordinator.parent.attachFiles($0) }
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.completionKey = { context.coordinator.parent.completionKey($0) }
        editor.focused = { [weak editor, weak coordinator = context.coordinator] in
            if let editor { coordinator?.focusChanged(editor) }
        }
        editor.contentHeightChanged = { height in Task { @MainActor in context.coordinator.parent.heightChanged(height) } }
        editor.string = text; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.appliedFocusToken != focusToken, let editor = scroll.documentView as? ComposerTextView {
            context.coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window, window.attachedSheet == nil, !editor.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(editor)
            }
        }
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.sessionID = sessionID
        context.coordinator.applyModelText(text,to:editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var appliedFocusToken = 0
        private var applyingModelText = false
        private var rejectedModelText: String?
        private var focusRevision = 0
        init(_ parent: NativeComposer) { self.parent = parent }
        func applyModelText(_ text: String, to editor: ComposerTextView) {
            guard !editor.hasMarkedText(), editor.string != text, rejectedModelText != text else { return }
            rejectedModelText = nil
            // insertText preserves native undo, but synchronously invokes the
            // delegate. A model-to-view refresh must not publish that same text
            // or completion state back into SwiftUI during updateNSView.
            applyingModelText = true; defer { applyingModelText = false }
            editor.insertText(text,replacementRange:NSRange(location:0,length:(editor.string as NSString).length))
            if editor.string != text { rejectedModelText = text }
        }
        func focusChanged(_ editor: ComposerTextView) {
            focusRevision += 1; let revision = focusRevision
            // Report navigation and native view attachment can restore first
            // responder inside a SwiftUI update. Publish after that transaction
            // and reject callbacks superseded by another responder or sheet.
            Task { @MainActor [weak self, weak editor] in
                guard let self, let editor, self.focusRevision == revision,
                      let window = editor.window, window.firstResponder === editor,
                      window.attachedSheet == nil, !editor.isHiddenOrHasHiddenAncestor else { return }
                self.parent.focused()
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            guard replacementString.utf8.count <= 262_144, NSMaxRange(affectedCharRange) <= (textView.string as NSString).length,
                  textView.string.utf8.count - (textView.string as NSString).substring(with: affectedCharRange).utf8.count + replacementString.utf8.count <= 262_144 else {
                let message = "The composer accepts at most 256 KiB of text. Attach or reference larger files instead."
                if applyingModelText { Task { @MainActor [weak self] in self?.parent.inputRejected(message) } }
                else { parent.inputRejected(message) }
                return false
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard !applyingModelText, let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            if !editor.hasMarkedText() { parent.completion(editor.string) }
        }
    }
}
struct ComposerEditMeasurement {
    private var candidate: (event: Double, handler: Double)?
    private var pending: (event: Double, handler: Double)?
    mutating func begin(event: Double, handler: Double) { candidate = (event, handler) }
    mutating func edited() { if pending == nil { pending = candidate } }
    mutating func end() { candidate = nil }
    mutating func draw(at time: Double) -> (input: Double, handler: Double)? {
        guard let value = pending else { return nil }; pending = nil
        return (time - value.event, time - value.handler)
    }
}
@MainActor final class ComposerTextView: NSTextView {
    /// The chat this editor belongs to (see `WindowPresentationController.redirectTyping`).
    var sessionID = ""
    private var measurement = ComposerEditMeasurement()
    var send: (() -> Void)?
    var directSlash: (() -> Void)?
    var pasted: (() -> Void)?
    var completionKey: ((UInt16) -> Bool)?
    var focused: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0
    /// Reports the laid-out text height so the shell can grow the field with its content.
    private func reportContentHeight() {
        guard let container = textContainer, let layout = layoutManager else { return }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + textContainerInset.height * 2)
        if abs(height - reportedHeight) >= 1 { reportedHeight = height; contentHeightChanged?(height) }
    }
    override func layout() { super.layout(); reportContentHeight() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focused?() }; return accepted }
    var attachFiles: (([URL]) -> Void)?
    override func paste(_ sender: Any?) {
        if PerformanceProbe.shared.enabled { measurement.begin(event: PerformanceProbe.now, handler: PerformanceProbe.now) }
        defer { measurement.end() }
        // A screenshot on the clipboard or a copied image file becomes an
        // attachment instead of a pasted file path.
        if let attachFiles, let urls = Self.imageFiles(on: NSPasteboard.general) { attachFiles(urls); return }
        pasted?(); super.paste(sender)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.imageFiles(on: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let attachFiles, let urls = Self.imageFiles(on: sender.draggingPasteboard) { attachFiles(urls); return true }
        return super.performDragOperation(sender)
    }
    /// Image files on the pasteboard, or a pasted bitmap written to a private PNG.
    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL]? {
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { extensions.contains($0.pathExtension.lowercased()) }
            return images.isEmpty ? nil : images
        }
        guard pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]),
              let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BelloAgent-Pasted", isDirectory: true)
        let url = folder.appendingPathComponent("pasted-" + UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try png.write(to: url, options: .atomic)
        } catch { return nil }
        return [url]
    }
    override func didChangeText() { measurement.edited(); super.didChangeText(); reportContentHeight() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let previous = self.string, range = markedRange()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if self.string != previous || markedRange() != range { measurement.edited() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let value = measurement.draw(at: PerformanceProbe.now) {
            PerformanceProbe.shared.observe("nativeInputToDrawMs", milliseconds: value.input)
            PerformanceProbe.shared.observe("nativeHandlerToDrawMs", milliseconds: value.handler)
        }
    }
    override func keyDown(with event: NSEvent) {
        let sends = [36, 76].contains(event.keyCode) && !event.modifierFlags.contains(.shift) && !hasMarkedText()
        if PerformanceProbe.shared.enabled && !event.modifierFlags.contains(.command) && !sends {
            let now = PerformanceProbe.now
            PerformanceProbe.shared.observe("nativeEventDispatchDelayMs", milliseconds: now - event.timestamp * 1000)
            measurement.begin(event: event.timestamp * 1000, handler: now)
        }
        defer { measurement.end() }
        if !hasMarkedText(), event.characters == "/", selectedRange().location == 0 { directSlash?() }
        if !hasMarkedText(), !event.modifierFlags.contains(.shift), completionKey?(event.keyCode) == true { return }
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(),
           !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) {
            if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { send?() }; return
        }
        super.keyDown(with: event)
        // Draw the edited native text before processing the next background
        // stream notification. This flushes only this view's invalidated region;
        // it does not force a window/SwiftUI layout or run when the editor is hidden.
        if window?.isVisible == true { displayIfNeeded() }
    }
}
