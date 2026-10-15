import Foundation

/// Reconciliation only. Opening a family never schedules an accepted turn or
/// re-invokes a control/work tool. Parent acceptance is the authority; child
/// terminals, receipt projections and context rows are evidence, not commands.
enum AgentFamilyRecovery {
    static func recover(state: inout SubagentJournalState, parent: SessionJournal, owner: String, directory: URL,
                        accounting: inout AttemptAccounting, spend: inout SessionSpend) throws {
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
            let exists = FileManager.default.fileExists(atPath:url.path)
            let completed = state.family!.turns.values.contains { $0.childID == childID && ($0.status == .completed || $0.status == .outputLimited) }
            let dispatched = accounting.attempts.values.contains { $0.admission?["sourceSessionId"].text == childID && $0.admission?["state"].text == "dispatched" }
            guard exists || !completed && !dispatched else {
                throw AgentError("subagent_recovery", "A child journal is missing after possible execution. Restore it before continuing; no accepted work was restarted.")
            }
            if exists {
                try SessionJournal.verifyManagedChild(url:url,id:childID)
                let reader = try JournalRecordReader(url)
                while let row = try reader.next() {
                    if row["type"].text != "session", !JournalRecordKind.isMarker(row["customType"].text) { markerOnly = false }
                    try childState.consume(row,sessionID:childID)
                    if let kind = row["customType"].text { try childAccounting.consume(kind:kind,data:row["data"],spend:&childSpend) }
                    if row["type"].text == "message", let id = row["id"].text { childRows[id] = try ChatMessage(id:id,pi:row["message"]) }
                }
                bytes = reader.size
                guard childState.origin?.matchesAccepted(plan.origin) == true || childState.origin == nil && markerOnly else { throw SubagentRecovery.damaged() }
            }
            func childWrite<T: Encodable>(_ kind: String, _ data: T) throws {
                guard exists else { return }
                if child == nil {
                    child = try SessionJournal(url:url,id:childID,cwd:directory,binding:nil,create:false)
                    guard child?.size == bytes else { throw SubagentRecovery.damaged() }
                    try child!.promoteToSteering(managedChild:true)
                }
                let row: JSON = ["type":"custom","customType":JSON(kind),"ownerID":JSON(owner),"data":try subagentJSON(data)]
                try childState.consume(row,sessionID:childID); try child!.append(row,flush:true)
            }
            if exists, childState.origin == nil { try childWrite(JournalRecordKind.subagentOrigin,plan.origin) }
            // Validate every mirror against its immutable owning attempt/turn.
            for (id, entry) in childAccounting.attempts {
                guard let cost = entry.contribution else { continue }
                guard let admission = accounting.attempts[id]?.admission,
                      admission["state"].text == "dispatched", admission["sourceSessionId"].text == childID,
                      admission["budgetOwnerSessionId"].text == owner, admission["delegationId"].text == plan.origin.link.delegationID,
                      let scope = try? JSONDecoder().decode(RequestScope.self,from:admission["scope"].data()), scope.valid,
                      scope.delegation == plan.origin.link,
                      cost["sourceSessionId"] == admission["sourceSessionId"], cost["budgetOwnerSessionId"] == admission["budgetOwnerSessionId"],
                      cost["delegationId"] == admission["delegationId"] else { throw SubagentRecovery.damaged() }
                if let number = scope.childTurn {
                    guard let turn = state.family!.turns[AgentTurnTarget(childID:childID,turn:number).id], turn.parentExecutionID == scope.parentExecutionID else { throw SubagentRecovery.damaged() }
                }
                let prior = accounting.attempts[id]?.contribution
                if prior == nil || prior?["unreported"].int == 1 && cost["reported"].int == 1 {
                    var value = cost; value["accountingRevision"] = JSON(accounting.revision + 1)
                    try charge(prior == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate,value)
                }
            }
            for entry in accounting.attempts.values where entry.admission?["sourceSessionId"].text == childID {
                guard let cost = entry.contribution, let id = cost["attemptId"].text else { continue }
                let prior = childAccounting.attempts[id]?.contribution
                if prior == nil || prior?["unreported"].int == 1 && cost["reported"].int == 1 { try childWrite(prior == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate,cost) }
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
                var terminal = original
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
            for var message in state.family!.pending(author:"parent") where message.childID == childID {
                message.disposition = "not_delivered_interrupted"; try write(JournalRecordKind.agentMessage,message)
                let notice = AgentFamilyMessage(id:"undelivered:" + message.id,sequence:state.family!.sequence + 1,childID:childID,turn:message.turn,author:"subagent",kind:"not_delivered_interrupted",text:"Parent message \(message.id) is retained but was not delivered before interruption.",task:message.task,epoch:message.epoch,replyTo:message.id)
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
    static func deliveryDigest(_ delivery: AgentDelivery) -> String { sha256(Data(JSON.array([textBlock(delivery.payload.encoded())]).encoded().utf8)) }
}

extension AgentChildTurn {
    mutating func normalizeResult() {
        guard result != nil else { return }
        result?.envelope["version"] = 3; result?.envelope["child_id"] = JSON(childID); result?.envelope["turn"] = JSON(turn)
        result?.metadata["version"] = 2; result?.metadata["turn"] = JSON(turn); result?.metadata["executionID"] = JSON(executionID)
        result?.metadata["parentAssistantMessageId"] = JSON(call.assistantMessageID); result?.metadata["toolCallId"] = JSON(call.toolCallID)
        if let effort { result?.envelope["effort"] = JSON(effort); result?.metadata["effort"] = JSON(effort) }
        result?.messageID = nil
    }
}
extension AgentFamilyMessage {
    static func resultEvent(_ turn: AgentChildTurn, task: String, sequence: Int) -> Self {
        let full = turn.result?.envelope["text"].text ?? "", text = SubagentToolResult.bounded(full,bytes:8192)
        var event = Self(id:"result:" + turn.id,sequence:sequence,childID:turn.childID,turn:turn.turn,author:"subagent",kind:"result",text:text,task:task,epoch:turn.epoch)
        event.result = turn.result?.envelope.removing(["text"]); event.result?["text_truncated"] = JSON(text.utf8.count < full.utf8.count)
        return event
    }
}
