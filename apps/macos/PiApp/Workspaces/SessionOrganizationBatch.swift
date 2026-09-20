import Foundation

/// Overlapping mutations wait only for the same session IDs. No application-wide
/// lock, and no suspension while registering the intent from a click.
@MainActor final class SessionOrganizationScheduler {
    private var tails: [String: (UUID, Task<Void, Never>)] = [:]
    var inFlight: Bool { !tails.isEmpty }

    func enqueue<T: Sendable>(ids: Set<String>, operation: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let token = UUID()
        var seen: Set<UUID> = []
        let predecessors = ids.compactMap { tails[$0] }.filter { seen.insert($0.0).inserted }.map(\.1)
        let task = Task { @MainActor in
            for predecessor in predecessors { await predecessor.value }
            defer { for id in ids where self.tails[id]?.0 == token { self.tails[id] = nil } }
            return try await operation()
        }
        let completion = Task { _ = try? await task.value }
        for id in ids { tails[id] = (token, completion) }
        return task
    }
}

extension WorkspaceModel {
    /// Captures navigation before awaiting persistence. A user's subsequent
    /// selection, side focus or page change owns focus, even if they return.
    func enqueueOrganization(_ ids: [String], change: ChatOrganizationChange) -> Task<ChatOrganizationBatch, Error> {
        let started = PerformanceProbe.now
        let selected = selectedID, focused = focusedSessionID
        let navigation = organizationNavigationRevision, selection = selectionRevision
        var seen: Set<String> = []
        let targets = ids.filter { seen.insert($0).inserted }
        let task = organizationScheduler.enqueue(ids: Set(targets)) { [self] in
            guard !installPreparing, !accountingStopped else { throw HostError.failure("Wait for the app update to finish before changing a chat.") }
            guard !targets.isEmpty, targets.count <= Self.markedSessionLimit, let store else { throw StoreError.invalidRecord }
            var existing: [String] = []
            for id in targets where record(id) != nil {
                // Pending chats retain their existing materialization/draft contract.
                // Ordinary saved targets incur no additional transaction/publication.
                if pendingChatIDs.contains(id) { try await materializeChat(id) }
                if record(id) != nil { existing.append(id) }
            }
            guard !existing.isEmpty else { return ChatOrganizationBatch() }
            if case .archived(true) = change { stopForArchive(existing) }
            let wait = PerformanceProbe.now
            let result: ChatOrganizationBatch
            if let organizationWrite { result = try await organizationWrite(existing, change) }
            else { result = try await store.updateChatOrganizations(ids: existing, change: change) }
            PerformanceProbe.shared.observe("organizationStoreWaitMs", milliseconds: PerformanceProbe.now - wait)
            PerformanceProbe.shared.observe("organizationTransactionMs", milliseconds: result.transactionMilliseconds)
            let patched = applyOrganizationBatch(result.records)
            PerformanceProbe.shared.observe("organizationChangedIDs", milliseconds: Double(patched.count))
            if case .archived = change, !patched.isEmpty { updateDockBadge() }
            // This uses committed/current records, never the originally marked
            // set: rejected targets remain candidates and deleted IDs stay absent.
            if organizationNavigationRevision == navigation, selectionRevision == selection,
               selectedID == selected, focusedSessionID == focused {
                switch change {
                case .archived(true):
                    if let selected, patched.contains(selected), let item = record(selected), item.isArchived,
                       let next = sidebarChats(in: item.workspaceID, archived: false, excluding: [selected]).first {
                        // With no active chat, preserve the old final fallback:
                        // the archived chat remains open without switching filters.
                        await select(next.id)
                    }
                case .archived(false):
                    if let id = focused ?? selected, patched.contains(id), let item = record(id), !item.isArchived { revealProjectChat(item) }
                default: break
                }
            }
            return result
        }
        PerformanceProbe.shared.observe("organizationClickFeedbackMs", milliseconds: PerformanceProbe.now - started)
        return task
    }

    /// One publication, rebased onto today's records. Unrelated journal, model,
    /// title-job and parent changes must survive an older store callback.
    @discardableResult func applyOrganizationBatch(_ saved: [ChatRecord], adding additions: [ChatRecord] = []) -> Set<String> {
        let start = PerformanceProbe.now
        let patches = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var next = chats, changed: Set<String> = []
        for index in next.indices {
            guard let patch = patches[next[index].id], (patch.organizationRevision ?? 0) >= (next[index].organizationRevision ?? 0) else { continue }
            let before = next[index]
            next[index].applyOrganization(from: patch)
            if next[index] != before { changed.insert(before.id) }
        }
        for chat in additions where !next.contains(where: { $0.id == chat.id }) { next.append(chat); changed.insert(chat.id) }
        if !changed.isEmpty {
            organizationPresentationRevision &+= 1
            chats = next
            PerformanceProbe.shared.observe("organizationChatPublications", milliseconds: 1)
            var nextSides = sides, sidesChanged = false
            for (parent, info) in sides where changed.contains(info.id) {
                guard let current = record(info.id) else { continue }
                if info.title != current.title || info.topicID != current.topicID {
                    nextSides[parent]?.title = current.title; nextSides[parent]?.topicID = current.topicID; sidesChanged = true
                }
            }
            if sidesChanged { sides = nextSides }
        }
        PerformanceProbe.shared.observe("organizationPatchMs", milliseconds: PerformanceProbe.now - start)
        return changed
    }

    /// Stop acknowledgements are not SQLite work and do not delay the batch or
    /// UI input. Four workers bound admissions across every project/helper.
    private func stopForArchive(_ ids: [String]) {
        let targets = ids.compactMap { id -> (String, SessionDisplay, HostSupervisor)? in
            guard let view = displays[id], view.busy, opened.contains(id), let item = record(id), let host = hosts[item.workspaceID] else { return nil }
            view.state = "stopping"
            return (id, view, host)
        }
        guard !targets.isEmpty else { return }
        archiveStopQueue.append(contentsOf: targets)
        for _ in 0..<min(4 - archiveStopWorkers, archiveStopQueue.count) {
            archiveStopWorkers += 1
            Task { [self] in
                defer { archiveStopWorkers -= 1 }
                while !archiveStopQueue.isEmpty {
                    let (id, view, host) = archiveStopQueue.removeFirst()
                    guard !accountingStopped else { archiveStopQueue.removeAll(); return }
                    do { _ = try await host.request("turn.stop", sessionID: id); refresh(id) }
                    catch {
                        guard displays[id] === view else { continue }
                        view.state = "interrupted"; view.uncertain = true; view.notice = error.localizedDescription
                    }
                }
            }
        }
    }
}
