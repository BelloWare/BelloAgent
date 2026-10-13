import Foundation

// Resume: the run a Stop, a quit, a restart or an update cut off goes on
// from the chat's history as it stands, with no new user message. This is
// pi 0.85.1's continue (agent.ts `continue`, agent-loop `agentLoopContinue`):
// the model is asked again from the context; a context that ends with an
// assistant reply has nothing to continue, and only then do pending steering
// and follow-ups go instead, as a prompt would send them.
//
// The no-replay rule stays: nothing here runs a tool. A call that was cut
// off already has its result in the context (cancelled before it ran, or
// interrupted with its effects unknown), and the model reads that and
// decides. A reply cut off mid-stream is kept as its interrupted row, which
// is never sent again (`replayEligible` is false); the continuation is a new
// assistant turn after it.

extension AgentSession {
    /// The receipt key a continuation's command is kept under. It never names
    /// a user turn, so a continuation's receipt cannot replace a message's.
    static let continuePrefix = "continue:"

    /// The last message a request would carry: what a continuation answers.
    var continuationTail: ChatMessage? {
        context.last { $0.replayEligible && !requestExclusions.contains($0.id) }
    }
    /// Whether `run.continue` would run the model now: nothing is running,
    /// no queued edit holds the chat, and the context ends with something the
    /// model has not answered — a user message, or tool results (cut-off
    /// ones included). The snapshot says so, and the app offers Resume.
    var canContinue: Bool {
        guard runTask == nil, !closed, queueEdit == nil, !titleTask, !isConnectionTest, let tail = continuationTail else { return false }
        return Self.continues(from: tail)
    }
    /// A context ending in a user message, tool results, or a compaction
    /// summary (a compaction that summarized the whole tail, before the
    /// request it made room for) has a run to go on with.
    static func continues(from tail: ChatMessage) -> Bool {
        tail.role == "user" || tail.role == "toolResult" || (tail.role == "system" && tail.kind == "compaction")
    }
    /// The turn a continuation belongs to: the newest user message's, or —
    /// when a compaction summarized it and kept its replies — the turn those
    /// replies carry; else the newest shown user message's.
    var continuedTurn: String? {
        let newest = context.last { $0.role == "user" || ($0.role != "system" && $0.turn?.isEmpty == false) }
        return newest.flatMap { $0.role == "user" ? $0.id : $0.turn } ?? visible.last { $0.role == "user" }?.id
    }

    /// `run.continue`. `overrides` are the chat's current choices (model,
    /// thinkingLevel, contextWindow, maxOutputTokens, modelOutputLimit, input),
    /// as for a send or a retry; absent keys mean the connection's defaults.
    ///
    /// Idempotent by `commandID`: the receipt is saved with the run state
    /// before the run starts, so the same command sent again — a reply lost
    /// to a helper that then restarted — finds it and runs nothing. A second
    /// Resume with a new identity while this one runs is refused as busy.
    public func continueRun(commandID: String, overrides: JSON = [:]) throws -> JSON {
        guard !closed else { throw AgentError("session_closed", "Session runtime is unloaded") }
        let receiptKey = Self.continuePrefix + commandID
        if let receipt = commands.last(where: { $0["commandId"].text == commandID }) {
            guard receipt["turnId"].text == receiptKey else { throw AgentError("command_conflict", "Command identity already used for another command") }
            return ["accepted": true, "duplicate": true, "continued": true, "state": receipt["state"]]
        }
        guard runTask == nil else { throw AgentError("session_busy", "Run already active") }
        guard queueEdit == nil else { throw Self.editHeldError }
        guard !titleTask, !isConnectionTest, let tail = continuationTail, Self.continues(from: tail) else {
            // Pi: from an answered context (or none: a first message stopped
            // before it was delivered), continue sends what waits instead.
            // So does a chat the model is never asked to go on in by itself
            // (a connection test, a title).
            guard !queue.isEmpty || !steering.isEmpty else {
                throw AgentError(AgentErrorCode.nothingToContinue, "There is nothing to resume; send a new message instead")
            }
            // Its receipt goes with the queue's release, in the same record:
            // the same command sent again releases nothing twice.
            commandState(Submission(commandID: commandID, turnID: receiptKey, text: ""), "completed")
            do { try resumeQueue() } catch { commands.removeAll { $0["turnId"].text == receiptKey }; throw error }
            return ["accepted": true, "continued": false, "resumedQueue": true]
        }
        var submission = Submission(commandID: commandID, turnID: receiptKey, text: "")
        submission.model = overrides["model"].text; submission.thinkingLevel = overrides["thinkingLevel"].text
        submission.contextWindow = overrides["contextWindow"].int; submission.maxOutputTokens = overrides["maxOutputTokens"].int
        submission.modelOutputLimit = overrides["modelOutputLimit"].int; submission.input = try NativeHostService.turnInput(overrides["input"])
        _ = try profile.overriding(submission)
        // The continuation's rows belong to the turn they continue.
        let previous = (turn: currentTurnID, paused: queuePaused, message: errorMessage, code: errorCode)
        if let turn = continuedTurn { currentTurnID = turn }
        activeSubmission = submission; continuing = true; queuePaused = false; errorMessage = nil; errorCode = nil
        commandState(submission, "queued")
        // Saved as a run under way, with its receipt: a helper that dies
        // before the run's own first record leaves the chat interrupted, so
        // it offers Resume again after the restart, never idle.
        do { try persistState(active: true) } catch {
            commands.removeAll { $0["turnId"].text == receiptKey }
            activeSubmission = nil; continuing = false
            currentTurnID = previous.turn; queuePaused = previous.paused; errorMessage = previous.message; errorCode = previous.code
            throw error
        }
        launch()
        return ["accepted": true, "continued": true]
    }
}
