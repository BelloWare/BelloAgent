import AppKit
import Combine
import GitView

/// A project's changes and history, laid out like IntelliJ's Git tool
/// window: a branch menu with fetch, pull, push and stash controls; a
/// changelist with checkboxes, amend and discard; the history with filters
/// and ref badges; and a unified or side-by-side diff of whatever is
/// selected. Shown in a tab beside the chats or in a window of its own
/// (`ChangesTab`), over a controller its tab keeps.
///
/// The panel observes its controller. Each part below takes only the values
/// it shows and compares on them, so a file chosen, a character typed or a
/// box ticked updates the parts that show it and lets the others pass
/// (`RedrawCounter` counts each part's updates).
@MainActor final class GitPanelView: NSView, PiKit.SizeObserver {
    let controller: GitController
    /// Where the panel is, and the discard question it has up, if any: its
    /// tab's, so closing the tab takes the question down.
    let place: GitPanelPlace
    /// The panel's own asker, so a question about discarding is only ever
    /// refused by another question about discarding.
    let questions: PiQuestion
    /// The project the panel shows, named in its header.
    let project: String?
    let openFile: ((String, Int) -> Void)?
    /// Optional layout observation for tests: each file row's frame in its
    /// window, from the top left. No row geometry is read in the app.
    let observeFileRow: (@MainActor (String, CGRect) -> Void)?
    /// Wide enough for the list beside the diff; below this the list goes
    /// above it (`GitPanelSplit`).
    nonisolated static let wideWidth: CGFloat = 900
    private(set) var wide = true

    private let header: GitPanelHeader
    private let toolbar: GitPanelToolbar
    private let toolbarRule = HairlineView()
    private let notRepository: NoticeView
    private let changesList: GitChangesList
    private let changesRule = HairlineView()
    private let commitBox: GitCommitBox
    private let history: GitHistoryList
    private let splitRule = HairlineView()
    private let detail: GitPanelDetail
    private let probe = GitPanelProbe()
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false

    init(controller: GitController, place: GitPanelPlace = GitPanelPlace(), questions: PiQuestion = PiQuestion(), project: String? = nil,
         openFile: ((String, Int) -> Void)? = nil, observeFileRow: (@MainActor (String, CGRect) -> Void)? = nil) {
        self.controller = controller; self.place = place; self.questions = questions; self.project = project
        self.openFile = openFile; self.observeFileRow = observeFileRow
        header = GitPanelHeader(controller: controller, project: project)
        toolbar = GitPanelToolbar(controller: controller)
        notRepository = NoticeView(symbol: PiKit.Symbol("arrow.triangle.branch", size: 28), title: "Not a git repository",
                                   titleFont: PiKit.Font.title(17), detail: "", detailFont: PiKit.Font.caption)
        notRepository.spacing = PiSpacing.sm; notRepository.padding = 0; notRepository.detailWidth = 420
        let discard: @MainActor ([GitStatusEntry]) -> Void = { [questions, controller, place] entries in
            place.askToDiscard(entries, questions: questions) { entries in Task { await controller.discard(entries) } }
        }
        changesList = GitChangesList(controller: controller, discard: discard, observeFileRow: observeFileRow)
        commitBox = GitCommitBox(controller: controller, inputs: GitCommitBox.Inputs(controller), discard: discard)
        history = GitHistoryList(controller: controller)
        detail = GitPanelDetail(controller: controller, openFile: openFile)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [probe, header, toolbar, toolbarRule, notRepository, changesList, changesRule, commitBox, history, splitRule, detail] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(false)
        setAccessibilityIdentifier("git-panel")
        // On screen or not, as the panel's own view is: the controller reads
        // and watches only while it is, and a discard question the panel has
        // up goes down, unanswered, when the panel goes or moves.
        place.probe = probe
        probe.shown = { [controller, place] shown in
            controller.setShown(shown)
            if !shown { place.cancelQuestion() }
        }
        probe.moved = { [place] in place.cancelQuestion() }
        // A change is read once it is made: `objectWillChange` comes before
        // the value is set, so the parts are updated in the next layout pass
        // or on the next turn, whichever comes first.
        observations.append(controller.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        observations.append(controller.presentation.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.detail.presentationChanged() } }
        })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    /// A part changed its size: the panel lays its parts out again, and
    /// nothing outside it does.
    func contentSizeChanged() { framesDirty = true; needsLayout = true }
    /// The project the panel shows was renamed.
    func setProject(_ name: String) { header.setProject(name) }
    /// The parts' frames must be worked out again (a part's height, or which
    /// parts show, changed); otherwise a layout pass at the same size only
    /// reads the controller.
    private var framesDirty = true
    private var laidOutSize = CGSize.zero

    private func scheduleRefresh() {
        needsLayout = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refreshIfScheduled() } }
    }
    private func refreshIfScheduled() {
        guard refreshScheduled else { return }
        refresh()
    }
    /// Each part takes what it shows now; those whose inputs changed update.
    /// The panel lays its parts out again only when which parts show changes
    /// or a part says its height changed (`contentSizeChanged`).
    func refresh() {
        refreshScheduled = false
        header.apply(GitPanelHeader.Inputs(controller))
        toolbar.apply(GitPanelToolbar.Inputs(controller), wide: wide)
        let missing = controller.statusRead && controller.repositoryRoot == nil && !controller.loading
        if missing {
            notRepository.set(title: "Not a git repository",
                              detail: "\(controller.displayRoot) is not inside a git repository. Run git init there, or choose another folder of this project.")
        }
        let changes = controller.panel == .changes
        let shown = Shown(missing: missing, changes: changes)
        if shown != self.shown {
            self.shown = shown
            notRepository.isHidden = !missing
            for view in [changesList, changesRule, commitBox] as [NSView] { view.isHidden = missing || !changes }
            history.isHidden = missing || changes
            splitRule.isHidden = missing; detail.isHidden = missing
            framesDirty = true; needsLayout = true
        }
        if changes {
            changesList.apply(GitChangesList.Inputs(controller))
            commitBox.apply(GitCommitBox.Inputs(controller))
        } else {
            history.apply(GitHistoryList.Inputs(controller))
        }
        detail.apply(GitPanelDetail.Inputs(controller))
    }
    private struct Shown: Equatable { var missing: Bool, changes: Bool }
    private var shown: Shown?

    // MARK: Layout

    override func layout() {
        if refreshScheduled { refresh() }
        super.layout()
        guard framesDirty || bounds.size != laidOutSize else { return }
        framesDirty = false; laidOutSize = bounds.size
        let width = bounds.width, scale = piScale
        let nowWide = width >= Self.wideWidth
        if nowWide != wide { wide = nowWide; toolbar.apply(GitPanelToolbar.Inputs(controller), wide: wide) }
        probe.frame = .zero
        header.frame = CGRect(x: 0, y: 0, width: width, height: 32)
        let toolbarHeight = toolbar.height(forWidth: width)
        toolbar.frame = CGRect(x: 0, y: 32, width: width, height: toolbarHeight)
        toolbarRule.frame = CGRect(x: 0, y: 32 + toolbarHeight, width: width, height: 1)
        let body = CGRect(x: 0, y: toolbarRule.frame.maxY, width: width, height: max(0, bounds.height - toolbarRule.frame.maxY))
        notRepository.frame = body
        guard notRepository.isHidden else { return }
        let changes = controller.panel == .changes
        let list: CGRect, detailFrame: CGRect
        if wide {
            let listWidth = min(GitPanelSplit.listWidth, body.width)
            list = CGRect(x: 0, y: body.minY, width: listWidth, height: body.height)
            splitRule.frame = CGRect(x: listWidth, y: body.minY, width: 1, height: body.height)
            detailFrame = CGRect(x: listWidth + 1, y: body.minY, width: max(0, body.width - listWidth - 1), height: body.height)
        } else {
            // What the side cannot give up: its size when offered no height
            // at all, the commit message at its two lines.
            let fixed = changes ? 1 + commitBox.minimumHeight(forWidth: body.width) : history.fixedHeight(forWidth: body.width)
            let height = GitPanelSplit.listHeight(available: max(0, body.height - 1), least: fixed + GitPanelSplit.leastRows)
            list = CGRect(x: 0, y: body.minY, width: body.width, height: height)
            splitRule.frame = CGRect(x: 0, y: body.minY + height, width: body.width, height: 1)
            detailFrame = CGRect(x: 0, y: body.minY + height + 1, width: body.width, height: max(0, body.height - height - 1))
        }
        if changes {
            // The commit box keeps its height; the list takes what is left.
            let boxHeight = commitBox.height(forWidth: list.width)
            let listHeight = max(0, list.height - 1 - boxHeight)
            changesList.frame = CGRect(x: list.minX, y: list.minY, width: list.width, height: listHeight)
            changesRule.frame = CGRect(x: list.minX, y: list.minY + listHeight, width: list.width, height: 1)
            commitBox.frame = CGRect(x: list.minX, y: list.minY + listHeight + 1, width: list.width, height: boxHeight)
        } else {
            history.frame = list
        }
        detail.frame = detailFrame
        _ = scale
    }
}

