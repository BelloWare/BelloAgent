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
    public func fork(to newID: String, at messageID: String? = nil) throws -> JSON {
        guard !closed, let journal, !ephemeral else { throw AgentError("session_unavailable", "Save this session before forking its context") }
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
            // The same reducer every journal is replayed with, stopped at the reply.
            var state=try ConversationReplay()
            do {
                let reader=try journal.recordReader(); var index=0
                while let record=try reader.next() {
                    if index <= cutoff { try state.consume(record) }; index += 1
                }
            }
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
        do {
            let prepared=try SessionJournal(url:temporary,id:newID,cwd:cwd,binding:profile.binding,create:true)
            let reader=try journal.recordReader(); var index=0
            while let record=try reader.next() {
                defer { index += 1 }
                if let end, index > end { continue }
                let kind=record["customType"].text ?? ""
                // A fork is a chat of its own: it starts with no spend of its own.
                if ["pi-app.native.v1", "pi-app.native.state.v1", "pi-app.side-origin.v1", "pi-app.fork-origin.v1", "pi-app.context-recovery.v1", SessionSpend.recordType].contains(kind) { continue }
                // Branch records can contain a queued edit. Preserve the branch
                // and all message bytes, but never authorize its command twice.
                try prepared.append(record.removing(["id","parentId","timestamp","nativeState"]),id:try identity(record["id"]),flush:false)
            }
            try prepared.append(["type":"custom","customType":"pi-app.native.context.v1","data":["ids":.array(contextIDs.map { JSON($0) }),"visibleIDs":.array(timeline.map { JSON($0) })]])
            try prepared.append(["type":"custom","customType":"pi-app.fork-origin.v1","data":origin])
            var fresh = SessionSpend().record; fresh["source"] = "fork"
            try prepared.append(["type":"custom","customType":JSON(SessionSpend.recordType),"data":fresh])
            try prepared.append(["type":"custom","customType":"pi-app.native.state.v1","data":["active":false,"queue":[],"steering":[],"commands":[],"queuePaused":false,"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode)]])
            try prepared.publish(to:destination)
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        return ["accepted":true,"sessionId":JSON(newID),"path":JSON(destination.path),"origin":origin]
    }
    /// The last journal record a fork at `messageID` keeps: the reply itself,
    /// or the last result of the tools it called, so the fork starts after
    /// its whole tool batch. A batch still running is refused; one a crash
    /// left without results is kept, and the fork records their outcome as
    /// unknown when it opens, as any reopened chat does.
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
        let value: JSON = ["active":JSON(active ?? (runTask != nil)),"queue":.array(queue.map(\.savedValue)),"steering":.array(steering.map(\.savedValue)),"commands":.array(Array(commands.suffix(128))),"queuePaused":JSON(queuePaused),"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode),"runStatus":JSON(runStatus),"errorMessage":errorMessage.map { JSON($0) } ?? .null,"errorCode":errorCode.map { JSON($0) } ?? .null,"timing":["modelMs":cumulativeModelMs.map { JSON($0) } ?? .null,"toolMs":cumulativeToolMs.map { JSON($0) } ?? .null]]
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
    func persistState(active: Bool? = nil) throws {
        let value=try savedState(active:active)
        try journal?.append(["type":"custom","customType":"pi-app.native.state.v1","data":value],flush:journalFlushesEachRecord)
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
            for message in history { try prepared.append(["type":"message","message":message.pi],id:message.id) }
            try prepared.append(["type":"custom","customType":"pi-app.native.context.v1","data":["ids":.array(context.map { JSON($0.id) })]])
            try prepared.append(["type":"custom","customType":"pi-app.side-origin.v1","data":parentInfo])
            // What the side spent before it was kept goes with it.
            try prepared.append(carriedSpendRecord())
            try prepared.append(["type":"custom","customType":"pi-app.native.state.v1","data":try savedState()])
            try prepared.publish(to:destination); journal=prepared; ephemeral=false; keepRequested=false
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        event("side.kept")
        return ["accepted":true,"sessionId":JSON(id),"path":JSON(destination.path),"ephemeral":false]
    }
}
