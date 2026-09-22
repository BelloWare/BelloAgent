import Foundation

/// Shared by the read-only desktop and the live helper. These are presentation
/// budgets, never model-context or journal retention limits. A single full
/// row may exceed the preferred byte window; IPC chunks do not shorten it.
public enum HistoryWindowPolicy {
    public static let turns = 3
    public static let rows = 60
    public static let envelopeBytes = 256 * 1024
    public static let metadataAllowance = 8192
    public static let residentRows = 500
    public static let residentBytes = 4_000_000
    public static let automaticFills = 2

    /// Each delivered visible user input is a display-turn boundary, including
    /// steering. A task's nativeTurn can span several submissions; it must not
    /// merge those inputs. Old/imported rows use the same conservative boundary.
    public static func range(count: Int, before: Int? = nil, after: Int? = nil,
                             around: Int? = nil, target: Int = turns,
                             isUser: (Int) -> Bool) -> Range<Int> {
        if let start = around ?? after.map({ $0 + 1 }) {
            let start = min(count, max(0, start))
            var end = start, turns = start < count && isUser(start) ? 0 : 1
            while end < count && end - start < rows {
                if isUser(end) { if turns >= target { break }; turns += 1 }
                end += 1
            }
            return start..<end
        }
        let end = min(count, max(0, before ?? count))
        var start = end, turns = 0
        while start > 0 && end - start < rows {
            start -= 1
            if isUser(start) { turns += 1; if turns >= target { break } }
        }
        return start..<end
    }
}

/// Stable exclusive entry boundary. The UI passes this through without index
/// arithmetic. Source adapters validate incarnation and structural lineage;
/// ordinary appends keep earlier boundaries valid.
public struct ConversationCursor: Codable, Equatable, Sendable {
    public var incarnation: String
    public var lineage: String
    public var entry: String
    public var committedBytes: UInt64? = nil
    public var fingerprint: String? = nil
    public init(incarnation: String, lineage: String, entry: String) {
        self.incarnation = incarnation; self.lineage = lineage; self.entry = entry
    }
}
