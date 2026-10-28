import Foundation

extension AgentSteeringCoordinator {
    func publishQueuedChild(_ env: SubagentEnvironment, plan: SubagentPlan, turn: AgentChildTurn, seedMessages: [ChatMessage]) throws {
        let origin = plan.origin, url = env.directory.appendingPathComponent(origin.link.childSessionID + ".jsonl")
        let (_, profile) = try SubagentModelGrant.resolve(origin.model.model,parent:env.profile,grants:[origin.model])
        let journal = try SessionJournal(url:url,id:origin.link.childSessionID,cwd:env.cwd,binding:profile.binding,create:true,managedChild:true)
        if turn.taskName != nil { try journal.promoteToCodex(managedChild:true) }
        else { try journal.promoteToSteering(managedChild:true) }
        try journal.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":subagentJSON(origin)])
        if let seed = plan.forkSeed {
            guard seed.matches(seedMessages) else { throw AgentForkSeed.publicationError }
            for message in seedMessages { try journal.append(["type":"message","message":message.pi],id:message.id,flush:false) }
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(seed.ids.map(JSON.string))]],flush:false)
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentForkSeed),"data":seed.reference],flush:true)
        }
        try journal.append(["type":"custom","customType":JSON(JournalRecordKind.agentTurn),"ownerID":JSON(env.ownerID),"data":subagentJSON(turn)])
    }
    /// Historical v2 turn 1 was already returned synchronously. Adoption never
    /// re-delivers that answer or changes the immutable creation link.
    func adoptLegacy(_ plan: SubagentPlan, parent: AgentSession, environment env: SubagentEnvironment) async throws {
        let link = plan.origin.link, path = env.directory.appendingPathComponent(link.childSessionID + ".jsonl")
        try SessionJournal.verifyManagedChild(url:path,id:link.childSessionID)
        let reader = try JournalRecordReader(path)
        var child = SubagentJournalState()
        while let record = try reader.next() { try child.consume(record,sessionID:link.childSessionID) }
        guard child.origin == plan.origin, let saved = child.terminal else { throw AgentError("subagent_unsettled", "The v2 child must settle before a follow-up") }
        let result = try JSONDecoder().decode(SubagentToolResult.self,from:saved["result"].data())
        var turn = AgentChildTurn(childID:link.childSessionID,turn:1,executionID:link.delegationID,parentExecutionID:link.parentExecutionID,generation:0,runtimeID:"legacy",epoch:"legacy",inputID:link.delegationID,task:plan.task,call:link.call,status:result.status,result:result)
        if plan.origin.frozenResources == nil {
            var snapshot = env.resources
            snapshot.prompt += "\n\nLegacy child: the original v2 instruction snapshot was not saved. The parent's instructions at first v3 follow-up were adopted and frozen; earlier conversation remains intact. Existing tool and permission limits still apply."
            snapshot.revision = sha256(Data((snapshot.revision + "legacy-v3-adoption").utf8))
            turn.legacyResources = snapshot
        }
        turn.normalizeResult()
        try await parent.appendAgentRecord(JournalRecordKind.agentTurn,turn)
        let state = await parent.agentState()
        var event = AgentFamilyMessage.resultEvent(turn,task:plan.origin.description,sequence:state.sequence + 1)
        event.disposition = "delivered"
        try await parent.appendAgentRecord(JournalRecordKind.agentMessage,event)
    }
}
