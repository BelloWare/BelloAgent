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
    var sourceTurn: AgentTurnTarget? = nil
    var interruptTarget: AgentTurnTarget? = nil
    var interruptBy: String? = nil
    var acceptedAt: Double = Date().timeIntervalSince1970
    var id: String { Self.id(key) }
    static func id(_ key: SubagentCallKey) -> String { sha256(Data((try! subagentJSON(key)).encoded().utf8)) }
}
struct AgentTurnTarget: Codable, Sendable, Equatable, Hashable {
    var childID: String, turn: Int
    var id: String { childID + ":" + String(turn) }
}
/// A turn paused at the family's cost limit continues under the parent
/// execution that resumed it. Appended once per Resume; older helpers ignore it.
struct AgentTurnContinuation: Codable, Sendable, Equatable {
    var parentExecutionID: String, generation: Int, runtimeID: String, epoch: String
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
    /// Frozen at acceptance. Older turns inherit their saved model grant.
    var effort: String? = nil
    /// Resumes after a cost-limit pause, oldest first. The fields above stay
    /// the turn's immutable acceptance identity; admission uses the latest.
    var continuations: [AgentTurnContinuation]? = nil
    var taskName: String? = nil
    var forkTurns: String? = nil
    var sender: String? = nil
    var interruptedBy: String? = nil
    var interruptNote: String? = nil
    var inputEvent: AgentDeliveryEvent? = nil
    var codexContext: AgentCodexContext? = nil
    var currentParentExecutionID: String { continuations?.last?.parentExecutionID ?? parentExecutionID }
    var currentGeneration: Int { continuations?.last?.generation ?? generation }
    var currentRuntimeID: String { continuations?.last?.runtimeID ?? runtimeID }
    var currentEpoch: String { continuations?.last?.epoch ?? epoch }
    /// Charges recorded under the acceptance or any later continuation.
    func acceptsParentExecution(_ id: String?) -> Bool {
        id == parentExecutionID || continuations?.contains { $0.parentExecutionID == id } == true
    }
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
    var type: String? = nil
    var sender: String? = nil
    var recipient: String? = nil
    var senderChildID: String? = nil
    var recipientChildID: String? = nil
    var queueOnly: Bool? = nil
    var deliveryEvent: AgentDeliveryEvent? {
        guard let type, let sender, let recipient else { return nil }
        return AgentDeliveryEvent(id:id,sequence:sequence,type:type,sender:sender,recipient:recipient,senderChildID:senderChildID,recipientChildID:recipientChildID,turn:turn,status:type == "FINAL_ANSWER" ? result?["status"].text : nil,text:text)
    }
    var event: JSON {
        var v: JSON = ["event_id":JSON(id),"family_sequence":JSON(sequence),"child_id":JSON(childID),"turn":JSON(turn),"author":JSON(author),"kind":JSON(kind),"text":JSON(text),"task":JSON(task)]
        if let replyTo { v["reply_to"] = JSON(replyTo) }; if let result { v["result"] = result }; return v
    }
}
struct AgentDelivery: Codable, Sendable, Equatable {
    var rowID: String, recipientID: String, eventIDs: [String], payload: JSON
    var committed = false
    var continuation: Bool? = nil
    var cursor: String? = nil
    var eventTurns: [String:Int]? = nil
    var text: String { payload.text ?? payload.encoded() }
}
struct AgentFamilyRun: Codable, Sendable, Equatable {
    var epoch: String
    var closed = false
    var heldChildren: [String] = []
    var stoppedByUser: Bool? = nil
    var reportContinuations = 0
    var rateTimes: [String: [Double]] = [:]
    var deliveryCursor: String? = nil
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
    var names: [String:String]? = nil
    var deliveryCursors: [String:String]? = nil
    func latest(_ child: String) -> AgentChildTurn? { turns.values.filter { $0.childID == child }.max { $0.turn < $1.turn } }
    func pending(author: String) -> [AgentFamilyMessage] { messages.values.filter { $0.author == author && $0.disposition == "pending" }.sorted { $0.sequence < $1.sequence } }
    mutating func operation(_ op: AgentOperation, mirror: Bool = false) throws {
        guard op.key.parentSessionID == ownerID || (op.sourceTurn?.childID == op.key.parentSessionID && (mirror || latest(op.key.parentSessionID)?.target == op.sourceTurn && latest(op.key.parentSessionID)?.status.terminal == false)) || (op.message?.author == "subagent" && (op.message?.senderChildID ?? op.message?.childID) == op.key.parentSessionID) else { throw SubagentRecovery.damaged() }
        if let old = operations[op.id] { guard old == op else { throw SubagentRecovery.damaged() }; return }
        if mirror, op.receipt["version"].int == 4 { operations[op.id] = op; revision += 1; return }
        if let plan = op.plan, let name = plan.origin.taskName {
            if names == nil { names = [:] }
            guard !names!.contains(where: { $0.key != plan.origin.link.childSessionID && $0.value == name }) else { throw SubagentRecovery.damaged() }
            names?[plan.origin.link.childSessionID] = name
        }
        if let turn = op.turn {
            guard turn.turn == (latest(turn.childID)?.turn ?? 0) + 1,
                  latest(turn.childID)?.status.terminal != false else { throw SubagentRecovery.damaged() }
            turns[turn.id] = turn
        }
        if let target = op.interruptTarget, let by = op.interruptBy {
            guard var turn = turns[target.id] else { throw SubagentRecovery.damaged() }
            if !turn.status.terminal { turn.interruptedBy = by; turns[target.id] = turn }
        }
        if let message = op.message {
            guard messages[message.id] == nil, message.sequence > sequence else { throw SubagentRecovery.damaged() }
            messages[message.id] = message; sequence = message.sequence
        }
        if op.key.parentSessionID == ownerID, run?.epoch != op.epoch { run = AgentFamilyRun(epoch:op.epoch) }
        operations[op.id] = op; revision += 1
    }
    mutating func consume(_ row: JSON, mirror: Bool = false) throws {
        let data = row["data"]
        switch row["customType"].text {
        case JournalRecordKind.agentOperation:
            try operation(JSONDecoder().decode(AgentOperation.self,from:data.data()),mirror:mirror)
        case JournalRecordKind.agentTurn, JournalRecordKind.agentTurnState, JournalRecordKind.agentTerminal:
            var turn = try JSONDecoder().decode(AgentChildTurn.self,from:data.data())
            if let old = turns[turn.id] {
                // Released v3 helpers omit unknown optional fields when they
                // seal recovery. Absence cannot erase the accepted effort.
                if turn.effort == nil { turn.effort = old.effort }
                if turn.interruptedBy == nil { turn.interruptedBy = old.interruptedBy }
                // Released helpers omit continuations too; absence keeps them.
                if turn.continuations == nil { turn.continuations = old.continuations }
                var identity = old; identity.status = turn.status; identity.result = turn.result
                if !old.status.terminal, old.interruptedBy == nil || turn.interruptedBy == "the user" { identity.interruptedBy = turn.interruptedBy }
                if old.continuations != turn.continuations {
                    // Only a Resume of a paused, unsealed turn extends them,
                    // one continuation at a time, and it requeues the turn.
                    let previous = old.continuations ?? [], next = turn.continuations ?? []
                    guard !old.status.terminal, next.count == previous.count + 1, Array(next.dropLast()) == previous,
                          turn.status == .queued, turn.result == nil else { throw SubagentRecovery.damaged() }
                    identity.continuations = turn.continuations
                }
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
                      old.continuation == delivery.continuation, old.cursor == delivery.cursor, old.eventTurns == delivery.eventTurns,
                      !old.committed || delivery.committed else { throw SubagentRecovery.damaged() }
            } else {
                if delivery.continuation == true {
                    guard delivery.recipientID == ownerID, run != nil, !delivery.committed else { throw SubagentRecovery.damaged() }
                    run?.reportContinuations += 1
                }
                if let cursor = delivery.cursor {
                    if deliveryCursors == nil { deliveryCursors = [:] }; deliveryCursors?[delivery.recipientID] = cursor
                    if delivery.recipientID == ownerID { run?.deliveryCursor = cursor }
                }
            }
            deliveries[delivery.rowID] = delivery
            if delivery.committed {
                for id in delivery.eventIDs {
                    messages[id]?.disposition = "delivered"; messages[id]?.rowID = delivery.rowID
                    if let deliveredTurn = delivery.eventTurns?[id] { messages[id]?.turn = deliveredTurn }
                }
            }
            revision += 1
        case JournalRecordKind.agentNames:
            let adopted = try JSONDecoder().decode([String:String].self,from:data.data())
            let previous = names ?? [:]
            guard previous.allSatisfy({ adopted[$0.key] == $0.value }), Set(adopted.values).count == adopted.count,
                  adopted.values.allSatisfy({ $0.hasPrefix("/root/") && (try? SubagentCodexContract.canonical(String($0.dropFirst(6)))) == $0 }) else { throw SubagentRecovery.damaged() }
            names = adopted; revision += 1
        case JournalRecordKind.familyRun:
            run = try JSONDecoder().decode(AgentFamilyRun.self,from:data.data()); revision += 1
        default: break
        }
    }
}
