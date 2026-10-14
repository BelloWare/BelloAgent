import AppKit
import Combine
import GitView

/// History's list and filter controls; commit details remain owned by the
/// existing controller, including its blame pin and large-patch gate.
@MainActor final class GitHistoryBrowser: NSView {
    struct Inputs: Equatable {
        let filter: GitLogFilter
        let options: GitHistoryOptions
        let selected: GitCommit?
        let repository: GitController.RepositoryIdentity?
        let ready: Bool
        @MainActor init(_ controller: GitController, options: GitHistoryOptions) {
            filter = controller.logFilter; self.options = options
            selected = controller.selectedCommit; repository = controller.repositoryIdentity
            ready = controller.acceptsRepository(repository)
        }
    }
    private let controller: GitController
    private let state: GitHistoryState
    private let getOptions: () -> GitHistoryOptions
    private let setOptions: (GitHistoryOptions) -> Void
    private let openExact: (GitCommit) -> Void
    private let loadMore: () async -> Void
    private var historyOptions: GitHistoryOptions { get { getOptions() } set { setOptions(newValue) } }
    let message = PiKit.TextField(placeholder: "Search commit messages", icon: "magnifyingglass")
    let author = PiKit.TextField(placeholder: "Author", icon: "person")
    let refs = PiKit.Button("Refs", symbol: "arrow.triangle.branch", style: .ghost)
    let dates = PiKit.Button("Dates", symbol: "calendar", style: .ghost)
    let openHashButton = PiKit.IconButton(symbol: "number", label: "Open commit by hash", size: 30)
    let list = LazyStackView()
    let popover = PiPopoverPresenter()
    private let rule = HairlineView()
    private let note = PiKit.TextLine(PiKit.Line("Committed dates · UTC", font: PiKit.Font.micro, color: .piInkTertiary))
    private var chips: [GitHistoryFilterChip] = []
    private var inputs: Inputs?
    private var observations: [AnyCancellable] = []
    private var popupTask: Task<Void, Never>?
    private var popupID = UUID()
    private var rowIDs: [String] = []
    private var shownCommits: [GitCommit] = []
    private var shownStatusHeight: CGFloat = 66
    private var highlighted: String?
    private var navigation = UUID()
    private var pendingNavigation: UUID?
    private var previousQuery: GitHistoryQuery?
    private var reading = GitHistoryState.Reading()

