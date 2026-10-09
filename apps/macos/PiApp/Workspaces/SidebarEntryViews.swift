import AppKit
import Combine

// The views of the sidebar list's entries, other than the headers
// (SidebarGroupHeader.swift): chat and side rows, the archived heading, the
// "Show more" line, a group's empty line and a topic's remove question.

/// What every sidebar entry view says about itself to the list.
@MainActor protocol SidebarEntryView: NSView {
    /// Its height at the list's width.
    func entryHeight(width: CGFloat) -> CGFloat
}

/// A chat in the sidebar: its press surface, its highlight, its right-click
/// menu and, in a project, its drag source.
@MainActor final class SidebarChatRowView: NSView, SidebarEntryView {
    private let model: WorkspaceModel
    private(set) var chat: ChatRecord
    private(set) var state: SidebarChatRowState
    private(set) var projectID: String
    let body = ChatRowBodyView()
    let row: PiKit.SelectableRow
    private var surface: TopicSessionDragSurfaceView?
    private var sourceWatch: AnyCancellable?
    private var minuteWatch: AnyCancellable?
    /// The live page this row last read its figures from.
    private weak var watchedDisplay: SessionDisplay?
    /// The retained accounting this row draws, held while the row is: the
    /// cache keeps a chat's figures only while something draws them.
    private var retained: CachedSessionAccounting?
    /// Tests count rows that drew themselves again.
    static var builds = 0

