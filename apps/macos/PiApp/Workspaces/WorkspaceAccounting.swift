import Foundation

extension WorkspaceModel {
    /// Metadata updates, not body chunks, invalidate compact accounting. One
    /// task per session coalesces streaming metadata and late final billing.
    func captureDidPersist(_ packet: [String: WireValue], workspaceID: String) {
        guard !accountingStopped, let type = packet["type"]?.string, ["begin", "metadata", "finish", "links", "interrupted"].contains(type) else { return }
        if let id = packet["metadata"]?.object?["sessionId"]?.string,
           record(id)?.workspaceID == workspaceID {
            scheduleAccounting(id, workspaceID: workspaceID)
        } else if type == "links" || type == "interrupted" {
            for id in displays.keys where record(id)?.workspaceID == workspaceID {
                scheduleAccounting(id, workspaceID: workspaceID)
            }
        }
    }

    private func scheduleAccounting(_ id: String, workspaceID: String) {
        dirtyAccounting.insert(id)
        guard accountingTasks[id] == nil else { return }
        accountingTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            defer { accountingTasks.removeValue(forKey: id) }
            while !Task.isCancelled, dirtyAccounting.remove(id) != nil {
                guard record(id)?.workspaceID == workspaceID else { break }
                if let view = displays[id] { await refreshAccounting(view, workspaceID: workspaceID) }
                else {
                    let revision = beginChatStatsQuery(id)
                    if let value = try? await traces.gatewayAccounting(sessionID: id, workspaceID: workspaceID, messages: []),
                       !Task.isCancelled, record(id)?.workspaceID == workspaceID {
                        publishChatStats(value.session, sessionID: id, revision: revision)
                    }
                }
                if dirtyAccounting.contains(id) { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    func refreshRetainedAccounting() async {
        for view in displays.values {
            if let workspaceID = record(view.id)?.workspaceID { await refreshAccounting(view, workspaceID: workspaceID) }
        }
        await refreshChatStats()
    }

    /// All project groups remain visible, so restore retained totals without
    /// loading their hosts. Publish each result promptly and reject an older
    /// query if a late capture or loaded display has already superseded it.
    func refreshChatStats(query: (@MainActor (ChatRecord) async throws -> GatewayTotals)? = nil) async {
        chatStatsRevision += 1
        let batch = chatStatsRevision
        let records = chats.filter { displays[$0.id] == nil }
        guard !records.isEmpty else { return }
        if query == nil {
            // One grouped read for every chat; chats with no retained attempts
            // publish empty totals so stale figures never linger.
            let revisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, beginChatStatsQuery($0.id)) })
            guard let totals = try? await traces.allSessionTotals(), !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
            for chat in records where record(chat.id)?.workspaceID == chat.workspaceID && displays[chat.id] == nil {
                publishChatStats(totals[chat.workspaceID + "\u{0}" + chat.id] ?? GatewayTotals(), sessionID: chat.id, revision: revisions[chat.id])
            }
            return
        }
        for chat in records {
            guard !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
            if displays[chat.id] != nil { continue }
            let revision = beginChatStatsQuery(chat.id)
            do {
                let totals = try await query!(chat)
                guard !Task.isCancelled, !accountingStopped, batch == chatStatsRevision else { return }
                if record(chat.id)?.workspaceID == chat.workspaceID, displays[chat.id] == nil {
                    publishChatStats(totals, sessionID: chat.id, revision: revision)
                }
            } catch { /* Keep the last observed totals while storage is unavailable. */ }
        }
    }

    private func beginChatStatsQuery(_ id: String) -> Int {
        let revision = (chatStatsVersions[id] ?? 0) + 1
        chatStatsVersions[id] = revision
        return revision
    }

    func publishChatStats(_ totals: GatewayTotals, sessionID id: String, revision: Int? = nil) {
        if let revision {
            guard chatStatsVersions[id] == revision else { return }
        } else { _ = beginChatStatsQuery(id) }
        if chatStats[id] != totals { chatStats[id] = totals }
    }

    func refreshAccounting(_ view: SessionDisplay, workspaceID: String, query: (@MainActor () async throws -> SessionGatewayAccounting)? = nil) async {
        view.accountingRevision += 1
        let revision = view.accountingRevision
        let totalsRevision = beginChatStatsQuery(view.id)
        let requestedIDs = view.messages.map(\.id)
        do {
            let value: SessionGatewayAccounting
            if let query { value = try await query() }
            else { value = try await traces.gatewayAccounting(sessionID: view.id, workspaceID: workspaceID, messages: view.messages, includeTiming: true) }
            guard !Task.isCancelled, view.accountingRevision == revision else { return }
            if view.footer.gateway != value.session { view.footer.gateway = value.session }
            if let timing = value.timing, view.footer.timing != timing { view.footer.timing = timing }
            publishChatStats(value.session, sessionID: view.id, revision: totalsRevision)
            if !view.footer.gatewayNotice.isEmpty { view.footer.gatewayNotice = "" }
            // A streamed message/page change must not discard session billing.
            // Only per-message attribution depends on the requested projection.
            guard view.messages.map(\.id) == requestedIDs else { return }
            view.messageAccounting = value.messages
            var messages = view.messages
            for index in messages.indices { messages[index].accounting = value.messages[messages[index].id] }
            // Accounting doesn't invalidate the helper's content revision.
            let revision = view.projectionRevision
            if view.messages != messages { view.messages = messages; view.projectionRevision = revision }
        } catch {
            guard !Task.isCancelled, view.accountingRevision == revision else { return }
            view.footer.gatewayNotice = "Retained cost/cache metrics unavailable"
        }
    }
}
