import AppKit
import FileFinder
import GitView

/// Kept by the window, including while no chat is selected. Never saved.
@MainActor final class SessionPanelState {
    enum Tab: String { case agents = "Agents", diff = "Diff", files = "Files" }
    var selection = Tab.agents
    var collapsed = false
}

enum SessionPanelLayout {
    static let width: CGFloat = 288
    static let gap: CGFloat = 16
    static let inset: CGFloat = 16
    static let minimumTranscript: CGFloat = 480
    static let minimumHeight: CGFloat = 180
    static let minimumWidth = minimumTranscript + width + gap + inset

    static func fits(width: CGFloat, height: CGFloat) -> Bool {
        width >= minimumWidth && height >= minimumHeight + inset * 2
    }
    static func transcript(in area: CGRect) -> CGRect {
        let available = max(0, area.width - width - gap - inset)
        let reading = min(available, TranscriptMetrics.pageWidth + TranscriptMetrics.pageGutter)
        // Once the reading column fits, use its spare right margin first.
        // In a very wide window the column keeps its original centred position.
        let left = min(max(0, (area.width - reading) / 2), available - reading)
        return CGRect(x: area.minX + left, y: area.minY, width: reading, height: area.height)
    }
}

/// A floating Pi card belonging to the main conversation, not the right pane.
@MainActor final class SessionFloatingPanel: NSView, PiKit.SizeObserver {
    let state: SessionPanelState
    let tabs: PiKit.Tabs<SessionPanelState.Tab>
    let collapse = PiKit.IconButton(symbol: "chevron.up", label: "Collapse session panel", size: 24)
    private let content = FlippedView()
    private let surface: PiKit.Box
    private let scroll = NSScrollView()
    private lazy var folder = PiKit.MenuButton(title: "", icon: "folder") { [weak self] in
        (self?.project?.roots ?? []).map { path in
            PiMenuEntry.button(URL(fileURLWithPath: path).lastPathComponent, checked: path == self?.root) { [weak self] in
                self?.changeRoot(path)
            }
        }
    }
    private weak var model: WorkspaceModel?
    private var chatID = ""
    private var project: WorkspaceRecord?
    private var root: String?
    private var repository: String?
    private(set) var repositoryChecked = false
    private var repositoryWatch: GitStateWatch?
    private var discovery: Task<Void, Never>?
    private var discoveryToken = UUID()
    private(set) var agents: AgentFamilyPopoverView?
    private(set) var changes: SessionPanelChanges?
    private(set) var files: FileFolderPanel?
    private var filesActive = false
    private var presented = false
    private var enabled = true
    var onCollapse: (() -> Void)?
    var sizeChanged: (() -> Void)?
    var selectedTab: SessionPanelState.Tab { availableTabs.contains(state.selection) ? state.selection : .agents }
    var availableTabs: [SessionPanelState.Tab] {
        [.agents] + (repository == nil ? [] : [.diff]) + (root == nil ? [] : [.files])
    }

    init(state: SessionPanelState) {
        self.state = state
        tabs = PiKit.Tabs(selection: .agents, items: [(.agents, "Agents")], horizontalPadding: 12,
                          keyboardFocusable: true, accessibilityName: "Session panel tabs")
        surface = PiKit.elevated(content, radius: 14)
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityIdentifier("session-floating-panel")
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Session panel")
        addSubview(surface)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        for view in [tabs, collapse, folder, scroll] as [NSView] { content.addSubview(view) }
        tabs.animatesSelection = false
        tabs.onSelect = { [weak self] in self?.select($0) }
        collapse.setAccessibilityIdentifier("collapse-session-panel")
        collapse.onPress = { [weak self] in self?.onCollapse?() }
    }
    required init?(coder: NSCoder) { nil }
    deinit { discovery?.cancel() }
    override var isFlipped: Bool { true }

