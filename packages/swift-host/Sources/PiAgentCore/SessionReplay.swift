import Foundation

/// What a chat's journal replays to: its rows and model context, and what its
/// records add up to. Opening a chat replays its journal this way, from its
/// metadata file's checkpoint when that still matches the journal
/// (`JournalCheckpoint`), and a chat opened from a checkpoint loads its older
/// rows the same way when something asks for them (`ensureFullHistory`).
struct JournalReplay: Sendable {
    var history: [ChatMessage] = [], visible: [ChatMessage] = [], context: [ChatMessage] = []
    var versions = MessageVersionStore()
    var spend = SessionSpend(), spendTracked = false
    var assistantMessageCount = 0, latestAssistantMessageID: String?
    var pendingRequestLinks: [String: [String]] = [:]
    var recentTaskPresentations: [TaskPresentationRecord] = []
    var compactionState: JSON = .null, contextRecovery: JSON = .null, failedCompactionFingerprint: String?, parentInfo: JSON = .null
    var presentationOrdinal = 0
    var rowSpans: [String: JournalCheckpoint.Row] = [:]
    /// Shown rows before the loaded ones, when resumed from a checkpoint.
    var olderRows = 0
    var stateRecord: JSON?
    /// The latest point the next open can resume from, if any.
    var captured: JournalCheckpoint?
    /// Whether this replay resumed from the metadata file's checkpoint.
    var resumed = false
    /// The newest run state's record: its bytes, where it is, and its key.
    var stateSource: StateSource?
    /// How much of the journal the records replayed so far take up, from its
    /// start: where the next record goes, once they are the whole journal.
    var coveredBytes: UInt64 = 0
}

/// A run-state record a checkpoint points at.
struct StateSource: Sendable {
    var line: Data
    var offset: UInt64
    var key: String
}

/// A journal's replay, one line at a time: what `AgentSession.replay` reads
/// from a journal, and what a fork feeds it as it writes one, so the fork's
/// state is the one its journal replays to without reading it again.
struct JournalReplayConsumer {
    private(set) var r = JournalReplay()
    private let id: String
    private let header: JournalCheckpoint.Check?, marker: JournalCheckpoint.Check?
    // The newest run state's record, for a checkpoint: its bytes, where it
    // is, and the key it holds the state under.
    private var stateSource: (line: Data, offset: UInt64, key: String)?
    // The latest point the next open can resume from, and the highest
    // presentation ordinal so far (`JournalCheckpoint`).
    private var ordinalMax = 0
    // The run state is written several times a turn and only the newest
    // counts; in a long chat those snapshots were most of the journal and
    // most of the time it took to open. Keep the newest one's line and
    // parse it once, at the end; a superseded one is not read at all. A
    // line of another shape is read as before.
    private var newestStateLine: Data?
    // The receipts: the newest record with the whole list, and the
    // records with changes only after it, read once at the end
    // (`CommandReceipts`). A checkpoint carries them as they stood there.
    private var receiptsBase = CommandReceipts.Base.none, receiptChanges: [Data] = []
    private var capturedReceipts: (base: CommandReceipts.Base, changes: [Data])?

    /// `header` and `marker` are the journal's, as a checkpoint names them;
    /// `spendTracked` is what a journal with no cost record counts as.
    init(id: String, header: JournalCheckpoint.Check?, marker: JournalCheckpoint.Check?, spendTracked: Bool) {
        self.id = id; self.header = header; self.marker = marker; r.spendTracked = spendTracked
    }

