import AppKit
import GitView

// MARK: - Changes

/// A square that ticks, unticks, or shows some of a section ticked.
@MainActor func gitCheckbox(on: Bool, mixed: Bool = false, label: String, action: @escaping () -> Void) -> SymbolButton {
    let button = SymbolButton(symbol: gitCheckboxSymbol(on: on, mixed: mixed), color: on || mixed ? .piAccent : .piInkTertiary,
                              size: CGSize(width: 18, height: 18), label: label, action: action)
    return button
}
@MainActor func gitCheckboxSymbol(on: Bool, mixed: Bool) -> PiKit.Symbol {
    PiKit.Symbol(on ? "checkmark.square.fill" : mixed ? "minus.square.fill" : "square", size: 14, weight: .medium)
}
extension SymbolButton {
    /// Sets a Changes tick's state.
    func setTick(on: Bool, mixed: Bool = false, label: String) {
        symbol = gitCheckboxSymbol(on: on, mixed: mixed)
        color = on || mixed ? .piAccent : .piInkTertiary
        setAccessibilityLabel(label)
    }
}

/// The changed files, staged first, each with its tick and its badge.
@MainActor final class GitChangesList: NSView {
    struct Inputs: Equatable {
        var read: Bool, staged: [GitStatusEntry], unstaged: [GitStatusEntry], empty: Bool
        var checked: Set<String>, selection: GitController.Selection?
        var context: GitController.RepositoryContext?
        @MainActor init(_ controller: GitController) {
            read = controller.statusRead; staged = controller.staged; unstaged = controller.unstaged; empty = controller.status.entries.isEmpty
            checked = controller.checked; selection = controller.selection
            context = controller.repositoryContext
        }
    }
    private enum Row: Hashable { case empty, section(staged: Bool), file(path: String, staged: Bool) }
    private let controller: GitController
    private let discard: @MainActor ([GitStatusEntry]) -> Void
    private let observeFileRow: (@MainActor (String, CGRect) -> Void)?
    let list = LazyStackView()
    private var inputs: Inputs?
    private var rows: [Row] = []
    private var tall: Set<Row> = []
    private let glide = PiKit.SelectionGlide()

