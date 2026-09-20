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
        // An overlay scroller never narrows the text container, so a reply reaching the height
        // clamp cannot rewrap, change height, hide the scroller and rewrap again.
        scroll.scrollerStyle = .overlay
        let editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 10, height: 9)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityLabel); editor.setAccessibilityIdentifier("nativeComposer"); editor.sessionID = sessionID
        // Every one of these is held by the editor, and the coordinator holds
        // this view value, whose closures hold the chat's page and the whole
        // workspace. Capturing the coordinator strongly made an editor that
        // outlived its pane — AppKit keeps a text view alive past the SwiftUI
        // teardown — keep that chat's transcript page in memory for the rest
        // of the session, so memory grew with every chat visited.
        let coordinator = context.coordinator
        editor.send = { [weak coordinator] in coordinator?.parent.send() }
        editor.directSlash = { [weak coordinator] in coordinator?.parent.directSlash() }
        editor.pasted = { [weak coordinator] in coordinator?.parent.pasted() }
        editor.attachFiles = { [weak coordinator] in coordinator?.parent.attachFiles($0) }
        editor.attachmentDestination = { [weak coordinator] in
            guard let parent = coordinator?.parent else { return nil }
            // Snapshot the callbacks for this session before conversion yields.
            return ComposerTextView.AttachmentDestination(attach: parent.attachFiles, reject: parent.inputRejected)
        }
        editor.imageRejected = { [weak coordinator] in coordinator?.parent.inputRejected($0) }
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.completionKey = { [weak coordinator] in coordinator?.parent.completionKey($0) ?? false }
        editor.focused = { [weak editor, weak coordinator] in
            if let editor { coordinator?.focusChanged(editor) }
        }
        editor.contentHeightChanged = { [weak coordinator] height in Task { @MainActor in coordinator?.parent.heightChanged(height) } }
        editor.string = text; context.coordinator.adopt(text); scroll.documentView = editor
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
        /// The text the editor and the model last agreed on, in the app's own
        /// storage. `NSTextView.string` hands back a fresh UTF-16 bridge each
        /// time; comparing the draft against one of those decodes the whole
        /// document, so a 200 KB draft used to cost about 10 ms per keystroke.
        /// Comparing against this copy is a pointer check in the usual case.
        private var settled: String?
        init(_ parent: NativeComposer) { self.parent = parent }
        func adopt(_ text: String) { settled = text }
        /// The editor's text in the app's own UTF-8 storage, so every later
        /// comparison is a memcmp rather than a UTF-16 decode. AppKit's own
        /// UTF-8 buffer is an order of magnitude faster than transcoding the
        /// bridge character by character; it stops at an embedded NUL, so the
        /// length is checked and the slow path used when one is present.
        static func contents(of editor: NSTextView) -> String {
            let source = editor.string as NSString
            if let buffer = source.utf8String {
                let text = String(cString: buffer)
                if text.utf16.count == source.length { return text }
            }
            var text = editor.string
            text.makeContiguousUTF8()
            return text
        }
        func applyModelText(_ text: String, to editor: ComposerTextView) {
            guard !editor.hasMarkedText(), settled != text, rejectedModelText != text else { return }
            let current = Self.contents(of: editor)
            guard current != text else { settled = text; return }
            rejectedModelText = nil
            // insertText preserves native undo, but synchronously invokes the
            // delegate. A model-to-view refresh must not publish that same text
            // or completion state back into SwiftUI during updateNSView.
            applyingModelText = true; defer { applyingModelText = false }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
            let applied = Self.contents(of: editor)
            settled = applied
            if applied != text { rejectedModelText = text }
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
            guard replacementString.utf8.count <= 262_144, NSMaxRange(affectedCharRange) <= (textView.textStorage?.length ?? 0),
                  Self.fits(textView, replacing: affectedCharRange, with: replacementString) else {
                let message = "The composer accepts at most 256 KiB of text. Attach or reference larger files instead."
                if applyingModelText { Task { @MainActor [weak self] in self?.parent.inputRejected(message) } }
                else { parent.inputRejected(message) }
                return false
            }
            return true
        }
        /// The 256 KiB submission limit, without reading the whole document on
        /// every keystroke: a UTF-16 unit never exceeds three UTF-8 bytes, so a
        /// draft that cannot reach the limit is accepted from its length alone.
        static func fits(_ textView: NSTextView, replacing range: NSRange, with replacement: String) -> Bool {
            let units = (textView.textStorage?.length ?? 0) - range.length
            let added = replacement.utf8.count
            if units <= (262_144 - added) / 3 { return true }
            let text = textView.string
            return text.utf8.count - (text as NSString).substring(with: range).utf8.count + added <= 262_144
        }
        func textDidChange(_ notification: Notification) {
            guard !applyingModelText, let editor = notification.object as? NSTextView else { return }
            // The editor only notifies after a real edit, so the text is new by
            // construction: comparing it against the draft first would cost a
            // full decode of the document for nothing.
            let text = Self.contents(of: editor)
            settled = text
            parent.text = text
            if !editor.hasMarkedText() { parent.completion(text) }
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
    /// The keys that belong to the conversation rather than to the draft.
    static func conversationScroll(for keyCode: UInt16) -> TranscriptKeyScroll? {
        switch keyCode {
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .top
        case 119: return .bottom
        default: return nil
        }
    }
    /// True while the whole draft is on screen, so these keys have nothing to
    /// do here. A draft long enough to scroll keeps them.
    var draftFitsInTheField: Bool {
        guard let scroll = enclosingScrollView else { return true }
        return (scroll.documentView?.frame.height ?? 0) <= scroll.contentSize.height + 1
    }
    /// The conversation this composer sits under.
    func conversationScrollView() -> TranscriptNativeScrollView? {
        func find(_ view: NSView) -> TranscriptNativeScrollView? {
            if let scroll = view as? TranscriptNativeScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let root = window?.contentView else { return nil }
        return find(root)
    }
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
    /// The tallest the field ever becomes; past it the exact text height no
    /// longer changes the layout, so it is never measured.
    var maximumContentHeight: CGFloat = 240
    /// Reports the laid-out text height so the shell can grow the field with
    /// its content. A long draft is laid out only as far as the ceiling:
    /// `ensureLayout(for:)` would lay out every line of a 200 KB draft on every
    /// keystroke, which is the whole cost of typing into one.
    private func reportContentHeight() {
        guard let container = textContainer, let layout = layoutManager else { return }
        let inset = textContainerInset.height * 2
        let ceiling = max(0, maximumContentHeight - inset)
        layout.ensureLayout(forBoundingRect: CGRect(x: 0, y: 0, width: container.size.width, height: ceiling + 1), in: container)
        let height = ceil(min(layout.usedRect(for: container).height, ceiling) + inset)
        if abs(height - reportedHeight) >= 1 { reportedHeight = height; contentHeightChanged?(height) }
    }
    override func layout() { super.layout(); reportContentHeight() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focused?() }; return accepted }
    var attachFiles: (([URL]) -> Void)?
    struct AttachmentDestination {
        var attach: ([URL]) -> Void
        var reject: ((String) -> Void)?
    }
    var attachmentDestination: (() -> AttachmentDestination?)?
    /// Reported when a pasted or dropped image cannot be read; wired to the
    /// same notice the composer uses for text it refuses.
    var imageRejected: ((String) -> Void)?
    override func paste(_ sender: Any?) {
        if PerformanceProbe.shared.enabled { measurement.begin(event: PerformanceProbe.now, handler: PerformanceProbe.now) }
        defer { measurement.end() }
        // A screenshot on the clipboard or a copied image file becomes an
        // attachment instead of a pasted file path.
        if pasteAttachments(from: NSPasteboard.general) { return }
        pasted?(); super.paste(sender)
    }
    /// True when the pasteboard held images and they became attachments.
    /// Separated from `paste` so a test can paste from its own pasteboard
    /// rather than the clipboard the owner is using.
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard let attachFiles else { return false }
        if let urls = Self.imageFiles(on: pasteboard) { attachFiles(urls); return true }
        guard let pasted = Self.pastedImage(on: pasteboard) else { return false }
        let destination = attachmentDestination?() ?? AttachmentDestination(attach: attachFiles, reject: imageRejected)
        // Decoding a screenshot, re-encoding it and writing it out takes long
        // enough to freeze the window: a 4000x3000 paste is hundreds of
        // milliseconds. Only the bytes are taken here; the rest happens off
        // the main thread and the chip appears when it lands.
        Task { @MainActor in
            let written = await Task.detached(priority: .userInitiated) { Self.writePastedImage(pasted) }.value
            if let written { destination.attach([written]) }
            else { destination.reject?("That image could not be read. Copy it again, or attach the file instead.") }
        }
        return true
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        return Self.acceptsImageTypes(on: pasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if pasteAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
    /// Image bytes taken from the pasteboard without decoding them.
    struct PastedImage: Sendable { let data: Data; let isPNG: Bool }
    /// Drag admission must not fetch/decode a promised screenshot's bytes.
    static func acceptsImageTypes(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    static func pastedImage(on pasteboard: NSPasteboard) -> PastedImage? {
        if let png = pasteboard.data(forType: .png) { return PastedImage(data: png, isPNG: true) }
        if let tiff = pasteboard.data(forType: .tiff) { return PastedImage(data: tiff, isPNG: false) }
        return nil
    }
    /// Writes the pasted bytes to a private PNG. PNG goes through untouched;
    /// anything else is converted here, off the main thread.
    nonisolated static func writePastedImage(_ image: PastedImage) -> URL? {
        let bytes: Data
        if image.isPNG { bytes = image.data }
        else {
            guard let bitmap = NSBitmapImageRep(data: image.data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            bytes = png
        }
        guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BelloAgent-Pasted", isDirectory: true)
        let url = folder.appendingPathComponent("pasted-" + UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: .atomic)
        } catch { return nil }
        return url
    }
    /// Image files on the pasteboard, which need no conversion at all.
    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL]? {
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        let images = urls.filter { extensions.contains($0.pathExtension.lowercased()) }
        return images.isEmpty ? nil : images
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
        // Page Up and Page Down, Home and End move the reader through the
        // conversation, not through a draft that already fits in the field.
        // Focus stays here: a reader reads and keeps typing without a click.
        // `.function` and `.numericPad` are what the keyboard says about these
        // keys themselves, not something the reader held down.
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let move = Self.conversationScroll(for: event.keyCode), draftFitsInTheField,
           conversationScrollView()?.scroll(by: move) == true { return }
        super.keyDown(with: event)
        // Draw the edited native text before processing the next background
        // stream notification. This flushes only this view's invalidated region;
        // it does not force a window/SwiftUI layout or run when the editor is hidden.
        if window?.isVisible == true { displayIfNeeded() }
    }
}
