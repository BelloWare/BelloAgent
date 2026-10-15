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
        guard let model else { return }
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
        if let container, let window = model.tabs.window(of: container) { window.title = title + " — Bello Agent" }
        if model.subagentTabIsShown(key), model.displays[key]?.historyState == nil || model.displays[key]?.historyState == .dormant { ensureLoaded() }
    }
    override func makeAppKitContent() -> NSView {
        guard let model else { return NSView() }
        let pane = ConversationPaneView(model: model); self.pane = pane
        refresh(); return pane
    }
    override var focusView: NSView? { pane }
    override func didShow() { focusOnAttachment = true; refresh(); ensureLoaded(); focusIfAttached() }
    private func ensureLoaded() {
        guard let model, loading == nil, model.record(key)?.isSubagent == true else { return }
        loading = Task { [weak self, weak model] in
            guard let self, let model else { return }
            await model.loadSubagentTab(self)
            self.loading = nil
        }
    }
    override func contentVisibilityChanged(_ shown: Bool) {
        refresh()
        if shown { focusIfAttached() }
    }
    private func focusIfAttached() {
        guard focusOnAttachment, let pane, pane.window != nil else { return }
        focusOnAttachment = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model, model.subagentTabIsShown(self.key), !model.presentsSheet,
                  self.pane?.isHiddenOrHasHiddenAncestor == false else { return }
            self.focus()
        }
    }
    func focus() {
        refresh()
        if let pane, let window = pane.window { window.makeFirstResponder(pane) }
        model?.focusedSessionID = key
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { pane?.performKeyEquivalent(with: event) ?? false }
    override func willClose() {
        loading?.cancel(); loading = nil
        model?.displays[key]?.presentation.cancel()
        if let model, model.focusedSessionID == key { model.focusedSessionID = model.selectedID }
    }
}

extension WorkspaceModel {
    func configureSubagentTab(_ tab: HostedTab) { (tab as? SubagentTab)?.configure(self) }
    func subagentTab(_ id: String) -> SubagentTab? { tabs.tab(kind: SubagentTab.kind, key: id) as? SubagentTab }
    func subagentTabIsShown(_ id: String) -> Bool {
        guard let tab = subagentTab(id), let container = tab.container else { return false }
        return container.activeID == tab.id && !container.sideShown && (!container.isPane || page == .chats)
    }
    @discardableResult func openSubagentTab(_ id: String) async -> SubagentTab? {
        guard let child = record(id), child.isSubagent else { return nil }
        subagentNavigationRevision &+= 1
        let request = subagentNavigationRevision
        let selection = selectionRevision
        // Keep the owner in the main column. An orphan's saved reader can
        // still open beside the currently selected chat.
        if let ownerID = child.delegation?.budgetOwnerSessionID, let parent = record(ownerID), parent.workspaceID == child.workspaceID, !parent.isSubagent, selectedID != ownerID {
            await select(ownerID, revealInSidebar: false, reopensSide: false, focusesComposer: false)
            guard selectedID == ownerID, selectionRevision == selection + 1 else { return nil }
        }
        guard !Task.isCancelled, request == subagentNavigationRevision, record(id)?.delegation == child.delegation else { return nil }
        page = .chats
        let openingSelection = selectionRevision
        let tab = tabs.open(kind: SubagentTab.kind, key: id) { SubagentTab(childID: id) } as! SubagentTab
        if let loading = tab.loading { await loading.value }
        else {
            // Reopening an already shown viewer can reattach after recovery.
            do { try await attachManagedSubagent(child) }
            catch is CancellationError { }
            catch { displays[id]?.notice = error.localizedDescription }
        }
        guard !Task.isCancelled, request == subagentNavigationRevision, selectionRevision == openingSelection, subagentTab(id) === tab else { return nil }
        tab.focus()
        return tab
    }
    func loadSubagentTab(_ tab: SubagentTab) async {
        guard let child = record(tab.key), child.isSubagent, subagentTab(child.id) === tab else { return }
        let view = displays[child.id] ?? SessionDisplay(id: child.id)
        if view.historyState != .dormant && view.historyState != .loading {
            do { try await attachManagedSubagent(child) }
            catch is CancellationError { }
            catch { view.notice = error.localizedDescription }
            tab.refresh(); return
        }
        let held = HeldRows(cached: view.hasPresentedRows, identity: view.presentation.identity, partialTurnInput: view.presentation.partialTurnInput)
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        view.historyState = .loading; view.refreshingCachedRows = held.cached
        view.isManagedSubagent = true; view.browsingHistory = true; view.used = Date()
        displays[child.id] = view
        tab.refresh()
        await loadSelectedChat(child.id, item: child, into: view, selection: selectionRevision,
                               generation: view.presentationGeneration, heldRows: held, focusesComposer: false, inTab: true)
        tab.refresh()
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
