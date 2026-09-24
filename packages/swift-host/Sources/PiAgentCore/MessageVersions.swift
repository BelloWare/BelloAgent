import Foundation

/// The versions of edited user messages, read from a journal's records in
/// the order they were written. An edit writes a branch record naming the
/// message it replaces, and the next user message the journal records is the
/// replacement. Version 1 is the message as first sent; each edit of any of
/// its versions adds the next one, so editing a replacement again, or editing
/// after a compaction, extends the same list.
///
/// Shared by the helper and the app's retained history reader, which feed it
/// the same records in the same order and so number versions alike. It reads
/// what every edit already wrote: a chat edited before versions were shown
/// reads the same way, and no journal is rewritten.
struct MessageVersionLedger: Sendable, Equatable {
    /// At most this many edited messages are tracked; later edits still work,
    /// they just show no earlier versions.
    static let groupLimit = 4096
    /// Each edited message's versions, oldest first, keyed by the first one.
    private(set) var groups: [String: [String]] = [:]
    /// The list each version belongs to.
    private(set) var groupOf: [String: String] = [:]
    /// The lists in the order their first edit was recorded.
    private var order: [String] = []
    /// The list whose replacement has not been recorded yet.
    private var awaiting: String?

    init() {}

    /// A branch record: `messageID` is replaced by the next user message.
    mutating func branched(from messageID: String) {
        // A branch that names no message edits nothing the list can show.
        guard !messageID.isEmpty else { awaiting = nil; return }
        if let group = groupOf[messageID] { awaiting = group; return }
        guard groups.count < Self.groupLimit else { awaiting = nil; return }
        groups[messageID] = [messageID]; groupOf[messageID] = messageID; order.append(messageID); awaiting = messageID
    }
    /// A user message record.
    mutating func recorded(userMessage id: String) {
        guard let group = awaiting else { return }
        awaiting = nil
        guard groupOf[id] == nil else { return }
        groups[group, default: []].append(id); groupOf[id] = group
    }
    /// A message's versions, oldest first, when it has more than one.
    func versions(of id: String) -> [String]? {
        guard let group = groupOf[id], let ids = groups[group], ids.count > 1 else { return nil }
        return ids
    }
    /// Where a message stands among its versions, 1-based, when it has more than one.
    func position(of id: String) -> (index: Int, count: Int)? {
        guard let ids = versions(of: id), let at = ids.firstIndex(of: id) else { return nil }
        return (at + 1, ids.count)
    }
    /// Every edited message's versions, in the order each was first edited.
    var edited: [[String]] { order.compactMap { groups[$0] }.filter { $0.count > 1 } }
}
