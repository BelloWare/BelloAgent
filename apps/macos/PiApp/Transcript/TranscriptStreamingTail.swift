import Foundation

/// Whether two readings of the same row differ only by text appended to the
/// end of the reply that is still arriving. That is the one change a token
/// makes, and the only one the page can answer by extending the message's own
/// native surface instead of rebuilding the row.
///
/// The test is deliberately strict: the new row is copied, the arriving text
/// is put back to what it was, and the two must then be equal. So a tool that
/// started, a turn line that moved, a reply that settled, reasoning that grew
/// — or any field added to these rows later — all take the ordinary path,
/// which is correct, merely slower.
enum TranscriptStreamingTail {
    struct Append {
        /// The reply whose text grew.
        let messageID: String
        /// Its whole text now, not the suffix: the surface reads a prefix of
        /// it and knows what it already has.
        let text: String
    }

    static func append(from old: TranscriptItem, to new: TranscriptItem) -> Append? {
        switch (old, new) {
        case (.message(let was), .message(let now)):
            guard grew(was, now) else { return nil }
            var probe = now
            probe.text = was.text
            guard probe == was else { return nil }
            return Append(messageID: now.id, text: now.text)
        case (.block(let was), .block(let now)):
            // Only the block's own prose reply streams into the page as text;
            // reasoning and tool output are rows of the work list.
            guard let before = was.message, let after = now.message, before.id == after.id, grew(before, after),
                  restoring(now, id: after.id, text: before.text) == was else { return nil }
            return Append(messageID: after.id, text: after.text)
        default: return nil
        }
    }

    /// Only the arriving text grew, whatever else did: the page counts these
    /// so a path it cannot take fast is visible rather than merely slow.
    static func textGrew(from old: TranscriptItem, to new: TranscriptItem) -> Bool {
        switch (old, new) {
        case (.message(let was), .message(let now)): return grew(was, now)
        case (.block(let was), .block(let now)):
            guard let before = was.message, let after = now.message else { return false }
            return grew(before, after)
        default: return false
        }
    }

    private static func grew(_ was: TranscriptMessage, _ now: TranscriptMessage) -> Bool {
        was.id == now.id && was.isStreaming && now.isStreaming && !was.text.isEmpty
            && now.text.utf8.count > was.text.utf8.count && now.text.hasPrefix(was.text)
    }

    /// The row with that reply's text put back, wherever the row carries a
    /// copy of it: the reply itself, the turn's requests, a task summary.
    private static func restoring(_ block: TranscriptBlock, id: String, text: String) -> TranscriptBlock {
        var copy = block
        if copy.message?.id == id { copy.message?.text = text }
        for index in copy.activity.indices where copy.activity[index].id == id { copy.activity[index].text = text }
        if var turn = copy.turn {
            for index in turn.requests.indices where turn.requests[index].id == id { turn.requests[index].text = text }
            copy.turn = turn
        }
        if var summary = copy.taskSummary {
            for index in summary.requests.indices where summary.requests[index].id == id { summary.requests[index].text = text }
            copy.taskSummary = summary
        }
        return copy
    }
}
