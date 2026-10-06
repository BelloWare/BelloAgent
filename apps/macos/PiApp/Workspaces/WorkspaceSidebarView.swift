import AppKit
import Combine

// The sidebar column: its header with the new-chat and project buttons, the
// filter, the bar that appears while rows are marked, the list itself, and
// the bar of buttons along the bottom.

@MainActor final class WorkspaceSidebarView: NSView {
    let model: WorkspaceModel
    /// A project header drops its buttons when the reader has pulled the
    /// sidebar in far enough that they would eat the project's name.
    var width: CGFloat = WindowChrome.sidebarWidth { didSet { if oldValue != width { refresh(animated: false) } } }

    private var observer: ShellObserver!
    private var layoutWatch: AnyCancellable?
    private let title = PiKit.TextLine(PiKit.Line("Projects", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.5, uppercased: true))
    let newChat = PiKit.IconButton(symbol: "square.and.pencil", label: "New Chat (⌘N)", tone: .accent, size: 24, filled: true)
    let manage = PiKit.IconButton(symbol: "folder.badge.plus", label: "Add or manage projects", size: 24)
    let filterField = PiKit.TextField(placeholder: "Filter chats and topics", icon: "magnifyingglass")
    private let filterKeys = SidebarFilterDelegate()
    let selectionBar: SidebarSelectionBarView
    let scroll = NSScrollView()
    let list: SidebarListDocument
    private let empty = SidebarEmptyView()
    private let hairline = NSView()
    let report = PiKit.IconButton(symbol: "chart.xyaxis.line", label: "Usage Report (⇧⌘R)")
    let inspector = PiKit.IconButton(symbol: "ladybug", label: "Session Inspector · what this chat sent and received")
    let resources = PiKit.IconButton(symbol: "book.closed", label: "Skills, instructions and MCP servers for this project")
    let background = PiKit.IconButton(symbol: "sparkles.rectangle.stack", label: "Background requests · chat titles, title suggestions and webhooks (⇧⌘B)")
    let archive = PiKit.IconButton(symbol: "archivebox", label: "Show archived chats")
    let settings = PiKit.IconButton(symbol: "gearshape", label: "Settings · connections, keys and preferences")

    /// Whether the window around the sidebar lets it be used: SwiftUI's
    /// `.disabled` on the workspace while an install is being prepared.
    var inheritedEnabled = true {
        didSet {
            guard inheritedEnabled != oldValue else { return }
            list.inheritedEnabled = inheritedEnabled
            refreshChrome()
        }
    }

    /// What the filter says (the model is told too: marking a range and
    /// stepping with the keyboard follow what it left listed).
    private(set) var filter = ""
    // What used to be the groups' own state.
    private var confirmingRemove: Set<String> = []
    private var removing: Set<String> = []
    private var dropTarget: (project: String, topic: String?)?
    /// The next change comes from something the reader did that moves the
    /// list (a disclosure, the archive switch, a page): rows glide.
    private var glideNext = false
    private var shownRevision: Int?
    private var shownWidth: CGFloat = -1
    private var barShown = false
    private var revealKey: RevealKey?