    init(model: WorkspaceModel, chat: ChatRecord, state: SidebarChatRowState, projectID: String, glide: PiKit.SelectionGlide) {
        self.model = model; self.chat = chat; self.state = state; self.projectID = projectID
        row = PiKit.SelectableRow(content: body, selected: state.selected, marked: state.marked, providesCursor: !state.draggable, glide: glide)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(row)
        row.onPress = { [weak self] in self?.click(NSEvent.modifierFlags) }
        // Archive's confirmation is wider than the button it replaces: the
        // surface's cut-outs follow it at once.
        body.controlsChanged = { [weak self] in
            guard let self else { return }
            // The compact Archive button is taller than the icon it replaces.
            if self.bounds.width > 0, self.entryHeight(width: self.bounds.width) != self.bounds.height {
                (self.superview as? SidebarListDocument)?.entryChangedHeight()
            }
            self.needsLayout = true; self.layoutSubtreeIfNeeded()
        }
        row.doubleClick = { [weak self] in self?.rename() }
        body.toggle = { [weak self] in
            guard let self else { return }
            let folded = !self.model.collapsedSidebarSides.contains(self.chat.id)
            // The list moves its rows for it, when it has one.
            if let fold = (self.superview as? SidebarListDocument)?.setSideFolded { fold(self.chat.id, folded) }
            else { self.model.setSidebarSideFolded(self.chat.id, folded: folded) }
        }
        body.archive = { [weak self] in guard let self else { return }; self.model.toggleSessionArchive(self.chat.id) }
        minuteWatch = SidebarMinute.shared.$tick.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshBody() } }
        apply(chat: chat, state: state, projectID: projectID, force: true)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    static func symbol(_ chat: ChatRecord) -> String {
        chat.imported ? "doc.text" : chat.parentSessionID != nil ? "arrow.triangle.branch" : chat.connectionTest == true ? "checkmark.seal"
            : chat.toolMode == ChatRecord.readOnlyTools ? "eye" : "bubble.left"
    }

    /// Takes the chat and its state; changes only what differs.
    func apply(chat: ChatRecord, state: SidebarChatRowState, projectID: String, force: Bool = false) {
        guard force || chat != self.chat || state != self.state || projectID != self.projectID else { return }
        Self.builds &+= 1
        self.chat = chat; self.state = state; self.projectID = projectID
        row.selected = state.selected
        row.marked = state.marked
        row.recencyTint = PiKit.SelectableRow.recencyTint(rank: state.recency)
        row.showsPointer = !state.draggable
        watchSource()
        refreshBody()
        // A draggable row's surface owns the plain left press.
        if state.draggable, surface == nil {
            let view = TopicSessionDragSurfaceView()
            addSubview(view, positioned: .above, relativeTo: row)
            surface = view
        } else if !state.draggable, let surface { surface.removeFromSuperview(); self.surface = nil }
        surface?.actions = TopicSessionRowActions(item: { [weak self] in self?.dragItem() }, image: { [weak self] in self?.dragImage() },
                                                  click: { [weak self] in self?.click($0) }, doubleClick: { [weak self] in self?.rename() },
                                                  dragging: dragHold.callback(model: model, list: { [weak self] in self?.superview as? SidebarListDocument }))
        needsLayout = true
    }

    /// The figures come from the chat's live page while it has one, and from
    /// the retained accounting otherwise; the row watches whichever it is.
    private func watchSource() {
        if let display = Self.liveDisplay(model: model, chatID: chat.id, state: state) {
            guard display !== watchedDisplay else { return }
            watchedDisplay = display; retained = nil
            sourceWatch = display.objectWillChange.merge(with: display.footer.objectWillChange)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleBody() } }
        } else {
            guard retained == nil || watchedDisplay != nil else { return }
            let accounting = model.chatAccounting.row(for: chat.id)
            watchedDisplay = nil; retained = accounting
            sourceWatch = accounting.objectWillChange
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleBody() } }
        }
    }
    private var bodyScheduled = false
    private func scheduleBody() {
        guard !bodyScheduled else { return }
        bodyScheduled = true
        // On the next turn, or with the next layout if that comes first.
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushBody() }
        }
    }
    private func flushBody() {
        guard bodyScheduled else { return }
        bodyScheduled = false; refreshBody()
    }
    /// A live page's figures: what its footer has billed, its run state, and
    /// its newest message.
    static func liveStats(_ display: SessionDisplay, now: Date) -> ChatRowStats {
        var value = ChatRowStats(totals: display.footer.gateway, timing: display.footer.timing, now: now)
        value.updateActivity(state: display.state, loading: display.loading, activity: display.activity)
        value.costLimited = display.failureCode == SessionDisplay.costLimitCode
        // A message that just landed is more recent than the last retained request.
        if let at = display.messages.last(where: { $0.at != nil })?.at { value.noteActivity(max(value.lastActivity ?? 0, at / 1_000), now: now) }
        return value
    }
    /// What a chat's row shows, from the chat, its state and where its figures
    /// come from: the live page while it has one, else the retained accounting.
    static func content(model: WorkspaceModel, chat: ChatRecord, state: SidebarChatRowState,
                        display: SessionDisplay?, retained: CachedSessionAccounting?) -> ChatRowBodyView.Content {
        let now = SidebarMinute.shared.now
        var stats = display.map { liveStats($0, now: now) }
            ?? ChatRowStats(totals: (retained ?? model.chatAccounting.row(for: chat.id)).totals, now: now)
        // Paused before a restart, and not opened since: the saved hold says so.
        if display?.runStateKnown != true, let held = state.heldRun { stats.updateActivity(state: held, loading: false, activity: [:]) }
        return ChatRowBodyView.Content(stats: stats, title: chat.title, subtitle: state.subtitle, symbol: symbol(chat), selected: state.selected,
                                       unreadCount: state.unreadCount, unreadFailure: state.unreadFailure,
                                       markedUnreadOnly: state.markedUnreadOnly, hasDraft: state.hasDraft, hasSide: state.hasSide,
                                       expanded: state.expanded, pinned: chat.isPinned, archived: chat.isArchived,
                                       archivable: !chat.isUtilityChat, available: state.available)
    }
    /// The live page a row in `state` reads its figures from, if any.
    static func liveDisplay(model: WorkspaceModel, chatID: String, state: SidebarChatRowState) -> SessionDisplay? {
        state.liveIdentity == nil ? nil : model.displays[chatID]
    }
    private func refreshBody() {
        let height = bounds.width > 0 ? entryHeight(width: bounds.width) : nil
        let content = Self.content(model: model, chat: chat, state: state, display: watchedDisplay, retained: retained)
        body.update(content)
        if row.accessibilityLabel() != content.accessibilityLabel { row.setAccessibilityLabel(content.accessibilityLabel) }
        // A line more or less under the title: the list lays out again.
        if let height, entryHeight(width: bounds.width) != height { (superview as? SidebarListDocument)?.entryChangedHeight() }
    }

    private func click(_ flags: NSEvent.ModifierFlags) {
        let model = self.model, id = chat.id
        SidebarRowClick(modifiers: flags).apply(to: model, sessionID: id) {
            Task { await model.openFromSidebar(id) }
        }
    }
    private func rename() { if !chat.isBackgroundTask { model.presentRename(chat.id) } }

    /// What this row would put on the drag pasteboard right now: read before
    /// the press is applied, so a marked row still carries the marks it was dragged by.
    private func dragItem() -> NSPasteboardItem? {
        TopicSessionDrag(sessionIDs: model.dragSessionIDs(for: chat.id, in: projectID), workspaceID: projectID).pasteboardItem()
    }
    private func dragImage() -> NSImage? {
        TopicSessionDragPreview.image(count: model.dragSessionIDs(for: chat.id, in: projectID).count, title: model.record(chat.id)?.title ?? "Chat",
                                      appearance: effectiveAppearance)
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu: NSMenu
        if state.anyMarked && state.marked { menu = PiMenus.menu(MarkedSessionActions.entries(model: model)) }
        else {
            let model = self.model, chat = self.chat, state = self.state
            menu = PiMenus.menu(Self.entries(model: model, chat: chat, state: state))
        }
        // The rows stay where they are while the menu is open.
        menuHold.hold(menu, model: model, list: superview as? SidebarListDocument)
        return menu
    }
    private let menuHold = SidebarMenuOrderHold()
    private let dragHold = SidebarDragOrderHold()
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, chat: ChatRecord, state: SidebarChatRowState) -> [PiMenuEntry] {
        if chat.parentSessionID != nil {
            PiMenuEntry.button("Open on Its Own", systemImage: "rectangle.expand.vertical") { Task { await model.select(chat.id) } }
            PiMenuEntry.divider
        }
        SessionOrganizationActions.entries(model: model, chat: chat)
        PiMenuEntry.divider
        SessionReferenceActions.entries(model: model, sessionID: chat.id)
        if state.offersMarkAsRead {
            PiMenuEntry.divider
            PiMenuEntry.button("Mark as Read") { model.markSessionRead(chat.id) }
        } else if model.canMarkSessionUnread(chat.id) {
            PiMenuEntry.divider
            PiMenuEntry.button("Mark as Unread", identifier: "markSessionUnread") { model.markSessionUnread(chat.id) }
        }
    }

    // MARK: Layout

    func entryHeight(width: CGFloat) -> CGFloat { row.height(forWidth: max(0, width - state.indent)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        flushBody()
        super.layout()
        row.frame = CGRect(x: state.indent, y: 0, width: max(0, bounds.width - state.indent), height: bounds.height)
        if let surface {
            surface.frame = row.frame
            // The buttons' places, once the row has laid them out at its new size.
            row.layoutSubtreeIfNeeded()
            surface.controls = body.controlFrames.map { body.convert($0, to: surface) }
        }
    }
}

