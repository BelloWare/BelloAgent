import AppKit
import Combine

/// The workspace window's content: the sidebar under the window's chrome,
/// its resize handle, and the content column — the error strip over the
/// chat (or what shows in its place) with its pane beside it, the pages laid
/// over them, and the sides panel at the right edge or docked as a column.
@MainActor final class WorkspaceRootView: NSView {
    let model: WorkspaceModel
    /// The pane's tabs beside the chat: the window's, whatever chat is shown.
    let pane: TabContainer

    // The parts, made once.
    let chrome = WindowChromeView()
    private let chromeController = WindowPresentationController(defaults: .standard)
    let sidebar: WorkspaceSidebarView
    let sidebarHandle: PiKit.ResizeHandle
    private let column = WorkspaceContentColumn()
    let errorStrip = WorkspaceErrorStrip()
    /// The chat's region: the chat and its pane, under the pages.
    private let region = WorkspaceRegionView()
    private let chats = WorkspaceChatsLayer()
    private(set) var conversation: ConversationPaneView?
    private var welcome: WorkspaceWelcomeView?
    private var onboarding: OnboardingContentView?
    let splitHandle: PiKit.ResizeHandle
    private(set) var rightPane: RightPaneView?
    private var page: NSView?
    private var shownPage: WorkspacePage?
    private var edge: SidesPanelEdgeView?
    private var pinnedPanel: SidesPanelView?
    private let pinnedLine = ShellHairline()
    private let visibility = ConversationPageVisibilityView()
    private let activityHook = WindowActivityGuard.HookView()
    private let activityGuard: WindowActivityGuard.Coordinator
    private var installCover: WorkspaceInstallCover?
    private let sheets: WorkspaceSheetPresenter
    private let quickOpen: WorkspaceQuickOpenPresenter

    private var observer: ShellObserver!
    private var draggingSidebarWidth: CGFloat?
    private var draggingSideFraction: Double?
    private var splitDragStart: Double?
    /// The window's disabled state (`.disabled` on the SwiftUI around it).
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    /// Reduced motion as the SwiftUI around it has it (`piReduceMotion`).
    var inheritedReduceMotion = false { didSet { if oldValue != inheritedReduceMotion { refresh() } } }
    var reducesMotion: Bool { inheritedReduceMotion || PiKit.Motion.reduced }
    /// What was shown last, so a change that shows nothing new does nothing.
    private struct Geometry: Equatable {
        var sidebarWidth: CGFloat, pinned: Bool, cover: Bool, fraction: Double, showsPane: Bool, page: WorkspacePage
    }
    private var shownGeometry: Geometry?
    private var shownChat: (session: ObjectIdentifier, chat: ChatRecord, enabled: Bool)?
    /// What the pane was last handed: the side's whole record, so a side
    /// that becomes live or kept reaches its pane.
    private struct SideKey: Equatable {
        var side: SideRecord?, session: ObjectIdentifier?, width: CGFloat, enabled: Bool, tabs: [UUID], shown: UUID?
    }
    private var shownSideKey: SideKey?
    private var shownSheets: [AnyHashable?]?
    private var shownVisibility: String?
    nonisolated(unsafe) private var defaultsWatcher: NSObjectProtocol?

