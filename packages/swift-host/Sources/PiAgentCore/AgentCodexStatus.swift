import Foundation

extension AgentSteeringCoordinator {
    func codexList(_ args: JSON, owner: AgentSession) async throws -> JSON {
        let state = await owner.agentState(), saved = await owner.subagents
        let prefix = args["path_prefix"].text ?? ""
        var start = 0, high = Int.max
        if let value = args["cursor"].text {
            guard let bytes = Data(base64Encoded:value), let cursor = try? JSON.parse(bytes), cursor["owner"].text == owner.id, cursor["prefix"].text == prefix,
                  let index = cursor["index"].int, let bound = cursor["high"].int, index >= 0, bound >= index else { throw AgentError("subagent_cursor","Invalid family cursor") }
            start = index; high = bound
        }
        var members: [(String,String?)] = [("/root",nil)]
        members += (saved.callOrder ?? []).compactMap { id in
            guard let plan = saved.plans[id], let name = state.names?[plan.origin.link.childSessionID] ?? plan.origin.taskName else { return nil }
            return (name,plan.origin.link.childSessionID)
        }
        members = members.filter { $0.0.hasPrefix(prefix) }; high = min(high,members.count); start = min(start,high)
        var rows: [JSON] = [], end = start
        for (name,child) in members[start..<high] {
            var row: JSON = ["agent_name":JSON(name),"agent_status":JSON(state.run?.closed == true ? "idle" : "running")]
            if let child {
                if let turn = state.latest(child) { row["agent_status"] = JSON(codexStatus(turn,held:state.run?.heldChildren.contains(child) == true)); row["turn"] = JSON(turn.turn) }
                else { row["agent_status"] = "idle"; row["turn"] = 1 }
            }
            if JSON.array(rows + [row]).encoded().utf8.count > 15000 { break }
            rows.append(row); end += 1
        }
        let cursor: JSON = ["owner":JSON(owner.id),"prefix":JSON(prefix),"index":JSON(end),"high":JSON(high)]
        return ["agents":.array(rows),"next_cursor":end < high ? JSON(try cursor.data().base64EncodedString()) : .null]
    }
    func codexWait(_ args: JSON, caller: AgentSession) async -> String {
        let owner = await caller.budgetOwner ?? caller
        let timeout = SubagentCodexContract.waitMilliseconds(args), start = ContinuousClock.now
        let note = (args["timeout_ms"].int ?? 30000) < 10000 ? " Timeout raised to 10000 ms." : ""
        let wake = signal(owner.id)
        while true {
            let revision = await wake.revision, state = await owner.agentState()
            let answer: String?
            if await owner.costPaused { answer = "Wait interrupted by cost limit." }
            else if Task.isCancelled || state.run?.closed == true { answer = "Wait interrupted by Stop." }
            else if await caller.hasAgentUserSteering { answer = "Wait interrupted by new input." }
            else {
                let held = await caller.agentDeliveryHeld
                let names = Set(state.messages.values.filter { message in
                    guard !held, message.disposition == "pending" else { return false }
                    return message.type != nil ? (message.recipientChildID ?? owner.id) == caller.id : caller === owner ? message.author == "subagent" : message.author == "parent" && message.childID == caller.id
                }.map { $0.sender ?? state.names?[$0.childID] ?? "/root" }).sorted()
                let elapsed = start.duration(to:.now), ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                if !names.isEmpty { answer = "Wait completed: updates from " + names.joined(separator:", ") + "." }
                else if ms >= timeout { answer = "Wait timed out." }
                else { await wake.wait(after:revision,milliseconds:timeout-ms); continue }
            }
            return (answer ?? "Wait timed out.") + note
        }
    }
    func codexDetails(_ args: JSON, parent: AgentSession, cursor: Int, limit: Int) async throws -> JSON {
        let state = await parent.agentState(), plans = await parent.subagents.plans
        let child = args["childId"].text
        if let child, !plans.values.contains(where: { $0.origin.link.childSessionID == child }) { throw AgentError("agent_not_found","Agent is not in this family") }
        let kind = args["detail"].text
        let values: [JSON]
        if kind == "messages" {
            values = state.messages.values.filter { child == nil || $0.childID == child || $0.senderChildID == child || $0.recipientChildID == child }.sorted { $0.sequence < $1.sequence }.map { message in
                var row = message.deliveryEvent?.json ?? message.event
                row["disposition"] = JSON(message.disposition); row["queueOnly"] = JSON(message.queueOnly == true)
                let waiting = message.disposition == "pending" && message.queueOnly == true && message.recipientChildID.map { state.latest($0)?.status.terminal != false } == true
                row["deliveryState"] = JSON(waiting ? "waiting_next_turn" : message.disposition)
                if let id = message.rowID { row["rowId"] = JSON(id) }; return row
            }
        } else if kind == "turns" {
            values = state.turns.values.filter { child == nil || $0.childID == child }.sorted { ($0.childID,$0.turn) < ($1.childID,$1.turn) }.map { turn in
                let origin = plans.values.first { $0.origin.link.childSessionID == turn.childID }?.origin
                var row: JSON = ["childId":JSON(turn.childID),"turn":JSON(turn.turn),"executionID":JSON(turn.executionID),"status":JSON(turn.status.rawValue),"task":JSON(turn.task)]
                if let name = turn.taskName ?? state.names?[turn.childID] ?? origin?.taskName { row["taskName"] = JSON(name); row["forkTurns"] = JSON(turn.forkTurns ?? origin?.forkTurns ?? "none") }
                if let effort = turn.effort { row["effort"] = JSON(effort) }
                if let who = turn.interruptedBy { row["interruptedBy"] = JSON(who) }
                if let note = turn.interruptNote { row["interruptNote"] = JSON(note) }
                if let result = turn.result { row["result"] = result.envelope }; return row
            }
        } else { throw AgentError("invalid_params","detail must be messages or turns") }
        let start = min(max(0,cursor),values.count)
        var page: [JSON] = [], end = start
        for row in values[start...].prefix(limit) {
            if !page.isEmpty, JSON.array(page + [row]).encoded().utf8.count > 15000 { break }
            page.append(row); end += 1
        }
        return ["revision":JSON(state.revision),"total":JSON(values.count),"cursor":end < values.count ? JSON(end) : .null,(kind!): .array(page)]
    }
}
