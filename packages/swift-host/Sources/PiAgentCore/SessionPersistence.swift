import Foundation

// What a session writes down and republishes: saved queue/run state,
// message appends, forks, and keeping an ephemeral side chat.

extension AgentSession {
    /// A side's starting context and origin. The origin also names the tools
    /// this chat's requests offer and the prompt cache they join, which the
    /// side's requests keep (SessionSide.swift).
    public func sideSeed() -> (messages:[ChatMessage], info:JSON) { (boundary,["parentSessionId":JSON(id),"cutoffEntryId":boundary.last.map { JSON($0.id) } ?? .null,"contextRevision":JSON(sha256(Data(boundary.map(\.id).joined(separator:"\n").utf8))),"capturedAt":JSON(isoNow()),"instructionRevision":appliedRevision.map { JSON($0) } ?? .null,
        "parentToolMode":JSON(offersReadOnlyTools ? "read-only" : "editing"),"cacheSessionId":JSON(promptCacheSessionID)]) }
    /// Clone the complete retained journal without replaying a queued command.
    /// A running source contributes its latest complete model/tool boundary;
    /// later source records remain inspectable in the clone's original history.
    ///
    /// `messageID` forks at one assistant reply instead, in the timeline shown
    /// now or in an earlier version of an edited message: the clone holds the
    /// journal only up to that reply and the results of the tools it called,
    /// and its context is what replaying those records gives, so the edits and
    /// compactions in effect then are the ones it has. A reply a later
    /// compaction summarized comes back with its whole context.
    public func fork(to newID: String, at messageID: String? = nil) throws -> JSON { try forked(to: newID, at: messageID).result }
    /// The fork, and the replay of its journal, made as the journal is
    /// written: the fork's session opens with it (`AgentSession(prepared:)`)
    /// and goes on from it, not reading the journal again. That open writes
    /// the metadata file, as a first open does.
    func forked(to newID: String, at messageID: String? = nil) throws -> (result: JSON, replay: JournalReplayConsumer) {
        guard !closed, let journal, !ephemeral else { throw AgentError("session_unavailable", "Save this session before forking its context") }
        SessionJournal.removeForkLeftovers(in: directory)
        if let cloned = clonedFork(to: newID, journal: journal, at: messageID) { return cloned }
        // A chat opened from its metadata file has only its latest rows. A
        // fork of the whole chat replays everything it copies, which is the
        // chat's whole history, and the chat takes its rows from that; a
        // fork from a reply reads the whole journal first, as before.
        let hydrating = messageID == nil && partialHistory
        if !hydrating { try ensureFullHistory() }
        do {
            let made = try forkCopy(to: newID, at: messageID, journal: journal, hydrating: hydrating)
            if let copied=made.copied { try adoptCopiedHistory(copied.history, places: copied.places) }
            return (made.result, made.replay)
        } catch {
            // A fork that fails leaves the chat with its whole history, as
            // reading it before the attempt did; a journal that cannot be
            // read in full fails with that, as it did.
            if hydrating, partialHistory { try ensureFullHistory() }
            throw error
        }
    }
    /// A fork made by cloning the chat's journal instead of copying it
    /// (`SessionJournal.clone`): the chat's records as they were written (up
    /// to a reply's, for a fork from it), then the fork's origin, a spend that
    /// starts again from nothing, its run state and its context, in that
    /// order, so the checkpoint the fork opens from is taken after all of
    /// them. The fork's replay is the chat's (`durableReplay`), or for a fork
    /// from a reply the one rebuilt at it (`replyPoint`), taken on through
    /// those records; its metadata file is that replay's checkpoint. A chat
    /// opened with every row gives a fork opened so, one opened from its
    /// metadata file a fork opened from its own. The chat is left as it was.
    ///
    /// Nil, with nothing left behind, when the fork cannot be cloned or its
    /// checkpoint known: a run going, receipts not known, a volume that does
    /// not clone, an identity longer than the chat's, a write that fails.
    /// The fork is then copied, as before.
    private func clonedFork(to newID: String, journal: SessionJournal, at messageID: String?) -> (result: JSON, replay: JournalReplayConsumer)? {
        guard runTask == nil, !journaledCommandsUncertain, (try? identity(JSON(newID))) != nil, newID != id,
              var replay = try? forkBase() else { return nil }
        var origin=sideSeed().info.removing(["parentToolMode","cacheSessionId"]); origin["relationship"]="fork"
        origin["omittedIncompleteEntries"]=JSON(max(0,context.count-boundary.count))
        var contextIDs=boundary.map(\.id), through: (bytes: UInt64, lastID: String)?
        if let messageID {
            guard let point=(try? replyPoint(messageID, journal: journal, chat: replay)) ?? nil else { return nil }
            replay=point.replay; contextIDs=point.context; through=point.through
            origin["forkedAtMessageId"]=JSON(messageID)
            origin["cutoffEntryId"]=contextIDs.last.map { JSON($0) } ?? .null
            origin["contextRevision"]=JSON(sha256(Data(contextIDs.joined(separator:"\n").utf8)))
            origin["omittedIncompleteEntries"]=0
        }
        let temporary=directory.appendingPathComponent(".fork-\(UUID().uuidString).jsonl")
        let destination=directory.appendingPathComponent("fork_"+newID+".jsonl")
        guard let clone=journal.clone(to: temporary, id: newID, cwd: cwd, through: through) else { return nil }
        do {
            replay.retarget(id: newID, header: clone.headerCheck)
            replay.retarget(rebinds: clone.rebinds.map(\.check))
            func written() throws {
                guard let span=clone.lastAppend, let line=clone.lastAppendLine else { throw AgentError("session_damaged", "The fork's journal was not written as expected") }
                try replay.consume(line, at: span.offset)
            }
            func write(_ value: JSON) throws { try clone.append(value, flush: false); try written() }
            // A fork from a reply written before the chat moved to its
            // connection ends where the journal was bound to the old one: it
            // moves to the chat's, as the chat did.
            if clone.binding != profile.binding { try clone.rebind(to: profile.binding, flush: false); try written() }
            try write(["type":"custom","customType":JSON(JournalRecordKind.forkOrigin),"data":origin])
            var fresh = SessionSpend().record; fresh["source"] = "fork"; fresh[SessionSpend.resetKey] = true
            try write(["type":"custom","customType":JSON(SessionSpend.recordType),"data":fresh])
            try write(["type":"custom","customType":JSON(JournalRecordKind.state),"data":["active":false,"queue":[],"steering":[],"commands":[],"queuePaused":false,"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode)]])
            // The rows shown are the chat's up to the last of these; every
            // reader works them out from the ids.
            try write(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(contextIDs.map { JSON($0) })]])
            guard let checkpoint=try replay.finished().captured, checkpoint.last.offset == clone.lastAppend?.offset else {
                throw AgentError("session_damaged", "The fork's checkpoint cannot be known")
            }
            try clone.publish(to: destination)
            // Without it, the fork's first open reads its whole journal.
            try? checkpoint.write(for: destination)
            return (["accepted":true,"sessionId":JSON(newID),"path":JSON(destination.path),"origin":origin], replay)
        } catch {
            try? FileManager.default.removeItem(at: temporary); try? FileManager.default.removeItem(atPath: temporary.path+".lock")
            return nil
        }
    }
    /// Where a fork from the reply `messageID` ends, found from where the
    /// reply is rather than by reading the journal from its start: the reply
    /// itself, or the last result of the tools it called before the next
    /// reply or message (`forkPoint`'s rule). Then the chat's replay rebuilt
    /// there, from the chat's latest checkpoint before the reply, or from the
    /// start for a reply before it, and the context a fork from it has, as
    /// `ConversationReplay` gives it. From a checkpoint, that context is the
    /// checkpoint's (a compaction, an edit or a fork's context, which both
    /// replays set alike) and each message after it a request sends.
    ///
    /// Nil when this cannot be known here: the reply's place unknown, a
    /// record that is not the reply, a reply that cannot be forked from, a
    /// context record after the checkpoint. The copy decides then, and gives
    /// its errors.
    private func replyPoint(_ messageID: String, journal: SessionJournal, chat: JournalReplayConsumer) throws
        -> (through: (bytes: UInt64, lastID: String), replay: JournalReplayConsumer, context: [String])? {
        guard let span=chat.r.rowSpans[messageID] ?? rowSpans[messageID] ?? olderIndex?.span(of: messageID), span.kind == .message else { return nil }
        let reader=try JournalRecordReader(journal.url, expectedBytes: journal.size, startingAt: span.offset)
        guard let line=try reader.nextLine(), line.count == span.length else { return nil }
        let record=try JSON.parse(line)
        guard record["type"].text == "message", record["id"].text == messageID else { return nil }
        let reply=try ChatMessage(id: messageID, pi: record["message"])
        guard reply.role == "assistant", reply.kind == nil, reply.replayEligible else { return nil }
        var pending=Set(reply.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text })
        var end=(bytes: reader.completeBytes, lastID: messageID)
        while !pending.isEmpty, let next=try reader.nextLine() {
            if next.isEmpty { continue }
            let item=try JSON.parse(next)
            guard item["type"].text == "message" else { continue }
            let role=item["message"]["role"].text
            if role == "toolResult", let call=item["message"]["toolCallId"].text, pending.remove(call) != nil { end=(reader.completeBytes, try identity(item["id"])); continue }
            if role == "assistant" || role == "user" { break }
        }
        try reader.checkUnchanged()
        var replay=JournalReplayConsumer(id: id, header: journal.headerCheck, marker: journal.markerCheck, spendTracked: spendTracked)
        // The context there, from the chat's latest checkpoint before the
        // reply when both replays set the context at its record: after it
        // come only messages, each shown, and in the context if a request
        // sends it. Otherwise it is rebuilt from the start.
        var seed=try chat.capturedCheckpoint() ?? chat.r.resumedFrom
        if let checkpoint=seed, checkpoint.start > span.offset || !Self.bothReplaysSetTheContext(at: checkpoint, in: journal.url) { seed=nil }
        var context=seed?.context ?? [], shown=seed?.rows.map(\.id) ?? [], pure: ConversationReplay?=seed == nil ? try ConversationReplay() : nil
        // Rebuilt from that checkpoint, the fork opens from its own metadata
        // file, fast, and loads its older rows after (`startHistoryFill`);
        // without one, it is rebuilt from the start and opens whole.
        let from: UInt64
        if let checkpoint=seed, let loaded=Self.loadCheckpoint(checkpoint, url: journal.url) {
            replay.resume(from: checkpoint, loaded: loaded); from=checkpoint.start
        } else if pure != nil { from=0 }
        else { return nil }
        let records=try from == 0 ? journal.recordReader() : JournalRecordReader(journal.url, expectedBytes: journal.size, startingAt: from)
        if from == 0 { replay.starts(at: records.completeBytes) }
        while true {
            let start=records.completeBytes
            guard start < end.bytes, let line=try records.nextLine() else { break }
            if line.isEmpty { continue }
            try replay.consume(line, at: start)
            if pure != nil { try pure?.consume(try JSON.parse(line)); continue }
            guard let checkpoint=seed, start >= checkpoint.start else { continue }
            let item=try JSON.parse(line)
            if ["compaction", "branch"].contains(item["type"].text ?? "") || item["customType"].text == JournalRecordKind.context { return nil }
            guard item["type"].text == "message" else { continue }
            let message=try ChatMessage(id: identity(item["id"]), pi: item["message"])
            shown.append(message.id); if message.replayEligible { context.append(message.id) }
        }
        try records.checkUnchanged()
        if let pure { context=pure.context.map(\.id); shown=pure.visible.map(\.id) }
        guard context.contains(messageID), EditReplayPlan.forkTimeline(visible: shown, boundary: context).contains(messageID) else { return nil }
        return (end, replay, context)
    }
    /// Whether a checkpoint's context is the one both replays have there: the
    /// record that set it is the one the checkpoint follows, or a compaction
    /// or edit among its rows before that (a live chat's checkpoint follows
    /// the compaction's finished progress, written after it); that record
    /// sets the context for both alike (a compaction, an edit, or a fork's
    /// context record that is no message: a message carrying that kind is a
    /// message to one and a context to the other); and no message comes
    /// between it and the record the checkpoint follows.
    private static func bothReplaysSetTheContext(at checkpoint: JournalCheckpoint, in url: URL) -> Bool {
        func setsTheContext(_ item: JSON) -> Bool {
            let type=item["type"].text
            return type == "compaction" || type == "branch" || (type != "message" && item["customType"].text == JournalRecordKind.context)
        }
        guard let file=try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let last=JournalCheckpoint.verified(checkpoint.last, in: file), let lastItem=try? JSON.parse(last) else { return false }
        if setsTheContext(lastItem) { return true }
        guard lastItem["type"].text != "message",
              let setting=checkpoint.rows.filter({ ($0.kind == .compaction || $0.kind == .branch) && $0.offset < checkpoint.last.offset }).max(by: { $0.offset < $1.offset }),
              let reader=try? JournalRecordReader(url, startingAt: setting.offset), let line=try? reader.nextLine(), line.count == setting.length,
              let item=try? JSON.parse(line), item["id"].text == setting.id, setsTheContext(item) else { return false }
        // What follows it, through the record the checkpoint follows: no message.
        while reader.completeBytes <= checkpoint.last.offset {
            guard let next=try? reader.nextLine() else { return false }
            if next.isEmpty { continue }
            guard let record=try? JSON.parse(next), record["type"].text != "message", !setsTheContext(record) else { return false }
        }
        return true
    }
    /// The chat's rows from what a fork of the whole chat copied, their places
    /// mapped back to this chat's journal; a place not found is read again.
    private func adoptCopiedHistory(_ copied: JournalReplay, places: [UInt64: (offset: UInt64, length: Int)]) throws {
        var whole = copied, spans: [String: JournalCheckpoint.Row] = [:]
        for (row, span) in whole.rowSpans {
            guard let place=places[span.offset] else { try ensureFullHistory(); return }
            spans[row]=JournalCheckpoint.Row(id:span.id,kind:span.kind,offset:place.offset,length:place.length)
        }
        whole.rowSpans=spans
        adoptFullHistory(whole)
    }
    /// The fork's journal written, and what it replays to; with `hydrating`,
    /// also what the copied records replay to, the chat's whole history, and
    /// where each record is in this chat's journal, by its offset in the fork's.
    private func forkCopy(to newID: String, at messageID: String?, journal: SessionJournal, hydrating: Bool)
        throws -> (result: JSON, replay: JournalReplayConsumer, copied: (history: JournalReplay, places: [UInt64: (offset: UInt64, length: Int)])?) {
        _ = try identity(JSON(newID))
        guard newID != id else { throw AgentError("session_conflict", "A fork needs a new session identity") }
        let temporary=directory.appendingPathComponent(".fork-\(UUID().uuidString).jsonl")
        let destination=directory.appendingPathComponent("fork_"+newID+".jsonl")
        // A fork has its own tools and its own prompt cache.
        var origin=sideSeed().info.removing(["parentToolMode","cacheSessionId"]); origin["relationship"]="fork"
        origin["omittedIncompleteEntries"]=JSON(max(0,context.count-boundary.count))
        var contextIDs=boundary.map(\.id), timeline=EditReplayPlan.forkTimeline(visible:visible.map(\.id),boundary:contextIDs)
        var end: Int?
        if let messageID {
            let cutoff=try forkPoint(messageID, in: journal.recordReader()); end=cutoff
            // The read-only replay, stopped at the reply. Opening a chat replays
            // with `AgentSession.replay` instead; the two give the same rows
            // and the same context a request sends, but the open's context
            // also keeps rows no request sends, such as an interrupted reply's
            // partial, until a record resets it (ReplayParityTests).
            let state: ConversationReplay
            do { state=try ConversationReplay(upTo: cutoff, in: journal.recordReader()) }
            catch { throw AgentError("fork_target", "The conversation up to that reply cannot be rebuilt: \(error.localizedDescription)") }
            contextIDs=state.context.map(\.id)
            timeline=EditReplayPlan.forkTimeline(visible:state.visible.map(\.id),boundary:contextIDs)
            guard contextIDs.contains(messageID), timeline.contains(messageID) else {
                throw AgentError("fork_target", "That reply is not part of the conversation it belongs to, so it cannot be forked.")
            }
            origin["forkedAtMessageId"]=JSON(messageID)
            origin["cutoffEntryId"]=contextIDs.last.map { JSON($0) } ?? .null
            origin["contextRevision"]=JSON(sha256(Data(contextIDs.joined(separator:"\n").utf8)))
            origin["omittedIncompleteEntries"]=0
        }
        let replay: JournalReplayConsumer
        var copiedHistory: JournalReplay?, sourcePlaces: [UInt64: (offset: UInt64, length: Int)] = [:]
        do {
            let prepared=try SessionJournal(url:temporary,id:newID,cwd:cwd,binding:profile.binding,create:true)
            // Each record the fork's journal gets, from its marker on, is
            // replayed as it is written, as the fork's first open would.
            var consumer=JournalReplayConsumer(id:newID,header:prepared.headerCheck,marker:prepared.markerCheck,spendTracked:false)
            func replayWritten() throws { if let span=prepared.lastAppend, let line=prepared.lastAppendLine { try consumer.consume(line,at:span.offset) } }
            try replayWritten()
            // A fork is a chat of its own: it starts with no spend of its own.
            // A copy's marker is the chat's binding now: the moves that led
            // there are the chat's history, not the fork's.
            let left: Set<String> = [JournalRecordKind.marker, JournalRecordKind.state, JournalRecordKind.sideOrigin, JournalRecordKind.forkOrigin, JournalRecordKind.contextRecovery, SessionSpend.recordType, JournalRecordKind.rebind]
            let reader=try journal.recordReader(); var index=0
            func copied(from lineStart: UInt64, length: Int) { if hydrating, let span=prepared.lastAppend { sourcePlaces[span.offset]=(lineStart, length) } }
            while true {
                // The records past the reply a fork ends at are neither
                // copied nor read again: forkPoint has read them.
                if let end, index > end { break }
                let lineStart=reader.completeBytes
                guard let line=try reader.nextLine() else { break }
                if line.isEmpty { continue }
                defer { index += 1 }
                // The record's kind and id, read without building it; a line
                // the scan cannot read plainly is parsed. The thousands of
                // run-state records a long chat has are left out, each still
                // checked to be JSON the parser takes, as parsing it checked.
                if let fields=JournalLineScan.stateTail(line) ?? JournalLineScan.fields(line), let recordID=fields.id {
                    if left.contains(fields.customType ?? "") {
                        if !JSONSyntax.plainlyValid(line) { _ = try JSON.parse(line) }
                        continue
                    }
                    let id=try identity(JSON(recordID))
                    // Its bytes as they were, but for its envelope; the replay
                    // below parses what is written, as the fork's open would.
                    if let copy=JournalEnvelope.rewritten(line,id:id,parentID:prepared.head,timestamp:isoNow()), copy.count <= JournalRecordReader.maximumRecordBytes {
                        try prepared.appendLine(copy,id:id,flush:false)
                        copied(from:lineStart,length:line.count)
                        try replayWritten()
                        continue
                    }
                }
                let record=try JSON.parse(line)
                if left.contains(record["customType"].text ?? "") { continue }
                // Branch records can contain a queued edit. Preserve the branch
                // and all message bytes, but never authorize its command twice.
                try prepared.append(record.removing(["id","parentId","timestamp","nativeState"]),id:try identity(record["id"]),flush:false)
                copied(from:lineStart,length:line.count)
                try replayWritten()
            }
            try reader.checkUnchanged()
            if hydrating {
                // Every record copied: the chat's whole history, whose shown
                // rows the fork's timeline is cut from.
                let whole=try consumer.finished()
                timeline=EditReplayPlan.forkTimeline(visible:whole.visible.map(\.id),boundary:contextIDs)
                copiedHistory=whole
            }
            // As with the copied records, `publish` forces these to disk
            // before the fork takes its name.
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(contextIDs.map { JSON($0) }),"visibleIDs":.array(timeline.map { JSON($0) })]],flush:false)
            try replayWritten()
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.forkOrigin),"data":origin],flush:false)
            try replayWritten()
            var fresh = SessionSpend().record; fresh["source"] = "fork"
            try prepared.append(["type":"custom","customType":JSON(SessionSpend.recordType),"data":fresh],flush:false)
            try replayWritten()
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":["active":false,"queue":[],"steering":[],"commands":[],"queuePaused":false,"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode)]],flush:false)
            try replayWritten()
            _=try consumer.finished(); replay=consumer
            try prepared.publish(to:destination)
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        return (["accepted":true,"sessionId":JSON(newID),"path":JSON(destination.path),"origin":origin], replay, copiedHistory.map { ($0, sourcePlaces) })
    }
    /// The last journal record a fork at `messageID` keeps: the reply itself,
    /// or the last result of the tools it called, so the fork starts after
    /// its whole tool batch. A batch still running is refused; one a crash
    /// left without results is kept, and the fork records their outcome as
    /// unknown when it opens, as any reopened chat does.
    ///
    /// It reads every record to the journal's end, so one the parser refuses
    /// fails the fork with its error; the fork's replay and copy then stop at
    /// the point.
    func forkPoint(_ messageID: String, in reader: JournalRecordReader) throws -> Int {
        var index=0, start: Int?, end=0, pending=Set<String>(), batchFinished=false
        while let record=try reader.next() {
            defer { index += 1 }
            if start == nil {
                guard record["type"].text == "message", record["id"].text == messageID else { continue }
                start=index; end=index
                let reply = try ChatMessage(id: messageID, pi: record["message"])
                guard reply.role == "assistant", reply.kind == nil else { throw AgentError("fork_target", "Choose one of the assistant's replies to fork from.") }
                guard reply.replayEligible else {
                    throw AgentError("fork_target", "That reply was stopped before it finished, so it is not part of the conversation. Fork from an earlier reply.")
                }
                pending=Set(reply.content.filter { $0["type"].text == "toolCall" }.compactMap { $0["id"].text })
                continue
            }
            guard !pending.isEmpty, !batchFinished else { continue }
            guard record["type"].text == "message" else { continue }
            let role = record["message"]["role"].text
            if role == "toolResult", let call = record["message"]["toolCallId"].text, pending.remove(call) != nil { end = index; continue }
            // The batch is over once the next reply or message begins.
            if role == "assistant" || role == "user" { batchFinished=true }
        }
        guard start != nil else { throw AgentError("fork_target", "That reply is not in this conversation's journal yet.") }
        if !pending.isEmpty, runTask != nil, context.contains(where: { $0.id == messageID }) {
            throw AgentError("fork_tools_running", "That reply's tools are still running. Fork from it once they finish.")
        }
        return end
    }
    func savedState(active: Bool? = nil) throws -> JSON {
        var value: JSON = ["active":JSON(active ?? (runTask != nil)),"queue":.array(queue.map(\.savedValue)),"steering":.array(steering.map(\.savedValue)),"commands":.array(Array(commands.suffix(128))),"queuePaused":JSON(queuePaused),"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode),"runStatus":JSON(runStatus.rawValue),"errorMessage":errorMessage.map { JSON($0) } ?? .null,"errorCode":errorCode.map { JSON($0) } ?? .null,"timing":["modelMs":cumulativeModelMs.map { JSON($0) } ?? .null,"toolMs":cumulativeToolMs.map { JSON($0) } ?? .null]]
        // The message being delivered counts with the lanes it goes back to.
        if let delivering { value["delivering"] = ["lane": JSON(delivering.lane), "submission": delivering.submission.savedValue] }
        // A queued edit's hold and the outcomes of recent edits; absent when there are none.
        if let queueEdit { value["queueEdit"] = (try? JSON.parse(JSONEncoder().encode(queueEdit))) ?? .null }
        if !queueEditOutcomes.isEmpty { value["queueEditOutcomes"] = (try? JSON.parse(JSONEncoder().encode(queueEditOutcomes))) ?? .null }
        if queueEditRevision > 0 { value["queueEditSequence"]=JSON(queueEditSequence); value["queueEditRevision"]=JSON(queueEditRevision) }
        if queueEditForgottenRevision > 0 { value["queueEditForgottenRevision"]=JSON(queueEditForgottenRevision) }
        guard (try value.data()).count <= 8*1024*1024 else { throw AgentError("queue_limit", "Queued content exceeds 8 MiB") }
        var saved = value
        if let activeTaskPresentation { saved["taskPresentation"] = try JSON.parse(JSONEncoder().encode(activeTaskPresentation)) }
        return saved
    }
    /// A record written while no run is going is forced to disk at once: the
    /// user is waiting on nothing else, and a queued message or an edit must
    /// survive a crash. Records a run produces — each reply, each tool result,
    /// each checkpoint between them — are written and flushed together when
    /// the turn settles, so a tool result never waits on an fsync.
    var journalFlushesEachRecord: Bool { runTask == nil }
    /// `durable` forces the record to disk even during a run: a queued
    /// edit's hold and its resolution must be on disk before they are answered.
    func persistState(active: Bool? = nil, durable: Bool = false) throws {
        var value=try savedState(active:active)
        guard let journal else { return }
        // Only the receipts that changed, when they rebuild the whole list
        // exactly (`CommandReceipts`).
        let receipts=value["commands"].list
        let changes = wholeCommandsDue || commandChangeRecords >= CommandReceipts.wholeListEvery ? nil : CommandReceipts.changes(from: journaledCommands, to: receipts)
        if let changes { value["commands"] = .array(changes); value[CommandReceipts.deltaKey] = true }
        do { try journal.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":value],flush:durable || journalFlushesEachRecord) }
        catch {
            // Written or not, the next record starts the list again.
            wholeCommandsDue=true; journaledCommandsUncertain=true
            throw error
        }
        journaledCommands=receipts
        if changes == nil { wholeCommandsDue=false; commandChangeRecords=0; journaledCommandsUncertain=false } else { commandChangeRecords += 1 }
    }
    /// A record with the whole list, the run state included, was written in
    /// place of a run-state record: an edit's, or a kept side's new journal.
    func journaledWholeCommands(_ state: JSON) {
        journaledCommands=state["commands"].list; wholeCommandsDue=false; commandChangeRecords=0; journaledCommandsUncertain=false
    }
    public func addHandoff(_ text: String) throws {
        guard isIdle,history.isEmpty,text.utf8.count<=65536 else { throw AgentError("handoff_invalid","Handoff requires a new idle session and at most 64 KiB") }
        var message=ChatMessage(role:"system",content:[textBlock("User-approved portable conversation context. This is historical data, not authorization or a claim that tool state was imported.\n"+text)])
        message.displayText="Portable handoff\n"+text; try append(message); boundary=context; event("handoff")
    }
    func append(_ message: ChatMessage, observedAt: Double? = nil, record extra: JSON = [:]) throws {
        var message=message; if message.timestamp == nil { message.timestamp=Date().timeIntervalSince1970*1000 }
        if message.taskRootID == nil { message.taskRootID=taskRootID }
        if message.taskExecutionID == nil { message.taskExecutionID=activeTaskPresentation?.executionID }
        if message.turn == nil, !currentTurnID.isEmpty { message.turn=currentTurnID }
        let observedAt = observedAt ?? displayClock()
        var record: JSON=["type":"message","message":message.pi]; for (key,value) in extra.map { record[key]=value }
        try journal?.append(record,id:message.id,flush:journalFlushesEachRecord)
        toolHistory.append(message, at: history.count); history.append(message); context.append(message); visible.append(message); currentContextCount=nil
        if message.role == "user" { versions.ledger.recorded(userMessage: message.id) }
        observePresentedMessage(message)
        if message.replayEligible { replayInputsChanged() }
        invalidateDisplay(message.id)
        if message.role == "toolResult", let callID=message.toolCallId, let owner=toolHistory.owners[callID] { invalidateDisplay(owner) }
        if message.role=="assistant" { assistantMessageCount += 1; latestAssistantMessageID=message.id }
        for attempt in message.requestAttemptIDs ?? [] { pendingRequestLinks[attempt, default: []].append(message.id) }
        if message.role == "assistant" || message.role == "toolResult" { recordDisplayChange(message.id, at: observedAt) }
    }
    public func keep(whenFinished: Bool) throws -> JSON {
        guard ephemeral else { return ["accepted":true,"ephemeral":false,"path":path.map { JSON($0) } ?? .null] }
        if !isIdle { guard whenFinished else { throw AgentError("session_busy", "Keep when idle or choose Keep when finished") }; keepRequested=true; event("side.keep-requested"); return ["accepted":true,"whenFinished":true] }
        return try keepNow()
    }
    /// Closing a side panel saves it even while it is running. The queue/active
    /// state is part of the same publication, so a crash cannot replay a tool.
    public func preserveSide() throws -> JSON {
        guard parentInfo["parentSessionId"].text != nil, parentInfo["relationship"].text != "fork" else { throw AgentError("not_side", "Only side conversations use this operation") }
        return ephemeral ? try keepNow() : ["accepted":true,"sessionId":JSON(id),"path":path.map { JSON($0) } ?? .null,"ephemeral":false]
    }
    func keepNow() throws -> JSON {
        // Build a complete new journal first, then publish ownership in memory.
        // Failed writes leave the live side untouched; never overwrite another chat.
        let temporary=directory.appendingPathComponent(".side-\(UUID().uuidString).jsonl"), destination=directory.appendingPathComponent("side_"+id+".jsonl")
        do {
            let prepared=try SessionJournal(url:temporary,id:id,cwd:cwd,binding:profile.binding,create:true)
            // No record is forced to disk on its own: `publish` forces the whole
            // journal there before it takes the side's name. A side opened from
            // a long chat paid one fsync per message of its parent's context.
            for message in history { try prepared.append(["type":"message","message":message.pi],id:message.id,flush:false) }
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(context.map { JSON($0.id) })]],flush:false)
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.sideOrigin),"data":parentInfo],flush:false)
            // What the side spent before it was kept goes with it.
            try prepared.append(carriedSpendRecord(),flush:false)
            let state=try savedState()
            try prepared.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":state],flush:false)
            try prepared.publish(to:destination); journal=prepared; ephemeral=false; keepRequested=false
            journaledWholeCommands(state)
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        event("side.kept")
        return ["accepted":true,"sessionId":JSON(id),"path":JSON(destination.path),"ephemeral":false]
    }
}
