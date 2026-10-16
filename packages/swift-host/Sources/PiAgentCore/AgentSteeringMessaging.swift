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
        if let lease = await session.agentLease {
            guard let job = jobs[lease.id], job.child === session else { throw SubagentRecovery.damaged() }
            let lock = gate(job.owner.id); try await lock.acquire()
            do {
                let delivered = try await deliver(owner:job.owner,recipient:session,childTurn:lease)
                if final, !delivered {
                    // A cost-limit pause defers the seal: the runner parks the
                    // turn and Resume finds its answer already in place.
                    if paused.contains(job.owner.id) { throw CancellationError() }
                    var terminal = jobs[lease.id] ?? job
                    terminal.turn.result = await session.agentResult(lease,plan:job.plan,cancelled:terminal.cancelled)
                    terminal.turn.status = terminal.turn.result!.status
                    try await seal(job:terminal,child:session)
                }
                await lock.release(); return delivered
            } catch { await lock.release(); throw error }
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
                if try await deliver(owner:session,recipient:session,childTurn:nil) { await lock.release(); return true }
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
            } catch { await lock.release(); throw error }
        }
    }
    func seal(job original: Job, child: AgentSession?) async throws {
        var job = original; job.turn.normalizeResult()
        if jobs[job.turn.id]?.sealed == true { return }
        if let child { await child.endSubagentProgress(); try await child.saveAgentTerminal(job.turn) }
        try await job.owner.appendAgentRecord(JournalRecordKind.agentTerminal,job.turn)
        let state = await job.owner.agentState()
        let id = "result:" + job.turn.id
        if state.messages[id] == nil {
            let message = AgentFamilyMessage.resultEvent(job.turn,task:job.plan.origin.description,sequence:state.sequence + 1)
            try await job.owner.appendAgentRecord(JournalRecordKind.agentMessage,message)
        }
        for var pending in state.pending(author:"parent") where pending.childID == job.turn.childID && pending.turn == job.turn.turn {
            pending.disposition = "not_delivered_interrupted"
            try await job.owner.appendAgentRecord(JournalRecordKind.agentMessage,pending)
            let current = await job.owner.agentState()
            let notice = AgentFamilyMessage(id:"undelivered:" + pending.id,sequence:current.sequence + 1,childID:pending.childID,turn:pending.turn,author:"subagent",kind:"not_delivered_interrupted",text:"Parent message \(pending.id) was retained but not delivered before the child stopped.",task:pending.task,epoch:pending.epoch,replyTo:pending.id)
            try await job.owner.appendAgentRecord(JournalRecordKind.agentMessage,notice)
        }
        jobs[job.turn.id]?.turn = job.turn; jobs[job.turn.id]?.sealed = true
        await signal(job.owner.id).pulse()
    }
    func deliver(owner: AgentSession, recipient: AgentSession, childTurn: AgentChildTurn?) async throws -> Bool {
        guard !(await recipient.agentDeliveryHeld) else { return false }
        let state = await owner.agentState(), author = childTurn == nil ? "subagent" : "parent"
        let pending = state.pending(author:author).filter { childTurn == nil || ($0.childID == recipient.id && $0.turn == childTurn?.turn) }
        guard !pending.isEmpty else { return false }
        var selected: [AgentFamilyMessage] = []
        if childTurn != nil { selected = Array(pending.prefix(1)) }
        else {
            // Round robin between child heads; sequence order within each child.
            var buckets = Dictionary(grouping:pending,by: \.childID)
            let keys = buckets.keys.sorted()
            let position = state.run?.deliveryCursor.flatMap { cursor in keys.firstIndex(where: { $0 > cursor }) } ?? 0
            var ordered = Array(keys[position...]) + Array(keys[..<position])
            var bytes = 0
            while selected.count < 8, !ordered.isEmpty {
                let key = ordered.removeFirst(), head = buckets[key]!.first!
                // If a head cannot fit, do not pass it with a smaller later
                // message from that child. It keeps its FIFO place next time.
                guard bytes + head.text.utf8.count <= 16384 else { continue }
                buckets[key]!.removeFirst(); selected.append(head); bytes += head.text.utf8.count
                if !buckets[key]!.isEmpty { ordered.append(key) }
            }
        }
        guard !selected.isEmpty else { throw AgentError("subagent_delivery_limit", "Pending input cannot fit the agent lane") }
        var payload: JSON = ["kind":"agent_events","version":3,"events":.array(selected.map(\.event))]
        while !(try await recipient.agentPayloadFits(payload,parentLane:childTurn == nil)) {
            if selected.count > 1 { selected.removeLast(); payload["events"] = .array(selected.map(\.event)); continue }
            if await recipient.canCompact { try await recipient.compactContext(reason:"agent-delivery") }
            guard try await recipient.agentPayloadFits(payload,parentLane:childTurn == nil) else { throw AgentError("coordination_limit", "Accepted agent input is held because it cannot fit this request budget; adjust context or Resume") }
            break
        }
        let ids = selected.map(\.id)
        if childTurn == nil, (state.run?.reportContinuations ?? 0) >= 32,
           selected.contains(where: { $0.kind != "result" && $0.kind != "not_delivered_interrupted" }) {
            throw AgentMailboxPolicy.cap()
        }
        let existing = state.deliveries.values.first { !$0.committed && $0.recipientID == recipient.id && $0.eventIDs == ids }
        var delivery = existing ?? AgentDelivery(rowID:UUID().uuidString,recipientID:recipient.id,eventIDs:ids,payload:payload)
        if existing == nil, childTurn == nil, state.run != nil, (state.run?.reportContinuations ?? 0) < 32 { delivery.continuation = true }
        if existing == nil, childTurn == nil, state.run != nil { delivery.cursor = selected.last?.childID }
        if existing == nil { try await owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery) }
        try await recipient.appendAgentDelivery(delivery,selected:selected)
        delivery.committed = true
        try await owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery)
        if owner !== recipient { try await recipient.appendAgentRecord(JournalRecordKind.agentDelivery,delivery,owner:owner.id) }
        await signal(owner.id).pulse(); return true
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
