import AppKit

struct TopicEditorTarget: Identifiable, Equatable {
    let projectID: String
    let topicID: String?
    var id: String { projectID + ":" + (topicID ?? "new") }
    init(projectID: String, topicID: String? = nil) {
        self.projectID = projectID; self.topicID = topicID
    }
}

/// A topic is local organization within a project; creating one neither opens
/// a session nor changes a session's working directory or model.
@MainActor final class TopicSheetView: NSView, InheritsEnabled {
    static let size = NSSize(width: 480, height: 260)
    let model: WorkspaceModel
    let target: TopicEditorTarget
    private let dismiss: () -> Void
    let field = PiKit.TextField(placeholder: "Topic name", icon: "folder")
    private let explainer = ShellText("Topics keep chats together without changing their context or project folders.", font: PiKit.Font.caption, color: .piInkSecondary)
    private let notice = ShellNote("", tone: .danger)
    let cancel = PiKit.Button("Cancel", style: .secondary)
    let save = PiKit.Button("Create Topic", style: .primary)
    private let column: ShellStack
    private let footer: SheetFooterRow
    private let sheet: PiKit.Sheet
    private var saving = false { didSet { refresh() } }
    /// The window's disabled state, from the SwiftUI sheet around it.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    private var editing: Bool { target.topicID != nil }

    init(model: WorkspaceModel, target: TopicEditorTarget, dismiss: @escaping () -> Void) {
        self.model = model; self.target = target; self.dismiss = dismiss
        column = ShellStack(.vertical, spacing: PiSpacing.md, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl),
                            [.view(field, .fill), .view(explainer, .fill), .view(notice, .fill)])
        footer = SheetFooterRow(trailing: [save])
        sheet = PiKit.Sheet(target.topicID != nil ? "Rename topic" : "New topic", subtitle: "Group related chats inside this project.", symbol: "folder",
                            content: SheetCenteredContent(column), actions: [cancel], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addSubview(sheet)
        field.field.setAccessibilityLabel("Topic name"); field.field.setAccessibilityIdentifier("topicTitle")
        save.setAccessibilityIdentifier("saveTopic")
        field.onChange = { [weak self] _ in self?.refresh() }
        field.onSubmit = { [weak self] in self?.submit() }
        // Return submits (`onSubmit`); leaving the field does not.
        field.field.cell?.sendsActionOnEndEditing = false
        save.onPress = { [weak self] in self?.submit() }
        cancel.onPress = { [weak self] in self?.dismiss() }
        sheet.dismiss = { [weak self] in self?.dismiss() }
        if let id = target.topicID { field.text = model.topics.first { $0.id == id }?.title ?? "" }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }
    /// Closing: the field gives up its editor, which the window would keep.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, field.field.currentEditor() != nil { window.makeFirstResponder(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private var trimmed: String { field.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func refresh() {
        save.title = saving ? "Saving…" : editing ? "Rename" : "Create Topic"
        save.isEnabled = !saving && !trimmed.isEmpty && inheritedEnabled
        cancel.isEnabled = !saving && inheritedEnabled
        field.field.isEnabled = inheritedEnabled
        sheet.cancelDisabled = saving || !inheritedEnabled
        notice.isHidden = notice.text.isEmpty
        column.relayoutAll()
        footer.needsLayout = true
    }
    private func submit() {
        guard !saving, !trimmed.isEmpty else { return }
        saving = true; notice.text = ""
        let value = trimmed, model = self.model, target = self.target
        Task { [weak self] in
            do {
                if let id = target.topicID { try await model.renameTopic(id, title: value) }
                else { _ = try await model.createTopic(in: target.projectID, title: value) }
                self?.saving = false
                self?.dismiss()
            } catch {
                self?.notice.text = error.localizedDescription
                self?.saving = false
            }
        }
    }
}

/// A sheet that follows the window's disabled state (`.disabled` on the
/// SwiftUI around it).
@MainActor protocol InheritsEnabled: AnyObject { var inheritedEnabled: Bool { get set } }

/// A sheet's content that does not fill it, in the middle of its room, as
/// `PiSheet` placed a stack shorter than the sheet.
@MainActor final class SheetCenteredContent: NSView, PiKit.SizeObserver {
    let column: ShellStack
    init(_ column: ShellStack) { self.column = column; super.init(frame: .zero); addSubview(column) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true }
    override func layout() {
        super.layout()
        let height = column.height(forWidth: bounds.width)
        column.frame = CGRect(x: 0, y: max(0, PiKit.round((bounds.height - height) / 2, piScale)), width: bounds.width, height: height)
    }
}

/// A sheet's footer row: a spacer, then its buttons at the trailing edge
/// (`HStack { Spacer(); … }`), or buttons at both ends.
@MainActor final class SheetFooterRow: NSView {
    private let leading: [NSView], trailing: [NSView]
    init(leading: [NSView] = [], trailing: [NSView]) {
        self.leading = leading; self.trailing = trailing
        super.init(frame: .zero)
        for view in leading + trailing { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (leading + trailing).map(\.intrinsicContentSize.height).max() ?? 0)
    }
    override func layout() {
        super.layout()
        let scale = piScale
        var x: CGFloat = 0
        for view in leading {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, scale), width: size.width, height: size.height)
            x += size.width + PiSpacing.sm
        }
        var right = bounds.width
        for view in trailing.reversed() {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: right - size.width, y: PiKit.round((bounds.height - size.height) / 2, scale), width: size.width, height: size.height)
            right -= size.width + PiSpacing.sm
        }
    }
}
