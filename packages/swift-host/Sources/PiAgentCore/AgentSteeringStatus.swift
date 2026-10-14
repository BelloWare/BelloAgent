import Foundation

extension AgentSteeringCoordinator {
    func waitTargets(_ args: JSON, state: AgentFamilyState, execution: String) throws -> [AgentTurnTarget] {
        let targets: [AgentTurnTarget]
        if args.map["targets"] != nil { targets = args["targets"].list.map { .init(childID:$0["child_id"].text!,turn:$0["turn"].int!) } }
        else { targets = state.turns.values.filter { $0.parentExecutionID == execution && (!$0.status.terminal || state.messages["result:" + $0.id]?.disposition != "delivered") }.sorted { $0.id < $1.id }.map(\.target) }
        guard targets.allSatisfy({ state.turns[$0.id] != nil }) else { throw AgentError("subagent_scope", "Wait targets must be accepted turns in this family") }
        return targets
    }
    func status(_ args: JSON, parent: AgentSession) async throws -> JSON {
        let state = await parent.agentState()
        if args["action"].text == "read_result" {
            let key = AgentTurnTarget(childID:args["child_id"].text!,turn:args["turn"].int!).id
            guard let turn = state.turns[key] else { throw AgentError("subagent_scope", "Unknown child turn") }
            guard let result = turn.result else { throw AgentError("result_not_ready", "The turn has not settled") }
            let text = result.envelope["text"].text ?? "", data = Data(text.utf8), offset = args["offset"].int ?? 0
            guard offset <= data.count, let tail = String(data:data.dropFirst(offset),encoding:.utf8) else { throw AgentError("invalid_offset", "offset must be a UTF-8 boundary") }
            let part = SubagentToolResult.bounded(tail,bytes:args["limit_bytes"].int ?? 8192)
            guard tail.isEmpty || !part.isEmpty else { throw AgentError("invalid_limit", "limit_bytes cannot fit the next character") }
            return ["version":3,"child_id":JSON(turn.childID),"turn":JSON(turn.turn),"status":JSON(turn.status.rawValue),"text":JSON(part),"offset":JSON(offset),"next_offset":offset + part.utf8.count < data.count ? JSON(offset + part.utf8.count) : .null,"result_truncated":result.envelope["truncated"]]
        }
        let filter = args["child_id"].text ?? args["wait_id"].text ?? ""
        var start = 0, high = Int.max
        if let token = args["cursor"].text {
            guard let bytes = Data(base64Encoded:token), let cursor = try? JSON.parse(bytes), cursor["owner"].text == parent.id, cursor["filter"].text == filter,
                  let position = cursor["start"].int, let bound = cursor["high"].int, position >= 0, bound >= position else { throw AgentError("subagent_cursor", "Invalid family cursor") }
            start = position; high = bound
        }
        let plans = await parent.subagents
        let turns: [AgentChildTurn]
        if let wait = args["wait_id"].text {
            guard let targets = state.operations[wait]?.waitTargets else { throw AgentError("subagent_scope", "Unknown wait") }
            turns = targets.compactMap { state.turns[$0.id] }
        } else {
            turns = (plans.callOrder ?? []).compactMap { plans.plans[$0]?.origin.link.childSessionID }.filter { args["child_id"].text == nil || $0 == args["child_id"].text }.compactMap { state.latest($0) }
            if args["child_id"].text != nil, turns.isEmpty { throw AgentError("subagent_scope", "Unknown child") }
        }
        high = min(high,turns.count); start = min(start,high)
        var rows: [JSON] = [], end = start
        for turn in turns[start..<high].prefix(args["limit"].int ?? 32) {
            let row: JSON = ["child_id":JSON(turn.childID),"turn":JSON(turn.turn),"status":JSON(turn.status.rawValue),"delivery_state":JSON(state.messages["result:" + turn.id]?.disposition ?? "pending"),"pending_messages":JSON(state.messages.values.filter { $0.childID == turn.childID && $0.disposition == "pending" }.count)]
            if JSON.array(rows + [row]).encoded().utf8.count > 15000 { break }; rows.append(row); end += 1
        }
        let cursor: JSON = ["owner":JSON(parent.id),"filter":JSON(filter),"start":JSON(end),"high":JSON(high)]
        return ["version":3,"revision":JSON(state.revision),"total":JSON(high),"children":.array(rows),"cursor":end < high ? JSON(try cursor.data().base64EncodedString()) : .null]
    }
    func list(parent: AgentSession, cursor: Int, limit: Int) async -> JSON {
        let saved = await parent.subagents, state = await parent.agentState(), waiting = await parent.familyWaiting
        let plans = (saved.callOrder ?? []).compactMap { saved.plans[$0] }
        let start = min(max(0,cursor),plans.count), page = plans[start...].prefix(max(1,min(limit,256))), end = start + page.count
        return ["revision":JSON(await parent.sequence),"total":JSON(plans.count),"active":JSON(state.turns.values.filter { !$0.status.terminal }.count),"cursor":end < plans.count ? JSON(end) : .null,"children":.array(page.compactMap { plan in
            guard let turn = state.latest(plan.origin.link.childSessionID) else { return try? subagentJSON(SubagentSummary(link:plan.origin.link,description:plan.origin.description,model:plan.origin.model.model,status:saved.outcomes?[plan.origin.link.delegationID] ?? .interrupted,revision:state.revision)) }
            return try? subagentJSON(SubagentSummary(link:plan.origin.link,description:plan.origin.description,model:plan.origin.model.model,status:turn.status,revision:state.revision,tools:plan.origin.tools,turn:turn.turn,executionID:turn.executionID,deliveryState:state.messages["result:" + turn.id]?.disposition ?? "pending",pendingMessages:state.messages.values.filter { $0.childID == turn.childID && $0.disposition == "pending" }.count,followUpsRemaining:max(0,8-state.turns.values.filter { $0.childID == turn.childID && $0.epoch == state.run?.epoch && $0.turn > 1 }.count),parentWaiting:waiting))
        })]
    }
}

extension AgentSteeringCoordinator {
    func stop(parent: AgentSession, target: AgentTurnTarget, human: Bool) async throws {
        let state = await parent.agentState()
        guard state.turns[target.id] != nil else { throw AgentError("subagent_scope", "Unknown child turn") }
        if human, state.latest(target.childID)?.turn == target.turn, var run = state.run {
            if !run.heldChildren.contains(target.childID) { run.heldChildren.append(target.childID) }
            try await parent.appendAgentRecord(JournalRecordKind.familyRun,run)
        }
        await stop(owner:parent.id,target:target,human:human)
    }
}