    init(model: WorkspaceModel) {
        self.model = model; pane = model.tabs.pane
        sidebar = WorkspaceSidebarView(model: model, width: Self.storedSidebarWidth)
        sidebarHandle = PiKit.ResizeHandle(orientation: .vertical, label: "Resize sidebar",
                                           hint: "Drag left or right, or press Control-Command-Left and Control-Command-Right")
        splitHandle = PiKit.ResizeHandle(orientation: .vertical, label: "Resize the side conversation",
                                         hint: "Drag left or right; the split stays between 30 and 70 per cent")
        activityGuard = WindowActivityGuard.Coordinator(model)
        sheets = WorkspaceSheetPresenter(model: model)
        quickOpen = WorkspaceQuickOpenPresenter(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        wantsLayer = true
        chrome.controller = chromeController
        chromeController.stepVersion = { [weak model] session, step in model?.stepVersion(sessionID: session, step: step) ?? false }
        chromeController.closeTab = { [weak model] in model?.closeShownPaneTab() ?? false }
        chromeController.quickOpenKey = { [weak model] event in model?.quickOpenKey(event) ?? false }
        activityHook.attached = { [weak activityGuard] window in activityGuard?.attach(window) }
        visibility.closeReport = { [weak model] in model?.closeReport() }
        visibility.contentFocus = { [weak self] in self?.pane.shownTab(sideAvailable: true)?.focusView }

        addSubview(activityHook)
        addSubview(visibility)
        column.strip = errorStrip
        column.region = region
        region.chats = chats
        chats.splitHandle = splitHandle
        errorStrip.dismiss = { [weak model] in model?.error = nil }
        errorStrip.heightChanged = { [weak self] in self?.needsLayout = true; self?.column.needsLayout = true }
        for view in [sidebar, chrome, column, sidebarHandle] as [NSView] { addSubview(view) }

        sidebarHandle.changed = { [weak self] translation in
            guard let self else { return }
            let base = self.sidebarDragStart ?? self.sidebarWidth
            if self.sidebarDragStart == nil { self.sidebarDragStart = self.sidebarWidth }
            self.draggingSidebarWidth = WindowChrome.clampSidebarWidth(base + translation)
            self.sidebarHandle.dragging = true
            self.applySidebarWidth()
        }
        sidebarHandle.ended = { [weak self] translation in
            guard let self else { return }
            let landed = WindowChrome.clampSidebarWidth((self.sidebarDragStart ?? self.sidebarWidth) + translation)
            self.sidebarDragStart = nil; self.draggingSidebarWidth = nil; self.sidebarHandle.dragging = false
            UserDefaults.standard.set(Double(landed), forKey: "sidebarWidth")
            self.applySidebarWidth()
        }
        splitHandle.changed = { [weak self] translation in
            guard let self else { return }
            let total = max(1, self.region.bounds.width)
            let base = self.splitDragStart ?? self.sideFraction
            if self.splitDragStart == nil { self.splitDragStart = self.sideFraction }
            self.draggingSideFraction = SplitPane.clampFraction(base + Double(translation / total))
            self.splitHandle.dragging = true
            self.chats.needsLayout = true; self.refresh()
        }
        splitHandle.ended = { [weak self] translation in
            guard let self else { return }
            let total = max(1, self.region.bounds.width)
            let landed = SplitPane.clampFraction((self.splitDragStart ?? self.sideFraction) + Double(translation / total))
            self.splitDragStart = nil; self.draggingSideFraction = nil; self.splitHandle.dragging = false
            UserDefaults.standard.set(landed, forKey: "sidePaneFraction")
            self.chats.needsLayout = true; self.refresh()
        }
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model)
        observer.observe(pane)
        errorStrip.reducesMotion = { [weak self] in self?.reducesMotion ?? PiKit.Motion.reduced }
        // `@AppStorage`: the keyboard's sidebar steps and a stored split land here too.
        defaultsWatcher = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shown = self.shownGeometry else { return }
                if shown.sidebarWidth != self.sidebarWidth || shown.fraction != self.sideFraction { self.refresh() }
            }
        }
        refresh()
    }
    deinit { if let defaultsWatcher { NotificationCenter.default.removeObserver(defaultsWatcher) } }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            chromeController.attach(window, chrome: chrome)
            sheets.attach(window)
            quickOpen.attach(window)
            // What the model asks for reaches the sheets of this window.
            shownSheets = nil; refresh()
        } else {
            chromeController.detach(); activityGuard.detach()
            sheets.detach(); quickOpen.detach()
            shownSheets = nil
            visibility.restoreNativeViews(restoreFocus: false)
        }
    }

    // MARK: Widths

    /// The sidebar keeps the width the user last dragged it to.
    private static var storedSidebarWidth: CGFloat {
        let stored = UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? Double(WindowChrome.sidebarWidth)
        return WindowChrome.clampSidebarWidth(CGFloat(stored))
    }
    private var sidebarDragStart: CGFloat?
    var sidebarWidth: CGFloat { draggingSidebarWidth ?? Self.storedSidebarWidth }
    /// Where the boundary between a chat and its open side sits, kept across launches.
    var sideFraction: Double {
        SplitPane.clampFraction(draggingSideFraction ?? (UserDefaults.standard.object(forKey: "sidePaneFraction") as? Double ?? SplitPane.defaultFraction))
    }
    private func applySidebarWidth() {
        let width = sidebarWidth
        if sidebar.width != width { sidebar.width = width; needsLayout = true }
        if chrome.sidebarWidth != width { chrome.sidebarWidth = width; chrome.needsDisplay = true; needsLayout = true }
    }

    // MARK: What it shows

    /// The chat's side shown beside it, if it has one.
    var shownSide: (info: SideRecord, session: SessionDisplay)? {
        guard model.selected != nil, let chat = model.chat else { return nil }
        return model.sides[chat.id].flatMap { side in model.displays[side.id].map { (side, $0) } }
    }

    func refresh() {
        let enabled = inheritedEnabled && !model.installPreparing
        let onChats = model.page == .chats
        applySidebarWidth()
        chromeController.focusedSessionID = model.focusedSessionID ?? model.selectedID
        if sidebar.inheritedEnabled != enabled { sidebar.inheritedEnabled = enabled }

        // The error strip, above the content column.
        errorStrip.inheritedEnabled = enabled
        errorStrip.show(model.error)

        // The chat, or what shows in its place.
        if let session = model.selected, let chat = model.chat {
            let view = conversation ?? ConversationPaneView(model: model)
            if conversation == nil { conversation = view }
            view.inheritedEnabled = enabled && onChats
            if shownChat?.session != ObjectIdentifier(session) || shownChat?.chat != chat {
                shownChat = (ObjectIdentifier(session), chat, enabled)
                view.show(session: session, chat: chat)
            }
            chats.main = view
        } else if model.launching {
            shownChat = nil
            chats.main = nil
        } else if model.presentsSetup {
            shownChat = nil
            let view = onboarding ?? OnboardingContentView(model: model)
            onboarding = view
            chats.main = view
        } else {
            shownChat = nil
            let view = welcome ?? WorkspaceWelcomeView(model: model)
            welcome = view
            view.inheritedEnabled = enabled && onChats
            view.refresh()
            chats.main = view
        }
        if !(chats.main is OnboardingContentView) { onboarding = nil }
        if !(chats.main is WorkspaceWelcomeView) { welcome = nil }

        // Beside it, the pane: the chat's side and the window's tabs.
        let side = shownSide
        let showsPane = side != nil || !pane.tabs.isEmpty
        chats.fraction = sideFraction
        if showsPane {
            let view = rightPane ?? makeRightPane()
            rightPane = view
            let paneEnabled = enabled && onChats
            let force = view.inheritedEnabled != paneEnabled
            view.inheritedEnabled = paneEnabled
            chats.side = view
            let key = SideKey(side: side?.info, session: side.map { ObjectIdentifier($0.session) }, width: chats.sideWidth, enabled: paneEnabled,
                              tabs: pane.tabs.map(\.id), shown: pane.shownTab(sideAvailable: side != nil)?.id)
            if force || key != shownSideKey {
                shownSideKey = key
                view.update(side: side, width: chats.sideWidth, force: force)
            }
        } else {
            shownSideKey = nil
            chats.side = nil
        }

        // The chats stay mounted under a page.
        chats.covered = !onChats
        if shownPage != model.page {
            shownPage = model.page
            page?.removeFromSuperview(); page = nil
            if !onChats {
                let view = WorkspacePages.make(model.page, model: model)
                region.page = view
                page = view
            } else { region.page = nil }
        }
        if let page { WorkspacePages.update(page, enabled: enabled, reduceMotion: reducesMotion) }

        // The sides panel: at the edge, or docked.
        if model.sidesPanelPinned {
            if edge != nil { column.edge = nil; edge = nil }
            let panel = pinnedPanel ?? SidesPanelView(model: model, parentID: model.selectedID, pinned: true)
            if pinnedPanel == nil { pinnedPanel = panel; addSubview(pinnedLine); addSubview(panel) }
            panel.parentID = model.selectedID
            panel.inheritedEnabled = enabled
            panel.motionReduced = reducesMotion
        } else {
            if let panel = pinnedPanel { panel.removeFromSuperview(); pinnedLine.removeFromSuperview(); pinnedPanel = nil }
            if onChats, !model.launching, let parentID = model.selectedID, model.sidesPanelAvailable(for: parentID) {
                if let edge { edge.show(parentID: parentID) } else {
                    let view = SidesPanelEdgeView(model: model, parentID: parentID, reveal: model.sidesPanelReveal)
                    view.reducesMotion = { [weak self] in self?.reducesMotion ?? PiKit.Motion.reduced }
                    column.edge = view
                    edge = view
                }
                edge?.inheritedEnabled = enabled
                edge?.motionReduced = reducesMotion
            } else if edge != nil { column.edge = nil; edge = nil }
        }

        // Focus and visibility of what a page or a tab covers.
        let covered: Set<String> = side.flatMap { side in pane.shownTab(sideAvailable: true) != nil ? [side.info.id] : nil } ?? []
        let visibilityKey = "\(onChats)|\(model.focusedSessionID ?? "")|" + covered.sorted().joined(separator: ",")
        if visibilityKey != shownVisibility {
            shownVisibility = visibilityKey
            visibility.update(reportVisible: !onChats, focusIdentity: model.focusedSessionID, covered: covered)
        }

        // Every sheet in a sheet window of the app's own, told only of a change.
        let wanted = sheets.wanted + [AnyHashable(enabled), AnyHashable(reducesMotion)]
        if window != nil, wanted != shownSheets {
            shownSheets = wanted
            sheets.update(enabled: enabled, reduceMotion: reducesMotion)
        }
        // ⌘P's list, over the whole window; it goes when a sheet comes.
        if model.presentsSheet { model.quickOpen.close(restoringFocus: false) }

        // While an update installs: drafts are saved, nothing takes input.
        if model.installPreparing {
            if installCover == nil { let cover = WorkspaceInstallCover(); installCover = cover; addSubview(cover) }
        } else if let cover = installCover { cover.removeFromSuperview(); installCover = nil }

        // The window lays out again only when its geometry changed.
        let geometry = Geometry(sidebarWidth: sidebarWidth, pinned: model.sidesPanelPinned, cover: model.installPreparing,
                                fraction: sideFraction, showsPane: showsPane, page: model.page)
        if geometry != shownGeometry { shownGeometry = geometry; needsLayout = true; chats.needsLayout = true }
    }

    /// What the chat and its pane take: the window's state, and only on the chats page.
    private var paneEnabled: Bool { inheritedEnabled && !model.installPreparing && model.page == .chats }
    private func makeRightPane() -> RightPaneView {
        let view = RightPaneView(model: model, host: model.tabs, pane: pane)
        view.makeSideView = { [weak self] info, session, width in
            guard let self else { return NSView() }
            let side = SidePaneView(model: self.model, session: session, info: info, paneWidth: width)
            side.inheritedEnabled = self.paneEnabled
            return side
        }
        view.updateSideView = { [weak self] view, info, _, width in
            guard let self, let side = view as? SidePaneView else { return }
            side.update(info: info, paneWidth: width)
            side.inheritedEnabled = self.paneEnabled
        }
        return view
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = sidebarWidth
        activityHook.frame = bounds; visibility.frame = .zero
        chrome.frame = CGRect(x: 0, y: 0, width: width, height: WindowChrome.height)
        sidebar.frame = CGRect(x: 0, y: WindowChrome.height, width: width, height: max(0, bounds.height - WindowChrome.height))
        // The hairline at the boundary, its handle centred on it.
        let thickness = PiKit.ResizeHandle.hitThickness
        sidebarHandle.frame = CGRect(x: width + 0.5 - thickness / 2, y: 0, width: thickness, height: bounds.height)
        var right = bounds.width
        if let panel = pinnedPanel {
            panel.frame = CGRect(x: bounds.width - SidesPanelMetrics.width, y: 0, width: SidesPanelMetrics.width, height: bounds.height)
            pinnedLine.frame = CGRect(x: panel.frame.minX - 1, y: 0, width: 1, height: bounds.height)
            right = pinnedLine.frame.minX
        }
        column.frame = CGRect(x: width + 1, y: 0, width: max(0, right - width - 1), height: bounds.height)
        if let cover = installCover {
            let size = cover.intrinsicContentSize
            cover.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                                 width: size.width, height: size.height)
        }
        // The handle above everything it borders.
        if subviews.last !== sidebarHandle, installCover == nil { addSubview(sidebarHandle, positioned: .above, relativeTo: nil) }
    }
}

