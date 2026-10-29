import Foundation

/// Reconciliation only. Opening a family never schedules an accepted turn or
/// re-invokes a control/work tool. Parent acceptance is the authority; child
/// terminals, receipt projections and context rows are evidence, not commands.
enum AgentFamilyRecovery {
    static func recover(state: inout SubagentJournalState, parent: SessionJournal, owner: String, directory: URL,
                        accounting: inout AttemptAccounting, spend: inout SessionSpend, costPaused: Bool = false, context: [ChatMessage] = []) throws {
        guard state.origin == nil, state.family?.ownerID == owner else { return }
        func write<T: Encodable>(_ kind: String, _ data: T) throws {
            let row: JSON = ["type":"custom","customType":JSON(kind),"ownerID":JSON(owner),"data":try subagentJSON(data)]
            var next = state; try next.consume(row,sessionID:owner)
            try parent.append(row,flush:true); state = next
        }
        func charge(_ kind: String, _ data: JSON) throws {
            var next = accounting, total = spend
            if try next.consume(kind:kind,data:data,spend:&total) {
                try parent.append(["type":"custom","customType":JSON(kind),"data":data],flush:true); accounting = next; spend = total
            }
        }
        // The row can be durable even when its delivery acknowledgement is not.
        for var delivery in Array(state.family!.deliveries.values) where delivery.recipientID == owner && !delivery.committed {
            if let digest = state.family!.contextRows[delivery.rowID] {
                guard digest == deliveryDigest(delivery) else { throw SubagentRecovery.damaged() }
                delivery.committed = true; try write(JournalRecordKind.agentDelivery,delivery)
            }
        }
        let plans = (state.callOrder ?? []).compactMap { state.plans[$0] }
        for plan in plans {
            let childID = plan.origin.link.childSessionID
            guard state.family!.latest(childID) != nil else { continue }
            let url = directory.appendingPathComponent(try identity(JSON(childID)) + ".jsonl")
            guard within(canonical(url.path),canonical(directory.path)) else { throw SubagentRecovery.damaged() }
            var childState = SubagentJournalState(), childAccounting = AttemptAccounting(), childSpend = SessionSpend()
            var childRows: [String:ChatMessage] = [:], child: SessionJournal?, bytes: UInt64 = 0, markerOnly = true
            var seedReference: JSON?, orderedRows: [ChatMessage] = []
            var exists = FileManager.default.fileExists(atPath:url.path)
            let completed = state.family!.turns.values.contains { $0.childID == childID && ($0.status == .completed || $0.status == .outputLimited) }
            let dispatched = accounting.attempts.values.contains { $0.admission?["sourceSessionId"].text == childID && $0.admission?["state"].text == "dispatched" }
            guard exists || !completed && !dispatched else {
                throw AgentError("subagent_recovery", "A child journal is missing after possible execution. Restore it before continuing; no accepted work was restarted.")
            }
            if !exists, plan.origin.taskName != nil {
                // A v4 publication cut off before file creation can publish
                // its accepted history on reopen. It still never executes.
                guard var binding = parent.binding else { throw SubagentRecovery.damaged() }
                binding["model"] = JSON(plan.origin.model.model)
                child = try SessionJournal(url:url,id:childID,cwd:directory,binding:binding,create:true,managedChild:true)
                try child!.promoteToCodex(managedChild:true)
                try child!.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(plan.origin)])
                exists = true
            }
            if exists {
                try SessionJournal.verifyManagedChild(url:url,id:childID)
                let reader = try JournalRecordReader(url)
                while let row = try reader.next() {
                    if row["type"].text != "session", !JournalRecordKind.isMarker(row["customType"].text) { markerOnly = false }
                    try childState.consume(row,sessionID:childID)
                    if let kind = row["customType"].text { try childAccounting.consume(kind:kind,data:row["data"],spend:&childSpend) }
                    if row["type"].text == "message", let id = row["id"].text { let message = try ChatMessage(id:id,pi:row["message"]); childRows[id] = message; orderedRows.append(message) }
                    if row["customType"].text == JournalRecordKind.agentForkSeed {
                        guard plan.forkSeed?.reference == row["data"] else { throw SubagentRecovery.damaged() }
                        seedReference = row["data"]
                    }
                }
                bytes = reader.size
                guard childState.origin?.matchesAccepted(plan.origin) == true || childState.origin == nil && markerOnly else { throw SubagentRecovery.damaged() }
            }
            let seedComplete = plan.forkSeed.map { $0.complete(rows:orderedRows,reference:seedReference) } ?? true
            guard seedComplete || !completed && !dispatched else { throw SubagentRecovery.damaged() }
            func childAppend(_ row: JSON, id: String? = nil) throws {
                guard exists else { return }
                if child == nil {
                    child = try SessionJournal(url:url,id:childID,cwd:directory,binding:nil,create:false)
                    guard child?.size == bytes else { throw SubagentRecovery.damaged() }
                    if plan.origin.taskName != nil { try child!.promoteToCodex(managedChild:true) }
                    else { try child!.promoteToSteering(managedChild:true) }
                }
                let recordID = id ?? UUID().uuidString
                var projection = row; projection["id"] = JSON(recordID)
                try childState.consume(projection,sessionID:childID); try child!.append(row,id:recordID,flush:true)
            }
            func childWrite<T: Encodable>(_ kind: String, _ data: T) throws {
                try childAppend(["type":"custom","customType":JSON(kind),"ownerID":JSON(owner),"data":try subagentJSON(data)])
            }
            if exists, childState.origin == nil { try childWrite(JournalRecordKind.subagentOrigin,plan.origin) }
            // Finish a partial publication, never its accepted execution. The
            // original turn below still seals not-executed (also during a cost
            // pause); later explicit follow-ups can use the complete history.
            // Keep the seed before child turns/messages, as requirePublished expects.
            if exists, !seedComplete, let seed = plan.forkSeed {
                guard seedReference == nil || seedReference == seed.reference else { throw SubagentRecovery.damaged() }
                // A missing/changed parent boundary cannot supply authority.
                // Seal nonexecution below and leave the publication fence shut.
                if let messages = seed.rebuild(from:context,before:plan.origin.link.call.assistantMessageID) {
                    guard orderedRows.count <= messages.count,
                          orderedRows.map(\.id) == Array(seed.ids.prefix(orderedRows.count)),
                          zip(orderedRows,messages).allSatisfy({ saved, original in saved.content == original.content && saved.userInput == nil && saved.nativeInherited == original.nativeInherited }) else { throw SubagentRecovery.damaged() }
                    if messages.contains(where: { $0.nativeMailboxCut != nil || $0.nativeAgentCallCancellation != nil }) {
                        if child == nil { child = try SessionJournal(url:url,id:childID,cwd:directory,binding:nil,create:false) }
                        try child!.promoteToMailboxCut(managedChild:true)
                    }
                    for message in messages.dropFirst(orderedRows.count) { try childAppend(["type":"message","message":message.pi],id:message.id) }
                    try childWrite(JournalRecordKind.context,["ids":JSON.array(seed.ids.map(JSON.string))])
                    try childWrite(JournalRecordKind.agentForkSeed,seed.reference)
                }
            }
            // An owner commit may precede the recipient mirror and any of
            // its rows. Repair those before delivery reconciliation or sealing.
            for commit in (state.cuts?.commits.values.map { $0 } ?? []).filter({ $0["recipientSessionId"].text == childID }) {
                guard exists, let preparation = childState.cuts?.preparations[commit["cutId"].text ?? ""] else { throw SubagentRecovery.damaged() }
                try MailboxCutJournal.validate(commit,preparation:preparation,accounting:accounting)
                let rows = try MailboxCutJournal.rows(preparation,commit:commit)
                if child == nil {
                    child = try SessionJournal(url:url,id:childID,cwd:directory,binding:nil,create:false)
                    guard child?.size == bytes else { throw SubagentRecovery.damaged() }
                }
                try child!.promoteToMailboxCut(managedChild:true)
                if childState.cuts?.commits[commit["cutId"].text ?? ""] == nil { try childWrite(JournalRecordKind.agentCutCommitted,commit) }
                for row in rows {
                    if let saved = childRows[row.id] { guard saved.pi == row.pi else { throw SubagentRecovery.damaged() } }
                    else {
                        try childAppend(["type":"message","message":row.pi],id:row.id)
                        childRows[row.id] = row; orderedRows.append(row)
                    }
                }
            }
            // Validate every mirror against its immutable owning attempt/turn.
            for (id, entry) in childAccounting.attempts {
                guard let cost = entry.contribution else { continue }
                guard let admission = accounting.attempts[id]?.admission,
                      admission["state"].text == "dispatched", admission["sourceSessionId"].text == childID,
                      admission["budgetOwnerSessionId"].text == owner, admission["delegationId"].text == plan.origin.link.delegationID,
                      let scope = try? JSONDecoder().decode(RequestScope.self,from:admission["scope"].data()), scope.valid,
                      scope.delegation == plan.origin.link else { throw SubagentRecovery.damaged() }
                if let number = scope.childTurn {
                    guard let turn = state.family!.turns[AgentTurnTarget(childID:childID,turn:number).id], turn.acceptsParentExecution(scope.parentExecutionID) else { throw SubagentRecovery.damaged() }
                }
                if let update = try FamilyCharge.merge(cost,into:accounting.attempts[id],revision:accounting.revision,
                    child:.init(accepted:plan.origin,observed:childState.origin),failure:SubagentRecovery.damaged()) {
                    try charge(update.kind,update.data)
                }
            }
            for entry in accounting.attempts.values where entry.admission?["sourceSessionId"].text == childID {
                guard let cost = entry.contribution, let id = cost["attemptId"].text else { continue }
                if let update = try FamilyCharge.merge(cost,into:childAccounting.attempts[id],revision:childAccounting.revision,
                    admission:entry.admission,child:.init(accepted:plan.origin,observed:childState.origin),failure:SubagentRecovery.damaged()) {
                    try childWrite(update.kind,update.data)
                    try childAccounting.consume(kind:update.kind,data:update.data,spend:&childSpend)
                }
            }
            // Owner acceptance may precede the child-side report receipt mirror.
            for op in state.family!.operations.values where op.key.parentSessionID == childID {
                guard let sender = childRows[op.key.assistantMessageID], sender.role == "assistant",
                      sender.content.contains(where: { $0["type"].text == "toolCall" && $0["id"].text == op.key.toolCallID }) else { throw SubagentRecovery.damaged() }
                if childState.family?.operations[op.id] == nil { try childWrite(JournalRecordKind.agentOperation,op) }
            }
            for var delivery in Array(state.family!.deliveries.values) where delivery.recipientID == childID && !delivery.committed {
                if let digest = childState.family?.contextRows[delivery.rowID] {
                    guard digest == deliveryDigest(delivery) else { throw SubagentRecovery.damaged() }
                    delivery.committed = true; try write(JournalRecordKind.agentDelivery,delivery)
                    try childWrite(JournalRecordKind.agentDelivery,delivery)
                }
            }
            let turns = state.family!.turns.values.filter { $0.childID == childID }.sorted { $0.turn < $1.turn }
            for original in turns {
                if costPaused, seedComplete, !(state.family!.run?.heldChildren.contains(childID) ?? false),
                   !original.status.terminal, !(childState.family?.turns[original.id]?.status.terminal ?? false) {
                    // Paused at the family's cost limit: the turn is held for
                    // Resume, not interrupted. A run cut off mid-pause keeps
                    // its place in the queue; its child mirror agrees. A
                    // durable reader Stop instead recovers a terminal outcome.
                    var held = original; held.status = .queued; held.result = nil
                    if held != original { try write(JournalRecordKind.agentTurnState,held) }
                    if let mirror = childState.family?.turns[original.id], mirror != held {
                        for step in held.mirrorSteps(from:mirror) { try childWrite(JournalRecordKind.agentTurnState,step) }
                    }
                    continue
                }
                var terminal = original
                // A Resume records continuations in the owner first; a turn
                // sealed (by Stop or quit) before its child ran never reached
                // the mirror. Catch the mirror up before any terminal record.
                if let mirror = childState.family?.turns[original.id], !mirror.status.terminal,
                   (mirror.continuations ?? []) != (original.continuations ?? []) {
                    var queued = original; queued.status = .queued; queued.result = nil
                    for step in queued.mirrorSteps(from:mirror) where step != mirror { try childWrite(JournalRecordKind.agentTurnState,step) }
                }
                if var evidence = childState.family?.turns[original.id], evidence.status.terminal {
                    // An older helper may seal a child before its accepted
                    // turn was mirrored. The owner's acceptance retains effort.
                    if evidence.effort == nil { evidence.effort = original.effort }
                    guard evidence.executionID == original.executionID, evidence.parentExecutionID == original.parentExecutionID,
                          let result = evidence.result, result.status == evidence.status,
                          result.metadata["sessionId"].text == childID, result.metadata["delegationId"].text == plan.origin.link.delegationID,
                          result.metadata["budgetOwnerSessionId"].text == owner,
                          result.metadata["resultRef"]["messageIds"].list.allSatisfy({ $0.text.map { childRows[$0] != nil } == true }) else { throw SubagentRecovery.damaged() }
                    if original.status.terminal { guard original == evidence else { throw SubagentRecovery.damaged() } }
                    terminal = evidence
                } else if !original.status.terminal {
                    let dispatched = accounting.attempts.values.contains { $0.admission?["sourceSessionId"].text == childID && $0.admission?["scope"]["childTurn"].int == original.turn && $0.admission?["state"].text == "dispatched" }
                    terminal.status = dispatched || original.status == .running || original.status == .stopping ? .interrupted : .notExecuted
                    if terminal.taskName != nil, state.family!.run?.stoppedByUser == true || state.family!.run?.heldChildren.contains(childID) == true { terminal.interruptedBy = "the user" }
                    terminal.result = SubagentToolResult(plan:plan,status:terminal.status,error:AgentError("subagent_interrupted", "The helper stopped before a sealed result. Accepted work was not replayed; inspect effects before following up."),accountingRevision:accounting.revision,began:dispatched)
                    terminal.normalizeResult()
                    try childWrite(JournalRecordKind.agentTerminal,terminal)
                } else {
                    // Publication/open can fail after the queued journal was
                    // created. Preserve the owner's sealed nonexecution result
                    // in that child too; a cold viewer must not remain queued.
                    try childWrite(JournalRecordKind.agentTerminal,terminal)
                }
                if !original.status.terminal { try write(JournalRecordKind.agentTerminal,terminal) }
                let resultID = "result:" + original.id
                if state.family!.messages[resultID] == nil {
                    let message = AgentFamilyMessage.resultEvent(terminal,task:plan.origin.description,sequence:state.family!.sequence + 1)
                    try write(JournalRecordKind.agentMessage,message)
                }
            }
            // Steering for a held turn stays pending; it is delivered after Resume.
            for var message in state.family!.messages.values.sorted(by: { $0.sequence < $1.sequence }) where (message.recipientChildID ?? (message.author == "parent" ? message.childID : "")) == childID && message.queueOnly != true &&
                (message.disposition == "pending" || message.disposition == "not_delivered_interrupted") {
                if message.disposition == "pending" {
                    if costPaused, state.family!.turns[AgentTurnTarget(childID:childID,turn:message.turn).id]?.status.terminal == false { continue }
                    message.disposition = "not_delivered_interrupted"; try write(JournalRecordKind.agentMessage,message)
                }
                if message.type != nil, state.family!.turns[AgentTurnTarget(childID:childID,turn:message.turn).id]?.inputID == message.id { continue }
                let notice = AgentFamilyMessage.undelivered(message,sequence:state.family!.sequence + 1,legacyText:"Parent message \(message.id) is retained but was not delivered before interruption.")
                if state.family!.messages[notice.id] == nil { try write(JournalRecordKind.agentMessage,notice) }
            }
            // Migration copies contain private bodies too; remove only this
            // exact managed sibling while holding/validating family authority.
            try? FileManager.default.removeItem(at:url.appendingPathExtension("promotion"))
        }
        for entry in Array(accounting.attempts.values) {
            if entry.contribution == nil, var admission = entry.admission, admission["state"].text == "admitted" {
                admission["state"] = "not_dispatched"; admission["accountingRevision"] = JSON(accounting.revision + 1)
                try charge(JournalRecordKind.budgetAttempt,admission)
            }
        }
        if var run = state.family!.run, !run.closed { run.closed = true; try write(JournalRecordKind.familyRun,run) }
    }
    /// A parked Stop has no live runner. The host calls this only when no
    /// retained writer exists, under its runtime gate. A subsequent reader
    /// retires pause/tool state from this terminal authority during restore.
    static func mirrorTerminal(_ turn: AgentChildTurn, plan: SubagentPlan, directory: URL) throws {
        let id = try identity(JSON(turn.childID)), url = directory.appendingPathComponent(id + ".jsonl")
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        try SessionJournal.verifyManagedChild(url:url,id:id)
        let journal = try SessionJournal(url:url,id:id,cwd:directory,binding:nil,create:false)
        let reader = try JournalRecordReader(url)
        var state = SubagentJournalState()
        while let row = try reader.next() { try state.consume(row,sessionID:id) }
        guard state.origin?.matchesAccepted(plan.origin) == true else { throw SubagentRecovery.damaged() }
        if turn.taskName != nil { try journal.promoteToCodex(managedChild:true) }
        else { try journal.promoteToSteering(managedChild:true) }
        func write(_ kind: String, _ value: AgentChildTurn) throws {
            let row: JSON = ["type":"custom","customType":JSON(kind),"ownerID":JSON(plan.origin.link.budgetOwnerSessionID),"data":try subagentJSON(value)]
            try state.consume(row,sessionID:id); try journal.append(row,flush:true)
        }
        if let saved = state.family?.turns[turn.id], !saved.status.terminal {
            var queued = turn; queued.status = .queued; queued.result = nil
            for step in queued.mirrorSteps(from:saved) where step != saved { try write(JournalRecordKind.agentTurnState,step) }
        }
        if state.family?.turns[turn.id] != turn { try write(JournalRecordKind.agentTerminal,turn) }
    }
    static func deliveryDigest(_ delivery: AgentDelivery) -> String { sha256(Data(JSON.array([textBlock(delivery.text)]).encoded().utf8)) }
}

