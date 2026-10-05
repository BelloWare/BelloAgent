import AppKit
import Combine

/// A chat's side beside it: its own conversation pane, with the side's
/// header (bring back, keep, close). Bring Back opens the handoff sheet.
@MainActor final class SidePaneView: NSView, PiKit.SizeObserver {
    let model: WorkspaceModel
    let session: SessionDisplay
    private(set) var info: SideRecord
    /// The share of the content column this side has, for the composer bar.
    var paneWidth: CGFloat { didSet { pane.composerProposalWidth = paneWidth } }
    let pane: ConversationPaneView
    private var observer: ShellObserver!
    private var handoff: PiSheetWindow?
    var inheritedEnabled = true {
        didSet {
            pane.inheritedEnabled = inheritedEnabled
            // An open handoff follows it, as the SwiftUI sheet followed its
            // presenter: on the next turn, as its coordinator did, since this
            // can be set inside SwiftUI's update and the sheet's settings publish.
            guard inheritedEnabled != oldValue, handoff != nil else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handoff?.inherit(PiSheetWindowInherited(reduceMotion: PiKit.Motion.reduced, enabled: self.inheritedEnabled))
                }
            }
        }
    }

    init(model: WorkspaceModel, session: SessionDisplay, info: SideRecord, paneWidth: CGFloat) {
        self.model = model; self.session = session; self.info = info; self.paneWidth = paneWidth
        pane = ConversationPaneView(model: model)
        super.init(frame: .zero)
        pane.composerProposalWidth = paneWidth
        // The hairline that used to start this pane is the split's draggable
        // divider now, drawn once by the workspace between the two panes.
        addSubview(pane)
        observer = ShellObserver { [weak self] in self?.show() }
        observer.observe(model)
        show()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    var minimumWidth: CGFloat { pane.minimumWidth }
    func contentSizeChanged() { needsLayout = true; PiKit.sizeChanged(self) }

    func update(info: SideRecord, paneWidth: CGFloat) {
        self.info = info; self.paneWidth = paneWidth
        show()
    }
    private func show() {
        let model = self.model, id = info.id
        pane.show(session: session, chat: model.record(id) ?? info.chat, side: info,
                  sideActions: SideActions(bringBack: { [weak self] in self?.bringBack() }, keep: { model.keepSide(id) }, close: { model.closeSide(id) }))
    }
    override func layout() { super.layout(); pane.frame = bounds }
    /// The side gone from the window (closed, or another chat shown): its
    /// handoff goes with it, at once, as the SwiftUI sheet went with its view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let handoff { self.handoff = nil; handoff.end(animated: false, requested: true) }
    }

    /// The handoff sheet over this window.
    private func bringBack() {
        guard let window, window.attachedSheet == nil else { return }
        let model = self.model, session = self.session
        handoff = AppKitSheets.present(on: window, size: SideHandoffView.size, enabled: inheritedEnabled) { dismiss in
            SideHandoffView(model: model, session: session, dismiss: dismiss)
        }
    }
}

/// Edit what the side found before it goes back to the parent's draft.
@MainActor final class SideHandoffView: NSView, InheritsEnabled {
    static let size = NSSize(width: 720, height: 480)
    let model: WorkspaceModel
    let session: SessionDisplay
    private let dismiss: () -> Void
    let editor: NativeCodeEditorView
    private let notice = ShellNote("", tone: .danger)
    let cancel = PiKit.Button("Cancel", style: .secondary)
    let copy = PiKit.Button("Copy", symbol: "doc.on.doc", style: .secondary)
    let replace = PiKit.Button("Replace Parent Draft", style: .secondary)
    let insert = PiKit.Button("Insert in Parent Draft", style: .primary)
    private let body = HandoffBody()
    private let footer: SheetFooterRow
    private let sheet: PiKit.Sheet
    /// The window's disabled state, from the SwiftUI sheet around it.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }

    init(model: WorkspaceModel, session: SessionDisplay, dismiss: @escaping () -> Void) {
        self.model = model; self.session = session; self.dismiss = dismiss
        let text = session.messages.last(where: { $0.role == "assistant" && !$0.isStreaming })?.text ?? ""
        editor = NativeCodeEditorView(text: text, accessibilityLabel: "Editable side summary")
        footer = SheetFooterRow(leading: [copy], trailing: [replace, insert])
        sheet = PiKit.Sheet("Bring back to parent draft", subtitle: "Edit this summary or selection. Bringing it back only changes the parent draft; review it before sending.",
                            symbol: "arrow.uturn.backward", content: body, actions: [cancel], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        body.inset.content = editor
        body.notice = notice
        body.addSubview(notice)
        addSubview(sheet)
        editor.onChange = { [weak self] _ in self?.refresh() }
        cancel.onPress = { [weak self] in self?.dismiss() }
        sheet.dismiss = { [weak self] in self?.dismiss() }
        copy.onPress = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.editor.text, forType: .string)
        }
        replace.onPress = { [weak self] in self?.bringBack(replace: true) }
        insert.onPress = { [weak self] in self?.bringBack(replace: false) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }

    private func refresh() {
        let empty = editor.text.isEmpty
        for button in [copy, replace, insert] { button.isEnabled = !empty && inheritedEnabled }
        cancel.isEnabled = inheritedEnabled
        editor.editor.isEditable = inheritedEnabled
        sheet.cancelDisabled = !inheritedEnabled
        notice.isHidden = notice.text.isEmpty
        body.needsLayout = true
    }
    private func bringBack(replace: Bool) {
        do { try model.bringBack(editor.text, from: session.id, replace: replace); dismiss() }
        catch { notice.text = error.localizedDescription; refresh() }
    }

    /// The editor in its inset, filling the room, the error under it
    /// (`VStack(spacing: 8)` in the sheet's 24-point padding).
    @MainActor final class HandoffBody: NSView {
        let inset = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md)
        var notice: ShellNote?
        override init(frame: NSRect) { super.init(frame: frame); inset.clipsContent = true; addSubview(inset) }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            let inner = bounds.insetBy(dx: PiSpacing.xl, dy: PiSpacing.xl)
            var noteHeight: CGFloat = 0
            if let notice, !notice.isHidden { noteHeight = notice.height(forWidth: inner.width) + PiSpacing.sm }
            inset.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(0, inner.height - noteHeight))
            notice?.frame = CGRect(x: inner.minX, y: inset.frame.maxY + PiSpacing.sm, width: inner.width, height: max(0, noteHeight - PiSpacing.sm))
        }
    }
}