/// The content column: the error strip, then the chat's region under it,
/// the sides panel's edge laid over both at the right.
@MainActor final class WorkspaceContentColumn: NSView {
    var strip: WorkspaceErrorStrip? { didSet { replace(oldValue, strip) } }
    var region: NSView? { didSet { replace(oldValue, region) } }
    var edge: NSView? { didSet { replace(oldValue, edge) } }
    private func replace(_ old: NSView?, _ new: NSView?) {
        guard old !== new else { return }
        old?.removeFromSuperview()
        if let new { addSubview(new) }
        if let edge, edge.superview === self { addSubview(edge, positioned: .above, relativeTo: nil) }
        needsLayout = true
    }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    override func layout() {
        super.layout()
        let stripHeight = strip?.height(forWidth: bounds.width) ?? 0
        strip?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        region?.frame = CGRect(x: 0, y: stripHeight, width: bounds.width, height: max(0, bounds.height - stripHeight))
        edge?.frame = bounds
    }
}

/// The chat's region: the chats (chat and pane) under the page on screen,
/// clipped to the region.
@MainActor final class WorkspaceRegionView: NSView {
    var chats: NSView? { didSet { oldValue?.removeFromSuperview(); if let chats { addSubview(chats, positioned: .below, relativeTo: nil) }; needsLayout = true } }
    var page: NSView? { didSet { oldValue?.removeFromSuperview(); if let page { addSubview(page) }; needsLayout = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        chats?.frame = bounds
        page?.frame = bounds
    }
}

/// The chat (or what shows in its place) and, beside it, the pane, with the
/// split's handle between. Under a page, it stays mounted (transcript,
/// scroll, drafts and any running generation survive), unseen and unheard.
@MainActor final class WorkspaceChatsLayer: NSView {
    var main: NSView? { didSet { swap(oldValue, main) } }
    var side: NSView? { didSet { swap(oldValue, side); splitHandle?.isHidden = side == nil } }
    var splitHandle: PiKit.ResizeHandle? { didSet { oldValue?.removeFromSuperview(); if let splitHandle { addSubview(splitHandle); splitHandle.isHidden = side == nil } } }
    var fraction: Double = SplitPane.defaultFraction { didSet { if oldValue != fraction { needsLayout = true } } }
    var covered = false {
        didSet {
            guard oldValue != covered else { return }
            alphaValue = covered ? 0 : 1
            setAccessibilityElement(false)
            setAccessibilityHidden(covered)
        }
    }
    private func swap(_ old: NSView?, _ new: NSView?) {
        guard old !== new else { return }
        old?.removeFromSuperview()
        if let new { addSubview(new, positioned: .below, relativeTo: splitHandle) }
        needsLayout = true
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { covered ? nil : super.hitTest(point) }
    /// Rounded to whole points so the two panes and their divider add up to the region.
    var mainWidth: CGFloat { side == nil ? bounds.width : SplitPane.mainWidth(total: bounds.width, fraction: fraction) }
    var sideWidth: CGFloat { SplitPane.sideWidth(total: bounds.width, fraction: fraction) }
    override func layout() {
        super.layout()
        let main = mainWidth
        self.main?.frame = CGRect(x: 0, y: 0, width: main, height: bounds.height)
        if let side {
            side.frame = CGRect(x: main + SplitPane.dividerWidth, y: 0, width: sideWidth, height: bounds.height)
            let thickness = PiKit.ResizeHandle.hitThickness
            splitHandle?.frame = CGRect(x: main + 0.5 - thickness / 2, y: 0, width: thickness, height: bounds.height)
        }
    }
}

/// "Saving drafts and preparing to close…" over the window while an update installs.
@MainActor final class WorkspaceInstallCover: NSView {
    private let row = ShellStack(.horizontal, spacing: PiSpacing.md, padding: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), [
        .view(PiKit.spinner(controlSize: .small)),
        .view(PiKit.TextLine(PiKit.Line("Saving drafts and preparing to close…", font: PiKit.Font.body, color: .piInk))),
    ])
    private lazy var box = PiKit.elevated(row, radius: 18)
    override init(frame: NSRect) { super.init(frame: frame); addSubview(box) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: row.intrinsicContentSize.width, height: row.height(forWidth: row.intrinsicContentSize.width)) }
    override func layout() { super.layout(); box.frame = bounds }
}