extension AgentChildTurn {
    /// The records that bring a child's mirror of this (unsealed) turn up to
    /// the owner's: one per continuation it has not seen, then the status.
    func mirrorSteps(from mirror: AgentChildTurn) -> [AgentChildTurn] {
        let known = mirror.continuations ?? [], all = continuations ?? []
        guard all.count >= known.count, Array(all.prefix(known.count)) == known else { return [self] }
        var steps: [AgentChildTurn] = [], step = self
        for count in stride(from:known.count + 1, through:all.count, by:1) {
            step.continuations = Array(all.prefix(count)); step.status = .queued; step.result = nil; steps.append(step)
        }
        if steps.last != self { steps.append(self) }
        return steps
    }
    mutating func normalizeResult() {
        guard result != nil else { return }
        result?.envelope["version"] = JSON(taskName == nil ? 3 : 4); result?.envelope["child_id"] = JSON(childID); result?.envelope["turn"] = JSON(turn)
        result?.metadata["version"] = 2; result?.metadata["turn"] = JSON(turn); result?.metadata["executionID"] = JSON(executionID)
        result?.metadata["parentAssistantMessageId"] = JSON(call.assistantMessageID); result?.metadata["toolCallId"] = JSON(call.toolCallID)
        if let effort { result?.envelope["effort"] = JSON(effort); result?.metadata["effort"] = JSON(effort) }
        result?.messageID = nil
    }
}
extension AgentFamilyMessage {
    static func undelivered(_ message: Self, sequence: Int, legacyText: String) -> Self {
        var notice = Self(id:"undelivered:" + message.id,sequence:sequence,childID:message.childID,turn:message.turn,author:"subagent",kind:"not_delivered_interrupted",text:legacyText,task:message.task,epoch:message.epoch,replyTo:message.id)
        if message.type != nil {
            notice.type = "MESSAGE"; notice.sender = message.recipient; notice.recipient = "/root"; notice.senderChildID = message.recipientChildID
            notice.text = "A task for " + (message.recipient ?? "this agent") + " was retained but not delivered before the turn ended."
        }
        return notice
    }
    static func resultEvent(_ turn: AgentChildTurn, task: String, sequence: Int) -> Self {
        if let name = turn.taskName {
            let full = turn.result?.envelope["text"].text ?? "", reason = turn.result?.envelope["error"]["message"].text ?? "The turn ended before a complete answer."
            let text: String
            switch turn.status {
            case .completed: text = full
            case .outputLimited: text = full + "\n\n(The answer stopped at the model's output limit.)"
            case .notExecuted: text = turn.interruptedBy == "the user" ? "Agent stopped by the user." : "Agent did not start: " + reason
            case .failed: text = "Agent errored: " + reason + "\n\nThis agent's turn failed. If you still need this agent, use followup_task to give it another task."
            default:
                if turn.interruptedBy == "the user" { text = "Agent stopped by the user." }
                else if let who = turn.interruptedBy { text = "Agent interrupted by " + who + "." }
                else { text = "Agent errored: " + reason + "\n\nThis agent's turn failed. If you still need this agent, use followup_task to give it another task." }
            }
            var event = Self(id:"result:" + turn.id,sequence:sequence,childID:turn.childID,turn:turn.turn,author:"subagent",kind:"result",text:text,task:task,epoch:turn.epoch)
            event.type = "FINAL_ANSWER"; event.sender = name; event.recipient = "/root"; event.senderChildID = turn.childID
            event.result = turn.result?.envelope.removing(["text"])
            if turn.interruptedBy == "/root", [.interrupted,.cancelled,.notExecuted].contains(turn.status) { event.disposition = "suppressed" }
            return event
        }
        let full = turn.result?.envelope["text"].text ?? "", text = SubagentToolResult.bounded(full,bytes:8192)
        var event = Self(id:"result:" + turn.id,sequence:sequence,childID:turn.childID,turn:turn.turn,author:"subagent",kind:"result",text:text,task:task,epoch:turn.epoch)
        event.result = turn.result?.envelope.removing(["text"]); event.result?["text_truncated"] = JSON(text.utf8.count < full.utf8.count)
        return event
    }
}
