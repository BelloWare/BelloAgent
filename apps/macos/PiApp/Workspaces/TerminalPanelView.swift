import AppKit
import Combine

// The panel under the transcript: the project's terminals as tabs, a new
// one, and the shown one's name, shell title, rename, restart and close,
// then the terminal. Its height drags on its top edge and is remembered.

@MainActor final class TerminalPanelView: NSView {
    let model: WorkspaceModel
    /// The project whose terminals it shows; the pane hands it another.
    var workspace: WorkspaceRecord {
        didSet {
            guard workspace != oldValue else { return }
            registry.ensureInitialSession(for: workspace)
            refresh()
            // The old project's view leaves the window with the keyboard, so
            // the new project's shell has to be given it back. The same
            // project's record changing (a relocated folder) keeps focus where it is.
            if workspace.id != oldValue.id { focusSoon() }
        }
    }
    /// The window's disabled state, from the SwiftUI around the pane.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    /// Its ideal or minimum height changed.
    var sizeChanged: (() -> Void)?

    private let registry = TerminalRegistry.shared
    private var registryWatch: AnyCancellable?
    private var heightWatch: AnyCancellable?
    private var shownStoredHeight: CGFloat = 0
    private var sessionWatch: AnyCancellable?
    private weak var watched: TerminalSession?
    private var scheduled = false

    let handle = PiKit.ResizeHandle(orientation: .horizontal, label: "Resize terminal", hint: "Drag up or down")
    let header: TerminalHeaderView
    private let host = TerminalHostView()
    private let empty: TerminalEmptyView
    /// The height being dragged to, until the drag ends.
    private var dragging: CGFloat?
    private var startHeight: CGFloat?
    private var shownKey: String?

