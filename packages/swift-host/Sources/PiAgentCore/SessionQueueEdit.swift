import Foundation

// Rewriting a queued message: while one is being edited, every pending
// message in the chat waits, steering and follow-ups alike. The run that is
// going goes on; nothing pending is claimed until the edit is saved,
// cancelled or the message removed. Each edit has the app's identity, and
// its outcome is kept, so a reply lost to a crash or a restart can be told
// apart from a later edit.

/// The queued message being rewritten, which holds the chat's pending input.
struct QueueEditHold: Codable, Sendable, Equatable {
    var editID: String, turnID: String, lane: String, sequence: Int
    var value: JSON { ["editId":JSON(editID),"turnId":JSON(turnID),"kind":JSON(lane),"sequence":JSON(sequence)] }
}

/// How one edit ended: `saved` (with the digest of the text it saved, so a
/// repeat of the same Save is recognised and a different one refused),
/// `cancelled` or `removed`.
struct QueueEditOutcome: Codable, Sendable, Equatable {
    var editID: String, turnID: String, outcome: String, sequence: Int, textDigest: String?
    /// The hold revision this outcome was recorded at.
    var revision: Int?
}

extension AgentSession {
    /// Outcomes kept to recognise an edit whose reply was lost.
    static let queueEditOutcomeLimit = 64
    /// The hold as it stands, for every answer: a reader adopts this, not a
    /// guess that the hold is gone.
    var heldValue: JSON { queueEdit.map { $0.value } ?? .null }
    /// Whether pending input may be claimed now.
    var pendingInputHeld: Bool { queueEdit != nil }

    func queueEditOutcome(_ editID: String) -> QueueEditOutcome? { queueEditOutcomes.last { $0.editID == editID } }
    static func resolvedError(_ outcome: QueueEditOutcome) -> AgentError {
        let words = outcome.outcome == "saved" ? "was already saved" : outcome.outcome == "removed" ? "was removed" : "was already cancelled"
        return AgentError("queue_edit_" + outcome.outcome, "That queued edit \(words).")
    }
    static func validEditID(_ editID: String) throws {
        guard !editID.isEmpty, editID.utf8.count <= 128 else { throw AgentError("invalid_params", "An edit identity is 1–128 bytes") }
    }
    /// A journal whose last write may or may not have landed can't vouch for
    /// any edit: nothing is answered until a reopen reads what it holds.
    func requireCertainJournal() throws {
        // What a reopen read may not have been synced before the restart:
        // the first edit command after an open forces the file to disk.
        if !queueEditJournalConfirmed, let journal, !journal.writeOutcomeUncertain {
            do { try journal.confirmDurable(); queueEditJournalConfirmed=true } catch { }
        }
        if journal?.writeOutcomeUncertain == true {
            throw AgentError(AgentErrorCode.journalUncertain, "The chat's journal could not be synchronized, so the queued edit's state is unknown. Reopen the chat before continuing; nothing waiting was sent.")
        }
    }
    /// Where a pending message is: its lane and index.
    func pendingPosition(_ turnID: String) -> (lane: String, index: Int)? {
        if let i=queue.firstIndex(where: { $0.turnID == turnID }) { return ("follow-up", i) }
        if let i=steering.firstIndex(where: { $0.turnID == turnID }) { return ("steering", i) }
        return nil
    }
    func queueEditReply(_ hold: QueueEditHold) -> JSON {
        var value = hold.value
        guard let position = pendingPosition(hold.turnID) else { return value }
        let item = position.lane == "steering" ? steering[position.index] : queue[position.index]
        for (key, field) in item.previewValue.map where !["text","textTruncated","turnId","commandId"].contains(key) { value[key] = field }
        value["commandId"]=JSON(item.commandID); value["text"]=JSON(item.text); value["textBytes"]=JSON(item.text.utf8.count)
        value["attachmentCount"]=JSON(item.attachments.count); value["skillCount"]=JSON(item.skills.count)
        value["revision"]=JSON(queueEditRevision); value["held"]=heldValue
        return value
    }