/// Where the boundary between an open chat and its side conversation sits, as
/// the chat's share of the content column. Bounded so neither pane can be
/// squeezed to a sliver, and rounded to whole points so the two panes plus
/// their divider always add up to the column exactly.
enum SplitPane {
    static let defaultFraction = 0.5
    static let minimumFraction = 0.30
    static let maximumFraction = 0.70
    static let dividerWidth: CGFloat = 1
    static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFraction }
        return min(maximumFraction, max(minimumFraction, value))
    }
    static func mainWidth(total: CGFloat, fraction: Double) -> CGFloat {
        guard total.isFinite, total > dividerWidth + 2 else { return max(0, total - dividerWidth) }
        let usable = total - dividerWidth
        return min(usable - 1, max(1, (usable * CGFloat(clampFraction(fraction))).rounded(.down)))
    }
    static func sideWidth(total: CGFloat, fraction: Double) -> CGFloat {
        max(0, total - dividerWidth - mainWidth(total: total, fraction: fraction))
    }
}

// MARK: - The error strip

/// Errors used to be a modal alert: a background save failure interrupted
/// typing with the same weight as a failed send, and the text vanished on
/// OK. The strip stays until dismissed and never steals focus. Its room is
/// taken and given back in one step, so the conversation's edge never drags
/// the line the reader is on; the banner itself comes down from above and
/// fades in (`PiMotion.reveal`), and fades up and out as it goes.
@MainActor final class WorkspaceErrorStrip: NSView {
    var dismiss: (() -> Void)?
    /// The strip's height changed: the column lays out again.
    var heightChanged: (() -> Void)?
    /// Motion as the window has it (reduced there, or for the whole app).
    var reducesMotion: () -> Bool = { PiKit.Motion.reduced }
    private(set) var banner: ErrorBannerView?
    private var leaving: [ErrorBannerView] = []
    /// `.padding(.horizontal, xl).padding(.top, md).padding(.bottom, sm)` around the banner.
    private static let insets = NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.xl, bottom: PiSpacing.sm, right: PiSpacing.xl)
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { banner == nil ? nil : super.hitTest(point) }
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { banner?.inheritedEnabled = inheritedEnabled } } }

    func show(_ text: String?) {
        guard text != banner?.text else { return }
        let animates = window != nil && !reducesMotion()
        if let banner, let text {
            // Another error replaces this one's words in place.
            banner.update(text: text)
        } else if let text {
            let view = ErrorBannerView(text: text)
            view.dismiss = { [weak self] in self?.dismiss?() }
            view.sizeChanged = { [weak self] in self?.needsLayout = true; self?.heightChanged?() }
            view.inheritedEnabled = inheritedEnabled
            banner = view
            addSubview(view)
            if animates { layoutSubtreeIfNeeded(); move(view, arriving: true) }
        } else if let banner {
            self.banner = nil
            if animates { leaving.append(banner); move(banner, arriving: false) } else { banner.removeFromSuperview() }
        }
        needsLayout = true
        heightChanged?()
    }
    /// Down from above and in, or up and out (`.move(edge: .top)` with opacity, `PiMotion.base`).
    private func move(_ view: ErrorBannerView, arriving: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { if !arriving { view.removeFromSuperview() }; return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = arriving ? 0 : 1; fade.toValue = arriving ? 1 : 0
        let shift = view.frame.maxY * (self.layer?.isGeometryFlipped == true ? -1 : 1)
        let slide = CABasicAnimation(keyPath: "position.y")
        slide.fromValue = layer.position.y + (arriving ? shift : 0); slide.toValue = layer.position.y + (arriving ? 0 : shift)
        let group = CAAnimationGroup(); group.animations = [fade, slide]
        group.duration = PiKit.Motion.base; group.timingFunction = PiKit.Motion.timing(.easeOut)
        group.fillMode = arriving ? .backwards : .forwards; group.isRemovedOnCompletion = arriving
        CATransaction.begin()
        if !arriving {
            CATransaction.setCompletionBlock { [weak self, weak view] in view?.removeFromSuperview(); self?.leaving.removeAll { $0 === view } }
            DispatchQueue.main.asyncAfter(deadline: .now() + PiKit.Motion.base + 0.05) { [weak self, weak view] in
                guard let view else { return }
                view.removeFromSuperview(); self?.leaving.removeAll { $0 === view }
            }
        }
        layer.add(group, forKey: arriving ? "arrive" : "leave")
        CATransaction.commit()
    }
    /// The strip's height: the banner's with its insets, or none.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let banner else { return 0 }
        return Self.insets.top + banner.height(forWidth: bannerWidth(width)) + Self.insets.bottom
    }
    /// `.frame(maxWidth: 640)`, in the middle of the strip.
    private func bannerWidth(_ width: CGFloat) -> CGFloat { min(640, max(0, width - Self.insets.left - Self.insets.right)) }
    override func layout() {
        super.layout()
        // A leaving banner keeps its place over the conversation as it goes.
        for view in [banner].compactMap({ $0 }) + leaving where view === banner {
            let width = bannerWidth(bounds.width)
            view.frame = CGRect(x: PiKit.round((bounds.width - width) / 2, piScale), y: Self.insets.top, width: width, height: view.height(forWidth: width))
        }
    }
}

