import Foundation

/// The real inputs a validated historical plan replays, and the latest shown
/// rows that go with them. Earlier display rows and hidden versions stay in
/// the journal, as when opening from a checkpoint; their readers load them.
struct EditAdoption: Sendable {
    var history: [ChatMessage], visible: [ChatMessage], context: [ChatMessage]
    var spans: [String: JournalCheckpoint.Row]
    var olderRows: Int
    var lineage: String?
    var ledger: MessageVersionLedger
    var links: [String: [String]]
    var tasks: [TaskPresentationRecord]
    var covered: UInt64
}

extension EditPreparationIndex {
    func adoption(_ plan: HistoricalEditPlan, url: URL, live: [ChatMessage], liveTasks: [TaskPresentationRecord]) throws -> EditAdoption {
        let replayIDs = Set(plan.replay), shown = Set(plan.displayPrefix)
        let timeline = plan.displayPrefix + plan.replay.filter { !shown.contains($0) }
        let first = timeline.firstIndex { replayIDs.contains($0) } ?? timeline.count
        let retained = Array(timeline.dropFirst(first)), wanted = Set(retained).union(replayIDs)
        let live = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let file = try openSource(url); defer { try? file.close() }
        var loaded: [String: ChatMessage] = [:], spans: [String: JournalCheckpoint.Row] = [:]
        for id in wanted {
            try Task.checkCancellation()
            guard let recorded = replay.rowSpans[id] else {
                throw AgentError("edit_target", "A required historical input is not retained.")
            }
            let span: JournalCheckpoint.Row
            if let stored = self.spans[id], stored.offset == recorded.offset { span = stored }
            else { span = recorded }
            spans[id] = span
            if let current = live[id] { loaded[id] = current }
            else {
                guard let message = AgentSession.journalRow(span, in: file) else { throw AgentError("edit_target", "A required historical input could not be read.") }
                loaded[id] = message
            }
        }
        // A checkpoint completed its own progress row; a live row, as in a
        // full-history adoption, keeps its current presentation instead.
        for message in loaded.values where message.kind == "compaction" {
            guard let operation = message.operationID,
                  let progress = loaded.values.first(where: { $0.kind == "execution" && $0.operationID == operation }), live[progress.id] == nil else { continue }
            var finished = progress; AgentSession.adoptCompactionProgress(&finished); loaded[finished.id] = finished
        }
        for id in loaded.keys where live[id] == nil {
            if var message = loaded[id] { _ = AgentSession.endWithoutReceipt(&message); loaded[id] = message }
        }
        let markers = Set(replay.history.lazy.filter { $0.kind == "branch" }.map(\.id))
        return EditAdoption(history: replay.history.compactMap { loaded[$0.id] }, visible: retained.compactMap { loaded[$0] },
                            context: plan.replay.compactMap { loaded[$0] }, spans: spans, olderRows: first,
                            lineage: timeline.prefix(first).last(where: markers.contains),
                            ledger: replay.versions.ledger, links: replay.pendingRequestLinks,
                            tasks: AgentSession.mergedTasks(replay.recentTaskPresentations, live: liveTasks, shown: Set(timeline)), covered: covered)
    }
}

extension AgentSession {
    func editAdoption(_ plan: HistoricalEditPlan) async throws -> EditAdoption? {
        guard partialHistory, let index = editPreparationIndex, let journal else { return nil }
        let url = journal.url, source = JournalSource(journal), head = journal.head, live = history, liveTasks = recentTaskPresentations
        let made = await Self.offActor(priority: .userInitiated) { () -> Result<EditAdoption, Error> in
            Result { try index.adoption(plan, url: url, live: live, liveTasks: liveTasks) }
        }
        try throwIfClosed(); try Task.checkCancellation()
        guard self.journal?.head == head, self.journal.flatMap(JournalSource.init) == source else { throw AgentError("edit_changed", "The conversation changed while preparing the edit. Select the message again.") }
        return try made.get()
    }

    /// Takes a sparse prefix only after its branch is durable. The queue,
    /// receipts, spend and the edit's model-context reset follow the ordinary
    /// branch path; reads of earlier display rows or versions remain lazy.
    func adoptEdit(_ adoption: EditAdoption, from messageID: String, markerID: String) {
        cancelHistoryFill()
        history = adoption.history; visible = adoption.visible; context = adoption.context
        let marker = Self.branchMarker(markerID); history.append(marker); visible.append(marker)
        versions = MessageVersionStore(); versions.ledger = adoption.ledger; versions.ledger.branched(from: messageID)
        rowSpans = adoption.spans; spansScannedTo = adoption.covered
        olderRows = adoption.olderRows; checkpointLineage = adoption.lineage; partialHistory = true; olderIndex = nil
        cachedPresentationTimeline = nil
        pendingRequestLinks = adoption.links; recentTaskPresentations = adoption.tasks
        toolHistory = ToolHistoryIndex(history)
        let old = durable; durable = nil; Discarded.release(old)
    }
}
