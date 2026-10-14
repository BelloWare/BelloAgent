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

    let panelBackground = GitPanelBackground()
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
            let context = controller.repositoryContext
            guard controller.accepts(context) else { return }
            place.askToDiscard(entries, questions: questions) { entries in
                guard controller.accepts(context) else { return }
                Task { await controller.discard(entries, context: context) }
            }
        }
        changesList = GitChangesList(controller: controller, discard: discard, observeFileRow: observeFileRow)
        commitBox = GitCommitBox(controller: controller, inputs: GitCommitBox.Inputs(controller), discard: discard,
                                 operation: { context, reword in place.requestCommit(controller, context: context, reword: reword, questions: questions) })
        history = GitHistoryList(controller: controller)
        detail = GitPanelDetail(controller: controller, openFile: openFile)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [panelBackground, probe, header, toolbar, toolbarRule, notRepository, changesList, changesRule, commitBox, history, splitRule, detail] as [NSView] {
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
        // A stack keeps the folder symbol and fixed controls even where
        // their minimum exceeds the pane. Only the toolbar overflows; the
        // history and detail still receive the pane's actual allocation.
        toolbar.layoutProposalWidth = width
        let toolbarWidth = toolbar.width(forProposal: width)
        let toolbarHeight = toolbar.height(forWidth: width)
        // The released stack's background covered its overflowing toolbar's
        // full width, while the header, history and detail kept the proposal.
        let backgroundWidth = max(width, toolbarWidth)
        panelBackground.frame = CGRect(x: (width - backgroundWidth) / 2, y: 0, width: backgroundWidth, height: bounds.height)
        toolbar.frame = CGRect(x: (width - toolbarWidth) / 2, y: 32, width: toolbarWidth, height: toolbarHeight)
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
            // Keep the full draft and its actions. Prefer three changelist
            // rows, but let those scroll before taking the diff's useful
            // height. Keep one section and file whole while space allows.
            let available = max(0, body.height - 1)
            let fixed = changes ? 1 + commitBox.height(forWidth: body.width) : history.fixedHeight(forWidth: body.width)
            let least = changes ? min(fixed + GitPanelSplit.leastRows, max(fixed + changesList.minimumRowsHeight, available - GitPanelSplit.preferredDetailHeight))
                : fixed + GitPanelSplit.leastRows
            let height = GitPanelSplit.listHeight(available: available, least: least)
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

/// Paint only: extending the surface must not intercept neighboring controls.
@MainActor final class GitPanelBackground: FillView {
    init() {
        super.init(.piContent)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The list and the diff: side by side where the panel is wide, the list
/// 340 points wide; where it is narrow (the pane beside the chat), the list
/// above the diff, both the panel's width. The same views either way, so
/// the diff table, the lists and what they hold (the wrap, where they were
/// scrolled) stay as they were when the panel's width crosses the line.
enum GitPanelSplit {
    static let listWidth: CGFloat = 340
    static let preferredDetailHeight: CGFloat = 180
    /// Narrow: how tall the list side is, of the `available` height (the
    /// panel's less the rule): 45% of it, never less than the side needs
    /// (`least`: its commit box or filters, and a few rows), and leaving the
    /// diff 180 points where that allows; at most all there is.
    static func listHeight(available: CGFloat, least: CGFloat) -> CGFloat {
        min(max((available * 0.45).rounded(), least), max(available - preferredDetailHeight, least), available)
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

/// The single-root folder caption keeps the natural width of its truncated
/// text, as the released Label did. Its compressed first grapheme is retained
/// even where there is not enough room for an ellipsis.
@MainActor private final class GitRootCaption: NSView {
    var line = PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary) {
        didSet {
            source = nil; ellipsis = nil; knownCuts.removeAll(keepingCapacity: true); placedPlan = nil
            invalidateIntrinsicContentSize(); needsDisplay = true
            setAccessibilityLabel(line.text)
        }
    }
    private var source: CTLine?, ellipsis: CTLine?
    private enum CaptionCut {
        case prefix
        case pieces([String], CGFloat)
        case rightToLeft(CTLine, CGFloat)
        var width: CGFloat? {
            switch self { case .prefix: nil; case .pieces(_, let width), .rightToLeft(_, let width): width }
        }
    }
    private var knownCuts: [CGFloat: CaptionCut] = [:]
    private struct CaptionPlan { var width: CGFloat; var cut: CaptionCut? }
    private var placedPlan: CaptionPlan?
    private var glyph: PiKit.Symbol { PiKit.Symbol("folder", size: line.font.pointSize, weight: line.font.piWeight) }
    var symbolWidth: CGFloat { glyph.layoutSize.width + LabelView.spacing }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(line.text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale), image = glyph.layoutSize
        return NSSize(width: symbolWidth + text.width, height: max(text.height, image.height))
    }
    private func cut(to width: CGFloat) -> CaptionCut {
        if let known = knownCuts[width] { return known }
        if source == nil {
            var attributes = line.attributes()
            attributes.removeValue(forKey: .foregroundColor)
            attributes[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            source = CTLineCreateWithAttributedString(NSAttributedString(string: line.shown, attributes: attributes))
            ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        }
        let result: CaptionCut
        let rtl = (CTLineGetGlyphRuns(source!) as? [CTRun] ?? []).contains { CTRunGetStatus($0).contains(.rightToLeft) }
        if rtl {
            if let cut = CTLineCreateTruncatedLine(source!, Double(width), .middle, ellipsis!) {
                result = .rightToLeft(cut, CTLineGetTypographicBounds(cut, nil, nil, nil))
            } else { result = .prefix }
        } else if let cut = line.middleCut(width: width) {
            // The original Text measures the head, ellipsis and tail as
            // separate runs. It keeps just the ellipsis if no head fits.
            let pieces = [cut.head, "…", cut.head.isEmpty ? "" : cut.tail].filter { !$0.isEmpty }
            let naturalWidth = pieces.reduce(CGFloat(0)) { width, text in
                var part = line; part.text = text
                return width + part.width
            }
            result = .pieces(pieces, naturalWidth)
        } else { result = .prefix }
        if knownCuts.count >= 32 { knownCuts.removeAll(keepingCapacity: true) }
        knownCuts[width] = result
        return result
    }
    func width(forProposal proposal: CGFloat, retainCut: Bool = false) -> CGFloat {
        let ideal = intrinsicContentSize.width
        let offered = min(ideal, max(symbolWidth, proposal)), textWidth = offered - symbolWidth
        let plan: CaptionPlan
        if offered >= ideal { plan = CaptionPlan(width: ideal, cut: nil) }
        else {
            let selected = cut(to: textWidth)
            let width = selected.width.map { min(offered, symbolWidth + PiKit.ceil($0, piScale)) } ?? PiKit.round(offered, piScale)
            plan = CaptionPlan(width: width, cut: selected)
        }
        // StackLayout first probes zero/infinity, then offers the actual
        // share. Only placement may retain that final finite proposal.
        if retainCut, proposal.isFinite { placedPlan = plan }
        return plan.width
    }
    override func draw(_ dirtyRect: NSRect) {
        let image = glyph.layoutSize, text = line.size(scale: piScale)
        glyph.draw(centredIn: CGRect(x: 0, y: 0, width: image.width, height: bounds.height), color: line.color, scale: piScale)
        let rect = CGRect(x: symbolWidth, y: PiKit.round((bounds.height - text.height) / 2, piScale),
                          width: max(0, bounds.width - symbolWidth), height: text.height)
        guard rect.width > 0, !line.text.isEmpty else { return }
        guard rect.width < text.width else { line.draw(at: rect.origin, scale: piScale); return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect)
        let selected = placedPlan.flatMap { $0.width == bounds.width ? $0.cut : nil } ?? cut(to: rect.width)
        switch selected {
        case .rightToLeft(let cut, _):
            context.setFillColor(line.color.cgColor)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + line.baseline(scale: piScale))
            CTLineDraw(cut, context)
        case .pieces(let pieces, _):
            var x = rect.minX
            for text in pieces {
                var part = line; part.text = text
                part.draw(at: CGPoint(x: x, y: rect.minY), scale: piScale)
                x += part.width
            }
        case .prefix:
            var first = line; first.text = String(line.text.prefix(1))
            first.draw(at: rect.origin, scale: piScale)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The folder, the branch menu, fetch, pull and push, the stash menu, the
/// Changes and History tabs, and what the last action said: one row where
/// the panel is wide; where it is narrow, the tabs and what the last action
/// said on a second row.
@MainActor final class GitPanelToolbar: NSView, PiKit.WidthSizing {
    struct Inputs: Equatable {
        var roots: [String], root: String?, displayRoot: String, repository: Bool
        var context: GitController.RepositoryContext?
        var branch: String, upstream: String?, behind: Int, ahead: Int
        var stashes: Int, busy: Bool, panel: GitController.Panel, notice: String, lastCommit: String?
        @MainActor init(_ controller: GitController) {
            roots = controller.roots; root = controller.root; displayRoot = controller.displayRoot; repository = controller.repositoryRoot != nil
            context = controller.repositoryContext
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
    var layoutProposalWidth: CGFloat? { didSet { if oldValue != layoutProposalWidth { needsLayout = true } } }
    private var rootDropdown: PiKit.Dropdown<String>?
    private let rootLabel = GitRootCaption()
    private lazy var branchMenu = PiKit.MenuButton(title: "", icon: "arrow.triangle.branch", identifier: "git-branch-menu") { [weak self, controller] in
        let current = controller.status.branch, context = self?.inputs?.context
        PiMenuEntry.button("New Branch from \(current.isEmpty ? "HEAD" : current)…") { self?.showNewBranch(context: context) }
        PiMenuEntry.divider
        for branch in controller.branches {
            PiMenuEntry.button(branch, enabled: branch != current, checked: branch == current) { guard controller.accepts(context) else { return }; Task { await controller.checkout(branch, context: context) } }
        }
    }
    private let remote: GitRemoteControls
    private lazy var stashMenu = PiKit.MenuButton(title: "Stash", icon: "tray.and.arrow.down", identifier: "git-stash-menu") { [weak self, controller] in
        let context = self?.inputs?.context
        PiMenuEntry.button("Stash Changes…", enabled: !controller.status.entries.isEmpty) { self?.showStash(context: context) }
        if !controller.stashes.isEmpty {
            PiMenuEntry.divider
            for stash in controller.stashes {
                PiMenuEntry.button("Pop \(stash.name): \(stash.subject)") { guard controller.accepts(context) else { return }; Task { await controller.popStash(stash.name, context: context) } }
            }
        }
    }
    private let panelTabs: PiKit.Tabs<GitController.Panel>
    private let notice = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piDanger))
    private var committed: PiKit.Badge?
    private let branchPopover = AnchoredPopover(), stashPopover = AnchoredPopover()
    private struct RepositoryForm { let token = UUID(); let repository: GitController.RepositoryIdentity }
    private var branchForm: RepositoryForm?, stashForm: RepositoryForm?
    private var repositoryWatch: AnyCancellable?
    private var formNotice = ""

    init(controller: GitController) {
        self.controller = controller
        remote = GitRemoteControls(controller: controller)
        panelTabs = PiKit.Tabs(selection: controller.panel, items: GitController.Panel.allCases.map { ($0, $0.title) }) { [controller] in controller.panel = $0 }
        super.init(frame: .zero)
        for view in [rootLabel, branchMenu, remote, stashMenu, panelTabs, notice] as [NSView] { addSubview(view) }
        repositoryWatch = controller.$repositoryIdentity.sink { [weak self] in self?.repositoryChanged($0) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ next: Inputs, wide: Bool) {
        guard next != inputs || wide != self.wide else { return }
        let previousMinimum = minimumWidth
        let proposal = layoutProposalWidth ?? bounds.width
        let previousWidth = width(forProposal: proposal)
        inputs = next; self.wide = wide
        measures = nil
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
        remote.apply(behind: next.behind, ahead: next.ahead, upstream: next.upstream, busy: next.busy, context: next.context)
        stashMenu.label = next.stashes == 0 ? "Stash" : "Stash · \(next.stashes)"
        stashMenu.isEnabled = !next.busy
        panelTabs.selection = next.panel
        showNotice(next.notice)
        if let last = next.lastCommit {
            if let committed { committed.text = "Committed \(last)" } else {
                let badge = PiKit.Badge(text: "Committed \(last)", tone: .success, icon: "checkmark")
                addSubview(badge); committed = badge
            }
        } else { committed?.removeFromSuperview(); committed = nil }
        needsLayout = true
        let height = proposal > 0 ? self.height(forWidth: proposal) : 0
        if height != bounds.height || minimumWidth != previousMinimum || width(forProposal: proposal) != previousWidth {
            PiKit.sizeChanged(self)
        }
    }

    // MARK: Layout

    private func rootItem(retainCaptionCut: Bool = false) -> StackLayout.Item {
        // The dropdown and the menus are their own size (`fixedSize`).
        if let rootDropdown { return .fixed(rootDropdown) }
        // The caption can give up its text, but the folder and its label
        // spacing retain the minimum of the original SwiftUI Label.
        return .view(rootLabel, StackLayout.Sizing(width: { [rootLabel] in rootLabel.width(forProposal: $0, retainCut: retainCaptionCut) },
                                                   height: { [rootLabel] _ in rootLabel.intrinsicContentSize.height }))
    }
    private var outcomeItems: [StackLayout.Item] {
        var items: [StackLayout.Item] = []
        if !notice.isHidden { items.append(.line(notice)) }
        if let committed { items.append(.view(committed, .intrinsic(committed))) }
        return items
    }
    private func firstRow(retainCaptionCut: Bool = false) -> [StackLayout.Item] {
        var items = [rootItem(retainCaptionCut: retainCaptionCut)]
        if inputs?.repository == true {
            items.append(.fixed(branchMenu))
            items.append(.view(remote, remote.sizing))
            items.append(.view(stashMenu, .intrinsic(stashMenu)))
        }
        if wide { items.append(.fixed(panelTabs)); items.append(.spacer()); items += outcomeItems } else { items.append(.spacer(0)) }
        return items
    }
    private func secondRow() -> [StackLayout.Item] { [.fixed(panelTabs), .spacer()] + outcomeItems }

    var minimumWidth: CGFloat {
        let first = StackLayout.width(firstRow(), spacing: PiSpacing.sm, proposal: 0)
        let second = wide ? 0 : StackLayout.width(secondRow(), spacing: PiSpacing.sm, proposal: 0)
        return max(first, second) + PiSpacing.lg * 2
    }

    /// The toolbar's last measured width and height, for one proposal at one
    /// scale. The panel lays its parts out again whenever any of them changes
    /// size (a commit message's first character changes the commit box's),
    /// and measuring the toolbar's rows afresh each time cost more than the
    /// rest of that pass. Kept until the toolbar's inputs change or one of its
    /// parts reports a new size (`PiKit.sizeChanged` invalidates each
    /// container on its way up).
    private struct Measures { var scale: CGFloat; var width: (proposal: CGFloat, value: CGFloat)? = nil; var height: (width: CGFloat, value: CGFloat)? = nil }
    private var measures: Measures?
    override func invalidateIntrinsicContentSize() { measures = nil; super.invalidateIntrinsicContentSize() }
    /// The measures kept at the current scale, dropping them if it changed.
    private var currentMeasures: Measures {
        let scale = piScale
        if let measures, measures.scale == scale { return measures }
        return Measures(scale: scale)
    }

    func width(forProposal width: CGFloat) -> CGFloat {
        var kept = currentMeasures
        if let measured = kept.width, measured.proposal == width { return measured.value }
        let value = measureWidth(forProposal: width)
        RedrawCounter.note("GitPanelToolbar measured")
        kept.width = (width, value); measures = kept
        return value
    }
    private func measureWidth(forProposal width: CGFloat) -> CGFloat {
        let inner = max(0, width - PiSpacing.lg * 2)
        let first = StackLayout.width(firstRow(), spacing: PiSpacing.sm, proposal: inner)
        let second = wide ? 0 : StackLayout.width(secondRow(), spacing: PiSpacing.sm, proposal: inner)
        return max(width, max(first, second) + PiSpacing.lg * 2)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var kept = currentMeasures
        if let measured = kept.height, measured.width == width { return measured.value }
        let value = measureHeight(forWidth: width)
        RedrawCounter.note("GitPanelToolbar measured")
        kept.height = (width, value); measures = kept
        return value
    }
    private func measureHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = width - PiSpacing.lg * 2
        var height = StackLayout.height(firstRow(), spacing: PiSpacing.sm, width: inner)
        if !wide { height += PiSpacing.sm + StackLayout.height(secondRow(), spacing: PiSpacing.sm, width: inner) }
        return height + PiSpacing.sm * 2
    }
    override func layout() {
        super.layout()
        // SwiftUI reports an overflowing row's width but retains the
        // parent's original proposal for its children. Feeding the wider
        // result back would give a short folder caption extra space.
        let inner = (layoutProposalWidth ?? bounds.width) - PiSpacing.lg * 2, scale = piScale
        let first = firstRow(retainCaptionCut: true), firstHeight = StackLayout.height(first, spacing: PiSpacing.sm, width: inner)
        StackLayout.place(first, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.lg, y: PiSpacing.sm, width: inner, height: firstHeight), scale: scale)
        if !wide {
            let second = secondRow(), secondHeight = StackLayout.height(second, spacing: PiSpacing.sm, width: inner)
            StackLayout.place(second, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.lg, y: PiSpacing.sm + firstHeight + PiSpacing.sm, width: inner, height: secondHeight), scale: scale)
        }
        remote.layoutForm()
    }

    // MARK: Popovers

    private func showNotice(_ message: String) {
        let text = [formNotice, message].filter { !$0.isEmpty }.joined(separator: " ")
        notice.line.text = text; notice.toolTip = text; notice.isHidden = text.isEmpty
    }
    private func repositoryChanged(_ identity: GitController.RepositoryIdentity?) {
        var closed: [String] = []
        if let branchForm, branchForm.repository != identity {
            self.branchForm = nil
            if branchPopover.isShown { branchPopover.close(); closed.append("New Branch") }
        }
        if let stashForm, stashForm.repository != identity {
            self.stashForm = nil
            if stashPopover.isShown { stashPopover.close(); closed.append("Stash") }
        }
        guard !closed.isEmpty else { return }
        // Keep the explanation even if the new repository's status read
        // fails; that error does not explain why the reader's form closed.
        formNotice = "Repository changed. \(closed.joined(separator: " and ")) closed."
        showNotice(controller.notice); measures = nil; needsLayout = true; PiKit.sizeChanged(self)
    }

    /// IntelliJ's branch popup: a new branch from HEAD, checked out.
    private func showNewBranch(context: GitController.RepositoryContext?) {
        guard controller.accepts(context), let identity = controller.repositoryIdentity else { return }
        let request = RepositoryForm(repository: identity)
        let form = GitNamePopover(title: "New branch", placeholder: "feature/name", icon: "arrow.triangle.branch", mono: true,
                                  note: "Created from the current HEAD and checked out; your changes come along.", action: "Create",
                                  requiresText: true, width: 320)
        form.cancel = { [weak self] in
            guard let self, self.branchForm?.token == request.token else { return }
            self.branchForm = nil; self.branchPopover.close()
        }
        form.submit = { [weak self, controller] name in
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let self, self.branchForm?.token == request.token, self.branchPopover.isShown,
                  controller.acceptsRepository(identity) else { return }
            self.branchForm = nil; self.branchPopover.close()
            Task { await controller.createBranch(name, repository: identity) }
        }
        branchForm = request; formNotice = ""; showNotice(controller.notice)
        branchPopover.show(form, width: 320, below: branchMenu, focus: form.field.field)
    }
    private func showStash(context: GitController.RepositoryContext?) {
        guard controller.accepts(context), let identity = controller.repositoryIdentity else { return }
        let request = RepositoryForm(repository: identity)
        let form = GitNamePopover(title: "Stash changes", placeholder: "Message (optional)", icon: "text.quote", mono: false,
                                  note: "Sets aside every change, untracked files included, and restores a clean working tree.", action: "Stash",
                                  requiresText: false, width: 340)
        form.cancel = { [weak self] in
            guard let self, self.stashForm?.token == request.token else { return }
            self.stashForm = nil; self.stashPopover.close()
        }
        form.submit = { [weak self, controller] message in
            guard let self, self.stashForm?.token == request.token, self.stashPopover.isShown,
                  controller.acceptsRepository(identity) else { return }
            self.stashForm = nil; self.stashPopover.close()
            Task { await controller.stash(message: message, repository: identity) }
        }
        stashForm = request; formNotice = ""; showNotice(controller.notice)
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
    private var context: GitController.RepositoryContext?
    private var behind = 0, ahead = 0, upstream: String?
    private let fetchButton: PiKit.Button, pullButton: PiKit.Button, pushButton: PiKit.Button
    private var icons: GitRemoteIconButtons?
    /// The width offered when last laid out: the form follows it.
    private var named = true
    static let iconSize = CGSize(width: 3 * 26 + 2 * 2, height: 26)

    init(controller: GitController) {
        self.controller = controller
        fetchButton = PiKit.Button("Fetch", symbol: "arrow.down.to.line", style: .secondary, compact: true)
        pullButton = PiKit.Button("Pull", symbol: "arrow.down.circle", style: .secondary, compact: true)
        pushButton = PiKit.Button("Push", symbol: "arrow.up.circle", style: .secondary, compact: true)
        super.init(frame: .zero)
        for (button, name) in [(fetchButton, "fetch"), (pullButton, "pull"), (pushButton, "push")] {
            button.setAccessibilityIdentifier("git-remote-" + name); addSubview(button)
        }
        fetchButton.toolTip = "Fetch from every remote and prune"
        apply(behind: 0, ahead: 0, upstream: nil, busy: false, context: controller.repositoryContext)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(behind: Int, ahead: Int, upstream: String?, busy: Bool, context: GitController.RepositoryContext? = nil) {
        self.behind = behind; self.ahead = ahead; self.upstream = upstream
        self.context = context
        fetchButton.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.fetch(context: context) } }
        pullButton.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.pull(context: context) } }
        pushButton.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.push(context: context) } }
        pullButton.title = behind > 0 ? "Pull \(behind)" : "Pull"
        pullButton.toolTip = behind > 0 ? "Pull \(behind) new commits (fast-forward only)" : "Pull (fast-forward only)"
        pullButton.setAccessibilityLabel(behind > 0 ? "Pull, \(behind) commits" : "Pull")
        pushButton.title = ahead > 0 ? "Push \(ahead)" : "Push"
        pushButton.toolTip = ahead > 0 ? "Push \(ahead) commits to \(upstream ?? "the upstream")" : "Push"
        pushButton.setAccessibilityLabel(ahead > 0 ? "Push, \(ahead) commits" : "Push")
        for button in [fetchButton, pullButton, pushButton] { button.isEnabled = !busy }
        icons?.apply(behind: behind, ahead: ahead, upstream: upstream, busy: busy, context: context)
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
            made.apply(behind: behind, ahead: ahead, upstream: upstream, busy: busy, context: context)
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
    private let controller: GitController
    private let fetch: PiKit.IconButton, pull: PiKit.IconButton, push: PiKit.IconButton
    private let pullCount = GitCountBadge(), pushCount = GitCountBadge()
    init(controller: GitController) {
        self.controller = controller
        fetch = PiKit.IconButton(symbol: "arrow.down.to.line", label: "Fetch", size: 26)
        pull = PiKit.IconButton(symbol: "arrow.down.circle", label: "Pull", size: 26)
        push = PiKit.IconButton(symbol: "arrow.up.circle", label: "Push", size: 26)
        super.init(frame: .zero)
        for view in [fetch, pull, push, pullCount, pushCount] as [NSView] { addSubview(view) }
        fetch.toolTip = "Fetch from every remote and prune"
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func apply(behind: Int, ahead: Int, upstream: String?, busy: Bool, context: GitController.RepositoryContext? = nil) {
        RedrawCounter.note("GitRemoteIconButtons")
        fetch.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.fetch(context: context) } }
        pull.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.pull(context: context) } }
        push.onPress = { [controller] in guard controller.accepts(context) else { return }; Task { await controller.push(context: context) } }
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
        var context: GitController.RepositoryContext?
        @MainActor init(_ controller: GitController) {
            context = controller.repositoryContext
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
            if let selection = inputs.selection ?? changesDiff.hunkReview?.offerSelection {
                setMode(.changes)
                changesDiff.bindHunkReview(controller)
                changesDiff.show(files: inputs.diff.files, title: selection.path, subtitle: selection.staged ? "Staged · index versus HEAD" : "Working tree versus index",
                                 identity: GitController.diffIdentity(path: selection.path, staged: selection.staged), loading: inputs.diffLoading,
                                 split: presentation.split, setSplit: setSplit, expanded: presentation.whole, setExpanded: setExpanded, openFile: openFile)
            } else {
                showPlaceholder("Select a file to see its changes.")
            }
        } else if let detail = controller.detail {
            let context = inputs.context
            header.openWorkingFile = openFile.map { open in { path in
                guard controller.accepts(context) else { return }
                open(path, 1)
            } }
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
                                setSplit: setSplit, expanded: presentation.whole, setExpanded: setExpanded, openFile: nil,
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
    private let workingFile = PlainTextButton("Open Working File", font: PiKit.Font.micro, color: .piAccent)
    var openWorkingFile: ((String) -> Void)?
    var select: ((String?) -> Void)?
    var showMore: (() -> Void)?
    var showHistory: ((String) -> Void)?
    private var hasBody = false, hasNote = false, hasFiles = false, mergeAlone = false, merge = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        workingFile.setAccessibilityIdentifier("git-open-working-file")
        workingFile.toolTip = "Open today's file at its beginning. Historical line numbers may no longer match."
        note.setAccessibilityIdentifier("git-reveal-note")
        summaryRow.setAccessibilityElement(false); summaryRow.setAccessibilityIdentifier("git-commit-summary")
        summaryRow.addSubview(summary); summaryRow.addSubview(summaryMerge)
        for view in [subject, meta, body, mergeBadge, note, summaryRow, chips, workingFile] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func show(_ detail: GitCommitDetail, note: String?, selected: String?, shown: Int) {
        let path = selected ?? (detail.files.count == 1 ? detail.files.first?.path : nil)
        workingFile.isHidden = path == nil || openWorkingFile == nil
        workingFile.onPress = { [weak self] in if let path { self?.openWorkingFile?(path) } }
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
            if !workingFile.isHidden { parts.append((workingFile, min(inner, workingFile.intrinsicContentSize.width), workingFile.intrinsicContentSize.height)) }
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
        PiQuestion.alert(title: entries.count == 1 ? "Discard changes to \((entries[0].path as NSString).lastPathComponent)?" : "Discard changes to \(entries.count) files?",
                         detail: "Tracked files revert to HEAD and untracked files are deleted. Git keeps no copy of these changes.",
                         action: "Discard", cancel: "Cancel", destructive: true, cancelIsDefault: true)
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
    var operation: GitOperationQuestion?
    /// Asks, over the window the panel is in now (not the one it was in when
    /// last told: a tab moves between windows). A request refused because a
    /// question is already up keeps that question as the one to take down.
    func askToDiscard(_ entries: [GitStatusEntry], questions: PiQuestion, then act: @escaping ([GitStatusEntry]) -> Void) {
        if let asked = GitDiscard.ask(questions, discarding: entries, in: window, then: act) { question = asked }
    }
    func cancelQuestion() { question?.cancel(); question = nil; operation?.cancel(); operation = nil }
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
