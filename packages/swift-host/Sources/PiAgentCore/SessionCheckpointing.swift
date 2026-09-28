import Foundation

// Opening a chat from its journal's metadata file (`JournalCheckpoint`):
// what a checkpoint records while the journal is replayed, and loading the
// rows it names. Static: the synchronous initializer calls them.

extension AgentSession {
    /// A checkpoint just after the record `lastLine`, which set the model
    /// context (a compaction, an edit or a fork boundary). nil when some row
    /// it would name has no known place in the journal: the next open then
    /// replays the whole journal, as every open did before.
    static func checkpoint(sessionID: String, header: JournalCheckpoint.Check?, marker: JournalCheckpoint.Check?,
                           last lastLine: Data, at lastOffset: UInt64, lastID: String,
                           visible: [ChatMessage], context: [ChatMessage], spans: [String: JournalCheckpoint.Row],
                           state: (line: Data, offset: UInt64, key: String)?, assistantMessageCount: Int, latestAssistantMessageID: String?,
                           versions: MessageVersionLedger, tasks: [TaskPresentationRecord], helper: JSON) -> JournalCheckpoint? {
        guard let header, let marker, !context.isEmpty else { return nil }
        // The rows shown from the context's first one on: the context is
        // mostly the latest rows, so look for it from the end.
        var remaining = Set(context.map(\.id)), first = visible.count
        while first > 0, !remaining.isEmpty { first -= 1; remaining.remove(visible[first].id) }
        guard remaining.isEmpty else { return nil }
        var rows: [JournalCheckpoint.Row] = []
        rows.reserveCapacity(visible.count - first)
        for message in visible[first...] {
            guard let span = spans[message.id] else { return nil }
            rows.append(span)
        }
        let stateCheck = state.map { JournalCheckpoint.Check(offset: $0.offset, length: $0.line.count, sha256: JournalCheckpoint.digest($0.line)) }
        return JournalCheckpoint(sessionID: sessionID, header: header, marker: marker,
                                 last: .init(offset: lastOffset, length: lastLine.count, sha256: JournalCheckpoint.digest(lastLine)), lastID: lastID,
                                 rows: rows, rowsBefore: first, context: context.map(\.id), lineage: visible.last(where: { $0.kind == "branch" })?.id,
                                 state: stateCheck, stateKey: state?.key,
                                 assistantMessageCount: assistantMessageCount, latestAssistantMessageID: latestAssistantMessageID,
                                 versions: versions, tasks: tasks, helper: helper.encoded())
    }

    /// The rows and context a checkpoint names, and the run state it points
    /// at, read from the journal; nil when any record is not what it recorded.
    static func loadCheckpoint(_ checkpoint: JournalCheckpoint, url: URL) -> (rows: [ChatMessage], context: [ChatMessage], state: JSON?, stateLine: Data?)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var rows: [ChatMessage] = []
        rows.reserveCapacity(checkpoint.rows.count)
        for row in checkpoint.rows {
            guard let bytes = JournalCheckpoint.rowBytes(row, in: file), let record = try? JSON.parse(bytes) else { return nil }
            switch row.kind {
            case .message:
                guard record["type"].text == "message", record["id"].text == row.id, let message = try? ChatMessage(id: row.id, pi: record["message"]) else { return nil }
                rows.append(message)
            case .update:
                guard record["customType"].text == "pi-app.presentation.update.v1", record["data"]["id"].text == row.id,
                      var message = try? ChatMessage(id: row.id, pi: record["message"]) else { return nil }
                message.replayEligible = false
                rows.append(message)
            case .compaction:
                guard record["type"].text == "compaction", record["id"].text == row.id, let summary = try? CompactionCheckpoint.summary(record) else { return nil }
                rows.append(summary)
            case .branch:
                guard record["type"].text == "branch", record["id"].text == row.id else { return nil }
                rows.append(branchMarker(row.id))
            }
        }
        // A compaction record adopts its progress row, as the replay does,
        // unless that row was replaced after it.
        for (index, row) in checkpoint.rows.enumerated() where row.kind == .compaction {
            guard let operation = rows[index].operationID,
                  let position = rows.firstIndex(where: { $0.kind == "execution" && $0.operationID == operation }),
                  checkpoint.rows[position].offset < row.offset else { continue }
            rows[position].responseTimeline?.finish("completed"); rows[position].detail = "Compaction · Checkpoint durably adopted"
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let context = checkpoint.context.compactMap { byID[$0] }
        guard context.count == checkpoint.context.count else { return nil }
        var state: JSON?, stateLine: Data?
        if let check = checkpoint.state {
            guard let key = checkpoint.stateKey, let line = JournalCheckpoint.verified(check, in: file), let record = try? JSON.parse(line) else { return nil }
            state = record[key]; stateLine = line
        }
        return (rows, context, state, stateLine)
    }

