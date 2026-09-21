import Foundation

// What a session writes down and republishes: saved queue/run state,
// message appends, forks, and keeping an ephemeral side chat.

extension AgentSession {
    public func sideSeed() -> (messages:[ChatMessage], info:JSON) { (boundary,["parentSessionId":JSON(id),"cutoffEntryId":boundary.last.map { JSON($0.id) } ?? .null,"contextRevision":JSON(sha256(Data(boundary.map(\.id).joined(separator:"\n").utf8))),"capturedAt":JSON(isoNow()),"instructionRevision":appliedRevision.map { JSON($0) } ?? .null]) }
    /// Clone the complete retained journal without replaying a queued command.
    /// A running source contributes its latest complete model/tool boundary;
    /// later source records remain inspectable in the clone's original history.
    public func fork(to newID: String) throws -> JSON {
        guard !closed, let journal, !ephemeral else { throw AgentError("session_unavailable", "Save this session before forking its context") }
        _ = try identity(JSON(newID))
        guard newID != id else { throw AgentError("session_conflict", "A fork needs a new session identity") }
        let source=try journal.records(), temporary=directory.appendingPathComponent(".fork-\(UUID().uuidString).jsonl")
        let destination=directory.appendingPathComponent("fork_"+newID+".jsonl")
        var origin=sideSeed().info; origin["relationship"]="fork"
        origin["omittedIncompleteEntries"]=JSON(max(0,context.count-boundary.count))
        do {
            let prepared=try SessionJournal(url:temporary,id:newID,cwd:cwd,binding:profile.binding,create:true)
            for record in source {
                let kind=record["customType"].text ?? ""
                if ["pi-app.native.v1", "pi-app.native.state.v1", "pi-app.side-origin.v1", "pi-app.fork-origin.v1", "pi-app.context-recovery.v1"].contains(kind) { continue }
                // Branch records can contain a queued edit. Preserve the branch
                // and all message bytes, but never authorize its command twice.
                try prepared.append(record.removing(["id","parentId","timestamp","nativeState"]),id:try identity(record["id"]))
            }
            try prepared.append(["type":"custom","customType":"pi-app.native.context.v1","data":["ids":.array(boundary.map { JSON($0.id) }),"visibleIDs":.array(EditReplayPlan.forkTimeline(visible:visible.map(\.id),boundary:boundary.map(\.id)).map { JSON($0) })]])
            try prepared.append(["type":"custom","customType":"pi-app.fork-origin.v1","data":origin])
            try prepared.append(["type":"custom","customType":"pi-app.native.state.v1","data":["active":false,"queue":[],"steering":[],"commands":[],"queuePaused":false,"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode)]])
            try prepared.publish(to:destination)
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        return ["accepted":true,"sessionId":JSON(newID),"path":JSON(destination.path),"origin":origin]
    }
    func savedState(active: Bool? = nil) throws -> JSON {
        let value: JSON = ["active":JSON(active ?? (runTask != nil)),"queue":.array(queue.map(\.savedValue)),"steering":.array(steering.map(\.savedValue)),"commands":.array(Array(commands.suffix(128))),"queuePaused":JSON(queuePaused),"steeringMode":JSON(steeringMode),"followUpMode":JSON(followUpMode),"runStatus":JSON(runStatus),"errorMessage":errorMessage.map { JSON($0) } ?? .null,"timing":["modelMs":cumulativeModelMs.map { JSON($0) } ?? .null,"toolMs":cumulativeToolMs.map { JSON($0) } ?? .null]]
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
            try prepared.append(["type":"custom","customType":"pi-app.native.state.v1","data":try savedState()])
            try prepared.publish(to:destination); journal=prepared; ephemeral=false; keepRequested=false
        } catch { try? FileManager.default.removeItem(at:temporary); try? FileManager.default.removeItem(atPath:temporary.path+".lock"); throw error }
        event("side.kept")
        return ["accepted":true,"sessionId":JSON(id),"path":JSON(destination.path),"ephemeral":false]
    }
}