    static let heightKey = "terminalHeight"
    private var storedHeight: CGFloat {
        get { UserDefaults.standard.object(forKey: Self.heightKey).map { _ in CGFloat(UserDefaults.standard.double(forKey: Self.heightKey)) } ?? 240 }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.heightKey) }
    }
    /// The terminal's own height: as dragged, else as remembered.
    var terminalHeight: CGFloat { TerminalPanel.clampHeight(dragging ?? storedHeight) }

    init(model: WorkspaceModel, workspace: WorkspaceRecord) {
        self.model = model; self.workspace = workspace
        header = TerminalHeaderView()
        empty = TerminalEmptyView()
        super.init(frame: .zero)
        wantsLayer = true
        for view in [host, empty, header, handle] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
        setAccessibilityIdentifier("terminal-panel")
        handle.changed = { [weak self] translation in
            guard let self, self.inheritedEnabled else { return }
            let base = self.startHeight ?? self.terminalHeight
            if self.startHeight == nil { self.startHeight = self.terminalHeight }
            self.dragging = TerminalPanel.clampHeight(base - translation)
            self.handle.dragging = true
            self.sizeChanged?()
        }
        handle.ended = { [weak self] translation in
            guard let self, self.inheritedEnabled || self.dragging != nil else { return }
            self.storedHeight = TerminalPanel.clampHeight((self.startHeight ?? self.terminalHeight) - translation)
            self.startHeight = nil; self.dragging = nil; self.handle.dragging = false
            self.sizeChanged?()
        }
        header.newTerminal.onPress = { [weak self] in guard let self else { return }; self.registry.create(for: self.workspace) }
        header.hide.onPress = { [weak self] in self?.model.toggleTerminal() }
        header.selectTab = { [weak self] id in guard let self else { return }; self.registry.select(id, in: self.workspace.id) }
        header.rename.onPress = { [weak self] in self?.ask { registry, id, generation, workspace, window in
            await registry.requestRename(id, generation: generation, in: workspace.id, over: window) } }
        header.restart.onPress = { [weak self] in self?.ask { registry, id, generation, workspace, window in
            _ = await registry.requestEnding(.restart, id, generation: generation, in: workspace, over: window) } }
        header.close.onPress = { [weak self] in self?.ask { registry, id, generation, workspace, window in
            _ = await registry.requestEnding(.close, id, generation: generation, in: workspace, over: window) } }
        empty.create.onPress = { [weak self] in guard let self else { return }; self.registry.create(for: self.workspace) }
        registryWatch = registry.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
        // Every panel follows the remembered height, as `@AppStorage` did.
        // Defaults say they changed on the writer's thread: read on the main queue.
        heightWatch = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.storedHeightMayHaveChanged() } }
        shownStoredHeight = storedHeight
        registry.ensureInitialSession(for: workspace)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private var session: TerminalSession? { registry.selected(for: workspace.id) }

    private func storedHeightMayHaveChanged() {
        let height = storedHeight
        guard height != shownStoredHeight else { return }
        shownStoredHeight = height
        if dragging == nil { sizeChanged?() }
    }

    /// The terminal as it is when clicked: a click that waited behind a
    /// restart doesn't act on the new shell.
    private func ask(_ action: @escaping @MainActor (TerminalRegistry, UUID, Int, WorkspaceRecord, NSWindow?) async -> Void) {
        // The terminal the header shows, not one that replaced it since.
        guard inheritedEnabled, let target = header.target else { return }
        let id = target.id, generation = target.generation, workspace = self.workspace, registry = self.registry, window = self.window
        Task { await action(registry, id, generation, workspace, window) }
    }

    // MARK: Changes

    private func schedule() {
        guard !scheduled else { return }
        // Nothing is laid out again until the refresh finds a change.
        scheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }
    private func flush() { guard scheduled else { return }; scheduled = false; refresh() }

    /// What the panel shows, compared before anything is redrawn.
    private struct Shown: Equatable {
        var tabs: [[String]]
        var selected: String?
        var title: String
        var exited: Bool
        var failure: String?
        var project: String
        var enabled: Bool
    }
    private var shown: Shown?
    private var shownSession: ObjectIdentifier?

    private func refresh() {
        let session = self.session
        if session !== watched {
            watched = session
            sessionWatch = session?.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
        }
        let sessions = registry.sessions(for: workspace.id)
        let project = (workspace.path as NSString).lastPathComponent
        let new = Shown(tabs: sessions.map { [$0.id.uuidString, $0.displayName] }, selected: session.map { "\($0.id)/\($0.generation)" },
                        title: session?.shellTitle ?? "", exited: session?.exited ?? false, failure: session?.failure, project: project, enabled: inheritedEnabled)
        // The shown shell's own view only moves when another one is shown.
        let identity = session.map(ObjectIdentifier.init)
        if identity != shownSession || session.map({ $0.view.superview !== host }) ?? false { shownSession = identity; host.show(session) }
        guard new != shown else { return }
        let before = shown
        shown = new
        let chrome = chromeHeight
        header.update(sessions: sessions, selected: session, projectName: project, enabled: inheritedEnabled)
        empty.isHidden = session != nil
        empty.create.isEnabled = inheritedEnabled
        // What the keyboard follows: the shown terminal, and its restarts.
        let key = new.selected ?? "none"
        if key != shownKey { shownKey = key; focusSoon() }
        needsLayout = true
        if before == nil || chromeHeight != chrome { sizeChanged?() }
    }
    private func focusSoon() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.session?.focus() } }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        registry.ensureInitialSession(for: workspace)
        refresh(); focusSoon()
    }

    // MARK: Layout

    /// The handle's line and the header.
    var chromeHeight: CGFloat { 1 + header.preferredHeight }
    /// Its height when it has the room: the chrome and the terminal as dragged.
    var idealHeight: CGFloat { chromeHeight + terminalHeight }
    /// The least it takes: the terminal gives way down to its minimum.
    var minimumHeight: CGFloat { chromeHeight + min(terminalHeight, TerminalPanel.minimumHeight) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: idealHeight) }

    override func layout() {
        flush()
        super.layout()
        let width = bounds.width
        // The handle's hairline is the panel's first point; the strip it can
        // be grabbed by reaches four points either side of it.
        handle.frame = CGRect(x: 0, y: 0.5 - PiKit.ResizeHandle.hitThickness / 2, width: width, height: PiKit.ResizeHandle.hitThickness)
        let headerHeight = header.preferredHeight
        header.frame = CGRect(x: 0, y: 1, width: width, height: headerHeight)
        let body = CGRect(x: 0, y: 1 + headerHeight, width: width, height: max(0, bounds.height - 1 - headerHeight))
        host.frame = body; empty.frame = body
    }
    /// The grab strip above the panel's top edge takes the pointer too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // Disabled, the strip takes nothing, inside the panel or above it.
        if handle.frame.contains(local) { return inheritedEnabled ? handle : nil }
        return super.hitTest(point)
    }
}