    init(controller: GitController, discard: @escaping @MainActor ([GitStatusEntry]) -> Void, observeFileRow: (@MainActor (String, CGRect) -> Void)?) {
        self.controller = controller; self.discard = discard; self.observeFileRow = observeFileRow
        super.init(frame: .zero)
        list.spacing = 2
        list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
        addSubview(list)
        if observeFileRow != nil {
            list.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(reportRows), name: NSView.boundsDidChangeNotification, object: list.contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        list.frame = bounds
        if observeFileRow != nil { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reportRows() } } }
    }
    /// One section and its first file, including the surrounding list insets.
    /// The diff can give up space before this row becomes a clipped sliver.
    var minimumRowsHeight: CGFloat {
        list.insets.top + GitSectionRow.height + list.spacing + GitFileRowView.height + 1 + list.insets.bottom
    }
    /// Each file row's frame in the window, from the top left.
    @objc private func reportRows() {
        guard let observeFileRow, let window, let content = window.contentView else { return }
        for case let row as GitFileRowView in list.documentView?.subviews ?? [] {
            let frame = row.convert(row.bounds, to: nil)
            guard let path = row.entry?.path else { continue }
            observeFileRow(path, CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height))
        }
    }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        let first = inputs == nil
        inputs = next
        if !first || next.read { RedrawCounter.note("GitChangesList") }
        var rows: [Row] = []
        if next.read && next.empty { rows.append(.empty) }
        if !next.staged.isEmpty { rows.append(.section(staged: true)); rows += next.staged.map { .file(path: $0.path, staged: true) } }
        if !next.unstaged.isEmpty { rows.append(.section(staged: false)); rows += next.unstaged.map { .file(path: $0.path, staged: false) } }
        let staged = Dictionary(next.staged.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let unstaged = Dictionary(next.unstaged.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        // The rows' heights: a file with no folder line is a point taller.
        let tall = Set(rows.compactMap { row -> Row? in
            guard case .file(let path, let isStaged) = row, let entry = isStaged ? staged[path] : unstaged[path],
                  GitFileRowContent.folder(of: entry).isEmpty else { return nil }
            return row
        })
        let sameRows = rows == self.rows && tall == self.tall
        self.rows = rows; self.tall = tall
        let source = LazyStackView.Source(count: rows.count, key: { [rows] in AnyHashable(rows[$0]) }, height: { [rows, tall] index, width in
            switch rows[index] {
            case .empty: return GitEmptyRow.height
            case .section: return GitSectionRow.height
            case .file:
                // A file at the top has no folder: its empty line is a point taller.
                return GitFileRowView.height + (tall.contains(rows[index]) ? 1 : 0)
            }
        }, view: { [weak self, rows] index, existing in
            guard let self else { return NSView() }
            switch rows[index] {
            case .empty: return existing ?? GitEmptyRow("No changes. The working tree matches HEAD.")
            case .section(let isStaged):
                let row = existing as? GitSectionRow ?? GitSectionRow()
                self.configure(section: row, staged: isStaged, inputs: next)
                return row
            case .file(let path, let isStaged):
                guard let entry = isStaged ? staged[path] : unstaged[path] else { return existing ?? NSView() }
                let row = existing as? GitFileRowView ?? GitFileRowView(controller: self.controller, discard: self.discard, glide: self.glide)
                row.apply(entry: entry, staged: isStaged, selected: next.selection == GitController.Selection(path: entry.path, staged: isStaged),
                          checked: next.checked.contains(entry.path), context: next.context)
                return row
            }
        })
        // A tick or a selection: the same rows, the same heights.
        if sameRows { list.update(source) } else { list.reload(source) }
    }

    private func configure(section row: GitSectionRow, staged: Bool, inputs: Inputs) {
        let controller = controller
        let count = staged ? inputs.staged.count : inputs.unstaged.count
        let title = staged ? "Staged · \(count)" : "Changes · \(count)"
        let paths = Set((staged ? inputs.staged : inputs.unstaged).map(\.path)), context = inputs.context
        let all = paths.isSubset(of: inputs.checked)
        row.apply(title: title, all: all, mixed: !all && !paths.isDisjoint(with: inputs.checked),
                  actionTitle: staged ? "Unstage all" : "Stage all",
                  tick: {
                      guard controller.accepts(context) else { return }
                      if all { controller.checked.subtract(paths) } else { controller.checked.formUnion(paths) }
                  },
                  action: { guard controller.accepts(context) else { return }; Task { if staged { await controller.unstage(Array(paths), context: context) } else { await controller.stage(Array(paths), context: context) } } })
    }
}

/// "No changes": caption text 16 points in.
@MainActor final class GitEmptyRow: NSView {
    static var height: CGFloat { PiKit.Line("", font: PiKit.Font.caption, color: .black).lineHeight + PiSpacing.lg * 2 }
    private let line: PiKit.TextLine
    var text: String { get { line.line.text } set { if line.line.text != newValue { line.line.text = newValue; needsLayout = true } } }
    init(_ text: String) {
        line = PiKit.TextLine(PiKit.Line(text, font: PiKit.Font.caption, color: .piInkSecondary))
        super.init(frame: .zero)
        addSubview(line)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let size = line.intrinsicContentSize
        line.frame = CGRect(x: PiSpacing.lg, y: PiSpacing.lg, width: min(size.width, max(0, bounds.width - PiSpacing.lg * 2)), height: size.height)
    }
}