    init(controller: GitController, state: GitHistoryState, options: @escaping () -> GitHistoryOptions,
         setOptions: @escaping (GitHistoryOptions) -> Void, openExact: @escaping (GitCommit) -> Void,
         loadMore: @escaping () async -> Void) {
        self.controller = controller; self.state = state
        getOptions = options; self.setOptions = setOptions; self.openExact = openExact; self.loadMore = loadMore
        super.init(frame: .zero)
        setAccessibilityElement(false); setAccessibilityLabel("Commit history")
        message.field.setAccessibilityLabel("Search commit messages literally")
        message.setAccessibilityIdentifier("git-history-filter")
        author.field.setAccessibilityLabel("Filter by author")
        author.setAccessibilityIdentifier("git-history-author")
        refs.setAccessibilityIdentifier("git-history-refs"); dates.setAccessibilityIdentifier("git-history-dates")
        openHashButton.setAccessibilityIdentifier("git-history-open-hash")
        message.onChange = { [weak self] in self?.controller.logFilter.text = $0 }
        author.onChange = { [weak self] in self?.controller.logFilter.author = $0 }
        message.onSubmit = { [weak self] in self?.focusList() }
        author.onSubmit = { [weak self] in self?.focusList() }
        refs.onPress = { [weak self] in self?.showReferences() }
        dates.onPress = { [weak self] in self?.showDates() }
        openHashButton.onPress = { [weak self] in self?.showHash() }
        list.insets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8); list.spacing = 2
        list.setAccessibilityLabel("Commits, newest first. Up and Down select; Return opens details.")
        for view in [message, author, refs, dates, openHashButton, note, rule, list] as [NSView] { addSubview(view) }
        observations.append(state.$reading.sink { [weak self] next in self?.show(next) })
        observations.append(popover.$isShown.dropFirst().sink { [weak self] shown in if !shown { self?.cancelPopupRead() } })
        apply(Inputs(controller, options: options()))
    }
    required init?(coder: NSCoder) { nil }
    deinit { popupTask?.cancel() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { popover.close(); cancelPopupRead() } }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        let before = inputs; inputs = next
        if before?.repository != next.repository { popover.close(); cancelPopupRead(); highlighted = nil; navigation = UUID(); pendingNavigation = nil }
        message.text = next.filter.text; author.text = next.filter.author
        message.field.isEnabled = next.ready; author.field.isEnabled = next.ready
        refs.isEnabled = next.ready; dates.isEnabled = next.ready; openHashButton.isEnabled = next.ready
        if next.selected?.hash != before?.selected?.hash { highlighted = next.selected?.hash; navigation = UUID(); pendingNavigation = nil }
        if before?.filter != next.filter || before?.options != next.options { rebuildChips(next) }
        show(reading)
    }

    private func rebuildChips(_ next: Inputs) {
        chips.forEach { $0.removeFromSuperview() }; chips = []
        func add(_ text: String, action: @escaping () -> Void) {
            let chip = GitHistoryFilterChip(text, remove: action); chips.append(chip); addSubview(chip)
        }
        if !next.filter.text.isEmpty { add("Message: " + next.filter.text) { [weak self] in self?.controller.logFilter.text = "" } }
        if !next.filter.author.isEmpty { add("Author: " + next.filter.author) { [weak self] in self?.controller.logFilter.author = "" } }
        if let path = next.filter.path {
            add("File: " + path + " · follows renames") { [weak self] in self?.controller.clearFileHistory() }
            chips.last?.setAccessibilityIdentifier("git-history-path")
            chips.last?.remove.setAccessibilityIdentifier("git-history-all-files")
        }
        if let ref = next.options.reference { add(ref) { [weak self] in self?.historyOptions.reference = nil } }
        else if next.filter.allBranches { add("All branches") { [weak self] in self?.controller.logFilter.allBranches = false } }
        if !next.options.dates.from.isEmpty { add("Committed from " + next.options.dates.from + " UTC") { [weak self] in
            guard let self else { return }; historyOptions.dates = .init(through: historyOptions.dates.through)
        } }
        if !next.options.dates.through.isEmpty { add("Committed through " + next.options.dates.through + " UTC") { [weak self] in
            guard let self else { return }; historyOptions.dates = .init(from: historyOptions.dates.from)
        } }
        needsLayout = true; PiKit.sizeChanged(self)
    }

    private func show(_ next: GitHistoryState.Reading) {
        reading = next
        let repository = inputs?.repository
        // Hiding disables actions, but keeps this repository's scroll document.
        // Dropping its rows while suspended would clamp the reader to the top.
        let ownsReading = repository != nil && next.snapshot?.root == repository?.root
        let commits = ownsReading ? next.commits : [], ids = commits.map(\.hash)
        let changedQuery = previousQuery != next.query
        previousQuery = next.query
        if changedQuery { highlighted = inputs?.selected?.hash; navigation = UUID(); pendingNavigation = nil; list.scrollToTop() }
        if let selected = inputs?.selected, !next.loading, !ids.contains(selected.hash) {
            note.line.text = "Opened \(selected.shortHash) outside these filters · committed UTC"
        } else { note.line.text = "Committed dates · UTC" }
        note.toolTip = note.line.text
        let empty = commits.isEmpty
        let tail = next.loading || next.paging || next.next != nil || !next.notice.isEmpty
        let count = empty ? 1 : commits.count + (tail ? 1 : 0)
        let statusHeight: CGFloat = !next.notice.isEmpty && next.next != nil ? 112 : 66
        let highlighted = highlighted
        let source = LazyStackView.Source(count: count, key: { index in
            index < commits.count ? AnyHashable(commits[index].hash) : AnyHashable("history-state")
        }, height: { index, _ in index < commits.count ? GitHistoryRow.height(commits[index]) : statusHeight }, view: { [weak self] index, existing in
            guard let self else { return existing ?? NSView() }
            if index < commits.count {
                let commit = commits[index], row = existing as? GitHistoryRow ?? GitHistoryRow()
                row.show(commit, selected: highlighted == commit.hash) { [weak self] in self?.open(commit, repository: repository) }
                row.onKey = { [weak self] in self?.keyDown(with: $0) }
                return row
            }
            let row = existing as? GitHistoryStatusRow ?? GitHistoryStatusRow()
            let text = !next.notice.isEmpty ? next.notice : next.loading || !ownsReading ? "Loading history…" : next.paging ? "Loading older commits…" : empty ?
                (next.query == GitHistoryQuery() ? "No commits yet." : "No commits match these filters.") : ""
            row.show(text, more: next.next != nil && !next.paging && !next.loading) { [weak self] in
                guard let self else { return }; Task { await self.loadMore() }
            }
            return row
        })
        if rowIDs == ids && shownCommits == commits && shownStatusHeight == statusHeight && !changedQuery { list.update(source) } else { rowIDs = ids; list.reload(source) }
        shownCommits = commits; shownStatusHeight = statusHeight
        RedrawCounter.note("GitHistoryList")
    }

    private func open(_ commit: GitCommit, repository: GitController.RepositoryIdentity?) {
        guard controller.acceptsRepository(repository) else { return }
        navigation = UUID(); pendingNavigation = nil
        highlighted = commit.hash; controller.selectedCommit = commit; show(reading)
        focusHighlighted()
    }
    func focusList() {
        if let index = reading.commits.firstIndex(where: { $0.hash == highlighted }) { highlight(index) }
        else { moveSelection(1) }
    }
    func moveSelection(_ direction: Int) {
        let repository = inputs?.repository
        guard controller.acceptsRepository(repository), reading.snapshot?.root == repository?.root else { return }
        let commits = reading.commits
        guard !commits.isEmpty else { return }
        let current = commits.firstIndex { $0.hash == highlighted }
        let next = current.map { $0 + direction } ?? (direction > 0 ? 0 : commits.count - 1)
        if next >= commits.count, reading.next != nil {
            guard pendingNavigation == nil, !reading.paging else { return }
            let token = UUID(); navigation = token; pendingNavigation = token
            let snapshot = reading.snapshot?.id
            Task { [weak self] in
                guard let self else { return }
                defer { if pendingNavigation == token { pendingNavigation = nil } }
                await loadMore()
                guard navigation == token, controller.acceptsRepository(repository), reading.snapshot?.id == snapshot, next < reading.commits.count else { return }
                guard !isHiddenOrHasHiddenAncestor, let focused = window?.firstResponder as? GitHistoryRow,
                      focused.isDescendant(of: self) else { return }
                highlight(next)
            }
        } else if commits.indices.contains(next) { navigation = UUID(); pendingNavigation = nil; highlight(next) }
    }
    private func highlight(_ index: Int) {
        highlighted = reading.commits[index].hash; show(reading); list.scrollToRow(index)
        focusHighlighted()
    }
    private func focusHighlighted() {
        guard let highlighted, let row = list.madeView(for: highlighted) as? GitHistoryRow else { return }
        window?.makeFirstResponder(row)
        NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
    }
    override func moveUp(_ sender: Any?) { moveSelection(-1) }
    override func moveDown(_ sender: Any?) { moveSelection(1) }
    override func insertNewline(_ sender: Any?) { if let commit = reading.commits.first(where: { $0.hash == highlighted }) { open(commit, repository: inputs?.repository) } }
    override func cancelOperation(_ sender: Any?) { popover.close() }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 125: moveDown(nil)
        case 126: moveUp(nil)
        case 36, 76: insertNewline(nil)
        case 53: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }

    private var fieldHeight: CGFloat { message.intrinsicContentSize.height }
    private func chipFrames(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0
        for chip in chips {
            let size = CGSize(width: min(max(0, width), chip.intrinsicContentSize.width), height: 26)
            if x > 0, x + size.width > width { x = 0; y += 31 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size)); x += size.width + 5
        }
        return (frames, chips.isEmpty ? 0 : y + 26)
    }
    func fixedHeight(forWidth width: CGFloat) -> CGFloat {
        16 + fieldHeight * 2 + 6 + 20 + (chips.isEmpty ? 0 : chipFrames(width: max(0, width - 16)).height + 6) + 1
    }
    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 16), field = fieldHeight
        message.frame = CGRect(x: 8, y: 8, width: max(0, inner - 36), height: field)
        openHashButton.frame = CGRect(x: max(8, bounds.width - 38), y: 8, width: 30, height: field)
        let y = 8 + field + 6, rw = refs.intrinsicContentSize.width, dw = dates.intrinsicContentSize.width
        author.frame = CGRect(x: 8, y: y, width: max(0, inner - rw - dw - 8), height: field)
        refs.frame = CGRect(x: author.frame.maxX + 4, y: y, width: rw, height: field)
        dates.frame = CGRect(x: refs.frame.maxX + 4, y: y, width: dw, height: field)
        var bottom = y + field + 6
        let layout = chipFrames(width: inner)
        for (chip, frame) in zip(chips, layout.frames) { chip.frame = frame.offsetBy(dx: 8, dy: bottom) }
        if !chips.isEmpty { bottom += layout.height + 6 }
        note.frame = CGRect(x: 8, y: bottom, width: inner, height: 14); bottom += 16
        rule.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: 1)
        list.frame = CGRect(x: 0, y: bottom + 1, width: bounds.width, height: max(0, bounds.height - bottom - 1))
    }

    private func cancelPopupRead() { popupID = UUID(); popupTask?.cancel(); popupTask = nil }
    func showReferences() {
        if popover.isShown { popover.close(); return }
        guard let repository = controller.repositoryIdentity, controller.acceptsRepository(repository) else { return }
        let picker = GitHistoryRefPicker()
        picker.close = { [weak self] in self?.popover.close() }
        picker.choose = { [weak self] scope in
            guard let self, controller.acceptsRepository(repository) else { return }
            popover.close()
            switch scope {
            case .current: historyOptions.reference = nil; controller.logFilter.allBranches = false
            case .all: historyOptions.reference = nil; controller.logFilter.allBranches = true
            case .reference(let ref): historyOptions.reference = ref
            }
        }
        popover.toggle(from: refs, width: 340, maximumHeight: 440, animates: false) { picker }
        picker.window?.makeFirstResponder(picker.search.field)
        let token = UUID(); popupID = token
        popupTask = Task { [weak self, weak picker] in
            do {
                let values = try await GitService.shared.historyReferences(in: repository.root)
                guard let self, !Task.isCancelled, popupID == token, controller.acceptsRepository(repository) else { return }
                picker?.show(values)
            } catch {
                guard let self, !Task.isCancelled, popupID == token else { return }; picker?.showError(error.localizedDescription)
            }
        }
    }
    func showDates() {
        if popover.isShown { popover.close(); return }
        let repository = controller.repositoryIdentity
        let editor = GitHistoryDateEditor(historyOptions.dates)
        editor.close = { [weak self] in self?.popover.close() }
        editor.apply = { [weak self] dates in
            guard let self, controller.acceptsRepository(repository) else { return }
            historyOptions.dates = dates; popover.close()
        }
        popover.toggle(from: dates, width: 310, maximumHeight: 280, animates: false) { editor }
        editor.window?.makeFirstResponder(editor.from.field)
    }
    func showHash() {
        if popover.isShown { popover.close(); return }
        guard let repository = controller.repositoryIdentity, controller.acceptsRepository(repository) else { return }
        let editor = GitHistoryHashEditor()
        editor.close = { [weak self] in self?.popover.close() }
        editor.field.onChange = { [weak self] _ in self?.cancelPopupRead() }
        editor.open = { [weak self, weak editor] hash in
            guard let self else { return }; cancelPopupRead()
            let token = popupID
            popupTask = Task { [weak self, weak editor] in
                do {
                    let commit = try await GitService.shared.historyCommit(hash, in: repository.root)
                    guard let self, !Task.isCancelled, popupID == token, controller.acceptsRepository(repository) else { return }
                    openExact(commit); popover.close()
                } catch {
                    guard let self, !Task.isCancelled, popupID == token else { return }; editor?.showError(error.localizedDescription)
                }
            }
        }
        popover.toggle(from: openHashButton, width: 340, maximumHeight: 230, animates: false) { editor }
        editor.window?.makeFirstResponder(editor.field.field)
    }
}

