import Foundation

/// One durable member intent avoids a growing, size-limited family manifest.
/// The tombstone remains after the intent is cleared: IDs are never reused.
struct SessionDeletionRecord: Codable, Sendable {
    static let kind = "session-delete"
    var id: String
    var ownerID: String
    var workspaceID: String
    var path: String?
    /// Set only after the helper durably repaired surviving numeric ledgers.
    /// Missing on older intents: those still require the repair barrier.
    var repairCompleted: Bool? = nil
    /// A saved side deleted with its chat (0.1.129), at this depth below the
    /// deleted root. Only these members accept a `side_‹id›.jsonl` journal;
    /// managed children keep their UUID names. Absent on older intents.
    var sideDepth: Int? = nil

    /// A side's own identity is used in file names; it must be one plain name.
    var isSavedSide: Bool {
        guard let sideDepth, sideDepth > 0, sideDepth <= 128, !id.isEmpty, id.utf8.count <= 128, id != ".", id != ".." else { return false }
        return !id.contains { "/\\:\u{0}".contains($0) || $0.isNewline }
    }
}
