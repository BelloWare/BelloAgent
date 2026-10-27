import Foundation

/// Rebuildable, body-free references. The journals own acceptance/delivery;
/// capture links prove which physical requests produced or consumed a row.
struct AgentCoordinationEntry: Equatable, Sendable, Identifiable {
    var id: String, childID: String, turn: Int, kind: String, author: String
    var sourceSessionID: String, sourceMessageID: String? = nil, sourceToolCallID: String? = nil
    var recipientID: String, recipientMessageID: String? = nil
    var disposition: String
    var sourceAttemptID: String? = nil, consumingAttemptID: String? = nil
    var subagentNumber: Int? = nil
    var sender: String? = nil, recipient: String? = nil
    var queueOnly = false
    var title: String {
        if let sender, let recipient {
            let kind = ["NEW_TASK": "New task", "MESSAGE": "Message", "FINAL_ANSWER": "Final answer"][kind] ?? kind
            return (SubagentLabel.task(sender) ?? sender) + " → " + (SubagentLabel.task(recipient) ?? recipient) + " · " + kind
        }
        return SubagentLabel.name(subagentNumber) + " · " + kind.replacingOccurrences(of: "_", with: " ").capitalized + " · turn \(turn)"
    }
    var deliveryLabel: String {
        switch disposition {
        case "waiting_next_turn": "Waiting for its next turn"
        case "delivered": "Delivered"
        case "not_delivered_interrupted": "Not delivered · interrupted"
        case "held": "Pending for parent Resume"
        default: author == "parent" ? "Queued for steering" : "Pending delivery"
        }
    }
}
struct AgentCoordination: Equatable, Sendable {
    var entries: [AgentCoordinationEntry] = []
    var heldChildren: Set<String> = []
    var subagentNumbers: [String: Int] = [:]
}

