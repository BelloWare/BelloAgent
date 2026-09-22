import Foundation

extension AgentSession {
    /// Presentation rows have their own append-only records and stable location.
    /// They never enter replay context, task reply counts or usage accounting.
    func appendPresentation(_ message: ChatMessage) throws {
        var message = message
        message.replayEligible = false
        message.timestamp = message.timestamp ?? Date().timeIntervalSince1970 * 1000
        message.taskRootID = taskRootID; message.taskExecutionID = activeTaskPresentation?.executionID
        message.turn = currentTurnID
        try journal?.append(["type":"message","message":message.pi],id:message.id,flush:journalFlushesEachRecord)
        history.append(message); visible.append(message); invalidateDisplay(message.id)
        for attempt in message.requestAttemptIDs ?? [] { pendingRequestLinks[attempt, default: []].append(message.id) }
    }
    func updatePresentation(_ message: ChatMessage, persist: Bool) throws {
        guard let index = history.firstIndex(where: { $0.id == message.id }), ["execution","requestLedger"].contains(history[index].kind ?? "") else { return }
        if persist { try journal?.append(["type":"custom","customType":"pi-app.presentation.update.v1","data":["id":JSON(message.id)],"message":message.pi],flush:journalFlushesEachRecord) }
        let oldAttempts = Set(history[index].requestAttemptIDs ?? [])
        for attempt in message.requestAttemptIDs ?? [] where !oldAttempts.contains(attempt) { pendingRequestLinks[attempt, default: []].append(message.id) }
        history[index] = message
        if let index = visible.firstIndex(where: { $0.id == message.id }) { visible[index] = message }
        invalidateDisplay(message.id)
    }
    func startResponseLedger(_ observation: RequestObservation) {
        guard observation.phase == "awaiting", observation.purpose != "compaction", let partialID,
              partialLedgerID == nil else { return }
        var message = ChatMessage(role:"system",content:[])
        message.kind = "requestLedger"; message.detail = "Request dispatched"
        message.presentationSourceID = partialID; message.requestAttemptIDs = [observation.attemptID]
        message.responseTimeline = ResponseTimeline()
        do { try appendPresentation(message); partialLedgerID = message.id }
        catch { partialTimeline.coverage = "partial" }
    }
    func saveResponseLedger(persist: Bool, terminal: String? = nil) {
        guard let id = partialLedgerID, var row = history.first(where: { $0.id == id }) else { return }
        row.responseTimeline = partialTimeline
        if let terminal { row.responseTimeline?.finish(terminal); row.detail = "Request \(terminal)" }
        do { try updatePresentation(row,persist:persist) } catch { partialTimeline.coverage = "partial" }
    }
    func operationStatus(_ text: String, terminal: String? = nil, persist: Bool = true) {
        guard let id = compactionPresentationID, var row = history.first(where: { $0.id == id }) else { return }
        var timeline = row.responseTimeline ?? ResponseTimeline()
        presentationOrdinal += 1
        let event = ResponsePartEvent(attemptID:id,ordinal:presentationOrdinal,itemID:id,kind:"status",update:"begin",text:text,observedAt:nowMS(),evidence:"local")
        timeline.consume(event)
        if let terminal { timeline.finish(terminal) }
        row.responseTimeline=timeline; row.detail="Compaction · " + text
        do { try updatePresentation(row,persist:persist) } catch { }
    }
    func showToolInvocation(_ call: ToolCall) {
        var row = ChatMessage(role:"system",content:[])
        row.kind="execution"; row.detail="Tool started · " + call.name
        row.requestAttemptIDs=currentAttemptIDs
        var timeline = ResponseTimeline(); presentationOrdinal += 1
        timeline.consume(ResponsePartEvent(attemptID:currentAttemptIDs.first ?? row.id,ordinal:presentationOrdinal,itemID:row.id,kind:"status",update:"begin",text:"Invocation started: \(call.name)",callID:call.id,name:call.name,observedAt:nowMS(),evidence:"local"))
        timeline.finish("recorded"); row.responseTimeline=timeline
        try? appendPresentation(row)
        event("tool_execution_start")
    }
}
