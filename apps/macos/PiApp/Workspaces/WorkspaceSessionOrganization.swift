import AppKit

struct SidebarChatEntry: Identifiable {
    let chat: ChatRecord
    let depth: Int
    let hasChildren: Bool
    var id: String { chat.id }
}

/// Everything the sidebar asks the model for, answered once per change instead
/// of once per row. Every group recomputes its entries several times in one
/// `body`, every row looks its own record up, and the marked-rows bar rebuilds
/// the whole sidebar order: with a few hundred chats that turned one unread dot
/// or one selection into tens of milliseconds of repeated filtering, sorting
/// and linear scanning on the main thread. `WorkspaceModel` invalidates this
/// whenever anything these queries read changes.
@MainActor final class SidebarIndex {
    struct EntryKey: Hashable {
        let project: String
        let topic: String?
        let archived: Bool
        let collapsed: [String]
    }
    /// One sidebar group of one project: its chats, filtered and sorted.
    struct GroupKey: Hashable {
        let project: String
        let topic: String?
        let archived: Bool
    }
    private var chatsByID: [String: ChatRecord]?
    private var sidesByID: [String: SideRecord]?
    private var projectGroups: [SidebarProject]?
    private var groupChats: [GroupKey: [ChatRecord]] = [:]
    private var groupedProjects: Set<String> = []
    private var entryLists: [EntryKey: [SidebarChatEntry]] = [:]
    private var chatOrder: [String]?
    /// How many of these answers were actually computed rather than reused.
    /// A sidebar pass must not grow this with the number of rows it draws.
    private(set) var computations = 0

