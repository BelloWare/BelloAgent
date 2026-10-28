import Foundation

extension AgentSteeringCoordinator {
    func prepareCodex(_ call: ToolCall, key: SubagentCallKey, caller: AgentSession) async throws -> JSON {
        try SubagentCodexContract.validate(call.name,call.arguments)
        let owner: AgentSession
        var source: AgentTurnTarget?
        if let lease = await caller.agentLease {
            guard call.name != "spawn_agent" else { throw AgentError("agent_spawn_root_only","Only /root can start sub-agents. Ask /root with send_message if more agents would help.") }
            guard let job = jobs[lease.id], job.child === caller, !job.cancelled, !job.sealed else { throw AgentError("subagent_closed","This agent turn no longer accepts commands") }
            owner = job.owner; source = lease.target
        } else {
            guard !(await caller.isSubagent) else { throw AgentError("subagent_closed","A dormant agent cannot issue commands") }
            owner = caller
        }
        let lock = gate(owner.id); try await lock.acquire()
        do {
            let result = try await codexCommand(call,key:key,caller:caller,owner:owner,source:source)
            await lock.release(); return result
        } catch { await lock.release(); throw error }
    }
    private func codexCommand(_ call: ToolCall, key: SubagentCallKey, caller: AgentSession, owner: AgentSession, source: AgentTurnTarget?) async throws -> JSON {
        let digest = sha256(Data((call.name + call.arguments.encoded()).utf8))
        if let receipt = try await owner.agentReceipt(key,digest:digest) { return receipt }
        let env = try await owner.delegationEnvironment()
        if let source {
            guard let job = jobs[source.id], job.child === caller, !job.cancelled, !job.sealed,
                  job.turn.currentParentExecutionID == env.executionID else { throw AgentError("subagent_closed","The issuing agent no longer belongs to this execution") }
        }
        try await owner.adoptCodexNames()
        var state = await owner.agentState()
        let names = state.names ?? [:]
        let sender: String
        if let source {
            guard let name = names[source.childID] else { throw SubagentRecovery.damaged() }
            sender = name
        } else { sender = "/root" }
        if call.name == "list_agents" { return ["version":4,"output":JSON(try await codexList(call.arguments,owner:owner).encoded())] }
        var plan: SubagentPlan?, turn: AgentChildTurn?, message: AgentFamilyMessage?
        var seedMessages: [ChatMessage] = []
        var target: String?, interrupt: AgentTurnTarget?, interruptBy: String?
        var receipt: JSON = ["version":4,"accepted":true,"operation_id":JSON(AgentOperation.id(key)),"tool":JSON(call.name)]
        if let addressed = call.arguments["target"].text {
            target = try SubagentCodexContract.resolve(addressed,owner:owner.id,names:names)
            if call.name == "followup_task", target == owner.id { throw AgentError("agent_scope","Follow-up tasks can't target the root agent") }
            if call.name == "interrupt_agent", target == owner.id { throw AgentError("agent_scope","root is not a spawned agent") }
            if target == caller.id {
                throw AgentError("agent_scope",call.name == "interrupt_agent" ? "an agent cannot interrupt itself; return your result and let the parent interrupt you if needed" : "An agent cannot message itself")
            }
        }
        switch call.name {
        case "spawn_agent":
            guard source == nil else { throw AgentError("agent_spawn_root_only","Only /root can start sub-agents. Ask /root with send_message if more agents would help.") }
            let name = try SubagentCodexContract.availableName(call.arguments["task_name"].text!,names:names)
            var input = call.arguments.removing(["task_name","message","fork_turns","reasoning_effort"]); input["task"] = call.arguments["message"]
            let spec = try SubagentSpec(input), fork = call.arguments["fork_turns"].text ?? "all"
            let available = Set(env.definitions.map(\.name)).subtracting(SubagentSteeringContract.names.union(SubagentCodexContract.names).union(["subagent"]))
            let selected = spec.tools ?? available
            guard selected.isSubset(of:available) else { throw AgentError("subagent_tools","Requested tools exceed parent permissions") }
            let grant = try SubagentModelGrant.childModel(spec.model,parent:env.profile,grants:env.models).selectingEffort(call.arguments["reasoning_effort"].text,parent:env.profile,connectionSupportsReasoning:env.connectionSupportsReasoning)
            let offered = await owner.sessionDefinitions()
            let prefix = AgentCodexContext(cacheSessionID:await owner.promptCacheSessionID,resources:env.resources,tools:offered.filter { selected.contains($0.name) || SubagentCodexContract.names.contains($0.name) })
            let link = SubagentLink(delegationID:UUID().uuidString,childSessionID:UUID().uuidString,budgetOwnerSessionID:owner.id,call:key,parentTurnID:env.turnID,parentExecutionID:env.executionID,parentAttemptID:env.parentAttemptID)
            plan = SubagentPlan(origin:.init(link:link,description:spec.description,model:grant,tools:selected.sorted(),readOnly:env.readOnly,resourceRevision:env.resources.revision,mcpPolicy:env.mcpPolicy,frozenResources:env.resources,taskName:name,forkTurns:fork,codexContext:prefix),task:spec.task,resultMessageID:UUID().uuidString)
            if fork == "all" { let seed = await owner.codexSeed(); plan?.forkSeed = seed.reference; seedMessages = seed.messages }
            turn = newTurn(child:link.childSessionID,number:1,text:spec.task,key:key,env:env)
            turn?.effort = grant.thinkingLevel; turn?.taskName = name; turn?.forkTurns = fork; turn?.sender = sender
            let payload = SubagentCodexContract.handoff(name:name,fork:fork) + "\n\n" + spec.task
            message = codexMessage(id:turn!.inputID,sequence:state.sequence + 1,target:link.childSessionID,turn:1,type:"NEW_TASK",sender:sender,recipient:name,source:source,text:payload,task:spec.description,epoch:env.executionID,queueOnly:false)
            receipt["route"] = "start"; receipt["child_id"] = JSON(link.childSessionID)
            var output: JSON = ["task_name":JSON(name)]
            if let notice = grant.fallbackNotice(requested:spec.model) { output["model"] = JSON(grant.model); output["model_notice"] = JSON(notice) }
            receipt["output"] = JSON(output.encoded())
        case "send_message", "followup_task":
            guard let target else { throw SubagentRecovery.damaged() }
            if target == owner.id {
                guard let source else { throw SubagentRecovery.damaged() }
                message = codexMessage(sequence:state.sequence + 1,target:nil,turn:source.turn,type:"MESSAGE",sender:sender,recipient:"/root",source:source,text:call.arguments["message"].text!,task:"",epoch:env.executionID,queueOnly:true)
                receipt["output"] = "Queued for /root."; receipt["route"] = "message"
                break
            }
            guard let saved = await owner.subagents.plans.values.first(where: { $0.origin.link.childSessionID == target }), let name = names[target] else { throw SubagentRecovery.damaged() }
            if state.latest(target) == nil { try await adoptLegacy(saved,parent:owner,environment:env); state = await owner.agentState() }
            guard var latest = state.latest(target) else { throw SubagentRecovery.damaged() }
            if call.name == "followup_task", !latest.status.terminal, let job = jobs[latest.id], let child = job.child, await child.agentFinalProduced {
                // A finished answer is the closing boundary. Queue-only mail
                // stays for the next turn; a new task follows this sealed turn.
                var final = job; final.turn.result = await child.agentResult(latest,plan:saved,cancelled:job.cancelled); final.turn.status = final.turn.result!.status
                try await seal(job:final,child:child)
                state = await owner.agentState(); latest = state.latest(target)!
            }
            if call.name == "followup_task" {
                guard !(state.run?.heldChildren.contains(target) ?? false), latest.status != .stopping else { throw AgentError("subagent_stopped","Child is stopping or held by user Stop") }
                let grant = try saved.origin.model.selectingEffort(call.arguments["reasoning_effort"].text,parent:env.profile,connectionSupportsReasoning:env.connectionSupportsReasoning)
                if latest.status.terminal {
                    if let seed = saved.forkSeed { try seed.requirePublished(at:env.directory.appendingPathComponent(target + ".jsonl")) }
                    if latest.status != .notExecuted, !FileManager.default.fileExists(atPath:env.directory.appendingPathComponent(target + ".jsonl").path) { throw AgentError("subagent_missing","The saved child conversation is missing; it cannot be resumed") }
                    turn = newTurn(child:target,number:latest.turn + 1,text:call.arguments["message"].text!,key:key,env:env)
                    turn?.taskName = name; turn?.forkTurns = saved.origin.forkTurns ?? "none"; turn?.sender = sender; turn?.effort = grant.thinkingLevel
                    turn?.codexContext = latest.codexContext ?? saved.origin.codexContext
                    if turn?.codexContext == nil { turn?.codexContext = AgentCodexContext(cacheSessionID:await owner.promptCacheSessionID,resources:env.resources,tools:await owner.sessionDefinitions().filter { saved.origin.tools.contains($0.name) || SubagentCodexContract.names.contains($0.name) }) }
                    if let who = latest.interruptedBy { turn?.interruptNote = "The previous turn was interrupted on purpose by \(who). Any running tools were cancelled; check the state before continuing." }
                    receipt["route"] = "follow_up"; receipt["output"] = JSON("Task sent to \(name) (turn \(turn!.turn)).")
                } else {
                    guard latest.currentParentExecutionID == env.executionID else { throw AgentError("subagent_closed","This agent belongs to a stopped execution") }
                    receipt["route"] = "steer"; receipt["output"] = JSON("Task queued for running \(name).")
                }
            } else { receipt["route"] = "message"; receipt["output"] = JSON("Queued for \(name).") }
            let payload = (turn?.interruptNote).map { $0 + "\n\n" + call.arguments["message"].text! } ?? call.arguments["message"].text!
            message = codexMessage(id:turn?.inputID ?? UUID().uuidString,sequence:state.sequence + 1,target:target,turn:turn?.turn ?? latest.turn,type:call.name == "followup_task" ? "NEW_TASK" : "MESSAGE",sender:sender,recipient:name,source:source,text:payload,task:saved.origin.description,epoch:env.executionID,queueOnly:call.name == "send_message")
            receipt["child_id"] = JSON(target); receipt["turn"] = JSON(turn?.turn ?? latest.turn)
        case "wait_agent": receipt["output"] = "Wait interrupted by Stop."; receipt["route"] = "wait"
        case "interrupt_agent":
            guard let target else { throw SubagentRecovery.damaged() }
            // A retained v2 conversation can be named before its first v4
            // follow-up adopts turn records. It has no live turn to interrupt.
            guard let latest = state.latest(target) else {
                receipt["output"] = "{\"previous_status\":\"idle\"}"; receipt["route"] = "stop"
                break
            }
            let previous: JSON = ["previous_status":JSON(codexStatus(latest,held:state.run?.heldChildren.contains(target) == true))]
            receipt["output"] = JSON(previous.encoded())
            receipt["route"] = "stop"; receipt["child_id"] = JSON(target); receipt["turn"] = JSON(latest.turn)
            if !latest.status.terminal { interrupt = latest.target; interruptBy = sender }
        default: throw AgentError("tool_unavailable","Unavailable agent tool")
        }
        if let event = message?.deliveryEvent, turn != nil { turn?.inputEvent = event }
        if let turn { receipt["child_id"] = JSON(turn.childID); receipt["turn"] = JSON(turn.turn) }
        if let message { receipt["message_id"] = JSON(message.id) }
        if let childID = receipt["child_id"].text {
            let saved = await owner.subagents.plans.values.first { $0.origin.link.childSessionID == childID }
            if let origin = plan?.origin ?? saved?.origin, call.name == "spawn_agent" || call.name == "followup_task" {
                receipt["nativeSubagent"] = codexMetadata(origin:origin,name:turn?.taskName ?? names[childID]!,fork:origin.forkTurns ?? "none",key:key,turn:receipt["turn"].int ?? 1,route:receipt["route"].text!,effort:turn?.effort ?? state.latest(childID)?.effort ?? origin.model.thinkingLevel)
            }
        }
        let op = try await owner.acceptAgentOperation(.init(key:key,digest:digest,receipt:receipt,plan:plan,turn:turn,message:message,epoch:env.executionID,sourceTurn:source,interruptTarget:interrupt,interruptBy:interruptBy),generation:env.generation)
        if source != nil { try await caller.appendAgentRecord(JournalRecordKind.agentOperation,op,owner:owner.id) }
        try await enqueue(op,env:env,state:state,parent:owner,seedMessages:seedMessages)
        if call.name == "interrupt_agent", let target { await owner.cancelMailboxDrains(source:target) }
        if let interrupt {
            jobs[interrupt.id]?.turn.interruptedBy = sender
            await stop(owner:owner.id,target:interrupt,human:false)
        }
        await signal(owner.id).pulse()
        return op.receipt
    }
    func codexMessage(id: String = UUID().uuidString, sequence: Int, target: String?, turn: Int, type: String, sender: String, recipient: String, source: AgentTurnTarget?, text: String, task: String, epoch: String, queueOnly: Bool) -> AgentFamilyMessage {
        var message = AgentFamilyMessage(id:id,sequence:sequence,childID:target ?? source!.childID,turn:turn,author:source == nil ? "parent" : "subagent",kind:type == "NEW_TASK" ? "steer" : "note",text:text,task:task,epoch:epoch)
        message.type = type; message.sender = sender; message.recipient = recipient; message.senderChildID = source?.childID; message.recipientChildID = target; message.queueOnly = queueOnly
        return message
    }
    func codexMetadata(origin: SubagentOrigin, name: String, fork: String, key: SubagentCallKey, turn: Int, route: String, effort: String?) -> JSON {
        var value: JSON = ["version":2,"sessionId":JSON(origin.link.childSessionID),"delegationId":JSON(origin.link.delegationID),"budgetOwnerSessionId":JSON(origin.link.budgetOwnerSessionID),"parentAssistantMessageId":JSON(key.assistantMessageID),"toolCallId":JSON(key.toolCallID),"turn":JSON(turn),"route":JSON(route),"status":"accepted","effects":"completed","taskName":JSON(name),"forkTurns":JSON(fork)]
        if let effort { value["effort"] = JSON(effort) }; return value
    }
    func codexStatus(_ turn: AgentChildTurn, held: Bool) -> String {
        if held { return "stopped_by_user" }
        switch turn.status { case .queued: return "queued"; case .running: return "running"; case .completed,.outputLimited:return "idle"; case .failed,.notExecuted:return "errored"; default:return "interrupted" }
    }
}
