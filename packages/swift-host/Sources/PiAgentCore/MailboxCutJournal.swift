import Foundation

struct MailboxCutJournal: Codable, Sendable, Equatable {
    var preparations: [String:JSON] = [:]
    var commits: [String:JSON] = [:]
    var projected: [String:String] = [:]

    static func digest(_ preparation: JSON) -> String { sha256(Data(preparation.removing(["digest"]).encoded().utf8)) }
    mutating func consume(_ record: JSON) throws {
        let data = record["data"], kind = record["customType"].text
        if kind == JournalRecordKind.agentCutPrepared || kind == JournalRecordKind.agentCutCommitted {
            guard data["version"].int == 1, let id = data["cutId"].text, !id.isEmpty,
                  data["attemptId"].text?.isEmpty == false, data["recipientSessionId"].text?.isEmpty == false,
                  data["digest"].text?.count == 64 else { throw SubagentRecovery.damaged() }
            if kind == JournalRecordKind.agentCutPrepared {
                guard data["digest"].text == Self.digest(data), !data["rows"].list.isEmpty,
                      preparations[id] == nil || preparations[id] == data else { throw SubagentRecovery.damaged() }
                preparations[id] = data
            } else {
                guard commits[id] == nil || commits[id] == data else { throw SubagentRecovery.damaged() }
                commits[id] = data
            }
        }
        if record["type"].text == "message", record["message"]["nativeInherited"].isNull,
           !record["message"]["nativeMailboxCut"].isNull || !record["message"]["nativeAgentCallCancellation"].isNull {
            let id = try identity(record["id"]), hash = sha256(Data(record["message"].encoded().utf8))
            guard projected[id] == nil || projected[id] == hash else { throw SubagentRecovery.damaged() }
            projected[id] = hash
        }
    }
    static func rows(_ preparation: JSON, commit: JSON) throws -> [ChatMessage] {
        guard preparation["digest"].text == digest(preparation),
              ["cutId", "attemptId", "recipientSessionId", "digest"].allSatisfy({ preparation[$0] == commit[$0] }) else { throw SubagentRecovery.damaged() }
        let rows = try preparation["rows"].list.map { try ChatMessage(id:identity($0["id"]),pi:$0["message"]) }
        guard let first = rows.first, first.role == "assistant", first.nativeMailboxCut?["cutId"] == commit["cutId"],
              first.nativeMailboxCut?["version"].int == 1, first.nativeMailboxCut?["attemptId"] == commit["attemptId"],
              first.nativeMailboxCut?["responseId"].text?.isEmpty == false, first.nativeMailboxCut?["itemId"].text?.isEmpty == false,
              first.requestAttemptIDs == [commit["attemptId"].text!], first.usage?.isNull != false,
              Set(rows.map(\.id)).count == rows.count else { throw SubagentRecovery.damaged() }
        let calls = first.content.filter { $0["type"].text == "toolCall" }
        guard calls.count == rows.count - 1 else { throw SubagentRecovery.damaged() }
        for (call, result) in zip(calls,rows.dropFirst()) {
            guard result.role == "toolResult", result.toolCallId == call["id"].text,
                  result.isError, result.text == "Not executed: agent message arrived before dispatch.",
                  result.nativeAgentCallCancellation?["version"].int == 1, result.nativeAgentCallCancellation?["reason"].text == "agent_message",
                  result.nativeAgentCallCancellation?["cutId"] == commit["cutId"] else { throw SubagentRecovery.damaged() }
        }
        return rows
    }
}

