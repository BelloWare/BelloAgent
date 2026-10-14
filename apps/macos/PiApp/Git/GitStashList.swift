import AppKit
import GitView

/// One selected stash and one selected file own the entire preview cache.
/// Metadata arrives first. Every superseded read is cancelled and retired.
@MainActor final class GitStashList: NSView {
    enum Action { case apply, pop, drop }
    let list = LazyStackView(), filesList = LazyStackView()
    let diff = DiffView()
    let apply = PiKit.Button("Apply", style: .secondary, compact: true)
    let pop = PiKit.Button("Pop", style: .secondary, compact: true)
    let drop = PiKit.Button("Drop…", style: .ghostDanger, compact: true)
    let note = TextBlock("Reading stashes…", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 4)
    let fileHeading = PiKit.TextLine(PiKit.Line("Select a stash", font: PiKit.Font.caption, color: .piInkSecondary))
    private let rule = HairlineView()
    private let service: GitService, root: String
    private let valid: () -> Bool
    var action: ((Action, GitStashRecord) -> Void)?
    private(set) var records: [GitStashRecord] = []
    private(set) var selected: GitStashRecord?
    private(set) var files: [GitStashFile] = []
    private(set) var selectedFile: GitStashFile?
    private(set) var preview: [GitDiffFile] = []
    private var listing: Task<Void, Never>?, reading: Task<Void, Never>?
    private var listToken = UUID(), readToken = UUID()
    private var split = false
    private var expanded: String?
    var busy = false { didSet { updateActions() } }
    init(service: GitService, root: String, valid: @escaping () -> Bool) {
        self.service = service; self.root = root; self.valid = valid
        super.init(frame: .zero)
        for stack in [list, filesList] { stack.insets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10); stack.spacing = 3 }
        list.setAccessibilityLabel("Stashes. Message, branch and age. Use Up and Down to select.")
        filesList.setAccessibilityLabel("Files in the selected stash, read only")
        apply.onPress = { [weak self] in self?.activate(.apply) }; pop.onPress = { [weak self] in self?.activate(.pop) }; drop.onPress = { [weak self] in self?.activate(.drop) }
        apply.toolTip = "Apply and keep the stash"; pop.toolTip = "Apply, then remove this stash only if application succeeds"
        for view in [list, filesList, diff, apply, pop, drop, note, fileHeading, rule] as [NSView] { addSubview(view) }
        updateActions(); reload()
    }
    required init?(coder: NSCoder) { nil }
    deinit { listing?.cancel(); reading?.cancel() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var wasAttached = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wasAttached = true } else if wasAttached { cancel() }
    }
    func cancel() { listToken = UUID(); readToken = UUID(); listing?.cancel(); reading?.cancel(); listing = nil; reading = nil }
    func setNotice(_ message: String) { note.text = message; note.toolTip = message; needsLayout = true }
    private func updateActions() { for button in [apply, pop, drop] { button.isEnabled = selected != nil && !busy && valid() } }
    private func activate(_ action: Action) { if let selected, !busy, valid() { self.action?(action, selected) } }
    func reload(keepingNotice: Bool = false) {
        listing?.cancel(); listToken = UUID(); let token = listToken
        if !keepingNotice { setNotice("Reading stashes…") }
        listing = Task { [weak self, service, root] in
            do {
                let rows = try await service.stashRecords(in: root)
                guard let self, !Task.isCancelled, token == listToken, valid() else { return }
                let old = selected; records = rows
                if !keepingNotice { setNotice(rows.isEmpty ? "No stashes in this repository." : "") }
                select(rows.first { $0 == old } ?? rows.first); renderList(); listing = nil
            } catch {
                guard let self, !Task.isCancelled, token == listToken, valid() else { return }
                setNotice(error.localizedDescription); listing = nil
            }
        }
    }
    func select(_ stash: GitStashRecord?) {
        selected = stash; selectedFile = nil; files = []; preview = []; expanded = nil
        readToken = UUID(); reading?.cancel(); let token = readToken
        updateActions(); renderList(); renderFiles(); showDiff(loading: stash != nil)
        guard let stash, valid() else { return }
        fileHeading.line.text = "Reading changed files…"
        reading = Task { [weak self, service, root] in
            do {
                let files = try await service.stashFiles(stash, in: root)
                guard let self, !Task.isCancelled, token == readToken, valid() else { return }
                self.files = files; fileHeading.line.text = "\(Set(files.map(\.path)).count) changed files · read only"
                renderFiles(); selectFile(files.first)
            } catch {
                guard let self, !Task.isCancelled, token == readToken, valid() else { return }
                setNotice(error.localizedDescription); showDiff(loading: false)
            }
        }
    }
    func selectFile(_ file: GitStashFile?) {
        reading?.cancel(); readToken = UUID(); let token = readToken
        selectedFile = file; preview = []; expanded = nil; renderFiles(); showDiff(loading: file != nil)
        guard let stash = selected, let file, valid() else { return }
        reading = Task { [weak self, service, root] in
            do {
                let preview = try await service.stashDiff(stash, file: file, in: root)
                guard let self, !Task.isCancelled, token == readToken, valid() else { return }
                self.preview = preview; showDiff(loading: false); reading = nil
            } catch {
                guard let self, !Task.isCancelled, token == readToken, valid() else { return }
                setNotice(error.localizedDescription); showDiff(loading: false); reading = nil
            }
        }
    }
    private func showDiff(loading: Bool = false) {
        let identity = (selected?.oid ?? "empty") + ":" + (selectedFile?.id ?? "")
        diff.show(files: preview, title: selectedFile?.path, subtitle: selectedFile.map { $0.untracked ? "Untracked file saved in stash · read only" : $0.staged ? "Saved index versus base · read only" : "Saved working tree versus base · read only" }, identity: identity, loading: loading,
                  split: split, setSplit: { [weak self] value in self?.split = value; self?.showDiff() }, expanded: expanded,
                  setExpanded: { [weak self] value in self?.expanded = value; self?.showDiff() })
    }
    private func renderList() {
        let records = records
        list.reload(.init(count: records.count, key: { records[$0].id }, height: { _, _ in 68 }, view: { [weak self] index, existing in
            let record = records[index], row = (existing as? GitStashRow) ?? GitStashRow()
            row.show(record, selected: self?.selected?.id == record.id)
            row.row.onPress = { [weak self] in self?.select(record) }
            return row
        }))
    }
    private func renderFiles() {
        let files = files
        filesList.reload(.init(count: files.count, key: { files[$0].id }, height: { _, _ in 30 }, view: { [weak self] index, _ in
            let file = files[index]
            let label = PiKit.TextLine(PiKit.Line(file.status + "  " + file.path + (file.staged ? " · index" : ""), font: PiKit.Font.mono, color: .piInk))
            label.truncation = .middle
            let row = PiKit.SelectableRow(content: label, selected: self?.selectedFile == file)
            row.setAccessibilityLabel(file.path + (file.untracked ? ", untracked file in stash" : file.staged ? ", staged file in stash" : ", working file in stash"))
            row.toolTip = file.path; row.onPress = { [weak self] in self?.selectFile(file) }; return row
        }))
    }
    override func keyDown(with event: NSEvent) {
        guard [125, 126].contains(event.keyCode), !records.isEmpty else { super.keyDown(with: event); return }
        let index = records.firstIndex { $0.id == selected?.id } ?? 0
        let next = min(max(index + (event.keyCode == 125 ? 1 : -1), 0), records.count - 1)
        select(records[next]); list.scrollToRow(next)
    }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let noticeHeight = note.text.isEmpty ? 0 : min(72, note.height(forWidth: max(1, w - 32))) + 8
        let footer = 48 + noticeHeight, contentHeight = max(0, h - footer)
        let wide = w >= 700, listWidth = wide ? min(280, w * 0.33) : w
        list.frame = CGRect(x: 0, y: 0, width: listWidth, height: wide ? contentHeight : min(140, contentHeight * 0.30))
        let x: CGFloat = wide ? listWidth + 1 : 0, y: CGFloat = wide ? 0 : list.frame.maxY + 1
        let room = max(0, w - x), bodyHeight = max(0, contentHeight - y)
        rule.frame = wide ? CGRect(x: listWidth, y: 0, width: 1, height: contentHeight) : CGRect(x: 0, y: list.frame.maxY, width: w, height: 1)
        fileHeading.frame = CGRect(x: x + 12, y: y + 8, width: max(0, room - 24), height: 18)
        let filesHeight = min(96, bodyHeight * 0.24)
        filesList.frame = CGRect(x: x, y: y + 30, width: room, height: filesHeight)
        diff.frame = CGRect(x: x, y: filesList.frame.maxY, width: room, height: max(0, contentHeight - filesList.frame.maxY))
        note.frame = CGRect(x: 16, y: contentHeight + 4, width: max(0, w - 32), height: max(0, noticeHeight - 8))
        var bx: CGFloat = 16
        for button in [apply, pop, drop] { let width = button.fittingSize.width; button.frame = CGRect(x: bx, y: h - 36, width: width, height: 28); bx += width + 8 }
    }
}

@MainActor private final class GitStashRow: NSView {
    private let content = GitStashRowContent()
    let row: PiKit.SelectableRow
    init() { row = PiKit.SelectableRow(content: content); super.init(frame: .zero); addSubview(row) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }
    func show(_ stash: GitStashRecord, selected: Bool) { content.show(stash); row.selected = selected; row.setAccessibilityLabel(content.spoken); row.toolTip = content.spoken }
}
@MainActor private final class GitStashRowContent: NSView {
    private let title = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.body, color: .piInk))
    private let branch = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private let age = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    var spoken: String { [title.line.text, branch.line.text, age.line.text].joined(separator: ", ") }
    override init(frame: NSRect) { super.init(frame: frame); for view in [title, branch, age] { view.truncation = .middle; addSubview(view) } }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func show(_ stash: GitStashRecord) {
        title.line.text = stash.message; branch.line.text = stash.selector + " · " + stash.branch
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        age.line.text = formatter.localizedString(for: stash.date, relativeTo: Date())
    }
    override func layout() {
        super.layout()
        title.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
        branch.frame = CGRect(x: 0, y: 21, width: bounds.width, height: 15)
        age.frame = CGRect(x: 0, y: 38, width: bounds.width, height: 14)
    }
}
