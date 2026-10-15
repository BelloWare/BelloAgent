import AppKit

/// One intent belongs to one reader, including while its tab moves between
/// containers. Workspace selection/page revisions never retire this token.
@MainActor struct HostedReaderToken {
    let reader: SubagentTab
    let generation: UUID
    var isCurrent: Bool { reader.acceptsNavigation(generation) }
    func retire() { if isCurrent { reader.renewNavigation() } }
}

/// Ordinary main/side navigation retains its workspace ownership. Hosted
/// readers use only their local token, across every awaited history operation.
@MainActor struct TranscriptNavigationToken {
    var reader: HostedReaderToken?
    var workspaceRevision: Int
    /// A Source action can read a different transcript while its originating
    /// child remains visible. Back in that child retires the entire chain.
    var origin: HostedReaderToken? = nil
    func isCurrent(in model: WorkspaceModel) -> Bool {
        guard origin?.isCurrent != false else { return false }
        return reader.map { $0.isCurrent && model.subagentTab($0.reader.key) === $0.reader }
            ?? (workspaceRevision == model.messageNavigationRevision)
    }
}

extension WorkspaceModel {
    func transcriptNavigation(_ id: String, advancing: Bool = false) -> TranscriptNavigationToken {
        let tab = subagentTab(id)
        if advancing, tab == nil { retirePendingSubagentOpening(); messageNavigationRevision += 1 }
        return .init(reader: advancing ? tab?.renewNavigation() : tab?.navigation, workspaceRevision: messageNavigationRevision)
    }

    /// Only an unfinished external opening is superseded by another external
    /// destination. A Find/Home read in an independent window is not one.
    func retirePendingSubagentOpening() {
        let old = pendingSubagentOpening; pendingSubagentOpening = nil
        old?.retire()
    }
    func beginSubagentOpening(_ id: String) -> HostedReaderToken {
        let reader = subagentTab(id) ?? SubagentTab(childID: id)
        retirePendingSubagentOpening()
        reader.model = self
        let token = reader.renewNavigation()
        pendingSubagentOpening = token
        return token
    }
    func finishSubagentOpening(_ token: HostedReaderToken) {
        if pendingSubagentOpening?.generation == token.generation { pendingSubagentOpening = nil }
    }
    func mainSelectionChangedDuringReaderOpening() {
        guard let pending = pendingSubagentOpening, pending.reader.container == nil else { return }
        guard let child = record(pending.reader.key), let ownerID = child.delegation?.budgetOwnerSessionID,
              let owner = record(ownerID) else { retirePendingSubagentOpening(); return }
        if selectedID != (sideFamilyOwner(owner) ?? ownerID) { retirePendingSubagentOpening() }
    }
    func tabNavigationChanged(_ tab: HostedTab?, in container: TabContainer) {
        guard container.isPane, let pending = pendingSubagentOpening,
              pending.reader.container == nil, tab !== pending.reader else { return }
        retirePendingSubagentOpening()
    }

    /// A child window's active reader owns its menu commands even if a main
    /// selection changed the workspace's remembered focus. Embedded readers
    /// resolve through the actual responder, without scanning transcript rows.
    func hostedConversationReader(in window: NSWindow?) -> SubagentTab? {
        guard let window else { return nil }
        if let container = tabs.windows.first(where: { tabs.window(of: $0) === window }),
           let reader = container.activeTab as? SubagentTab, subagentTabIsShown(reader.key) { return reader }
        var view = window.firstResponder as? NSView
        while let current = view {
            if let content = current as? TabContentView, let reader = content.tab as? SubagentTab,
               subagentTabIsShown(reader.key), !content.isHiddenOrHasHiddenAncestor { return reader }
            view = current.superview
        }
        return nil
    }
    func conversationCommandID(in window: NSWindow? = nil) -> String? {
        hostedConversationReader(in: window ?? conversationWindow())?.key ?? focusedSessionID ?? selectedID
    }
}