extension AgentSession {
    func cancelMailboxDrains(source: String) {
        for commit in subagents.cuts?.commits.values.map({ $0 }) ?? [] where commit["recipientSessionId"].text == source {
            requestPermits[commit["attemptId"].text ?? ""]?.cancel()
        }
    }
    func waitForRequestDrains() async {
        guard hasMailboxDrains else { return }
        await withCheckedContinuation { requestDrainWaiters.append($0) }
    }
    func finishRequestDrainWaiters() {
        guard !hasMailboxDrains else { return }
        let waiting = requestDrainWaiters; requestDrainWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    private var hasMailboxDrains: Bool {
        subagents.cuts?.commits.values.contains { requestPermits[$0["attemptId"].text ?? ""] != nil } ?? false
    }
    /// Called before partial-log recovery and before unfinished family turns
    /// seal. Branches/forks keep historical rows; only missing projections of
    /// this recipient's committed preparation can be repaired.
    func recoverMailboxCuts() throws {
        guard let cuts = subagents.cuts else { return }
        for commit in cuts.commits.values.sorted(by: { $0["cutId"].text! < $1["cutId"].text! }) where commit["recipientSessionId"].text == id {
            guard let preparation = cuts.preparations[commit["cutId"].text ?? ""] else { throw SubagentRecovery.damaged() }
            let rows = try MailboxCutJournal.rows(preparation,commit:commit)
            if !isSubagent { try MailboxCutJournal.validate(commit,preparation:preparation,accounting:accounting) }
            var previous = preparation["branchId"]
            for row in rows {
                if let hash = cuts.projected[row.id] {
                    guard hash == sha256(Data(row.pi.encoded().utf8)) else { throw SubagentRecovery.damaged() }
                } else {
                    guard journal?.markerKind == JournalRecordKind.cutinMarker, previous == (context.last.map { JSON($0.id) } ?? .null) else { throw SubagentRecovery.damaged() }
                    try append(row); try journal?.synchronize()
                }
                previous = JSON(row.id)
            }
        }
    }
    func prepareMailboxCut(_ candidate: ModelReply, events: [String], scope: RequestScope) throws -> JSON? {
        guard let cut = candidate.mailboxCut, !events.isEmpty, let journal,
              !closed, !agentDeliveryHeld, !costPaused, agentContractVersion == 4,
              scope.turnID == currentTurnID, requestPermits[cut.attemptId] != nil else { return nil }
        try requestPermits[cut.attemptId]?.check()
        var assistant = candidate.message
        assistant.id = partialID ?? assistant.id; assistant.timestamp = Date().timeIntervalSince1970 * 1000
        assistant.turn = currentTurnID; assistant.taskRootID = taskRootID; assistant.taskExecutionID = activeTaskPresentation?.executionID
        assistant.nativeMailboxCut = try subagentJSON(cut); assistant.usage = nil; assistant.contextUsageBinding = nil
        // Canonical content only: a display timeline may contain an open suffix.
        assistant.responseTimeline = nil
        var rows = [assistant]
        for call in candidate.calls {
            var result = ChatMessage(role:"toolResult",content:[textBlock("Not executed: agent message arrived before dispatch.")])
            result.toolCallId = call.id; result.toolName = call.name; result.isError = true
            result.turn = assistant.turn; result.taskRootID = assistant.taskRootID; result.taskExecutionID = assistant.taskExecutionID; result.timestamp = assistant.timestamp
            result.toolStats = ["outcome":"not_executed"]
            result.nativeAgentCallCancellation = ["version":1,"cutId":JSON(cut.cutId),"reason":"agent_message"]
            rows.append(result)
        }
        var data: JSON = ["version":1,"cutId":JSON(cut.cutId),"attemptId":JSON(cut.attemptId),"turnId":JSON(scope.turnID),
                          "branchId":context.last.map { JSON($0.id) } ?? .null,"generation":JSON(stopCount),"recipientSessionId":JSON(id),
                          "eventIds":.array(events.map(JSON.string)),"rows":.array(rows.map { ["id":JSON($0.id),"message":$0.pi] })]
        data["digest"] = JSON(MailboxCutJournal.digest(data))
        // Leave room for the journal envelope; never truncate opaque state.
        guard data.encoded().utf8.count < 32 * 1024 * 1024 - 4096 else { return nil }
        try appendAgentRecord(JournalRecordKind.agentCutPrepared,data)
        try journal.synchronize()
        receivingAgentMessage = true; event("subagents.changed")
        return data
    }
    func promoteMailboxCut(_ preparation: JSON) throws {
        guard preparation["generation"].int == stopCount, preparation["branchId"] == (context.last.map { JSON($0.id) } ?? .null),
              !closed, !agentDeliveryHeld else { throw CancellationError() }
        try requestPermits[preparation["attemptId"].text ?? ""]?.check()
        try journal?.promoteToMailboxCut(managedChild:isSubagent)
    }
    func commitMailboxCut(_ preparation: JSON, scope: RequestScope) throws -> JSON {
        let attempt = preparation["attemptId"].text ?? ""
        try validateRequestOwner(scope)
        guard !closed, !agentDeliveryHeld, scope.ownerGeneration == stopCount,
              accounting.attempts[attempt]?.admission?["state"].text == "dispatched",
              accounting.attempts[attempt]?.admission?["scope"] == (try subagentJSON(scope)),
              let permit = requestPermits[attempt],
              preparation["eventIds"].list.allSatisfy({ event in agentState().messages[event.text ?? ""]?.disposition == "pending" }) else { throw CancellationError() }
        try permit.check(); try enforceCostLimit()
        try journal?.promoteToMailboxCut(managedChild:false)
        let commit = preparation.removing(["turnId", "branchId", "generation", "eventIds", "rows"])
        try appendAgentRecord(JournalRecordKind.agentCutCommitted,commit)
        return commit
    }
    func projectMailboxCut(_ preparation: JSON, commit: JSON, owner: String) throws -> ChatMessage {
        // The commit owns recovery from now on, even if projection fails.
        retireMailboxPartial()
        if subagents.cuts?.commits[commit["cutId"].text ?? ""] == nil { try appendAgentRecord(JournalRecordKind.agentCutCommitted,commit,owner:owner) }
        let rows = try MailboxCutJournal.rows(preparation,commit:commit)
        for row in rows {
            if let saved = subagents.cuts?.projected[row.id] {
                guard saved == sha256(Data(row.pi.encoded().utf8)) else { throw SubagentRecovery.damaged() }
            } else { try append(row); try journal?.synchronize() }
        }
        boundary = context; event("message_end"); return rows[0]
    }
    func retireMailboxPartial() {
        partialID = nil; partialText = ""; partialThinking = ""; resetPartialRow(); partialLedgerID = nil
        removeStreamedLog()
    }
    func endMailboxDelivery() { if receivingAgentMessage { receivingAgentMessage = false; event("subagents.changed") } }
}

extension MailboxCutJournal {
    static func validate(_ commit: JSON, preparation: JSON, accounting: AttemptAccounting) throws {
        guard let admission = accounting.attempts[commit["attemptId"].text ?? ""]?.admission,
              admission["state"].text == "dispatched", admission["sourceSessionId"] == commit["recipientSessionId"],
              admission["scope"]["turnID"] == preparation["turnId"] else { throw SubagentRecovery.damaged() }
    }
}

extension AgentSteeringCoordinator {
    func cut(_ candidate: ModelReply, recipient: AgentSession, scope: RequestScope) async throws -> ModelReply? {
        let lease = await recipient.agentLease
        let owner: AgentSession
        if let lease {
            guard let job = jobs[lease.id], job.child === recipient, !job.cancelled, !job.sealed else { return nil }
            owner = job.owner
        } else { owner = recipient }
        let lock = gate(owner.id); try await lock.acquire()
        do {
            guard await recipient.agentContractVersion == 4, !(await recipient.agentDeliveryHeld) else { await lock.release(); return nil }
            let state = await owner.agentState()
            let events = state.messages.values.filter {
                $0.type != nil && $0.disposition == "pending" && ($0.recipientChildID ?? owner.id) == recipient.id &&
                $0.id != lease?.inputID && (lease == nil || $0.queueOnly == true || $0.turn == lease?.turn)
            }.sorted { $0.sequence < $1.sequence }.map(\.id)
            guard !events.isEmpty, let preparation = try await recipient.prepareMailboxCut(candidate,events:events,scope:scope) else { await lock.release(); return nil }
            try await recipient.promoteMailboxCut(preparation)
            // A failed fsync can still leave a commit on disk. From this
            // point recovery must use the reserved rows, never a partial row
            // with the same ID and different content.
            await recipient.retireMailboxPartial()
            let commit = try await owner.commitMailboxCut(preparation,scope:scope)
            var result = candidate
            result.message = try await recipient.projectMailboxCut(preparation,commit:commit,owner:owner.id)
            await lock.release(); return result
        } catch {
            await recipient.endMailboxDelivery(); await lock.release()
            if !(error is CancellationError), (error as? AgentError)?.code != AgentSession.costLimitCode { await owner.failFamilyAccounting(error) }
            throw error
        }
    }
}
