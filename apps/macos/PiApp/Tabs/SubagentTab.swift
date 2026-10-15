import AppKit

/// A saved child is a reader in the ordinary tab host. The key is the child
/// identity, so every entry point reuses it across pane/window moves.
@MainActor final class SubagentTab: HostedTab {
    override class var kind: String { "subagent" }
    weak var model: WorkspaceModel?
    private(set) var pane: ConversationPaneView?
    var loading: Task<Void, Never>?
    private var observer: ShellObserver?
    private var foundRecord = false
    private var closed = false
    private var focusOnAttachment = false
    init(childID: String) { super.init(key: childID, title: "Sub-agent", symbol: "person.crop.rectangle.stack") }
    override class func restore(key: String, state: Data?) -> HostedTab? {
        guard !key.isEmpty else { return nil }
        return SubagentTab(childID: key)
    }
    func configure(_ model: WorkspaceModel) {
        self.model = model
        let observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model); self.observer = observer
        refresh()
    }
    func refresh() {
        guard !closed, let model else { return }
        guard let child = model.record(key), child.isSubagent else {
            if foundRecord, container != nil { model.tabs.close(self) }; return
        }
        foundRecord = true
        if title != child.displayTitle { title = child.displayTitle }
        help = model.subagentSearchTitle(child)
        if let view = model.displays[key], let pane {
            pane.showsAgentFamily = container?.isPane == false
            pane.show(session: view, chat: child)
        }
        if let container, container.activeTab === self, let window = model.tabs.window(of: container) { window.title = title + " — Bello Agent" }
        if model.subagentTabIsShown(key), model.displays[key]?.historyState == nil || model.displays[key]?.historyState == .dormant { ensureLoaded() }
    }
    override var stripTitle: String { model?.record(key)?.subagentShortTitle ?? title }
    override var truncatesTitleAtEnd: Bool { true }
    override func makeAppKitContent() -> NSView {
        guard let model else { return NSView() }
        let pane = ConversationPaneView(model: model); self.pane = pane
        refresh(); return pane
    }
    override var focusView: NSView? { pane }
    override var canRestoreFocus: Bool { model?.focusedSessionID == key && model?.subagentTabIsShown(key) == true }
    override func didShow() { refresh(); ensureLoaded(); focus() }
    override func didHide() {
        focusOnAttachment = false
        if let model, !model.subagentTabIsShown(key), model.focusedSessionID == key {
            model.focusedSessionID = model.selectedID
        }
    }
    func ensureLoaded() {
        guard !closed, let model, loading == nil, model.record(key)?.isSubagent == true else { return }
        loading = Task { [weak self, weak model] in
            guard let self, let model else { return }
            await model.loadSubagentTab(self)
            self.loading = nil
            if model.subagentTab(self.key) === self { self.refresh() }
        }
    }
    override func contentVisibilityChanged(_ shown: Bool) {
        refresh()
        // The ordinary Side selection can uncover this tab without activate().
        if shown { ensureLoaded(); focusIfAttached() }
        else { didHide() }
    }
    private func focusIfAttached() {
        guard focusOnAttachment, let pane, pane.window != nil else { return }
        focusOnAttachment = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model, model.focusedSessionID == self.key,
                  model.subagentTabIsShown(self.key), !model.presentsSheet,
                  self.pane?.isHiddenOrHasHiddenAncestor == false else { return }
            self.focus()
        }
    }
    func focus() {
        guard let model, model.subagentTabIsShown(key), model.record(key)?.isSubagent == true else { return }
        focusOnAttachment = true
        if let pane, let window = pane.window, !pane.isHiddenOrHasHiddenAncestor {
            focusOnAttachment = false; window.makeFirstResponder(pane)
        }
        model.focusedSessionID = key
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if pane?.performKeyEquivalent(with: event) == true { return true }
        guard let model, let pane, let window = pane.window, event.window === window,
              window.attachedSheet == nil, !(window.childWindows ?? []).contains(where: { $0.isVisible && $0.canBecomeKey }),
              model.subagentTabIsShown(key), model.subagentReaderCommandsEnabled(key),
              let responder = window.firstResponder as? NSView, responder === pane || responder.isDescendant(of: pane),
              let display = model.displays[key] else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let text = event.charactersIgnoringModifiers?.lowercased()
        let find: TranscriptFindCommand.Kind?
        switch (text, flags) {
        case ("f", .command): find = .show
        case ("g", .command): find = .next
        case ("g", [.command, .shift]) where display.findHost?.findIsOpen == true: find = .previous
        case ("f", [.command, .option]): model.inspectConversation(key); return true
        case (".", .command): model.stop(sessionID: key); return true
        default: return false
        }
        if let find { model.revealSerial += 1; display.findCommand = .init(kind: find, serial: model.revealSerial) }
        return true
    }
    override func willClose() {
        closed = true; focusOnAttachment = false
        loading?.cancel(); loading = nil
        model?.displays[key]?.presentation.cancel()
        if let model, model.focusedSessionID == key { model.focusedSessionID = model.selectedID }
        // Window-close/teardown calls willClose before removing its tab array.
        // Evict on the next turn, once closed tabs no longer hold their readers.
        DispatchQueue.main.async { [weak model] in
            guard let model, !model.isShutDown else { return }
            model.releaseUnreadDisplays(keeping: model.selectedID ?? "")
        }
    }
}

