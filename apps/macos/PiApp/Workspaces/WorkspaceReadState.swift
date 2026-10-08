import Foundation
import AppKit

/// Only completed assistant identities and counters; no transcript content.
struct SessionReadState: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var observedAssistantCount: Int
    var latestAssistantID: String?
    var unreadOutputs = 0
    var unreadTargetID: String?
    /// The last run failed while the chat was out of view: shown as unread, never counted in the Dock badge.
    var unreadFailure: Bool?
    /// The reader marked the chat unread (Mark as Unread): shown and counted
    /// as one unread reply, in the Dock badge too, until the reader opens it
    /// or marks it read.
    var markedUnread: Bool?
    /// Made by Mark as Unread before any count was observed for the chat: the
    /// next observation takes the helper's counter as already read rather
    /// than counting the whole history as new.
    var baselinePending: Bool?
    var revision: Int64 = 0
    /// Shown as unread in the sidebar, whatever made it so.
    var isUnread: Bool { unreadOutputs > 0 || markedUnread == true }
}

/// Replies not yet published as unread: see `WorkspaceModel.visibleReplyGrace`.
struct HeldUnread {
    var count: Int
    var target: String
    var release: Task<Void, Never>?
}

struct SidebarReadCounts {
    var unreadChats = 0
    var dockChats = 0
    var projects: Set<String> = []
}

extension WorkspaceModel {
    private var sidebarReadCounts: SidebarReadCounts {
        if let readBadgeCache { return readBadgeCache }
        var counts = SidebarReadCounts()
        for state in unreadStates.values {
            guard let chat = record(state.id), !chat.isArchived, chat.connectionTest != true else { continue }
            if state.isUnread {
                counts.unreadChats += 1
                // A mark the reader made counts on its own: a run that fails
                // after it does not take it off the badge.
                if state.markedUnread == true || state.unreadFailure != true { counts.dockChats += 1 }
            }
            if state.isUnread || state.unreadFailure == true { counts.projects.insert(chat.workspaceID) }
        }
        readBadgeCache = counts
        return counts
    }
    var unreadCount: Int { sidebarReadCounts.unreadChats }
    /// Unread replies, or one for a chat the reader marked unread: everything
    /// that shows a dot, a bold title or a count reads this.
    func unreadOutputCount(sessionID: String) -> Int {
        guard let item = record(sessionID), item.connectionTest != true, !item.isArchived, let state = unreadStates[sessionID] else { return 0 }
        return max(state.unreadOutputs, state.markedUnread == true ? 1 : 0)
    }
    /// Unread only because the reader marked it so, with no reply behind the
    /// mark: its words say "Unread", not "New reply".
    func markedUnreadOnly(sessionID: String) -> Bool {
        guard let item = record(sessionID), item.connectionTest != true, !item.isArchived, let state = unreadStates[sessionID] else { return false }
        return state.markedUnread == true && state.unreadOutputs == 0
    }
    /// Whether Mark as Unread applies: a saved chat of the reader's own (not
    /// archived, not a connection test or background request, not a side that
    /// has not been kept, not a New chat never sent), with nothing unread.
    func canMarkSessionUnread(_ sessionID: String) -> Bool {
        guard let item = record(sessionID), !item.isArchived, !item.isUtilityChat, !isEphemeral(sessionID),
              !pendingChatIDs.contains(sessionID), readStatesRestored else { return false }
        return !offersMarkSessionRead(sessionID)
    }
    /// Whether Mark as Read applies: replies not viewed, a failure mark, or
    /// a mark the reader made.
    func offersMarkSessionRead(_ sessionID: String) -> Bool {
        unreadOutputCount(sessionID: sessionID) > 0 || unreadFailure(sessionID: sessionID)
    }
    /// Mark as Unread: the chat shows and counts as one unread reply until
    /// the reader opens it again or marks it read.
    func markSessionUnread(_ sessionID: String) {
        guard canMarkSessionUnread(sessionID) else { return }
        var next = unreadStates[sessionID] ?? SessionReadState(id: sessionID, observedAssistantCount: 0, latestAssistantID: nil, baselinePending: true)
        next.markedUnread = true
        saveReadState(next)
    }
    /// The reader opened the chat: a mark they made is done with. Replies
    /// not yet viewed stay unread until the page sees them.
    func clearManualUnread(sessionID: String) {
        guard var next = unreadStates[sessionID], next.markedUnread == true else { return }
        next.markedUnread = nil
        saveReadState(next)
    }
    /// Whether a collapsed group has to show its dot. Driven from the unread
    /// states, which are few, rather than from every chat of the project.
    func projectHasUnread(_ projectID: String) -> Bool {
        sidebarReadCounts.projects.contains(projectID)
    }
    func unreadFailure(sessionID: String) -> Bool {
        guard let item = record(sessionID), item.connectionTest != true, !item.isArchived else { return false }
        return unreadStates[sessionID]?.unreadFailure == true
    }
    /// A run ended in an error while the chat was not in front: mark it so the
    /// sidebar shows it, without bouncing the Dock or counting in its badge.
    func markRunFailed(sessionID: String) {
        guard let item = record(sessionID), item.connectionTest != true, !item.isArchived else { return }
        guard !(page == .chats && (sessionID == selectedID || sides[selectedID ?? ""]?.id == sessionID) && NSApp.isActive) else { return }
        var next = unreadStates[sessionID] ?? SessionReadState(id: sessionID, observedAssistantCount: 0, latestAssistantID: nil)
        guard next.unreadFailure != true else { return }
        next.unreadFailure = true
        saveReadState(next)
    }
    /// Opening the chat shows the failure where the conversation stopped, which clears the mark.
    func clearFailureMark(sessionID: String) {
        guard var next = unreadStates[sessionID], next.unreadFailure == true else { return }
        next.unreadFailure = nil
        saveReadState(next)
    }

