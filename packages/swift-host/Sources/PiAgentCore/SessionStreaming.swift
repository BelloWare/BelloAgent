import Foundation

// The full streamed reply. Snapshots are coalesced and subsequent reads carry
// appended text rather than re-sending the entire document on every fragment.

extension AgentSession {
    /// An unexplained incomplete is not an assistant response, even as a
    /// display-only partial. The app projects orphan request ledgers as
    /// replies, so persist a content-free ledger as well as dropping the log.
    func discardIncompleteReply() throws {
        partialText=""; partialThinking=""; partialTimeline=ResponseTimeline()
        // A refused journal update must not leave this attempt recoverable.
        dropStreamed()
        try partialReplyLog?.discard()
        partialReplyLog=nil
        if let id=partialLedgerID, var row=history.first(where: { $0.id == id }) {
            row.responseTimeline=ResponseTimeline(); row.responseTimeline?.finish("failed")
            row.detail="Request failed"
            // The durable ledger is still content-free. Clear the live copy
            // too even if recording its failure receipt is refused.
            try updatePresentation(row,persist:false)
            try updatePresentation(row,persist:true)
        }
        partialLedgerID=nil; resetPartialRow()
    }
    /// Clears everything the streaming row is built from: its tool cards, the
    /// count of calls it has seen.
    func resetPartialRow() {
        saveResponseLedger(persist:true,terminal:"interrupted"); dropStreamed()
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
            logStreamed(.part(part))
            let previous = partialTimeline.segments.last?.id
            changed = partialTimeline.consume(part)
            // Until the terminal is accepted, only the removable .stream log
            // keeps this content on disk. An append-only ledger must not
            // expose a rejected reply if a later cleanup write fails. Normal
            // completed/interrupted replies persist their timeline at settlement.
            if changed, previous != partialTimeline.segments.last?.id || part.update == "end" || part.update == "replace" { saveResponseLedger(persist:false) }
        case .text(let text):
            partialText += text
            changed = !text.isEmpty
            if changed { logStreamed(.text(text)) }
        case .thinking(let text):
            partialThinking += text
            changed = !text.isEmpty
            if changed { logStreamed(.thinking(text)) }
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
