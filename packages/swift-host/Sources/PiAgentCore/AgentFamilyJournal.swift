import Foundation

/// V3 accepts an operation and all its constituents in ONE synced journal row.
/// This is the acceptance commit: no partial unit can authorize execution.
struct AgentOperation: Codable, Sendable, Equatable {
    var key: SubagentCallKey
    var digest: String
    var receipt: JSON
    var plan: SubagentPlan?
    var turn: AgentChildTurn?
    var message: AgentFamilyMessage?
    var waitTargets: [AgentTurnTarget]?
    var epoch: String
    var acceptedAt: Double = Date().timeIntervalSince1970
    var id: String { Self.id(key) }
    static func id(_ key: SubagentCallKey) -> String { sha256(Data((try! subagentJSON(key)).encoded().utf8)) }
}
struct AgentTurnTarget: Codable, Sendable, Equatable, Hashable {
    var childID: String, turn: Int
    var id: String { childID + ":" + String(turn) }
}
struct AgentChildTurn: Codable, Sendable, Equatable {
    var childID: String, turn: Int, executionID: String
    var parentExecutionID: String, generation: Int, runtimeID: String, epoch: String
    var inputID: String, task: String
    var call: SubagentCallKey
    var status: SubagentStatus = .queued
    var result: SubagentToolResult?
    /// V2 did not persist the original snapshot. Freeze the current parent's
    /// snapshot once at adoption, without rewriting immutable v2 provenance.
    var legacyResources: ResourceSnapshot? = nil
    var target: AgentTurnTarget { .init(childID:childID,turn:turn) }
    var id: String { target.id }
}
struct AgentFamilyMessage: Codable, Sendable, Equatable {
    var id: String, sequence: Int, childID: String, turn: Int
    var author: String, kind: String, text: String, task: String, epoch: String
    var replyTo: String?
    var disposition: String = "pending"
    var rowID: String?
    var result: JSON? = nil
    var event: JSON {
        var v: JSON = ["event_id":JSON(id),"family_sequence":JSON(sequence),"child_id":JSON(childID),"turn":JSON(turn),"author":JSON(author),"kind":JSON(kind),"text":JSON(text),"task":JSON(task)]
        if let replyTo { v["reply_to"] = JSON(replyTo) }; if let result { v["result"] = result }; return v
    }
}
struct AgentDelivery: Codable, Sendable, Equatable {
    var rowID: String, recipientID: String, eventIDs: [String], payload: JSON
    var committed = false
    var continuation: Bool? = nil
}
struct AgentFamilyRun: Codable, Sendable, Equatable {
    var epoch: String
    var closed = false
    var heldChildren: [String] = []
    var reportContinuations = 0
    var rateTimes: [String: [Double]] = [:]
}
struct AgentFamilyState: Codable, Sendable, Equatable {
    var ownerID: String
    var operations: [String:AgentOperation] = [:]
    var turns: [String:AgentChildTurn] = [:]
    var messages: [String:AgentFamilyMessage] = [:]
    var deliveries: [String:AgentDelivery] = [:]
    var contextRows: [String:String] = [:]
    var run: AgentFamilyRun?
    var revision = 0
    var sequence = 0
    func latest(_ child: String) -> AgentChildTurn? { turns.values.filter { $0.childID == child }.max { $0.turn < $1.turn } }
    func pending(author: String) -> [AgentFamilyMessage] { messages.values.filter { $0.author == author && $0.disposition == "pending" }.sorted { $0.sequence < $1.sequence } }
    mutating func operation(_ op: AgentOperation) throws {
        guard op.key.parentSessionID == ownerID || (op.message?.author == "subagent" && op.message?.childID == op.key.parentSessionID) else { throw SubagentRecovery.damaged() }
        if let old = operations[op.id] { guard old == op else { throw SubagentRecovery.damaged() }; return }
        if let turn = op.turn {
            guard turn.turn == (latest(turn.childID)?.turn ?? 0) + 1,
                  latest(turn.childID)?.status.terminal != false else { throw SubagentRecovery.damaged() }
            turns[turn.id] = turn
        }
        if let message = op.message {
            guard messages[message.id] == nil, message.sequence > sequence else { throw SubagentRecovery.damaged() }
            messages[message.id] = message; sequence = message.sequence
        }
        if op.key.parentSessionID == ownerID, run?.epoch != op.epoch { run = AgentFamilyRun(epoch:op.epoch) }
        operations[op.id] = op; revision += 1
    }
    mutating func consume(_ row: JSON) throws {
        let data = row["data"]
        switch row["customType"].text {
        case JournalRecordKind.agentOperation:
            try operation(JSONDecoder().decode(AgentOperation.self,from:data.data()))
        case JournalRecordKind.agentTurn, JournalRecordKind.agentTurnState, JournalRecordKind.agentTerminal:
            let turn = try JSONDecoder().decode(AgentChildTurn.self,from:data.data())
            if let old = turns[turn.id] {
                var identity = old; identity.status = turn.status; identity.result = turn.result
                guard identity == turn, !old.status.terminal || old == turn else { throw SubagentRecovery.damaged() }
            }
            turns[turn.id] = turn; revision += 1
        case JournalRecordKind.agentMessage:
            let message = try JSONDecoder().decode(AgentFamilyMessage.self,from:data.data())
            if let old = messages[message.id] {
                guard old.childID == message.childID, old.turn == message.turn, old.text == message.text,
                      old.disposition == "pending" || old == message else { throw SubagentRecovery.damaged() }
            }
            messages[message.id] = message; sequence = max(sequence,message.sequence); revision += 1
        case JournalRecordKind.agentDelivery:
            let delivery = try JSONDecoder().decode(AgentDelivery.self,from:data.data())
            if let old = deliveries[delivery.rowID] {
                guard old.recipientID == delivery.recipientID, old.eventIDs == delivery.eventIDs, old.payload == delivery.payload,
                      old.continuation == delivery.continuation,
                      !old.committed || delivery.committed else { throw SubagentRecovery.damaged() }
            } else if delivery.continuation == true {
                guard delivery.recipientID == ownerID, run != nil, !delivery.committed else { throw SubagentRecovery.damaged() }
                run?.reportContinuations += 1
            }
            deliveries[delivery.rowID] = delivery
            if delivery.committed { for id in delivery.eventIDs { messages[id]?.disposition = "delivered"; messages[id]?.rowID = delivery.rowID } }
            revision += 1
        case JournalRecordKind.familyRun:
            run = try JSONDecoder().decode(AgentFamilyRun.self,from:data.data()); revision += 1
        default: break
        }
    }
}