extension HistoryReader {
    func agentCoordination(path: URL, ownerID: String) throws -> AgentCoordination {
        let fingerprint = try Self.coordinationFingerprint(path)
        if let cached = agentCoordinationCache[ownerID + "|" + path.path], cached.fingerprint == fingerprint { return cached.value }
        let value = try Self.scanCoordination(path: path, ownerID: ownerID, scanned: &subagentScannedBytes)
        keepCoordination(value, path: path, ownerID: ownerID, fingerprint: fingerprint, checkingFile: false)
        return value
    }
    /// The journal as the coordination cache knows it: the file, its size and
    /// when it was last written.
    nonisolated static func coordinationFingerprint(_ path: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return [attributes[.systemFileNumber], attributes[.size], attributes[.modificationDate]].map { String(describing: $0) }.joined(separator: ":")
    }
    /// A scan of the journal for its agents' coordination. It reads nothing of
    /// this reader, so it can also run off it and be kept here after
    /// (`WorkspaceModel.catchUpFinishedRows`).
    nonisolated static func scanCoordination(path: URL, ownerID: String, scanned: inout Int) throws -> AgentCoordination {
        var entries: [String: AgentCoordinationEntry] = [:], order: [String] = [], children: Set<String> = [], held: Set<String> = []
        var numbers: [String: Int] = [:]
        var active: Set<String> = [], codex: Set<String> = []
        func add(_ entry: AgentCoordinationEntry) {
            if entries[entry.id] == nil { order.append(entry.id) }
            entries[entry.id] = entry
        }
        try subagentRecords(path, scanned: &scanned) { row, line in
            if line == 1 { guard row["type"]?.string == "session", row["id"]?.string == ownerID else { throw StoreError.invalidRecord } }
            if let plan = Self.subagentPlan(row), let raw = plan["origin"],
               let origin = try? JSONDecoder().decode(SubagentHeader.self, from: JSONEncoder().encode(raw)), origin.link.valid {
                let id = origin.link.childSessionID
                // Copied starts reserve their number without granting this
                // fork ownership of the original child's messages or holds.
                if numbers[id] == nil { numbers[id] = numbers.count + 1 }
                if origin.link.budgetOwnerSessionID == ownerID {
                    children.insert(id)
                    if origin.taskName != nil { codex.insert(id) }
                }
            }
            let data = row["data"]?.object ?? [:]
            switch row["customType"]?.string {
            case "pi-app.agent-operation.v1":
                guard let key = data["key"]?.object, let source = key["parentSessionID"]?.string else { break }
                if let turn = data["turn"]?.object, let child = turn["childID"]?.string, children.contains(child), source == ownerID || children.contains(source),
                   let number = turn["turn"]?.nonnegativeInteger, number > 0, let input = turn["inputID"]?.string {
                    active.insert(child)
                    if turn["taskName"] != nil { codex.insert(child) }
                    add(.init(id: input, childID: child, turn: number, kind: turn["taskName"] == nil ? (number == 1 ? "task" : "follow_up") : "NEW_TASK", author: source == ownerID ? "parent" : "subagent",
                              sourceSessionID: source, sourceMessageID: key["assistantMessageID"]?.string, sourceToolCallID: key["toolCallID"]?.string,
                              recipientID: child, recipientMessageID: input, disposition: "pending", sender: turn["sender"]?.string, recipient: turn["taskName"]?.string))
                }
                if let message = data["message"]?.object, let id = message["id"]?.string, let child = message["childID"]?.string,
                   children.contains(child), let turn = message["turn"]?.nonnegativeInteger, turn > 0,
                   let author = message["author"]?.string, (author == "parent" && source == ownerID || author == "subagent" && (source == child || message["senderChildID"]?.string == source && children.contains(source))) {
                    let recipient = message["recipientChildID"]?.string ?? (message["recipient"]?.string == "/root" ? ownerID : author == "parent" ? child : ownerID)
                    guard recipient == ownerID || children.contains(recipient) else { break }
                    add(.init(id: id, childID: child, turn: turn, kind: message["type"]?.string ?? message["kind"]?.string ?? "note", author: author,
                              sourceSessionID: source, sourceMessageID: key["assistantMessageID"]?.string, sourceToolCallID: key["toolCallID"]?.string,
                              recipientID: recipient, disposition: message["disposition"]?.string ?? "pending",
                              sender: message["sender"]?.string, recipient: message["recipient"]?.string, queueOnly: message["queueOnly"]?.bool == true))
                }
            case "pi-app.subagent-turn-terminal.v1":
                guard let child = data["childID"]?.string, children.contains(child), let number = data["turn"]?.nonnegativeInteger else { break }
                active.remove(child)
                // V4 journals queue an explicit typed final answer. An
                // interrupt without one must never invent pending mail.
                guard !codex.contains(child) else { break }
                let id = "result:" + child + ":" + String(number)
                add(.init(id: id, childID: child, turn: number, kind: "result", author: "subagent", sourceSessionID: child,
                          sourceMessageID: data["result"]?.object?["metadata"]?.object?["resultRef"]?.object?["messageIds"]?.array?.first?.string,
                          recipientID: ownerID, disposition: "pending"))
            case "pi-app.agent-message.v1":
                if let id = data["id"]?.string, entries[id] == nil,
                   let child = data["childID"]?.string, children.contains(child),
                   let kind = data["type"]?.string, ["NEW_TASK", "MESSAGE", "FINAL_ANSWER"].contains(kind),
                   let turn = data["turn"]?.nonnegativeInteger, turn > 0,
                   let sender = data["sender"]?.string, let recipient = data["recipient"]?.string {
                    let sourceID = sender == "/root" ? ownerID : data["senderChildID"]?.string ?? child
                    let recipientID = recipient == "/root" ? ownerID : data["recipientChildID"]?.string ?? child
                    if (sourceID == ownerID || children.contains(sourceID)), (recipientID == ownerID || children.contains(recipientID)) {
                        add(.init(id: id, childID: child, turn: turn, kind: kind, author: sender == "/root" ? "parent" : "subagent",
                            sourceSessionID: sourceID, sourceMessageID: data["result"]?.object?["metadata"]?.object?["resultRef"]?.object?["messageIds"]?.array?.first?.string,
                            recipientID: recipientID, disposition: data["disposition"]?.string ?? "pending",
                            sender: sender, recipient: recipient, queueOnly: data["queueOnly"]?.bool == true))
                    }
                }
                if let id = data["id"]?.string, var entry = entries[id] {
                    entry.disposition = data["disposition"]?.string ?? entry.disposition
                    entry.sender = data["sender"]?.string ?? entry.sender; entry.recipient = data["recipient"]?.string ?? entry.recipient
                    entry.kind = data["type"]?.string ?? entry.kind; entry.queueOnly = data["queueOnly"]?.bool ?? entry.queueOnly
                    entries[id] = entry
                }
            case "pi-app.agent-delivery.v1":
                guard data["committed"]?.bool == true, let recipient = data["recipientID"]?.string, let rowID = data["rowID"]?.string else { break }
                for id in data["eventIDs"]?.array?.compactMap(\.string) ?? [] {
                    guard var entry = entries[id], entry.recipientID == recipient else { continue }
                    entry.recipientMessageID = rowID; entry.disposition = "delivered"; entries[id] = entry
                }
            case "pi-app.family-run.v1": held = Set(data["heldChildren"]?.array?.compactMap(\.string) ?? [])
            default: break
            }
            return true
        }
        return AgentCoordination(entries: order.compactMap { id in
            entries[id].map { value in
                var entry = value; entry.subagentNumber = numbers[entry.childID]
                if entry.queueOnly, entry.disposition == "pending", entry.recipientID != ownerID, !active.contains(entry.recipientID) { entry.disposition = "waiting_next_turn" }
                return entry
            }
        }, heldChildren: held.intersection(children), subagentNumbers: numbers)
    }
    /// A scan's coordination, kept for the journal it read. A scan made off
    /// this reader (`checkingFile`, `scanned`) is kept only while the file is
    /// still the one it read.
    func keepCoordination(_ value: AgentCoordination, path: URL, ownerID: String, fingerprint: String, checkingFile: Bool = true, scanned: Int = 0) {
        subagentScannedBytes += scanned
        if checkingFile { guard (try? Self.coordinationFingerprint(path)) == fingerprint else { return } }
        if agentCoordinationCache.count >= 8 { agentCoordinationCache.removeAll(keepingCapacity: true) }
        agentCoordinationCache[ownerID + "|" + path.path] = (fingerprint, value)
    }
}