    /// Starts from the metadata file's checkpoint: the rows it names, then
    /// only the records after it. Rows shown before them load when asked for.
    mutating func resume(from checkpoint: JournalCheckpoint, loaded: (rows: [ChatMessage], context: [ChatMessage], state: JSON?, stateLine: Data?)) {
        r.resumed=true
        r.history=loaded.rows; r.visible=loaded.rows; r.context=loaded.context
        for (row, message) in zip(checkpoint.rows, loaded.rows) {
            r.rowSpans[row.id]=row
            if row.kind != .branch { for attempt in message.requestAttemptIDs ?? [] { r.pendingRequestLinks[attempt, default: []].append(message.id) } }
        }
        r.olderRows=checkpoint.rowsBefore
        r.assistantMessageCount=checkpoint.assistantMessageCount; r.latestAssistantMessageID=checkpoint.latestAssistantMessageID
        r.versions.ledger=checkpoint.versions; r.recentTaskPresentations=checkpoint.tasks
        let saved=(try? JSON.parse(Data(checkpoint.helper.utf8))) ?? [:]
        r.spend.add(record: saved["spend"]); r.spendTracked=saved["spendTracked"].flag == true
        r.failedCompactionFingerprint=saved["failedCompactionFingerprint"].text
        r.contextRecovery=saved["contextRecovery"]; r.compactionState=saved["compactionState"]; r.parentInfo=saved["parentInfo"]
        ordinalMax=saved["presentationOrdinal"].int ?? 0
        r.stateRecord=loaded.state
        if let check=checkpoint.state, let key=checkpoint.stateKey, let line=loaded.stateLine { stateSource=(line, check.offset, key) }
        // A record with changes only stands for the list the file carries.
        if let state=loaded.state { receiptsBase = .list(state[CommandReceipts.deltaKey].flag == true ? saved["commands"].list : state["commands"].list) }
    }