/// The open, unsaved side conversation under its parent.
@MainActor final class SidebarSideRowView: NSView, SidebarEntryView {
    private let model: WorkspaceModel
    private(set) var state: SidebarSideRowState
    let body = ChatRowBodyView()
    let row: PiKit.SelectableRow
    private var sourceWatch: AnyCancellable?
    private var minuteWatch: AnyCancellable?

    init(model: WorkspaceModel, state: SidebarSideRowState, glide: PiKit.SelectionGlide) {
        self.model = model; self.state = state
        row = PiKit.SelectableRow(content: body, selected: state.selected, glide: glide)
        super.init(frame: .zero)
        addSubview(row)
        row.onPress = { [weak self] in
            guard let self else { return }
            let model = self.model, id = self.state.id
            Task { await model.openFromSidebar(id) }
        }
        minuteWatch = SidebarMinute.shared.$tick.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshBody() } }
        apply(state, force: true)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ new: SidebarSideRowState, force: Bool = false) {
        guard force || new != state else { return }
        SidebarChatRowView.builds &+= 1
        state = new
        row.selected = new.selected
        row.recencyTint = PiKit.SelectableRow.recencyTint(rank: new.recency)
        if let display = new.liveIdentity == nil ? nil : model.displays[new.id] {
            sourceWatch = display.objectWillChange.merge(with: display.footer.objectWillChange)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleBody() } }
        } else { sourceWatch = nil }
        refreshBody()
        row.setAccessibilityLabel(new.title)
        needsLayout = true
    }
    /// A live side's changes, coalesced to one redraw a turn (or the next layout).
    private var bodyScheduled = false
    private func scheduleBody() {
        guard !bodyScheduled else { return }
        bodyScheduled = true; needsLayout = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushBody() } }
    }
    private func flushBody() {
        guard bodyScheduled else { return }
        bodyScheduled = false; refreshBody()
    }
    /// What a side's row shows: its live page's figures while it has one.
    static func content(model: WorkspaceModel, state: SidebarSideRowState) -> ChatRowBodyView.Content {
        var stats = ChatRowStats(totals: nil)
        if state.liveIdentity != nil, let display = model.displays[state.id] {
            stats = SidebarChatRowView.liveStats(display, now: SidebarMinute.shared.now)
        }
        return ChatRowBodyView.Content(stats: stats, title: state.title, subtitle: state.kept ? "Saved · Read-only" : "In memory · Read-only",
                                       symbol: "arrow.triangle.branch", selected: state.selected, unreadCount: state.unreadCount,
                                       available: state.available)
    }
    private func refreshBody() {
        let height = bounds.width > 0 ? entryHeight(width: bounds.width) : nil
        body.update(Self.content(model: model, state: state))
        // A rate line more or less: the list lays out again.
        if let height, entryHeight(width: bounds.width) != height { (superview as? SidebarListDocument)?.entryChangedHeight() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let model = self.model, state = self.state
        let menu = PiMenus.menu(Self.entries(model: model, state: state))
        menuHold.hold(menu, model: model, list: superview as? SidebarListDocument)
        return menu
    }
    private let menuHold = SidebarMenuOrderHold()
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, state: SidebarSideRowState) -> [PiMenuEntry] {
        if state.kept, let record = model.record(state.id) { SessionOrganizationActions.entries(model: model, chat: record) }
        SessionReferenceActions.entries(model: model, sessionID: state.id)
        if state.unreadCount > 0 { PiMenuEntry.button("Mark as Read") { model.markSessionRead(state.id) } }
        else if model.canMarkSessionUnread(state.id) { PiMenuEntry.button("Mark as Unread", identifier: "markSessionUnread") { model.markSessionUnread(state.id) } }
    }
    func entryHeight(width: CGFloat) -> CGFloat { row.height(forWidth: max(0, width - state.indent)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        flushBody()
        super.layout()
        row.frame = CGRect(x: state.indent, y: 0, width: max(0, bounds.width - state.indent), height: bounds.height)
    }
}

