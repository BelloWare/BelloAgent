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
        }, height: { index, _ in if case .heading = rows[index] { return index == 0 ? 25 : 31 }; return 36 }, view: { [weak self] index, existing in
            switch rows[index] {
            case .heading(let title):
                let header = (existing as? GitBranchSectionHeader) ?? GitBranchSectionHeader()
                header.show(title, first: index == 0); return header
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
    private let content = GitBranchRowContent()
    let row: PiKit.SelectableRow
    init() { row = PiKit.SelectableRow(content: content); super.init(frame: .zero); addSubview(row) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }
    func show(_ branch: GitBranchReference, selected: Bool) {
        content.show(branch)
        row.selected = selected; row.toolTip = ([branch.ref, content.trackingDescription].filter { !$0.isEmpty }).joined(separator: "\n")
        row.setAccessibilityLabel(branch.name + (branch.remote.map { ", remote " + $0 } ?? ", local branch"))
        row.setAccessibilityValue(([branch.current ? "Current" : "", content.trackingDescription].filter { !$0.isEmpty }).joined(separator: ". "))
        row.setAccessibilityIdentifier("git-branch-" + branch.ref)
    }
}

/// Quick Open's micro uppercase heading, with extra room between sections.
@MainActor private final class GitBranchSectionHeader: NSView {
    private let text = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
    private var first = false
    init() { super.init(frame: .zero); addSubview(text); text.setAccessibilityIdentifier("git-branches-section") }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func show(_ title: String, first: Bool) { text.line.text = title; self.first = first; needsLayout = true }
    override func layout() {
        super.layout()
        text.frame = CGRect(x: 14, y: first ? 8 : 14, width: max(0, bounds.width - 28), height: text.intrinsicContentSize.height)
    }
}

@MainActor private final class GitBranchRowContent: NSView {
    private let check = PiKit.SymbolView(PiKit.Symbol("checkmark", size: 12, weight: .semibold), color: .piInk)
    private let name = LabelView(PiKit.Line("", font: PiKit.Font.body, color: .piInk), symbol: "arrow.triangle.branch")
    private let upstream = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let counts = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private(set) var trackingDescription = ""
    init() {
        super.init(frame: .zero)
        for view in [check, name, upstream, counts] as [NSView] { addSubview(view); view.setAccessibilityElement(false) }
        check.setAccessibilityIdentifier("git-branch-current")
        upstream.setAccessibilityIdentifier("git-branch-upstream"); upstream.truncation = .middle
        counts.setAccessibilityIdentifier("git-branch-tracking-counts")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    func show(_ branch: GitBranchReference) {
        check.isHidden = !branch.current; name.line.text = branch.name
        name.symbolName = branch.remote == nil ? "arrow.triangle.branch" : "cloud"
        upstream.line.text = branch.tracking?.upstream ?? ""
        counts.line.text = ""; trackingDescription = ""
        if let tracking = branch.tracking {
            if tracking.gone {
                counts.line.text = "gone"; trackingDescription = "Upstream \(tracking.upstream) is missing"
            } else if let ahead = tracking.ahead, let behind = tracking.behind {
                counts.line.text = [ahead > 0 ? "↑\(ahead)" : "", behind > 0 ? "↓\(behind)" : ""].filter { !$0.isEmpty }.joined(separator: " ")
                trackingDescription = "Tracks \(tracking.upstream), " + (ahead == 0 && behind == 0 ? "up to date" : "\(ahead) ahead, \(behind) behind")
            } else {
                counts.line.text = "?"; trackingDescription = "Tracks \(tracking.upstream), counts unavailable"
            }
        }
        upstream.isHidden = upstream.line.text.isEmpty; counts.isHidden = counts.line.text.isEmpty
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        check.frame = CGRect(x: 0, y: 0, width: 14, height: height)
        // Reserve the check column even on unchecked rows. Keep counts visible
        // and give the branch name priority over a long upstream name.
        let available = max(0, width - 20)
        let countWidth = counts.isHidden ? 0 : min(available, counts.intrinsicContentSize.width)
        let remaining = max(0, available - countWidth - (countWidth > 0 ? 8 : 0))
        let preferredName = min(name.intrinsicContentSize.width, max(100, remaining * 0.6))
        let upstreamWidth = upstream.isHidden ? 0 : min(upstream.intrinsicContentSize.width, max(0, remaining - preferredName - 8))
        name.frame = CGRect(x: 20, y: 0, width: max(0, remaining - (upstreamWidth > 0 ? upstreamWidth + 8 : 0)), height: height)
        let textHeight = counts.intrinsicContentSize.height
        counts.frame = CGRect(x: width - countWidth, y: (height - textHeight) / 2, width: countWidth, height: textHeight)
        upstream.frame = CGRect(x: width - countWidth - (countWidth > 0 ? 8 : 0) - upstreamWidth, y: (height - textHeight) / 2, width: upstreamWidth, height: textHeight)
    }
}
