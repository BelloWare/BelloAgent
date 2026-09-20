import Foundation

/// Project navigation preferences live only in Bello Agent's desktop metadata.
/// They never modify Codex configuration or a project's files.
struct ProjectSidebarState: Codable, Sendable, Equatable, Identifiable {
    /// A project cannot fold or page more of its own sidebar than this.
    static let maximumPresentationEntries = 2_000
    static let maximumShownRoots = 100_000
    var id: String
    var expanded = true
    var archived = false
    var revision: Int64 = 0
    /// Chats of this project whose side chats are folded away. Optional so
    /// records written before the sidebar remembered folds still decode.
    var collapsedSides: [String]?
    /// How many root chats each of this project's groups shows, keyed by topic
    /// id, or by the project's own id for the chats outside every topic.
    var shownRoots: [String: Int]?

    /// Nothing read back from the vault is trusted to be the size or shape the
    /// sidebar last wrote.
    var sanitized: ProjectSidebarState {
        var value = self
        value.collapsedSides = collapsedSides.map { ids in
            Array(ids.filter { !$0.isEmpty && $0.utf8.count <= 512 }.prefix(Self.maximumPresentationEntries))
        }
        value.shownRoots = shownRoots.map { pages in
            Dictionary(uniqueKeysWithValues: pages
                .filter { !$0.key.isEmpty && $0.key.utf8.count <= 512 && $0.value > 0 && $0.value <= Self.maximumShownRoots }
                .sorted { $0.key < $1.key }
                .prefix(Self.maximumPresentationEntries)
                .map { ($0.key, $0.value) })
        }
        return value
    }
}

struct SidebarProject: Identifiable {
    let record: WorkspaceRecord
    let available: Bool
    let name: String
    var id: String { record.id }

    /// How much of a sibling's name has to match before the tail is what tells
    /// two projects apart.
    static let ambiguousPrefix = 6
    /// A project name reads from its start: `bello-agent` truncates to
    /// `bello-ag…`, not `be…ent`. Only a sibling sharing a long enough prefix
    /// makes the middle worth keeping.
    static func truncatesInTheMiddle(_ name: String, among siblings: [String]) -> Bool {
        let prefix = name.prefix(ambiguousPrefix)
        guard prefix.count == ambiguousPrefix else { return false }
        return siblings.contains { $0 != name && $0.hasPrefix(prefix) }
    }
}

extension WorkspaceModel {
    /// Losing or replacing configuration must not hide retained history. These
    /// synthetic groups expose existing IDs without recreating trusted folders
    /// or changing the configuration vault.
    var sidebarProjects: [SidebarProject] { sidebarIndex.projects { self.buildSidebarProjects() } }
    private func buildSidebarProjects() -> [SidebarProject] {
        var groups = workspaces.map { SidebarProject(record: $0, available: true, name: URL(fileURLWithPath: $0.path).lastPathComponent) }
        if chats.contains(where: { $0.workspaceID == WorkspaceRecord.scratchID && (!$0.isBackgroundTask || showBackgroundSessions) }) {
            groups.append(SidebarProject(record: scratchWorkspace, available: true, name: "No project"))
        }
        let configured = Set(workspaces.map(\.id)).union([WorkspaceRecord.scratchID])
        for id in Set(chats.map(\.workspaceID) + topics.map(\.workspaceID)).subtracting(configured).sorted() {
            groups.append(SidebarProject(record: WorkspaceRecord(id: id, path: "", trusted: false), available: false, name: "Retained chats · " + String(id.prefix(8))))
        }
        return groups
    }
    func projectIsExpanded(_ id: String) -> Bool { projectSidebarStates[id]?.expanded ?? true }
    func projectShowsArchive(_ id: String) -> Bool { projectSidebarStates[id]?.archived ?? false }

    func restoreProjectSidebarStates() async throws {
        let known = Set(sidebarProjects.map(\.id))
        let stored = try await store?.list(ProjectSidebarState.self, kind: "project-sidebar") ?? []
        projectSidebarStates = Dictionary(stored.filter { known.contains($0.id) && $0.revision >= 0 && $0.revision < Int64.max }
            .map { ($0.id, $0.sanitized) }, uniquingKeysWith: { first, _ in first })
        // Folds and page sizes come back with the disclosure they belong to.
        collapsedSidebarSides = Set(projectSidebarStates.values.flatMap { $0.collapsedSides ?? [] })
        sidebarPageSizes = projectSidebarStates.values.reduce(into: [:]) { pages, state in
            for (group, count) in state.shownRoots ?? [:] { pages[group] = count }
        }
    }

