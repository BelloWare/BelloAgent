import Foundation

// The streamed row while a reply arrives: bounded text, thinking and
// tool cards, accumulated at a cost that does not grow with the reply.

extension AgentSession {
    /// How wide the streamed row's two documents are on the wire. A token past
    /// the cap changes nothing the reader can see, which is what makes the
    /// per-token change test constant time.
    static let streamedTextBytes = 16384, streamedThinkingBytes = 8192
    /// Clears everything the streaming row is built from: its tool cards, the
    /// count of calls it has seen, and the two cached bounded documents.
    func resetPartialRow() {
        partialTools=[:]; partialToolOrder=[]; partialToolSeen=[]
        partialCardsVersion &+= 1; partialTextPreview=nil; partialThinkingPreview=nil
    }
    func delta(_ value: StreamDelta) {
        let observedAt = displayClock()
        var changed = false
        switch value {
        case .text(let text):
            // The row shows a bounded prefix of a string that only grows, so a
            // token can only change what the reader sees while the reply is
            // still under the cap, or at the moment it crosses it. Building and
            // comparing two 16 KiB previews per token was the helper's largest
            // streaming cost and it grew with the reply.
            let before = partialText.utf8.count
            partialText += text
            let after = partialText.utf8.count
            if before < Self.streamedTextBytes { partialTextPreview = nil }
            changed = (after != before && before < Self.streamedTextBytes) || (before > Self.streamedTextBytes) != (after > Self.streamedTextBytes)
        case .thinking(let text):
            let before = partialThinking.utf8.count
            partialThinking += text
            let after = partialThinking.utf8.count
            if before < Self.streamedThinkingBytes { partialThinkingPreview = nil }
            changed = after != before && before < Self.streamedThinkingBytes
        case .tool(let id,let name,let arguments):
            let previous = partialTools[id]
            // Only the cards the row displays are retained. A reply announcing
            // hundreds of calls would otherwise grow the projected row past the
            // transport frame limit, which terminates the helper.
            if previous == nil {
                let first = partialToolSeen.insert(id).inserted
                guard partialToolOrder.count < ToolInputDisplay.projectedCards else {
                    // Nothing beyond the projected cards is retained. The row
                    // only has to learn, once, that it shows a subset.
                    if first, partialToolSeen.count == ToolInputDisplay.projectedCards+1 { recordDisplayChange(partialID, at: observedAt) }
                    event("message_update"); return
                }
                partialToolOrder.append(id); partialCardsVersion &+= 1
            }
            var tool=previous ?? ["id":JSON(id),"name":JSON(name),"state":"preparing","input":"","output":"","durationMs":.null,"truncated":false,"inputTruncated":false,"inputBytes":0]
            if !name.isEmpty { tool["name"]=JSON(name) }
            // The accumulator itself stays bounded, so a multi-megabyte
            // argument stream costs constant memory. Streamed arguments are a
            // partial document at every step; the app parses the card only
            // once the completed call replaces it.
            let joined=(tool["input"].text ?? "")+arguments, bounded=encodedPreview(joined,bytes:ToolInputDisplay.inlineBytes)
            let streamed=(tool["inputBytes"].int ?? 0)+arguments.utf8.count
            tool["input"]=JSON(bounded); tool["inputBytes"]=JSON(streamed)
            tool["inputTruncated"]=JSON((tool["inputTruncated"].flag ?? false) || bounded.utf8.count < joined.utf8.count)
            partialTools[id]=tool
            changed = previous != tool
            if changed { partialCardsVersion &+= 1 }
        }
        if changed { recordDisplayChange(partialID, at: observedAt) }
        event("message_update")
    }
}