/// Where a group's archived chats begin while the archive switch is on: the
/// archive glyph where the rows carry theirs, the word and how many there
/// are, and a hairline to the edge.
@MainActor final class SidebarArchiveHeadingView: NSView, SidebarEntryView {
    private var count: Int, indent: CGFloat
    private let glyph = PiKit.SymbolView(PiKit.Symbol("archivebox", size: 11, weight: .medium), color: .piInkTertiary)
    private let label = PiKit.TextLine()
    private let rule = CALayer()
    init(groupID: String, count: Int, indent: CGFloat) {
        self.count = count; self.indent = indent
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glyph); addSubview(label); layer?.addSublayer(rule)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("archivedChats-" + groupID)
        update(count: count, indent: indent)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(count: Int, indent: CGFloat) {
        self.count = count; self.indent = indent
        label.line = PiKit.Line("Archived · \(count)", font: PiKit.Font.caption, color: .piInkTertiary)
        setAccessibilityLabel(count == 1 ? "1 archived chat" : "\(count) archived chats")
        needsLayout = true
    }
    private var lineHeight: CGFloat { max(label.intrinsicContentSize.height, glyph.intrinsicContentSize.height) }
    func entryHeight(width: CGFloat) -> CGFloat { lineHeight + 6 + 2 }
    override func layout() {
        super.layout()
        let height = lineHeight, scale = piScale
        var x = indent + 10
        let glyphSize = glyph.intrinsicContentSize
        glyph.frame = CGRect(x: x + PiKit.round((16 - glyphSize.width) / 2, scale), y: 6 + PiKit.round((height - glyphSize.height) / 2, scale),
                             width: glyphSize.width, height: glyphSize.height)
        x += 16 + 8
        let labelSize = label.intrinsicContentSize
        label.frame = CGRect(x: x, y: 6 + PiKit.round((height - labelSize.height) / 2, scale), width: labelSize.width, height: labelSize.height)
        x += labelSize.width + 8
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rule.frame = CGRect(x: x, y: 6 + PiKit.round((height - 1) / 2, scale), width: max(0, bounds.width - 10 - x), height: 1)
        rule.backgroundColor = piCGColor(.piHairline)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}

/// A plain label button: a symbol and words in the caption font, no face,
/// dimming when disabled (`Label` in `.buttonStyle(.plain)`).
@MainActor final class SidebarLinkButton: PiKit.ButtonBase {
    override var title: String { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
    let symbol: String
    let ink: NSColor
    init(title: String, symbol: String, ink: NSColor, action: @escaping () -> Void) {
        self.symbol = symbol; self.ink = ink
        super.init(frame: .zero)
        self.title = title
        pressScales = false; hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
        onPress = action
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    private var line: PiKit.Line { PiKit.Line(title, font: PiKit.Font.caption, color: ink) }
    private var glyph: PiKit.Symbol { PiKit.Symbol(symbol, size: PiKit.Font.captionSize) }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale), box = glyph.layoutSize
        return NSSize(width: box.width + PiKit.Button.labelSpacing + text.width, height: max(text.height, box.height))
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale, box = glyph.layoutSize, text = line.size(scale: scale)
        glyph.drawPlaced(centredIn: CGRect(x: 0, y: 0, width: box.width, height: rect.height), color: ink, scale: scale)
        line.draw(at: CGPoint(x: box.width + PiKit.Button.labelSpacing, y: PiKit.round((rect.height - text.height) / 2, scale)), scale: scale)
    }
    override func setAccessibilityLabel(_ accessibilityLabel: String?) { super.setAccessibilityLabel(accessibilityLabel) }
}

/// "Show N more · M hidden" and "Show less" under a group that pages.
@MainActor final class SidebarPaginationView: NSView, SidebarEntryView {
    private let more: SidebarLinkButton
    private let less: SidebarLinkButton
    private var indent: CGFloat = 0
    var showMore: (() -> Void)?
    var showLess: (() -> Void)?
    init(groupID: String) {
        more = SidebarLinkButton(title: "", symbol: "chevron.down", ink: .piAccent) {}
        less = SidebarLinkButton(title: "Show less", symbol: "chevron.up", ink: .piInkSecondary) {}
        super.init(frame: .zero)
        more.onPress = { [weak self] in self?.showMore?() }
        less.onPress = { [weak self] in self?.showLess?() }
        more.setAccessibilityIdentifier("sessionShowMore-" + groupID)
        less.setAccessibilityIdentifier("sessionShowLess-" + groupID)
        addSubview(more); addSubview(less)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(hiddenRoots: Int, shownRoots: Int, indent: CGFloat) {
        self.indent = indent
        more.isHidden = hiddenRoots == 0
        more.title = "Show \(min(hiddenRoots, SidebarSessionPresentation.pageSize * 2)) more \u{b7} \(hiddenRoots) hidden"
        more.setAccessibilityLabel(more.title)
        less.isHidden = shownRoots <= SidebarSessionPresentation.pageSize
        less.setAccessibilityLabel("Show less")
        needsLayout = true
    }
    private var lineHeight: CGFloat { max(more.intrinsicContentSize.height, less.intrinsicContentSize.height) }
    func entryHeight(width: CGFloat) -> CGFloat { lineHeight + 8 }
    override func layout() {
        super.layout()
        var x = indent + 9
        for button in [more, less] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: 4 + PiKit.round((lineHeight - size.height) / 2, piScale), width: size.width, height: size.height)
            x += size.width + PiSpacing.md
        }
    }
}

