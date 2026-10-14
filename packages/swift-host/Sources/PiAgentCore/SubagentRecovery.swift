import Foundation

/// Reconciles durable evidence before a reopened parent can Resume. It never
/// creates a run, submits a child task, or invokes a tool. Parent results already
/// written (including by an older helper) are immutable transcript history.
enum SubagentRecovery {
    static func recover(state: SubagentJournalState, context: [ChatMessage], parent: SessionJournal,
                        owner: String, directory: URL, accounting: inout AttemptAccounting,
                        spend: inout SessionSpend) throws -> [SubagentCallKey: SubagentToolResult] {
        var results: [SubagentCallKey: SubagentToolResult] = [:]
        let history = ToolHistoryIndex(context)
        func commit(_ kind: String, _ data: JSON) throws {
            var next = accounting, total = spend
            guard try next.consume(kind: kind, data: data, spend: &total) else { return }
            try parent.append(["type":"custom","customType":JSON(kind),"data":data], flush: true)
            accounting = next; spend = total
        }
        for id in state.callOrder ?? state.plans.keys.sorted() {
            guard let plan = state.plans[id] else { continue }
            if state.family?.latest(plan.origin.link.childSessionID) != nil { continue }
            let link = plan.origin.link, key = link.call
            guard link.valid, link.budgetOwnerSessionID == owner else { throw damaged() }
            let alreadyPaired = state.outcomes?[id] != nil || history.results[key.assistantMessageID]?[key.toolCallID] != nil
            let childID = try identity(JSON(link.childSessionID))
            let url = canonical(directory.appendingPathComponent(childID + ".jsonl").path)
            guard within(url, canonical(directory.path)) else { throw damaged() }
            let attempts = accounting.attempts.values.filter { $0.admission?["delegationId"].text == id }
            let exists = FileManager.default.fileExists(atPath: url.path)
            let completed = state.outcomes?[id] == .completed || state.outcomes?[id] == .outputLimited
            guard exists || !completed && !attempts.contains(where: { $0.admission?["state"].text == "dispatched" }) else {
                throw AgentError("subagent_recovery", "A child journal is missing after possible execution. No delegated task was restarted; restore the journal before continuing. Saved parent history remains available.")
            }
            var child = SubagentJournalState(), childAccounting = AttemptAccounting(), childSpend = SessionSpend()
            var writer: SessionJournal?, childBytes: UInt64 = 0
            var markerOnly = true, childMessages = Set<String>()
            if exists {
                try SessionJournal.verifyManagedChild(url: url, id: childID)
                let reader = try JournalRecordReader(url)
                while let line = try reader.nextLine() {
                    if line.isEmpty { continue }
                    let record = try JSON.parse(line)
                    if record["type"].text == "message", let message = record["id"].text { childMessages.insert(message) }
                    if record["type"].text != "session", record["customType"].text != JournalRecordKind.childMarker { markerOnly = false }
                    try child.consume(record, sessionID: childID)
                    if let kind = record["customType"].text { try childAccounting.consume(kind: kind, data: record["data"], spend: &childSpend) }
                }
                childBytes = reader.size
                guard child.origin == plan.origin || child.origin == nil && markerOnly else { throw damaged() }
            }
            func writeChild(_ kind: String, _ data: JSON) throws {
                if writer == nil {
                    writer = try SessionJournal(url: url, id: childID, cwd: directory, binding: nil, create: false)
                    guard writer?.size == childBytes else { throw damaged() }
                }
                try writer?.append(["type":"custom","customType":JSON(kind),"data":data], flush: true)
            }
            if exists, child.origin == nil {
                // Creation stopped after the v2 marker and before origin. No
                // child content exists and the parent durably accepted this ID.
                try writeChild(JournalRecordKind.subagentOrigin, subagentJSON(plan.origin))
                child.origin = plan.origin
            }
            // A child mirror is evidence only for an admitted physical attempt
            // of this exact delegation. It can fill a missing/unknown charge,
            // never import another chat's spend or overwrite a known revision.
            for (attempt, entry) in childAccounting.attempts {
                guard let cost = entry.contribution else { continue }
                guard let owned = accounting.attempts[attempt], let admission = owned.admission,
                      admission["sourceSessionId"].text == childID, admission["budgetOwnerSessionId"].text == owner,
                      admission["delegationId"].text == id, admission["state"].text == "dispatched",
                      cost["sourceSessionId"] == admission["sourceSessionId"], cost["budgetOwnerSessionId"] == admission["budgetOwnerSessionId"],
                      cost["delegationId"] == admission["delegationId"] else { throw damaged() }
                if owned.contribution == nil || owned.contribution?["unreported"].int == 1 && cost["reported"].int == 1 {
                    var value = cost; value["accountingRevision"] = JSON(accounting.revision + 1)
                    try commit(owned.contribution == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate, value)
                }
            }
            let settledAttempts = accounting.attempts.values.filter { $0.admission?["delegationId"].text == id }
            if exists {
                for entry in settledAttempts {
                    guard let cost = entry.contribution, let attempt = cost["attemptId"].text else { continue }
                    let prior = childAccounting.attempts[attempt]?.contribution
                    if prior == nil || prior?["unreported"].int == 1 && cost["reported"].int == 1 {
                        try writeChild(prior == nil ? JournalRecordKind.cost : JournalRecordKind.costUpdate, cost)
                    }
                }
            }
            let result: SubagentToolResult
            if let terminal = child.terminal {
                result = try JSONDecoder().decode(SubagentToolResult.self, from: terminal["result"].data())
                guard result.status.terminal, terminal["status"] == result.envelope["status"],
                      result.metadata["status"] == result.envelope["status"], result.metadata["version"].int == 1,
                      result.envelope["truncated"].flag != nil,
                      case .array(let references) = result.metadata["resultRef"]["messageIds"],
                      references.allSatisfy({ $0.text.map(childMessages.contains) ?? false }),
                      result.messageID == plan.resultMessageID, result.metadata["delegationId"].text == id,
                      result.metadata["sessionId"].text == childID, result.metadata["budgetOwnerSessionId"].text == owner,
                      result.metadata["parentAssistantMessageId"].text == key.assistantMessageID,
                      result.metadata["toolCallId"].text == key.toolCallID,
                      (result.envelope["text"].text?.utf8.count ?? Int.max) <= 65_536 else { throw damaged() }
            } else {
                let began = child.status == .running || child.status == .stopping || attempts.contains { $0.admission?["state"].text == "dispatched" }
                result = SubagentToolResult(plan: plan, status: began ? .interrupted : .notExecuted,
                    error: AgentError(began ? "subagent_interrupted" : "subagent_not_started", began
                        ? "The helper stopped before a durable child result. Effects may already have occurred. This task was not restarted."
                        : "The helper stopped before this task began. It was not restarted."), accountingRevision: accounting.revision, began: began)
                if exists { try writeChild(JournalRecordKind.subagentTerminal, ["delegationID":JSON(id),"status":JSON(result.status.rawValue),"result":try subagentJSON(result)]) }
            }
            if !alreadyPaired { results[key] = result }
        }
        // Admission alone precedes dispatch intent. A stopped process cannot
        // have sent that attempt; dispatched attempts without costs stay unknown.
        for entry in Array(accounting.attempts.values) {
            guard entry.contribution == nil, var admission = entry.admission, admission["state"].text == "admitted" else { continue }
            admission["state"] = "not_dispatched"; admission["accountingRevision"] = JSON(accounting.revision + 1)
            try commit(JournalRecordKind.budgetAttempt, admission)
        }
        return results
    }
    static func damaged() -> AgentError {
        AgentError("subagent_recovery", "The parent and child journals disagree. No delegated task was restarted; inspect their saved history before continuing.")
    }
}
