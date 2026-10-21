import AppKit
import FileView
import GitProcessSafety

// What the workspace does with the tabs beside its chats (`TabHost`): opens
// files in them, closes the one shown with ⌘W, and tells a file tab what it
// needs to know of its project.

extension WorkspaceModel {
    /// Opens a file in a tab of the pane (or shows the tab it is open in,
    /// wherever it is), at lines if given, as a file of a project.
    @discardableResult func openFile(_ url: URL, lines: ClosedRange<Int>? = nil, project: String? = nil, in container: TabContainer? = nil) -> FileTab {
        let key = FileTab.key(for: url)
        let tab = tabs.open(kind: FileTab.kind, key: key, in: container) { FileTab(url: url, projectID: project ?? projectID(holding: key), lines: lines) }
        // ⌘P's list offers it again with nothing typed.
        quickOpen.noteOpened(URL(fileURLWithPath: key), projectID: (tab as? FileTab)?.projectID ?? project ?? projectID(holding: key))
        if let file = tab as? FileTab {
            // Kept for when it is first shown, if it has not been yet.
            if let lines { file.reveal(lines: lines) }
            return file
        }
        return FileTab(url: url, projectID: project)
    }
    /// Viewer navigation uses the same opening path as chat links and checks
    /// the destination's project afresh. Restored tabs are configured too.
    func configureFileNavigation(_ tab: HostedTab) {
        guard let file = tab as? FileTab else { return }
        file.openNearbyFile = { [weak self, weak file] url in
            guard let self, let file else { return }
            self.openFile(url, in: file.container).showTop()
        }
        file.containingFolderRoot = { [weak self, weak file] in
            guard let self, let file, let project = self.workspaces.first(where: { $0.id == file.projectID }), project.trusted else { return nil }
            return project.roots.map { URL(fileURLWithPath: FileTab.key(for: URL(fileURLWithPath: $0)), isDirectory: false) }
                .filter { root in FileTab.key(for: file.url).gitIsWithin(root.path) }
                .max { $0.path.utf8.count < $1.path.utf8.count }
        }
    }
    /// A file a chat's tool read or changed, from its card: the path as the
    /// host resolved it, else as the call gave it (from home, or from the
    /// chat's project), at the lines (from 1) read or changed. It opens as a
    /// file of the project whose root holds it, whichever chat named it.
    @discardableResult func openFile(fromChat sessionID: String, path: String, lines: ClosedRange<Int>?) -> FileTab? {
        var resolved = (path as NSString).expandingTildeInPath
        if !resolved.gitHasPrefix("/") {
            guard let workspaceID = record(sessionID)?.workspaceID, let root = workspaces.first(where: { $0.id == workspaceID })?.path else { return nil }
            resolved = (root as NSString).appendingPathComponent(resolved)
        }
        let file = openFile(URL(fileURLWithPath: resolved), lines: lines.map { ($0.lowerBound - 1)...($0.upperBound - 1) })
        // A link to the whole file shows its start, whatever an earlier link
        // to it left shown or set apart.
        if lines == nil { file.showTop() }
        return file
    }
    /// The project a path is in: the one whose root holds it most closely.
    func projectID(holding path: String) -> String? {
        let path = FileTab.key(for: URL(fileURLWithPath: path))
        var best: (id: String, length: Int, trusted: Bool)?
        for project in workspaces where !project.isScratch {
            for root in project.roots {
                let root = FileTab.key(for: URL(fileURLWithPath: root))
                guard path.gitIsWithin(root) else { continue }
                if root.utf8.count > (best?.length ?? -1) || (root.utf8.count == best?.length && best?.trusted == true && !project.trusted) {
                    best = (project.id, root.utf8.count, project.trusted)
                }
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