    init(model: WorkspaceModel, width: CGFloat = WindowChrome.sidebarWidth) {
        self.model = model
        self.width = width
        selectionBar = SidebarSelectionBarView(model: model)
        list = SidebarListDocument(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)

        newChat.setAccessibilityIdentifier("newChat")
        newChat.onPress = { [weak self] in self?.model.newChat() }
        manage.setAccessibilityIdentifier("manageProjects")
        manage.onPress = { [weak self] in self?.model.showWorkspaceManager = true }

        filterField.field.delegate = filterKeys
        filterKeys.changed = { [weak self] in self?.filterChanged($0) }
        filterKeys.escape = { [weak self] in self?.escapeFromFilter() }
        filterField.field.setAccessibilityLabel("Filter chats and topics by title")
        filterField.field.setAccessibilityIdentifier("sidebarFilter")

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = list
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // A legacy scroller coming or going narrows or widens the rows.
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        list.setProjectExpanded = { [weak self] id, expanded in self?.glide { $0.model.setProjectExpanded(id, expanded: expanded) } }
        list.setTopicExpanded = { [weak self] id, expanded in self?.glide { $0.model.setTopicExpanded(id, expanded: expanded) } }
        list.confirmRemove = { [weak self] id in self?.confirmingRemove.insert(id); self?.refresh(animated: false) }
        list.cancelRemove = { [weak self] id in self?.confirmingRemove.remove(id); self?.refresh(animated: false) }
        list.removeTopic = { [weak self] id in self?.remove(topic: id) }
        list.setShownRoots = { [weak self] group, count, project in self?.glide { $0.model.setSidebarShownRoots(group, to: count, in: project) } }
        list.setSideFolded = { [weak self] id, folded in self?.glide { $0.model.setSidebarSideFolded(id, folded: folded) } }
        list.dropTargetChanged = { [weak self] target in
            guard let self, self.dropTarget?.project != target?.project || self.dropTarget?.topic != target?.topic else { return }
            self.dropTarget = target; self.refresh(animated: false)
        }

        empty.add.onPress = { [weak self] in self?.model.showWorkspaceManager = true }
        hairline.wantsLayer = true

        report.setAccessibilityIdentifier("requestDashboard")
        report.onPress = { [weak self] in self?.model.toggleReport() }
        inspector.setAccessibilityIdentifier("requestInspector")
        inspector.onPress = { [weak self] in if let id = self?.model.selectedID { self?.model.inspect(id) } }
        resources.setAccessibilityIdentifier("projectResources")
        resources.onPress = { [weak self] in self?.model.inspectResources(self?.model.selectedID) }
        background.setAccessibilityIdentifier("backgroundRequests")
        background.onPress = { [weak self] in self?.model.toggleBackgroundRequests() }
        // One switch for every project: each lists its archived chats after
        // its active ones while it is on.
        archive.setAccessibilityIdentifier("archivedChatsToggle")
        archive.onPress = { [weak self] in self?.glide { $0.model.toggleArchivedChats() } }
        settings.setAccessibilityIdentifier("openSettings")
        settings.onPress = { [weak self] in self?.model.showProfiles = true }

        selectionBar.isHidden = true
        for view in [title, newChat, manage, filterField, selectionBar, scroll, empty, hairline,
                     report, inspector, resources, background, archive, settings] as [NSView] { addSubview(view) }
        model.sidebarFilter = filter
        observer = ShellObserver { [weak self] in self?.refresh(animated: nil) }
        observer.observe(model)
        // A change waiting for its turn is also applied by the next layout
        // pass, should that come first (a window drawn at once).
        layoutWatch = model.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.needsLayout = true } }
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var isFlipped: Bool { true }
    /// Disabled, nothing in the column takes a press, a right-click or a drag.
    override func hitTest(_ point: NSPoint) -> NSView? { inheritedEnabled ? super.hitTest(point) : nil }
    /// The column is as wide as it is drawn, whoever sizes it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, newSize.width != width { width = newSize.width }
    }

    // MARK: Changes

    /// Applies what changed now, rather than on the next turn (tests).
    func settle() { observer.flush(); layoutSubtreeIfNeeded() }

    private func glide(_ change: (WorkspaceSidebarView) -> Void) {
        glideNext = true
        change(self)
        observer.flush()
    }

    /// Works out the list again and changes only what changed. `animated`
    /// nil lets the change decide: rows glide when the reader moved them.
    func refresh(animated: Bool?) {
        let revision = model.organizationPresentationRevision
        let glides = animated ?? (glideNext || shownRevision.map { $0 != revision } ?? false)
        glideNext = false; shownRevision = revision
        let contents = SidebarListContents.build(model: model, filter: filter, sidebarWidth: width,
                                                 confirmingRemove: confirmingRemove, removing: removing, dropTarget: dropTarget)
        let listWidth = scroll.contentSize.width > 0 ? scroll.contentSize.width : width
        if contents != list.contents || listWidth != shownWidth {
            shownWidth = listWidth
            list.update(contents, width: listWidth, animated: glides && window != nil)
        }
        refreshChrome()
        // Unfolding what hides the open chat changes the list: show it now.
        if revealOpenChats() { observer.flush() }
    }

    private func refreshChrome() {
        let trusted = model.workspaces.contains { $0.id == model.selectedWorkspaceID && $0.trusted }
        let enabled = inheritedEnabled
        newChat.isEnabled = trusted && enabled
        newChat.label = model.selectedWorkspaceID == nil ? "Create or choose a project before starting a chat" : "New Chat (⌘N)"
        let onReport = model.page == .report, onBackground = model.page == .background
        report.label = onReport ? "Back to Chats" : "Usage Report (⇧⌘R)"
        Self.set(report, tone: onReport ? .accent : .neutral, filled: onReport)
        inspector.isEnabled = model.selectedID != nil && enabled
        resources.isEnabled = model.selectedWorkspaceID != nil && enabled
        for button in [manage, report, background, archive, settings] { button.isEnabled = enabled }
        filterField.field.isEnabled = enabled
        empty.add.isEnabled = enabled
        for button in [selectionBar.copy, selectionBar.archiveWord, selectionBar.clearWord, selectionBar.archiveIcon, selectionBar.clearIcon] {
            button.isEnabled = enabled
        }
        background.label = onBackground ? "Back to Chats" : "Background requests · chat titles, title suggestions and webhooks (⇧⌘B)"
        Self.set(background, tone: onBackground ? .accent : .neutral, filled: onBackground)
        let archived = model.sidebarShowsArchived
        archive.label = archived ? "Hide archived chats" : "Show archived chats"
        Self.set(archive, tone: archived ? .accent : .neutral, filled: archived)
        // During first-run setup the setup's own last step adds the project:
        // a second way in beside it read as two paths.
        empty.isHidden = !(model.sidebarProjects.isEmpty && !model.presentsSetup)
        let marked = model.hasMarkedSessions
        if marked { selectionBar.refresh() }
        if marked != barShown {
            barShown = marked
            showBar(marked)
        }
    }

    /// A button's look changed only when it changes: setting it redraws it.
    private static func set(_ button: PiKit.IconButton, tone: PiTone, filled: Bool) {
        if button.tone != tone { button.tone = tone }
        if button.filled != filled { button.filled = filled }
    }

    /// Marking rows takes a strip above the list; the list moves down to
    /// make room rather than jumping (`PiKit.Motion.base`), and the strip comes
    /// down from under the filter (`PiKit.Motion.reveal`).
    private func showBar(_ shown: Bool) {
        let before = scroll.frame.minY
        selectionBar.isHidden = false
        needsLayout = true; layoutSubtreeIfNeeded()
        let delta = scroll.frame.minY - before
        let animates = window != nil && !PiKit.Motion.reduced
        if !shown {
            if animates, let layer = selectionBar.layer {
                // It goes back up under the filter as it fades.
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self else { return }
                    self.selectionBar.layer?.removeAnimation(forKey: "leave")
                    if !self.barShown { self.selectionBar.isHidden = true }
                }
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
                let move = CABasicAnimation(keyPath: "transform.translation.y"); move.fromValue = 0; move.toValue = -selectionBar.bounds.height
                let group = CAAnimationGroup(); group.animations = [fade, move]
                group.duration = PiKit.Motion.base; group.timingFunction = PiKit.Motion.timing(.easeOut)
                group.fillMode = .forwards; group.isRemovedOnCompletion = false
                layer.add(group, forKey: "leave")
                CATransaction.commit()
            } else { selectionBar.isHidden = true }
        } else if animates {
            selectionBar.layer?.removeAnimation(forKey: "leave")
            PiKit.arrive(selectionBar)
        }
        guard animates, delta != 0 else { return }
        scroll.wantsLayer = true
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -delta; slide.toValue = 0
        slide.duration = PiKit.Motion.base; slide.timingFunction = PiKit.Motion.timing(.easeOut)
        scroll.layer?.add(slide, forKey: "slide")
    }

    private func filterChanged(_ value: String) {
        filter = value
        model.sidebarFilter = value
        refresh(animated: false)
    }
    private func escapeFromFilter() {
        if model.hasMarkedSessions { model.clearSessionMarks() } else {
            filterField.text = ""
            if !filter.isEmpty { filterChanged("") }
            model.focusComposer()
        }
    }
    /// Sets the filter as typing would.
    func setFilter(_ value: String) { filterField.text = value; filterChanged(value) }

    private func remove(topic id: String) {
        guard !removing.contains(id) else { return }
        removing.insert(id); refresh(animated: false)
        let model = model
        Task { [weak self] in
            do {
                try await model.removeTopic(id)
                self?.confirmingRemove.remove(id)
            } catch { model.error = error.localizedDescription }
            self?.removing.remove(id); self?.refresh(animated: false)
        }
    }

    @objc private func scrolled() { list.materialize() }
    @objc private func clipResized() {
        let listWidth = scroll.contentSize.width
        guard listWidth > 0, listWidth != shownWidth else { return }
        shownWidth = listWidth
        list.update(list.contents, width: listWidth, animated: false)
    }

    // MARK: Opening a chat unfolds whatever hides it

    /// What a reveal depends on: which chat is open, and which group it is in.
    private struct RevealKey: Equatable {
        var selected: String?
        var focused: String?
        var selectedTopic: String?
        var focusedTopic: String?
    }
    @discardableResult private func revealOpenChats() -> Bool {
        let key = RevealKey(selected: model.selectedID, focused: model.focusedSessionID,
                            selectedTopic: model.selectedID.flatMap { model.record($0)?.topicID },
                            focusedTopic: model.focusedSessionID.flatMap { model.record($0)?.topicID })
        guard key != revealKey else { return false }
        revealKey = key
        revealAncestors(of: model.selectedID)
        revealAncestors(of: model.focusedSessionID)
        return true
    }
    private func revealAncestors(of id: String?) {
        // A chat the reader clicked in the sidebar, or reached in a pane on
        // screen, was already in view: nothing unfolds for it.
        guard let id, !model.quietSidebarReveal.contains(id), let selected = model.record(id),
              model.sidebarProjects.contains(where: { $0.record.id == selected.workspaceID }) else { return }
        let project = selected.workspaceID
        var parent = selected.parentSessionID, seen: Set<String> = [], reveal: Set<String> = []
        while let id = parent, seen.insert(id).inserted, let item = model.record(id), item.workspaceID == project {
            reveal.insert(id); parent = item.parentSessionID
        }
        model.revealSidebarSides(reveal, in: project)
    }

    // MARK: Layout

    static let headerHeight: CGFloat = 38
    static let bottomBarHeight: CGFloat = 40
    override func layout() {
        // A change still waiting for its turn is laid out with everything else.
        observer.flush()
        super.layout()
        let w = bounds.width
        // `.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)`.
        let titleSize = title.intrinsicContentSize
        manage.frame = CGRect(x: w - PiSpacing.lg - 24, y: 10, width: 24, height: 24)
        newChat.frame = CGRect(x: manage.frame.minX - 4 - 24, y: 10, width: 24, height: 24)
        title.frame = CGRect(x: PiSpacing.lg, y: PiKit.round(10 + (24 - titleSize.height) / 2, piScale),
                             width: min(titleSize.width, max(0, newChat.frame.minX - 4 - PiSpacing.lg)), height: titleSize.height)
        var y = Self.headerHeight
        let fieldHeight = filterField.intrinsicContentSize.height
        filterField.frame = CGRect(x: PiSpacing.md, y: y, width: max(0, w - PiSpacing.md * 2), height: fieldHeight)
        y += fieldHeight + 6
        if barShown {
            let height = selectionBar.height(forWidth: max(0, w - PiSpacing.md * 2))
            selectionBar.frame = CGRect(x: PiSpacing.md, y: y, width: max(0, w - PiSpacing.md * 2), height: height)
            y += height + 6
        }
        let bottom = bounds.height - Self.bottomBarHeight - 1
        let scrollFrame = CGRect(x: 0, y: y, width: w, height: max(0, bottom - y))
        if scroll.frame != scrollFrame {
            scroll.frame = scrollFrame
            let listWidth = scroll.contentSize.width
            if listWidth != shownWidth { shownWidth = listWidth; list.update(list.contents, width: listWidth, animated: false) }
            else { list.materialize() }
        }
        let emptyHeight = empty.height(forWidth: w)
        empty.frame = CGRect(x: 0, y: scrollFrame.minY + PiKit.round((scrollFrame.height - emptyHeight) / 2, piScale), width: w, height: emptyHeight)
        hairline.frame = CGRect(x: 0, y: bottom, width: w, height: 1)
        // `HStack(spacing: 2)`, `.padding(.horizontal, 8).padding(.vertical, 6)`.
        var x = PiSpacing.sm
        for button in [report, inspector, resources, background, archive] {
            button.frame = CGRect(x: x, y: bottom + 1 + 6, width: 28, height: 28); x += 28 + 2
        }
        settings.frame = CGRect(x: w - PiSpacing.sm - 28, y: bottom + 1 + 6, width: 28, height: 28)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piWindow)
        hairline.layer?.backgroundColor = piCGColor(.piHairline)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh(animated: false) }
    }
}