/// The list and the diff: side by side where the panel is wide, the list
/// 340 points wide; where it is narrow (the pane beside the chat), the list
/// above the diff, both the panel's width. The same views either way, so
/// the diff table, the lists and what they hold (the wrap, where they were
/// scrolled) stay as they were when the panel's width crosses the line.
enum GitPanelSplit {
    static let listWidth: CGFloat = 340
    /// Narrow: how tall the list side is, of the `available` height (the
    /// panel's less the rule): 45% of it, never less than the side needs
    /// (`least`: its commit box or filters, and a few rows), and leaving the
    /// diff 180 points where that allows; at most all there is.
    static func listHeight(available: CGFloat, least: CGFloat) -> CGFloat {
        min(max((available * 0.45).rounded(), least), max(available - 180, least), available)
    }
    /// Three rows of the list, below the side's fixed parts.
    static let leastRows: CGFloat = 3 * 44
}

// MARK: - Header

/// The panel's head, as a file tab's is: the project, and what the
/// repository is at (its branch, what it tracks, how many files changed, what
/// is stashed); the spinner while the reader's read runs, and Refresh.
@MainActor final class GitPanelHeader: NSView {
    struct Inputs: Equatable {
        var repository: Bool, branch: String, upstream: String?, changed: Int, stashes: Int, working: Bool
        @MainActor init(_ controller: GitController) {
            repository = controller.repositoryRoot != nil; branch = controller.status.branch; upstream = controller.status.upstream
            changed = controller.status.entries.count; stashes = controller.stashes.count; working = controller.loading || controller.busy
        }
    }
    private var projectLabel: PiKit.TextLine?
    private let chevron = PiKit.SymbolView(PiKit.Symbol("chevron.right", size: 8, weight: .semibold), color: .piInkTertiary)
    private let subtitle = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let pathGroup = NSView()
    private let spinner = PiKit.spinner(controlSize: .small)
    private let refreshButton: PiKit.IconButton
    private let rule = HairlineView()
    private var inputs: Inputs?

    init(controller: GitController, project: String?) {
        projectLabel = project.map { PiKit.TextLine(PiKit.Line($0, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piInkSecondary)) }
        projectLabel?.truncation = .middle
        refreshButton = PiKit.IconButton(symbol: "arrow.clockwise", label: "Refresh changes", size: 26) { Task { await controller.refresh() } }
        super.init(frame: .zero)
        for view in [projectLabel, project == nil ? nil : chevron, subtitle].compactMap({ $0 }) as [NSView] { pathGroup.addSubview(view) }
        // The path is read as one: the project and where the repository is.
        pathGroup.setAccessibilityElement(true); pathGroup.setAccessibilityRole(.staticText)
        for view in [pathGroup, spinner, refreshButton, rule] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// The project was renamed.
    func setProject(_ name: String) {
        guard let projectLabel, projectLabel.line.text != name else { return }
        projectLabel.line.text = name
        if let inputs { self.inputs = nil; apply(inputs) }
    }
    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        inputs = next
        RedrawCounter.note("GitPanelHeader")
        let text = Self.subtitle(next)
        subtitle.line.text = text
        pathGroup.toolTip = text
        pathGroup.setAccessibilityLabel([projectLabel?.line.text, text].compactMap { $0 }.joined(separator: ", "))
        spinner.isHidden = !next.working
        needsLayout = true
    }
    static func subtitle(_ inputs: Inputs) -> String {
        guard inputs.repository else { return "Working-tree changes and history of the project's folders." }
        var parts = [inputs.branch.isEmpty ? "detached HEAD" : inputs.branch]
        if let upstream = inputs.upstream { parts.append("tracks \(upstream)") }
        parts.append("\(inputs.changed) changed")
        if inputs.stashes > 0 { parts.append("\(inputs.stashes) stashed") }
        return parts.joined(separator: " · ")
    }

    private var pathItems: [StackLayout.Item] {
        var items: [StackLayout.Item] = []
        if let projectLabel { items.append(.line(projectLabel, priority: 1)); items.append(.fixed(chevron)) }
        items.append(.line(subtitle))
        return items
    }
    override func layout() {
        super.layout()
        var items: [StackLayout.Item] = [.row(pathItems, spacing: 4), .spacer(PiSpacing.sm)]
        if !spinner.isHidden { items.append(.fixed(spinner)) }
        items.append(.fixed(refreshButton))
        let frames = StackLayout.place(items, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: 0, width: bounds.width - PiSpacing.md * 2, height: 32), scale: piScale)
        // The path's parts, inside the group's own frame.
        let group = frames[0]
        pathGroup.frame = group
        StackLayout.place(pathItems, spacing: 4, in: CGRect(origin: .zero, size: group.size), scale: piScale)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

// MARK: - Toolbar

/// The folder, the branch menu, fetch, pull and push, the stash menu, the
/// Changes and History tabs, and what the last action said: one row where
/// the panel is wide; where it is narrow, the tabs and what the last action
/// said on a second row.
@MainActor final class GitPanelToolbar: NSView, PiKit.WidthSizing {
    struct Inputs: Equatable {
        var roots: [String], root: String?, displayRoot: String, repository: Bool
        var branch: String, upstream: String?, behind: Int, ahead: Int
        var stashes: Int, busy: Bool, panel: GitController.Panel, notice: String, lastCommit: String?
        @MainActor init(_ controller: GitController) {
            roots = controller.roots; root = controller.root; displayRoot = controller.displayRoot; repository = controller.repositoryRoot != nil
            branch = controller.status.branch; upstream = controller.status.upstream; behind = controller.status.behind; ahead = controller.status.ahead
            stashes = controller.stashes.count; busy = controller.busy; panel = controller.panel; notice = controller.notice; lastCommit = controller.lastCommit
        }
    }
    /// Where the panel is narrow, the longest a folder's or a branch's name
    /// is shown; the whole name is its help.
    static let narrowLabelWidth: CGFloat = 150

    private let controller: GitController
    private var inputs: Inputs?
    private var wide = true
    private var rootDropdown: PiKit.Dropdown<String>?
    private let rootLabel = LabelView(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary), symbol: "folder")
    private lazy var branchMenu = PiKit.MenuButton(title: "", icon: "arrow.triangle.branch", identifier: "git-branch-menu") { [weak self, controller] in
        let current = controller.status.branch
        PiMenuEntry.button("New Branch from \(current.isEmpty ? "HEAD" : current)…") { self?.showNewBranch() }
        PiMenuEntry.divider
        for branch in controller.branches {
            PiMenuEntry.button(branch, enabled: branch != current, checked: branch == current) { Task { await controller.checkout(branch) } }
        }
    }
    private let remote: GitRemoteControls
    private lazy var stashMenu = PiKit.MenuButton(title: "Stash", icon: "tray.and.arrow.down", identifier: "git-stash-menu") { [weak self, controller] in
        PiMenuEntry.button("Stash Changes…", enabled: !controller.status.entries.isEmpty) { self?.showStash() }
        if !controller.stashes.isEmpty {
            PiMenuEntry.divider
            for stash in controller.stashes {
                PiMenuEntry.button("Pop \(stash.name): \(stash.subject)") { Task { await controller.popStash(stash.name) } }
            }
        }
    }
    private let panelTabs: PiKit.Tabs<GitController.Panel>
    private let notice = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piDanger))
    private var committed: PiKit.Badge?
    private let branchPopover = AnchoredPopover(), stashPopover = AnchoredPopover()

    init(controller: GitController) {
        self.controller = controller
        rootLabel.truncation = .middle
        remote = GitRemoteControls(controller: controller)
        panelTabs = PiKit.Tabs(selection: controller.panel, items: GitController.Panel.allCases.map { ($0, $0.title) }) { [controller] in controller.panel = $0 }
        super.init(frame: .zero)
        for view in [rootLabel, branchMenu, remote, stashMenu, panelTabs, notice] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs, wide: Bool) {
        guard next != inputs || wide != self.wide else { return }
        inputs = next; self.wide = wide
        RedrawCounter.note("GitPanelToolbar")
        if next.roots.count > 1 {
            let items = next.roots.map { ($0, ($0 as NSString).lastPathComponent) }
            if let rootDropdown {
                rootDropdown.items = items; rootDropdown.selection = next.root ?? ""
                rootDropdown.maxLabelWidth = wide ? nil : Self.narrowLabelWidth
            } else {
                let dropdown = PiKit.Dropdown(selection: next.root ?? "", items: items, icon: "folder", compact: true,
                                              maxLabelWidth: wide ? nil : Self.narrowLabelWidth, accessibilityName: "Repository") { [controller] in controller.root = $0 }
                addSubview(dropdown)
                rootDropdown = dropdown
            }
            rootDropdown?.toolTip = wide ? nil : next.displayRoot
            rootLabel.isHidden = true
        } else {
            rootDropdown?.removeFromSuperview(); rootDropdown = nil
            rootLabel.isHidden = false
            rootLabel.line.text = next.displayRoot
            rootLabel.toolTip = wide ? nil : next.displayRoot
        }
        for view in [branchMenu, remote, stashMenu] as [NSView] { view.isHidden = !next.repository }
        branchMenu.label = next.branch.isEmpty ? "detached" : next.branch
        branchMenu.maxLabelWidth = wide ? nil : Self.narrowLabelWidth
        branchMenu.isEnabled = !next.busy
        remote.apply(behind: next.behind, ahead: next.ahead, upstream: next.upstream, busy: next.busy)
        stashMenu.label = next.stashes == 0 ? "Stash" : "Stash · \(next.stashes)"
        stashMenu.isEnabled = !next.busy
        panelTabs.selection = next.panel
        notice.line.text = next.notice; notice.toolTip = next.notice; notice.isHidden = next.notice.isEmpty
        if let last = next.lastCommit {
            if let committed { committed.text = "Committed \(last)" } else {
                let badge = PiKit.Badge(text: "Committed \(last)", tone: .success, icon: "checkmark")
                addSubview(badge); committed = badge
            }
        } else { committed?.removeFromSuperview(); committed = nil }
        needsLayout = true
        let height = bounds.width > 0 ? self.height(forWidth: bounds.width) : 0
        if height != bounds.height { PiKit.sizeChanged(self) }
    }

    // MARK: Layout

    private var rootItem: StackLayout.Item {
        // The dropdown and the menus are their own size (`fixedSize`).
        if let rootDropdown { return .fixed(rootDropdown) }
        return .view(rootLabel, StackLayout.Sizing(width: { [rootLabel] in min(rootLabel.intrinsicContentSize.width, max(0, $0)) },
                                                   height: { [rootLabel] _ in rootLabel.intrinsicContentSize.height }))
    }
    private var outcomeItems: [StackLayout.Item] {
        var items: [StackLayout.Item] = []
        if !notice.isHidden { items.append(.line(notice)) }
        if let committed { items.append(.view(committed, .intrinsic(committed))) }
        return items
    }
    private func firstRow() -> [StackLayout.Item] {
        var items = [rootItem]
        if inputs?.repository == true {
            items.append(.fixed(branchMenu))
            items.append(.view(remote, remote.sizing))
            items.append(.view(stashMenu, .intrinsic(stashMenu)))
        }
        if wide { items.append(.fixed(panelTabs)); items.append(.spacer()); items += outcomeItems } else { items.append(.spacer(0)) }
        return items
    }
    private func secondRow() -> [StackLayout.Item] { [.fixed(panelTabs), .spacer()] + outcomeItems }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - PiSpacing.lg * 2
        var height = StackLayout.height(firstRow(), spacing: PiSpacing.sm, width: inner)
        if !wide { height += PiSpacing.sm + StackLayout.height(secondRow(), spacing: PiSpacing.sm, width: inner) }
        return height + PiSpacing.sm * 2
    }
    override func layout() {
        super.layout()
        let inner = bounds.width - PiSpacing.lg * 2, scale = piScale
        let first = firstRow(), firstHeight = StackLayout.height(first, spacing: PiSpacing.sm, width: inner)
        StackLayout.place(first, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.lg, y: PiSpacing.sm, width: inner, height: firstHeight), scale: scale)
        if !wide {
            let second = secondRow(), secondHeight = StackLayout.height(second, spacing: PiSpacing.sm, width: inner)
            StackLayout.place(second, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.lg, y: PiSpacing.sm + firstHeight + PiSpacing.sm, width: inner, height: secondHeight), scale: scale)
        }
        remote.layoutForm()
    }

    // MARK: Popovers

    /// IntelliJ's branch popup: a new branch from HEAD, checked out.
    private func showNewBranch() {
        let form = GitNamePopover(title: "New branch", placeholder: "feature/name", icon: "arrow.triangle.branch", mono: true,
                                  note: "Created from the current HEAD and checked out; your changes come along.", action: "Create",
                                  requiresText: true, width: 320)
        form.cancel = { [weak self] in self?.branchPopover.close() }
        form.submit = { [weak self, controller] name in
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self?.branchPopover.close()
            Task { await controller.createBranch(name) }
        }
        branchPopover.show(form, width: 320, below: branchMenu, focus: form.field.field)
    }
    private func showStash() {
        let form = GitNamePopover(title: "Stash changes", placeholder: "Message (optional)", icon: "text.quote", mono: false,
                                  note: "Sets aside every change, untracked files included, and restores a clean working tree.", action: "Stash",
                                  requiresText: false, width: 340)
        form.cancel = { [weak self] in self?.stashPopover.close() }
        form.submit = { [weak self, controller] message in
            self?.stashPopover.close()
            Task { await controller.stash(message: message) }
        }
        stashPopover.show(form, width: 340, below: stashMenu, focus: form.field.field)
    }
}

