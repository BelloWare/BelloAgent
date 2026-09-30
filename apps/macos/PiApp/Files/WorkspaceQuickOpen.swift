import AppKit

// ⌘P in the workspace window: which project it finds files in, the keys the
// list takes before anything else in the window, and opening its choice in
// a tab beside the chat, the keyboard in the file.

extension QuickOpen.Project {
    init(_ record: WorkspaceRecord) {
        self.init(id: record.id, name: URL(fileURLWithPath: record.path).lastPathComponent, roots: record.roots, trusted: record.trusted)
    }
}

extension WorkspaceModel {
    /// The project ⌘P finds files in: the chat on screen's, else the one
    /// selected; never the scratch space, which is no project.
    var quickOpenProject: WorkspaceRecord? {
        let chatProject = (focusedSessionID ?? selectedID).flatMap { record($0)?.workspaceID }
        guard let id = chatProject ?? selectedWorkspaceID, let project = workspace(for: id), !project.isScratch else { return nil }
        return project
    }
    var canQuickOpen: Bool { !presentsSheet && !installPreparing && quickOpenProject != nil }

    /// Shows ⌘P's list for the project on screen, taking the keyboard from
    /// `window`.
    func showQuickOpen(in window: NSWindow? = NSApp.keyWindow) {
        guard canQuickOpen, let project = quickOpenProject else { return }
        quickOpen.show(QuickOpen.Project(project), in: window)
    }

    /// Opens the list's choice, or row `id`, in a tab: at the line a query
    /// ending ":N" names, else as the tab was if it is open. The chats come
    /// back if another page was shown, and the keyboard goes to the file.
    func openQuickOpenChoice(_ id: String? = nil) {
        if let id { quickOpen.select(id) }
        guard let row = quickOpen.selectedRow else { return }
        let line = quickOpen.line
        quickOpen.close(restoringFocus: false)
        if page != .chats { page = .chats }
        // A listed symlink may resolve into another project's trust boundary.
        let tab = openFile(row.url, lines: line.map { ($0 - 1)...($0 - 1) })
        Task { @MainActor [weak tab] in
            // Once the pane has drawn the tab: its view, in the window.
            for _ in 0..<60 {
                if let view = tab?.focusView, let window = view.window {
                    window.makeFirstResponder(view)
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// A key pressed while ⌘P's list is up: true when the list took it.
    /// ↑ ↓ (and ⌃P ⌃N, page up and down) choose, ↩ opens, esc and ⌘W close.
    func quickOpenKey(_ event: NSEvent) -> Bool {
        guard quickOpen.isOpen, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 125: quickOpen.move(1); return true
            case 126: quickOpen.move(-1); return true
            case 121: quickOpen.move(QuickOpenPanel.visibleRows - 1); return true
            case 116: quickOpen.move(-(QuickOpenPanel.visibleRows - 1)); return true
            case 36, 76: openQuickOpenChoice(); return true
            case 53: quickOpen.close(restoringFocus: true); return true
            default: return false
            }
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .control, key == "n" { quickOpen.move(1); return true }
        if modifiers == .control, key == "p" { quickOpen.move(-1); return true }
        if modifiers == .command, key == "w" { quickOpen.close(restoringFocus: true); return true }
        return false
    }

    /// The projects as configured now, for ⌘P: a project gone or no longer
    /// trusted is forgotten, and its list closed.
    func quickOpenProjectsChanged() {
        quickOpen.projectsChanged(workspaces.filter { !$0.isScratch }.map(QuickOpen.Project.init))
    }
}