    /// One record: `line`, not empty, which starts `lineStart` bytes into the journal.
    mutating func consume(_ line: Data, at lineStart: UInt64) throws {
        r.coveredBytes = lineStart + UInt64(line.count) + 1
        if line.starts(with: JournalLineScan.statePrefix) {
            newestStateLine=line; stateSource=(line, lineStart, "data")
            if CommandReceipts.holdsChanges(line) { receiptChanges.append(line) } else { receiptsBase = .line(line); receiptChanges.removeAll(keepingCapacity: true) }
            return
        }
        let item=try JSON.parse(line)
        if item["customType"].text == SessionSpend.recordType { r.spend.add(record: item["data"]); r.spendTracked = true; return }
        if item["type"].text == "message" {
            let message=try ChatMessage(id:required(item["id"],"message id"),pi:item["message"]); r.history.append(message); if !["execution","requestLedger"].contains(message.kind ?? "") { r.context.append(message) }; r.visible.append(message)
            r.rowSpans[message.id] = .init(id:message.id,kind:.message,offset:lineStart,length:line.count); ordinalMax=max(ordinalMax,AgentSession.maxOrdinal(message))
            if message.role=="assistant" { r.assistantMessageCount += 1; r.latestAssistantMessageID=message.id }
            if message.role=="user" { r.versions.ledger.recorded(userMessage: message.id) }
            for attempt in message.requestAttemptIDs ?? [] { r.pendingRequestLinks[attempt, default: []].append(message.id) }
        } else if item["type"].text == "compaction" {
            let restored=try CompactionCheckpoint.restore(item,context:r.context)
            let summary=restored.summary, kept=restored.kept
            for attempt in summary.requestAttemptIDs ?? [] { r.pendingRequestLinks[attempt, default: []].append(summary.id) }
            r.context=[summary]+kept; r.history.append(summary); r.visible.append(summary)
            r.rowSpans[summary.id] = .init(id:summary.id,kind:.compaction,offset:lineStart,length:line.count)
            if let operation = summary.operationID, let position = r.history.firstIndex(where: { $0.kind == "execution" && $0.operationID == operation }) {
                AgentSession.adoptCompactionProgress(&r.history[position])
                let replacement=r.history[position]
                if let index=r.visible.firstIndex(where: { $0.id == replacement.id }) { r.visible[index]=replacement }
            }
            r.compactionState=summary.compaction ?? .null
            if let recovery=summary.compaction?["recovery"], !recovery.isNull { r.contextRecovery=recovery }
        } else if item["type"].text == "branch" {
            // Replay an edit: the live context becomes exactly the kept ids and
            // the abandoned tail leaves the displayed timeline, never the journal.
            // What it hides stays readable as the edited message's earlier version.
            r.versions.hide(from: item["fromMessageId"].text ?? "", visible: r.visible, history: r.history)
            let markerID=try identity(item["id"])
            if !item["nativeBranchVersion"].isNull {
                let plan = try AgentSession.restoreBranch(item, history: r.history, visible: r.visible, context: r.context)
                AgentSession.adoptBranch(plan, history: &r.history, visible: &r.visible, context: &r.context, markerID: markerID)
            } else {
            let ordered=try CompactionCheckpoint.identities(item["keptIds"]), ids=Set(ordered)
            guard r.context.filter({ ids.contains($0.id) }).map(\.id)==ordered else { throw AgentError("session_damaged","Branch references missing, abandoned or reordered messages") }
            AgentSession.branch(history:&r.history,context:&r.context,visible:&r.visible,from:item["fromMessageId"].text ?? "",keptIDs:ids,markerID:markerID)
            // New branches publish their replacement queue in the same
            // durable record. A crash before delivery restores it paused.
            }
            r.rowSpans[markerID] = .init(id:markerID,kind:.branch,offset:lineStart,length:line.count)
            if !item["nativeState"].isNull {
                r.stateRecord=item["nativeState"]; newestStateLine=nil; stateSource=(line, lineStart, "nativeState")
                receiptsBase = .list(item["nativeState"]["commands"].list); receiptChanges.removeAll(keepingCapacity: true)
            }
            r.contextRecovery = .null; r.compactionState = .null
        } else if item["customType"].text == JournalRecordKind.presentationUpdate {
            let target = try identity(item["data"]["id"])
            // An update follows the row it updates closely: search from the end.
            if let position = r.history.lastIndex(where: { $0.id == target }), ["execution","requestLedger"].contains(r.history[position].kind ?? "") {
                var replacement = try ChatMessage(id:target,pi:item["message"]); replacement.replayEligible=false
                r.history[position]=replacement
                r.rowSpans[target] = .init(id:target,kind:.update,offset:lineStart,length:line.count); ordinalMax=max(ordinalMax,AgentSession.maxOrdinal(replacement))
                if let index=r.visible.lastIndex(where: { $0.id == target }) { r.visible[index]=replacement }
            }
        } else if item["customType"].text == JournalRecordKind.taskTerminal {
            let task = try JSONDecoder().decode(TaskPresentationRecord.self, from: item["data"].data())
            guard task.valid, task.terminal else { throw AgentError("session_damaged", "Invalid task completion evidence") }
            r.recentTaskPresentations.removeAll { $0.key == task.key }; r.recentTaskPresentations.append(task)
            if r.recentTaskPresentations.count > 64 { r.recentTaskPresentations.removeFirst() }
        } else if item["customType"].text == JournalRecordKind.state {
            r.stateRecord=item["data"]; newestStateLine=nil; stateSource=(line, lineStart, "data")
            if item["data"][CommandReceipts.deltaKey].flag == true { receiptChanges.append(line) }
            else { receiptsBase = .list(item["data"]["commands"].list); receiptChanges.removeAll(keepingCapacity: true) }
        }
        else if item["customType"].text == JournalRecordKind.compactionFailure { r.failedCompactionFingerprint=item["data"]["fingerprint"].text }
        else if item["customType"].text == JournalRecordKind.contextRecovery { r.contextRecovery=item["data"] }
        else if item["customType"].text == JournalRecordKind.context {
            let byID=Dictionary(r.history.map { ($0.id,$0) },uniquingKeysWith:{_,b in b})
            let ids=try CompactionCheckpoint.identities(item["data"]["ids"])
            r.context=try ids.map { guard let message=byID[$0] else { throw AgentError("session_damaged","Unknown context reference") }; return message }
            let selected = EditReplayPlan.forkTimeline(visible: r.visible.map(\.id), boundary: ids)
            if !item["data"]["visibleIDs"].isNull, try CompactionCheckpoint.identities(item["data"]["visibleIDs"]) != selected { throw AgentError("session_damaged", "Fork timeline does not match the complete boundary") }
            r.visible = selected.compactMap { byID[$0] }
        } else if [JournalRecordKind.sideOrigin, JournalRecordKind.forkOrigin].contains(item["customType"].text ?? "") {
            r.parentInfo=item["data"]
            if item["customType"].text == JournalRecordKind.forkOrigin { r.contextRecovery = .null; r.compactionState = .null }
        }
        // A record that sets the model context is where the next open can
        // resume from: the metadata file records what it takes to.
        if ["compaction", "branch"].contains(item["type"].text ?? "") || item["customType"].text == JournalRecordKind.context {
            let helper=AgentSession.checkpointHelper(spend:r.spend,spendTracked:r.spendTracked,failedCompactionFingerprint:r.failedCompactionFingerprint,
                                                     contextRecovery:r.contextRecovery,compactionState:r.compactionState,parentInfo:r.parentInfo,presentationOrdinal:ordinalMax)
            r.captured=AgentSession.checkpoint(sessionID:id,header:header,marker:marker,last:line,at:lineStart,lastID:try identity(item["id"]),
                                               visible:r.visible,context:r.context,spans:r.rowSpans,state:stateSource,assistantMessageCount:r.assistantMessageCount,
                                               latestAssistantMessageID:r.latestAssistantMessageID,versions:r.versions.ledger,tasks:r.recentTaskPresentations,helper:helper)
            capturedReceipts = (receiptsBase, receiptChanges)
        }
    }