@MainActor final class GitHistoryStatusRow: NSView {
    private let text = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 3)
    private let more = PiKit.Button("Load older commits", style: .ghost)
    override init(frame: NSRect) { super.init(frame: frame); addSubview(text); addSubview(more) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func show(_ value: String, more: Bool, action: @escaping () -> Void) {
        text.text = value; text.toolTip = value; text.isHidden = value.isEmpty; self.more.isHidden = !more; self.more.onPress = action; needsLayout = true
    }
    override func layout() {
        super.layout()
        let buttonSize = more.intrinsicContentSize
        let textHeight = max(0, bounds.height - (more.isHidden ? 16 : buttonSize.height + 24))
        text.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: textHeight)
        more.frame = CGRect(origin: CGPoint(x: 8, y: text.isHidden ? 8 : text.frame.maxY + 8), size: buttonSize)
    }
}

@MainActor final class GitHistoryRefPicker: NSView, PiKit.WidthSizing, NSTextFieldDelegate {
    let search = PiKit.TextField(placeholder: "Find a branch or tag", icon: "magnifyingglass")
    private let list = LazyStackView()
    private let status = PiKit.TextLine(PiKit.Line("Loading refs…", font: PiKit.Font.caption, color: .piInkSecondary))
    private var refs: [GitHistoryRef] = []
    private var entries: [(String, GitHistoryQuery.Scope)] = []
    private var selection = 0
    var choose: ((GitHistoryQuery.Scope) -> Void)?
    var close: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [search, list, status] as [NSView] { addSubview(view) }
        search.field.setAccessibilityLabel("Find a branch or tag")
        search.field.delegate = self
        search.onChange = { [weak self] _ in self?.update() }; search.onCancel = { [weak self] in self?.close?() }
        search.onSubmit = { [weak self] in self?.activate() }
        update()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { 400 }
    func show(_ refs: [GitHistoryRef]) { self.refs = refs; status.line.text = "Branches and tags in this repository"; update(preservingSelection: true) }
    func showError(_ error: String) { status.line.text = error; status.toolTip = error }
    private func update(preservingSelection: Bool = false) {
        let selected = preservingSelection && entries.indices.contains(selection) ? entries[selection].1 : nil
        let query = search.text
        entries = [("Current branch", .current), ("All branches", .all)].filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }
        entries += refs.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map { ($0.kind + ": " + $0.title, .reference($0.name)) }
        selection = selected.flatMap { scope in entries.firstIndex { $0.1 == scope } } ?? 0
        render(); list.scrollToRow(selection)
    }
    private func render() {
        let entries = entries, selection = selection
        list.reload(.init(count: entries.count, key: { entries[$0].0 }, height: { _, _ in 34 }, view: { [weak self] index, _ in
            let label = PiKit.TextLine(PiKit.Line(entries[index].0, font: PiKit.Font.body, color: .piInk)); label.truncation = .middle
            let row = PiKit.SelectableRow(content: label, selected: selection == index) { [weak self] in self?.choose?(entries[index].1) }
            row.toolTip = entries[index].0; return row
        }))
    }
    private func activate() { if entries.indices.contains(selection) { choose?(entries[selection].1) } }
    func controlTextDidChange(_ notification: Notification) { search.controlTextDidChange(notification) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selection = max(0, min(entries.count - 1, selection + delta)); render(); list.scrollToRow(selection)
            if entries.indices.contains(selection), let row = list.madeView(for: entries[selection].0) {
                NSAccessibility.post(element: row, notification: .selectedChildrenChanged)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): close?(); return true
        default: return search.control(control, textView: textView, doCommandBy: command)
        }
    }
    override func cancelOperation(_ sender: Any?) { close?() }
    override func layout() {
        super.layout()
        search.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: search.intrinsicContentSize.height)
        status.frame = CGRect(x: 12, y: search.frame.maxY + 8, width: max(0, bounds.width - 24), height: 16)
        list.frame = CGRect(x: 4, y: status.frame.maxY + 8, width: max(0, bounds.width - 8), height: max(0, bounds.height - status.frame.maxY - 12))
    }
}

