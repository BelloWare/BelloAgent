import Foundation

extension AgentSession {
    /// Captured synchronously on the session actor. Never triggers the older
    /// history replay; a checkpoint-backed chat already knows these facts.
    func committedHistorySource() throws -> CommittedHistorySource? {
        guard !closed, !ephemeral, let journal, !journal.writeOutcomeUncertain,
              !receivingAgentMessage else { return nil }
        // A commit can survive a failed projection. Recovery owns completing
        // it; a file reader may never publish the prefix between those writes.
        if let cuts = subagents.cuts {
            for commit in cuts.commits.values where commit["recipientSessionId"].text == id {
                guard let prepared = cuts.preparations[commit["cutId"].text ?? ""],
                      prepared["rows"].list.allSatisfy({ cuts.projected[$0["id"].text ?? ""] != nil }) else { return nil }
            }
        }
        // Legacy accepted-plan cards can be enriched from the owner's live
        // family even without nativeSubagent in the result. Keep their source.
        guard !subagents.plans.values.contains(where: { $0.origin.taskName == nil }) else { return nil }
        // A failed terminal write can outlive partialLedgerID. Keep every
        // in-memory-only replacement behind the helper boundary until saved.
        var live = Set(toolStateOwners.values).union(historyNonDurablePresentations)
        for entry in [activeTaskPresentation?.rootID, partialLedgerID, compactionPresentationID].compactMap({ $0 }) { live.insert(entry) }
        let base = olderIndex?.shown ?? olderRows
        var tail: CommittedHistorySource.Tail?
        if !live.isEmpty {
            guard let at = visible.firstIndex(where: { live.contains($0.id) }) else { return nil }
            tail = .init(entry: visible[at].id, position: base + at)
        } else if partialID != nil || runTask != nil {
            // A legacy run without typed task metadata is confined to its
            // latest display turn; if its start is unloaded, use the helper.
            guard let at = visible.lastIndex(where: { HistoryWindowPolicy.startsTurn(role: $0.role, kind: $0.kind, agentDelivery: $0.nativeAgentDelivery != nil) }) else { return nil }
            tail = .init(entry: visible[at].id, position: base + at)
        }
        return try journal.historySource(sessionID: id, lineage: presentationTimeline, runtime: displayEpoch,
                                         presentationRevision: historyPresentationRevision, total: base + visible.count, liveTail: tail,
                                         availableFrom: olderIndex == nil ? olderRows : 0)
    }
}
