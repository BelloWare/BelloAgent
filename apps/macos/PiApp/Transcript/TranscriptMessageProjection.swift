import Foundation

/// The display's projection, kept between tokens. State changes invalidate
/// it; an ordinary fragment replaces only its source's presented row.
@MainActor struct TranscriptMessageProjection {
    struct Context: Equatable {
        var loading: Bool
        var managed: Bool
        var task: String?
        var busy: Bool
        var state: String
        var starting: Bool
        var queueEmpty: Bool
        var editingQueue: Bool
        @MainActor init(_ session: SessionDisplay) {
            loading = session.historyState == .loading && !session.refreshingCachedRows
            managed = session.isManagedSubagent; task = session.delegatedTask
            busy = session.busy; state = session.state; starting = session.loading
            queueEmpty = session.queue.isEmpty; editingQueue = session.queueEditHold != nil
        }
    }
    var context: Context?
    var rows: [TranscriptMessage]?
    var positions: [String: Int] = [:]
    var sourceRows = 0
    var changes = TranscriptChanges()
    mutating func invalidate() { rows = nil }
    mutating func install(_ rows: [TranscriptMessage], context: Context, sources: [String: Int]) {
        self.rows = rows; self.context = context
        positions = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        sourceRows = rows.prefix { sources[$0.id] != nil }.count
        changes = TranscriptChanges()
    }
}

extension SessionDisplay {
    /// Used by row delivery and by fixtures driving that same boundary. The
    /// caller supplies edits within the current row order; semantic changes
    /// retain the complete projection and planner.
    @discardableResult func replaceMessages(_ next: [TranscriptMessage], at indices: [Int]) -> Bool {
        guard next.count == messages.count,
              indices.allSatisfy({ messages.indices.contains($0) && messages[$0].id == next[$0].id }) else { return false }
        let changed = indices.filter { messages[$0] != next[$0] }
        guard !changed.isEmpty else { return true }
        guard changed.allSatisfy({ messages[$0].role == "assistant" && next[$0].role == "assistant" &&
            messages[$0].kind == nil && next[$0].kind == nil && messages[$0].nativeAgentDelivery == nil && next[$0].nativeAgentDelivery == nil }) else { return false }
        if messageProjection.context != .init(self) { messageProjection.invalidate() }
        if messageProjection.rows != nil {
            var presented: [Int] = []
            for index in changed {
                let row = next[index]
                guard let place = messageProjection.positions[row.id] else { continue }
                messageProjection.rows?[place] = presentAgentState(row)
                presented.append(place)
            }
            messageProjection.changes.record(presented)
        }
        messageBytes += changed.reduce(0) { $0 + TranscriptPaging.size(next[$1]) - TranscriptPaging.size(messages[$1]) }
        replacingMessages = true
        messages = next
        replacingMessages = false
        return true
    }

    /// A helper window can replace its tail (a first reply, a new part or a
    /// ledger taking its final source). The prefix retains its projection.
    @discardableResult func replaceMessageTail(_ next: [TranscriptMessage], from start: Int) -> Bool {
        guard start >= 0, start <= min(messages.count, next.count), versionView == nil,
              !(isManagedSubagent && messages.isEmpty) else { return false }
        let oldTail = Array(messages[start...]), newTail = Array(next[start...])
        if oldTail == newTail { return true }
        guard messageProjection.context == .init(self), let shown = messageProjection.rows else { return false }
        let cut = start == messages.count ? messageProjection.sourceRows : messageProjection.positions[messages[start].id]
        guard let cut, messageProjection.sourceRows - cut == oldTail.count,
              zip(oldTail, shown[cut..<messageProjection.sourceRows]).allSatisfy({ $0.id == $1.id }),
              Set(newTail.map(\.id)).count == newTail.count else { return false }
        var projected: [TranscriptMessage] = []
        for row in newTail {
            if let old = messagePositions[row.id], old < start { return false }
            if let old = messagePositions[row.id], messages[old] == row, let place = messageProjection.positions[row.id] {
                projected.append(shown[place])
            } else {
                guard row.role == "assistant", row.kind == nil, row.nativeAgentDelivery == nil else { return false }
                projected.append(presentAgentState(row))
            }
        }
        for row in oldTail { messageProjection.positions[row.id] = nil; messagePositions[row.id] = nil }
        let sourceEnd = messageProjection.sourceRows
        messageProjection.rows?.replaceSubrange(cut..<sourceEnd, with: projected)
        messageProjection.sourceRows = cut + projected.count
        for index in cut..<messageProjection.rows!.count {
            let id = messageProjection.rows![index].id
            messageProjection.positions[id] = index
        }
        for index in start..<next.count { messagePositions[next[index].id] = index }
        messageProjection.changes.recordTail(from: cut)
        messageBytes += newTail.reduce(0) { $0 + TranscriptPaging.size($1) } - oldTail.reduce(0) { $0 + TranscriptPaging.size($1) }
        replacingMessages = true; messages = next; replacingMessages = false
        return true
    }

    func appendMessage(_ row: TranscriptMessage) {
        var next = messages; next.append(row)
        if !replaceMessageTail(next, from: messages.count) { messages = next }
    }
}
