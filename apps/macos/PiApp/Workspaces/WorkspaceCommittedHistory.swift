import Foundation

extension WorkspaceModel {
    /// The helper remains display authority. Two small metadata replies fence
    /// the file read; the page never imports retained state into the live run.
    func readCommittedHistory(_ item: ChatRecord, host: HostSupervisor, cursor: ConversationCursor?, newer: Bool,
                              around: String?, start: Bool, position: Int?, validating: ConversationCursor?, opening: Bool,
                              handoff: inout ConversationCursor?) async throws -> ConversationHistoryPage? {
        guard host.supportsCommittedHistory, let path = item.path, !isEphemeral(item.id) else { return nil }
        // Latest-page reads retain the helper's live snapshot attachment and
        // its already loaded tail. The file serves explicit history navigation.
        if !start, cursor == nil, around == nil, position == nil { return nil }
        // A helper cursor does not identify the file its ordinals came from.
        // Let that helper validate a numeric request; entry-based reads can
        // hand over after the journal's stable-entry and lineage checks.
        if position != nil, let held = cursor ?? validating, !held.incarnation.hasPrefix("file:") { return nil }
        let connection = host.connectionID
        func source() async throws -> CommittedHistorySource? {
            let result = try await host.request("session.history.source", sessionID: item.id, params: ["version": .number(1)])
            guard result != .null else { return nil }
            guard let value = try? JSONDecoder().decode(CommittedHistorySource.self, from: JSONEncoder().encode(result)),
                  value.valid, value.sessionID == item.id, value.path == path else { return nil }
            return value
        }
        guard let captured = try await source() else { return nil }
        let page: HistoryPage
        do {
            page = try await history.window(path: path, cursor: cursor, newer: newer, around: around, start: start,
                                             position: position, validating: validating, limits: opening ? TranscriptPaging.pageLimits.opening : nil,
                                             source: captured)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A file that changed under the read is not published. The helper
            // validates the same stable entry on the compatibility path.
            return nil
        }
        if let position, !page.messages.isEmpty {
            // Carry the requested row even if the page starts earlier in its
            // turn. The helper's live byte weight can change before handoff.
            let entry: String
            if let held = cursor ?? validating, held.incarnation != captured.incarnation {
                // The file reader already rebound a replacement to this entry.
                entry = held.entry
            } else {
                let at = max(0, min(position, captured.total - 1)) - (page.start ?? 0)
                guard page.messages.indices.contains(at) else { throw HostError.failure("The history target changed while reading. Reload to reanchor it.") }
                entry = page.messages[at].id
            }
            handoff = .init(incarnation: captured.incarnation, lineage: captured.lineage, entry: entry)
        }
        guard let end = page.start.map({ $0 + page.messages.count }), end <= (captured.liveTail?.position ?? captured.total) else { return nil }
        guard let current = try await source(), current.validates(captured, through: end),
              connection == host.connectionID, hosts[item.workspaceID] === host, opened.contains(item.id) else {
            throw HostError.failure("History changed while reading. Reload to reanchor it.")
        }
        try await history.validateCommittedSource(captured)
        try Task.checkCancellation()
        var result = try ConversationHistoryPage(page)
        result.fromJournal = false; result.retainedRun = nil; result.failure = nil; result.failureCode = nil
        result.revision = nil; result.assistantCount = nil; result.latestAssistantID = nil
        return result
    }
}
