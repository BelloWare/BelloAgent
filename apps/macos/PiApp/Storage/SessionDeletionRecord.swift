import Foundation

/// One durable member intent avoids a growing, size-limited family manifest.
/// The tombstone remains after the intent is cleared: IDs are never reused.
struct SessionDeletionRecord: Codable, Sendable {
    static let kind = "session-delete"
    var id: String
    var ownerID: String
    var workspaceID: String
    var path: String?
}