/// A small form in a popover: a heading, a field, a note, Cancel and the action.
@MainActor final class GitNamePopover: NSView, PiKit.WidthSizing {
    let field: PiKit.TextField
    private let heading: PiKit.TextLine
    private let note: TextBlock
    private let cancelButton = PiKit.Button("Cancel", style: .secondary, compact: true)
    private let actionButton: PiKit.Button
    private let requiresText: Bool
    var cancel: (() -> Void)?
    var submit: ((String) -> Void)?
    init(title: String, placeholder: String, icon: String, mono: Bool, note: String, action: String, requiresText: Bool, width: CGFloat) {
        heading = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.heading, color: .piInk))
        field = PiKit.TextField(placeholder: placeholder, icon: icon, mono: mono)
        self.note = TextBlock(note, font: PiKit.Font.micro, color: .piInkTertiary)
        actionButton = PiKit.Button(action, style: .primary, compact: true)
        self.requiresText = requiresText
        super.init(frame: .zero)
        for view in [heading, field, self.note, cancelButton, actionButton] as [NSView] { addSubview(view) }
        cancelButton.onPress = { [weak self] in self?.cancel?() }
        actionButton.onPress = { [weak self] in guard let self else { return }; self.submit?(self.field.text) }
        field.onSubmit = { [weak self] in guard let self, self.actionButton.isEnabled else { return }; self.submit?(self.field.text) }
        field.onChange = { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func refresh() { actionButton.isEnabled = !requiresText || !field.text.trimmingCharacters(in: .whitespaces).isEmpty }
    private func heights(_ width: CGFloat) -> [CGFloat] {
        let inner = width - PiSpacing.lg * 2
        return [heading.intrinsicContentSize.height, field.intrinsicContentSize.height, note.height(forWidth: inner),
                max(cancelButton.intrinsicContentSize.height, actionButton.intrinsicContentSize.height)]
    }
    func height(forWidth width: CGFloat) -> CGFloat { heights(width).reduce(0, +) + PiSpacing.sm * 3 + PiSpacing.lg * 2 }
    override func layout() {
        super.layout()
        let inner = bounds.width - PiSpacing.lg * 2, rows = heights(bounds.width)
        var y = PiSpacing.lg
        heading.frame = CGRect(x: PiSpacing.lg, y: y, width: min(inner, heading.intrinsicContentSize.width), height: rows[0]); y += rows[0] + PiSpacing.sm
        field.frame = CGRect(x: PiSpacing.lg, y: y, width: inner, height: rows[1]); y += rows[1] + PiSpacing.sm
        note.frame = CGRect(x: PiSpacing.lg, y: y, width: inner, height: rows[2]); y += rows[2] + PiSpacing.sm
        StackLayout.place([.spacer(), .fixed(cancelButton), .fixed(actionButton)], spacing: StackLayout.system,
                          in: CGRect(x: PiSpacing.lg, y: y, width: inner, height: rows[3]), scale: piScale)
    }
}

/// Fetch, pull and push: named wherever the toolbar has room, and three
/// symbols that keep their counts and help where it does not
/// (`ViewThatFits`). The symbols are built only when they are what shows.
@MainActor final class GitRemoteControls: NSView {
    private let controller: GitController
    private var behind = 0, ahead = 0, upstream: String?
    private let fetchButton: PiKit.Button, pullButton: PiKit.Button, pushButton: PiKit.Button
    private var icons: GitRemoteIconButtons?
    /// The width offered when last laid out: the form follows it.
    private var named = true
    static let iconSize = CGSize(width: 3 * 26 + 2 * 2, height: 26)