/// The filter field's keys: typing filters, Escape clears the marks or the
/// filter and goes back to the composer (`.onExitCommand`).
@MainActor final class SidebarFilterDelegate: NSObject, NSTextFieldDelegate {
    var changed: ((String) -> Void)?
    var escape: (() -> Void)?
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        changed?(field.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        escape?(); return true
    }
}

/// With no project yet: a folder, a line, and the way to add one.
@MainActor final class SidebarEmptyView: NSView {
    private let icon = PiKit.SymbolView(PiKit.Symbol("folder.badge.plus", size: 24), color: .piInkTertiary)
    private let text = ShellText("Add a project to start chatting.", font: PiKit.Font.caption, color: .piInkSecondary)
    let add = PiKit.Button("Add Project", style: .secondary, compact: true)
    init() {
        super.init(frame: .zero)
        text.centred = true
        for view in [icon, text, add] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func textWidth(_ width: CGFloat) -> CGFloat { min(text.naturalWidth, max(0, width - PiSpacing.lg * 2)) }
    /// `VStack(spacing: 10)` in `.padding(16)`.
    func height(forWidth width: CGFloat) -> CGFloat {
        PiSpacing.lg * 2 + icon.intrinsicContentSize.height + 10 + text.height(forWidth: textWidth(width)) + 10 + add.intrinsicContentSize.height
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        var y = PiSpacing.lg
        let iconSize = icon.intrinsicContentSize
        icon.frame = CGRect(x: PiKit.round((w - iconSize.width) / 2, piScale), y: y, width: iconSize.width, height: iconSize.height)
        y += iconSize.height + 10
        let textWidth = textWidth(w), textHeight = text.height(forWidth: textWidth)
        text.frame = CGRect(x: PiKit.round((w - textWidth) / 2, piScale), y: y, width: textWidth, height: textHeight)
        y += textHeight + 10
        let addSize = add.intrinsicContentSize
        add.frame = CGRect(x: PiKit.round((w - addSize.width) / 2, piScale), y: y, width: addSize.width, height: addSize.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Shift/Command marking is only useful when the reader can see what is
/// marked and act on it without the context menu.
@MainActor final class SidebarSelectionBarView: NSView {
    private let model: WorkspaceModel
    private let icon = PiKit.SymbolView(PiKit.Symbol("checklist", size: 11, weight: .semibold), color: .piAccent)
    private let count = PiKit.TextLine()
    let copy = PiKit.IconButton(symbol: "doc.on.doc", label: "Copy selected session references, tokens and cost", size: 20)
    let archiveWord = PiKit.Button("Archive", style: .ghost)
    let clearWord = PiKit.Button("Clear", style: .ghost)
    let archiveIcon = PiKit.IconButton(symbol: "archivebox", label: "Archive selected chats", size: 20)
    let clearIcon = PiKit.IconButton(symbol: "xmark", label: "Clear selection", size: 20)
    private(set) var marked = 0
    private var allArchived = false
    /// Words first; symbols once the words no longer fit beside the count
    /// (`ViewThatFits`): a sidebar at its minimum broke "Archive" across lines.
    private(set) var compact = false

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Shift-click a row for a range, Command-click to add one. Drag any marked row to move them all."
        count.setAccessibilityIdentifier("sidebarSelectionCount")
        copy.setAccessibilityIdentifier("sidebarSelectionCopy")
        copy.onPress = { [weak self] in guard let model = self?.model else { return }; Task { await model.copyMarkedSessionReferences() } }
        for button in [archiveWord, archiveIcon] as [PiKit.ButtonBase] {
            button.setAccessibilityIdentifier("sidebarSelectionArchive")
            button.onPress = { [weak self] in guard let self else { return }; self.model.archiveMarkedSessions(!self.allArchived) }
        }
        for button in [clearWord, clearIcon] as [PiKit.ButtonBase] {
            button.setAccessibilityIdentifier("sidebarSelectionClear")
            button.onPress = { [weak self] in self?.model.clearSessionMarks() }
        }
        for view in [icon, count, copy, archiveWord, clearWord, archiveIcon, clearIcon] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func refresh() {
        let chats = model.markedChats
        let archived = !chats.isEmpty && chats.allSatisfy(\.isArchived)
        guard chats.count != marked || archived != allArchived else { return }
        marked = chats.count; allArchived = archived
        archiveWord.title = archived ? "Restore" : "Archive"
        archiveIcon.symbol = archived ? "arrow.uturn.backward" : "archivebox"
        archiveIcon.label = archived ? "Restore selected chats" : "Archive selected chats"
        applyCount()
        needsLayout = true
    }
    private func applyCount() {
        count.line = PiKit.Line(compact ? "\(marked)" : "\(marked) selected", font: PiKit.Font.caption, color: .piInk)
        count.setAccessibilityLabel("\(marked) chats selected")
    }
    /// `.padding(.horizontal, 8).padding(.vertical, 4)` around `HStack(spacing: 6)`.
    func height(forWidth width: CGFloat) -> CGFloat {
        let words = max(archiveWord.intrinsicContentSize.height, clearWord.intrinsicContentSize.height)
        let line = count.intrinsicContentSize.height
        return max(line, 20, compact(for: width) ? 20 : words, icon.intrinsicContentSize.height) + 8
    }
    private func fullWidth(count marked: Int) -> CGFloat {
        let label = PiKit.Line("\(marked) selected", font: PiKit.Font.caption, color: .piInk).size(scale: piScale).width
        return icon.intrinsicContentSize.width + 6 + label + 6 + 2 + 6 + 20 + 6 + archiveWord.intrinsicContentSize.width + 6 + clearWord.intrinsicContentSize.width
    }
    private func compact(for width: CGFloat) -> Bool { fullWidth(count: marked) > width - 16 }
    override func layout() {
        super.layout()
        let isCompact = compact(for: bounds.width)
        if isCompact != compact { compact = isCompact; applyCount() }
        archiveWord.isHidden = compact; clearWord.isHidden = compact
        archiveIcon.isHidden = !compact; clearIcon.isHidden = !compact
        let h = bounds.height
        func centred(_ size: CGSize) -> CGFloat { PiKit.round((h - size.height) / 2, piScale) }
        var x: CGFloat = 8
        let iconSize = icon.intrinsicContentSize
        icon.frame = CGRect(x: x, y: centred(iconSize), width: iconSize.width, height: iconSize.height); x += iconSize.width + 6
        let countSize = count.intrinsicContentSize
        count.frame = CGRect(x: x, y: centred(countSize), width: countSize.width, height: countSize.height)
        var right = bounds.width - 8
        let trailing: [NSView] = compact ? [clearIcon, archiveIcon, copy] : [clearWord, archiveWord, copy]
        for view in trailing {
            let size = view === copy || compact ? CGSize(width: 20, height: 20) : view.intrinsicContentSize
            view.frame = CGRect(x: right - size.width, y: centred(size), width: size.width, height: size.height)
            right -= size.width + 6
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piAccentSoft)
        layer?.cornerRadius = PiRadius.sm; layer?.cornerCurve = .continuous
    }
}
