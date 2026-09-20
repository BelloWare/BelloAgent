import AppKit
import Foundation

/// Marking sidebar rows for one bulk action. Shift extends a range in sidebar
/// order, Command adds or removes one row, and an ordinary click clears the
/// marks and selects as before. Marking is presentation only: it never opens,
/// closes, stops or starts a chat, and every bulk action below goes through the
/// same durable path as its single-chat menu item.
extension WorkspaceModel {
    /// A bulk action covers what a person can reasonably mark by hand, and one
    /// drag carries exactly the same number.
    static let markedSessionLimit = TopicSessionDrag.maximumSessions

    func isSessionMarked(_ id: String) -> Bool { markedSessionIDs.contains(id) }

    /// Marked chats in sidebar order. Rows whose group is collapsed keep their
    /// marks and sort after the visible ones; chats that no longer exist drop out.
    var markedChats: [ChatRecord] {
        guard !markedSessionIDs.isEmpty else { return [] }
        var rank: [String: Int] = [:]
        for (index, id) in sidebarChatOrder.enumerated() { rank[id] = index }
        return markedSessionIDs.compactMap { record($0) }
            .sorted { (rank[$0.id] ?? Int.max, $0.id) < (rank[$1.id] ?? Int.max, $1.id) }
    }
    /// The one project every mark belongs to, or nil when they are spread out.
    var markedProjectID: String? {
        let projects = Set(markedChats.map(\.workspaceID))
        return projects.count == 1 ? projects.first : nil
    }
    /// What a bulk menu offers: marking one row is still an ordinary selection.
    var hasMarkedSessions: Bool { markedSessionIDs.count > 1 }

    /// Command-click. The first Command-click extends the row that is already
    /// open, so the marks start from what the reader was looking at.
    func toggleSessionMark(_ id: String) {
        guard record(id) != nil else { return }
        var marks = markedSessionIDs.isEmpty ? Set([focusedSessionID ?? selectedID].compactMap { $0 }) : markedSessionIDs
        var anchor = sessionMarkAnchorID
        if marks.contains(id) { marks.remove(id) } else if marks.count < Self.markedSessionLimit { marks.insert(id); anchor = id }
        applyMarks(marks, anchor: anchor)
    }

    /// Shift-click: every row between the anchor and this one, in the order the
    /// sidebar lists them. Rows inside a collapsed side or a folded page are in
    /// that order too, so the count says how many chats the action will touch.
    func extendSessionMarks(to id: String) {
        guard record(id) != nil else { return }
        let order = sidebarChatOrder
        guard let anchor = sessionMarkAnchorID ?? focusedSessionID ?? selectedID,
              anchor != id, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            // No anchor in the listed order: mark this row beside the open chat.
            var marks = markedSessionIDs
            marks.insert(id)
            if let current = focusedSessionID ?? selectedID { marks.insert(current) }
            applyMarks(marks, anchor: id)
            return
        }
        let range = from <= to ? order[from...to] : order[to...from]
        // The anchor stays put, so the next Shift-click re-measures the range
        // from the same row instead of growing the last one.
        applyMarks(Set(range.prefix(Self.markedSessionLimit)), anchor: anchor)
    }

    func clearSessionMarks() {
        guard !markedSessionIDs.isEmpty || sessionMarkAnchorID != nil else { return }
        markedSessionIDs = []; sessionMarkAnchorID = nil
    }

    private func applyMarks(_ marks: Set<String>, anchor: String?) {
        let valid = marks.filter { record($0) != nil }
        if let anchor, valid.isEmpty || valid.contains(anchor) { sessionMarkAnchorID = anchor }
        else if sessionMarkAnchorID.map({ !valid.contains($0) }) ?? true { sessionMarkAnchorID = valid.sorted().first }
        // One mark on the chat that is already open is an ordinary selection.
        markedSessionIDs = valid.count == 1 && valid.first == (focusedSessionID ?? selectedID) ? [] : valid
    }

    /// What one drag carries: the marked chats of this project when the dragged
    /// row is marked, otherwise just that row. Background tasks and connection
    /// tests never travel, exactly as the menu refuses to move them.
    func dragSessionIDs(for id: String, in projectID: String) -> [String] {
        guard markedSessionIDs.contains(id) else { return [id] }
        let ids = markedChats.filter { $0.workspaceID == projectID && !$0.isBackgroundTask && $0.connectionTest != true }.map(\.id)
        return ids.contains(id) ? ids : [id]
    }

    // MARK: Bulk actions

    /// Archives or restores every marked chat, one durable write each, then
    /// clears the marks. A chat already in that state is left alone.
    func archiveMarkedSessions(_ archived: Bool) {
        let ids = markedChats.filter { $0.isArchived != archived }.map(\.id)
        clearSessionMarks()
        guard !ids.isEmpty else { return }
        Task {
            let failed = await applyToMarked(ids) { try await self.setSessionArchived($0, archived: archived) }
            if let failed { error = (archived ? "Some chats could not be archived. " : "Some chats could not be restored. ") + failed }
        }
    }

    func pinMarkedSessions(_ pinned: Bool) {
        let ids = markedChats.filter { $0.isPinned != pinned }.map(\.id)
        clearSessionMarks()
        guard !ids.isEmpty else { return }
        Task {
            let failed = await applyToMarked(ids) { try await self.setSessionPinned($0, pinned: pinned) }
            if let failed { error = "Some chats could not be pinned. " + failed }
        }
    }

    /// One durable write per chat, and the first real failure. A bulk action
    /// runs one await at a time, so a chat can be deleted — from a menu, from
    /// another window, by the run that owned it — while the loop is partway
    /// through. A chat that is no longer there is nothing to report: the reader
    /// deleted it, and "Some chats could not be archived" would be a lie.
    private func applyToMarked(_ ids: [String], _ write: @escaping (String) async throws -> Void) async -> String? {
        var failed: String?
        for id in ids {
            guard chats.contains(where: { $0.id == id }) else { continue }
            do { try await write(id) }
            catch { failed = failed ?? error.localizedDescription }
        }
        return failed
    }

    /// Moves every marked chat of one project into a topic, as one transaction,
    /// the same way the single-chat menu and a drop do.
    func moveMarkedSessions(toTopic topicID: String?) {
        let chats = markedChats.filter { !$0.isBackgroundTask && $0.connectionTest != true }
        guard let projectID = markedProjectID, !chats.isEmpty else {
            error = "Move chats that are all in the same project."; return
        }
        let ids = chats.map(\.id)
        clearSessionMarks()
        Task {
            do { try await moveSessions(ids, in: projectID, toTopic: topicID) }
            catch { self.error = error.localizedDescription }
        }
    }

    func markMarkedSessionsRead() {
        let ids = markedChats.map(\.id)
        clearSessionMarks()
        for id in ids where chats.contains(where: { $0.id == id }) { markSessionRead(id) }
    }
}
