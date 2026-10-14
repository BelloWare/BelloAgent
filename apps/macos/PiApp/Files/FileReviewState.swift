import AppKit
import FileView
import GitView

/// TabHost stores this beside the canonical file reference. Older tabs only
/// have `project`; optional reading state deliberately contains no file text.
struct FileReviewState: Codable {
    var project: String?
    var reading: FileReadingPosition?
}

/// Quick Open's existing twenty references per project, in desktop UI state
/// alongside TabHost. Tests pass their own defaults suite (or no persistence).
struct FileRecentState: Codable {
    var version = 1
    var projects: [String: [String]]
    static let key = "fileReviewRecents"
    static let projectLimit = 128
    static let byteLimit = 2 << 20

    @MainActor static func read(_ defaults: UserDefaults?) -> [String: [URL]] {
        guard let data = defaults?.data(forKey: key), data.count <= byteLimit,
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.projects.sorted { $0.key < $1.key }.prefix(projectLimit).map { id, paths in
            var seen = Set<String>()
            return (id, paths.filter { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") && seen.insert($0).inserted }
                .prefix(QuickOpen.recentLimit).map { URL(fileURLWithPath: $0) })
        })
    }
    @MainActor static func write(_ recents: [String: [URL]], to defaults: UserDefaults?) {
        guard let defaults else { return }
        let value = Self(projects: recents.mapValues { $0.map(\.path) })
        if let data = try? JSONEncoder().encode(value), data.count <= byteLimit { defaults.set(data, forKey: key) }
    }
}

/// One outstanding History intent across the workspace, including detached
/// windows. A slower source tab cannot replace a newer file's history.
@MainActor final class FileReviewNavigation {
    var revision = 0
    weak var source: FileTab?
    /// Deterministic fixture delay at the real repository resolution boundary.
    var beforeResolution: (() async -> Void)?
    var repositoryRoot: ((String) async -> String?)?
    func cancel() {
        source?.historyTask?.cancel(); source = nil; revision &+= 1
    }
}

extension WorkspaceModel {
    /// Direct file → History navigation is independent of blame. Resolve the
    /// repository off the UI actor, then check the originating project and tab
    /// again before presenting it. No Git mutation is involved.
    func showFileHistory(from tab: FileTab) {
        guard !isShutDown, tab.readable, let projectID = tab.projectID,
              let project = workspace(for: projectID), project.trusted,
              tabs.allTabs.contains(where: { $0 === tab }) else { return }
        tabs.activate(tab)
        fileReviewNavigation.cancel()
        fileReviewNavigation.source = tab
        let revision = fileReviewNavigation.revision
        (tabs.tab(kind: ChangesTab.kind, key: projectID) as? ChangesTab)?.navigation?.cancel()
        tab.historyTask?.cancel()
        let url = tab.url, roots = project.roots, service = FileBlame.service, before = fileReviewNavigation.beforeResolution
        let repositoryRoot = fileReviewNavigation.repositoryRoot
        tab.historyTask = Task { [weak self, weak tab] in
            await before?()
            guard !Task.isCancelled else { return }
            // Refuse redirected or no-longer-contained references before
            // starting even a read-only Git process in that directory.
            let eligible = await Task.detached(priority: .userInitiated) {
                // Retained URLs cache metadata. Each boundary needs a fresh
                // read, including after the repository-resolution await.
                let current = URL(fileURLWithPath: url.path)
                return current.resolvingSymlinksInPath().path == url.path &&
                (try? current.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                roots.contains { root in
                    let path = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                    return url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
                }
            }.value
            guard !Task.isCancelled else { return }
            guard eligible else { return }
            guard self?.isShutDown == false, self?.fileReviewNavigation.revision == revision,
                  tab?.readable == true, self?.tabs.allTabs.contains(where: { $0 === tab }) == true,
                  self?.workspace(for: projectID)?.trusted == true, self?.workspace(for: projectID)?.roots == roots else { return }
            let folder = url.deletingLastPathComponent().path
            let top = if let repositoryRoot { await repositoryRoot(folder) } else { await service.repositoryRoot(of: folder) }
            guard !Task.isCancelled else { return }
            let location = await Task.detached(priority: .userInitiated) { () -> (folder: String, path: String)? in
                let current = URL(fileURLWithPath: url.path)
                guard let top, current.resolvingSymlinksInPath().path == url.path,
                      (try? current.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                let resolvedTop = URL(fileURLWithPath: top).resolvingSymlinksInPath().path
                guard url.path.hasPrefix(resolvedTop + "/") else { return nil }
                let folder = roots.first { root in
                    let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
                    return url.path.hasPrefix(resolved.hasSuffix("/") ? resolved : resolved + "/") &&
                        (resolved == resolvedTop || resolved.hasPrefix(resolvedTop + "/") || resolvedTop.hasPrefix(resolved + "/"))
                }
                return folder.map { folder in
                    let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
                    // A nested repository must be read at its own root, not
                    // silently routed to an enclosing project's repository.
                    let queryFolder = resolvedTop.hasPrefix(resolved + "/") ? top : folder
                    return (queryFolder, String(url.path.dropFirst(resolvedTop.count + 1)))
                }
            }.value
            guard !Task.isCancelled, let self, !self.isShutDown, let tab, tab.readable,
                  self.fileReviewNavigation.revision == revision,
                  self.tabs.allTabs.contains(where: { $0 === tab }),
                  let current = self.workspace(for: projectID), current.trusted, current.roots == roots else { return }
            guard let location else { self.error = "This file is not in a Git repository in its project."; return }
            guard let changes = self.showChanges(in: projectID) else { return }
            changes.navigation?.cancel()
            changes.cameFrom(tab)
            let controller = changes.controller
            // Keep configured repositories reachable while a nested target is
            // selected, and let the picker name its current selection.
            let choices = roots.contains(location.folder) ? roots : roots + [location.folder]
            if controller.roots != choices { controller.roots = choices }
            if controller.root != location.folder { controller.root = location.folder }
            controller.showFileHistory(location.path)
        }
    }
}