    func restoreReadStates() async throws {
        let known = Set(chats.filter { $0.connectionTest != true }.map(\.id))
        let saved = try await store?.list(SessionReadState.self, kind: "session-read") ?? []
        unreadStates = Dictionary(saved.filter { known.contains($0.id) && (0...100_000).contains($0.observedAssistantCount) && (0...100_000).contains($0.unreadOutputs) && $0.revision >= 0 && $0.revision < Int64.max }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        readStatesRestored = true
        // Chats the reader opened while these were read: their marks are done with.
        for id in openedBeforeReadStates { clearManualUnread(sessionID: id) }
        openedBeforeReadStates = []
        updateDockBadge()
    }

    var applicationIsActive: Bool { applicationIsActiveOverride ?? NSApp.isActive }
    /// A reply that finishes in the chat the reader is looking at, while the
    /// page follows its newest row, is read by the page's own check a frame or
    /// two after it lands. Publishing it as unread first put a dot on that
    /// chat's row, and a count on the Dock, for those frames every time a run
    /// finished. The page gets this long to say it saw the reply; if it does
    /// not (the window is behind another, a sheet is up), the reply becomes
    /// unread then, as it would have.
    static let visibleReplyGrace: Duration = .milliseconds(600)
    private func readerFollowsNewestRow(of sessionID: String) -> Bool {
        page == .chats && (sessionID == selectedID || sides[selectedID ?? ""]?.id == sessionID)
            && displays[sessionID]?.scrollAnchor?.followsBottom == true && applicationIsActive
    }
    private func holdUnread(_ sessionID: String, added: Int, target: String) {
        var held = heldUnread[sessionID] ?? HeldUnread(count: 0, target: target)
        held.count += added; held.target = target
        held.release?.cancel()
        held.release = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleReplyGrace)
            guard !Task.isCancelled else { return }
            self?.publishHeldUnread(sessionID)
        }
        heldUnread[sessionID] = held
    }
    /// The page did not read it in time: the reply is unread after all.
    private func publishHeldUnread(_ sessionID: String) {
        guard let held = heldUnread.removeValue(forKey: sessionID) else { return }
        held.release?.cancel()
        guard record(sessionID) != nil, var next = unreadStates[sessionID] else { return }
        next.unreadOutputs = min(100_000, next.unreadOutputs + held.count)
        next.unreadTargetID = held.target
        saveReadState(next)
    }
    private func dropHeldUnread(_ sessionID: String) {
        heldUnread.removeValue(forKey: sessionID)?.release?.cancel()
    }

    /// Called for every accepted status snapshot, even when no messages were
    /// requested. A first observation baselines imported/existing history.
    /// session.open observes this before any turn can be submitted.
    func observeAssistantOutputs(sessionID: String, snapshot: [String: WireValue]) {
        guard let item = record(sessionID), item.connectionTest != true,
              let rawCount = snapshot["assistantMessageCount"]?.number, rawCount.isFinite,
              rawCount.rounded() == rawCount, rawCount >= 0, rawCount <= 100_000 else { return }
        let latest = snapshot["latestAssistantMessageId"]?.string
        guard latest.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? (rawCount == 0) else { return }
        // A state Mark as Unread made before any count was seen: this count is
        // the history the reader had, not new replies. Taken even mid-run.
        if var pending = unreadStates[sessionID], pending.baselinePending == true {
            pending.baselinePending = nil; pending.observedAssistantCount = Int(rawCount); pending.latestAssistantID = latest
            saveReadState(pending); return
        }
        // A reply is unread only once the run has finished and reported back.
        // Tool-round messages appended mid-run wait for the idle snapshot, so
        // neither the sidebar dot nor the Dock badge appears while work continues.
        if let state = snapshot["state"]?.string, RunState(rawValue: state).isBusy, unreadStates[sessionID] != nil { return }
        let count = Int(rawCount)
        var next = unreadStates[sessionID] ?? SessionReadState(id: sessionID, observedAssistantCount: count, latestAssistantID: latest)
        if count > next.observedAssistantCount, let latest, latest != next.latestAssistantID {
            let added = count - next.observedAssistantCount
            if readerFollowsNewestRow(of: sessionID) {
                holdUnread(sessionID, added: added, target: latest)
            } else {
                // A reply held earlier is older than this one: count it first.
                if let held = heldUnread.removeValue(forKey: sessionID) { held.release?.cancel(); next.unreadOutputs += held.count }
                next.unreadOutputs = min(100_000, next.unreadOutputs + added)
                next.unreadTargetID = latest
            }
        }
        // Branches do not decrement the host's durable counter. A lower value
        // means restored/replaced history, and must not manufacture unread work.
        next.observedAssistantCount = count; next.latestAssistantID = latest
        // A reply that finished while another app is frontmost is easy to miss;
        // bounce the Dock icon once. The badge below carries the count.
        // Archived chats retain read state for restore but show no unread marks.
        if next.unreadOutputs > (unreadStates[sessionID]?.unreadOutputs ?? 0), !NSApp.isActive, NSClassFromString("XCTestCase") == nil,
           snapshot["runStatus"]?.string != "failed", snapshot["state"]?.string != "error", !item.isArchived {
            NSApp.requestUserAttention(.informationalRequest)
        }
        saveReadState(next)
    }

    /// The page checks foreground, key window and occlusion first, and reports
    /// only a completed reply whose bottom is actually in the viewport.
    func acknowledgeVisibleReply(sessionID: String, messageID: String) {
        guard page == .chats, sessionID == selectedID || sides[selectedID ?? ""]?.id == sessionID,
              let message = displays[sessionID]?.messages.first(where: { $0.id == messageID }), message.role == "assistant",
              !message.isStreaming else { return }
        // The page saw this chat's newest reply in a key, visible window: the
        // failure mark it carries has been seen with it.
        clearFailureMark(sessionID: sessionID)
        if heldUnread[sessionID]?.target == messageID {
            // Read within the grace: it never shows as unread, and neither
            // does anything older than it.
            dropHeldUnread(sessionID)
            if var next = unreadStates[sessionID], next.unreadOutputs > 0 { next.unreadOutputs = 0; next.unreadTargetID = nil; saveReadState(next) }
            return
        }
        guard var next = unreadStates[sessionID], next.unreadOutputs > 0, next.unreadTargetID == messageID else { return }
        next.unreadOutputs = 0; next.unreadTargetID = nil
        saveReadState(next)
    }

    /// The Dock badge counts chats with unread replies, one per chat however
    /// many replies each holds. A chat whose run failed, and an archived chat,
    /// never count here. Archived chats also hide their sidebar marks.
    func updateDockBadge() {
        PerformanceProbe.shared.count("dockBadgeRecomputations")
        let total = sidebarReadCounts.dockChats
        let label = total > 0 ? String(total) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// An explicit sidebar action can dismiss a reply abandoned by an edit.
    /// Automatic acknowledgements still require the exact visible target above.
    func markSessionRead(_ sessionID: String) {
        dropHeldUnread(sessionID)
        guard record(sessionID) != nil, var next = unreadStates[sessionID], next.isUnread || next.unreadFailure == true else { return }
        next.unreadOutputs = 0; next.unreadTargetID = nil; next.unreadFailure = nil; next.markedUnread = nil
        saveReadState(next)
    }

    private func saveReadState(_ value: SessionReadState) {
        guard unreadStates[value.id] != value else { return }
        var value = value
        value.revision = max((unreadStates[value.id]?.revision ?? 0) + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        unreadStates[value.id] = value
        updateDockBadge()
        guard !isEphemeral(value.id), store != nil else { return }
        dirtyReadStates.insert(value.id)
        scheduleReadStateWrite(value.id)
    }

    private func scheduleReadStateWrite(_ id: String) {
        guard readStateWrites[id] == nil else { return }
        readStateWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.readStateWrites[id] = nil }
            while self.dirtyReadStates.contains(id) { if !(await self.persistReadState(id)) { break } }
        }
    }

    @discardableResult private func persistReadState(_ id: String) async -> Bool {
        guard let store, let value = unreadStates[id], !isEphemeral(id) else { dirtyReadStates.remove(id); return true }
        do {
            try await store.put(value, kind: "session-read", id: id, revision: value.revision)
            if unreadStates[id]?.revision == value.revision { dirtyReadStates.remove(id) }
            return true
        } catch {
            self.error = "Unread state could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// Kept sides acquire durable read state along with their chat record.
    func retainSideReadState(_ id: String) async {
        guard unreadStates[id] != nil else { return }
        dirtyReadStates.insert(id); await persistReadState(id)
    }

    func forgetReadState(_ id: String) {
        dropHeldUnread(id)
        guard unreadStates.removeValue(forKey: id) != nil else { dirtyReadStates.remove(id); return }
        dirtyReadStates.remove(id)
        // The Dock counted this chat; it must stop.
        updateDockBadge()
    }

    @discardableResult func flushReadStates(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var retried: Set<String> = []
        while !dirtyReadStates.isEmpty || !readStateWrites.isEmpty {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            // Retry failed writes once; do not await a store actor that may be
            // blocked behind unrelated writes. Quit/install cleanup stays bounded.
            for id in dirtyReadStates where readStateWrites[id] == nil && retried.insert(id).inserted { scheduleReadStateWrite(id) }
            if readStateWrites.isEmpty { return dirtyReadStates.isEmpty }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }
}
