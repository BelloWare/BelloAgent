import Foundation

// Earlier versions of edited messages: which exist, and the rows each one
// read as before an edit hid it. Read-only: nothing here writes the journal
// or changes the live context or the displayed timeline, which always stay
// on the latest version.

/// What the helper keeps to show a version an edit hid: the timeline each
/// branch hid, as positions in `history`, and where every hidden version's
/// message starts in one of them. Positions stay valid because `history` is
/// append-only; a presentation update replaces a row in place.
struct MessageVersionStore {
    var ledger = MessageVersionLedger()
    private(set) var timelines: [[Int]] = []
    private(set) var starts: [String: (timeline: Int, offset: Int)] = [:]

    /// Called just before a branch hides the visible timeline from
    /// `messageID` on: that message, and every version shown after it, keep
    /// the rows they read as until now. The branch's marker rows are left out;
    /// the version switcher takes their place.
    mutating func hide(from messageID: String, visible: [ChatMessage], history: [ChatMessage]) {
        ledger.branched(from: messageID)
        guard let first = visible.firstIndex(where: { $0.id == messageID }) else { return }
        let tail = visible[first...].filter { $0.kind != "branch" }
        // The hidden rows are mostly the latest ones: look them up from the end.
        var wanted = Set(tail.map(\.id)), positions: [String: Int] = [:], index = history.count
        while index > 0, !wanted.isEmpty {
            index -= 1
            if wanted.remove(history[index].id) != nil { positions[history[index].id] = index }
        }
        var rows: [Int] = [], found: [(id: String, offset: Int)] = []
        rows.reserveCapacity(tail.count)
        for message in tail {
            guard let at = positions[message.id] else { continue }
            if message.role == "user", ledger.groupOf[message.id] != nil, starts[message.id] == nil { found.append((message.id, rows.count)) }
            rows.append(at)
        }
        guard !found.isEmpty else { return }
        timelines.append(rows)
        for entry in found { starts[entry.id] = (timelines.count - 1, entry.offset) }
    }
    /// A hidden version's rows, from its message on, as history positions.
    func hiddenRows(of id: String) -> ArraySlice<Int>? {
        guard let start = starts[id] else { return nil }
        return timelines[start.timeline][start.offset...]
    }
}

extension AgentSession {
    /// The mark a user row carries when its message has versions: which one
    /// it is, of how many, and every version's message id, oldest first.
    func versionMark(_ message: ChatMessage) -> JSON? {
        guard message.role == "user", let ids = versions.ledger.versions(of: message.id), let at = ids.firstIndex(of: message.id) else { return nil }
        var mark: JSON = ["index": JSON(at + 1), "count": JSON(ids.count)]
        if ids.count <= 64 { mark["ids"] = .array(ids.map { JSON($0) }) }
        return mark
    }
    /// A version's rows, from its message on: the live timeline for the
    /// version shown now, else the timeline it read as when an edit hid it.
    func versionRows(_ id: String) -> [ChatMessage]? {
        if let at = visible.firstIndex(where: { $0.id == id }) { return visible[at...].filter { $0.kind != "branch" } }
        guard let rows = versions.hiddenRows(of: id) else { return nil }
        return rows.compactMap { history.indices.contains($0) ? history[$0] : nil }
    }
    private func versionList(_ ids: [String]) -> JSON {
        let shown = Set(visible.lazy.filter { $0.role == "user" }.map(\.id))
        let wanted = Set(ids)
        let messages = Dictionary(history.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current: JSON = .null
        let entries: [JSON] = ids.enumerated().map { offset, id in
            let rows = versionRows(id) ?? []
            let message = messages[id]
            let live = shown.contains(id)
            if live { current = JSON(offset + 1) }
            var entry: JSON = ["index": JSON(offset + 1), "messageId": JSON(id), "live": JSON(live), "rows": JSON(rows.count),
                               "text": JSON(preview(message.map { $0.displayText ?? $0.text } ?? "", bytes: 512)),
                               "turns": .array(rows.filter { $0.role == "user" }.prefix(256).map { JSON($0.id) })]
            if let at = message?.timestamp { entry["at"] = JSON(at) }
            let attempts = rows.flatMap { $0.requestAttemptIDs ?? [] }
            entry["requests"] = JSON(Set(attempts).count)
            return entry
        }
        return ["group": JSON(ids[0]), "count": JSON(ids.count), "current": current, "versions": .array(entries)]
    }
    /// `session.versions`: one message's versions, or with no message every
    /// edited message's, in the order each was first edited.
    public func messageVersions(_ params: JSON) throws -> JSON {
        if params["messageId"].isNull {
            return ["groups": .array(versions.ledger.edited.suffix(256).map(versionList))]
        }
        let id = try identity(params["messageId"])
        guard history.contains(where: { $0.id == id }) else { throw AgentError("message_missing", "Message is not retained") }
        guard let ids = versions.ledger.versions(of: id) else { return ["messageId": JSON(id), "count": 1, "versions": []] }
        var result = versionList(ids); result["messageId"] = JSON(id)
        return result
    }
    /// `session.version.page`: a version's rows from `offset` on, in the
    /// transcript's own row format, each with the request attempts it came
    /// from. Byte-bounded like a history window; `next` continues it.
    public func versionPage(_ params: JSON) throws -> JSON {
        let id = try identity(params["messageId"])
        guard let ids = versions.ledger.versions(of: id), let index = ids.firstIndex(of: id) else {
            throw AgentError("version_missing", "That message has no earlier versions.")
        }
        guard let rows = versionRows(id) else { throw AgentError("version_missing", "That version's rows are not retained.") }
        let offset = try boundedInt(params["offset"], maximum: 1_000_000)
        guard offset <= rows.count else { throw AgentError("invalid_range", "The version page starts past its last row.") }
        var page: [JSON] = [], bytes = HistoryWindowPolicy.metadataAllowance, end = offset
        for message in rows[offset...] {
            // A version reads as it was: nested edits show no switcher of their own.
            var row = boundedDisplayRow(displayMessage(message)).removing(["versions"])
            if let attempts = message.requestAttemptIDs, !attempts.isEmpty { row["requestAttemptIDs"] = .array(attempts.map { JSON($0) }) }
            let size = (try? row.data().count) ?? HistoryWindowPolicy.envelopeBytes
            guard page.isEmpty || bytes + size + 1 <= HistoryWindowPolicy.envelopeBytes else { break }
            bytes += size + 1; page.append(row); end += 1
        }
        let shown = rows[offset..<end]
        let keys = Set(shown.compactMap { message in message.taskExecutionID.map { TaskPresentationRecord.identity(message.taskRootID ?? "", $0) } })
        let sources = Set(shown.map(\.id))
        let tasks = (try? JSON.parse(JSONEncoder().encode(recentTaskPresentations.filter { keys.contains($0.key) || $0.anchorSourceID.map(sources.contains) == true }))) ?? []
        return ["messageId": JSON(id), "version": JSON(index + 1), "count": JSON(ids.count), "live": JSON(visible.contains { $0.id == id }),
                "messages": .array(page), "start": JSON(offset), "end": JSON(end), "total": JSON(rows.count),
                "next": end < rows.count ? JSON(end) : .null, "taskRecords": tasks]
    }
}