/// Where the shown terminal's own view goes: only it, re-parented when it
/// shows again (switching projects used to leave the previous project's
/// terminal stacked underneath, still drawing).
@MainActor final class TerminalHostView: NSView {
    override var isFlipped: Bool { true }
    func show(_ session: TerminalSession?) {
        let view = session?.view
        for other in subviews where other !== view { other.removeFromSuperview() }
        guard let session, let view else { return }
        if view.superview !== self {
            view.removeFromSuperview()
            view.frame = bounds; view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        session.applyColors()
    }
    override func layout() { super.layout(); for view in subviews { view.frame = bounds } }
}

/// A project whose terminals were all closed: a line and New Terminal.
@MainActor final class TerminalEmptyView: NSView {
    private let line = PiKit.TextLine(PiKit.Line("No terminals in this project", font: PiKit.Font.caption, color: .piInkSecondary))
    let create = PiKit.Button("New Terminal", symbol: "plus", style: .secondary, compact: true)
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(line); addSubview(create)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // `VStack(spacing: 8)` in the middle.
        let l = line.intrinsicContentSize, b = create.intrinsicContentSize, scale = piScale
        let total = l.height + PiSpacing.sm + b.height
        let top = PiKit.round((bounds.height - total) / 2, scale)
        line.frame = CGRect(x: PiKit.round((bounds.width - l.width) / 2, scale), y: top, width: l.width, height: l.height)
        create.frame = CGRect(x: PiKit.round((bounds.width - b.width) / 2, scale), y: top + l.height + PiSpacing.sm, width: b.width, height: b.height)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piTerminalSurface) }
}

// MARK: - The header

/// `HStack(spacing: 8)` in `.padding(.horizontal, 12).padding(.vertical, 5)`
/// on the window's color: the terminal mark, the tabs (scrolling past a
/// limit, fading at their end), New, the shell's title and the project's
/// folder (giving way, whole, to the buttons in a narrow pane), and the
/// shown terminal's state and buttons.
@MainActor final class TerminalHeaderView: NSView {
    private let mark = PiKit.SymbolView(PiKit.Symbol("terminal", size: 11, weight: .semibold), color: .piInkSecondary)
    private let tabsScroll = NSScrollView()
    private var tabs: PiKit.Tabs<UUID>?
    private let fade = CAGradientLayer()
    let newTerminal = PiKit.IconButton(symbol: "plus", label: "New terminal", size: 22)
    private let title = PiKit.TextLine()
    private let project = PiKit.TextLine()
    private let badge = PiKit.Badge(text: "", tone: .danger)
    let rename = PiKit.IconButton(symbol: "pencil", label: "Rename terminal", size: 22)
    let restart = PiKit.IconButton(symbol: "arrow.clockwise", label: "Restart terminal", size: 22)
    let close = PiKit.IconButton(symbol: "trash", label: "Close terminal", size: 22)
    let hide = PiKit.IconButton(symbol: "xmark", label: "Hide terminal (⌃`)", size: 22)
    var selectTab: ((UUID) -> Void)?
    private var selectedID: UUID?
    /// The terminal the buttons act on: the one shown when the header was
    /// last drawn, by its identity and generation.
    private(set) var target: (id: UUID, generation: Int)?
    /// A tab to bring into view once the row has its final size.
    private var pendingReveal: (id: UUID, animated: Bool)?

