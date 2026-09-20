import Foundation

/// Reduce the old ordered archive policy without opening any of its intermediate
/// panes. If every active chat is archived, the last destination stays open,
/// still in the active sidebar filter. One sort and one forward cursor suffice.
enum SessionOrganizationSelection {
    static func afterArchive(selected: String, targets: [String], archived: Set<String>, records: [ChatRecord], includeBackground: Bool) -> String {
        guard archived.contains(selected), let project = records.first(where: { $0.id == selected })?.workspaceID else { return selected }
        let candidates = records.filter { $0.workspaceID == project && (!$0.isArchived || archived.contains($0.id)) && (!$0.isBackgroundTask || includeBackground) }
            .sorted(by: ChatRecord.sidebarPrecedes)
        var available = Set(candidates.map(\.id)), cursor = 0, destination = selected
        for id in targets where archived.contains(id) {
            available.remove(id)
            guard destination == id else { continue }
            while cursor < candidates.count, !available.contains(candidates[cursor].id) { cursor += 1 }
            if cursor < candidates.count { destination = candidates[cursor].id }
        }
        return destination
    }
}

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
            if case .archived(false) = change {
                // A later restore supersedes stop commands not yet admitted to
                // a helper. It cannot undo a stop already dispatched.
                for id in existing { archiveStopRevisions[id, default: 0] += 1 }
            }
            let wait = PerformanceProbe.now
            let result: ChatOrganizationBatch
            if let organizationWrite { result = try await organizationWrite(existing, change) }
            else { result = try await store.updateChatOrganizations(ids: existing, change: change) }
            PerformanceProbe.shared.observe("organizationStoreWaitMs", milliseconds: PerformanceProbe.now - wait)
            PerformanceProbe.shared.count("organizationCommits")
            PerformanceProbe.shared.observe("organizationTransactionMs", milliseconds: result.transactionMilliseconds)
            let patched = applyOrganizationBatch(result.records)
            PerformanceProbe.shared.count("organizationChangedIDs", by: patched.count)
            if case .archived = change, !patched.isEmpty { updateDockBadge() }
            // This uses committed/current records, never the originally marked
            // set: rejected targets remain candidates and deleted IDs stay absent.
            if organizationNavigationRevision == navigation, selectionRevision == selection,
               selectedID == selected, focusedSessionID == focused {
                switch change {
                case .archived(true):
                    if let selected {
                        let destination = SessionOrganizationSelection.afterArchive(selected: selected, targets: targets,
                            archived: patched, records: chats, includeBackground: showBackgroundSessions)
                        if destination != selected, let item = record(destination) {
                            await select(destination, preserveArchiveFilter: item.isArchived)
                        }
                    }
                case .archived(false):
                    if let item = [focused, selected].compactMap({ $0 }).filter({ patched.contains($0) }).compactMap({ record($0) }).first(where: { !$0.isArchived }) { revealProjectChat(item) }
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
            PerformanceProbe.shared.count("organizationChatPublications")
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
        let targets = ids.compactMap { id -> (String, Int, SessionDisplay, HostSupervisor)? in
            guard let view = displays[id], view.busy, opened.contains(id), let item = record(id), let host = hosts[item.workspaceID] else { return nil }
            archiveStopRevisions[id, default: 0] += 1
            return (id, archiveStopRevisions[id]!, view, host)
        }
        guard !targets.isEmpty else { return }
        archiveStopQueue.append(contentsOf: targets)
        for _ in 0..<min(4 - archiveStopWorkers, archiveStopQueue.count) {
            archiveStopWorkers += 1
            Task { [self] in
                defer { archiveStopWorkers -= 1 }
                while !archiveStopQueue.isEmpty {
                    let (id, revision, view, host) = archiveStopQueue.removeFirst()
                    guard !accountingStopped else { archiveStopQueue.removeAll(); return }
                    guard archiveStopRevisions[id] == revision, displays[id] === view, record(id) != nil else { continue }
                    view.state = "stopping"
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