extension PayloadArchive {
    func coordinationRequests(_ entries: [AgentCoordinationEntry], ownerID: String, workspaceID: String) async throws -> [AgentCoordinationEntry] {
        guard Self.inspectorScope(ownerID, workspaceID) else { throw CaptureFailure.unavailable }
        return try await dashboardReader().run(consumer: "inspector") { engine in
            try entries.map { original in
                try Task.checkCancellation()
                var entry = original
                func attempt(_ message: String?, role: String, session: String) throws -> String? {
                    guard let message else { return nil }
                    return try engine.db.rows("SELECT a.id FROM message_links l JOIN attempts a ON a.id=l.attempt WHERE l.message=? AND l.role=? AND a.session=? AND a.workspace=? AND (a.session=? OR a.local_owner=?) ORDER BY a.wall,a.id LIMIT 1",
                        [.text(message),.text(role),.text(session),.text(workspaceID),.text(ownerID),.text(ownerID)]).first?["id"]?.string
                }
                entry.sourceAttemptID = try attempt(entry.sourceMessageID, role: "output", session: entry.sourceSessionID)
                entry.consumingAttemptID = try engine.db.rows("SELECT a.id FROM attempts a WHERE a.session=? AND a.workspace=? AND (a.session=? OR a.local_owner=?) AND (EXISTS(SELECT 1 FROM agent_delivery_links d WHERE d.attempt=a.id AND d.event=?) OR (a.agent_delivery_ids IS NULL AND EXISTS(SELECT 1 FROM message_links l WHERE l.attempt=a.id AND l.role='context' AND l.message=?))) ORDER BY a.wall,a.id LIMIT 1",
                    [.text(entry.recipientID),.text(workspaceID),.text(ownerID),.text(ownerID),.text(entry.id),entry.recipientMessageID.map(CaptureSQLValue.text) ?? .null]).first?["id"]?.string
                if entry.consumingAttemptID != nil { entry.disposition = "delivered" }
                return entry
            }
        }
    }
}