    static let padding = NSEdgeInsets(top: 5, left: PiSpacing.md, bottom: 5, right: PiSpacing.md)
    static let spacing = PiSpacing.sm

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        mark.setAccessibilityElement(false)
        tabsScroll.drawsBackground = false; tabsScroll.hasHorizontalScroller = false; tabsScroll.hasVerticalScroller = false
        tabsScroll.horizontalScrollElasticity = .none; tabsScroll.verticalScrollElasticity = .none
        tabsScroll.contentView.drawsBackground = false
        tabsScroll.automaticallyAdjustsContentInsets = false
        tabsScroll.wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        title.truncation = .end; project.truncation = .middle
        newTerminal.toolTip = "Open another terminal in this project"
        rename.toolTip = "Give this terminal a name of your own"
        restart.toolTip = "Starts a new shell in this terminal. Its scrollback is removed. Asks first while the shell is running."
        close.toolTip = "Ends this terminal's shell and removes its output. Asks first while the shell is running."
        hide.toolTip = "Hide the terminals; they keep running"
        for view in [mark, tabsScroll, newTerminal, title, project, badge, rename, restart, close, hide] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(sessions: [TerminalSession], selected: TerminalSession?, projectName: String, enabled: Bool) {
        let items = sessions.map { ($0.id, $0.displayName) }
        if sessions.isEmpty {
            tabs?.removeFromSuperview(); tabs = nil; tabsScroll.documentView = nil
        } else if let tabs {
            if tabs.items.map(\.0) != items.map(\.0) || tabs.items.map(\.1) != items.map(\.1) { tabs.items = items }
            tabs.accessibilityName = "Terminals in " + projectName
        } else {
            let made = PiKit.Tabs<UUID>(selection: selected?.id ?? UUID(), items: items, accessibilityName: "Terminals in " + projectName) { [weak self] id in
                self?.selectTab?(id)
            }
            tabs = made; tabsScroll.documentView = made
        }
        tabsScroll.isHidden = sessions.isEmpty
        if let tabs, let id = selected?.id, tabs.selection != id { tabs.selection = id }
        let moved = selected?.id != selectedID
        selectedID = selected?.id
        target = selected.map { ($0.id, $0.generation) }
        for case let tab as PiKit.ButtonBase in tabs?.subviews ?? [] { tab.isEnabled = enabled }
        title.line = PiKit.Line(selected?.shellTitle ?? "", font: PiKit.Font.caption, color: .piInkSecondary)
        title.isHidden = (selected?.shellTitle ?? "").isEmpty
        project.line = PiKit.Line(projectName, font: PiKit.Font.micro, color: .piInkTertiary)
        // A short badge, so the buttons beside it stay in reach in a narrow
        // pane; the whole message is its help and what VoiceOver reads.
        if let failure = selected?.failure {
            badge.isHidden = false; badge.text = "Terminal error"; badge.tone = .danger
            badge.toolTip = failure; badge.setAccessibilityLabel("Terminal error: " + failure)
        } else if selected?.exited == true {
            badge.isHidden = false; badge.text = "Shell exited"; badge.tone = .warning
            badge.toolTip = nil; badge.setAccessibilityLabel("Shell exited")
        } else { badge.isHidden = true }
        let name = selected?.displayName ?? ""
        for button in [rename, restart, close] { button.isHidden = selected == nil }
        rename.spokenLabel = "Rename " + name; restart.spokenLabel = "Restart " + name; close.spokenLabel = "Close " + name
        for button in [newTerminal, rename, restart, close, hide] { button.isEnabled = enabled }
        tabs?.alphaValue = 1
        needsLayout = true
        if moved, let id = selected?.id { pendingReveal = (id, window != nil) }
    }

    /// The header's height: its tallest piece in its padding.
    var preferredHeight: CGFloat {
        let tabsHeight = tabs?.intrinsicContentSize.height ?? 0
        return max(22, tabsHeight, mark.intrinsicContentSize.height) + Self.padding.top + Self.padding.bottom
    }

    // MARK: Layout

    private var controls: [NSView] { [badge, rename, restart, close, hide].filter { !$0.isHidden } }
    private var controlsWidth: CGFloat {
        let views = controls
        return views.reduce(0) { $0 + $1.intrinsicContentSize.width } + Self.spacing * CGFloat(max(0, views.count - 1))
    }
    /// How wide the tab row may be: its tabs, but never more than leaves room
    /// for the mark, New and the controls after it; at least one tab's worth.
    private func tabsRoom(_ inner: CGFloat) -> CGFloat {
        let others = controlsWidth + 16 + 22 + Self.spacing * 5
        return max(72, min(TerminalPanel.tabsLimit, inner - others))
    }

