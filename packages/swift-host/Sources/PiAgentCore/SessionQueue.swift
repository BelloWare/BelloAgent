import Foundation

// Pending work: the follow-up queue, the steering lane, and delivering
// a submission into the conversation.

extension AgentSession {
    func commandState(_ submission: Submission, _ status: String) {
        let record: JSON=["commandId":JSON(submission.commandID),"turnId":JSON(submission.turnID),"status":JSON(status),"state":JSON(status)]
        if let i=commands.firstIndex(where:{$0["turnId"].text == submission.turnID}) { commands[i]=record } else { commands.append(record) }
        if commands.count > 128 { commands.removeFirst(commands.count-128) }
    }
    func validate(_ input: Submission, steer: Bool) throws {
        guard !closed else { throw AgentError("session_closed","Session runtime is unloaded") }
        guard !input.text.isEmpty || !input.skills.isEmpty || !input.attachments.isEmpty else { throw AgentError("empty_message", "Enter a message or select a skill") }
        guard input.text.utf8.count <= 262144, queue.count + steering.count < 64 else { throw AgentError("queue_limit", "Message or queue limit exceeded") }
        guard !commands.contains(where:{$0["turnId"].text == input.turnID}), !history.contains(where:{$0.id == input.turnID}) else { throw AgentError("duplicate_turn", "Turn identity already accepted; no duplicate submission was made") }
        _ = try profile.overriding(model:input.model,thinkingLevel:input.thinkingLevel,contextWindow:input.contextWindow,maxOutputTokens:input.maxOutputTokens,modelOutputLimit:input.modelOutputLimit)
        if steer, runTask == nil { throw AgentError("not_running", "Steering requires an active run; send a normal message") }
        // A message sent to a chat at its cost limit is refused where it was
        // typed, with the same words as a run stopped there. One sent while a
        // run is going waits in the queue, which pauses if the run stops.
        if !steer, runTask == nil { try enforceCostLimit() }
        if !steer, runTask == nil, queuePaused, !queue.isEmpty || !steering.isEmpty { throw AgentError("queue_paused", "Resume or remove paused messages before sending another") }
    }
    public func submit(_ input: Submission, steer: Bool) throws -> JSON {
        try validate(input,steer:steer)
        if steer { steering.append(input) } else { queue.append(input) }; commandState(input,"queued")
        do { try persistState() } catch { if steer { steering.removeLast() } else { queue.removeLast() }; commands.removeAll{$0["turnId"].text == input.turnID}; throw error }
        event(steer ? "steering.queued" : "queue.changed")
        let queued=runTask != nil
        if runTask == nil { queuePaused=false; launch() }
        return ["accepted":true,"turnId":JSON(input.turnID),"queued":JSON(queued),"queueCount":JSON(queue.count),"delivery":JSON(steer ? "after-current-model-tool-turn" : queued ? "after-run-would-stop" : "start")]
    }
    public func removeQueued(_ turnID: String) throws {
        guard let item=(queue+steering).first(where:{$0.turnID == turnID}) else { throw AgentError("queue_missing", "Queued message is no longer pending") }
        let oldQ=queue, oldS=steering, oldState=state, oldPaused=queuePaused; queue.removeAll{$0.turnID == turnID}; steering.removeAll{$0.turnID == turnID}; commandState(item,"removed")
        if runTask == nil && queue.isEmpty && steering.isEmpty { if state != "error" { state="idle" }; queuePaused=false }
        do { try persistState() } catch { queue=oldQ; steering=oldS; state=oldState; queuePaused=oldPaused; throw error }; event("queue.changed")
    }
    /// Reorders the pending follow-ups; every pending turn id must appear exactly once.
    public func reorderQueue(_ turnIDs: [String]) throws {
        guard turnIDs.count == queue.count, Set(turnIDs).count == turnIDs.count, Set(turnIDs) == Set(queue.map(\.turnID)) else { throw AgentError("queue_order", "The new order must list every pending follow-up exactly once") }
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
        guard runTask != nil else { throw AgentError("not_running", "Steering requires an active run; the message stays queued") }
        let item=queue[index], oldQ=queue, oldS=steering
        queue.remove(at:index); steering.append(item)
        do { try persistState() } catch { queue=oldQ; steering=oldS; throw error }; event("steering.queued")
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
        queuePaused=false; try persistState()
        if !queue.isEmpty || !steering.isEmpty { launch(); return }
        if errorCode == Self.costLimitCode, !costLimitReached {
            // A run stopped at its cost limit with nothing left to continue
            // (a compaction, say) is over once the limit is above the spend.
            state="idle"; runStatus="idle"; errorMessage=nil; errorCode=nil; try persistState()
        } else if state != "error" { state="idle" }
        event("state")
    }
    /// Runs the failed or stopped turn again from where it stopped: the last
    /// user message, or the tool results after it, go to the model once more,
    /// with the chat's current choices (`overrides`: model, thinkingLevel,
    /// contextWindow, maxOutputTokens, modelOutputLimit; absent keys mean the
    /// connection's defaults), which the app sends with every retry so the
    /// request follows the pills, not a remembered turn or a restarted helper.
    /// The partial reply of the failed attempt stays in the transcript as what
    /// arrived but is never replayed. Queued follow-ups go on after the turn.
    public func retryRun(overrides: JSON = [:]) throws {
        guard runTask == nil else { throw AgentError("session_busy", "Run already active") }
        guard state == "error" || state == "paused", let last=history.last(where: { $0.replayEligible }), last.role != "assistant" else {
            throw AgentError("nothing_to_retry", "There is no failed request to retry; send a new message instead")
        }
        let turnID = currentTurnID.isEmpty ? (history.last(where: { $0.role == "user" })?.id ?? UUID().uuidString) : currentTurnID
        var submission = retrySubmission ?? Submission(commandID: UUID().uuidString, turnID: turnID, text: "")
        submission.model = overrides["model"].text; submission.thinkingLevel = overrides["thinkingLevel"].text
        submission.contextWindow = overrides["contextWindow"].int; submission.maxOutputTokens = overrides["maxOutputTokens"].int
        submission.modelOutputLimit = overrides["modelOutputLimit"].int
        _ = try profile.overriding(model:submission.model,thinkingLevel:submission.thinkingLevel,contextWindow:submission.contextWindow,maxOutputTokens:submission.maxOutputTokens,modelOutputLimit:submission.modelOutputLimit)
        currentTurnID = submission.turnID
        activeSubmission=submission; retrying=true; queuePaused=false; errorMessage=nil; errorCode=nil; try persistState(); launch()
    }
    func deliver(_ submission: Submission, lane: String = "follow-up", newTask: Bool = true) async throws {
        _ = try profile.overriding(model:submission.model,thinkingLevel:submission.thinkingLevel,contextWindow:submission.contextWindow,maxOutputTokens:submission.maxOutputTokens,modelOutputLimit:submission.modelOutputLimit)
        // A new task is a new turn, also when a queued follow-up starts inside
        // a run that is already going: its clock and model/tool split start
        // now, not when the run's first task did.
        if newTask { begin=nowMS(); end=nil; turnModelMs=0; turnToolMs=0; beginPresentedTask(submission.turnID); event("state") }
        try await resources.validate(submission.skills,tools:await tools.capabilityIDs(readOnly:readOnly)); appliedSnapshot=try await resources.resolve(); appliedRevision=appliedSnapshot?.revision; try Task.checkCancellation()
        let images=try loadImages(submission.attachments)
        guard images.isEmpty || profile.raw["input"].list.contains("image") else { throw AgentError("unsupported_image", "Selected model does not declare image support") }
        let expanded=(submission.skills.map{$0.expand(turnID:submission.turnID)} + [submission.text]).joined(separator:"\n\n")
        var message=ChatMessage(role:"user",content:[textBlock(expanded)]+images); message.displayText=submission.text; message.id=submission.turnID; message.turn=submission.turnID
        message.userInput = ["version":1,"attachments":.array(submission.attachments.map { $0.removing(["data"]) }),"skills":.array(submission.skills.map(\.recorded))]
        message.taskRootID=newTask ? submission.turnID : taskRootID
        message.taskExecutionID=activeTaskPresentation?.executionID
        message.inputLane=lane
        var overrides: JSON=[:]; if let model=submission.model { overrides["modelOverride"]=JSON(model) }; if let level=submission.thinkingLevel { overrides["thinkingLevel"]=JSON(level) }
        if let capacity=submission.contextWindow { overrides["contextWindow"]=JSON(capacity) }; if let output=submission.maxOutputTokens { overrides["maxOutputTokens"]=JSON(output) }; if let limit=submission.modelOutputLimit { overrides["modelOutputLimit"]=JSON(limit) }
        try append(message,record:overrides); taskRootID=message.taskRootID; boundary=context; currentTurnID=submission.turnID; activeSubmission=submission; retrySubmission=nil; commandState(submission,"delivered"); try persistState(active:true); event("message_end")
    }
    func drainSteering() async throws -> Bool {
        if steering.isEmpty { return false }
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
            guard let index=steering.firstIndex(where: { selected.contains($0.turnID) }) else { break }
            let next=steering.remove(at:index)
            // Steering joins the task that is running. With none running (a
            // resume that found only steering pending), the first message
            // starts one, with its live indicator, turn clock and receipt.
            let starts = activeTaskPresentation == nil && !titleTask
            do { try await deliver(next,lane:"steering",newTask:starts) }
            catch {
                if !hasDelivered(next) { steering.insert(next,at:0) }
                commandState(next,"failed"); throw error
            }
        }
        return true
    }
    func startFollowUp() async throws -> Bool {
        if queue.isEmpty { return false }
        let count=followUpMode == "all" ? queue.count : 1
        let selected=Set(queue.prefix(count).map(\.turnID))
        for position in 0..<count {
            guard let index=queue.firstIndex(where: { selected.contains($0.turnID) }) else { break }
            let next=queue.remove(at:index)
            do { try await deliver(next,newTask:position == 0) }
            catch {
                if !hasDelivered(next) { queue.insert(next,at:0) }
                commandState(next,"failed"); throw error
            }
        }
        return true
    }
    func hasDelivered(_ submission: Submission) -> Bool {
        history.contains { $0.role == "user" && $0.id == submission.turnID }
    }
}