/// Non-modal error strip at the top of the window. A gateway can return
/// kilobytes of explanation, so the strip stays three lines tall until it is
/// opened, then scrolls inside a bounded box; Copy takes the whole message
/// whether it is open or not.
@MainActor final class ErrorBannerView: NSView, PiKit.WidthSizing {
    private(set) var text: String
    var dismiss: (() -> Void)?
    var sizeChanged: (() -> Void)?
    /// Where Copy writes; a test passes its own rather than the owner's clipboard.
    var pasteboard: NSPasteboard = .general
    private(set) var expanded: Bool
    /// The window's disabled state: More, Copy and Dismiss go quiet with it.
    var inheritedEnabled = true {
        didSet { guard oldValue != inheritedEnabled else { return }; for button in [more, copyButton, dismissButton] { button.isEnabled = inheritedEnabled } }
    }
    /// Longer than this and the strip offers to open; the figure is about three
    /// lines at the strip's width.
    static let collapsedCharacters = 220
    static let expandedHeight: CGFloat = 220
    static func canExpand(_ text: String) -> Bool { text.count > collapsedCharacters || text.contains("\n") }
    var canExpand: Bool { Self.canExpand(text) }
    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }

    private let icon = PiKit.SymbolView(PiKit.Symbol("exclamationmark.triangle.fill", size: 13, weight: .semibold), color: .piDanger)
    let message: ShellSelectableText
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    let more = PiKit.Button("More", style: .ghost)
    let copyButton = PiKit.Button("Copy", style: .ghost)
    let dismissButton = PiKit.Button("Dismiss", style: .secondary, compact: true)
    private let buttons: ShellStack
    private let card = CALayer(), wash = CALayer(), stroke = CALayer()

    init(text: String, expanded: Bool = false) {
        self.text = text; self.expanded = expanded
        message = ShellSelectableText(text, font: PiKit.Font.body, color: .piInk)
        buttons = ShellStack(.horizontal, spacing: 2, [.view(more), .view(copyButton), .view(dismissButton)])
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(card); card.addSublayer(wash); card.addSublayer(stroke)
        card.cornerCurve = .continuous; wash.cornerCurve = .continuous; stroke.cornerCurve = .continuous
        card.zPosition = -1
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        for view in [icon, buttons] as [NSView] { addSubview(view) }
        more.setAccessibilityIdentifier("errorBannerExpand")
        copyButton.setAccessibilityIdentifier("errorBannerCopy")
        dismissButton.setAccessibilityIdentifier("errorBannerDismiss")
        message.setAccessibilityIdentifier("errorBannerText")
        more.onPress = { [weak self] in guard let self else { return }; self.setExpanded(!self.expanded) }
        copyButton.onPress = { [weak self] in guard let self else { return }; Self.copy(self.text, to: self.pasteboard) }
        dismissButton.onPress = { [weak self] in self?.dismiss?() }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("errorBanner")
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(text: String) {
        guard text != self.text else { return }
        self.text = text
        message.text = text
        apply()
    }
    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        apply()
    }
    /// A strip left open by one error must not open a short one that follows.
    private var opened: Bool { expanded && canExpand }
    private func apply() {
        setAccessibilityLabel("Error: " + text)
        more.isHidden = !canExpand
        more.title = expanded ? "Less" : "More"
        message.maximumLines = opened ? 0 : 3
        message.removeFromSuperview()
        if opened {
            message.text = text
            document.addSubview(message)
            if scroll.superview == nil { addSubview(scroll) }
        } else {
            scroll.removeFromSuperview()
            addSubview(message)
        }
        buttons.relayoutAll()
        invalidateIntrinsicContentSize(); needsLayout = true
        sizeChanged?()
    }

    // `HStack(alignment: .top, spacing: 8) { icon.padding(.top, 2); message; Spacer(minLength: 8); buttons }`,
    // `.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)`.
    private var buttonsWidth: CGFloat { buttons.intrinsicContentSize.width }
    private var iconWidth: CGFloat { icon.symbol.layoutSize.width }
    private func messageWidth(_ width: CGFloat) -> CGFloat { max(0, width - 12 - iconWidth - 8 - 8 - 8 - 8 - buttonsWidth - 4) }
    private func messageHeight(_ width: CGFloat) -> CGFloat {
        let full = message.height(forWidth: messageWidth(width))
        return opened ? min(Self.expandedHeight, full) : full
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        8 + max(2 + icon.symbol.layoutSize.height, messageHeight(width), buttons.height(forWidth: buttonsWidth)) + 8
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 640)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let box = icon.symbol.layoutSize
        icon.frame = CGRect(x: 12, y: 8 + 2, width: box.width, height: box.height)
        let width = messageWidth(bounds.width), height = messageHeight(bounds.width)
        let origin = CGPoint(x: 12 + box.width + 8, y: 8)
        if opened {
            scroll.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            scroll.shellFit(document) { message.height(forWidth: $0) }
            message.frame = document.bounds
        } else {
            // Three lines, the last cut where `Text` cuts it.
            let shown = ShellWrap.cut(text, font: PiKit.Font.body, width: width, lines: 3, scale: piScale)
            if message.text != shown { message.text = shown }
            message.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        }
        let size = CGSize(width: buttonsWidth, height: buttons.height(forWidth: buttonsWidth))
        buttons.frame = CGRect(x: bounds.width - 4 - size.width, y: 8, width: size.width, height: size.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.frame = bounds; wash.frame = card.bounds
        card.cornerRadius = PiRadius.md; wash.cornerRadius = PiRadius.md
        // A stroke centred on the edge, half outside, as `.stroke(lineWidth: 1)` draws it.
        stroke.frame = card.bounds.insetBy(dx: -0.5, dy: -0.5)
        stroke.cornerRadius = PiRadius.md + 0.5; stroke.borderWidth = 1
        card.shadowPath = CGPath(roundedRect: bounds, cornerWidth: PiRadius.md, cornerHeight: PiRadius.md, transform: nil)
        card.shadowRadius = PiKit.shadowRadius(12); card.shadowOffset = CGSize(width: 0, height: -4); card.shadowOpacity = 1
        CATransaction.commit()
        updateLayer()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // A wash of the danger colour over the surface, so the strip reads as
        // a failure at the same strength in both appearances.
        card.backgroundColor = piCGColor(.piSurface)
        wash.backgroundColor = piCGColor(NSColor.piDanger.withAlphaComponent(0.10))
        stroke.borderColor = piCGColor(NSColor.piDanger.withAlphaComponent(0.55))
        card.shadowColor = piCGColor(.piShadow)
    }
}