/// A section's head: its tick, its title and count, and Stage all or Unstage all.
@MainActor final class GitSectionRow: NSView {
    static var height: CGFloat { PiSpacing.sm + 18 + 2 }
    private let tick = gitCheckbox(on: false, label: "") {}
    private let title = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
    private let action = PlainTextButton("", font: PiKit.Font.micro, color: .piAccent)
    init() {
        super.init(frame: .zero)
        for view in [tick, title, action] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func apply(title text: String, all: Bool, mixed: Bool, actionTitle: String, tick press: @escaping () -> Void, action run: @escaping () -> Void) {
        tick.setTick(on: all, mixed: mixed, label: all ? "Uncheck \(text)" : "Check \(text)")
        tick.onPress = press
        title.line.text = text
        action.line.text = actionTitle
        action.onPress = run
        needsLayout = true
    }
    override func layout() {
        super.layout()
        StackLayout.place([.fixed(tick), .line(title), .spacer(), .fixed(action)], spacing: PiSpacing.sm,
                          in: CGRect(x: PiSpacing.sm, y: PiSpacing.sm, width: bounds.width - PiSpacing.sm * 2, height: 18), scale: piScale)
    }
}

/// One changed file: its tick, its badge, its name and folder, and stage or
/// unstage. Updated only when one of those, or its selection, changes.
@MainActor final class GitFileRowView: NSView {
    static var height: CGFloat {
        let text = PiKit.Line("", font: PiKit.Font.body, color: .black).lineHeight + 1 + PiKit.Line("", font: PiKit.Font.micro, color: .black).lineHeight
        return max(20, text) + PiKit.SelectableRow.padding.top + PiKit.SelectableRow.padding.bottom
    }
    private let controller: GitController
    private let discard: @MainActor ([GitStatusEntry]) -> Void
    private let content = GitFileRowContent()
    let row: PiKit.SelectableRow
    private(set) var entry: GitStatusEntry?
    private var shown: (entry: GitStatusEntry, staged: Bool, selected: Bool, checked: Bool)?
    private var staged = false
    private var context: GitController.RepositoryContext?

    init(controller: GitController, discard: @escaping @MainActor ([GitStatusEntry]) -> Void, glide: PiKit.SelectionGlide) {
        self.controller = controller; self.discard = discard
        row = PiKit.SelectableRow(content: content, glide: glide)
        super.init(frame: .zero)
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }

    func apply(entry: GitStatusEntry, staged: Bool, selected: Bool, checked: Bool, context: GitController.RepositoryContext? = nil) {
        let context = context ?? controller.repositoryContext
        if let shown, shown.entry == entry, shown.staged == staged, shown.selected == selected, shown.checked == checked, self.context == context { return }
        shown = (entry, staged, selected, checked)
        self.entry = entry; self.staged = staged; self.context = context
        RedrawCounter.note("GitFileRow")
        let controller = controller
        row.selected = selected
        row.onPress = { guard controller.accepts(context) else { return }; controller.selection = GitController.Selection(path: entry.path, staged: staged) }
        row.setAccessibilityIdentifier("git-file-" + entry.path)
        content.apply(entry: entry, staged: staged, checked: checked, controller: controller, context: context)
        row.setAccessibilityLabel(content.spokenText)
        row.setAccessibilityValue(entry.summary)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entry else { return nil }
        let staged = staged, controller = controller, discard = discard, context = context
        var entries: [PiMenuEntry] = [
            staged ? .button("Unstage") { guard controller.accepts(context) else { return }; Task { await controller.unstage([entry.path], context: context) } } : .button("Stage") { guard controller.accepts(context) else { return }; Task { await controller.stage([entry.path], context: context) } },
            .button(entry.untracked ? "Delete Untracked File…" : "Discard Changes…") { guard controller.accepts(context) else { return }; discard([entry]) },
            .divider,
        ]
        if !entry.untracked {
            entries.append(.button("Show History of This File", systemImage: "clock.arrow.circlepath", identifier: "git-file-history-" + entry.path) {
                guard controller.accepts(context) else { return }
                controller.showFileHistory(entry.path)
            })
        }
        entries.append(.button("Reveal in Finder") {
            if controller.accepts(context), let root = context?.root { NSWorkspace.shared.selectFile((root as NSString).appendingPathComponent(entry.path), inFileViewerRootedAtPath: root) }
        })
        entries.append(.button("Copy Path") { guard controller.accepts(context) else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) })
        return PiMenus.menu(entries)
    }

