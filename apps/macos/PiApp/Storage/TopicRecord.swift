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

/// A key with a default may be missing from a row another version wrote:
/// it reads as that default, as `ChatRecord`'s do. `createdAt` stays
/// required: it is the topic's fixed identity in its project (`put` refuses
/// a change), which a default of now would change on every read. Encoding
/// is the synthesized one.
extension TopicRecord {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); workspaceID = try c.decode(String.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
    }
}