    override func layout() {
        super.layout()
        let scale = piScale
        let inner = CGRect(x: Self.padding.left, y: Self.padding.top, width: max(0, bounds.width - Self.padding.left - Self.padding.right),
                           height: max(0, bounds.height - Self.padding.top - Self.padding.bottom))
        func centred(_ height: CGFloat) -> CGFloat { inner.minY + PiKit.round((inner.height - height) / 2, scale) }
        var x = inner.minX
        let markSize = mark.intrinsicContentSize
        mark.frame = CGRect(x: x, y: centred(markSize.height), width: markSize.width, height: markSize.height)
        x += markSize.width + Self.spacing
        if let tabs, !tabsScroll.isHidden {
            let natural = tabs.intrinsicContentSize
            let width = min(max(natural.width, 1), tabsRoom(inner.width))
            tabsScroll.frame = CGRect(x: x, y: centred(natural.height), width: width, height: natural.height)
            tabs.frame = CGRect(x: 0, y: 0, width: natural.width, height: natural.height)
            applyFade(overflows: natural.width > width)
            x += width + Self.spacing
            if let reveal = pendingReveal, width > 0 {
                pendingReveal = nil
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.scrollToTab(reveal.id, animated: reveal.animated) } }
            }
        }
        newTerminal.frame = CGRect(x: x, y: centred(22), width: 22, height: 22)
        x += 22 + Self.spacing
        // The controls at the trailing edge, as one fixed group.
        var right = inner.maxX
        for view in controls.reversed() {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: right - size.width, y: centred(size.height), width: size.width, height: size.height)
            right -= size.width + Self.spacing
        }
        // What is left between, past the spacer's eight points: the title and
        // the folder name when both fit (the name down to forty points), the
        // title alone, or neither (`ViewThatFits`).
        let room = max(0, right + Self.spacing - Self.spacing - x)
        let titleWidth = title.isHidden ? 0 : title.intrinsicContentSize.width
        let titleHeight = title.intrinsicContentSize.height, projectSize = project.intrinsicContentSize
        let both = (title.isHidden ? 0 : titleWidth + Self.spacing) + 40
        if room >= both {
            if !title.isHidden {
                title.frame = CGRect(x: x, y: centred(titleHeight), width: titleWidth, height: titleHeight); x += titleWidth + Self.spacing
            }
            // The folder takes half of what is left, as the stack shares it with the spacer.
            let share = max(40, min(320, (room - (title.isHidden ? 0 : titleWidth + Self.spacing)) / 2))
            let width = min(projectSize.width, share)
            project.isHidden = false
            project.frame = CGRect(x: x, y: centred(projectSize.height), width: max(40, width), height: projectSize.height)
            title.alphaValue = 1
        } else if !title.isHidden, room >= titleWidth {
            title.frame = CGRect(x: x, y: centred(titleHeight), width: titleWidth, height: titleHeight)
            project.isHidden = true
        } else {
            title.frame = .zero; project.isHidden = true
        }
    }

    private func applyFade(overflows: Bool) {
        // A row that scrolls fades at its end, so it reads as more.
        guard overflows else { tabsScroll.layer?.mask = nil; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = tabsScroll.bounds
        let stop = max(0, (tabsScroll.bounds.width - 24) / max(1, tabsScroll.bounds.width))
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: Double(stop)), 1]
        tabsScroll.layer?.mask = fade
        CATransaction.commit()
    }
    /// Shown again (the panel back in a window): its chosen tab in view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let id = selectedID { pendingReveal = (id, false); needsLayout = true }
    }
    /// The chosen tab in view (`ScrollViewReader.scrollTo`).
    private func scrollToTab(_ id: UUID, animated: Bool) {
        guard let tab = tabs?.tab(id) else { return }
        let visible = tabsScroll.contentView.bounds
        var origin = visible.origin
        if tab.frame.minX < visible.minX { origin.x = tab.frame.minX }
        else if tab.frame.maxX > visible.maxX { origin.x = tab.frame.maxX - visible.width }
        else { return }
        // `ScrollViewReader.scrollTo` with no anchor scrolls just enough.
        if animated, !PiKit.Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PiKit.Motion.quick
                tabsScroll.contentView.animator().setBoundsOrigin(origin)
            }
        } else { tabsScroll.contentView.setBoundsOrigin(origin) }
        tabsScroll.reflectScrolledClipView(tabsScroll.contentView)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }
}
