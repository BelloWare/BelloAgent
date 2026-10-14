import AppKit
import GitView

@MainActor final class GitBranchesPopover: NSView, PiKit.WidthSizing, NSTextFieldDelegate {
    enum Action { case checkout, newBranch, rename, delete, compare, history }
    let search = PiKit.TextField(placeholder: "Search branches", icon: "magnifyingglass")
    let list = LazyStackView()
    let note = TextBlock("Reading branches…", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 4)
    let recovery = PiKit.Button("Stash and Checkout", style: .secondary, compact: true)
    let newBranch = PiKit.Button("New Branch…", symbol: "plus", style: .ghost, compact: true)
    private let surface = FillView(.piContent)
    var action: ((Action, GitBranchReference) -> Void)?
    var cancel: (() -> Void)?
    var createFromHead: (() -> Void)?
    private(set) var catalog: GitBranchCatalog?
    private(set) var visibleBranches: [GitBranchReference] = []
    private(set) var selectedRef: String?
    private var rows: [Row] = []
    private enum Row { case heading(String), branch(GitBranchReference) }
    var busy = false { didSet { newBranch.isEnabled = !busy; recovery.isEnabled = !busy } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(surface)
        search.field.delegate = self
        search.field.setAccessibilityLabel("Search local and remote branches")
        search.setAccessibilityIdentifier("git-branches-search")
        list.setAccessibilityLabel("Branches. Up and Down select a branch. Return opens its actions.")
        list.insets = NSEdgeInsets(top: 3, left: 8, bottom: 8, right: 8); list.spacing = 2
        recovery.isHidden = true; recovery.setAccessibilityIdentifier("git-stash-and-checkout")
        newBranch.onPress = { [weak self] in self?.createFromHead?() }
        for view in [search, list, note, recovery, newBranch] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { 460 }
    func show(_ catalog: GitBranchCatalog) { self.catalog = catalog; setNotice(""); filter(search.text) }
    func setNotice(_ message: String) { note.text = message; note.toolTip = message; needsLayout = true }
    func offerRecovery(_ message: String, action: @escaping () -> Void) { setNotice(message); recovery.isHidden = false; recovery.onPress = action }
    func filter(_ query: String) {
        guard let catalog else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = catalog.branches.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        rows = []
        func section(_ title: String, _ branches: [GitBranchReference]) {
            guard !branches.isEmpty else { return }; rows.append(.heading(title)); rows += branches.map(Row.branch)
        }
        section("Recent", catalog.recent.compactMap { ref in matches.first { $0.ref == ref } })
        section("Local", matches.filter { $0.remote == nil })
        for remote in Set(matches.compactMap(\.remote)).sorted() { section("Remote · " + remote, matches.filter { $0.remote == remote }) }
        var seen: Set<String> = []
        visibleBranches = rows.compactMap { if case .branch(let branch) = $0, seen.insert(branch.ref).inserted { return branch }; return nil }
        if !visibleBranches.contains(where: { $0.ref == selectedRef }) { selectedRef = visibleBranches.first?.ref }
        if matches.isEmpty { setNotice("No matching branches.") } else if note.text == "No matching branches." { setNotice("") }
        render(); list.scrollToTop()
    }
    private func render() {
        let rows = rows
        list.reload(.init(count: rows.count, key: { index in
            switch rows[index] { case .heading(let text): return "section:" + text; case .branch(let branch): return "\(index):" + branch.ref }
        }, height: { index, _ in if case .heading = rows[index] { return 27 }; return 36 }, view: { [weak self] index, existing in
            switch rows[index] {
            case .heading(let title):
                let label = (existing as? PiKit.TextLine) ?? PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.micro, color: .piInkTertiary))
                label.line.text = title; return label
            case .branch(let branch):
                let row = (existing as? GitBranchPopupRow) ?? GitBranchPopupRow()
                row.show(branch, selected: self?.selectedRef == branch.ref)
                row.row.onPress = { [weak self, weak row] in
                    guard let self, let row, !self.busy else { return }
                    self.selectedRef = branch.ref; self.render(); self.openActions(branch, from: row)
                }
                return row
            }
        }))
    }
    private func openActions(_ branch: GitBranchReference, from anchor: NSView) {
        guard !busy else { return }
        let callback = action
        var entries: [PiMenuEntry] = [
            .button(branch.remote == nil ? "Checkout" : "Checkout as New Tracking Branch…", enabled: !branch.current) { callback?(.checkout, branch) },
            .button("New Branch from \(branch.name)…") { callback?(.newBranch, branch) },
            .button("Compare with Current", enabled: !branch.current && catalog?.head.isUnborn == false) { callback?(.compare, branch) },
            .button("Show in History") { callback?(.history, branch) }
        ]
        if branch.remote == nil {
            entries += [.divider, .button("Rename…") { callback?(.rename, branch) },
                        .button("Delete…", enabled: !branch.current && catalog?.head.isUnborn == false) { callback?(.delete, branch) }]
        }
        PiMenus.popUp(entries, below: anchor)
    }
    func move(_ delta: Int) {
        guard !visibleBranches.isEmpty else { return }
        let index = visibleBranches.firstIndex { $0.ref == selectedRef } ?? 0
        selectedRef = visibleBranches[min(max(index + delta, 0), visibleBranches.count - 1)].ref
        render()
        if let row = rows.firstIndex(where: { if case .branch(let branch) = $0 { return branch.ref == selectedRef }; return false }) { list.scrollToRow(row) }
    }
    func activateSelection() {
        guard let branch = visibleBranches.first(where: { $0.ref == selectedRef }) else { return }
        openActions(branch, from: search)
    }
    func controlTextDidChange(_ obj: Notification) { filter(search.text) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): cancel?()
        default: return false
        }; return true
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode { case 125: move(1); case 126: move(-1); case 36, 76: activateSelection(); case 53: cancel?(); default: super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { cancel?() }
    override func layout() {
        super.layout()
        surface.frame = bounds
        let width = max(0, bounds.width - 24)
        search.frame = CGRect(x: 12, y: 12, width: width, height: 34)
        let noteHeight = note.text.isEmpty ? 0 : min(74, note.height(forWidth: width))
        let footer: CGFloat = 46 + noteHeight + (recovery.isHidden ? 0 : 34)
        list.frame = CGRect(x: 4, y: 52, width: max(0, bounds.width - 8), height: max(0, bounds.height - 52 - footer))
        var y = list.frame.maxY + 4
        note.frame = CGRect(x: 12, y: y, width: width, height: noteHeight); y += noteHeight
        if !recovery.isHidden { recovery.frame = CGRect(x: 12, y: y + 3, width: min(width, recovery.fittingSize.width), height: 28); y += 34 }
        newBranch.frame = CGRect(x: 12, y: y + 5, width: min(width, newBranch.fittingSize.width), height: 28)
    }
}

@MainActor private final class GitBranchPopupRow: NSView {
    private let label = LabelView(PiKit.Line("", font: PiKit.Font.body, color: .piInk), symbol: "arrow.triangle.branch")
    let row: PiKit.SelectableRow
    init() { row = PiKit.SelectableRow(content: label); super.init(frame: .zero); addSubview(row) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }
    func show(_ branch: GitBranchReference, selected: Bool) {
        label.line.text = (branch.current ? "✓ " : "") + branch.name
        row.selected = selected; row.toolTip = branch.ref
        row.setAccessibilityLabel(branch.name + (branch.current ? ", current branch" : "") + (branch.remote.map { ", remote " + $0 } ?? ", local branch"))
        row.setAccessibilityIdentifier("git-branch-" + branch.ref)
    }
}
