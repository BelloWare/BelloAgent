import AppKit

/// Lives outside the composer card, above it, in both sidebar modes.
@MainActor final class PendingChatProjectChip: PiKit.PillFaceButton {
    private let model: WorkspaceModel
    private var sessionID: String?
    private var projectID: String?
    private var read: Task<Void, Never>?
    private var readGeneration = 0
    let presenter = PiPopoverPresenter()
    private(set) var picker: PendingChatProjectPicker?

    init(model: WorkspaceModel) {
        self.model = model
        super.init(label: "", icon: nil, chevron: "chevron.down", compact: true, fontSize: 12, padding: (10, 5), hoverFill: true)
        maxLabelWidth = 220
        setAccessibilityRole(.menuButton)
        setAccessibilityIdentifier("pending-chat-project")
        onPress = { [weak self] in self?.openProjects() }
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func show(sessionID: String?, project: WorkspaceRecord?, enabled: Bool) {
        if self.sessionID != sessionID || projectID != project?.id || project == nil || !enabled { close() }
        self.sessionID = sessionID; projectID = project?.id
        isHidden = project == nil
        isEnabled = enabled
        if let project {
            let name = URL(fileURLWithPath: project.path).lastPathComponent
            let text = "in " + name
            if label != text { label = text }
            setAccessibilityLabel("Project: \(name), change")
            toolTip = "Change project before sending · " + project.path
        }
    }
    func close() { readGeneration &+= 1; read?.cancel(); read = nil; presenter.close(); picker = nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { close() } }

    func openProjects() {
        if read != nil || presenter.isShown { close(); return }
        guard isEnabled, !isHidden, let id = sessionID, let current = projectID else { return }
        if let reason = model.pendingProjectBlocker(id) { model.displays[id]?.notice = reason; return }
        let projects = model.pendingChatProjects
        readGeneration &+= 1
        let generation = readGeneration
        read = Task { [weak self] in
            let available = await WorkspaceModel.availableChatProjects(projects)
            guard !Task.isCancelled, let self, self.readGeneration == generation else { return }
            self.read = nil
            guard self.sessionID == id, self.projectID == current, !self.isHidden,
                  self.model.pendingProjectBlocker(id) == nil else { return }
            let currentProjects = self.model.pendingChatProjects
            let entries: [PiMenuEntry] = available.filter(currentProjects.contains).map { project in
                .button(URL(fileURLWithPath: project.path).lastPathComponent, systemImage: "folder", checked: project.id == current,
                        identifier: project.id, help: project.path) { [weak self] in
                    guard let self else { return }
                    self.close()
                    Task {
                        do { try await self.model.setPendingChatProject(project.id, for: id) }
                        catch { self.model.displays[id]?.notice = error.localizedDescription }
                    }
                }
            }
            let picker = PendingChatProjectPicker(entries: entries) { [weak self] in self?.close() }
            self.picker = picker
            self.presenter.toggle(from: self, width: 310, maximumHeight: 470, animates: true) { picker }
            if picker.search.isHidden { picker.window?.makeFirstResponder(picker) }
            else { picker.window?.makeFirstResponder(picker.search.field) }
        }
    }
}

/// Pi menu commands rendered as a searchable, keyboard-driven choice list.
/// Menu construction and filtering only run on explicit picker interaction.
@MainActor final class PendingChatProjectPicker: NSView, PiKit.WidthSizing, NSTextFieldDelegate {
    let entries: [PiMenuEntry]
    let search = PiKit.TextField(placeholder: "Search projects", icon: "magnifyingglass")
    private let list = LazyStackView()
    private let heading = PiKit.TextLine(PiKit.Line("New chat in", font: PiKit.Font.caption, color: .piInkSecondary))
    private let empty = PiKit.TextLine(PiKit.Line("No available projects", font: PiKit.Font.body, color: .piInkSecondary))
    private let cancel: () -> Void
    private(set) var visible: [PiMenuItem] = []
    private(set) var highlighted: String?

    init(entries: [PiMenuEntry], cancel: @escaping () -> Void) {
        self.entries = entries; self.cancel = cancel
        super.init(frame: .zero)
        for view in [search, list, heading, empty] as [NSView] { addSubview(view) }
        search.isHidden = entries.count < 8
        search.field.delegate = self; search.field.setAccessibilityLabel("Search projects")
        list.spacing = 2
        list.setAccessibilityLabel("Projects. Up and Down select; Return changes project.")
        setAccessibilityIdentifier("pending-chat-project-picker")
        filter("")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { (search.isHidden ? 36 : 78) + min(340, max(52, CGFloat(visible.count) * 54)) + 8 }

    func filter(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = entries.compactMap { if case .item(let item) = $0 { return item }; return nil }.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.help?.localizedCaseInsensitiveContains(query) ?? false)
        }
        if !visible.contains(where: { $0.identifier == highlighted }) {
            highlighted = (visible.first(where: \.checked) ?? visible.first)?.identifier
        }
        empty.isHidden = !visible.isEmpty
        render(); needsLayout = true; PiKit.sizeChanged(self)
    }
    private func render() {
        let items = visible
        list.reload(.init(count: items.count, key: { items[$0].identifier ?? items[$0].title }, height: { _, _ in 52 }, view: { [weak self] index, _ in
            let item = items[index]
            let name = PiKit.TextLine(PiKit.Line(item.title, font: PiKit.Font.body, color: .piInk))
            let path = PiKit.TextLine(PiKit.Line(item.help ?? "", font: PiKit.Font.caption, color: .piInkSecondary)); path.truncation = .middle
            let check = PiKit.SymbolView(PiKit.Symbol(item.checked ? "checkmark" : "folder", size: 12), color: item.checked ? .piAccent : .piInkTertiary)
            let text = ShellStack(.vertical, spacing: 3, [.view(name, .fill), .view(path, .fill)])
            let content = ShellStack(.horizontal, spacing: 8, [.view(check), .view(text, .fill)])
            let row = PiKit.SelectableRow(content: content, selected: item.identifier == self?.highlighted, action: { [weak self] in self?.activate(item.identifier) })
            row.setAccessibilityLabel(item.title + (item.checked ? ", current project" : "") + ", " + (item.help ?? ""))
            row.setAccessibilityIdentifier("pending-project-" + (item.identifier ?? item.title))
            row.toolTip = item.help
            return row
        }))
    }
    func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.identifier == highlighted } ?? 0
        let next = min(max(0, index + delta), visible.count - 1)
        highlighted = visible[next].identifier; render(); list.scrollToRow(next)
    }
    func activate(_ id: String?) { visible.first { $0.identifier == id && $0.enabled }?.perform() }
    func controlTextDidChange(_ obj: Notification) { filter(search.text) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): activate(highlighted)
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }; return true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode { case 125: move(1); case 126: move(-1); case 36, 76: activate(highlighted); case 53: cancel(); default: super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { cancel() }
    override func layout() {
        super.layout()
        heading.frame = CGRect(x: 16, y: 12, width: max(0, bounds.width - 32), height: 17)
        search.frame = CGRect(x: 12, y: 36, width: max(0, bounds.width - 24), height: 34)
        let top: CGFloat = search.isHidden ? 36 : 78
        list.frame = CGRect(x: 8, y: top, width: max(0, bounds.width - 16), height: max(0, bounds.height - top - 8))
        empty.frame = CGRect(x: 16, y: top + 12, width: max(0, bounds.width - 32), height: 20)
    }
}
