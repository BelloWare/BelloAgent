import AppKit

/// Warm tab switches reuse immutable native row geometry, never hidden views,
/// timers or a previous pane's local disclosure/selection state. AppKit still
/// validates the rows entering the viewport before keeping their geometry.
@MainActor final class TranscriptGeometryCache {
    static let shared = TranscriptGeometryCache()
    private struct Key: Hashable {
        var sessionID: String
        var rowID: String
        var width: CGFloat
        var backingScale: CGFloat
    }
    private struct Entry {
        var item: TranscriptItem
        var fresh: Bool
        var environment: TranscriptRowEnvironment
        var disclosure: TranscriptRowDisclosure
        var size: CGSize
        var cost: Int
        var accessed: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    let countLimit: Int
    let byteLimit: Int
    let entryByteLimit: Int
    private(set) var byteCost = 0
    var count: Int { entries.count }

    init(countLimit: Int = 1_000, byteLimit: Int = 16 << 20, entryByteLimit: Int = 256 << 10) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
        self.entryByteLimit = max(0, entryByteLimit)
    }

    /// A row with any local height-changing disclosure always takes the normal
    /// native measurement path. Its open/closed state belongs to that row host,
    /// not the immutable transcript projection. Live output is never shared.
    static func permits(_ item: TranscriptItem) -> Bool {
        switch item {
        case .message(let message):
            return !message.isStreaming && !["compaction", "execution", "toolResult"].contains(message.kind ?? "") &&
                message.responseTimeline == nil && (message.tools ?? []).isEmpty &&
                (message.thinking ?? "").isEmpty && message.text.utf8.count <= 32_768
        case .block(let block):
            if let part = block.part, !["text", "refusal"].contains(part.part.kind) { return false }
            return !block.live && block.turn?.live != true && block.tools.isEmpty &&
                block.replies.allSatisfy { $0.text.utf8.count <= 32_768 && ($0.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.tools ?? []).isEmpty }
        }
    }

    private static func cost(_ item: TranscriptItem, sessionID: String) -> Int {
        func text(_ value: String?) -> Int { value?.utf8.count ?? 0 }
        func tool(_ value: ToolView) -> Int {
            256 + text(value.id) + text(value.name) + text(value.state) + text(value.path) + text(value.input) + text(value.output)
        }
        let messages: [TranscriptMessage]
        var extra = text(sessionID) + text(item.id)
        switch item {
        case .message(let message): messages = [message]
        case .block(let block):
            messages = block.replies + (block.turn?.requests ?? [])
            extra += text(block.id) + text(block.key) + text(block.turnID) + text(block.accounting.model) + text(block.accounting.modelMessageID)
            if let part = block.part {
                let evidence = part.part
                extra += 256 + text(part.id) + text(part.text) + text(part.state)
                extra += text(evidence.attemptID) + text(evidence.itemID) + text(evidence.kind) + text(evidence.update)
                extra += text(evidence.text) + text(evidence.callID) + text(evidence.name) + text(evidence.evidence) + text(evidence.reconcilesPartKey)
            }
            if let turn = block.turn {
                extra += text(turn.notice) + text(turn.accounting.model) + text(turn.accounting.modelMessageID)
                if let current = turn.current { extra += tool(current) }
            }
        }
        // Count every retained payload, including duplicate projections, rather
        // than assuming Swift will continue sharing their string allocations.
        // Fixed allowances cover value/container fields; this is a payload
        // budget, not an assertion about allocator-level process memory.
        var total = 512 + extra
        for message in messages {
            total += 512 + text(message.id) + text(message.role) + text(message.text)
            total += text(message.thinking) + text(message.detail) + text(message.kind)
            total += text(message.state) + text(message.stopReason) + text(message.turn)
            total += (message.tools ?? []).reduce(0) { $0 + tool($1) }
            total += (message.accounting?.models?.names ?? []).reduce(0) { $0 + 32 + text($1) }
        }
        return total
    }

    func measurement(sessionID: String, item: TranscriptItem, fresh: Bool, environment: TranscriptRowEnvironment,
                     disclosure: TranscriptRowDisclosure = .default, width: CGFloat, backingScale: CGFloat) -> CGSize? {
        let key = Key(sessionID: sessionID, rowID: item.id, width: width, backingScale: backingScale)
        guard var entry = entries[key] else { return nil }
        guard entry.item == item, entry.fresh == fresh, entry.environment == environment, entry.disclosure == disclosure else {
            remove(key)
            return nil
        }
        clock &+= 1; entry.accessed = clock; entries[key] = entry
        return entry.size
    }

    /// Called only after a later native fitting pass confirms the exact size.
    /// A partial first-mount proposal is never a shared cache entry.
    func store(_ size: CGSize, sessionID: String, item: TranscriptItem, fresh: Bool,
               environment: TranscriptRowEnvironment, disclosure: TranscriptRowDisclosure = .default, backingScale: CGFloat) {
        guard Self.permits(item), size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              backingScale.isFinite, backingScale > 0 else { return }
        let cost = Self.cost(item, sessionID: sessionID)
        let key = Key(sessionID: sessionID, rowID: item.id, width: size.width, backingScale: backingScale)
        remove(key)
        guard countLimit > 0, cost <= byteLimit, cost <= entryByteLimit else { return }
        while entries.count >= countLimit || byteCost > byteLimit - cost {
            guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(item: item, fresh: fresh, environment: environment, disclosure: disclosure, size: size, cost: cost, accessed: clock)
        byteCost += cost
    }

    func invalidate(sessionID: String, item: TranscriptItem, width: CGFloat, backingScale: CGFloat) {
        let key = Key(sessionID: sessionID, rowID: item.id, width: width, backingScale: backingScale)
        // An old mounted row must not remove a newer content revision's entry.
        if entries[key]?.item == item { remove(key) }
    }

    private func remove(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { byteCost -= removed.cost }
    }
}
