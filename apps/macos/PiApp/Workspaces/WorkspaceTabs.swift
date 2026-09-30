import AppKit
import FileView

// What the workspace does with the tabs beside its chats (`TabHost`): opens
// files in them, closes the one shown with ⌘W, and tells a file tab what it
// needs to know of its project.

extension WorkspaceModel {
    /// Opens a file in a tab of the pane (or shows the tab it is open in,
    /// wherever it is), at lines if given, as a file of a project.
    @discardableResult func openFile(_ url: URL, lines: ClosedRange<Int>? = nil, project: String? = nil) -> FileTab {
        let key = FileTab.key(for: url)
        let tab = tabs.open(kind: FileTab.kind, key: key) { FileTab(url: url, projectID: project ?? projectID(holding: key), lines: lines) }
        if let file = tab as? FileTab {
            // Kept for when it is first shown, if it has not been yet.
            if let lines { file.reveal(lines: lines) }
            return file
        }
        return FileTab(url: url, projectID: project)
    }
    /// The project a path is in: the one whose root holds it most closely.
    func projectID(holding path: String) -> String? {
        var best: (id: String, length: Int)?
        for project in workspaces where !project.isScratch {
            for root in project.roots {
                let root = FileTab.key(for: URL(fileURLWithPath: root))
                guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
                if root.count > best?.length ?? -1 { best = (project.id, root.count) }
            }
        }
        return best?.id
    }
    /// What a file tab needs to know of its project.
    func fileProjectState(_ id: String?) -> FileProjectState {
        guard let id else { return .none }
        guard let project = workspaces.first(where: { $0.id == id }) else { return .removed }
        let name = URL(fileURLWithPath: project.path).lastPathComponent
        return project.trusted ? .trusted(name: name, root: FileTab.key(for: URL(fileURLWithPath: project.path))) : .untrusted(name: name)
    }
    /// Whether the chat on screen shows its side beside it.
    var paneSideAvailable: Bool {
        guard selected != nil, let chat else { return false }
        return sides[chat.id].flatMap { displays[$0.id] } != nil
    }
    /// ⌘W in the main window: the tab its pane shows closes, when the chats
    /// are on screen, no sheet is up, and a tab (not the chat's side) is
    /// shown. Focus stays where it was, unless it was in the tab closed:
    /// then it goes to the tab shown next, if any.
    func closeShownPaneTab() -> Bool {
        guard page == .chats, !presentsSheet, let shown = tabs.pane.shownTab(sideAvailable: paneSideAvailable) else { return false }
        let window = shown.hasContent ? shown.contentView.window : nil
        let hadFocus = (window?.firstResponder as? NSView).map { $0 === shown.contentView || $0.isDescendant(of: shown.contentView) } ?? false
        tabs.close(shown)
        if hadFocus, let window {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let next = self.tabs.pane.shownTab(sideAvailable: self.paneSideAvailable)?.focusView, next.window === window { window.makeFirstResponder(next) }
                    else if window.firstResponder === window || window.firstResponder == nil { window.makeFirstResponder(nil) }
                }
            }
        }
        return true
    }
}