// MARK: - Welcome

/// The app's mark at 84 points (`.resizable().interpolation(.high).frame(width: 84, height: 84)`).
@MainActor final class WorkspaceWelcomeIcon: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: 84, height: 84) }
}

/// No chat open: the app's mark, what it is for, and the next step.
@MainActor final class WorkspaceWelcomeView: NSView {
    let model: WorkspaceModel
    private let icon = WorkspaceWelcomeIcon()
    /// Wraps in a narrow pane, as the unrestricted `Text` did.
    private let title = ShellText("What are we working on?", font: PiKit.Font.display(30), color: .piInk)
    private let words = ShellText("", font: PiKit.Font.body, color: .piInkSecondary)
    private let text: ShellStack
    /// `.frame(maxWidth: 460)`: the words' width, less in a narrower pane.
    private var wordsWidth: CGFloat = 460
    private let buttons = ShellStack(.horizontal, spacing: PiSpacing.md)
    private let column: ShellStack
    private var shown: [String]?
    let newChat = PiKit.Button("New Chat", symbol: "square.and.pencil", style: .primary)
    let projects = PiKit.Button("Projects…", symbol: "folder", style: .secondary)
    let connections = PiKit.Button("Connections…", symbol: "slider.horizontal.3", style: .secondary)

    init(model: WorkspaceModel) {
        self.model = model
        text = ShellStack(.vertical, spacing: 8, alignment: .center, [.view(title, .flexible), .view(words, .fixed(460))])
        column = ShellStack(.vertical, spacing: PiSpacing.lg, alignment: .center, [.view(icon), .view(text), .view(buttons)])
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(named: "BelloAgentIcon"); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Bello Agent")
        words.centred = true; words.lineSpacing = 3
        title.centred = true
        newChat.setAccessibilityIdentifier("welcome-new-chat")
        newChat.onPress = { [weak self] in guard let self, let workspace = self.readyWorkspace else { return }; self.model.newChat(in: workspace.id) }
        projects.onPress = { [weak self] in self?.model.showWorkspaceManager = true }
        connections.onPress = { [weak self] in self?.model.showProfiles = true }
        addSubview(column)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    /// The project a new chat would start in: the chosen one, else the first trusted one.
    private var readyWorkspace: WorkspaceRecord? {
        model.workspaces.first { $0.id == model.selectedWorkspaceID && $0.trusted } ?? model.workspaces.first(where: \.trusted)
    }
    /// The window's disabled state: the welcome's buttons go quiet with it.
    var inheritedEnabled = true {
        didSet { guard oldValue != inheritedEnabled else { return }; for button in [newChat, projects, connections] { button.isEnabled = inheritedEnabled } }
    }
    func refresh() {
        let workspace = readyWorkspace
        let ready = workspace != nil && !model.requestProfiles.isEmpty
        let text = ready ? "Start a new chat in \(workspace.map(WorkspaceLabel.name) ?? "your project"), or pick a chat in the sidebar.\nSide conversations, exact HTTP inspection and cost accounting are built in."
            : "Create a project from one or more trusted folders and connect a LiteLLM route to start a chat.\nSide conversations, exact HTTP inspection and cost accounting are built in."
        let key = [text, "\(ready)", "\(model.workspaces.isEmpty)", "\(model.requestProfiles.isEmpty)"]
        guard key != shown else { return }
        shown = key
        words.set(text, color: .piInkSecondary)
        if ready {
            // Both halves exist: the next step is a chat, not another setup sheet.
            projects.title = "Projects…"; projects.style = .secondary
            connections.title = "Connections…"
            buttons.items = [.view(newChat), .view(projects), .view(connections)]
        } else {
            projects.title = model.workspaces.isEmpty ? "Create a project" : "Projects…"; projects.style = .primary
            connections.title = model.requestProfiles.isEmpty ? "Add a Connection…" : "Connections…"
            buttons.items = [.view(projects), .view(connections)]
        }
        buttons.relayoutAll(); column.relayoutAll()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let room = min(460, bounds.width)
        if room != wordsWidth { wordsWidth = room; text.items = [.view(title, .flexible), .view(words, .fixed(room))]; column.relayoutAll() }
        let width = min(bounds.width, max(column.intrinsicContentSize.width, room))
        let height = column.height(forWidth: width)
        // Centred, the half pixel left over going below (as SwiftUI places it).
        let scale = piScale
        column.frame = CGRect(x: PiKit.round((bounds.width - width) / 2, scale), y: floor((bounds.height - height) / 2 * scale) / scale, width: width, height: height)
    }
}

// MARK: - ⌘P

/// Puts ⌘P's list over the window the list took the keys from, and takes it
/// away when the list closes.
@MainActor final class WorkspaceQuickOpenPresenter {
    let model: WorkspaceModel
    private weak var window: NSWindow?
    private var cover: QuickOpenOverlay?
    private var observer: ShellObserver!
    init(model: WorkspaceModel) {
        self.model = model
        observer = ShellObserver { [weak self] in self?.sync() }
        observer.observe(model.quickOpen)
    }
    private var attached = false
    func attach(_ window: NSWindow) { attached = true; sync() }
    /// The window went: the list goes, and nothing puts it back until the root is in a window again.
    func detach() { attached = false; close() }
    private func sync() {
        guard attached else { close(); return }
        let quickOpen = model.quickOpen
        guard let target = quickOpen.presentationWindow, let content = target.contentView else { close(); return }
        guard window !== target || cover?.superview !== content else { return }
        close()
        let overlay = QuickOpenOverlay(quickOpen: quickOpen) { [weak model] id in model?.openQuickOpenChoice(id) }
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        window = target; cover = overlay
    }
    private func close() { cover?.removeFromSuperview(); cover = nil; window = nil }
}
