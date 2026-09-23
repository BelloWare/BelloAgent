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
///
/// "Wherever the row carries a copy of it" includes the response timeline: a
/// reply the helper streams today arrives as "append" events on one text
/// segment, and its part row holds the words in its message and in that
/// segment, whose revision moves with every token. Putting back the message's
/// text alone would leave every such row looking changed, and no live reply
/// would ever take the fast path.
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
            guard grew(was, now), let probe = restored(now, to: was), probe == was else { return nil }
            return Append(messageID: now.id, text: now.text)
        case (.block(let was), .block(let now)):
            // Only the block's own prose reply streams into the page as text;
            // reasoning and tool output are rows of the work list.
            guard let before = was.message, let after = now.message, before.id == after.id, grew(before, after),
                  drawsProse(now), restoring(now, from: was, id: after.id) == was else { return nil }
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
            guard let before = was.message, let after = now.message, drawsProse(now) else { return false }
            return grew(before, after)
        default: return false
        }
    }

    private static func grew(_ was: TranscriptMessage, _ now: TranscriptMessage) -> Bool {
        was.id == now.id && was.isStreaming && now.isStreaming && !was.text.isEmpty
            && now.text.utf8.count > was.text.utf8.count && now.text.hasUTF8Prefix(was.text)
    }

    /// Whether the row draws its message's text as the reply's prose, through
    /// the reply's own surface: a legacy body, or the text part of a timeline.
    /// A reasoning or tool part streams too, but into a row of the work list.
    private static func drawsProse(_ block: TranscriptBlock) -> Bool {
        guard let part = block.part else { return true }
        return ["text", "refusal"].contains(part.part.kind) && part.text == block.message?.text
    }

    /// The row with that reply's arriving text put back, wherever the row
    /// carries a copy of it: its own timeline segment, the reply itself, the
    /// turn's requests, a task summary. Nil when a copy changed by anything
    /// other than text appended to it.
    private static func restoring(_ block: TranscriptBlock, from was: TranscriptBlock, id: String) -> TranscriptBlock? {
        var copy = block
        if copy.part != was.part {
            guard let part = copy.part, let before = was.part, let restored = restored(part, to: before) else { return nil }
            copy.part = restored
        }
        if let message = copy.message, let before = was.message, message.id == id, message != before {
            guard let restored = restored(message, to: before) else { return nil }
            copy.message = restored
        }
        func restore(_ messages: inout [TranscriptMessage], to previous: [TranscriptMessage]) -> Bool {
            guard messages.count == previous.count else { return false }
            for index in messages.indices where messages[index].id == id && messages[index] != previous[index] {
                guard previous[index].id == id, let restored = restored(messages[index], to: previous[index]) else { return false }
                messages[index] = restored
            }
            return true
        }
        guard restore(&copy.activity, to: was.activity) else { return nil }
        if var turn = copy.turn, let before = was.turn {
            guard restore(&turn.requests, to: before.requests) else { return nil }
            copy.turn = turn
        }
        if var summary = copy.taskSummary, let before = was.taskSummary {
            guard restore(&summary.requests, to: before.requests) else { return nil }
            copy.taskSummary = summary
        }
        return copy
    }

    /// A copy of the reply with its text, and the timeline it may carry, put
    /// back — provided both only grew by appending.
    private static func restored(_ now: TranscriptMessage, to was: TranscriptMessage) -> TranscriptMessage? {
        var copy = now
        if !copy.text.hasSameUTF8(as: was.text) {
            guard copy.text.hasUTF8Prefix(was.text) else { return nil }
            copy.text = was.text
        }
        if copy.responseTimeline != was.responseTimeline {
            guard let timeline = copy.responseTimeline, let before = was.responseTimeline,
                  timeline.segments.count == before.segments.count else { return nil }
            var restored = timeline
            for index in restored.segments.indices where restored.segments[index] != before.segments[index] {
                guard let segment = Self.restored(restored.segments[index], to: before.segments[index]) else { return nil }
                restored.segments[index] = segment
            }
            copy.responseTimeline = restored
        }
        return copy
    }

    /// A timeline segment with its text and revision put back, provided the
    /// only thing that happened to it is text appended to its end.
    private static func restored(_ now: ResponseTimeline.Segment, to was: ResponseTimeline.Segment) -> ResponseTimeline.Segment? {
        guard now.id == was.id, now.text.utf8.count > was.text.utf8.count, now.text.hasUTF8Prefix(was.text) else { return nil }
        var copy = now
        copy.text = was.text
        copy.revision = was.revision
        return copy
    }
}