    init(controller: GitController) {
        self.controller = controller
        fetchButton = PiKit.Button("Fetch", symbol: "arrow.down.to.line", style: .secondary, compact: true) { Task { await controller.fetch() } }
        pullButton = PiKit.Button("Pull", symbol: "arrow.down.circle", style: .secondary, compact: true) { Task { await controller.pull() } }
        pushButton = PiKit.Button("Push", symbol: "arrow.up.circle", style: .secondary, compact: true) { Task { await controller.push() } }
        super.init(frame: .zero)
        for (button, name) in [(fetchButton, "fetch"), (pullButton, "pull"), (pushButton, "push")] {
            button.setAccessibilityIdentifier("git-remote-" + name); addSubview(button)
        }
        fetchButton.toolTip = "Fetch from every remote and prune"
        apply(behind: 0, ahead: 0, upstream: nil, busy: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(behind: Int, ahead: Int, upstream: String?, busy: Bool) {
        self.behind = behind; self.ahead = ahead; self.upstream = upstream
        pullButton.title = behind > 0 ? "Pull \(behind)" : "Pull"
        pullButton.toolTip = behind > 0 ? "Pull \(behind) new commits (fast-forward only)" : "Pull (fast-forward only)"
        pullButton.setAccessibilityLabel(behind > 0 ? "Pull, \(behind) commits" : "Pull")
        pushButton.title = ahead > 0 ? "Push \(ahead)" : "Push"
        pushButton.toolTip = ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")" : "Push"
        pushButton.setAccessibilityLabel(ahead > 0 ? "Push, \(ahead) commits" : "Push")
        for button in [fetchButton, pullButton, pushButton] { button.isEnabled = !busy }
        icons?.apply(behind: behind, ahead: ahead, upstream: upstream, busy: busy)
        self.busy = busy
    }
    private var busy = false
    private var namedWidth: CGFloat {
        [fetchButton, pullButton, pushButton].reduce(0) { $0 + $1.intrinsicContentSize.width } + 4 * 2
    }
    /// The width it takes when offered `proposal`: its names where they fit.
    var sizing: StackLayout.Sizing {
        StackLayout.Sizing(width: { [weak self] proposal in
            guard let self else { return 0 }
            return proposal >= self.namedWidth ? self.namedWidth : Self.iconSize.width
        }, height: { [weak self] width in
            guard let self else { return 0 }
            return width >= self.namedWidth ? self.fetchButton.intrinsicContentSize.height : Self.iconSize.height
        })
    }
    /// Shows the form that fits the frame it was given.
    func layoutForm() {
        guard !isHidden else { return }
        named = bounds.width >= namedWidth - 0.5
        for button in [fetchButton, pullButton, pushButton] { button.isHidden = !named }
        if !named, icons == nil {
            let made = GitRemoteIconButtons(controller: controller)
            made.apply(behind: behind, ahead: ahead, upstream: upstream, busy: busy)
            addSubview(made); icons = made
        }
        icons?.isHidden = named
        needsLayout = true
    }
    override func layout() {
        super.layout()
        if named {
            var x: CGFloat = 0
            for button in [fetchButton, pullButton, pushButton] {
                let size = button.intrinsicContentSize
                button.frame = CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
                x += size.width + 4
            }
        } else {
            icons?.frame = CGRect(x: 0, y: PiKit.round((bounds.height - Self.iconSize.height) / 2, piScale), width: Self.iconSize.width, height: Self.iconSize.height)
        }
    }
}

/// Fetch, pull and push as three symbols, where the toolbar has no room for
/// their names: each keeps its count and its help.
@MainActor final class GitRemoteIconButtons: NSView {
    private let fetch: PiKit.IconButton, pull: PiKit.IconButton, push: PiKit.IconButton
    private let pullCount = GitCountBadge(), pushCount = GitCountBadge()
    init(controller: GitController) {
        fetch = PiKit.IconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26) { Task { await controller.fetch() } }
        pull = PiKit.IconButton(symbol: "arrow.down.circle", label: "Pull", size: 26) { Task { await controller.pull() } }
        push = PiKit.IconButton(symbol: "arrow.up.circle", label: "Push", size: 26) { Task { await controller.push() } }
        super.init(frame: .zero)
        for view in [fetch, pull, push, pullCount, pushCount] as [NSView] { addSubview(view) }
        fetch.toolTip = "Fetch from every remote and prune"
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func apply(behind: Int, ahead: Int, upstream: String?, busy: Bool) {
        RedrawCounter.note("GitRemoteIconButtons")
        pull.toolTip = behind > 0 ? "Pull \(behind) new commits (fast-forward only)" : "Pull (fast-forward only)"
        push.toolTip = ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")" : "Push"
        pullCount.value = behind; pushCount.value = ahead
        for button in [fetch, pull, push] { button.isEnabled = !busy }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for (index, button) in [fetch, pull, push].enumerated() { button.frame = CGRect(x: CGFloat(index) * 28, y: 0, width: 26, height: 26) }
        // At the button's top trailing corner, 4 points out.
        for (badge, button) in [(pullCount, pull), (pushCount, push)] {
            let size = badge.intrinsicContentSize
            badge.frame = CGRect(x: button.frame.maxX - size.width + 4, y: button.frame.minY - 4, width: size.width, height: size.height)
        }
    }
}

/// A commit count on an accent capsule.
@MainActor final class GitCountBadge: NSView {
    var value = 0 { didSet { isHidden = value <= 0; invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var line: PiKit.Line { PiKit.Line("\(value)", font: .systemFont(ofSize: 9, weight: .bold), color: .piOnAccent) }
    override init(frame: NSRect) { super.init(frame: frame); isHidden = true }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { let size = line.size(scale: piScale); return NSSize(width: size.width + 8, height: size.height + 2) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.piAccent.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        line.draw(at: CGPoint(x: 4, y: 1), scale: piScale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

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
        @MainActor init(_ controller: GitController) {
            read = controller.statusRead; staged = controller.staged; unstaged = controller.unstaged; empty = controller.status.entries.isEmpty
            checked = controller.checked; selection = controller.selection
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
                          checked: next.checked.contains(entry.path))
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
        let paths = staged ? controller.stagedPaths : controller.unstagedPaths
        let all = paths.isSubset(of: inputs.checked)
        row.apply(title: title, all: all, mixed: !all && !paths.isDisjoint(with: inputs.checked),
                  actionTitle: staged ? "Unstage all" : "Stage all",
                  tick: {
                      if all { controller.checked.subtract(paths) } else { controller.checked.formUnion(paths) }
                  },
                  action: { if staged { Task { await controller.unstage(controller.staged.map(\.path)) } } else { Task { await controller.stage(controller.unstaged.map(\.path)) } } })
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

    init(controller: GitController, discard: @escaping @MainActor ([GitStatusEntry]) -> Void, glide: PiKit.SelectionGlide) {
        self.controller = controller; self.discard = discard
        row = PiKit.SelectableRow(content: content, glide: glide)
        super.init(frame: .zero)
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }

    func apply(entry: GitStatusEntry, staged: Bool, selected: Bool, checked: Bool) {
        if let shown, shown.entry == entry, shown.staged == staged, shown.selected == selected, shown.checked == checked { return }
        shown = (entry, staged, selected, checked)
        self.entry = entry; self.staged = staged
        RedrawCounter.note("GitFileRow")
        let controller = controller
        row.selected = selected
        row.onPress = { controller.selection = GitController.Selection(path: entry.path, staged: staged) }
        row.setAccessibilityIdentifier("git-file-" + entry.path)
        content.apply(entry: entry, staged: staged, checked: checked, controller: controller)
        row.setAccessibilityLabel(content.spokenText)
        row.setAccessibilityValue(entry.summary)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entry else { return nil }
        let staged = staged, controller = controller, discard = discard
        var entries: [PiMenuEntry] = [
            staged ? .button("Unstage") { Task { await controller.unstage([entry.path]) } } : .button("Stage") { Task { await controller.stage([entry.path]) } },
            .button(entry.untracked ? "Delete Untracked File…" : "Discard Changes…") { discard([entry]) },
            .divider,
        ]
        if !entry.untracked {
            entries.append(.button("Show History of This File", systemImage: "clock.arrow.circlepath", identifier: "git-file-history-" + entry.path) {
                controller.showFileHistory(entry.path)
            })
        }
        entries.append(.button("Reveal in Finder") {
            if let root = controller.repositoryRoot { NSWorkspace.shared.selectFile((root as NSString).appendingPathComponent(entry.path), inFileViewerRootedAtPath: root) }
        })
        entries.append(.button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) })
        return PiMenus.menu(entries)
    }

    static func badgeColor(_ badge: String) -> NSColor {
        switch badge { case "A", "U": .piSuccess; case "D": .piDanger; case "R", "C": .piInfo; default: .piBrandOrange }
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

    func apply(entry: GitStatusEntry, staged: Bool, checked: Bool, controller: GitController) {
        tick.setTick(on: checked, label: checked ? "Exclude \(entry.path) from the commit" : "Include \(entry.path) in the commit")
        tick.setAccessibilityIdentifier("git-check-" + entry.path)
        tick.onPress = { if checked { controller.checked.remove(entry.path) } else { controller.checked.insert(entry.path) } }
        badge.text = entry.badge; badge.color = GitFileRowView.badgeColor(entry.badge); badge.toolTip = entry.summary
        name.line.text = (entry.path as NSString).lastPathComponent
        folder.line.text = Self.folder(of: entry)
        stageButton.symbol = staged ? "minus" : "plus"
        stageButton.label = staged ? "Unstage \(entry.path)" : "Stage \(entry.path)"
        stageButton.onPress = { Task { if staged { await controller.unstage([entry.path]) } else { await controller.stage([entry.path]) } } }
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

/// The commit message, what the commit takes (the checked files or the staged
/// index, always said, never inferred), amend, discard all, Reword Last
/// Commit and the commit itself.
@MainActor final class GitCommitBox: NSView, PiKit.WidthSizing {
    struct Inputs: Equatable {
        var message: String, amend: Bool, scope: GitCommitScope, checkedCount: Int, stagedCount: Int, entries: Int, hasHead: Bool, loading: Bool, busy: Bool
        @MainActor init(_ controller: GitController) {
            message = controller.commitMessage; amend = controller.amend; scope = controller.commitScope; checkedCount = controller.checkedCount
            stagedCount = controller.staged.count; entries = controller.status.entries.count; hasHead = controller.status.head != nil
            loading = controller.loading; busy = controller.busy
        }
    }

    /// What the box shows and allows for these inputs: the action's name,
    /// whether it and Reword are armed, and the line saying what the active
    /// scope takes. Kept apart from the drawing so it can be checked whole.
    struct Presentation: Equatable {
        var title: String, commitEnabled: Bool, rewordEnabled: Bool, hint: String
    }
    static func presentation(_ inputs: Inputs) -> Presentation {
        let message = inputs.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = inputs.scope == .checkedFiles ? inputs.checkedCount > 0 : inputs.stagedCount > 0
        let idle = !inputs.loading && !inputs.busy
        let title = switch (inputs.scope, inputs.amend) {
        case (.checkedFiles, false): "Commit Checked Files"
        case (.checkedFiles, true): "Amend with Checked Files"
        case (.stagedChanges, false): "Commit Staged Changes"
        case (.stagedChanges, true): "Amend with Staged Changes"
        }
        let hint: String
        switch inputs.scope {
        case .checkedFiles where !content:
            hint = "Tick the files to commit. Their whole working-tree state is committed, not only staged hunks."
        case .stagedChanges where !content:
            hint = "Nothing is staged. Stage changes, or commit checked files instead."
        case _ where inputs.amend && !inputs.hasHead:
            hint = "There is no commit to amend yet."
        default:
            let what = inputs.scope == .checkedFiles
                ? "\(inputs.checkedCount) of \(inputs.entries) files · their whole working-tree state"
                : "\(inputs.stagedCount) staged \(inputs.stagedCount == 1 ? "file" : "files") · exactly as staged; unstaged edits stay"
            hint = message.isEmpty ? what + " · write a message to commit" : what
        }
        return Presentation(title: title, commitEnabled: content && !message.isEmpty && idle && (!inputs.amend || inputs.hasHead),
                            rewordEnabled: inputs.hasHead && !message.isEmpty && idle, hint: hint)
    }

    private let controller: GitController
    private let discard: @MainActor ([GitStatusEntry]) -> Void
    let message = GitMessageEditor()
    private let scopeTabs: PiKit.Tabs<GitCommitScope>
    private let amendTick = gitCheckbox(on: false, label: "Amend the last commit") {}
    private let amendLabel = PiKit.TextLine(PiKit.Line("Amend", font: PiKit.Font.caption, color: .piInkSecondary))
    private let reword = PlainTextButton("Reword Last Commit", font: PiKit.Font.micro, color: .piAccent)
    private let discardAll = PlainTextButton("Discard All…", font: PiKit.Font.micro, color: .piDanger)
    private let hint = TextBlock("", font: PiKit.Font.micro, color: .piInkTertiary, maximumLines: 3)
    private let commit = PiKit.Button("", symbol: "checkmark.circle", style: .primary, compact: true)
    private var inputs: Inputs?

    init(controller: GitController, inputs: Inputs, discard: @escaping @MainActor ([GitStatusEntry]) -> Void) {
        self.controller = controller; self.discard = discard
        scopeTabs = PiKit.Tabs(selection: inputs.scope, items: [(GitCommitScope.checkedFiles, "Checked files"), (.stagedChanges, "Staged changes")],
                               accessibilityName: "Commit scope") { [controller] in controller.commitScope = $0 }
        super.init(frame: .zero)
        scopeTabs.setAccessibilityIdentifier("git-commit-scope")
        message.field.setAccessibilityIdentifier("git-commit-message")
        message.onChange = { [controller] in controller.commitMessage = $0 }
        amendTick.setAccessibilityIdentifier("git-amend")
        amendTick.onPress = { [controller] in controller.amend.toggle() }
        amendLabel.toolTip = "Add this commit's content to the last commit and replace its message."
        reword.toolTip = "Change the last commit's message only. Its files, and your staged and unstaged changes, stay as they are."
        reword.setAccessibilityIdentifier("git-reword")
        reword.onPress = { [controller] in Task { await controller.rewordLastCommit() } }
        discardAll.setAccessibilityIdentifier("git-discard-all")
        discardAll.onPress = { [controller, discard] in discard(controller.status.entries) }
        hint.setAccessibilityIdentifier("git-commit-hint")
        commit.setAccessibilityIdentifier("git-commit")
        commit.onPress = { [controller] in Task { await controller.commitInScope() } }
        for view in [message, scopeTabs, amendTick, amendLabel, reword, discardAll, hint, commit] as [NSView] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        inputs = next
        RedrawCounter.note("GitCommitBox")
        let shown = Self.presentation(next)
        message.placeholder = next.amend ? "Amended commit message" : "Commit message"
        message.text = next.message
        scopeTabs.selection = next.scope
        amendTick.setTick(on: next.amend, label: "Amend the last commit")
        reword.line.color = shown.rewordEnabled ? .piAccent : .piInkTertiary
        reword.isEnabled = shown.rewordEnabled
        discardAll.isHidden = next.entries == 0
        hint.text = shown.hint
        commit.title = shown.title
        commit.isEnabled = shown.commitEnabled
        needsLayout = true
        if bounds.width > 0, height(forWidth: bounds.width) != bounds.height { PiKit.sizeChanged(self) }
    }

    private func amendRow() -> [StackLayout.Item] {
        var items: [StackLayout.Item] = [.fixed(amendTick), .line(amendLabel), .spacer(), .fixed(reword)]
        if !discardAll.isHidden { items.append(.fixed(discardAll)) }
        return items
    }
    private func heights(_ width: CGFloat) -> [CGFloat] {
        let inner = width - PiSpacing.md * 2
        return [message.height(forWidth: inner), scopeTabs.intrinsicContentSize.height,
                StackLayout.height(amendRow(), spacing: PiSpacing.sm, width: inner), hint.height(forWidth: inner), commit.intrinsicContentSize.height]
    }
    func height(forWidth width: CGFloat) -> CGFloat { heights(width).reduce(0, +) + PiSpacing.sm * 4 + PiSpacing.md * 2 }
    /// Its height with the message at its fewest lines.
    func minimumHeight(forWidth width: CGFloat) -> CGFloat {
        height(forWidth: width) - message.height(forWidth: width - PiSpacing.md * 2) + message.minimumHeight
    }
    override func layout() {
        super.layout()
        let inner = bounds.width - PiSpacing.md * 2, rows = heights(bounds.width), scale = piScale
        var y = PiSpacing.md
        message.frame = CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[0]); y += rows[0] + PiSpacing.sm
        let tabs = scopeTabs.intrinsicContentSize
        scopeTabs.frame = CGRect(x: PiSpacing.md, y: y, width: min(tabs.width, inner), height: rows[1]); y += rows[1] + PiSpacing.sm
        StackLayout.place(amendRow(), spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[2]), scale: scale); y += rows[2] + PiSpacing.sm
        hint.frame = CGRect(x: PiSpacing.md, y: y, width: inner, height: rows[3]); y += rows[3] + PiSpacing.sm
        let size = commit.intrinsicContentSize
        commit.frame = CGRect(x: PiSpacing.md + inner - size.width, y: y, width: size.width, height: size.height)
    }
}

/// The commit message: a plain field on an inset surface that wraps, two to
/// five lines tall, scrolling past five (`TextField(axis: .vertical)` with
/// `lineLimit(2...5)`, 8 points of padding).
@MainActor final class GitMessageEditor: NSView, PiKit.WidthSizing, NSTextFieldDelegate {
    let field = NSTextField()
    private let box = PiKit.inset(NSView())
    var onChange: ((String) -> Void)?
    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { if field.placeholderString != newValue { field.placeholderString = newValue } }
    }
    static let minimumLines = 2, maximumLines = 5
    override init(frame: NSRect) {
        super.init(frame: frame)
        PiKit.configurePlain(field, font: PiKit.Font.body, placeholder: "Commit message")
        field.usesSingleLineMode = false
        field.cell?.wraps = true; field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.delegate = self
        addSubview(box)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func controlTextDidChange(_ notification: Notification) {
        // The box measures its height again when the controller has the text.
        onChange?(field.stringValue)
    }
    private var lineHeight: CGFloat { PiKit.Line("", font: PiKit.Font.body, color: .black).lineHeight }
    /// The lines the text takes at this width, from two to five.
    func lines(forWidth width: CGFloat) -> Int {
        let inner = max(1, width - PiSpacing.sm * 2)
        let paragraphs = field.stringValue.components(separatedBy: "\n")
        let count = paragraphs.reduce(0) { $0 + PiKit.wrappedLines($1, font: PiKit.Font.body, width: inner).count }
        return min(Self.maximumLines, max(Self.minimumLines, count))
    }
    func height(forWidth width: CGFloat) -> CGFloat { CGFloat(lines(forWidth: width)) * lineHeight + PiSpacing.sm * 2 }
    var minimumHeight: CGFloat { CGFloat(Self.minimumLines) * lineHeight + PiSpacing.sm * 2 }
    override func layout() {
        super.layout()
        box.frame = bounds
        field.frame = CGRect(x: PiSpacing.sm - PiKit.fieldInset, y: PiSpacing.sm, width: max(0, bounds.width - PiSpacing.sm * 2) + PiKit.fieldInset * 2,
                             height: max(0, bounds.height - PiSpacing.sm * 2))
    }
}

// MARK: - History

/// The filters and the commits, newest first.
@MainActor final class GitHistoryList: NSView {
    struct Inputs: Equatable {
        var filter: GitLogFilter, commits: [GitCommit], selected: GitCommit?, exhausted: Bool, loading: Bool
        @MainActor init(_ controller: GitController) {
            filter = controller.logFilter; commits = controller.commits; selected = controller.selectedCommit
            exhausted = controller.historyExhausted; loading = controller.loading
        }
    }
    private enum Row: Hashable { case empty, commit(String), more }
    private let controller: GitController
    private let filterField: PiKit.TextField
    private let authorField: PiKit.TextField
    private let allBranches = gitCheckbox(on: false, label: "Show all branches") {}
    private let allBranchesLabel = PiKit.TextLine(PiKit.Line("All branches", font: PiKit.Font.caption, color: .piInkSecondary))
    private let pathChip = GitHistoryPathChip()
    private let rule = HairlineView()
    let list = LazyStackView()
    private var inputs: Inputs?
    private let glide = PiKit.SelectionGlide()

    init(controller: GitController) {
        self.controller = controller
        filterField = PiKit.TextField(placeholder: "Filter by message or hash", icon: "magnifyingglass") { [controller] in controller.logFilter.text = $0 }
        authorField = PiKit.TextField(placeholder: "Author", icon: "person") { [controller] in controller.logFilter.author = $0 }
        super.init(frame: .zero)
        filterField.setAccessibilityIdentifier("git-history-filter")
        allBranches.onPress = { [controller] in controller.logFilter.allBranches.toggle() }
        pathChip.clear = { [controller] in controller.clearFileHistory() }
        list.spacing = 2
        list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
        for view in [filterField, authorField, allBranches, allBranchesLabel, pathChip, rule, list] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        let previous = inputs
        inputs = next
        RedrawCounter.note("GitHistoryList")
        filterField.text = next.filter.text
        authorField.text = next.filter.author
        allBranches.setTick(on: next.filter.allBranches, label: "Show all branches")
        pathChip.isHidden = next.filter.path == nil
        if let path = next.filter.path { pathChip.path = path }
        if previous?.filter.path != next.filter.path { needsLayout = true }
        var rows: [Row] = []
        if next.commits.isEmpty && !next.loading { rows.append(.empty) }
        rows += next.commits.map { .commit($0.hash) }
        if !next.exhausted && !next.commits.isEmpty { rows.append(.more) }
        let commits = Dictionary(next.commits.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        let filtered = next.filter.path != nil, empty = next.filter == GitLogFilter() ? "No commits yet." : "No commits match the filter."
        let controller = controller, glide = glide
        // The same commits in the same order: their heights stand, and only
        // the rows in view take the new state (a selection, a keystroke in a filter).
        let sameRows = rows == self.rows && previous?.commits == next.commits
        self.rows = rows
        let source = LazyStackView.Source(count: rows.count, key: { [rows] in AnyHashable(rows[$0]) }, height: { [weak self, rows] index, width in
            switch rows[index] {
            case .empty: return GitEmptyRow.height
            case .more: return GitLoadMoreRow.height
            case .commit(let hash): return commits[hash].map { self?.height(of: $0, width: width) ?? 0 } ?? 0
            }
        }, view: { [rows] index, existing in
            switch rows[index] {
            case .empty:
                let row = existing as? GitEmptyRow ?? GitEmptyRow(empty)
                row.text = empty
                return row
            case .more: return existing ?? GitLoadMoreRow { Task { await controller.loadMoreHistory() } }
            case .commit(let hash):
                guard let commit = commits[hash] else { return existing ?? NSView() }
                let row = existing as? GitCommitRowView ?? GitCommitRowView(controller: controller, glide: glide)
                row.apply(commit: commit, selected: next.selected == commit, filtered: filtered)
                return row
            }
        })
        if sameRows { list.update(source) } else { list.reload(source) }
    }
    private var rows: [Row] = []
    /// Each commit's row height, measured once a width.
    /// By what the height depends on: the subject and the refs.
    private var heights: [HeightKey: CGFloat] = [:]
    private struct HeightKey: Hashable { let subject: String, refs: [String] }
    private var heightsWidth: CGFloat = -1
    private func height(of commit: GitCommit, width: CGFloat) -> CGFloat {
        if width != heightsWidth { heights = [:]; heightsWidth = width }
        let key = HeightKey(subject: commit.subject, refs: commit.refs)
        if let known = heights[key] { return known }
        let measured = GitCommitRowView.height(of: commit, width: width)
        heights[key] = measured
        return measured
    }

    private var filterHeights: (field: CGFloat, author: CGFloat, chip: CGFloat) {
        (filterField.intrinsicContentSize.height, max(authorField.intrinsicContentSize.height, 18, allBranchesLabel.intrinsicContentSize.height),
         pathChip.isHidden ? 0 : pathChip.intrinsicContentSize.height)
    }
    /// The filters and the rule: what the side keeps however short it is.
    func fixedHeight(forWidth width: CGFloat) -> CGFloat {
        let heights = filterHeights
        return PiSpacing.sm * 2 + heights.field + PiSpacing.xs + heights.author + (pathChip.isHidden ? 0 : PiSpacing.xs + heights.chip) + 1
    }
    override func layout() {
        super.layout()
        let width = bounds.width, inner = width - PiSpacing.sm * 2, heights = filterHeights, scale = piScale
        var y = PiSpacing.sm
        filterField.frame = CGRect(x: PiSpacing.sm, y: y, width: inner, height: heights.field); y += heights.field + PiSpacing.xs
        StackLayout.place([.view(authorField, .flexible(height: { [authorField] _ in authorField.intrinsicContentSize.height })), .fixed(allBranches), .fixed(allBranchesLabel)],
                          spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.sm, y: y, width: inner, height: heights.author), scale: scale)
        y += heights.author
        if !pathChip.isHidden { y += PiSpacing.xs; pathChip.frame = CGRect(x: PiSpacing.sm, y: y, width: inner, height: heights.chip); y += heights.chip }
        y += PiSpacing.sm
        rule.frame = CGRect(x: 0, y: y, width: width, height: 1)
        list.frame = CGRect(x: 0, y: y + 1, width: width, height: max(0, bounds.height - y - 1))
    }
}

/// The file the history follows, and All files.
@MainActor final class GitHistoryPathChip: NSView {
    var path = "" { didSet { name.line.text = (path as NSString).lastPathComponent; name.toolTip = path; needsLayout = true } }
    var clear: (() -> Void)?
    private let symbol = PiKit.SymbolView(PiKit.Symbol("clock.arrow.circlepath", size: 10), color: .piAccent)
    private let name = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInk))
    private let note = PiKit.TextLine(PiKit.Line("history · follows renames", font: PiKit.Font.micro, color: .piInkTertiary))
    private let allFiles = PiKit.Button("All files", style: .ghost)
    private let fill = PiKit.Box(fill: .piAccentSoft, cornerRadius: PiRadius.sm)
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.truncation = .middle
        allFiles.setAccessibilityIdentifier("git-history-all-files")
        allFiles.onPress = { [weak self] in self?.clear?() }
        for view in [fill, symbol, name, note, allFiles] as [NSView] { addSubview(view) }
        setAccessibilityElement(false); setAccessibilityIdentifier("git-history-path")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var items: [StackLayout.Item] { [.fixed(symbol), .line(name), .line(note), .spacer(2), .fixed(allFiles)] }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: StackLayout.height(items, spacing: 6, width: .infinity) + 8)
    }
    override func layout() {
        super.layout()
        fill.frame = bounds
        StackLayout.place(items, spacing: 6, in: bounds.insetBy(dx: PiSpacing.sm, dy: 4), scale: piScale)
    }
}

/// "Load older commits".
@MainActor final class GitLoadMoreRow: NSView {
    private let button = PiKit.Button("Load older commits", style: .ghost)
    static var height: CGFloat { PiKit.Button("Load older commits", style: .ghost).intrinsicContentSize.height + PiSpacing.sm * 2 }
    init(_ action: @escaping () -> Void) {
        super.init(frame: .zero)
        button.onPress = action
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: PiSpacing.sm, y: PiSpacing.sm, width: size.width, height: size.height)
    }
}