/// A line of caption text in the list: a group's "No chats yet", or a
/// project's "Project unavailable · History only".
@MainActor final class SidebarNoteView: NSView, SidebarEntryView {
    private let label = PiKit.TextLine()
    private var leading: CGFloat
    private let vertical: CGFloat
    init(text: String, leading: CGFloat, vertical: CGFloat) {
        self.leading = leading; self.vertical = vertical
        super.init(frame: .zero)
        addSubview(label)
        update(text: text, leading: leading)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(text: String, leading: CGFloat) {
        self.leading = leading
        label.line = PiKit.Line(text, font: PiKit.Font.caption, color: .piInkTertiary)
        needsLayout = true
    }
    func entryHeight(width: CGFloat) -> CGFloat { label.intrinsicContentSize.height + vertical * 2 }
    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: leading, y: vertical, width: min(size.width, max(0, bounds.width - leading)), height: size.height)
    }
}

/// A topic's own "Remove this topic?" question, under its header.
@MainActor final class SidebarTopicRemoveView: NSView, SidebarEntryView {
    private let question = ShellText("Remove this topic? Its chats stay in the project.", font: PiKit.Font.caption, color: .piInkSecondary)
    let remove = PiKit.Button("Remove Topic", style: .secondary, compact: true)
    let cancel = PiKit.Button("Cancel", style: .ghost)
    init() {
        super.init(frame: .zero)
        for view in [question, remove, cancel] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(removing: Bool) {
        remove.title = removing ? "Removing…" : "Remove Topic"
        remove.isEnabled = !removing; cancel.isEnabled = !removing
        needsLayout = true
    }
    private var buttonsHeight: CGFloat { max(remove.intrinsicContentSize.height, cancel.intrinsicContentSize.height) }
    /// The question wraps, as an unconstrained `Text` does, in what is left
    /// beside `.padding(.leading, 35).padding(.trailing, 7)`.
    private func questionWidth(_ width: CGFloat) -> CGFloat { min(question.naturalWidth, max(0, width - 35 - 7)) }
    func entryHeight(width: CGFloat) -> CGFloat { question.height(forWidth: questionWidth(width)) + 6 + buttonsHeight + 10 }
    override func layout() {
        super.layout()
        let scale = piScale
        let width = questionWidth(bounds.width), height = question.height(forWidth: width)
        question.frame = CGRect(x: 35, y: 5, width: width, height: height)
        let y = 5 + height + 6
        let removeSize = remove.intrinsicContentSize, cancelSize = cancel.intrinsicContentSize
        remove.frame = CGRect(x: 35, y: y + PiKit.round((buttonsHeight - removeSize.height) / 2, scale), width: removeSize.width, height: removeSize.height)
        cancel.frame = CGRect(x: 35 + removeSize.width + 8, y: y + PiKit.round((buttonsHeight - cancelSize.height) / 2, scale),
                              width: cancelSize.width, height: cancelSize.height)
    }
}

/// What a right-click offers while several rows are marked. Every item runs
/// the same path as its single-chat counterpart. Copying preserves the marks.
enum MarkedSessionActions {
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel) -> [PiMenuEntry] {
        let marked = model.markedChats
        let archived = marked.filter(\.isArchived).count
        // A failure mark is cleared by Mark as Read too, so it counts here.
        let unread = marked.filter { model.offersMarkSessionRead($0.id) }.count
        let read = marked.filter { model.canMarkSessionUnread($0.id) }.count
        PiMenuEntry.note("\(marked.count) chats selected")
        PiMenuEntry.divider
        PiMenuEntry.button("Copy Session References", systemImage: "doc.on.doc", identifier: "copyMarkedSessionReferences",
                           help: "Copy selected session IDs, conversation file paths, token usage and reported cost") {
            Task { await model.copyMarkedSessionReferences() }
        }
        PiMenuEntry.divider
        if archived < marked.count {
            PiMenuEntry.button("Archive \(marked.count - archived) Chats", systemImage: "archivebox", identifier: "archiveMarkedSessions") {
                model.archiveMarkedSessions(true)
            }
        }
        if archived > 0 {
            PiMenuEntry.button("Restore \(archived) Chats", systemImage: "arrow.uturn.backward", identifier: "restoreMarkedSessions") {
                model.archiveMarkedSessions(false)
            }
        }
        PiMenuEntry.button("Pin All", systemImage: "pin") { model.pinMarkedSessions(true) }
        PiMenuEntry.button("Unpin All", systemImage: "pin.slash") { model.pinMarkedSessions(false) }
        if let projectID = model.markedProjectID, projectID != WorkspaceRecord.scratchID {
            PiMenuEntry.menu("Move \(marked.count) to Topic", systemImage: "folder", identifier: "moveMarkedSessionsToTopic") {
                PiMenuEntry.note("Includes saved side chats")
                PiMenuEntry.button("Project root", systemImage: "tray") { model.moveMarkedSessions(toTopic: nil) }
                for topic in model.topics(in: projectID) {
                    PiMenuEntry.button(topic.title, systemImage: "folder") { model.moveMarkedSessions(toTopic: topic.id) }
                }
            }
        }
        if unread > 0 || read > 0 { PiMenuEntry.divider }
        if unread > 0 { PiMenuEntry.button("Mark \(unread) as Read") { model.markMarkedSessionsRead() } }
        if read > 0 { PiMenuEntry.button("Mark \(read) as Unread", identifier: "markMarkedSessionsUnread") { model.markMarkedSessionsUnread() } }
        PiMenuEntry.divider
        PiMenuEntry.button("Clear Selection", systemImage: "xmark.circle") { model.clearSessionMarks() }
    }
}
