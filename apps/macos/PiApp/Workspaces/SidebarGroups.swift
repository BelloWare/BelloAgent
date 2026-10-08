import AppKit

// What the sidebar's groups share: paging and filtering of a group's chats,
// and the commands a chat's menus offer. The list itself is SidebarList.swift.

/// Pure sidebar presentation shared by topic and project-root groups. A title
/// match keeps its ancestors visible, so filtering cannot strand a side chat.
enum SidebarSessionPresentation {
    static let pageSize = 5
    /// The group key of a group's archived chats: they page on their own.
    static func archiveGroupID(_ group: String) -> String { "archived:" + group }
    /// `contentMatches`: chats whose messages match (`SidebarSearch`), listed as a title match is.
    static func filtered(_ entries: [SidebarChatEntry], by query: String, contentMatches: Set<String> = []) -> [SidebarChatEntry] {
        guard !query.isEmpty else { return entries }
        var kept: Set<Int> = [], ancestors: [Int] = []
        for (index, entry) in entries.enumerated() {
            while let last = ancestors.last, entries[last].depth >= entry.depth { ancestors.removeLast() }
            if entry.chat.title.localizedCaseInsensitiveContains(query) || contentMatches.contains(entry.chat.id) { kept.formUnion(ancestors); kept.insert(index) }
            ancestors.append(index)
        }
        return entries.enumerated().compactMap { kept.contains($0.offset) ? $0.element : nil }
    }
    static func page(_ entries: [SidebarChatEntry], roots requested: Int, selected: Set<String>, filtering: Bool) -> [SidebarChatEntry] {
        guard !filtering else { return entries }
        var limit = max(1, requested), rootCounts = 0
        for entry in entries {
            if entry.depth == 0 { rootCounts += 1 }
            if selected.contains(entry.id) { limit = max(limit, rootCounts) }
        }
        var result: [SidebarChatEntry] = [], roots = 0
        for entry in entries {
            if entry.depth == 0 { roots += 1; if roots > limit { break } }
            result.append(entry)
        }
        return result
    }
}

/// A chat's own organising commands: in its right-click menu and in the
/// conversation's "…" menu, built when either opens.
enum SessionOrganizationActions {
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, chat: ChatRecord) -> [PiMenuEntry] {
        if !chat.isBackgroundTask { PiMenuEntry.button("Rename…") { model.renameSession(chat.id) } }
        PiMenuEntry.button(chat.isPinned ? "Unpin Chat" : "Pin Chat", systemImage: chat.isPinned ? "pin.slash" : "pin") { model.toggleSessionPin(chat.id) }
        PiMenuEntry.button(chat.isArchived ? "Restore Chat" : "Archive Chat", systemImage: chat.isArchived ? "arrow.uturn.backward" : "archivebox") {
            model.toggleSessionArchive(chat.id)
        }
        if chat.workspaceID != WorkspaceRecord.scratchID, !chat.isUtilityChat {
            let current = model.effectiveTopicID(for: chat)
            PiMenuEntry.menu("Move to Topic", systemImage: "folder", identifier: "moveSessionToTopic-" + chat.id,
                             help: "Move this chat and its saved side chats within this project") {
                PiMenuEntry.note("Includes saved side chats")
                PiMenuEntry.button("Project root", systemImage: current == nil ? "checkmark" : "tray") { move(chat, model: model, to: nil) }
                for topic in model.topics(in: chat.workspaceID) {
                    PiMenuEntry.button(topic.title, systemImage: current == topic.id ? "checkmark" : "folder") { move(chat, model: model, to: topic.id) }
                }
            }
        }
        if chat.isArchived {
            PiMenuEntry.divider
            PiMenuEntry.button("Delete Chat…", systemImage: "trash", destructive: true) { model.deleteChat(chat.id) }
        }
    }
    @MainActor private static func move(_ chat: ChatRecord, model: WorkspaceModel, to topicID: String?) {
        Task {
            do { try await model.moveSessions([chat.id], in: chat.workspaceID, toTopic: topicID) }
            catch { model.error = error.localizedDescription }
        }
    }
}

/// Shared by sidebar right-click menus and the main/side conversation menu.
enum SessionReferenceActions {
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, sessionID: String) -> [PiMenuEntry] {
        PiMenuEntry.button("Copy Session ID", systemImage: "number", identifier: "copySessionID-" + sessionID) { model.copySessionID(sessionID) }
        PiMenuEntry.button("Copy Session Reference", systemImage: "doc.on.doc", identifier: "copySessionReference-" + sessionID,
                           help: "Copy the session ID, conversation file path, token usage and reported cost") {
            Task { await model.copySessionReference(sessionID) }
        }
    }
}