    func invalidate() {
        chatsByID = nil; sidesByID = nil; projectGroups = nil; chatOrder = nil
        if !entryLists.isEmpty { entryLists.removeAll(keepingCapacity: true) }
        if !groupChats.isEmpty { groupChats.removeAll(keepingCapacity: true); groupedProjects.removeAll(keepingCapacity: true) }
    }
    /// Every group of a project in one pass over that project's chats. Asking
    /// per group filtered the whole workspace once per topic, per archive
    /// filter, per project — a dozen scans and a dozen sorts for one redraw.
    func group(_ key: GroupKey, _ build: (String) -> [GroupKey: [ChatRecord]]) -> [ChatRecord] {
        if !groupedProjects.contains(key.project) {
            computations += 1
            groupedProjects.insert(key.project)
            for (bucket, chats) in build(key.project) { groupChats[bucket] = chats }
        }
        return groupChats[key] ?? []
    }
    func chat(_ id: String, in chats: [ChatRecord]) -> ChatRecord? {
        if chatsByID == nil {
            computations += 1
            chatsByID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return chatsByID?[id]
    }
    func side(_ id: String, in sides: [String: SideRecord]) -> SideRecord? {
        if sidesByID == nil {
            computations += 1
            sidesByID = Dictionary(sides.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return sidesByID?[id]
    }
    func projects(_ build: () -> [SidebarProject]) -> [SidebarProject] {
        if let projectGroups { return projectGroups }
        computations += 1
        let value = build(); projectGroups = value; return value
    }
    func entries(_ key: EntryKey, _ build: () -> [SidebarChatEntry]) -> [SidebarChatEntry] {
        if let cached = entryLists[key] { return cached }
        computations += 1
        let value = build(); entryLists[key] = value; return value
    }
    func order(_ build: () -> [String]) -> [String] {
        if let chatOrder { return chatOrder }
        computations += 1
        let value = build(); chatOrder = value; return value
    }
}

extension WorkspaceModel {
    /// Chats in the order the sidebar lists them: for keyboard navigation and
    /// for what a Shift range covers. A filter expands every project and topic
    /// and hides what does not match, so the order has to follow it — a range
    /// drawn over three visible rows used to mark every chat between them,
    /// including the ones the filter had taken off screen.
    var sidebarChatOrder: [String] {
        sidebarIndex.order {
            let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            return sidebarProjects.filter { !query.isEmpty || projectIsExpanded($0.id) }.flatMap { project -> [String] in
                let archive = projectShowsArchive(project.id)
                let grouped = topics(in: project.id).filter { !query.isEmpty || $0.expanded }.flatMap { topic -> [String] in
                    // A topic whose own title matches lists all of its chats.
                    let inner = topic.title.localizedCaseInsensitiveContains(query) ? "" : query
                    return SidebarSessionPresentation
                        .filtered(sidebarEntries(in: project.id, topicID: topic.id, archived: archive, collapsed: []), by: inner)
                        .map(\.chat.id)
                }
                return grouped + SidebarSessionPresentation
                    .filtered(sidebarEntries(in: project.id, topicID: nil, archived: archive, collapsed: []), by: query)
                    .map(\.chat.id)
            }
        }
    }
    /// Command-Option-Down and Command-Option-Up move through the sidebar
    /// without the mouse; rows are buttons, so arrow keys alone do nothing.
    func selectAdjacentChat(_ offset: Int) {
        guard page == .chats else { return }
        let order = sidebarChatOrder; guard !order.isEmpty else { return }
        let index = order.firstIndex(of: selectedID ?? "").map { max(0, min(order.count - 1, $0 + offset)) } ?? (offset > 0 ? 0 : order.count - 1)
        let target = order[index]
        guard target != selectedID else { return }
        Task { await select(target) }
    }

    /// Archive is a sidebar filter, not a host/session lifecycle operation.
    /// Active work, queued turns, unread state, drafts and captures stay intact.
    func sidebarChats(in workspaceID: String?, archived: Bool, excluding ids: Set<String> = []) -> [ChatRecord] {
        chats.filter { $0.workspaceID == workspaceID && $0.isArchived == archived && !ids.contains($0.id) && (!$0.isBackgroundTask || showBackgroundSessions) }
            .sorted(by: ChatRecord.sidebarPrecedes)
    }

    /// Durable side sessions stay under their parent even when their split pane
    /// is closed. A pinned child or a different archive state stays accessible
    /// as a top-level row. Invalid/cyclic legacy relationships cannot hide data.
    func sidebarEntries(in projectID: String, archived: Bool, collapsed: Set<String>) -> [SidebarChatEntry] {
        let visible = sidebarChats(in: projectID, archived: archived)
        return sidebarTree(visible, collapsed: collapsed)
    }

    /// A topic is a presentation group, independent of the journal's side
    /// relationship. A child in another group stays visible as a root there.
    func sidebarEntries(in projectID: String, topicID: String?, archived: Bool, collapsed: Set<String>) -> [SidebarChatEntry] {
        // One group asks for the same list several times in a single body, and
        // every project asks again: filtering and sorting the whole project for
        // each of those is what made a large sidebar slow.
        let key = SidebarIndex.EntryKey(project: projectID, topic: topicID, archived: archived, collapsed: collapsed.sorted())
        return sidebarIndex.entries(key) {
            sidebarTree(sidebarGroupChats(in: projectID, topicID: topicID, archived: archived), collapsed: collapsed)
        }
    }

    /// The chats of one sidebar group, sorted. Filtering before sorting keeps a
    /// topic from sorting the whole project, and bucketing every group of the
    /// project at once keeps each group from scanning the whole workspace.
    private func sidebarGroupChats(in projectID: String, topicID: String?, archived: Bool) -> [ChatRecord] {
        sidebarIndex.group(SidebarIndex.GroupKey(project: projectID, topic: topicID, archived: archived)) { project in
            let validTopics = Set(topics.filter { $0.workspaceID == project }.map(\.id))
            var buckets: [SidebarIndex.GroupKey: [ChatRecord]] = [:]
            for chat in chats where chat.workspaceID == project && (!chat.isBackgroundTask || showBackgroundSessions) {
                let group = !chat.isBackgroundTask && project != WorkspaceRecord.scratchID
                    ? chat.topicID.flatMap { validTopics.contains($0) ? $0 : nil } : nil
                buckets[SidebarIndex.GroupKey(project: project, topic: group, archived: chat.isArchived), default: []].append(chat)
            }
            for key in buckets.keys { buckets[key]?.sort(by: ChatRecord.sidebarPrecedes) }
            return buckets
        }
    }

    private func sidebarTree(_ visible: [ChatRecord], collapsed: Set<String>) -> [SidebarChatEntry] {
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [ChatRecord]] = [:], roots: [ChatRecord] = []
        for chat in visible {
            if !chat.isPinned, let parent = chat.parentSessionID, parent != chat.id, byID[parent] != nil { children[parent, default: []].append(chat) }
            else { roots.append(chat) }
        }
        var result: [SidebarChatEntry] = [], visited: Set<String> = []
        func appendTree(_ root: ChatRecord) {
            var stack = [(root, 0, true)]
            while let (chat, depth, shown) = stack.popLast() {
                guard visited.insert(chat.id).inserted else { continue }
                let descendants = children[chat.id] ?? []
                if shown { result.append(SidebarChatEntry(chat: chat, depth: depth, hasChildren: !descendants.isEmpty)) }
                for child in descendants.reversed() { stack.append((child, depth + 1, shown && !collapsed.contains(chat.id))) }
            }
        }
        for chat in roots { appendTree(chat) }
        for chat in visible where !visited.contains(chat.id) { appendTree(chat) }
        return result
    }

    /// The rename sheet: an editable title plus mini-model suggestions.
    func renameSession(_ id: String) { presentRename(id) }
    func presentRename(_ id: String) {
        guard !installPreparing, let item = chats.first(where: { $0.id == id }), !item.isBackgroundTask else { return }
        renameTarget = RenameTarget(id: id)
    }

    func setSessionTitle(_ id: String, title: String) async throws {
        try await changeSessionOrganization(id, change: .title(ChatRecord.normalizedTitle(title)))
    }

    func toggleSessionPin(_ id: String) {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        Task { do { try await setSessionPinned(id, pinned: !item.isPinned) } catch { self.error = error.localizedDescription } }
    }
    func setSessionPinned(_ id: String, pinned: Bool) async throws {
        try await changeSessionOrganization(id, change: .pinned(pinned))
    }

    func toggleSessionArchive(_ id: String) {
        guard let item = chats.first(where: { $0.id == id }) else { return }
        Task { do { try await setSessionArchived(id, archived: !item.isArchived) } catch { self.error = error.localizedDescription } }
    }
    func setSessionArchived(_ id: String, archived: Bool) async throws {
        // An archived chat runs nothing: a run in progress stops, and its queued follow-ups wait for a restore.
        if archived, displays[id]?.busy == true { stop(sessionID: id, userInitiated: false) }
        try await changeSessionOrganization(id, change: .archived(archived))
        if archived { updateDockBadge() }
        // A background session can be archived without changing current focus.
        guard selectedID == id || focusedSessionID == id, let item = record(id) else { return }
        if archived {
            // Archiving never switches the sidebar to the archive; the user
            // opens it deliberately. Move on to the nearest active chat instead.
            if selectedID == id, let next = sidebarChats(in: item.workspaceID, archived: false, excluding: [id]).first { await select(next.id) }
        } else {
            revealProjectChat(item)
        }
    }

    private func changeSessionOrganization(_ id: String, change: ChatOrganizationChange) async throws {
        guard !installPreparing else { throw HostError.failure("Wait for the app update to finish before changing a chat.") }
        guard chats.contains(where: { $0.id == id }), let store else { throw HostError.failure("This saved chat is unavailable.") }
        try await materializeChat(id)
        let saved = try await store.updateChatOrganization(id: id, change: change)
        guard let index = chats.firstIndex(where: { $0.id == id }),
              (saved.organizationRevision ?? 0) >= (chats[index].organizationRevision ?? 0) else { return }
        // An unrelated path/model update may have completed during the actor
        // write. Only publish the organization fields returned by this change.
        chats[index].applyOrganization(from: saved)
        if let side = side(id) { sides[side.parentID]?.title = chats[index].title }
    }
}
