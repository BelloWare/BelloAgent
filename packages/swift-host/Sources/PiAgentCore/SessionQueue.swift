import Foundation

// Pending work: the follow-up queue, the steering lane, and delivering
// a submission into the conversation.

extension AgentSession {
    // A terminal run can still own its task while final request links are
    // persisted. That task no longer has a model/tool boundary to steer.
    var acceptsSteering: Bool { runTask != nil && state == .running }
    func commandState(_ submission: Submission, _ status: String) {
        let record: JSON=["commandId":JSON(submission.commandID),"turnId":JSON(submission.turnID),"status":JSON(status),"state":JSON(status)]
        if let i=commands.firstIndex(where:{$0["turnId"].text == submission.turnID}) { commands[i]=record } else { commands.append(record) }
        if commands.count > 128 { commands.removeFirst(commands.count-128) }
    }
    func validate(_ input: Submission, steer: Bool) throws {
        guard !closed else { throw AgentError("session_closed","Session runtime is unloaded") }
        guard !input.text.isEmpty || !input.skills.isEmpty || !input.attachments.isEmpty else { throw AgentError("empty_message", "Enter a message or select a skill") }
        guard input.text.utf8.count <= 262144, queue.count + steering.count + (delivering == nil ? 0 : 1) < 64 else { throw AgentError("queue_limit", "Message or queue limit exceeded") }
        guard !commands.contains(where:{$0["turnId"].text == input.turnID}), !history.contains(where:{$0.id == input.turnID}) else { throw AgentError("duplicate_turn", "Turn identity already accepted; no duplicate submission was made") }
        let turn = try profile.overriding(input)
        // Images are refused where the message is typed, before it is
        // accepted: a model that takes none, or a file gone or changed.
        if !input.attachments.isEmpty {
            guard turn.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
            // Read, checked against its digest and signature, and converted as
            // delivery will: an image that can't be sent is refused now, not
            // replaced by a message about it once the draft has gone.
            let blocks = try loadImages(input.attachments)
            guard blocks.filter({ $0["type"].text == "image" }).count == input.attachments.count else {
                throw AgentError("attachment_unreadable", "An image could not be prepared for the model; select another")
            }
        }
        if steer, !acceptsSteering { throw AgentError("not_running", "Steering requires an active run; send a normal message") }
        // A message sent to a chat at its cost limit is refused where it was
        // typed, with the same words as a run stopped there, also when earlier
        // messages wait: nothing can run until the limit is raised. One sent
        // while a run is going waits in the queue, which pauses if the run stops.
        // While a queued message is being edited, a new one joins the held
        // queue; the limit is checked when it is delivered.
        if !steer, runTask == nil, queueEdit == nil { try enforceCostLimit() }
    }
    /// Stop (or a failure) left messages waiting: a new one joins them, after
    /// them, and nothing is sent until Resume.
    /// So does a family paused at its cost limit: a message sent after the
    /// limit is raised waits for Resume, which never happens by itself.
    /// Held tool calls (`costPendingCalls`) and a cut compaction wait like a
    /// pause, also once the pause itself is over (a helper that ended before Resume ran them): a
    /// message sent now goes after them, through Resume.
    var pausedWithPending: Bool { runTask == nil && queuePaused && (!queue.isEmpty || !steering.isEmpty || costPaused || !costPendingCalls.isEmpty || costPendingCompaction) }
    static var costPausedResumeError: AgentError {
        AgentError(costLimitCode, "This chat is paused at its cost limit. Choose Resume to go on with the paused work.")
    }
    func checkSubmissionStop(_ admittedAt: Int?) throws {
        guard admittedAt == nil || admittedAt == stopCount else {
            throw AgentError("submission_stopped", "The chat was stopped while preparing this message. Send it again when ready.")
        }
    }
    public func submit(_ input: Submission, steer: Bool, admittedAt: Int? = nil) throws -> JSON {
        try requireIndependentSession()
        try requireAgentExecution()
        return try submitManaged(input, steer: steer, admittedAt: admittedAt)
    }
    /// Only the coordinator submits a managed child's initial task.
    func submitManaged(_ input: Submission, steer: Bool, admittedAt: Int? = nil) throws -> JSON {
        // The comparison and admission share this actor turn: Stop cannot
        // slip between the final preflight check and launching the run.
        try checkSubmissionStop(admittedAt)
        try validate(input,steer:steer)
        let paused = pausedWithPending
        if steer { steering.append(input) } else { queue.append(input) }; commandState(input,"queued")
        do { try persistState() } catch { if steer { steering.removeLast() } else { queue.removeLast() }; commands.removeAll{$0["turnId"].text == input.turnID}; throw error }
        if steer { steeringAdmitted() } else { event("queue.changed") }
        let held = queueEdit != nil
        let queued=runTask != nil || paused || held
        if runTask == nil, !paused, !held { queuePaused=false; launch() }
        return ["accepted":true,"turnId":JSON(input.turnID),"queued":JSON(queued),"queueCount":JSON(queue.count),"delivery":JSON(held ? "after-edit" : steer ? "after-current-model-tool-turn" : paused ? "after-resume" : queued ? "after-run-would-stop" : "start")]
    }
    public func removeQueued(_ turnID: String) throws {
        // The message being edited goes with its hold, in one step.
        if let hold=queueEdit, hold.turnID == turnID { _ = try removeQueueEdit(editID:hold.editID); return }
        guard let item=(queue+steering).first(where:{$0.turnID == turnID}) else { throw AgentError("queue_missing", "Queued message is no longer pending") }
        let oldQ=queue, oldS=steering, oldState=state, oldPaused=queuePaused; queue.removeAll{$0.turnID == turnID}; steering.removeAll{$0.turnID == turnID}; commandState(item,"removed")
        // A stopped run the model has not answered stays paused, with Resume.
        if runTask == nil && queue.isEmpty && steering.isEmpty && !canContinue { if state != .error { state = .idle }; queuePaused=false }
        do { try persistState() } catch { queue=oldQ; steering=oldS; state=oldState; queuePaused=oldPaused; throw error }; event("queue.changed")
    }
    /// Reorders the pending follow-ups; every pending turn id must appear exactly once.
    public func reorderQueue(_ turnIDs: [String]) throws {
        guard turnIDs.count == queue.count, Set(turnIDs).count == turnIDs.count, Set(turnIDs) == Set(queue.map(\.turnID)) else { throw AgentError("queue_order", "The new order must list every pending follow-up exactly once") }
        guard queueEdit == nil else { throw Self.editHeldError }
        let byID=Dictionary(uniqueKeysWithValues: queue.map { ($0.turnID,$0) })
        let old=queue; queue=turnIDs.compactMap { byID[$0] }
        do { try persistState() } catch { queue=old; throw error }; event("queue.changed")
    }
    /// The complete text of one pending submission. Display rows carry a
    /// 1 KiB preview; an editor that saved that preview back would silently
    /// discard everything the user typed past it.
    public func queuedText(_ turnID: String) throws -> JSON {
        guard let item=(queue+steering).first(where:{$0.turnID == turnID}) else { throw AgentError("queue_missing", "Queued message is no longer pending") }
        return ["turnId":JSON(item.turnID),"commandId":JSON(item.commandID),"kind":JSON(steering.contains(where:{$0.turnID == turnID}) ? "steering" : "follow-up"),
                "text":JSON(item.text),"textBytes":JSON(item.text.utf8.count)]
    }
    /// Replaces the text of a pending follow-up or steering message before it is delivered.
    public func updateQueued(_ turnID: String, text: String) throws {
        guard queueEdit == nil else { throw Self.editHeldError }
        let steer: Bool, index: Int
        if let found=queue.firstIndex(where:{$0.turnID == turnID}) { steer=false; index=found }
        else if let found=steering.firstIndex(where:{$0.turnID == turnID}) { steer=true; index=found }
        else { throw AgentError("queue_missing", "Queued message is no longer pending") }
        var item=steer ? steering[index] : queue[index]; item.text=text
        guard !text.isEmpty || !item.skills.isEmpty || !item.attachments.isEmpty, text.utf8.count <= 262144 else { throw AgentError("empty_message", "Enter a message or select a skill") }
        let previousQueue=queue, previousSteering=steering
        if steer { steering[index]=item } else { queue[index]=item }
        do { try persistState() } catch { queue=previousQueue; steering=previousSteering; throw error }
        event(steer ? "steering.queued" : "queue.changed")
    }
    /// Moves a pending follow-up into the steering lane so it reaches the
    /// current run after its tool batch instead of waiting for the run to end.
    public func steerQueued(_ turnID: String) throws {
        guard let index=queue.firstIndex(where:{$0.turnID == turnID}) else { throw AgentError("queue_missing", "Queued message is no longer pending") }
        guard acceptsSteering else { throw AgentError("not_running", "Steering requires an active run; the message stays queued") }
        guard queueEdit == nil else { throw Self.editHeldError }
        let item=queue[index], oldQ=queue, oldS=steering
        queue.remove(at:index); steering.append(item)
        do { try persistState() } catch { queue=oldQ; steering=oldS; throw error }; steeringAdmitted()
    }
    /// A message persisted in the steering lane, by sending or by promotion:
    /// shown, and a parent asleep in a family or explicit wait woken to take
    /// it at the boundary it already reached.
    private func steeringAdmitted() {
        event("steering.queued")
        if let coordinator = agentCoordinator { let owner = id; Task { await coordinator.wake(owner) } }
    }
    /// How many pending messages one boundary consumes: one at a time, or all
    /// of them. Steering and follow-ups are configured independently.
    public func configureQueue(_ params: JSON) throws {
        let steering=params["steeringMode"].text ?? steeringMode, followUp=params["followUpMode"].text ?? followUpMode
        guard ["one-at-a-time","all"].contains(steering), ["one-at-a-time","all"].contains(followUp) else { throw AgentError("queue_mode", "Queue modes are one-at-a-time or all") }
        steeringMode=steering; followUpMode=followUp; try persistState(); event("queue.changed")
    }
    public func resumeQueue() throws {
        guard runTask == nil else { throw AgentError("session_busy", "Run already active") }
        guard queueEdit == nil else { throw Self.editHeldError }
        // Only the run's Resume (`run.continue`) ends a cost-limit pause: it
        // also resumes the parked sub-agent turns and names paused sides.
        guard !costPaused, costPendingCalls.isEmpty, !costPendingCompaction else { throw Self.costPausedResumeError }
        queuePaused=false; try persistState()
        if !queue.isEmpty || !steering.isEmpty { launch(); return }
        if errorCode == Self.costLimitCode, !costLimitReached {
            // A run stopped at its cost limit with nothing left to continue
            // (a compaction, say) is over once the limit is above the spend.
            state = .idle; runStatus = .idle; errorMessage=nil; errorCode=nil; try persistState()
        } else if state != .error { state = .idle }
        event("state")
    }
    /// Runs the failed or stopped turn again from where it stopped: the last
    /// user message, or the tool results after it, go to the model once more,
    /// with the chat's current choices (`overrides`: model, thinkingLevel,
    /// contextWindow, maxOutputTokens, modelOutputLimit, input; absent keys
    /// mean the connection's defaults), which the app sends with every retry so the
    /// request follows the pills, not a remembered turn or a restarted helper.
    /// The partial reply of the failed attempt stays in the transcript as what
    /// arrived but is never replayed. Queued follow-ups go on after the turn.
    public func retryRun(overrides: JSON = [:]) throws {
        try requireIndependentSession()
        guard runTask == nil else { throw AgentError("session_busy", "Run already active") }
        guard !costPaused else { throw Self.costPausedResumeError }
        guard state == .error || state == .paused, let last=history.last(where: { $0.replayEligible }), last.role != "assistant" else {
            throw AgentError(AgentErrorCode.nothingToRetry, "There is no failed request to retry; send a new message instead")
        }
        let turnID = currentTurnID.isEmpty ? (history.last(where: { $0.role == "user" })?.id ?? UUID().uuidString) : currentTurnID
        var submission = retrySubmission ?? Submission(commandID: UUID().uuidString, turnID: turnID, text: "")
        submission.model = overrides["model"].text; submission.thinkingLevel = overrides["thinkingLevel"].text
        submission.contextWindow = overrides["contextWindow"].int; submission.maxOutputTokens = overrides["maxOutputTokens"].int
        submission.modelOutputLimit = overrides["modelOutputLimit"].int; submission.input = try NativeHostService.turnInput(overrides["input"])
        _ = try profile.overriding(submission)
        currentTurnID = submission.turnID
        activeSubmission=submission; retrying=true; queuePaused=false; errorMessage=nil; errorCode=nil; try persistState(); launch()
    }
    func deliver(_ submission: Submission, lane: String = "follow-up", newTask: Bool = true) async throws {
        turnSubagentModels = submission.subagentModels ?? subagentModelGrants
        let turn = try profile.overriding(submission)
        // Steering delivered at a Resume's start takes the run over: the
        // continuation's command is done, its receipt says so.
        if let resumed=activeSubmission, resumed.turnID.hasPrefix(Self.continuePrefix), resumed.turnID != submission.turnID { commandState(resumed,"completed") }
        // A new task is a new turn, also when a queued follow-up starts inside
        // a run that is already going: its clock and model/tool split start
        // now, not when the run's first task did.
        if newTask { begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0; beginPresentedTask(submission.turnID); event("state") }
        try await resources.validate(submission.skills,tools:await tools.capabilityIDs(readOnly:readOnly)); appliedSnapshot=try await resources.resolve(); appliedRevision=appliedSnapshot?.revision; try Task.checkCancellation()
        let images=try loadImages(submission.attachments)
        guard images.isEmpty || turn.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
        let expanded=Self.userMessageText(submission.text,skills:submission.skills,turnID:submission.turnID)
        // An image-only message is its images: no text part, empty or invented.
        var message=ChatMessage(role:"user",content:(expanded.isEmpty && !images.isEmpty ? [] : [textBlock(expanded)])+images); message.displayText=submission.text; message.id=submission.turnID; message.turn=submission.turnID
        message.contextNote=pendingContextNote()
        message.userInput = ["version":1,"attachments":.array(submission.attachments.map { $0.removing(["data"]) }),"skills":.array(submission.skills.map(\.recorded))]
        if let lease = agentLease {
            message.userInput = nil
            message.nativeAgentDelivery = ["version":1,"author":"parent","childId":JSON(id),"turn":JSON(lease.turn),"eventIds":[JSON(lease.inputID)],"task":JSON(subagents.origin?.description ?? "")]
        }
        message.taskRootID=newTask ? submission.turnID : taskRootID
        message.taskExecutionID=activeTaskPresentation?.executionID
        message.inputLane=lane
        var overrides: JSON=[:]; if let model=submission.model { overrides["modelOverride"]=JSON(model) }; if let level=submission.thinkingLevel { overrides["thinkingLevel"]=JSON(level) }
        if let capacity=submission.contextWindow { overrides["contextWindow"]=JSON(capacity) }; if let output=submission.maxOutputTokens { overrides["maxOutputTokens"]=JSON(output) }; if let limit=submission.modelOutputLimit { overrides["modelOutputLimit"]=JSON(limit) }
        try append(message,record:overrides)
        if newTask { try startAgentEpoch() }
        // The conversation holds it now; the saved state no longer needs to.
        if delivering?.submission.turnID == submission.turnID { delivering=nil }
        taskRootID=message.taskRootID; boundary=context; currentTurnID=submission.turnID; activeSubmission=submission; retrySubmission=nil; commandState(submission,"delivered"); try persistState(active:true); event("message_end")
    }
    static var editHeldError: AgentError { AgentError("queue_edit_active", "Finish or cancel the queued edit first") }
    /// Delivers the steering due at this boundary; whether any was delivered.
    /// Every claim checks for a queued edit first, after any wait: once an
    /// edit holds the chat's pending input, nothing more of the batch goes.
    func drainSteering() async throws -> Bool {
        if steering.isEmpty || queueEdit != nil { return false }
        var delivered=false
        let count=steeringMode == "all" ? steering.count : 1
        let selected=Set(steering.prefix(count).map(\.turnID))
        // A delivery failure (revoked skill, moved attachment) must not destroy
        // the user's text: the submission stays at the head so it can be
        // inspected, edited or removed after the queue pauses. But if the user
        // journal append committed and only its following checkpoint failed,
        // history already owns the text: requeueing would duplicate that ID.
        for _ in 0..<count {
            // Delivery awaits resource validation. Pending entries may be removed,
            // edited or moved while suspended; new entries belong to the next batch.
            guard queueEdit == nil, let index=steering.firstIndex(where: { selected.contains($0.turnID) }) else { break }
            let next=steering.remove(at:index); delivering=("steering", next)
            // Steering joins the task that is running. With none running (a
            // resume that found only steering pending), the first message
            // starts one, with its live indicator, turn clock and receipt.
            let starts = activeTaskPresentation == nil && !titleTask
            do { try await deliver(next,lane:"steering",newTask:starts); delivered=true; skillRefreshedTurns.remove(next.turnID) }
            catch {
                delivering=nil
                let kept = !hasDelivered(next)
                if kept { steering.insert(next,at:0) }
                commandState(next,"failed")
                throw kept ? await refreshingQueuedSkills(next, after: error) : error
            }
        }
        return delivered
    }
    /// Starts the follow-ups due when the run would stop; whether any started.
    func startFollowUp() async throws -> Bool {
        if queue.isEmpty || queueEdit != nil { return false }
        var delivered=false
        let count=followUpMode == "all" ? queue.count : 1
        let selected=Set(queue.prefix(count).map(\.turnID))
        for _ in 0..<count {
            guard queueEdit == nil, let index=queue.firstIndex(where: { selected.contains($0.turnID) }) else { break }
            let next=queue.remove(at:index); delivering=("follow-up", next)
            do { try await deliver(next,newTask:!delivered); delivered=true; skillRefreshedTurns.remove(next.turnID) }
            catch {
                delivering=nil
                let kept = !hasDelivered(next)
                if kept { queue.insert(next,at:0) }
                commandState(next,"failed")
                throw kept ? await refreshingQueuedSkills(next, after: error) : error
            }
        }
        return delivered
    }
    /// A queued message `deliver` refused because a skill it carries changed
    /// or went away (`skill_revoked`), already back at the head of its lane:
    /// each such skill is pinned to its current file, or taken off if it is
    /// gone or no longer allowed (`Resources.repin`), and the run stops on a
    /// notice naming them (`skill_updated`). Only an explicit selection
    /// activates a skill: the queue stays paused, nothing is sent, and the
    /// reader's Resume confirms the updated version. A second change before it
    /// goes says the skill keeps changing rather than looping. Any other
    /// failure, or one that cannot be refreshed, is returned as it was.
    func refreshingQueuedSkills(_ submission: Submission, after error: Error) async -> Error {
        guard (error as? AgentError)?.code == "skill_revoked", !submission.skills.isEmpty else { return error }
        let tools = await tools.capabilityIDs(readOnly: readOnly)
        guard let refreshed = try? await resources.repin(submission.skills, tools: tools), !refreshed.updated.isEmpty || !refreshed.removed.isEmpty else { return error }
        // The message waited at the head of its lane while the files were
        // read, and a queued rewrite may have been saved meanwhile: it is
        // changed only where it still waits, not under an edit, and from what
        // it holds now, its skills alone (text a rewrite saved is kept).
        // A run cancelled meanwhile (a stop, a shutdown) leaves the message as
        // it was: its notice would not be saved with a cancelled run.
        guard queueEdit?.turnID != submission.turnID, !Task.isCancelled else { return error }
        let inQueue = queue.firstIndex(where: { $0.turnID == submission.turnID }), inSteering = steering.firstIndex(where: { $0.turnID == submission.turnID })
        guard let waiting = inQueue.map({ queue[$0] }) ?? inSteering.map({ steering[$0] }),
              waiting.skills.map({ $0.id + "|" + $0.metadataHash + "|" + $0.contentHash }) == submission.skills.map({ $0.id + "|" + $0.metadataHash + "|" + $0.contentHash }) else { return error }
        let removed = refreshed.removed.map(\.name)
        // What the reader wrote for a skill that is gone (`/name request`)
        // stays in the message, ahead of its text.
        let written = refreshed.removed.map(\.arguments).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var next = waiting; next.skills = refreshed.skills
        if !written.isEmpty {
            next.text = (written + (next.text.isEmpty ? [] : [next.text])).joined(separator: "\n\n")
            guard next.text.utf8.count <= 262144 else { return error }
            next.textRevision = (next.textRevision ?? 0) + 1
        }
        if next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && next.attachments.isEmpty && next.skills.isEmpty {
            return AgentError("skill_revoked", "\(Resources.quoted(removed)) \(removed.count == 1 ? "is" : "are") no longer available, so this queued message has nothing left to send. Remove it from the queue.")
        }
        if let inQueue { queue[inQueue] = next } else if let inSteering { steering[inSteering] = next }
        // A larger skill body must still fit the saved queue, or the message stays as it was.
        if (try? savedState()) == nil {
            if let inQueue { queue[inQueue] = waiting } else if let inSteering { steering[inSteering] = waiting }
            return error
        }
        let again = !skillRefreshedTurns.insert(submission.turnID).inserted
        skillUpdatedTurnID = submission.turnID
        var notice: [String] = []
        if !refreshed.updated.isEmpty {
            let names = Resources.quoted(refreshed.updated), one = refreshed.updated.count == 1
            notice.append(again
                ? "\(names) changed again after this queued message was updated, so \(one ? "it seems" : "they seem") to be changing right now. The message now uses the latest version; press Resume once \(one ? "the skill has" : "the skills have") stopped changing."
                : "\(names) changed after this message was queued. The message now uses the updated version\(one ? "" : "s").")
        }
        if !removed.isEmpty {
            let one = removed.count == 1
            notice.append("\(Resources.quoted(removed)) \(one ? "is" : "are") no longer available, so \(one ? "it was" : "they were") taken off this queued message"
                          + (written.isEmpty ? "." : "; what you wrote for \(one ? "it" : "them") is kept in the message."))
        }
        if !(again && !refreshed.updated.isEmpty) { notice.append("Press Resume to send it.") }
        return AgentError(Self.skillUpdatedCode, notice.joined(separator: " "))
    }
    /// A paused queue whose head message had its skills pinned again to their
    /// current files: the app draws the notice with Resume.
    static let skillUpdatedCode = "skill_updated"
    /// What a `skill_updated` stop says once its message no longer waits:
    /// the run's own failure, which Retry request finishes.
    static let skillUpdateWithdrawn = "The run stopped for a queued message whose skill had changed, and that message is no longer waiting. Retry request finishes the stopped turn."
    /// Whether the message a `skill_updated` stop re-pinned still waits.
    var skillUpdateWaiting: Bool { (queue + steering).contains { $0.turnID == skillUpdatedTurnID } }
    func hasDelivered(_ submission: Submission) -> Bool {
        history.contains { $0.role == "user" && $0.id == submission.turnID }
    }
}
