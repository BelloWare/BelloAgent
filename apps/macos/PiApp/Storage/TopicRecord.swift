import Foundation

/// A topic organizes sessions within one project. It is desktop metadata only:
/// moving or deleting a topic never changes a conversation journal or its tools.
struct TopicRecord: Codable, Sendable, Hashable, Identifiable {
    static let recordKind = "topic"
    static let deletedRecordKind = "topic-deleted"

    var id: String
    var workspaceID: String
    var title: String
    var createdAt: Date = Date()
    var expanded: Bool = true
    var revision: Int64 = 0

    static func normalizedTitle(_ title: String) throws -> String {
        let trimmed = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !trimmed.isEmpty else { throw HostError.failure("Enter a title for this topic.") }
        return String(trimmed.prefix(120))
    }

    static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains)
    }

    var isValid: Bool {
        Self.isValidIdentifier(id) && Self.isValidIdentifier(workspaceID)
            && workspaceID != WorkspaceRecord.scratchID && createdAt.timeIntervalSinceReferenceDate.isFinite
            && (try? Self.normalizedTitle(title)) == title && revision >= 0
    }

    static func sidebarPrecedes(_ lhs: TopicRecord, _ rhs: TopicRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}