/// One commit: its subject, its refs, its hash, author and age.
@MainActor final class GitCommitRowView: NSView {
    private let controller: GitController
    private let content = GitCommitRowContent()
    let row: PiKit.SelectableRow
    private var shown: (commit: GitCommit, selected: Bool, filtered: Bool)?
    init(controller: GitController, glide: PiKit.SelectionGlide) {
        self.controller = controller
        row = PiKit.SelectableRow(content: content, glide: glide)
        super.init(frame: .zero)
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); row.frame = bounds }
    static func height(of commit: GitCommit, width: CGFloat) -> CGFloat {
        let padding = PiKit.SelectableRow.padding
        return GitCommitRowContent.height(of: commit, width: width - padding.left - padding.right) + padding.top + padding.bottom
    }
    func apply(commit: GitCommit, selected: Bool, filtered: Bool) {
        if let shown, shown.commit == commit, shown.selected == selected, shown.filtered == filtered { return }
        shown = (commit, selected, filtered)
        RedrawCounter.note("GitCommitRow")
        let controller = controller
        row.selected = selected
        row.onPress = { controller.selectedCommit = commit }
        row.setAccessibilityIdentifier("git-commit-" + commit.shortHash)
        content.apply(commit)
        row.setAccessibilityLabel(content.spokenText)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shown else { return nil }
        let commit = shown.commit, controller = controller
        var entries: [PiMenuEntry] = [
            .button("Copy Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) },
            .button("Copy Subject") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) },
        ]
        if shown.filtered {
            entries.append(.divider)
            entries.append(.button("Show All Files Again", systemImage: "clock.arrow.circlepath") { controller.clearFileHistory() })
        }
        return PiMenus.menu(entries)
    }
}

