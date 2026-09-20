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
    var revision: Int64 = 0
}

extension WorkspaceModel {
    var unreadCount: Int { unreadStates.keys.filter { unreadOutputCount(sessionID: $0) > 0 }.count }
    func unreadOutputCount(sessionID: String) -> Int {
        guard let item = record(sessionID), item.connectionTest != true, !item.isArchived else { return 0 }
        return unreadStates[sessionID]?.unreadOutputs ?? 0
    }
    /// Whether a collapsed group has to show its dot. Driven from the unread
    /// states, which are few, rather than from every chat of the project.
    func projectHasUnread(_ projectID: String) -> Bool {
        unreadStates.contains { id, state in
            (state.unreadOutputs > 0 || state.unreadFailure == true) && record(id).map { $0.workspaceID == projectID && $0.connectionTest != true && !$0.isArchived } == true
        }
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
        updateDockBadge()
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
        // A reply is unread only once the run has finished and reported back.
        // Tool-round messages appended mid-run wait for the idle snapshot, so
        // neither the sidebar dot nor the Dock badge appears while work continues.
        if let state = snapshot["state"]?.string, ["queued", "running", "stopping", "compacting"].contains(state), unreadStates[sessionID] != nil { return }
        let count = Int(rawCount)
        var next = unreadStates[sessionID] ?? SessionReadState(id: sessionID, observedAssistantCount: count, latestAssistantID: latest)
        if count > next.observedAssistantCount, let latest, latest != next.latestAssistantID {
            next.unreadOutputs = min(100_000, next.unreadOutputs + count - next.observedAssistantCount)
            next.unreadTargetID = latest
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
              !message.isStreaming,
              var next = unreadStates[sessionID], next.unreadOutputs > 0, next.unreadTargetID == messageID else { return }
        next.unreadOutputs = 0; next.unreadTargetID = nil
        saveReadState(next)
    }

    /// The Dock badge counts chats with unread replies, one per chat however
    /// many replies each holds. A chat whose run failed, and an archived chat,
    /// never count here. Archived chats also hide their sidebar marks.
    func updateDockBadge() {
        let total = unreadStates.values.filter { state in
            guard state.unreadOutputs > 0, state.unreadFailure != true, let item = record(state.id), item.connectionTest != true, !item.isArchived else { return false }
            return true
        }.count
        let label = total > 0 ? String(total) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// An explicit sidebar action can dismiss a reply abandoned by an edit.
    /// Automatic acknowledgements still require the exact visible target above.
    func markSessionRead(_ sessionID: String) {
        guard record(sessionID) != nil, var next = unreadStates[sessionID], next.unreadOutputs > 0 || next.unreadFailure == true else { return }
        next.unreadOutputs = 0; next.unreadTargetID = nil; next.unreadFailure = nil
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
        unreadStates[id] = nil; dirtyReadStates.remove(id)
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
