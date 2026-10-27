import Foundation

/// Frozen cache prefix, separate from current execution permissions. Tool
/// execution still checks RestrictedTools and the current owner's lease.
struct AgentCodexContext: Codable, Sendable, Equatable {
    var cacheSessionID: String
    var resources: ResourceSnapshot
    var tools: [ToolDefinition]
}
/// Parent records retain only identities and a digest. Bodies live in the
/// acceptance call until publication, then only in the child's journal.
struct AgentForkSeed: Codable, Sendable, Equatable {
    var from: String
    var cutoffEntryID: String?
    var ids: [String]
    var digest: String
    enum CodingKeys: String, CodingKey { case from, cutoffEntryID = "cutoffEntryId", ids, digest }
    init(from: String, cutoffEntryID: String?, messages: [ChatMessage]) {
        self.from = from; self.cutoffEntryID = cutoffEntryID
        ids = messages.map(\.id); digest = Self.contentDigest(messages)
    }
    /// These fields round-trip exactly through message.pi and ChatMessage(pi:).
    static func contentDigest(_ messages: [ChatMessage]) -> String {
        sha256(Data(JSON.array(messages.map { .array([JSON($0.id),.array($0.content),$0.nativeInherited ?? .null]) }).encoded().utf8))
    }
    static var publicationError: AgentError {
        AgentError("subagent_fork_publication","The inherited history was not fully published. Reopen the main chat to reconcile it before following up; no child request was sent.")
    }
    func matches(_ messages: [ChatMessage]) -> Bool {
        messages.map(\.id) == ids && Set(ids).count == ids.count &&
            messages.allSatisfy { $0.userInput == nil && $0.nativeInherited == ["from":JSON(from),"cutoffEntryId":cutoffEntryID.map(JSON.string) ?? .null] } &&
            Self.contentDigest(messages) == digest
    }
    func complete(rows: [ChatMessage], reference saved: JSON?) -> Bool {
        saved == reference && matches(Array(rows.prefix(ids.count))) &&
            rows.dropFirst(ids.count).allSatisfy { !ids.contains($0.id) }
    }
    func requirePublished(at url: URL) throws {
        guard FileManager.default.fileExists(atPath:url.path) else { throw Self.publicationError }
        let reader = try JournalRecordReader(url)
        var rows: [ChatMessage] = [], saved: JSON?
        while let row = try reader.next() {
            if row["customType"].text == JournalRecordKind.agentForkSeed {
                guard row["data"] == reference else { throw Self.publicationError }
                saved = row["data"]
            }
            if row["type"].text == "message", let id = row["id"].text { rows.append(try ChatMessage(id:id,pi:row["message"])) }
        }
        guard complete(rows:rows,reference:saved) else { throw Self.publicationError }
    }
    func rebuild(from context: [ChatMessage], before assistant: String) -> [ChatMessage]? {
        guard let boundary = context.firstIndex(where: { $0.id == assistant }), ids.last == cutoffEntryID else { return nil }
        let messages = context[..<boundary].map { SubagentCodexContract.inherited($0,from:from,cutoff:cutoffEntryID) }
        guard matches(messages) else { return nil }
        return messages
    }
    var reference: JSON { ["from":JSON(from),"cutoffEntryId":cutoffEntryID.map(JSON.string) ?? .null,"ids":.array(ids.map(JSON.string)),"digest":JSON(digest)] }
}
extension AgentSession {
    func codexSeed() -> (reference: AgentForkSeed, messages: [ChatMessage]) {
        let seed = sideSeed(), cutoff = seed.info["cutoffEntryId"].text
        // sideSeed is the last complete boundary, before the spawning reply.
        let messages = seed.messages.map { SubagentCodexContract.inherited($0,from:id,cutoff:cutoff) }
        return (AgentForkSeed(from:id,cutoffEntryID:cutoff,messages:messages),messages)
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