@MainActor final class GitHistoryDateEditor: NSView, PiKit.WidthSizing {
    let from = PiKit.TextField(placeholder: "From · YYYY-MM-DD")
    let through = PiKit.TextField(placeholder: "Through · YYYY-MM-DD")
    private let title = PiKit.TextLine(PiKit.Line("Committed dates · UTC · inclusive", font: PiKit.Font.caption, color: .piInkSecondary))
    private let error = TextBlock("", font: PiKit.Font.caption, color: .piDanger, maximumLines: 2)
    let button = PiKit.Button("Apply dates", style: .primary)
    var apply: ((GitHistoryDates) -> Void)?
    var close: (() -> Void)?
    init(_ dates: GitHistoryDates) {
        super.init(frame: .zero)
        from.text = dates.from; through.text = dates.through
        from.field.setAccessibilityLabel("Committed from, YYYY-MM-DD, UTC")
        through.field.setAccessibilityLabel("Committed through, YYYY-MM-DD, UTC, inclusive")
        for view in [title, from, through, error, button] as [NSView] { addSubview(view) }
        from.onCancel = { [weak self] in self?.close?() }; through.onCancel = from.onCancel
        button.onPress = { [weak self] in self?.submit() }; through.onSubmit = button.onPress
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { 222 }
    func submit() {
        let dates = GitHistoryDates(from: from.text, through: through.text)
        do { _ = try dates.bounds(); apply?(dates) } catch { self.error.text = error.localizedDescription; needsLayout = true }
    }
    override func cancelOperation(_ sender: Any?) { close?() }
    override func layout() {
        super.layout(); let width = max(0, bounds.width - 24), h = from.intrinsicContentSize.height
        title.frame = CGRect(x: 12, y: 12, width: width, height: 18)
        from.frame = CGRect(x: 12, y: 38, width: width, height: h)
        through.frame = CGRect(x: 12, y: from.frame.maxY + 8, width: width, height: h)
        error.frame = CGRect(x: 12, y: through.frame.maxY + 8, width: width, height: 34)
        button.frame = CGRect(origin: CGPoint(x: 12, y: error.frame.maxY + 6), size: button.intrinsicContentSize)
    }
}

@MainActor final class GitHistoryHashEditor: NSView, PiKit.WidthSizing {
    let field = PiKit.TextField(placeholder: "Commit hash", mono: true)
    private let note = TextBlock("Open this exact commit. Your history filters stay in place.", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
    private let error = TextBlock("", font: PiKit.Font.caption, color: .piDanger, maximumLines: 2)
    let button = PiKit.Button("Open commit", style: .primary)
    var open: ((String) -> Void)?
    var close: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        field.field.setAccessibilityLabel("Commit hash, at least four hexadecimal characters")
        for view in [field, note, error, button] as [NSView] { addSubview(view) }
        field.onCancel = { [weak self] in self?.close?() }
        button.onPress = { [weak self] in guard let self else { return }; open?(field.text) }; field.onSubmit = button.onPress
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { 194 }
    func showError(_ value: String) { error.text = value }
    override func cancelOperation(_ sender: Any?) { close?() }
    override func layout() {
        super.layout(); let width = max(0, bounds.width - 24)
        field.frame = CGRect(x: 12, y: 12, width: width, height: field.intrinsicContentSize.height)
        note.frame = CGRect(x: 12, y: field.frame.maxY + 8, width: width, height: 32)
        error.frame = CGRect(x: 12, y: note.frame.maxY + 6, width: width, height: 32)
        button.frame = CGRect(origin: CGPoint(x: 12, y: error.frame.maxY + 8), size: button.intrinsicContentSize)
    }
}
