import AppKit

struct RenameTarget: Identifiable, Equatable { let id: String }

/// Rename a chat by hand or from three mini-model suggestions drawn from its
/// first message. Suggestions need the connection's mini model, like titles.
@MainActor final class RenameChatSheetView: NSView, InheritsEnabled {
    static let size = NSSize(width: 520, height: 400)
    let model: WorkspaceModel
    let chatID: String
    private let dismiss: () -> Void
    let field = PiKit.TextField(placeholder: "Chat title", icon: "text.cursor")
    private let heading = PiKit.TextLine(PiKit.Line("Suggestions", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
    private let spinner = PiKit.spinner(controlSize: .small)
    let suggest = PiKit.Button("Suggest titles", symbol: "sparkles", style: .secondary, compact: true)
    private let explainer = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let list: ShellStack
    private var rows: [PiKit.SelectableRow] = []
    private let notice = ShellNote("", tone: .danger)
    let cancel = PiKit.Button("Cancel", style: .secondary)
    let rename = PiKit.Button("Rename", style: .primary)
    private let column: ShellStack
    private let headingRow: ShellStack
    private let footer: SheetFooterRow
    private let sheet: PiKit.Sheet
    private var suggestions: [String] = []
    private var suggesting = false
    private var saving = false
    /// The suggestions are a request to the mini model that polls for its
    /// answer. They belong to the sheet: closing it cancels them.
    private var requested: Task<Void, Never>?
    /// The window's disabled state, from the SwiftUI sheet around it.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    private var observer: ShellObserver!

    private var chat: ChatRecord? { model.record(chatID) }
    private var canSuggest: Bool { chat.flatMap { item in model.profiles.first { $0.id == item.profileID } }.map { model.titleSuggestionsAvailable(for: $0) } ?? false }

    init(model: WorkspaceModel, chatID: String, dismiss: @escaping () -> Void) {
        self.model = model; self.chatID = chatID; self.dismiss = dismiss
        list = ShellStack(.vertical, spacing: 4)
        headingRow = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(heading), .spacer(8), .view(spinner), .view(suggest)])
        footer = SheetFooterRow(trailing: [rename])
        column = ShellStack(.vertical, spacing: PiSpacing.md, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl),
                            [.view(field, .fill), .view(headingRow, .fill), .view(explainer, .fill), .view(list, .fill), .view(notice, .fill)])
        sheet = PiKit.Sheet("Rename chat", subtitle: model.record(chatID)?.title, symbol: "pencil",
                            content: SheetCenteredContent(column), actions: [cancel], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addSubview(sheet)
        field.field.setAccessibilityIdentifier("sessionTitle")
        field.text = chat?.title ?? ""
        field.onChange = { [weak self] _ in self?.refresh() }
        field.onSubmit = { [weak self] in self?.save() }
        // Return submits (`onSubmit`); leaving the field does not.
        field.field.cell?.sendsActionOnEndEditing = false
        rename.onPress = { [weak self] in self?.save() }
        cancel.onPress = { [weak self] in self?.dismiss() }
        sheet.dismiss = { [weak self] in self?.dismiss() }
        suggest.onPress = { [weak self] in
            guard let self else { return }
            self.requested?.cancel()
            self.requested = Task { [weak self] in await self?.askForSuggestions() }
        }
        refresh()
        if canSuggest { requested = Task { [weak self] in await self?.askForSuggestions() } }
        // A mini model chosen in Settings meanwhile makes suggestions possible.
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { requested?.cancel() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // (The field does not take the keys by itself, as the SwiftUI field did not.)
        if window == nil { requested?.cancel() }
    }
    /// Closing: the field gives up its editor, which the window would keep.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, field.field.currentEditor() != nil { window.makeFirstResponder(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refresh() {
        spinner.isHidden = !suggesting
        suggest.title = suggestions.isEmpty ? "Suggest titles" : "Suggest again"
        let enabled = inheritedEnabled
        suggest.isEnabled = !suggesting && canSuggest && enabled
        field.field.isEnabled = enabled
        for row in rows { row.isEnabled = enabled }
        suggest.toolTip = canSuggest ? "Ask the connection's mini model for three titles" : "Suggestions need a mini model for this connection; choose one in Settings."
        explainer.isHidden = !suggestions.isEmpty
        explainer.set(canSuggest ? (suggesting ? "Asking the mini model…" : "The mini model reads the first message and proposes three titles.")
                      : "Choose a mini model for this connection in Settings to get suggestions.", color: .piInkSecondary)
        list.isHidden = suggestions.isEmpty
        let title = field.text
        for (row, suggestion) in zip(rows, suggestions) { row.selected = title == suggestion }
        notice.isHidden = notice.text.isEmpty
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        rename.title = saving ? "Renaming…" : "Rename"
        rename.isEnabled = !saving && !trimmed.isEmpty && enabled
        cancel.isEnabled = !saving && enabled
        sheet.cancelDisabled = saving || !enabled
        headingRow.relayoutAll(); column.relayoutAll()
        footer.needsLayout = true
    }

    private func showSuggestions() {
        rows = suggestions.enumerated().map { index, suggestion in
            let text = ShellText(suggestion, font: PiKit.Font.body, color: .piInk, maximumLines: 2)
            let row = PiKit.SelectableRow(content: text, selected: field.text == suggestion)
            row.setAccessibilityIdentifier("title-suggestion")
            row.onPress = { [weak self] in self?.field.text = suggestion; self?.refresh() }
            return row
        }
        list.items = rows.map { .view($0, .fill) }
        // The three titles arrive one after another (`piStaggered`), fading in together (`.transition(.opacity)`).
        if window != nil {
            for (index, row) in rows.enumerated() { PiKit.appear(row, index: index) }
        }
    }

    private func askForSuggestions() async {
        guard !suggesting else { return }
        suggesting = true; notice.text = ""; refresh()
        defer { suggesting = false; refresh() }
        do {
            let found = try await model.suggestTitles(for: chatID)
            guard !Task.isCancelled else { return }
            suggestions = found
            showSuggestions()
        } catch { notice.text = error.localizedDescription }
    }

    private func save() {
        let value = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !saving else { return }
        saving = true; refresh()
        let model = self.model, chatID = self.chatID
        Task { [weak self] in
            do {
                try await model.setSessionTitle(chatID, title: value)
                self?.saving = false; self?.refresh()
                self?.dismiss()
            } catch {
                self?.notice.text = error.localizedDescription
                self?.saving = false; self?.refresh()
            }
        }
    }
}
