import Foundation

// The full streamed reply. Snapshots are coalesced and subsequent reads carry
// appended text rather than re-sending the entire document on every fragment.

extension AgentSession {
    /// Clears everything the streaming row is built from: its tool cards, the
    /// count of calls it has seen.
    func resetPartialRow() {
        saveResponseLedger(persist:true,terminal:"interrupted")
        partialTimeline = ResponseTimeline(); partialLedgerID = nil
        partialTools=[:]; partialToolOrder=[]; partialToolSeen=[]; partialToolInputs=[:]; partialToolInputSizes=[:]
        partialTextSize=(0,0); partialThinkingSize=(0,0); streamedSegments=[:]
        partialCardsVersion &+= 1; partialGeneration &+= 1
    }
    func delta(_ value: StreamDelta) {
        let observedAt = displayClock()
        var changed = false
        switch value {
        case .part(var part):
            presentationOrdinal += 1; part.sessionOrdinal=presentationOrdinal
            let previous = partialTimeline.segments.last?.id
            changed = partialTimeline.consume(part)
            // The ledger is journaled when a part begins and, with its
            // terminal receipt, when the reply ends; every record holds the
            // whole timeline so far. An end or a repeated `.done` of a part
            // it holds only refreshes the row in memory.
            if changed, previous != partialTimeline.segments.last?.id { saveResponseLedger(persist:true) }
            else if changed, part.update == "end" || part.update == "replace" { saveResponseLedger(persist:false) }
        case .text(let text):
            partialText += text
            changed = !text.isEmpty
        case .thinking(let text):
            partialThinking += text
            changed = !text.isEmpty
        case .tool(let id,let name,let arguments):
            // The card changes only when a call appears or is named; its
            // arguments grow in place beside it, so a delta costs its own
            // size, and a reader that takes appends is sent just those bytes.
            var card = partialTools[id], cardChanged = false
            if card == nil {
                partialToolSeen.insert(id); partialToolOrder.append(id)
                card = ["id":JSON(id),"name":JSON(name),"state":"preparing","output":"","durationMs":.null,"truncated":false,"inputTruncated":false]
                cardChanged = true
            } else if !name.isEmpty, card?["name"].text != name { card?["name"] = JSON(name); cardChanged = true }
            if cardChanged { partialTools[id]=card; partialCardsVersion &+= 1 }
            if !arguments.isEmpty { partialToolInputs[id, default: ""] += arguments }
            changed = cardChanged || !arguments.isEmpty
        }
        if changed { recordDisplayChange(partialID, at: observedAt) }
        event("message_update")
    }
}