    /// Takes the hold and reads the whole message, as one step: from here
    /// no pending message in the chat is claimed until the edit resolves.
    /// A message already taken for delivery can't be edited. The hold is on
    /// disk before the reply. Repeating the same Begin returns the same edit.
    public func beginQueueEdit(turnID: String, editID: String, basis: Int? = nil) throws -> JSON {
        guard !closed else { throw AgentError("session_closed","Session runtime is unloaded") }
        try Self.validEditID(editID); try requireCertainJournal()
        if let hold=queueEdit {
            guard hold.editID == editID else { throw AgentError("queue_edit_busy", "Another queued message in this chat is being edited. Finish or cancel that edit first.") }
            guard hold.turnID == turnID else { throw AgentError("command_conflict", "That edit identity belongs to another queued message") }
            return queueEditReply(hold)
        }
        if let outcome=queueEditOutcome(editID) { throw Self.resolvedError(outcome) }
        // A Begin asked before the oldest outcome still remembered may be a
        // late copy of an edit already resolved and forgotten: refused.
        if queueEditForgottenRevision > 0, (basis ?? -1) < queueEditForgottenRevision {
            throw AgentError("queue_edit_expired", "That edit request is too old to be told apart from one already resolved. Choose Edit again.")
        }
        guard let position=pendingPosition(turnID) else {
            if delivering?.submission.turnID == turnID || hasDeliveredTurn(turnID) {
                throw AgentError("queue_delivering", "That message is already being sent, so it can no longer be edited.")
            }
            throw AgentError("queue_missing", "Queued message is no longer pending")
        }
        let previous=(queueEditSequence, queueEditRevision)
        queueEditSequence += 1; queueEditRevision += 1
        let hold=QueueEditHold(editID:editID,turnID:turnID,lane:position.lane,sequence:queueEditSequence)
        queueEdit=hold
        do { try persistState(durable:true) }
        catch {
            // Written or not, nothing pending is claimed: an unsure write
            // keeps the hold until a reopen reads what the journal holds.
            if journal?.writeOutcomeUncertain == true { throw AgentError(AgentErrorCode.journalUncertain, "The edit may have started, but the journal could not be synchronized. Reopen the chat before continuing.") }
            queueEdit=nil; (queueEditSequence, queueEditRevision)=previous; throw error
        }
        event("queue.changed")
        return queueEditReply(hold)
    }

    /// Saves the rewrite in the message's place: its identity, lane,
    /// position, images, skills and model choices stay. Repeating a Save
    /// that took effect answers as it did; a late Save of an edit that was
    /// cancelled or removed is refused.
    public func saveQueueEdit(editID: String, text: String) throws -> JSON {
        try Self.validEditID(editID); try requireCertainJournal()
        let digest=sha256(Data(text.utf8))
        if queueEdit?.editID != editID, let outcome=queueEditOutcome(editID) {
            guard outcome.outcome == "saved" else { throw Self.resolvedError(outcome) }
            guard outcome.textDigest == digest else { throw AgentError("command_conflict", "That edit was saved with other text") }
            return ["accepted":true,"outcome":"saved","turnId":JSON(outcome.turnID),"repeated":true,"revision":JSON(queueEditRevision),"held":heldValue]
        }
        guard let hold=queueEdit, hold.editID == editID, let position=pendingPosition(hold.turnID) else {
            throw AgentError("queue_edit_missing", "That queued edit is no longer open")
        }
        var item = position.lane == "steering" ? steering[position.index] : queue[position.index]
        guard text.utf8.count <= 262144 else { throw AgentError("queue_limit", "Message or queue limit exceeded") }
        guard !text.isEmpty || !item.skills.isEmpty || !item.attachments.isEmpty else { throw AgentError("empty_message", "Enter a message or select a skill") }
        if item.text != text { item.text=text; item.textRevision=(item.textRevision ?? 0) + 1 }
        return try resolveQueueEdit(hold, outcome:"saved", digest:digest, replacing:(position.lane, position.index, item))
    }
    /// Leaves the message as it was and releases the hold.
    public func cancelQueueEdit(editID: String) throws -> JSON {
        try Self.validEditID(editID); try requireCertainJournal()
        if queueEdit?.editID != editID, let outcome=queueEditOutcome(editID) {
            guard outcome.outcome == "cancelled" else { throw Self.resolvedError(outcome) }
            return ["accepted":true,"outcome":"cancelled","turnId":JSON(outcome.turnID),"repeated":true,"revision":JSON(queueEditRevision),"held":heldValue]
        }
        guard let hold=queueEdit, hold.editID == editID else {
            // A Cancel for an edit this chat never granted (its Begin's reply
            // was lost, or it is still on its way) is remembered, so that
            // Begin can't take the hold afterwards.
            guard queueEditOutcome(editID) == nil else { throw AgentError("queue_edit_missing", "That queued edit is no longer open") }
            try rememberQueueEditOutcome(QueueEditOutcome(editID:editID,turnID:"",outcome:"cancelled",sequence:0,textDigest:nil))
            return ["accepted":true,"outcome":"cancelled","unknown":true,"revision":JSON(queueEditRevision),"held":heldValue]
        }
        return try resolveQueueEdit(hold, outcome:"cancelled", digest:nil)
    }
    /// Removes the message being edited and releases the hold, as one step:
    /// never a Cancel and then a Remove, between which it could be sent.
    public func removeQueueEdit(editID: String) throws -> JSON {
        try Self.validEditID(editID); try requireCertainJournal()
        if queueEdit?.editID != editID, let outcome=queueEditOutcome(editID) {
            guard outcome.outcome == "removed" else { throw Self.resolvedError(outcome) }
            return ["accepted":true,"outcome":"removed","turnId":JSON(outcome.turnID),"repeated":true,"revision":JSON(queueEditRevision),"held":heldValue]
        }
        guard let hold=queueEdit, hold.editID == editID else { throw AgentError("queue_edit_missing", "That queued edit is no longer open") }
        return try resolveQueueEdit(hold, outcome:"removed", digest:nil, removing:true)
    }
    /// What became of an edit: `active` (with the held message's whole
    /// text), `saved`, `cancelled`, `removed`, or `unknown` when this chat
    /// has no record of it.
    public func queueEditStatus(editID: String) throws -> JSON {
        try Self.validEditID(editID); try requireCertainJournal()
        if let hold=queueEdit, hold.editID == editID { var value=queueEditReply(hold); value["state"]="active"; return value }
        if let outcome=queueEditOutcome(editID) {
            var value: JSON=["editId":JSON(editID),"turnId":JSON(outcome.turnID),"state":JSON(outcome.outcome),"sequence":JSON(outcome.sequence),"revision":JSON(queueEditRevision),"held":heldValue]
            if let digest=outcome.textDigest { value["textDigest"]=JSON(digest) }
            return value
        }
        return ["editId":JSON(editID),"state":"unknown","revision":JSON(queueEditRevision),"held":heldValue]
    }