extension WorkspaceModel {
    /// Page availability is scoped to the reader. A popped-out child remains
    /// usable while the workspace shows Reports; native responders and sheets
    /// are checked separately by its pane/tab.
    func subagentReaderCommandsEnabled(_ id: String) -> Bool {
        guard !presentsSheet, !quickOpen.isOpen, record(id)?.isSubagent == true else { return false }
        return page == .chats || (subagentTab(id)?.container?.isPane == false && subagentTabIsShown(id))
    }
    func configureSubagentTab(_ tab: HostedTab) { (tab as? SubagentTab)?.configure(self) }
    func subagentTab(_ id: String) -> SubagentTab? { tabs.tab(kind: SubagentTab.kind, key: id) as? SubagentTab }
    func subagentTabIsShown(_ id: String) -> Bool {
        guard let tab = subagentTab(id), let container = tab.container else { return false }
        return container.shownTab(sideAvailable: container.isPane && paneSideAvailable) === tab && (!container.isPane || page == .chats)
    }
    @discardableResult func openSubagentTab(_ id: String) async -> SubagentTab? {
        guard let child = record(id), child.isSubagent else { return nil }
        subagentNavigationRevision &+= 1
        let request = subagentNavigationRevision
        let selection = selectionRevision, paneIntent = tabs.navigationRevision
        // Keep the owner in the main column. An orphan's saved reader can
        // still open beside the currently selected chat.
        if let ownerID = child.delegation?.budgetOwnerSessionID, let owner = record(ownerID), owner.workspaceID == child.workspaceID, !owner.isSubagent {
            let mainID = sideFamilyOwner(owner) ?? ownerID
            if selectedID != mainID {
                await select(mainID, revealInSidebar: false, reopensSide: false, focusesComposer: false)
                guard selectedID == mainID, selectionRevision == selection + 1 else { return nil }
            }
        }
        guard !Task.isCancelled, request == subagentNavigationRevision, tabs.navigationRevision == paneIntent, record(id)?.delegation == child.delegation else { return nil }
        page = .chats
        let tab = tabs.open(kind: SubagentTab.kind, key: id) { SubagentTab(childID: id) } as! SubagentTab
        // Opening is the focus decision; finishing its asynchronous read is not.
        tab.focus(); tab.ensureLoaded()
        if let loading = tab.loading { await loading.value }
        else {
            // Reopening an already shown viewer can reattach after recovery.
            do { try await attachManagedSubagent(child) }
            catch is CancellationError { }
            catch { displays[id]?.notice = error.localizedDescription }
        }
        guard !Task.isCancelled, request == subagentNavigationRevision, subagentTab(id) === tab else { return nil }
        return tab
    }
    func loadSubagentTab(_ tab: SubagentTab) async {
        guard let child = record(tab.key), child.isSubagent, subagentTab(child.id) === tab else { return }
        let view = displays[child.id] ?? SessionDisplay(id: child.id)
        // Hidden children receive status only. Reuse the journal revision check
        // used by main-chat selection even if this display was already ready.
        let held = view.beginHistoryPresentation()
        view.presentation.navigation = tab.loading
        view.isManagedSubagent = true; view.browsingHistory = true; view.used = Date()
        displays[child.id] = view
        tab.refresh()
        await loadSelectedChat(child.id, item: child, into: view, selection: selectionRevision,
                               generation: view.presentationGeneration, heldRows: held, focusesComposer: false, tab: tab)
        tab.refresh()
        releaseUnreadDisplays(keeping: selectedID ?? "")
    }
    func focusSubagentParent(_ id: String) {
        focusedSessionID = id
        for window in NSApp.windows {
            func pane(in view: NSView) -> ConversationPaneView? {
                if let value = view as? ConversationPaneView, value.chat?.id == id { return value }
                return view.subviews.lazy.compactMap { pane(in: $0) }.first
            }
            if let root = window.contentView, let parent = pane(in: root), !parent.isHiddenOrHasHiddenAncestor {
                window.makeKeyAndOrderFront(nil)
                if let display = displays[id] { display.composerFocusRequest += 1 }
                window.makeFirstResponder(parent.composer); return
            }
        }
    }
}
