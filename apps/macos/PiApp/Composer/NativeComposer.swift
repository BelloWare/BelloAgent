import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The composer's native editor, as a value: what it shows and what it calls.
/// `makeView()` builds the field once; `apply(to:)` hands it a newer value,
/// as the chat's state changes. The field keeps its coordinator, which holds
/// the newest value; the editor's own callbacks reach it weakly.
@MainActor struct NativeComposer {
    /// The draft as the model has it.
    var text: String
    /// The reader changed the draft: the new text.
    var textChanged: (String) -> Void = { _ in }
    var send: (ComposerSubmissionIntent) -> Void
    /// The chat this composer belongs to, so typing anywhere in the window can find the right one.
    var sessionID = ""
    var completion: (String) -> Void = { _ in }
    var locationChanged: (ComposerLocation, ComposerTextView) -> Void = { _, _ in }
    var directSlash: () -> Void = {}
    var pasted: () -> Void = {}
    var completionKey: (UInt16, NSEvent.ModifierFlags) -> Bool = { _, _ in false }
    var focused: () -> Void = {}
    var accessibilityLabel = "Message composer"
    var inputRejected: (String) -> Void = { _ in }
    var imageRejected: ((String) -> Void)? = nil
    /// Image files dropped on or pasted into the composer.
    var attachFiles: (([URL]) -> Void)? = nil
    var pastedImages: PastedImageStorage? = nil
    var beginImageImport: () -> ComposerImageImport = { ComposerImageImport() }
    /// A changed token moves keyboard focus into the editor once the view is in a window.
    var focusToken = 0
    /// The token a new editor starts from. A new editor acts on a token
    /// past this one, which may be a request made before it existed.
    var settledFocusToken = 0
    /// The selected skills, drawn as tokens that lead the text.
    var skills: [SkillChip] = []
    /// Whose selection the tokens are: Backspace and Remove edit it.
    var skillDisplay: SessionDisplay? = nil
    var skillsChanged: @MainActor () -> Void = {}
    var skillPressed: (SkillChip, ComposerSkillToken) -> Void = { _, _ in }
    var skillHovered: (SkillChip, ComposerSkillToken, Bool) -> Void = { _, _, _ in }
    var describeSkill: (SkillChip) -> SkillDetail? = { _ in nil }
    /// The field's ceiling (`ComposerScrollView.ceiling`).
    var maximumFieldHeight: CGFloat = ComposerScrollView.maximumHeight
    /// False holds the text still: no typing, paste or drop changes it.
    var editable = true
    /// A coordinator for this value, outside any field (tests drive one directly).
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    /// Builds the field, its editor and its coordinator, showing this value.
    func makeView() -> ComposerScrollView {
        let coordinator = Coordinator(self)
        let scroll = ComposerScrollView()
        scroll.coordinator = coordinator; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        // An overlay scroller never narrows the text container, so a reply reaching the height
        // clamp cannot rewrap, change height, hide the scroller and rewrap again.
        scroll.scrollerStyle = .overlay
        let editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false; editor.textContainerInset = ComposerTextView.textInset
        ComposerTextView.applyLineMetrics(to: editor)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.delegate = coordinator
        editor.setAccessibilityLabel(accessibilityLabel); editor.setAccessibilityIdentifier("nativeComposer"); editor.sessionID = sessionID
        // Every one of these is held by the editor, and the coordinator holds
        // this view value, whose closures hold the chat's page and the whole
        // workspace. Capturing the coordinator strongly made an editor that
        // outlived its pane — AppKit keeps a text view alive past its
        // pane's teardown — keep that chat's transcript page in memory for
        // the rest of the session, so memory grew with every chat visited.
        editor.send = { [weak coordinator] in coordinator?.parent.send($0) }
        editor.directSlash = { [weak coordinator] in coordinator?.parent.directSlash() }
        editor.pasted = { [weak coordinator] in coordinator?.parent.pasted() }
        editor.attachFiles = { [weak coordinator] in coordinator?.parent.attachFiles?($0) }
        editor.attachmentDestination = { [weak coordinator] in
            guard let parent = coordinator?.parent, let attach = parent.attachFiles else { return nil }
            // Snapshot the callbacks for this session before conversion yields.
            return ComposerTextView.AttachmentDestination(attach: attach, reject: parent.imageRejected ?? parent.inputRejected, storage: parent.pastedImages, beginImport: parent.beginImageImport)
        }
        editor.imageRejected = { [weak coordinator] message in
            guard let parent = coordinator?.parent else { return }
            (parent.imageRejected ?? parent.inputRejected)(message)
        }
        editor.registerForDraggedTypes([.fileURL] + ComposerTextView.imagePasteboardTypes + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
        editor.completionKey = { [weak coordinator] in coordinator?.parent.completionKey($0, $1) ?? false }
        editor.focused = { [weak editor, weak coordinator] in
            if let editor { coordinator?.focusChanged(editor) }
        }
        // The field's height is the scroll view's own: the text's height is
        // its intrinsic height, so the pane sizes the field in the pass that
        // laid the new line out. Handed on through state a run-loop turn
        // later, the line was drawn in the old frame first and the field
        // grew (or shrank) a frame behind it, moving the transcript twice.
        editor.contentHeightChanged = { [weak scroll] height in scroll?.request(height) }
        editor.skillStrip.changed = { [weak coordinator] in coordinator?.parent.skillsChanged() }
        editor.skillStrip.pressed = { [weak coordinator] in coordinator?.parent.skillPressed($0, $1) }
        editor.skillStrip.hovered = { [weak coordinator] in coordinator?.parent.skillHovered($0, $1, $2) }
        editor.skillStrip.describe = { [weak coordinator] in coordinator?.parent.describeSkill($0) }
        editor.string = text; coordinator.adopt(text); scroll.documentView = editor
        editor.skillStrip.display = skillDisplay; editor.skillTokens = skills
        // The ceiling, whether it may be edited and any focus request apply
        // from the start, as they do on every later value.
        apply(to: scroll)
        return scroll
    }
    /// Hands the field a newer value: the model's text, focus requests, the
    /// ceiling, the skills and whether it may be edited.
    func apply(to scroll: ComposerScrollView) {
        guard let coordinator = scroll.coordinator else { return }
        coordinator.parent = self
        if coordinator.appliedFocusToken != focusToken, let editor = scroll.documentView as? ComposerTextView {
            coordinator.appliedFocusToken = focusToken
            DispatchQueue.main.async { [weak editor] in
                guard let editor, let window = editor.window, window.attachedSheet == nil, !editor.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(editor)
            }
        }
        if scroll.ceiling != maximumFieldHeight { scroll.ceiling = maximumFieldHeight }
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.sessionID = sessionID
        // The model's own text always applies; only the reader's typing is held.
        if !editor.isEditable { editor.isEditable = true }
        coordinator.applyModelText(text, to: editor)
        if editor.isEditable != editable { editor.isEditable = editable }
        editor.skillStrip.display = skillDisplay; editor.skillTokens = skills
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposer
        var appliedFocusToken = 0
        private var applyingModelText = false
        private var rejectedModelText: String?
        private var focusRevision = 0
        private var locationRevision = 0
        private var draftRevision: UInt64 = 0
        private let editorGeneration = UUID()
        /// The text the editor and the model last agreed on, in the app's own
        /// storage. `NSTextView.string` hands back a fresh UTF-16 bridge each
        /// time; comparing the draft against one of those decodes the whole
        /// document, so a 200 KB draft used to cost about 10 ms per keystroke.
        /// Comparing against this copy is a pointer check in the usual case.
        private var settled: String?
        init(_ parent: NativeComposer) { self.parent = parent; appliedFocusToken = parent.settledFocusToken }
        func adopt(_ text: String) { if settled != text { draftRevision &+= 1 }; settled = text }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView else { return }
            scheduleLocation(editor)
        }
        private func scheduleLocation(_ editor: ComposerTextView) {
            locationRevision += 1; let revision = locationRevision
            // Selection can arrive while the model's text is applied; publish afterwards.
            Task { @MainActor [weak self, weak editor] in
                guard let self, let editor, revision == self.locationRevision else { return }
                let location = ComposerLocation(sessionID: editor.sessionID, editorGeneration: self.editorGeneration,
                    draftRevision: self.draftRevision, selectedRangeUTF16: editor.selectedRange(),
                    markedRangeUTF16: editor.hasMarkedText() ? editor.markedRange() : nil)
                editor.completionLocation = location
                self.parent.locationChanged(location, editor)
            }
        }
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
            guard current != text else { adopt(text); return }
            rejectedModelText = nil
            // insertText preserves native undo, but synchronously invokes the
            // delegate. A model-to-view refresh must not publish that same text
            // or completion state back to the model while it is being applied.
            applyingModelText = true; defer { applyingModelText = false }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
            let applied = Self.contents(of: editor)
            adopt(applied); scheduleLocation(editor)
            if applied != text { rejectedModelText = text }
        }
        func focusChanged(_ editor: ComposerTextView) {
            focusRevision += 1; let revision = focusRevision
            // Report navigation and native view attachment can restore first
            // responder inside a layout or update pass. Publish after it
            // and reject callbacks superseded by another responder or sheet.
            Task { @MainActor [weak self, weak editor] in
                guard let self, let editor, self.focusRevision == revision,
                      let window = editor.window, window.firstResponder === editor,
                      window.attachedSheet == nil, !editor.isHiddenOrHasHiddenAncestor else { return }
                self.parent.focused()
            }
        }
        /// The most a message may hold: 256 KiB of UTF-8, the helper's own
        /// limit on what it is sent.
        static let byteLimit = 262_144
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            guard replacementString.utf8.count <= Self.byteLimit, NSMaxRange(affectedCharRange) <= (textView.textStorage?.length ?? 0),
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
            if units <= (byteLimit - added) / 3 { return true }
            let text = textView.string
            return text.utf8.count - (text as NSString).substring(with: range).utf8.count + added <= byteLimit
        }
        func textDidChange(_ notification: Notification) {
            guard !applyingModelText, let editor = notification.object as? NSTextView else { return }
            // The editor only notifies after a real edit, so the text is new by
            // construction: comparing it against the draft first would cost a
            // full decode of the document for nothing.
            let text = Self.contents(of: editor)
            adopt(text)
            parent.text = text
            parent.textChanged(text)
            if !editor.hasMarkedText() { parent.completion(text) }
            if let editor = editor as? ComposerTextView { scheduleLocation(editor) }
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
/// The composer's scroll view. Its intrinsic height is the text's, between
/// the field's floor and ceiling, and it asks to be sized again the moment
/// that height changes (`heightChanged`).
@MainActor final class ComposerScrollView: NSScrollView {
    /// What the field shows and calls; it holds the newest `NativeComposer`.
    fileprivate(set) var coordinator: NativeComposer.Coordinator?
    /// Called once the field's height has changed, for the view laying it out.
    var heightChanged: (() -> Void)?
    static let minimumHeight: CGFloat = 44
    static let maximumHeight: CGFloat = 240
    /// The ceiling with a terminal open below the chat: the field gives way
    /// (its text scrolls) so the transcript keeps its reading space.
    static let besideTerminalHeight: CGFloat = 88
    /// The ceiling now; lowering it shrinks a tall field, raising it lets
    /// the text take its own height again.
    var ceiling: CGFloat = ComposerScrollView.maximumHeight {
        didSet { if ceiling != oldValue { setField(textHeight) } }
    }
    /// The height the text asks for, before the ceiling.
    private var textHeight: CGFloat = ComposerScrollView.minimumHeight
    /// The text's own height, kept for when the ceiling moves.
    func request(_ height: CGFloat) { textHeight = height; setField(height) }
    /// The field's height: the text's, between the floor and the ceiling.
    private(set) var fieldHeight: CGFloat = ComposerScrollView.minimumHeight
    /// Clamped before it is stored, so a height clamped to the one already
    /// shown changes nothing, and one clamped to a new height is announced.
    /// (Clamping inside the property's own observer stored the clamped value
    /// without announcing it: a field cleared below the floor kept its old
    /// height until something else measured it.)
    private func setField(_ height: CGFloat) {
        let clamped = min(ceiling, Self.maximumHeight, max(Self.minimumHeight, height))
        guard clamped != fieldHeight else { return }
        fieldHeight = clamped
        invalidateIntrinsicContentSize()
        heightChanged?()
        // A height that changes inside a layout pass (the window resized
        // and the text or its tokens rewrapped) is not taken up by the
        // pass that is running, so it is asked for again after it.
        DispatchQueue.main.async { [weak self] in self?.invalidateIntrinsicContentSize(); self?.heightChanged?() }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: fieldHeight) }
}