/// A commit row's content: the subject (two lines at most), the refs as
/// badges, and the hash, author and age.
@MainActor final class GitCommitRowContent: NSView {
    private let subject = TextBlock("", font: PiKit.Font.body, color: .piInk, maximumLines: 2)
    private let refs = PiKit.FlowView()
    private let hashLine = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.mono, color: .piAccent))
    private let author = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    private let date = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    private let merge = PiKit.SymbolView(PiKit.Symbol("arrow.triangle.merge", size: 10.5, weight: .medium), color: .piInkTertiary)
    private var commit: GitCommit?
    override init(frame: NSRect) {
        super.init(frame: frame)
        refs.spacing = 4; refs.rowSpacing = 4
        merge.toolTip = "Merge commit"
        for view in [subject, refs, hashLine, author, date, merge] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    var spokenText: String { [subject.text, hashLine.line.text, author.line.text, date.line.text].joined(separator: ", ") }

    static func refBadge(_ ref: String) -> PiKit.Badge {
        PiKit.Badge(text: ref.replacingOccurrences(of: "HEAD -> ", with: ""), tone: ref.hasPrefix("HEAD") ? .accent : ref.hasPrefix("tag: ") ? .warning : .info,
                    icon: ref.hasPrefix("tag: ") ? "tag" : ref.hasPrefix("HEAD") ? "location" : nil)
    }
    func apply(_ commit: GitCommit) {
        let refsChanged = self.commit?.refs != commit.refs
        self.commit = commit
        subject.text = commit.subject
        if refsChanged {
            refs.subviews.forEach { $0.removeFromSuperview() }
            for ref in commit.refs { refs.addSubview(Self.refBadge(ref)) }
        }
        refs.isHidden = commit.refs.isEmpty
        hashLine.line.text = commit.shortHash
        author.line.text = commit.author
        date.line.text = commit.date.formatted(.relative(presentation: .named))
        merge.isHidden = commit.parents.count <= 1
        needsLayout = true
    }
    private static let flowProbe = PiKit.FlowView()
    /// Its height at `width`, without a view: the subject's lines, the refs' rows and the meta line.
    static func height(of commit: GitCommit, width: CGFloat) -> CGFloat {
        let subject = CGFloat(min(2, PiKit.wrappedLines(commit.subject, font: PiKit.Font.body, width: width).count)) * PiKit.Line("", font: PiKit.Font.body, color: .black).lineHeight
        var height = subject
        if !commit.refs.isEmpty {
            let flow = flowProbe
            flow.spacing = 4; flow.rowSpacing = 4
            flow.subviews.forEach { $0.removeFromSuperview() }
            for ref in commit.refs { flow.addSubview(refBadge(ref)) }
            height += 3 + flow.height(forWidth: width)
        }
        return height + 3 + metaHeight
    }
    private static var metaHeight: CGFloat {
        max(PiKit.Line("", font: PiKit.Font.mono, color: .black).lineHeight, PiKit.Line("", font: PiKit.Font.micro, color: .black).lineHeight)
    }
    private var metaItems: [StackLayout.Item] {
        var items: [StackLayout.Item] = [.fixed(hashLine), .line(author), .line(date)]
        if !merge.isHidden { items.append(.fixed(merge)) }
        return items
    }
    override func layout() {
        super.layout()
        let width = bounds.width, scale = piScale
        let subjectHeight = subject.height(forWidth: width)
        subject.frame = CGRect(x: 0, y: 0, width: width, height: subjectHeight)
        var y = subjectHeight + 3
        if !refs.isHidden {
            let height = refs.height(forWidth: width)
            refs.frame = CGRect(x: 0, y: y, width: width, height: height); y += height + 3
        }
        let meta = Self.metaHeight
        let frames = StackLayout.widths(metaItems, spacing: 6, proposal: width)
        let row = CGRect(x: 0, y: y, width: width, height: meta)
        _ = frames
        StackLayout.place(metaItems, spacing: 6, in: row, scale: scale)
    }
}