    /// What the records so far replay to. The consumer can go on after it.
    func finished() throws -> JournalReplay {
        var r = self.r
        // A process restart cannot manufacture terminal evidence. Retained
        // parts stay in place, with an explicit gap after the last checkpoint.
        for index in r.history.indices {
            guard AgentSession.endWithoutReceipt(&r.history[index]) else { continue }
            let replacement=r.history[index]
            if let shown = r.visible.firstIndex(where: { $0.id == replacement.id }) { r.visible[shown] = replacement }
        }
        r.presentationOrdinal = max(r.history.compactMap(\.responseTimeline).flatMap(\.segments).map { $0.part.sessionOrdinal ?? $0.part.ordinal }.max() ?? 0, r.resumed ? ordinalMax : 0)
        if let line=newestStateLine {
            let item=try JSON.parse(line)
            guard item["customType"].text == JournalRecordKind.state else { throw AgentError("session_damaged", "Invalid session state record") }
            r.stateRecord=item["data"]
        }
        if let state=r.stateRecord {
            var whole=state.removing([CommandReceipts.deltaKey])
            whole["commands"] = .array(try CommandReceipts.rebuild(receiptsBase, receiptChanges))
            r.stateRecord=whole
        }
        if var captured=r.captured, let receipts=capturedReceipts {
            var helper=(try? JSON.parse(Data(captured.helper.utf8))) ?? [:]
            helper["commands"] = .array(try CommandReceipts.rebuild(receipts.base, receipts.changes))
            captured.helper=helper.encoded(); r.captured=captured
        }
        r.stateSource = stateSource.map { StateSource(line: $0.line, offset: $0.offset, key: $0.key) }
        return r
    }
}

extension AgentSession {
    /// `resume` false replays the whole journal whatever its metadata file
    /// says. `spendTracked` is what a journal with no cost record counts as.
    static func replay(_ opened: SessionJournal, url: URL, id: String, binding: JSON, spendTracked: Bool, resume: Bool) throws -> JournalReplay {
        var resumeFrom: (checkpoint: JournalCheckpoint, loaded: (rows: [ChatMessage], context: [ChatMessage], state: JSON?, stateLine: Data?))?
        if resume, let checkpoint=opened.resumedFrom, let loaded=Self.loadCheckpoint(checkpoint, url: url) { resumeFrom=(checkpoint, loaded) }
        else if resume, opened.resumedFrom != nil { try opened.checkWhole(id: id, binding: binding) }
        var consumer=JournalReplayConsumer(id: id, header: opened.headerCheck, marker: opened.markerCheck, spendTracked: spendTracked)
        let replay: JournalRecordReader
        if let resumeFrom {
            consumer.resume(from: resumeFrom.checkpoint, loaded: resumeFrom.loaded)
            replay=try opened.recordReader(from: resumeFrom.checkpoint.start)
        } else {
            replay=try opened.recordReader()
        }
        while true {
            let lineStart=replay.completeBytes
            guard let line=try replay.nextLine() else { break }
            if line.isEmpty { continue }
            try consumer.consume(line, at: lineStart)
        }
        return try consumer.finished()
    }
    /// A progress row the journal holds no terminal receipt for, as a replay
    /// leaves it: interrupted, with the gap said. False for any other row.
    static func endWithoutReceipt(_ message: inout ChatMessage) -> Bool {
        guard ["execution","requestLedger"].contains(message.kind ?? ""), message.responseTimeline?.terminal == nil else { return false }
        message.responseTimeline?.finish("interrupted")
        message.responseTimeline?.coverage = "partial"
        message.detail = (message.kind == "requestLedger" ? "Request":"Compaction") + " interrupted · no terminal receipt"
        return true
    }
}
