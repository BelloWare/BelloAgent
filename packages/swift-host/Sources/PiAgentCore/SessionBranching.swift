import Foundation

// Editing an earlier user message: the journal keeps every record, while
// the live context and the displayed timeline drop the abandoned tail.

let branchMarkerText = "Edited from here · earlier replies stay in the journal"

extension AgentSession {
    /// Branch the conversation at one of its user messages and resubmit new text.
    /// The journal keeps every record; only the live context and the displayed
    /// timeline drop the abandoned tail. Nothing is written unless the new
    /// submission is itself acceptable.
    public func edit(fromMessageID messageID: String, input: Submission) throws -> JSON {
        guard isIdle else { throw AgentError("session_busy", "Edit requires an idle session with empty queues") }
        guard !ephemeral else { throw AgentError("side_ephemeral", "Keep this side chat before editing its messages; a branch must be durable") }
        try validate(input,steer:false)
        guard let position=context.firstIndex(where:{$0.id == messageID}), context[position].role == "user" else { throw AgentError("edit_target", "Edit requires a user message in the current context") }
        guard let journal else { throw AgentError("session_closed", "Session runtime is unloaded") }
        // A summary written before the replayed protected input can itself
        // depend on that input. Editing it must also abandon that summary.
        let byID=Dictionary(history.map { ($0.id,$0) },uniquingKeysWith:{_,b in b})
        func dependsOnEditedInput(_ message: ChatMessage) -> Bool {
            func dependencies(_ message: ChatMessage) -> [String] {
                guard let metadata=message.compaction else { return [] }
                return (metadata["dependencyIDs"].isNull ? metadata["sourceIDs"] : metadata["dependencyIDs"]).list.compactMap(\.text)
            }
            var pending=dependencies(message), seen=Set<String>()
            while let id=pending.popLast() {
                if id==messageID { return true }
                if seen.insert(id).inserted, let source=byID[id] { pending += dependencies(source) }
            }
            return false
        }
        let keptIDs=context[..<position].filter { !dependsOnEditedInput($0) }.map(\.id)
        let oldCommands=commands
        queue.append(input); commandState(input,"queued")
        let markerID: String
        do {
            // Publish the branch and accepted replacement atomically. No
            // separate queue append may fail after hiding the previous tail.
            let record: JSON=["type":"branch","fromMessageId":JSON(messageID),"keptIds":.array(keptIDs.map { JSON($0) }),"nativeState":try savedState(active:false)]
            markerID=try journal.append(record)
        } catch { queue.removeLast(); commands=oldCommands; throw error }
        applyBranch(from:messageID,keptIDs:Set(keptIDs),markerID:markerID)
        recordDisplayChange(markerID, at: displayClock())
        event("context.branched",["fromMessageId":JSON(messageID),"kept":JSON(keptIDs.count)])
        event("queue.changed"); queuePaused=false; launch()
        return ["accepted":true,"turnId":JSON(input.turnID),"queued":false,"queueCount":JSON(queue.count),"delivery":"start"]
    }
    func applyBranch(from messageID: String, keptIDs: Set<String>, markerID: String) {
        Self.branch(history:&history,context:&context,visible:&visible,from:messageID,keptIDs:keptIDs,markerID:markerID)
        invalidateDisplay(allRows: true)
        replayInputsChanged(); contextRecovery = .null
        boundary=context; contextBaseline=nil; currentContextCount=nil; clearRequestObservation()
    }
    /// Shared by live edits and journal replay (the synchronous initializer
    /// cannot call isolated methods). The marker is display-only: it joins
    /// history and the visible timeline, never the model context.
    static func branch(history: inout [ChatMessage], context: inout [ChatMessage], visible: inout [ChatMessage], from messageID: String, keptIDs: Set<String>, markerID: String) {
        context=context.filter { keptIDs.contains($0.id) }
        if let index=visible.firstIndex(where:{$0.id == messageID}) { visible=Array(visible[..<index]) } else { visible=visible.filter { keptIDs.contains($0.id) } }
        // A summary is written after the user turns it keeps. Editing one of
        // those turns must not hide the summary that remains in model context.
        let visibleIDs=Set(visible.map(\.id))
        visible += context.filter { !visibleIDs.contains($0.id) }
        var marker=ChatMessage(role:"system",content:[]); marker.id=markerID; marker.kind="branch"; marker.replayEligible=false; marker.displayText=branchMarkerText
        history.append(marker); visible.append(marker)
    }
}
