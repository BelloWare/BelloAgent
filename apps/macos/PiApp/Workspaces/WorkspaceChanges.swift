import AppKit
import GitView

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
    /// Opens the change a blamed line came from: the project's Changes, on
    /// the folder holding that repository, at the commit, its file under the
    /// name it had there, and the line. The file's tab stays as it is, to
    /// come back to. Only from a file still readable in its project.
    func showHistoricalChange(from tab: FileTab, target: GitHistoryTarget, repository: String, while still: @escaping @MainActor () -> Bool = { true }) {
        guard tab.readable, let projectID = tab.projectID, let project = changesProject(projectID) else {
            error = "Open the file from a project to see its history."; return
        }
        let top = URL(fileURLWithPath: repository).resolvingSymlinksInPath().path
        // The project's folder this repository is in, or that is in it.
        guard let folder = project.roots.first(where: { root in
            let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return resolved == top || resolved.hasPrefix(top + "/") || top.hasPrefix(resolved + "/")
        }) else {
            error = "This file's repository is not one of \(project.name)'s folders."; return
        }
        guard let changes = showChanges(in: projectID) else { return }
        changes.cameFrom(tab)
        let controller = changes.controller
        if controller.root != folder { controller.root = folder }
        // The file must stay readable in its project, and the project
        // trusted, until the change is shown: asked again after every wait.
        changes.navigate { [weak tab] in
            await controller.revealHistory(target, in: repository) {
                guard let tab else { return false }
                return still() && tab.readable && tab.container != nil && FileTab.resolveProject(projectID).isTrusted
            }
        }
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
    /// ⌘F, ⌘G, ⇧⌘G: the focused chat's find bar over its transcript,
    /// unless the keys are in text a tab holds.
    func findInFocusedConversation(_ kind: TranscriptFindCommand.Kind, in window: NSWindow? = NSApp.keyWindow) {
        guard !Self.typingInATab(in: window), let id = focusedSessionID ?? selectedID, let view = displays[id] else { return }
        revealSerial += 1
        view.findCommand = TranscriptFindCommand(kind: kind, serial: revealSerial)
    }
    /// Whether the focused chat's find bar is open: Find Previous (⇧⌘G) is
    /// only offered then; otherwise the keys open Changes and History.
    var focusedFindIsOpen: Bool {
        (focusedSessionID ?? selectedID).flatMap { displays[$0] }?.findHost?.findIsOpen == true
    }
    /// ⌘.: stops the focused chat, unless the keys are in text a tab holds.
    func stopFocused(in window: NSWindow? = NSApp.keyWindow) {
        guard !Self.typingInATab(in: window) else { return }
        stop(sessionID: focusedSessionID)
    }
    /// Whether a window's keyboard focus is in editable text inside a tab's
    /// content (`TabContentContainer`), such as a Changes tab's commit
    /// message, where the current shortcut routing keeps ⌘↩, ⌘. and ⌘F
    /// from acting on the chat.
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