@MainActor final class ComposerTextView: NSTextView {
    /// The keys that belong to the conversation rather than to the draft.
    static func conversationScroll(for keyCode: UInt16) -> TranscriptKeyScroll? {
        switch keyCode {
        case KeyCode.pageUp: return .pageUp
        case KeyCode.pageDown: return .pageDown
        case KeyCode.home: return .top
        case KeyCode.end: return .bottom
        default: return nil
        }
    }
    /// True while the whole draft is on screen, so these keys have nothing to
    /// do here. A draft long enough to scroll keeps them.
    var draftFitsInTheField: Bool {
        guard let scroll = enclosingScrollView else { return true }
        return (scroll.documentView?.frame.height ?? 0) <= scroll.contentSize.height + 1
    }
    /// The conversation this composer sits under: the transcript showing this
    /// editor's own chat. A side conversation's composer is under the side's
    /// transcript; the first one in the window is always the chat's, and the
    /// side's page keys used to scroll that one.
    func conversationScrollView() -> TranscriptNativeScrollView? {
        func collect(_ view: NSView, into found: inout [TranscriptNativeScrollView]) {
            if let scroll = view as? TranscriptNativeScrollView { found.append(scroll); return }
            for child in view.subviews { collect(child, into: &found) }
        }
        guard let root = window?.contentView else { return nil }
        var found: [TranscriptNativeScrollView] = []
        collect(root, into: &found)
        if let own = found.first(where: { ($0.documentView as? TranscriptNativeDocument)?.shownSessionID == sessionID }) { return own }
        // A document names its chat one update after the composer does: while
        // a switch lands, the transcript in this editor's own column.
        let column = convert(bounds, to: nil).midX
        return found.first { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return frame.minX <= column && column <= frame.maxX
        }
    }
    /// The chat this editor belongs to (see `WindowPresentationController.redirectTyping`).
    var sessionID = ""
    var completionLocation: ComposerLocation?
    /// The selected skills drawn as tokens ahead of the text (ComposerSkillTokens.swift).
    let skillStrip = ComposerSkillStrip()
    /// Rows of tokens above the text's first line move the text down.
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + skillTextOffset)
    }
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        // The text view sizes itself to its text alone; the moved-down text
        // needs the rows above it as well.
        if skillTextOffset > 0, isVerticallyResizable, let layout = layoutManager, let container = textContainer {
            size.height = max(size.height, ceil(layout.usedRect(for: container).height + textContainerInset.height * 2 + skillTextOffset))
        }
        let widthChanged = size.width != frame.width
        super.setFrameSize(size)
        if widthChanged, !skillStrip.tokens.isEmpty { layoutSkillTokens() }
    }
    override func deleteBackward(_ sender: Any?) {
        if removeLastSkillToken() { return }
        super.deleteBackward(sender)
    }
    override func deleteWordBackward(_ sender: Any?) {
        if removeLastSkillToken() { return }
        super.deleteWordBackward(sender)
    }
    override func moveLeft(_ sender: Any?) {
        if focusLastSkillToken() { return }
        super.moveLeft(sender)
    }
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        return skillStrip.tokens.isEmpty ? children : skillStrip.tokens + children
    }

    /// Text and explicit skill authorization form one native undo operation.
    func replaceCompletion(range: NSRange, with replacement: String, skills: [SkillChip],
                           display: SessionDisplay, changed: @escaping @MainActor @Sendable () -> Void) {
        let before = NativeComposer.Coordinator.contents(of: self), beforeSkills = display.skills, beforeRange = selectedRange()
        let after = (before as NSString).replacingCharacters(in: range, with: replacement)
        applySkillEdit(text: after, skills: skills, selection: NSRange(location: range.location + (replacement as NSString).length, length: 0),
                       previous: (before, beforeSkills, beforeRange), display: display, changed: changed)
    }
    private func applySkillEdit(text: String, skills: [SkillChip], selection: NSRange,
                               previous: (String, [SkillChip], NSRange), display: SessionDisplay, changed: @escaping @MainActor @Sendable () -> Void) {
        guard sessionID == display.id else { return }
        breakUndoCoalescing()
        undoManager?.disableUndoRegistration()
        insertText(text, replacementRange: NSRange(location: 0, length: textStorage?.length ?? 0))
        setSelectedRange(selection); display.draft = text; display.skills = skills
        display.directCommand = false; display.completionVisible = false; changed()
        undoManager?.enableUndoRegistration()
        undoManager?.registerUndo(withTarget: self) { [weak display] editor in
            MainActor.assumeIsolated {
                guard let display else { return }
                editor.applySkillEdit(text: previous.0, skills: previous.1, selection: previous.2,
                                      previous: (text, skills, selection), display: display, changed: changed)
            }
        }
        undoManager?.setActionName("Select Skill")
        window?.makeFirstResponder(self)
    }
    private var measurement = ComposerEditMeasurement()
    var send: ((ComposerSubmissionIntent) -> Void)?
    var directSlash: (() -> Void)?
    var pasted: (() -> Void)?
    var completionKey: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    var focused: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0
    /// The tallest the field ever becomes; past it the exact text height no
    /// longer changes the layout, so it is never measured.
    var maximumContentHeight: CGFloat = ComposerScrollView.maximumHeight
    /// Reports the laid-out text height so the shell can grow the field with
    /// its content. A long draft is laid out only as far as the ceiling:
    /// `ensureLayout(for:)` would lay out every line of a 200 KB draft on every
    /// keystroke, which is the whole cost of typing into one.
    func reportContentHeight() {
        guard let container = textContainer, let layout = layoutManager else { return }
        let inset = textContainerInset.height * 2
        let ceiling = max(0, maximumContentHeight - inset)
        layout.ensureLayout(forBoundingRect: CGRect(x: 0, y: 0, width: container.size.width, height: ceiling + 1), in: container)
        let height = ceil(min(layout.usedRect(for: container).height + skillTextOffset, ceiling) + inset)
        if abs(height - reportedHeight) >= 1 { reportedHeight = height; contentHeightChanged?(height) }
    }
    override func layout() { super.layout(); layoutSkillTokens(); reportContentHeight() }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focused?() }; return accepted }
    var attachFiles: (([URL]) -> Void)?
    @MainActor struct AttachmentDestination {
        var attach: ([URL]) -> Void
        var reject: ((String) -> Void)?
        var storage: PastedImageStorage? = nil
        var beginImport: () -> ComposerImageImport = { ComposerImageImport() }
    }
    var attachmentDestination: (() -> AttachmentDestination?)?
    /// Reported when a pasted or dropped image cannot be read; wired to the
    /// same notice the composer uses for text it refuses.
    var imageRejected: ((String) -> Void)?
    /// A plain NSTextView disables Paste for image-only boards before paste:
    /// can run. Menu admission, like drag admission, reads only type metadata.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.acceptsImageTypes(on: .general) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if PerformanceProbe.shared.enabled { measurement.begin(event: PerformanceProbe.now, handler: PerformanceProbe.now) }
        defer { measurement.end() }
        // A screenshot on the clipboard or a copied image file becomes an
        // attachment instead of a pasted file path.
        if pasteAttachments(from: NSPasteboard.general) { return }
        pasted?(); super.paste(sender)
    }
    /// True when an image paste was handled, including a visible refusal.
    /// Separated from `paste` so a test can paste from its own pasteboard
    /// rather than the clipboard the owner is using.
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        let urls = Self.imageFiles(on: pasteboard)
        let imageWasCopied = Self.imageIsWhatWasCopied(on: pasteboard)
        let image = imageWasCopied && (pasteboard.types ?? []).contains(where: Self.isImageType)
        let promise = imageWasCopied && Self.hasFilePromise(on: pasteboard)
        guard urls != nil || image || promise else { return false }
        // A resolver returning nil is an unavailable destination, not a reason
        // to fall back to an old callback or paste an image's caption as text.
        let resolved: AttachmentDestination?
        if let attachmentDestination { resolved = attachmentDestination() }
        else { resolved = attachFiles.map { AttachmentDestination(attach: $0, reject: imageRejected) } }
        guard let destination = resolved else {
            imageRejected?("Images cannot be attached in this composer. Open an editable chat and try again."); return true
        }
        guard urls != nil || image else {
            destination.reject?("This clipboard item promises a file but has no image data. Save the image, then attach the file."); return true
        }
        let pasted = urls == nil ? Self.pastedImage(on: pasteboard) : nil
        let storage = destination.storage
        let importing = destination.beginImport()
        // Decoding a screenshot, re-encoding it and writing it out takes long
        // enough to freeze the window: a 4000x3000 paste is hundreds of
        // milliseconds. Only the bytes are taken here; the rest happens off
        // the main thread and the chip appears when it lands.
        Task { @MainActor in
            defer { importing.finish() }
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    if let urls { return try Self.preparePastedFiles(urls, storage: storage) }
                    guard let storage else { throw HostError.failure(Self.storageUnavailable) }
                    guard let pasted, let file = Self.writePastedImage(pasted, storage: storage) else { throw HostError.failure(Self.unreadableImage) }
                    return [file]
                }.value
                guard importing.isCurrent() else {
                    destination.reject?("The draft changed while its image was being prepared. Attach it again.")
                    return
                }
                destination.attach(written)
            } catch {
                destination.reject?(error.localizedDescription)
            }
        }
        return true
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        return isEditable && Self.acceptsImageTypes(on: pasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if pasteAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
    /// Image bytes taken from the pasteboard without decoding them.
    struct PastedImage: Sendable { let data: Data; let isPNG: Bool }
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [.png] +
        [UTType.jpeg, .heic, .heif, .gif, .webP, .bmp].map { .init($0.identifier) } + [.tiff]
    private nonisolated static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }
    private static func hasFilePromise(on pasteboard: NSPasteboard) -> Bool {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        return !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes + ["com.apple.filepromise", "com.apple.pasteboard.promised-file-url"])
    }
    /// Drag admission must not fetch/decode a promised screenshot's bytes.
    static func acceptsImageTypes(on pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { $0 == .fileURL || isImageType($0) } || hasFilePromise(on: pasteboard)
    }
    /// Files win over their icons. Rich text with a rendering stays text;
    /// an image's URL, image-only HTML or lower-fidelity caption does not
    /// replace the image. Ambiguous text-first copies remain text.
    static func imageIsWhatWasCopied(on pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) { return false }
        if types.contains(.URL) { return true }
        let text = types.contains(.string) ? pasteboard.string(forType: .string) ?? "" : ""
        let hasText = text.contains { !$0.isWhitespace && $0 != "\u{fffc}" }
        if types.contains(.html), let html = pasteboard.string(forType: .html) {
            // Inspect markup only; an attributed HTML reader can fetch images
            // or stylesheets. Never load resources from copied HTML.
            guard html.utf8.count <= NativeComposer.Coordinator.byteLimit,
                  html.range(of: "(?i)<img\\b", options: .regularExpression) != nil else { return false }
            let visible = html
                .replacingOccurrences(of: "(?is)<!--.*?-->|<(head|style|script)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<(?:[^\"'>]|\"[^\"]*\"|'[^']*')*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)&nbsp;|&#160;|&#xA0;", with: " ", options: .regularExpression)
            return visible.allSatisfy { $0.isWhitespace || $0 == "\u{fffc}" }
        }
        if hasText, types.contains(.rtf) || types.contains(.rtfd) { return false }
        guard hasText else { return true }
        return types.first(where: { isImageType($0) || $0 == .string }).map(isImageType) ?? false
    }
    static func pastedImage(on pasteboard: NSPasteboard) -> PastedImage? {
        // AppKit also advertises a synthesized TIFF for JPEG/HEIC/etc.
        // Prefer their encoded source before TIFF to avoid a main-thread
        // conversion. Only request listed types; ImageIO decodes later.
        let types = (pasteboard.types ?? []).filter(isImageType)
        let ordered = imagePasteboardTypes.filter(types.contains) + types.filter { !imagePasteboardTypes.contains($0) }
        for type in ordered {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return PastedImage(data: data, isPNG: type == .png) }
        }
        return nil
    }
    private nonisolated static let unreadableImage = "That image could not be read or saved. Copy it again, or attach the file instead."
    private nonisolated static let storageUnavailable = "Desktop image storage is unavailable. Attach an image file instead."
    /// Preserve accepted PNGs; bridge larger clipboard images to the helper's
    /// 8 MiB attachment gate. Its provider normalizer still owns ordinary files.
    nonisolated static func writePastedImage(_ image: PastedImage, storage: PastedImageStorage) -> URL? {
        if image.isPNG, !image.data.isEmpty, image.data.count <= 8 * 1024 * 1024 { return try? storage.write(image.data) }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return nil }
        return writePastedImage(source, largePNG: image.isPNG, storage: storage)
    }
    private nonisolated static func writePastedImage(_ source: CGImageSource, largePNG: Bool = false, storage: PastedImageStorage) -> URL? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        var normalized = largePNG
        var pixels = normalized ? min(2000, max(width, height)) : max(width, height)
        while true {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            // PiImage's strict 4.5 MiB base64 bound and 2,000-pixel ceiling.
            if bytes.length <= 8 * 1024 * 1024, !normalized || (bytes.length + 2) / 3 * 4 < 4_718_592 {
                return try? storage.write(bytes as Data)
            }
            guard pixels > 1 else { return nil }
            pixels = normalized ? max(1, pixels * 3 / 4) : min(2000, pixels)
            normalized = true
        }
    }
    private nonisolated static func preparePastedFiles(_ urls: [URL], storage: PastedImageStorage?) throws -> [URL] {
        try urls.map { url in
            let canonical = url.resolvingSymlinksInPath()
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let count = values.fileSize, count > 0 else { throw HostError.failure("Select a regular image file.") }
            // Native files still go through the ordinary inspector once.
            // Its integrity/refusal errors must not become conversion retries.
            if count <= 8 * 1024 * 1024, ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) { return url }
            guard let storage else { throw HostError.failure(storageUnavailable) }
            guard let source = CGImageSourceCreateWithURL(canonical as CFURL, nil),
                  let file = writePastedImage(source, storage: storage) else { throw HostError.failure(unreadableImage) }
            return file
        }
    }
    /// File URLs are explicit input; TIFF/HEIC and oversized images are
    /// converted in the same background import as clipboard bytes.
    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL]? {
        guard pasteboard.types?.contains(.fileURL) == true,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension.lowercased())?.conforms(to: .image) == true }
        return images.isEmpty ? nil : images
    }
    override func didChangeText() { measurement.edited(); super.didChangeText(); reportContentHeight() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // The comparison below feeds a measurement that is off in the app.
        // Copying and comparing the whole draft for it on every input-method
        // step was the cost of the keystroke on a long draft.
        guard PerformanceProbe.shared.enabled else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); return
        }
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
    /// ⌘↩ steers a running chat and sends an idle one, as the hint under the
    /// composer says. AppKit offers a ⌘ key to the window's views and then to
    /// the menu bar before keyDown, and the Conversation menu's ⌘↩ used to
    /// take it there: the message was queued as a follow-up instead. The
    /// composer the reader is typing in claims ⌘↩ first; keyDown decides.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyCode.isReturn(event.keyCode), event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           window?.firstResponder === self {
            keyDown(with: event); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        let sends = KeyCode.isReturn(event.keyCode) && !event.modifierFlags.contains(.shift) && !hasMarkedText()
        if PerformanceProbe.shared.enabled && !event.modifierFlags.contains(.command) && !sends {
            let now = PerformanceProbe.now
            PerformanceProbe.shared.observe("nativeEventDispatchDelayMs", milliseconds: now - event.timestamp * 1000)
            measurement.begin(event: event.timestamp * 1000, handler: now)
        }
        defer { measurement.end() }
        if !hasMarkedText(), event.characters == "/", selectedRange().location == 0 { directSlash?() }
        if !hasMarkedText(), !event.modifierFlags.contains(.shift), completionKey?(event.keyCode, event.modifierFlags) == true { return }
        if KeyCode.isReturn(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewline(nil); return }
            if !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) {
                send?(event.modifierFlags.contains(.command) ? .steer : .followUp); return
            }
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
        // it does not force a window layout or run when the editor is hidden.
        if window?.isVisible == true { displayIfNeeded() }
    }
}