    /// One resolution: the change, the outcome and the released hold are
    /// written together, forced to disk, before anything pending may be
    /// claimed. A write that fails leaves everything as it was, the hold
    /// included; one that may or may not have reached the journal keeps
    /// the hold too, until a reopen reads which it was.
    private func resolveQueueEdit(_ hold: QueueEditHold, outcome: String, digest: String?, replacing: (lane: String, index: Int, item: Submission)? = nil, removing: Bool = false) throws -> JSON {
        let before=(queue: queue, steering: steering, commands: commands, outcomes: queueEditOutcomes, revision: queueEditRevision, state: state, paused: queuePaused)
        if let replacing { if replacing.lane == "steering" { steering[replacing.index]=replacing.item } else { queue[replacing.index]=replacing.item } }
        // Only the hold is released: a Stop, failure or reopen pause stays.
        if removing, let item=(queue+steering).first(where: { $0.turnID == hold.turnID }) {
            queue.removeAll { $0.turnID == hold.turnID }; steering.removeAll { $0.turnID == hold.turnID }
            commandState(item,"removed")
        }
        let forgotten=queueEditForgottenRevision
        queueEdit=nil; queueEditRevision += 1
        appendQueueEditOutcome(QueueEditOutcome(editID:hold.editID,turnID:hold.turnID,outcome:outcome,sequence:hold.sequence,textDigest:digest,revision:queueEditRevision))
        do { try persistState(durable:true) }
        catch {
            queue=before.queue; steering=before.steering; commands=before.commands; queueEditOutcomes=before.outcomes; queueEditForgottenRevision=forgotten
            queueEditRevision=before.revision; state=before.state; queuePaused=before.paused; queueEdit=hold
            if journal?.writeOutcomeUncertain == true {
                throw AgentError(AgentErrorCode.journalUncertain, "The edit may have been saved, but the journal could not be synchronized. Reopen the chat before continuing; nothing waiting was sent.")
            }
            throw error
        }
        event(hold.lane == "steering" ? "steering.queued" : "queue.changed")
        releaseHeldInput()
        return ["accepted":true,"outcome":JSON(outcome),"turnId":JSON(hold.turnID),"revision":JSON(queueEditRevision),"held":heldValue]
    }
    /// With the hold gone, pending work goes on once, when nothing else
    /// holds it: a run that is going takes it at its next boundary; an idle
    /// chat starts one unless Stop, a failure or a reopen paused it.
    func releaseHeldInput() {
        guard !closed, runTask == nil, queueEdit == nil, !queuePaused, state != .error, !queue.isEmpty || !steering.isEmpty else { return }
        launch()
    }
    /// Keeps an outcome; the oldest beyond the limit is forgotten, and Begins
    /// asked before it are refused from then on.
    func appendQueueEditOutcome(_ outcome: QueueEditOutcome) {
        queueEditOutcomes.append(outcome)
        while queueEditOutcomes.count > Self.queueEditOutcomeLimit {
            let dropped=queueEditOutcomes.removeFirst()
            queueEditForgottenRevision=max(queueEditForgottenRevision, (dropped.revision ?? queueEditRevision) + 1)
        }
    }
    private func rememberQueueEditOutcome(_ outcome: QueueEditOutcome) throws {
        let before=(queueEditOutcomes, queueEditForgottenRevision, queueEditRevision)
        queueEditRevision += 1
        var outcome=outcome; outcome.revision=queueEditRevision
        appendQueueEditOutcome(outcome)
        do { try persistState(durable:true) }
        catch { (queueEditOutcomes, queueEditForgottenRevision, queueEditRevision)=before; throw error }
    }
    func hasDeliveredTurn(_ turnID: String) -> Bool { history.contains { $0.role == "user" && $0.id == turnID } }
}
