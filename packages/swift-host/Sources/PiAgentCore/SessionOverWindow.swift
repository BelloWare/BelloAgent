import Foundation

// A request over the model's window that no compaction relieved, 0.1.138.
// What must stay (the task's request, steering, the newest batch of results)
// is never dropped, and a declared window can be conservative, so the request
// goes out whole with its ordinary output limit (`PiContext.outputCap`) and
// the gateway decides. The chat says so once per task: until now it said
// nothing unless the provider refused the request.

extension AgentSession {
    /// The lead of the notice's row, as a compaction's row leads with "Compaction · ".
    static let overWindowLead = "Context · "
    /// Digits in threes: the figures are read by the owner, in any locale.
    static func grouped(_ value: Int) -> String {
        var digits = String(abs(value)), out = ""
        while digits.count > 3 { out = "," + digits.suffix(3) + out; digits.removeLast(3) }
        return (value < 0 ? "-" : "") + digits + out
    }
    static func overWindowText(tokens: Int, usable: Int, window: Int) -> String {
        "This request is about \(grouped(tokens)) tokens, more than the \(grouped(usable)) that this model's \(grouped(window))-token window leaves for input. "
            + "Nothing was summarized away, and it is sent whole: the provider may refuse it, or cut the reply short."
    }
    /// Called with the count of the request about to be sent. A request that
    /// does not fit beside the reply's reserve, in a chat that compacts by
    /// itself, gets one row for its task: a presentation row, so it is shown
    /// and journaled and never sent to the model. The task's rows are what
    /// remember it, so a Stop and Resume, a Retry or a reopen do not say it
    /// again. Not said where the owner turned automatic compaction off (the
    /// meter shows the fill), for a bounded task with its own cap, or once a
    /// summary that was paid for failed: that row has said why.
    func noteOverWindow(_ count: RequestContextCount) throws {
        guard autoCompaction, !titleTask, turnProfile.outputCap == nil, !count.fits, !automaticCompactionSuppressed else { return }
        let root = taskRootID
        guard !history.reversed().contains(where: { $0.kind == "execution" && $0.taskRootID == root && ($0.detail ?? "").hasPrefix(Self.overWindowLead) }) else { return }
        let text = Self.overWindowText(tokens: count.requestTokens, usable: count.inputBudget, window: count.contextWindow)
        var row = ChatMessage(role: "system", content: [])
        row.kind = "execution"; row.detail = Self.overWindowLead + text
        var timeline = ResponseTimeline(); presentationOrdinal += 1
        timeline.consume(ResponsePartEvent(attemptID: row.id, ordinal: presentationOrdinal, itemID: row.id, kind: "status", update: "begin", text: text, observedAt: nowMS(), evidence: "local"))
        timeline.finish("recorded"); row.responseTimeline = timeline
        try appendPresentation(row)
    }
}