    /// Loads every row a chat opened from its metadata file left in the
    /// journal (shown rows before the loaded ones, and earlier versions an
    /// edit hid): the whole journal replayed, as a full open does. The model
    /// context, the queue and the run stay the live ones; the rows, their
    /// versions, and the links and task records they carry come from the
    /// journal, which holds every record this chat has written. A row loaded
    /// already keeps its live content.
    func ensureFullHistory() throws {
        guard partialHistory, let journal else { return }
        let replayed = try Self.replay(journal, url: journal.url, id: id, binding: profile.binding, spendTracked: spendTracked, resume: false)
        let live = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        history = replayed.history.map { live[$0.id] ?? $0 }
        visible = replayed.visible.map { live[$0.id] ?? $0 }
        versions = replayed.versions
        pendingRequestLinks = replayed.pendingRequestLinks
        rowSpans = replayed.rowSpans
        let liveTasks = Dictionary(recentTaskPresentations.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        var tasks = replayed.recentTaskPresentations.map { liveTasks[$0.key] ?? $0 }
        for task in recentTaskPresentations where !tasks.contains(where: { $0.key == task.key }) { tasks.append(task) }
        let shown = Set(visible.map(\.id))
        tasks.removeAll { $0.lastSourceID.map { !shown.contains($0) } ?? true }
        if tasks.count > 64 { tasks.removeFirst(tasks.count - 64) }
        recentTaskPresentations = tasks
        toolHistory = ToolHistoryIndex(history)
        olderRows = 0; partialHistory = false; checkpointLineage = nil; cachedPresentationTimeline = nil
        spansScannedTo = journal.size
        invalidateDisplay(allRows: true)
    }

    /// Writes the metadata file for a chat that just set its model context
    /// (a compaction or an edit), so the next open resumes after it. The
    /// records appended since the journal was last read are read for where
    /// their rows are; the context-setting record is the last of them.
    /// Nothing here can fail the chat: the file is only ever a shortcut.
    func refreshCheckpoint() {
        guard let journal, !ephemeral, let reader = try? JournalRecordReader(journal.url, expectedBytes: journal.size, startingAt: spansScannedTo) else { return }
        var last: (line: Data, offset: UInt64, id: String)?
        do {
            while true {
                let start = reader.completeBytes
                guard let line = try reader.nextLine() else { break }
                if line.isEmpty { continue }
                if line.starts(with: JournalLineScan.statePrefix) {
                    liveStateSource = StateSource(line: line, offset: start, key: "data")
                    if let id = JournalLineScan.stateTail(line)?.id { last = (line, start, id) }
                    continue
                }
                let item = try JSON.parse(line)
                guard let id = item["id"].text else { continue }
                last = (line, start, id)
                switch (item["type"].text, item["customType"].text) {
                case ("message", _): rowSpans[id] = .init(id: id, kind: .message, offset: start, length: line.count)
                case ("compaction", _): rowSpans[id] = .init(id: id, kind: .compaction, offset: start, length: line.count)
                case ("branch", _):
                    rowSpans[id] = .init(id: id, kind: .branch, offset: start, length: line.count)
                    if !item["nativeState"].isNull { liveStateSource = StateSource(line: line, offset: start, key: "nativeState") }
                case (_, "pi-app.presentation.update.v1"):
                    if let target = item["data"]["id"].text, history.contains(where: { $0.id == target && ["execution", "requestLedger"].contains($0.kind ?? "") }) {
                        rowSpans[target] = .init(id: target, kind: .update, offset: start, length: line.count)
                    }
                case (_, "pi-app.native.state.v1"): liveStateSource = StateSource(line: line, offset: start, key: "data")
                default: break
                }
            }
        } catch { return }
        spansScannedTo = reader.completeBytes
        guard let last else { return }
        let helper: JSON = ["spend": spend.record, "spendTracked": JSON(spendTracked), "failedCompactionFingerprint": failedCompactionFingerprint.map { JSON($0) } ?? .null,
                            "contextRecovery": contextRecovery, "compactionState": compactionState, "parentInfo": parentInfo, "presentationOrdinal": JSON(presentationOrdinal)]
        let state = liveStateSource.map { (line: $0.line, offset: $0.offset, key: $0.key) }
        guard var checkpoint = Self.checkpoint(sessionID: id, header: journal.headerCheck, marker: journal.markerCheck, last: last.line, at: last.offset, lastID: last.id,
                                               visible: visible, context: context, spans: rowSpans, state: state, assistantMessageCount: assistantMessageCount,
                                               latestAssistantMessageID: latestAssistantMessageID, versions: versions.ledger, tasks: recentTaskPresentations, helper: helper) else { return }
        // Rows a chat opened from its metadata file never loaded still count.
        checkpoint.rowsBefore += olderRows
        if checkpoint.lineage == nil { checkpoint.lineage = checkpointLineage }
        try? checkpoint.write(for: journal.url)
    }

    /// The highest presentation ordinal a row carries.
    static func maxOrdinal(_ message: ChatMessage) -> Int {
        message.responseTimeline?.segments.map { $0.part.sessionOrdinal ?? $0.part.ordinal }.max() ?? 0
    }
}