    // MARK: Fold and page

    /// How many root chats a sidebar group shows. A group is keyed by its topic
    /// id, or by its project's id for the chats outside every topic.
    func sidebarShownRoots(_ groupID: String) -> Int {
        max(SidebarSessionPresentation.pageSize, sidebarPageSizes[groupID] ?? SidebarSessionPresentation.pageSize)
    }
    func setSidebarShownRoots(_ groupID: String, to count: Int, in projectID: String) {
        let value = max(SidebarSessionPresentation.pageSize, min(ProjectSidebarState.maximumShownRoots, count))
        let stored: Int? = value == SidebarSessionPresentation.pageSize ? nil : value
        guard sidebarPageSizes[groupID] != stored else { return }
        sidebarPageSizes[groupID] = stored
        saveSidebarPresentation(in: projectID)
    }
    /// Folding a chat's side chats is a decision about the sidebar, and it
    /// outlives the group view, the archive filter and the launch.
    func setSidebarSideFolded(_ chatID: String, folded: Bool) {
        guard folded != collapsedSidebarSides.contains(chatID), let projectID = record(chatID)?.workspaceID else { return }
        if folded { collapsedSidebarSides.insert(chatID) } else { collapsedSidebarSides.remove(chatID) }
        saveSidebarPresentation(in: projectID)
    }
    /// Opening a chat unfolds whatever hides it.
    func revealSidebarSides(_ ids: Set<String>, in projectID: String) {
        guard !ids.isDisjoint(with: collapsedSidebarSides) else { return }
        collapsedSidebarSides.subtract(ids)
        saveSidebarPresentation(in: projectID)
    }
    private func saveSidebarPresentation(in projectID: String) {
        var value = projectSidebarStates[projectID] ?? ProjectSidebarState(id: projectID)
        let folded = collapsedSidebarSides.filter { record($0)?.workspaceID == projectID }.sorted()
        value.collapsedSides = folded.isEmpty ? nil : Array(folded.prefix(ProjectSidebarState.maximumPresentationEntries))
        let groups = Set([projectID] + topics(in: projectID).map(\.id))
        let pages = sidebarPageSizes.filter { groups.contains($0.key) }
        value.shownRoots = pages.isEmpty ? nil : pages
        saveProjectSidebarState(value)
    }

    func setProjectExpanded(_ id: String, expanded: Bool) {
        guard sidebarProjects.contains(where: { $0.id == id }) else { return }
        var value = projectSidebarStates[id] ?? ProjectSidebarState(id: id)
        guard value.expanded != expanded else { return }
        value.expanded = expanded; saveProjectSidebarState(value)
    }
    /// Switching between the chats and the archive starts each of the
    /// project's groups at its first page again.
    private func resetSidebarPages(in projectID: String) {
        let groups = Set([projectID] + topics(in: projectID).map(\.id))
        guard sidebarPageSizes.keys.contains(where: groups.contains) else { return }
        for group in groups { sidebarPageSizes.removeValue(forKey: group) }
    }

    func setProjectArchiveFilter(_ id: String, archived: Bool) {
        guard sidebarProjects.contains(where: { $0.id == id }) else { return }
        var value = projectSidebarStates[id] ?? ProjectSidebarState(id: id)
        let changing = value.archived != archived
        value.expanded = true; value.archived = archived
        if selectedWorkspaceID == id { showArchivedSessions = archived }
        if changing { resetSidebarPages(in: id); value.shownRoots = nil }
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
        if let topicID = effectiveTopicID(for: item) { setTopicExpanded(topicID, expanded: true) }
    }

    func newChat(in projectID: String) {
        newChat(in: projectID, topicID: nil)
    }

    func newChat(in projectID: String, topicID: String?) {
        guard let project = workspaces.first(where: { $0.id == projectID }), project.trusted else {
            error = "Choose a trusted project before starting a chat."; return
        }
        selectedWorkspaceID = projectID
        if !requestProfiles.contains(where: { $0.id == profileChoice }) { profileChoice = requestProfiles.first?.id ?? "" }
        setProjectArchiveFilter(projectID, archived: false)
        if let topicID { setTopicExpanded(topicID, expanded: true) }
        createNewChat(topicID: topicID)
    }

    private func saveProjectSidebarState(_ proposed: ProjectSidebarState) {
        let previous = projectSidebarStates[proposed.id] ?? ProjectSidebarState(id: proposed.id)
        guard previous.expanded != proposed.expanded || previous.archived != proposed.archived
                || previous.collapsedSides != proposed.collapsedSides || previous.shownRoots != proposed.shownRoots else { return }
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