// MARK: - Detail

/// The selected file's diff, or the selected commit: its header, its file
/// chips and its diff.
@MainActor final class GitPanelDetail: NSView {
    struct Inputs: Equatable {
        var panel: GitController.Panel, selection: GitController.Selection?, diff: GitDiffArray, diffLoading: Bool
        var commit: String?, detailFiles: Int, detailFile: String?, filesShown: Int
        var detailDiff: GitDiffArray, detailFileDiff: GitDiffArray, commitLoading: Bool, deferred: Bool
        var reveal: GitHistoryReveal?, revealNote: String?
        @MainActor init(_ controller: GitController) {
            reveal = controller.revealTarget; revealNote = controller.revealNote
            panel = controller.panel; selection = controller.selection; diff = GitDiffArray(controller.diff); diffLoading = controller.diffLoading
            commit = controller.detail?.commit.hash; detailFiles = controller.detail?.files.count ?? 0
            detailFile = controller.detailFile; filesShown = controller.commitFilesShown
            detailDiff = GitDiffArray(controller.detailDiff); detailFileDiff = GitDiffArray(controller.detailFileDiff)
            commitLoading = controller.commitLoading; deferred = controller.detailDiffDeferred
        }
    }
    private let controller: GitController
    private let openFile: ((String, Int) -> Void)?
    private var inputs: Inputs?
    /// The working tree's diff and a commit's: each keeps its own wrap.
    private var changesDiff = DiffView()
    private var commitDiff = DiffView()
    private let placeholder = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let header = GitCommitHeader()
    private let deferredView = GitDeferredCommit()
    private enum Mode { case changes, commit, deferred, placeholder, none }
    private var mode = Mode.none

    init(controller: GitController, openFile: ((String, Int) -> Void)?) {
        self.controller = controller; self.openFile = openFile
        super.init(frame: .zero)
        header.select = { [controller] in controller.detailFile = $0 }
        header.showMore = { [controller] in controller.commitFilesShown += GitController.commitFilesStep }
        header.showHistory = { [controller] in controller.showFileHistory($0) }
        deferredView.load = { [controller] in controller.loadDeferredCommitDiff() }
        for view in [placeholder, deferredView] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs) {
        guard next != inputs else { return }
        inputs = next
        RedrawCounter.note("GitPanelDetail")
        show(next)
    }
    /// Unified or split, or the whole diff asked for: only the diff shows it.
    func presentationChanged() { if let inputs { show(inputs) } }

    private func show(_ inputs: Inputs) {
        let controller = controller, presentation = controller.presentation
        let setSplit: (Bool) -> Void = { presentation.split = $0 }
        let setExpanded: (String?) -> Void = { presentation.whole = $0 }
        if inputs.panel == .changes {
            if let selection = inputs.selection {
                setMode(.changes)
                changesDiff.show(files: inputs.diff.files, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index",
                                 identity: GitController.diffIdentity(path: selection.path, staged: selection.staged), loading: inputs.diffLoading,
                                 split: presentation.split, setSplit: setSplit, expanded: presentation.whole, setExpanded: setExpanded, openFile: openFile)
            } else {
                showPlaceholder("Select a file to see its changes.")
            }
        } else if let detail = controller.detail {
            if inputs.deferred {
                setMode(.deferred)
                header.show(detail, note: nil, selected: inputs.detailFile, shown: inputs.filesShown)
                deferredView.show(header: header, summary: detail.summary)
            } else {
                setMode(.commit)
                let file = inputs.detailFile
                let files = file == nil ? inputs.detailDiff.files : inputs.detailFileDiff.files
                let note = inputs.revealNote
                header.show(detail, note: note, selected: file, shown: inputs.filesShown)
                let leadKey = CommitHeaderKey(commit: detail.commit.hash, files: detail.files.count, selected: file, shown: inputs.filesShown, note: note)
                let identity = GitController.diffIdentity(commit: detail.commit.hash, file: file)
                // The line a blame click asked for, once its commit and file
                // are the ones shown.
                let reveal = inputs.reveal.flatMap { asked -> GitDiffReveal? in
                    guard asked.target.commit == detail.commit.hash, asked.target.path == file else { return nil }
                    return GitDiffReveal(identity: identity, path: asked.target.path, line: asked.target.line, token: asked.token)
                }
                commitDiff.show(files: files, title: file, subtitle: file == nil ? nil : "In \(detail.commit.shortHash)", identity: identity,
                                loading: inputs.commitLoading, embedded: true, lead: header, leadKey: leadKey, split: presentation.split,
                                setSplit: setSplit, expanded: presentation.whole, setExpanded: setExpanded, openFile: openFile,
                                reveal: reveal, revealed: { controller.revealed($0, $1) })
            }
        } else if inputs.commitLoading {
            showPlaceholder("Loading…")
        } else {
            showPlaceholder("Select a commit to see what it changed.")
        }
    }
    /// What the commit header's height depends on, besides the width.
    private struct CommitHeaderKey: Hashable { let commit: String, files: Int, selected: String?, shown: Int, note: String? }

