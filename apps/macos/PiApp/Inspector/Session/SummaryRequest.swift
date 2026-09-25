import Foundation

/// Classifies current appended checkpoint instructions and historical summary
/// requests without rewriting their captured conversation.
enum SummaryRequestKind: String, Sendable, Equatable {
    /// Normal typed context followed by one checkpoint instruction.
    case continuation
    /// The history before the kept messages, summarized afresh.
    case earlierHistory
    /// New messages folded into a summary so far (`<previous-summary>`): a
    /// later compaction's update, or an earlier helper's next chained part.
    case update
    /// The start of a turn too large to keep whole (pi's turn-prefix prompt).
    case turnStart
    /// The history and the start of a turn too large to keep whole, in one request.
    case historyAndTurnStart
    /// An update of the summary so far and the start of a turn too large to keep whole.
    case updateAndTurnStart
}

struct SummaryRequestInfo: Sendable, Equatable {
    var kind: SummaryRequestKind
    /// The prompt's instruction: what follows the conversation, and the
    /// summary so far when there is one. At most `instructionLimit`
    /// characters; "Show all" reads it whole from the prompt (`item`).
    var instruction: String
    /// The instruction's first lines, wrapped as an item's preview is.
    var lines: [String] = []
    /// The whole instruction's length, in UTF-16 units.
    var characters = 0
    /// Which of the request's items is the prompt the instruction ends.
    var item: Int? = nil

    static let instructionLimit = 4_000
    static let checkpointMarker = "Create a concise continuation checkpoint for this conversation."
    /// Pi's summarization system prompt opens with this.
    static let systemMarker = "You are a context summarization assistant."
    /// Pi's turn-prefix prompt, and an earlier helper's turn-prefix update, carry this.
    static let turnPrefixMarker = "This is the PREFIX of a turn that was too large to keep."
    /// The helper's prompt for a split turn's prefix summarized with the history.
    static let splitTurnMarker = "The messages in <turn-prefix> are the PREFIX of a turn that was too large to keep."
    /// Pi's update prompt opens with this.
    static let updateMarker = "The messages above are NEW conversation messages"

    /// Whether a request's system prompt is pi's summarization prompt.
    static func isSummary(system: String?) -> Bool { system?.hasPrefix(systemMarker) == true }

    /// The kind and instruction of a summary request, from the text of its
    /// one user message: `<conversation>…</conversation>`, then
    /// `<turn-prefix>…</turn-prefix>` when it summarizes a split turn's start
    /// too, then `<previous-summary>…</previous-summary>` when there is a
    /// summary so far, then the instruction. The last of the closing tags ends
    /// what came before the instruction; any one may occur, quoted, inside
    /// what it closes, and only the last occurrence is the real end.
    static func read(prompt: String, limit: Int = instructionLimit) -> SummaryRequestInfo? {
        if prompt.hasPrefix(checkpointMarker) {
            let kept = String(prompt.prefix(limit))
            return SummaryRequestInfo(kind: .continuation, instruction: kept,
                lines: RequestDocument.wrap(RequestDocument.prefix(kept as NSString, limit: RequestDocument.previewLimit)),
                characters: (prompt as NSString).length)
        }
        let closings = ["</conversation>", "</turn-prefix>", "</previous-summary>"].map { prompt.range(of: $0, options: .backwards) }
        guard let end = closings.compactMap({ $0 }).max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let update = closings[2]?.lowerBound == end.lowerBound
        let instruction = prompt[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = update && instruction.hasPrefix(updateMarker)
        let kind: SummaryRequestKind = instruction.contains(turnPrefixMarker) ? .turnStart
            : instruction.contains(splitTurnMarker) ? (updated ? .updateAndTurnStart : .historyAndTurnStart)
            : updated ? .update : .earlierHistory
        let kept = String(instruction.prefix(limit))
        return SummaryRequestInfo(kind: kind, instruction: kept,
                                  lines: RequestDocument.wrap(RequestDocument.prefix(kept as NSString, limit: RequestDocument.previewLimit)),
                                  characters: (instruction as NSString).length)
    }
}

/// The summary requests of one compaction, in the order they were sent,
/// and what each is called.
enum SummaryRequestLabel {
    /// "start of this turn"; an update is "part N of M" when it is an earlier
    /// helper's chained part of one compaction's history, else "update";
    /// anything else is "earlier history", and a request that also
    /// summarized a split turn's start says so. `kinds` are the compaction's
    /// requests in order, nil where the body has not been read.
    static func label(at index: Int, kinds: [SummaryRequestKind?]) -> String? {
        guard kinds.indices.contains(index), let kind = kinds[index] else { return nil }
        switch kind {
        case .continuation: return "continuation checkpoint"
        case .turnStart: return "start of this turn"
        case .earlierHistory: return "earlier history"
        case .historyAndTurnStart: return "earlier history and start of this turn"
        case .updateAndTurnStart: return "update and start of this turn"
        case .update:
            // The history's parts: every request that is not the turn's start.
            // They can only be counted once every body has been read.
            guard !kinds.contains(where: { $0 == nil }) else { return "update" }
            let parts = kinds.indices.filter { kinds[$0] != .turnStart }
            guard parts.count > 1, let position = parts.firstIndex(of: index) else { return "update" }
            return "part \(position + 1) of \(parts.count)"
        }
    }
}

/// How the Conversation tab heads a summary request: the outline's first row,
/// which part of its compaction it is and what that part summarizes, and the
/// instruction its prompt ends with under it, shown whole in place on "Show
/// all".
struct InspectorSummaryHeading: Equatable {
    var info: SummaryRequestInfo
    /// "part 2 of 2" once the compaction's other requests are read.
    var name: String
    var subject: String

    init(_ info: SummaryRequestInfo, label: String?) {
        self.info = info
        switch info.kind {
        case .continuation:
            name = label ?? "continuation checkpoint"
            subject = "Reads the active conversation unchanged, summarizes the older context, and keeps the recent messages intact."
        case .earlierHistory:
            name = label ?? "earlier history"
            subject = "Summarizes the history before the messages the compaction keeps."
        case .update:
            name = label ?? "update"
            subject = "Folds new messages into the summary so far, given in <previous-summary>."
        case .turnStart:
            name = label ?? "start of this turn"
            subject = "Summarizes the start of a turn too large to keep whole; its recent work is kept."
        case .historyAndTurnStart:
            name = label ?? "earlier history and start of this turn"
            subject = "Summarizes the history before the messages the compaction keeps, and the start of a turn too large to keep whole; its recent work is kept."
        case .updateAndTurnStart:
            name = label ?? "update and start of this turn"
            subject = "Folds new messages into the summary so far, given in <previous-summary>, and summarizes the start of a turn too large to keep whole."
        }
    }
}
