import Foundation

/// Project navigation preferences live only in Bello Agent's desktop metadata.
/// They never modify Codex configuration or a project's files.
struct ProjectSidebarState: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var expanded = true
    var archived = false
    var revision: Int64 = 0
}

struct SidebarProject: Identifiable {
    let record: WorkspaceRecord
    let available: Bool
    let name: String
    var id: String { record.id }
}

extension WorkspaceModel {
    /// Losing or replacing configuration must not hide retained history. These
    /// synthetic groups expose existing IDs without recreating trusted folders
    /// or changing the configuration vault.
    var sidebarProjects: [SidebarProject] {
        var groups = workspaces.map { SidebarProject(record: $0, available: true, name: URL(fileURLWithPath: $0.path).lastPathComponent) }
        if chats.contains(where: { $0.workspaceID == WorkspaceRecord.scratchID && (!$0.isBackgroundTask || showBackgroundSessions) }) {
            groups.append(SidebarProject(record: scratchWorkspace, available: true, name: "No project"))
        }
        let configured = Set(workspaces.map(\.id)).union([WorkspaceRecord.scratchID])
        for id in Set(chats.map(\.workspaceID)).subtracting(configured).sorted() {
            groups.append(SidebarProject(record: WorkspaceRecord(id: id, path: "", trusted: false), available: false, name: "Retained chats · " + String(id.prefix(8))))
        }
        return groups
    }
    func projectIsExpanded(_ id: String) -> Bool { projectSidebarStates[id]?.expanded ?? true }
    func projectShowsArchive(_ id: String) -> Bool { projectSidebarStates[id]?.archived ?? false }

    func restoreProjectSidebarStates() async throws {
        let known = Set(sidebarProjects.map(\.id))
        let stored = try await store?.list(ProjectSidebarState.self, kind: "project-sidebar") ?? []
        projectSidebarStates = Dictionary(stored.filter { known.contains($0.id) && $0.revision >= 0 && $0.revision < Int64.max }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func setProjectExpanded(_ id: String, expanded: Bool) {
        guard sidebarProjects.contains(where: { $0.id == id }) else { return }
        var value = projectSidebarStates[id] ?? ProjectSidebarState(id: id)
        guard value.expanded != expanded else { return }
        value.expanded = expanded; saveProjectSidebarState(value)
    }

    func setProjectArchiveFilter(_ id: String, archived: Bool) {
        guard sidebarProjects.contains(where: { $0.id == id }) else { return }
        var value = projectSidebarStates[id] ?? ProjectSidebarState(id: id)
        value.expanded = true; value.archived = archived
        if selectedWorkspaceID == id { showArchivedSessions = archived }
        saveProjectSidebarState(value)
    }

    /// Selection from reports or the status panel reveals exactly its project.
    /// Other projects keep their disclosure and archive state.
    func revealProjectChat(_ item: ChatRecord) {
        if item.isBackgroundTask { showBackgroundSessions = true }
        showArchivedSessions = item.isArchived
        guard sidebarProjects.contains(where: { $0.id == item.workspaceID }) else { return }
        var value = projectSidebarStates[item.workspaceID] ?? ProjectSidebarState(id: item.workspaceID)
        value.expanded = true; value.archived = item.isArchived
        saveProjectSidebarState(value)
    }

    func newChat(in projectID: String) {
        guard let project = workspaces.first(where: { $0.id == projectID }), project.trusted else {
            error = "Choose a trusted project before starting a chat."; return
        }
        selectedWorkspaceID = projectID
        if !requestProfiles.contains(where: { $0.id == profileChoice }) { profileChoice = requestProfiles.first?.id ?? "" }
        setProjectArchiveFilter(projectID, archived: false)
        newChat()
    }

    private func saveProjectSidebarState(_ proposed: ProjectSidebarState) {
        let previous = projectSidebarStates[proposed.id] ?? ProjectSidebarState(id: proposed.id)
        guard previous.expanded != proposed.expanded || previous.archived != proposed.archived else { return }
        var value = proposed
        value.revision = max(previous.revision + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        projectSidebarStates[value.id] = value
        dirtyProjectSidebarStates.insert(value.id)
        scheduleProjectSidebarWrite(value.id)
    }

    private func scheduleProjectSidebarWrite(_ id: String) {
        guard projectSidebarWrites[id] == nil else { return }
        projectSidebarWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.projectSidebarWrites[id] = nil }
            while self.dirtyProjectSidebarStates.contains(id) {
                if !(await self.persistProjectSidebarState(id)) { break }
            }
        }
    }

    private func persistProjectSidebarState(_ id: String) async -> Bool {
        guard let value = projectSidebarStates[id] else { dirtyProjectSidebarStates.remove(id); return true }
        do {
            guard let store else { throw StoreError.unavailable }
            try await store.put(value, kind: "project-sidebar", id: id, revision: value.revision)
            if projectSidebarStates[id]?.revision == value.revision { dirtyProjectSidebarStates.remove(id) }
            return true
        } catch {
            self.error = "Project sidebar preferences could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult func flushProjectSidebarState(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var retried: Set<String> = []
        while !dirtyProjectSidebarStates.isEmpty || !projectSidebarWrites.isEmpty {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            for id in dirtyProjectSidebarStates where projectSidebarWrites[id] == nil && retried.insert(id).inserted {
                scheduleProjectSidebarWrite(id)
            }
            if projectSidebarWrites.isEmpty { return dirtyProjectSidebarStates.isEmpty }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }
}