    private func showPlaceholder(_ text: String) {
        placeholder.line.text = text
        setMode(.placeholder)
    }
    /// Only what shows is in the panel. A diff that leaves is let go of and
    /// comes back new, as SwiftUI made it again: unwrapped, at its top,
    /// nothing selected.
    private func setMode(_ next: Mode) {
        guard next != mode else { return }
        let previous = mode
        mode = next
        if previous == .changes, next != .changes { changesDiff.table.close(); changesDiff.removeFromSuperview(); changesDiff = DiffView() }
        if previous == .commit, next != .commit { commitDiff.table.close(); commitDiff.removeFromSuperview(); commitDiff = DiffView() }
        if next == .changes { addSubview(changesDiff) }
        if next == .commit { addSubview(commitDiff) }
        deferredView.isHidden = next != .deferred
        placeholder.isHidden = next != .placeholder
        needsLayout = true
    }
    override func layout() {
        super.layout()
        changesDiff.frame = bounds; commitDiff.frame = bounds; deferredView.frame = bounds
        let size = placeholder.intrinsicContentSize
        placeholder.frame = CGRect(x: PiKit.round((bounds.width - min(size.width, bounds.width)) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                                   width: min(size.width, bounds.width), height: size.height)
    }
}

/// A commit's subject, author, date and hash, the rest of its message, what
/// it changed, and its files as chips: above its diff, scrolling with it.
@MainActor final class GitCommitHeader: NSView, PiKit.WidthSizing {
    private let subject = TextBlock("", font: PiKit.Font.title(17), color: .piInk)
    private let meta = PiKit.SelectableText("", font: PiKit.Font.micro, color: .piInkTertiary)
    private let body = PiKit.SelectableText("", font: PiKit.Font.body, color: .piInkSecondary)
    private let mergeBadge = PiKit.Badge(text: "Merge · first parent", tone: .info, icon: "arrow.triangle.merge")
    private let note = WrappingLabelView(font: PiKit.Font.caption, color: .piInkSecondary, symbol: "info.circle")
    private let summary = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkSecondary))
    private let summaryMerge = PiKit.Badge(text: "Merge · first parent", tone: .info, icon: "arrow.triangle.merge")
    private let summaryRow = NSView()
    let chips = GitFileChipsView()
    var select: ((String?) -> Void)?
    var showMore: (() -> Void)?
    var showHistory: ((String) -> Void)?
    private var hasBody = false, hasNote = false, hasFiles = false, mergeAlone = false, merge = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        note.setAccessibilityIdentifier("git-reveal-note")
        summaryRow.setAccessibilityElement(false); summaryRow.setAccessibilityIdentifier("git-commit-summary")
        summaryRow.addSubview(summary); summaryRow.addSubview(summaryMerge)
        for view in [subject, meta, body, mergeBadge, note, summaryRow, chips] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func show(_ detail: GitCommitDetail, note: String?, selected: String?, shown: Int) {
        subject.text = detail.commit.subject
        meta.set("\(detail.commit.author) · \(detail.commit.date.formatted(date: .abbreviated, time: .shortened)) · \(detail.commit.hash)")
        hasBody = detail.message.contains("\n")
        if hasBody {
            body.set(detail.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        body.isHidden = !hasBody
        merge = detail.commit.parents.count > 1
        // A merge says what it is compared with even when that shows nothing.
        mergeAlone = merge && detail.files.isEmpty
        mergeBadge.isHidden = !mergeAlone
        hasNote = note != nil
        self.note.text = note ?? ""; self.note.isHidden = !hasNote
        hasFiles = !detail.files.isEmpty
        summaryRow.isHidden = !hasFiles; chips.isHidden = !hasFiles
        summary.line.text = detail.summary
        summaryMerge.isHidden = !merge
        if hasFiles {
            GitCommitFileChips.show(detail, selected: selected, shown: shown, in: chips,
                                    select: { [weak self] in self?.select?($0) }, showMore: { [weak self] in self?.showMore?() },
                                    showHistory: { [weak self] in self?.showHistory?($0) })
        }
        needsLayout = true
    }

    private func parts(_ width: CGFloat) -> [(NSView, CGFloat, CGFloat)] {
        let inner = max(0, width - PiSpacing.lg * 2)
        var parts: [(NSView, CGFloat, CGFloat)] = [(subject, inner, subject.height(forWidth: inner)), (meta, inner, meta.height(forWidth: inner))]
        if hasBody { parts.append((body, inner, body.height(forWidth: inner))) }
        if mergeAlone { let size = mergeBadge.intrinsicContentSize; parts.append((mergeBadge, size.width, size.height)) }
        if hasNote { parts.append((note, inner, note.height(forWidth: inner))) }
        if hasFiles {
            let row = max(summary.intrinsicContentSize.height, merge ? summaryMerge.intrinsicContentSize.height : 0)
            parts.append((summaryRow, inner, row))
            parts.append((chips, inner, chips.height(forWidth: inner)))
        }
        return parts
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let list = parts(width)
        return PiSpacing.lg + list.reduce(0) { $0 + $1.2 } + 4 * CGFloat(max(0, list.count - 1))
    }
    override func layout() {
        super.layout()
        var y = PiSpacing.lg
        for (view, width, height) in parts(bounds.width) {
            if view === meta || view === body {
                (view as? PiKit.SelectableText)?.frame = CGRect(x: PiSpacing.lg - PiKit.fieldInset, y: y, width: width + PiKit.fieldInset * 2, height: height)
            } else {
                view.frame = CGRect(x: PiSpacing.lg, y: y, width: width, height: height)
            }
            y += height + 4
        }
        if hasFiles {
            var items: [StackLayout.Item] = [.line(summary)]
            if merge { items.append(.fixed(summaryMerge)) }
            StackLayout.place(items, spacing: 8, in: summaryRow.bounds, scale: piScale)
        }
    }
}

/// A commit too large to show at once: its header, and the whole diff on request.
@MainActor final class GitDeferredCommit: NSView {
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private weak var header: GitCommitHeader?
    private let text = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let button = PiKit.Button("Show the whole diff", style: .secondary, compact: true)
    var load: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = document
        button.setAccessibilityIdentifier("git-commit-load-diff")
        button.onPress = { [weak self] in self?.load?() }
        document.addSubview(text); document.addSubview(button)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func show(header: GitCommitHeader, summary: String) {
        if header.superview !== document { header.removeFromSuperview(); document.addSubview(header) }
        self.header = header
        text.text = "This commit changes \(summary). Its files are listed above; open one to read its diff."
        needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentView.bounds.width
        var y: CGFloat = 0
        if let header, header.superview === document {
            let height = header.height(forWidth: width)
            header.frame = CGRect(x: 0, y: 0, width: width, height: height); y = height + PiSpacing.md
        }
        let inner = max(0, width - PiSpacing.lg * 2)
        let textHeight = text.height(forWidth: inner)
        text.frame = CGRect(x: PiSpacing.lg, y: y, width: inner, height: textHeight); y += textHeight + 6
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: PiSpacing.lg, y: y, width: size.width, height: size.height); y += size.height
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentView.bounds.height))
    }
}

/// A plain flipped container.
@MainActor final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A diff compared as the controller publishes it: a new array for every
/// read. Comparing the lines would walk them all.
struct GitDiffArray: Equatable {
    let files: [GitDiffFile]
    init(_ files: [GitDiffFile]) { self.files = files }
    static func == (a: Self, b: Self) -> Bool {
        a.files.withUnsafeBufferPointer { x in b.files.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress && x.count == y.count } }
    }
}

/// The one irreversible action in the panel, and the question it asks first.
/// It goes on a sheet over the panel through the app's single sheet-question
/// mechanism, so a second right-click while it is up is dropped rather than
/// stacked and nothing stops the main thread.
@MainActor enum GitDiscard {
    /// The question, up; nil when none was asked (nothing to discard, no
    /// window, or a question of this asker's already up).
    @discardableResult
    static func ask(_ questions: PiQuestion, discarding entries: [GitStatusEntry], in window: NSWindow?,
                    then act: @escaping ([GitStatusEntry]) -> Void) -> GitDiscardQuestion? {
        guard !entries.isEmpty, let window else { return nil }
        let alert = alert(for: entries), question = GitDiscardQuestion(alert: alert)
        let asked = questions.ask(alert, over: window) { [question] response in
            guard response == .alertFirstButtonReturn, !question.cancelled else { return }
            act(entries)
        }
        return asked ? question : nil
    }

    static func alert(for entries: [GitStatusEntry]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = entries.count == 1 ? "Discard changes to \((entries[0].path as NSString).lastPathComponent)?" : "Discard changes to \(entries.count) files?"
        alert.informativeText = "Tracked files revert to HEAD and untracked files are deleted. Git keeps no copy of these changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

/// A discard question that is up. Taken down unanswered when the panel it is
/// about is hidden, moves or closes: nothing is discarded, whatever is
/// pressed after.
@MainActor final class GitDiscardQuestion {
    private let alert: NSAlert
    private(set) var cancelled = false
    init(alert: NSAlert) { self.alert = alert }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
    }
}

/// Where a panel is: the view of its that is in a window, read when asked,
/// and the discard question it has up.
@MainActor final class GitPanelPlace {
    /// The panel's view that is in a window (`GitPanelProbe`).
    weak var probe: NSView?
    /// The window the panel is in now.
    var window: NSWindow? { probe?.window }
    private(set) var question: GitDiscardQuestion?
    /// Asks, over the window the panel is in now (not the one it was in when
    /// last told: a tab moves between windows). A request refused because a
    /// question is already up keeps that question as the one to take down.
    func askToDiscard(_ entries: [GitStatusEntry], questions: PiQuestion, then act: @escaping ([GitStatusEntry]) -> Void) {
        if let asked = GitDiscard.ask(questions, discarding: entries, in: window, then: act) { question = asked }
    }
    func cancelQuestion() { question?.cancel(); question = nil }
}

/// Says whether the panel is on screen: in a window and not hidden there,
/// neither itself nor anything it is in (another tab shown over it, the
/// report over the tabs). Told on the next turn of the run loop, once for
/// whatever moved in between, and only when it changes: a tab moving between
/// windows leaves one and joins another in the same turn.
@MainActor final class GitPanelProbe: NSView {
    var shown: ((Bool) -> Void)?
    /// On screen before and after, but in another window: a question the
    /// panel had up is on the window it left.
    var moved: (() -> Void)?
    private var told: Bool?
    /// The window it was on screen in, when last told.
    private weak var toldWindow: NSWindow?
    private var scheduled = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); check() }
    override func viewDidHide() { super.viewDidHide(); check() }
    override func viewDidUnhide() { super.viewDidUnhide(); check() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// On screen now: in a window, and neither it nor anything it is in hidden.
    var onScreen: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    func check() {
        guard !scheduled else { return }
        scheduled = true
        // Held until told: a panel taken down and let go of in the same turn
        // still says it is no longer on screen.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                self.scheduled = false
                let now = self.onScreen, window = now ? self.window : nil
                defer { self.toldWindow = window }
                if now, self.told == true, let before = self.toldWindow, before !== window { self.moved?() }
                guard now != self.told else { return }
                self.told = now
                self.shown?(now)
            }
        }
    }
}
