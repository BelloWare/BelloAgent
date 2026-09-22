import Foundation

// The full streamed reply. Snapshots are coalesced and subsequent reads carry
// appended text rather than re-sending the entire document on every fragment.

extension AgentSession {
    /// Clears everything the streaming row is built from: its tool cards, the
    /// count of calls it has seen.
    func resetPartialRow() {
        saveResponseLedger(persist:true,terminal:"interrupted")
        partialTimeline = ResponseTimeline(); partialLedgerID = nil
        partialTools=[:]; partialToolOrder=[]; partialToolSeen=[]
        partialCardsVersion &+= 1
    }
    func delta(_ value: StreamDelta) {
        let observedAt = displayClock()
        var changed = false
        switch value {
        case .part(var part):
            presentationOrdinal += 1; part.sessionOrdinal=presentationOrdinal
            let previous = partialTimeline.segments.last?.id
            changed = partialTimeline.consume(part)
            if changed, previous != partialTimeline.segments.last?.id || part.update == "end" || part.update == "replace" {
                saveResponseLedger(persist:true)
            }
        case .text(let text):
            partialText += text
            changed = !text.isEmpty
        case .thinking(let text):
            partialThinking += text
            changed = !text.isEmpty
        case .tool(let id,let name,let arguments):
            let previous = partialTools[id]
            if previous == nil {
                partialToolSeen.insert(id)
                partialToolOrder.append(id); partialCardsVersion &+= 1
            }
            var tool=previous ?? ["id":JSON(id),"name":JSON(name),"state":"preparing","input":"","output":"","durationMs":.null,"truncated":false,"inputTruncated":false,"inputBytes":0]
            if !name.isEmpty { tool["name"]=JSON(name) }
            let joined=(tool["input"].text ?? "")+arguments
            tool["input"]=JSON(joined); tool["inputBytes"]=JSON(joined.utf8.count)
            tool["inputTruncated"]=false
            partialTools[id]=tool
            changed = previous != tool
            if changed { partialCardsVersion &+= 1 }
        }
        if changed { recordDisplayChange(partialID, at: observedAt) }
        event("message_update")
    }
}
