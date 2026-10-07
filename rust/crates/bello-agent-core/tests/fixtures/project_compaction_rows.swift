// Field-only fixture carrier for the real CompactionPlanner groups/source code.
// Selection, protection and grouping algorithms are extracted verbatim from
// checked-in Swift; this DTO supplies no policy or computed behavior.
struct ChatMessage: Sendable {
    let id: String
    let role: String
    let replayEligible: Bool
    let content: [JSON]
    let toolCallId: String?
    let kind: String?
    let compaction: JSON?
    let userInput: JSON?
    let taskRootID: String?
    let contextNote: JSON?
}