    static func badgeColor(_ badge: String) -> NSColor {
        switch badge { case "A", "U": .piSuccess; case "D", "!": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
    }
}

/// A file row's content, inside its selectable row.
@MainActor final class GitFileRowContent: NSView {
    private let tick = gitCheckbox(on: false, label: "") {}
    private let badge = GitStatusBadge()
    private let name = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.body, color: .piInk))
    private let folder = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    private let stageButton = PiKit.IconButton(symbol: "plus", label: "", size: 20)
    init() {
        super.init(frame: .zero)
        folder.truncation = .middle
        for view in [tick, badge, name, folder, stageButton] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    var spokenText: String { [name.line.text, folder.line.text].filter { !$0.isEmpty }.joined(separator: ", ") }
    static func folder(of entry: GitStatusEntry) -> String {
        entry.renamed ? "\(entry.originalPath ?? "") → \(entry.path)" : (entry.path as NSString).deletingLastPathComponent
    }
    /// An empty `Text` is 14 points tall in SwiftUI, a point more than a line of micro text.
    private var folderHeight: CGFloat { folder.line.text.isEmpty ? 14 : folder.intrinsicContentSize.height }

    func apply(entry: GitStatusEntry, staged: Bool, checked: Bool, controller: GitController, context: GitController.RepositoryContext?) {
        tick.setTick(on: checked, label: checked ? "Exclude \(entry.path) from the commit" : "Include \(entry.path) in the commit")
        tick.setAccessibilityIdentifier("git-check-" + entry.path)
        tick.onPress = { guard controller.accepts(context) else { return }; if checked { controller.checked.remove(entry.path) } else { controller.checked.insert(entry.path) } }
        badge.text = entry.badge; badge.color = GitFileRowView.badgeColor(entry.badge); badge.toolTip = entry.summary
        name.line.text = (entry.path as NSString).lastPathComponent
        folder.line.text = Self.folder(of: entry)
        stageButton.symbol = staged ? "minus" : "plus"
        stageButton.label = staged ? "Unstage \(entry.path)" : "Stage \(entry.path)"
        stageButton.onPress = { guard controller.accepts(context) else { return }; Task { if staged { await controller.unstage([entry.path], context: context) } else { await controller.stage([entry.path], context: context) } } }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let scale = piScale
        let textHeight = name.intrinsicContentSize.height + 1 + folderHeight
        let block = StackLayout.Sizing(width: { [name, folder] proposal in min(max(name.intrinsicContentSize.width, folder.intrinsicContentSize.width), max(0, proposal)) },
                                       height: { _ in textHeight })
        let items: [StackLayout.Item] = [.fixed(tick), .view(badge, .fixed(CGSize(width: 18, height: 18))), StackLayout.Item(view: nil, sizing: block), .spacer(4), .fixed(stageButton)]
        let frames = StackLayout.place(items, spacing: PiSpacing.sm, in: bounds, scale: scale)
        let text = frames[2]
        name.frame = CGRect(x: text.minX, y: text.minY, width: min(name.intrinsicContentSize.width, text.width), height: name.intrinsicContentSize.height)
        folder.frame = CGRect(x: text.minX, y: text.minY + name.intrinsicContentSize.height + 1, width: min(folder.intrinsicContentSize.width, text.width),
                              height: folder.intrinsicContentSize.height)
    }
}

/// A file's status letter on its colour: 18 points square, corners of 5.
@MainActor final class GitStatusBadge: NSView {
    var text = "" { didSet { if oldValue != text { needsDisplay = true } } }
    var color: NSColor = .piBrandOrange { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(GitDiffMetrics.continuousRoundedRect(bounds, radius: 5))
        context.setFillColor(GitDiffMetrics.fill(color, opacity: 1)); context.fillPath()
        let line = PiKit.Line(text, font: .systemFont(ofSize: 10.5, weight: .bold), color: .piOnAccent), size = line.size(scale: piScale)
        line.draw(at: CGPoint(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale)), scale: piScale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
