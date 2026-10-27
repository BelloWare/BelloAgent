import Foundation

extension AgentSteeringCoordinator {
    func signal(_ owner: String) -> AgentWakeSignal {
        if let signal = signals[owner] { return signal }; let signal = AgentWakeSignal(); signals[owner] = signal; return signal
    }
    func wake(_ owner: String) async { await signal(owner).pulse() }
    func report(_ call: ToolCall, key: SubagentCallKey, child: AgentSession) async throws -> JSON {
        try SubagentSteeringContract.validate(call.name,call.arguments)
        guard call.name == "subagent_report", let lease = await child.agentLease,
              let job = jobs[lease.id], job.child === child, !job.cancelled, !job.sealed else { throw AgentError("tool_unavailable", "Reporting requires an active managed child") }
        let lock = gate(job.owner.id); try await lock.acquire()
        do {
            let digest = sha256(Data((call.name + call.arguments.encoded()).utf8))
            if let receipt = try await job.owner.agentReceipt(key,digest:digest) { await lock.release(); return receipt }
            let state = await job.owner.agentState()
            try validateReply(call.arguments["reply_to"].text,child:child.id,author:"parent",state:state)
            let message = AgentFamilyMessage(id:UUID().uuidString,sequence:state.sequence + 1,childID:child.id,turn:lease.turn,author:"subagent",kind:call.arguments["kind"].text!,text:call.arguments["message"].text!,task:job.plan.origin.description,epoch:lease.currentEpoch,replyTo:call.arguments["reply_to"].text)
            let receipt: JSON = ["version":3,"accepted":true,"route":"report","child_id":JSON(child.id),"turn":JSON(lease.turn),"message_id":JSON(message.id)]
            let op = try await job.owner.acceptAgentOperation(.init(key:key,digest:digest,receipt:receipt,message:message,epoch:lease.currentEpoch),generation:lease.currentGeneration)
            // Child mirror repairs a lost sender receipt without reporting again.
            try await child.appendAgentRecord(JournalRecordKind.agentOperation,op,owner:job.owner.id)
            await lock.release(); await signal(job.owner.id).pulse(); return receipt
        } catch { await lock.release(); throw error }
    }
    /// All calls here run only at complete request/tool boundaries. The per-owner
    /// gate serializes send routing, child sealing, and the final parent fence.
    func boundary(_ session: AgentSession, final: Bool) async throws -> Bool {
        var compacted = false
        if let lease = await session.agentLease {
            while true {
                try Task.checkCancellation()
                guard let job = jobs[lease.id], job.child === session else { throw SubagentRecovery.damaged() }
                let lock = gate(job.owner.id); try await lock.acquire()
                do {
                    if final, jobs[lease.id]?.sealed == true { await lock.release(); return false }
                    let delivery = try await deliver(owner:job.owner,recipient:session,childTurn:lease,canCompact:!compacted,deferMail:final && lease.taskName != nil)
                    if delivery != .compact {
                        if final, delivery == .none {
                            // A cost-limit pause defers the seal: the runner parks the
                            // turn and Resume finds its answer already in place.
                            if paused.contains(job.owner.id) { throw CancellationError() }
                            var terminal = jobs[lease.id] ?? job
                            terminal.turn.result = await session.agentResult(lease,plan:job.plan,cancelled:terminal.cancelled)
                            terminal.turn.status = terminal.turn.result!.status
                            try await seal(job:terminal,child:session)
                        }
                        await lock.release(); return delivery == .delivered
                    }
                    await lock.release()
                } catch { await lock.release(); throw error }
                // A provider request must not hold up a sibling's Stop. The
                // next pass selects messages again under the family gate.
                try await session.compactContext(reason:"agent-delivery"); compacted = true
            }
        }
        guard await session.subagents.family != nil else { return false }
        let lock = gate(session.id), wake = signal(session.id)
        while true {
            try Task.checkCancellation()
            // Paused at the cost limit: the run ends here, holding its family.
            if await session.costPaused { throw AgentSession.costHoldError }
            let revision = await wake.revision
            try await lock.acquire()
            do {
                let delivery = try await deliver(owner:session,recipient:session,childTurn:nil,canCompact:!compacted)
                if delivery == .delivered { await lock.release(); return true }
                if delivery == .compact { await lock.release() }
                else {
                    if !final { await lock.release(); return false }
                    if await session.agentDeliveryHeld {
                        await session.setFamilyWaiting(true)
                        await lock.release(); await wake.wait(after:revision); continue
                    }
                    let busy = jobs.values.contains { $0.owner === session }
                    if !busy {
                        let ready = try await session.closeAgentFamilyFence()
                        await lock.release(); return !ready
                    }
                    await session.setFamilyWaiting(true)
                    await lock.release()
                    if await session.hasAgentUserSteering { return true }
                    await wake.wait(after:revision)
                    continue
                }
            } catch { await lock.release(); throw error }
            try await session.compactContext(reason:"agent-delivery"); compacted = true
        }
    }
    func seal(job original: Job, child: AgentSession?) async throws {
        var job = original
        if let current = await job.owner.agentState().turns[job.turn.id] { job.turn.interruptedBy = current.interruptedBy }
        job.turn.normalizeResult()
        if jobs[job.turn.id]?.sealed == true { return }
        try await seal(turn:job.turn,parent:job.owner,task:job.plan.origin.description,child:child)
        jobs[job.turn.id]?.turn = job.turn; jobs[job.turn.id]?.sealed = true
    }
    /// A parked turn has no job. Its accepted Stop seals and reports through
    /// the same path; recovery catches up a closed child's mirror.
    func seal(turn proposed: AgentChildTurn, parent: AgentSession, task: String, child: AgentSession?) async throws {
        var turn = proposed
        if let current = await parent.agentState().turns[turn.id] { turn.interruptedBy = current.interruptedBy }
        let current = await parent.agentState()
        if turn.taskName != nil, current.turns[turn.id]?.status.terminal != true,
           current.run?.heldChildren.contains(turn.childID) == true || current.run?.stoppedByUser == true && [.cancelled,.interrupted,.notExecuted].contains(turn.status) { turn.interruptedBy = "the user" }
        if let child { await child.endSubagentProgress(); try await child.saveAgentTerminal(turn) }
        if await parent.agentState().turns[turn.id] != turn { try await parent.appendAgentRecord(JournalRecordKind.agentTerminal,turn) }
        let state = await parent.agentState()
        let id = "result:" + turn.id
        if state.messages[id] == nil {
            let message = AgentFamilyMessage.resultEvent(turn,task:task,sequence:state.sequence + 1)
            try await parent.appendAgentRecord(JournalRecordKind.agentMessage,message)
        }
        for var pending in state.messages.values.sorted(by: { $0.sequence < $1.sequence }) where (pending.recipientChildID ?? (pending.author == "parent" ? pending.childID : "")) == turn.childID && pending.queueOnly != true && pending.turn == turn.turn &&
            (pending.disposition == "pending" || pending.disposition == "not_delivered_interrupted") {
            if pending.disposition == "pending" {
                pending.disposition = "not_delivered_interrupted"
                try await parent.appendAgentRecord(JournalRecordKind.agentMessage,pending)
            }
            if pending.type != nil, pending.id == turn.inputID { continue }
            let current = await parent.agentState()
            let notice = AgentFamilyMessage.undelivered(pending,sequence:current.sequence + 1,legacyText:"Parent message \(pending.id) was retained but not delivered before the child stopped.")
            if current.messages[notice.id] == nil { try await parent.appendAgentRecord(JournalRecordKind.agentMessage,notice) }
        }
        await signal(parent.id).pulse()
    }
    enum AgentDeliveryResult { case none, delivered, compact }
    func deliver(owner: AgentSession, recipient: AgentSession, childTurn: AgentChildTurn?, canCompact: Bool = true, deferMail: Bool = false) async throws -> AgentDeliveryResult {
        guard !(await recipient.agentDeliveryHeld) else { return .none }
        let state = await owner.agentState()
        let pending = state.messages.values.filter { message in
            guard message.disposition == "pending" else { return false }
            if message.type != nil {
                let addressed = message.recipientChildID ?? owner.id
                guard addressed == recipient.id, !deferMail || message.queueOnly != true else { return false }
                // The task has its own durable Submission/row identity.
                if message.id == childTurn?.inputID { return false }
                return childTurn == nil || message.queueOnly == true || message.turn == childTurn?.turn
            }
            return childTurn == nil ? message.author == "subagent" : message.author == "parent" && message.childID == recipient.id && message.turn == childTurn?.turn
        }.sorted { $0.sequence < $1.sequence }
        guard !pending.isEmpty else { return .none }
        func author(_ message: AgentFamilyMessage) -> String { message.sender ?? message.childID }
        var buckets = Dictionary(grouping:pending,by:author), selected: [AgentFamilyMessage] = []
        let keys = buckets.keys.sorted(), cursor = state.deliveryCursors?[recipient.id] ?? state.run?.deliveryCursor
        let position = cursor.flatMap { value in keys.firstIndex(where: { $0 > value }) } ?? 0
        var ordered = Array(keys[position...]) + Array(keys[..<position])
        while !ordered.isEmpty {
            let key = ordered.removeFirst(); var head = buckets[key]!.removeFirst()
            if head.type != nil, head.queueOnly == true, let childTurn { head.turn = childTurn.turn }
            selected.append(head)
            if !buckets[key]!.isEmpty { ordered.append(key) }
        }
        func payload(_ events: [AgentFamilyMessage]) -> JSON {
            if events.allSatisfy({ $0.deliveryEvent != nil }) { return JSON(events.compactMap(\.deliveryEvent).map(\.envelope).joined(separator:"\n\n")) }
            // Already accepted v3 events keep their historic shape.
            return ["kind":"agent_events","version":3,"events":.array(events.map(\.event))]
        }
        // Do not mix envelope formats in a single row during v3 adoption.
        if let first = selected.first { selected = Array(selected.prefix { ($0.type != nil) == (first.type != nil) }) }
        var body = payload(selected)
        while !(try await recipient.agentPayloadFits(body,parentLane:childTurn == nil)) {
            if selected.count > 1 { selected.removeLast(); body = payload(selected); continue }
            if canCompact, await recipient.canCompact { return .compact }
            throw AgentError("coordination_limit", "Accepted agent input is held because it cannot fit this request budget; adjust context or Resume")
        }
        let ids = selected.map(\.id)
        let turns: [String:Int]? = selected.first?.type == nil ? nil : Dictionary(uniqueKeysWithValues:selected.map { ($0.id,$0.turn) })
        let existing = state.deliveries.values.first { !$0.committed && $0.recipientID == recipient.id && $0.eventIDs == ids && $0.eventTurns == turns }
        var delivery = existing ?? AgentDelivery(rowID:UUID().uuidString,recipientID:recipient.id,eventIDs:ids,payload:body,eventTurns:turns)
        if existing == nil, childTurn == nil, state.run != nil { delivery.continuation = true }
        if existing == nil { delivery.cursor = selected.last.map(author); try await owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery) }
        try await recipient.appendAgentDelivery(delivery,selected:selected)
        delivery.committed = true
        try await owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery)
        if owner !== recipient { try await recipient.appendAgentRecord(JournalRecordKind.agentDelivery,delivery,owner:owner.id) }
        await signal(owner.id).pulse(); return .delivered
    }
    func wait(_ receipt: JSON, args: JSON, parent: AgentSession) async throws -> JSON {
        let start = ContinuousClock.now
        let configuredTimeout = args["timeout_ms"].int ?? 60000
        let targets: [AgentTurnTarget]
        let waitID = receipt["wait_id"].text ?? receipt["operation_id"].text ?? ""
        let state = await parent.agentState()
        let acceptedAt = state.operations[waitID]?.acceptedAt ?? Date().timeIntervalSince1970
        let priorWait = Int(min(60000,max(0,(Date().timeIntervalSince1970-acceptedAt)*1000)))
        let timeout = max(0,configuredTimeout-priorWait)
        if let saved = state.operations[waitID]?.waitTargets { targets = saved }
        else if let child = receipt["child_id"].text, let turn = receipt["turn"].int { targets = [.init(childID:child,turn:turn)] }
        else { targets = [] }
        let wake = signal(parent.id), mode = args["mode"].text == "any" ? "any" : "all"
        while true {
            try Task.checkCancellation()
            let revision = await wake.revision, current = await parent.agentState()
            let completed = targets.filter { current.turns[$0.id]?.status.terminal == true }.count
            let held = await parent.agentDeliveryHeld
            let inbox = !held && !current.pending(author:"subagent").isEmpty
            let elapsed = start.duration(to:.now), ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let reason: String?
            if targets.isEmpty { reason = "empty" }
            // Held at the cost limit: a wait ends (it is not cut) and says so.
            else if await parent.costPaused { reason = "paused" }
            else if mode == "any" ? completed > 0 : completed == targets.count { reason = "settled" }
            else if inbox { reason = "message" }
            else if await parent.hasAgentUserSteering { reason = "steering" }
            else if ms >= timeout { reason = "timeout" }
            else { reason = nil }
            if let reason { return ["version":3,"wait_id":JSON(waitID),"wake_reason":JSON(reason),"target_count":JSON(targets.count),"settled_count":JSON(completed),"pending_count":JSON(targets.count-completed),"inbox_pending":JSON(inbox)] }
            await wake.wait(after:revision,milliseconds:max(1,timeout-ms))
        }
    }
}
