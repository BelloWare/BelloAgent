import Foundation

/// Frozen cache prefix, separate from current execution permissions. Tool
/// execution still checks RestrictedTools and the current owner's lease.
struct AgentCodexContext: Codable, Sendable, Equatable {
    var cacheSessionID: String
    var resources: ResourceSnapshot
    var tools: [ToolDefinition]
}
struct AgentForkSeed: Codable, Sendable, Equatable {
    var from: String
    var cutoffEntryID: String?
    var messages: [ChatMessage]
    var digest: String { sha256(Data((try! subagentJSON(messages)).encoded().utf8)) }
    func requirePublished(at url: URL) throws {
        let error = AgentError("subagent_fork_publication","The inherited history was not fully published. Reopen the main chat to reconcile it before following up; no child request was sent.")
        guard FileManager.default.fileExists(atPath:url.path) else { throw error }
        let reader = try JournalRecordReader(url)
        var found: Set<String> = [], referenceFound = false
        let expected = Dictionary(uniqueKeysWithValues:messages.map { ($0.id,$0) })
        while let row = try reader.next() {
            if row["customType"].text == JournalRecordKind.agentForkSeed { referenceFound = row["data"] == reference }
            if row["type"].text == "message", let id = row["id"].text, let original = expected[id] {
                let saved = try ChatMessage(id:id,pi:row["message"])
                guard saved.content == original.content, saved.userInput == nil, saved.nativeInherited == original.nativeInherited else { throw SubagentRecovery.damaged() }
                found.insert(id)
            }
        }
        guard referenceFound, found.count == messages.count else { throw error }
    }
    var reference: JSON { ["from":JSON(from),"cutoffEntryId":cutoffEntryID.map(JSON.string) ?? .null,"ids":.array(messages.map { JSON($0.id) }),"digest":JSON(digest)] }
}
extension AgentSession {
    func codexSeed() -> AgentForkSeed {
        let seed = sideSeed(), cutoff = seed.info["cutoffEntryId"].text
        // sideSeed is the last complete boundary, before the spawning reply.
        return AgentForkSeed(from:id,cutoffEntryID:cutoff,messages:seed.messages.map { SubagentCodexContract.inherited($0,from:id,cutoff:cutoff) })
    }
    func adoptCodexNames() throws {
        var names = subagents.family?.names ?? [:], changed = false
        for (index, key) in (subagents.callOrder ?? []).enumerated() {
            guard let plan = subagents.plans[key], names[plan.origin.link.childSessionID] == nil else { continue }
            names[plan.origin.link.childSessionID] = plan.origin.taskName ?? SubagentCodexContract.adoptedName(plan.origin.description,index:index + 1,used:Set(names.values)); changed = true
        }
        if changed { try journal?.promoteToCodex(managedChild:false); try appendAgentRecord(JournalRecordKind.agentNames,names) }
    }
    var agentFinalProduced: Bool {
        guard let lease = agentLease else { return false }
        return context.last.map { $0.role == "assistant" && $0.taskRootID == lease.inputID && !$0.content.contains { $0["type"].text == "toolCall" } } ?? false
    }
}

extension AgentSteeringCoordinator {
    func prepareTaskDelivery(_ turn: AgentChildTurn, child: AgentSession) async throws {
        guard let job = jobs[turn.id], job.child === child, let event = turn.inputEvent else { throw SubagentRecovery.damaged() }
        let delivery = AgentDelivery(rowID:turn.inputID,recipientID:child.id,eventIDs:[turn.inputID],payload:JSON(event.envelope))
        if await job.owner.agentState().deliveries[turn.inputID] == nil { try await job.owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery) }
    }
    func commitTaskDelivery(_ turn: AgentChildTurn, child: AgentSession) async throws {
        guard let job = jobs[turn.id], job.child === child, var delivery = await job.owner.agentState().deliveries[turn.inputID] else { throw SubagentRecovery.damaged() }
        guard !delivery.committed else { return }
        delivery.committed = true
        try await job.owner.appendAgentRecord(JournalRecordKind.agentDelivery,delivery)
        try await child.appendAgentRecord(JournalRecordKind.agentDelivery,delivery,owner:job.owner.id)
    }
}
