import Foundation

extension AgentSession {
    func prunePresentedTasksAfterBranch() {
        let retained = Set(visible.map(\.id))
        recentTaskPresentations.removeAll { $0.lastSourceID.map { !retained.contains($0) } ?? true }
    }
    var presentationTimeline: String {
        if let cachedPresentationTimeline { return cachedPresentationTimeline }
        let value = visible.last(where: { $0.kind == "branch" })?.id ?? "root"
        cachedPresentationTimeline = value
        return value
    }
    func beginPresentedTask(_ root: String) {
        guard !titleTask else { return }
        activeTaskPresentation = TaskPresentationRecord(rootID: root, startedAt: nowMS(), startedAtUnixMs: Date().timeIntervalSince1970 * 1000)
        activeTaskPresentation?.activeInputID = root
    }
    func observePresentedMessage(_ message: ChatMessage) {
        guard var task = activeTaskPresentation, message.taskRootID == task.rootID,
              message.taskExecutionID == task.executionID else { return }
        task.lastSourceID = message.id
        if message.role == "user" { task.activeInputID = message.id }
        if message.role == "assistant" {
            task.assistantID = message.id
            task.replies += 1
            task.issuedCalls += message.content.filter { $0["type"].text == "toolCall" }.count
            task.modelMs += message.modelMs ?? 0
        }
        if message.role == "toolResult" { task.toolMs += message.toolStats?["durationMs"].double ?? 0 }
        activeTaskPresentation = task
    }
    /// Called only at the actual continuation decision, never message_end or
    /// turn_end. Persist before advancing to a queued follow-up.
    func finishPresentedTask(_ outcome: String, detail: String? = nil) throws {
        guard var task = activeTaskPresentation else { return }
        task.phase = "terminal"; task.outcome = outcome; task.endedAt = nowMS()
        task.endedAtUnixMs = Date().timeIntervalSince1970 * 1000
        task.lastSourceID = task.lastSourceID ?? task.anchorSourceID
        task.detail = detail.map { preview($0, bytes: 2048) }; task.preparingCalls = 0; task.currentTool = nil
        let value = try JSON.parse(JSONEncoder().encode(task))
        try journal?.append(["type":"custom", "customType":"pi-app.task-terminal.v1", "data":value], flush:true)
        recentTaskPresentations.append(task)
        if recentTaskPresentations.count > 64 { recentTaskPresentations.removeFirst(recentTaskPresentations.count - 64) }
        activeTaskPresentation = nil
        invalidateDisplay(task.lastSourceID)
    }
    func taskPresentationSnapshot() -> TaskPresentationProjection {
        var active = activeTaskPresentation
        if active != nil {
            active?.phase = state == "stopping" ? "stopping" : runStatus == "retrying" ? "retrying" :
                runStatus == "compacting" ? "compacting" : runStatus == "waitingTool" ? "tools" : modelActive ? "model" : "preparing"
            if let partialID { active?.assistantID = partialID }
            active?.attemptID = requestObservation?.attemptID
            active?.preparingCalls = partialToolSeen.count
            active?.currentTool = toolStates.values.first { $0["state"].text == "running" }?["name"].text
        }
        return TaskPresentationProjection(sessionID:id, epoch:displayEpoch, timeline:presentationTimeline,
            sequence:sequence, sourceRevision:displayRevision, active:active, recent:recentTaskPresentations,
            utilityPhase:presentationUtility && active == nil && (state == "running" || state == "stopping") ? (runStatus == "compacting" ? "compacting" : "preparing") : nil)
    }
}