    func update(model: WorkspaceModel, chat: ChatRecord, enabled: Bool) {
        let next = model.workspace(for: chat.workspaceID).flatMap { $0.isScratch ? nil : $0 }
        guard self.model !== model || chatID != chat.id || project != next || self.enabled != enabled else { return }
        self.model = model; self.enabled = enabled
        if chatID != chat.id {
            invalidateRepository()
            chatID = chat.id
            // A list on screen follows the chat from its top, keeping the rows
            // that read the same (most chats have no sides or agents yet).
            // One out of sight is built again when the card shows.
            if let agents, agents.model === model, presented {
                agents.show(sessionID: chat.id)
                if scroll.contentView.bounds.origin != .zero {
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else { scroll.documentView = nil; agents = nil }
        }
        if project?.id != next?.id || project?.roots != next?.roots {
            project = next; changeRoot(next?.roots.first)
        } else { project = next }
        refresh()
    }
    private func changeRoot(_ path: String?) {
        if let path, project?.roots.contains(path) != true { return }
        suspend()
        root = path; repository = nil; repositoryChecked = false
        changes?.removeFromSuperview(); changes = nil
        files?.removeFromSuperview(); files = nil; filesActive = false
        refresh()
    }
    func setPresented(_ value: Bool) {
        guard value != presented else { return }
        presented = value; isHidden = !value
        refresh()
    }
    func select(_ tab: SessionPanelState.Tab) {
        guard availableTabs.contains(tab), enabled else { return }
        state.selection = tab; refresh()
    }
    func focusAgents() {
        select(.agents)
        if let first = PiKit.controls(in: tabs).first { window?.makeFirstResponder(first) }
    }
    private var active: Bool { presented && enabled && window != nil && !isHiddenOrHasHiddenAncestor }
    private func invalidateRepository() {
        discovery?.cancel(); discovery = nil; discoveryToken = UUID()
        repositoryChecked = false
    }
    private func setRepository(_ path: String?) {
        if repository != path {
            changes?.controller.letGo()
            changes?.removeFromSuperview(); changes = nil
        }
        repository = path
    }
    private func suspend() {
        invalidateRepository()
        repositoryWatch?.stop(); repositoryWatch = nil
        changes?.controller.setShown(false)
        files?.browser.stop(); filesActive = false
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidHide() { super.viewDidHide(); suspend() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    func refresh() {
        if active, repository == nil || !repositoryChecked, repositoryWatch?.isWatching != true, let root {
            // Watch before the read so git init cannot fall between a negative
            // snapshot and arming the stream. No status or file reads are added.
            let watch = GitStateWatch(root: root, discoveringRepository: true) { [weak self] in
                guard let self, self.active, self.root == root else { return }
                self.invalidateRepository(); self.refresh()
            }
            repositoryWatch = watch; watch.start()
        } else if repository != nil, repositoryChecked {
            repositoryWatch?.stop(); repositoryWatch = nil
        }
        if active, !repositoryChecked, discovery == nil, let root {
            let token = UUID(); discoveryToken = token
            // Only repository discovery is eager. Status/counts and directory
            // listings wait for their tab, and every superseded read is cancelled.
            discovery = Task { [weak self] in
                let top = await GitService.shared.repositoryRoot(of: root)
                guard let self, !Task.isCancelled, self.discoveryToken == token else { return }
                self.discovery = nil; self.setRepository(top); self.repositoryChecked = true
                self.refresh()
            }
        } else if !active { suspend() }
        let tab = selectedTab
        let items = availableTabs.map { ($0, $0.rawValue) }
        if tabs.items.map(\.0) != items.map(\.0) || tabs.items.map(\.1) != items.map(\.1) { tabs.items = items }
        tabs.selection = tab
        collapse.isEnabled = enabled
        for item in availableTabs {
            guard let control = tabs.tab(item) else { continue }
            control.isEnabled = enabled
            control.setAccessibilityLabel(item.rawValue)
            control.setAccessibilityIdentifier("session-panel-tab-" + item.rawValue.lowercased())
        }
        folder.isHidden = tab == .agents || (project?.roots.count ?? 0) < 2
        folder.label = root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        folder.isEnabled = enabled
        scroll.isHidden = tab != .agents
        if presented, tab == .agents, agents == nil, let model {
            let agents = AgentFamilyPopoverView(model: model, sessionID: chatID, close: {}, ownerWindow: window, embedded: true)
            self.agents = agents; scroll.documentView = agents
        }
        agents?.inheritedEnabled = enabled
        if active, tab == .diff, changes == nil, let model, let project, let root {
            let changes = SessionPanelChanges(root: root) { [weak model] entry in
                guard let model, model.changesProject(project.id)?.roots.contains(root) == true,
                      let tab = model.showChanges(in: project.id) else { return }
                let controller = tab.controller
                if controller.root != root { controller.root = root }
                controller.panel = .changes
                controller.selection = .init(path: entry.path, staged: !entry.unstaged && entry.staged)
            }
            changes.changed = { [weak self] in self?.contentSizeChanged() }
            changes.repositoryMissing = { [weak self, weak changes] in
                guard let self, let changes, self.changes === changes else { return }
                self.setRepository(nil)
                self.invalidateRepository(); self.refresh()
            }
            self.changes = changes; content.addSubview(changes)
        }
        changes?.isHidden = tab != .diff
        changes?.controller.setShown(active && tab == .diff)
        if active, tab == .files, files == nil {
            let browser = FolderBrowser()
            let files = FileFolderPanel(browser: browser)
            browser.openFile = { [weak self] url in
                guard let self, self.active, let model = self.model, let project = self.project,
                      model.workspace(for: project.id)?.roots == project.roots else { return }
                let tab = model.openFile(url)
                model.quickOpen.focusAfterOpening(tab)
            }
            browser.changed = { [weak self, weak files] in
                guard let self, let files, self.files === files else { return }
                files.refresh(); self.contentSizeChanged()
                self.invalidateRepository(); self.refresh()
            }
            self.files = files; content.addSubview(files)
        }
        files?.isHidden = tab != .files
        files?.tree.table.isEnabled = enabled
        if active, tab == .files, !filesActive, let root {
            filesActive = true
            let url = FileBreadcrumb.normalized(URL(fileURLWithPath: root))
            if files?.browser.root == url {
                // Keep expanded levels and cached rows; refresh those levels only.
                for expanded in files?.browser.expanded ?? [] { files?.browser.expand(expanded) }
            } else { files?.browser.showFolder(url, relativeTo: url) }
        } else if (!active || tab != .files), filesActive {
            files?.browser.stop(); filesActive = false
        }
        contentSizeChanged()
    }
    func contentSizeChanged() { needsLayout = true; sizeChanged?() }
    private var headerHeight: CGFloat { folder.isHidden ? 48 : 80 }
    var preferredHeight: CGFloat {
        let height: CGFloat
        switch selectedTab {
        case .agents: height = agents?.height(forWidth: SessionPanelLayout.width - 2) ?? 100
        case .diff: height = changes?.preferredHeight ?? 72
        case .files: height = 32 + CGFloat(files?.browser.rows.count ?? 2) * 26
        }
        return headerHeight + max(64, height) + 6
    }
    override func layout() {
        super.layout()
        surface.frame = bounds; content.frame = bounds
        tabs.frame = CGRect(origin: CGPoint(x: 10, y: 9), size: tabs.intrinsicContentSize)
        collapse.frame = CGRect(x: bounds.width - 34, y: 13, width: 24, height: 24)
        folder.frame = CGRect(x: 10, y: 46, width: bounds.width - 20, height: 28)
        let body = CGRect(x: 1, y: headerHeight, width: bounds.width - 2, height: max(0, bounds.height - headerHeight - 6))
        scroll.frame = body; changes?.frame = body; files?.frame = body
        if let agents { agents.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: agents.height(forWidth: scroll.contentSize.width)) }
    }
}

/// Shares Changes' reader, watcher, status model and cancellation. It never
/// reads history or a patch, and virtualizes its Pi rows through LazyStackView.
@MainActor final class SessionPanelChanges: NSView {
    let controller: GitController
    let list = LazyStackView()
    var changed: (() -> Void)?
    var repositoryMissing: (() -> Void)?
    private let open: (GitStatusEntry) -> Void
    private var observer: ShellObserver?
    private var entries: [GitStatusEntry] = []
    private var stats: [String: GitDiffStat] = [:]
    private var message = ""
    private var context: GitController.RepositoryContext?
    private var sourceEntries: [GitStatusEntry] = []
    init(root: String, open: @escaping (GitStatusEntry) -> Void) {
        controller = GitController(roots: [root], summaryOnly: true); self.open = open
        super.init(frame: .zero)
        list.insets = NSEdgeInsets(top: 4, left: 6, bottom: 6, right: 6); list.spacing = 2
        addSubview(list)
        let observer = ShellObserver { [weak self] in self?.refresh() }; observer.observe(controller); self.observer = observer
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { entries.isEmpty ? 72 : 10 + CGFloat(entries.count) * 48 }
    private func refresh() {
        if controller.statusRead, controller.repositoryRoot == nil, let repositoryMissing {
            repositoryMissing(); return
        }
        let source = controller.status.entries, stats = controller.changeStats
        let entries = source == sourceEntries ? self.entries : Self.compactEntries(source)
        let message = !controller.notice.isEmpty ? controller.notice : !controller.statusRead ? "Reading changes…" : "No changed files"
        let context = controller.repositoryContext
        guard entries != self.entries || stats != self.stats || message != self.message || context != self.context else { return }
        let sameRows = entries == self.entries && message == self.message
        sourceEntries = source; self.entries = entries; self.stats = stats; self.message = message
        self.context = context
        let rows = LazyStackView.Source(count: max(1, entries.count), key: { entries.isEmpty ? "empty" : entries[$0].path },
            height: { _, _ in entries.isEmpty ? 64 : 46 },
            view: { [weak self] index, existing in
                guard let self else { return NSView() }
                if entries.isEmpty { return GitEmptyRow(message) }
                let entry = entries[index]
                let row = existing as? SessionPanelDiffRow ?? SessionPanelDiffRow(entry: entry, stat: stats[entry.path])
                row.apply(entry: entry, stat: stats[entry.path])
                row.onPress = { [weak self] in
                    guard let self, self.controller.accepts(context) else { return }
                    self.open(entry)
                }
                return row
            })
        if sameRows { list.update(rows) } else { list.reload(rows); changed?() }
    }
    /// A staged deletion can also have an untracked recreation. The compact
    /// list shows each path once, preferring the working tree it opens.
    static func compactEntries(_ entries: [GitStatusEntry]) -> [GitStatusEntry] {
        var result: [GitStatusEntry] = [], indices: [String: Int] = [:]
        for entry in entries {
            if let index = indices[entry.path] {
                if entry.unstaged { result[index] = entry }
            } else { indices[entry.path] = result.count; result.append(entry) }
        }
        return result
    }
    override func layout() { super.layout(); list.frame = bounds }
}

@MainActor final class SessionPanelDiffRow: PiKit.ButtonBase {
    private(set) var entry: GitStatusEntry
    private var stat: GitDiffStat?
    init(entry: GitStatusEntry, stat: GitDiffStat?) {
        self.entry = entry; self.stat = stat
        super.init(frame: .zero)
        apply(entry: entry, stat: stat)
    }
    func apply(entry: GitStatusEntry, stat: GitDiffStat?) {
        self.entry = entry; self.stat = stat
        title = entry.path
        setAccessibilityIdentifier("panel-diff-" + entry.path)
        let detail = entry.originalPath.map { $0 + " → " + entry.path } ?? entry.path
        let label = entry.summary + ", " + detail + ", " + counts
        setAccessibilityLabel("Open diff, " + label); toolTip = label
        redrawContent()
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEffectivelyEnabled }
    override var canBecomeKeyView: Bool { isEffectivelyEnabled && !isHiddenOrHasHiddenAncestor }
    private var counts: String { stat.map { $0.binary ? "Binary" : "+\($0.added) −\($0.removed)" } ?? "Counts unavailable" }
    override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
    override func styleFace() {
        fill.backgroundColor = piCGColor(hovering || isPressedDown ? .piFill : .clear)
        stroke.borderColor = CGColor.clear; shadowLayer.shadowOpacity = 0
    }
    override func drawContent(in rect: CGRect) {
        PiKit.Line(entry.badge, font: .systemFont(ofSize: 11, weight: .semibold), color: GitFileRowView.badgeColor(entry.badge))
            .draw(in: CGRect(x: 8, y: 8, width: 16, height: 18), scale: piScale)
        let count = PiKit.Line(counts, font: PiKit.Font.micro, color: .piInkSecondary)
        let countWidth = count.size(scale: piScale).width
        count.draw(in: CGRect(x: rect.width - countWidth - 8, y: 9, width: countWidth, height: 16), scale: piScale)
        PiKit.Line((entry.path as NSString).lastPathComponent, font: PiKit.Font.caption, color: .piInk)
            .draw(in: CGRect(x: 30, y: 6, width: max(0, rect.width - countWidth - 46), height: 20), truncation: .end, scale: piScale)
        let detail = entry.originalPath.map { $0 + " → " + entry.path } ?? entry.path
        PiKit.Line(detail, font: PiKit.Font.micro, color: .piInkTertiary)
            .draw(in: CGRect(x: 30, y: 26, width: max(0, rect.width - 38), height: 16), truncation: .middle, scale: piScale)
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), isEnabled { onPress?() } else { super.keyDown(with: event) }
    }
}
