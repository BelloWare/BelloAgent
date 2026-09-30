import AppKit

// A project's changes and history, in a tab beside the chats (`ChangesTab`):
// opened from ⇧⌘G, the composer, a project's header and the sidebar.

extension WorkspaceModel {
    /// A line in a working-tree, staged or history diff opens the current
    /// file, with trust determined by its resolved path.
    func openChangesFile(_ url: URL, at line: Int) {
        guard line > 0 else { return }
        if page != .chats { page = .chats }
        let tab = openFile(url, lines: (line - 1)...(line - 1))
        quickOpen.focusAfterOpening(tab)
    }
    /// Opens a project's changes and history in a tab of the pane beside the
    /// chats, or shows the tab they are open in, wherever it is. The chats
    /// are brought back first: the report and the background requests cover
    /// the tabs. The tab, or nil when there is no project to show.
    @discardableResult func showChanges(in workspaceID: String? = nil) -> ChangesTab? {
        guard let workspaceID = workspaceID ?? chat?.workspaceID ?? selectedWorkspaceID, let project = changesProject(workspaceID) else {
            error = "Choose a project to see its changes."; return nil
        }
        if page != .chats { page = .chats }
        return tabs.open(kind: ChangesTab.kind, key: workspaceID) { ChangesTab(projectID: workspaceID, name: project.name, roots: project.roots) } as? ChangesTab
    }
    /// What a Changes tab needs of its project: its folder name and folders;
    /// nil once it is gone.
    func changesProject(_ id: String) -> (name: String, roots: [String])? {
        guard let project = workspaces.first(where: { $0.id == id }), !project.isScratch else { return nil }
        return (URL(fileURLWithPath: project.path).lastPathComponent, project.roots)
    }
    /// ⌘F: the focused chat's search, unless the keys are in text a tab holds.
    func searchFocusedConversation(in window: NSWindow? = NSApp.keyWindow) {
        guard !Self.typingInATab(in: window), let id = focusedSessionID ?? selectedID else { return }
        inspectConversation(id)
    }
    /// ⌘.: stops the focused chat, unless the keys are in text a tab holds.
    func stopFocused(in window: NSWindow? = NSApp.keyWindow) {
        guard !Self.typingInATab(in: window) else { return }
        stop(sessionID: focusedSessionID)
    }
    /// Whether a window's keyboard focus is in editable text inside a tab's
    /// content (`TabContentContainer`), such as a Changes tab's commit
    /// message, where ⌘↩, ⌘. and ⌘F are the text's and not the chat's: the
    /// Changes sheet kept them from the chat while it was up.
    static func typingInATab(in window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let text = window?.firstResponder as? NSTextView, text.isEditable else { return false }
        var view: NSView? = text
        while let current = view {
            if current is TabContentContainer { return true }
            view = current.superview
        }
        return false
    }
}
