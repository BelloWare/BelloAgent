import AppKit

struct SidebarChatEntry: Identifiable {
    let chat: ChatRecord
    let depth: Int
    let hasChildren: Bool
    var id: String { chat.id }
}

extension WorkspaceModel {
    /// Chats in sidebar order across every expanded project, for keyboard navigation.
    var sidebarChatOrder: [String] {
        sidebarProjects.filter { projectIsExpanded($0.id) }.flatMap { project in
            sidebarEntries(in: project.id, archived: projectShowsArchive(project.id), collapsed: []).map(\.chat.id)
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
        if archived, displays[id]?.busy == true { stop(sessionID: id) }
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
