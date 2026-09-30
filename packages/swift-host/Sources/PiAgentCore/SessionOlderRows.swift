import Darwin
import Foundation

// The rows a chat opened from its journal's metadata file did not load: the
// shown rows before the loaded ones, and rows an edit hid before them. The
// first read that reaches them (an earlier page, a search, a message read)
// replays the journal once, as a full open does, and keeps only where each
// of those rows is. Each is then read from the journal when it is asked for.
// The chat goes on holding just the rows it loaded, and a reader gets what a
// chat holding every row gives. An edit, a fork and a version read still
// load every row (`ensureFullHistory`).

/// Where the rows a chat did not load are in its journal.
struct OlderRows {
    struct Entry {
        var span: JournalCheckpoint.Row
        var user: Bool
    }
    /// The shown rows before the loaded ones, in order (`shown` of them),
    /// then the rows no timeline shows now: the versions an edit hid.
    var rows: [Entry] = []
    var shown = 0
    var positions: [String: Int] = [:]
    /// Rows their record does not give back as the replay left them, such
    /// as a progress row a compaction adopted: held as they are.
    var kept: [String: ChatMessage] = [:]
    /// Each tool call of a row here, with the row holding its result: the
    /// pairs a chat holding every row makes.
    var results: [String: [String: String]] = [:]
    /// History rows not loaded, which a chat holding every row counts.
    var historyRows = 0
    /// A row is not where the replay found it: the journal is not the one read.
    struct Unreadable: Error {}
    /// Where the row `id` is in the journal, if it is one of these and its
    /// record gives it back as the replay left it.
    func span(of id: String) -> JournalCheckpoint.Row? {
        guard kept[id] == nil, let position = positions[id] else { return nil }
        return rows[position].span
    }
}

/// The shown rows by position, as a chat holding every row has them: the
/// rows this chat did not load first, once it knows where they are, then
/// the loaded ones. A row not loaded is read from the journal when asked for.
struct ShownRows {
    let older: OlderRows?
    /// Shown rows before these that no position reaches: a chat opened from
    /// its metadata file that has not read where its older rows are.
    let base: Int
    let visible: [ChatMessage]
    let history: [ChatMessage]
    let descriptor: Int32?
    /// Rows read back so far, for a read that asks for one more than once.
    var read: [String: ChatMessage] = [:]
    var olderCount: Int { older?.shown ?? 0 }
    var count: Int { olderCount + visible.count }
    func id(_ position: Int) -> String {
        if let older, position < older.shown { return older.rows[position].span.id }
        return visible[position - olderCount].id
    }
    func isUser(_ position: Int) -> Bool {
        if let older, position < older.shown { return older.rows[position].user }
        return visible[position - olderCount].role == "user"
    }
    func position(of id: String) -> Int? {
        if let at = older?.positions[id] { return at < olderCount ? at : nil }
        return visible.firstIndex { $0.id == id }.map { $0 + olderCount }
    }
    /// Whether the row is one this chat did not load.
    func isOlder(_ id: String) -> Bool { older?.positions[id] != nil }
    mutating func row(_ position: Int) throws -> ChatMessage {
        if let older, position < older.shown { return try stored(older.rows[position]) }
        return visible[position - olderCount]
    }
    /// A row of the whole history, loaded or read back.
    mutating func message(_ id: String) throws -> ChatMessage? {
        if let older, let at = older.positions[id] { return try stored(older.rows[at]) }
        return history.first { $0.id == id }
    }
    /// Reads the rows at `positions` this chat did not load, several at a
    /// time, for a read that goes through many of them.
    mutating func prefetch(_ positions: Range<Int>) throws {
        guard let older, let descriptor else { return }
        let wanted = positions.clamped(to: 0..<older.shown).map { older.rows[$0].span }.filter { older.kept[$0.id] == nil && read[$0.id] == nil }
        guard wanted.count > 1 else { return }
        let rows = inParallel(wanted.count) { AgentSession.storedRow(wanted[$0], descriptor: descriptor) }
        for (span, row) in zip(wanted, rows) {
            guard let row else { throw OlderRows.Unreadable() }
            read[span.id] = row
        }
    }
    /// Lets go of the rows read back so far.
    mutating func forget() { read.removeAll(keepingCapacity: true) }
    private mutating func stored(_ entry: OlderRows.Entry) throws -> ChatMessage {
        let id = entry.span.id
        if let kept = older?.kept[id] { return kept }
        if let held = read[id] { return held }
        guard let descriptor, let message = AgentSession.storedRow(entry.span, descriptor: descriptor) else { throw OlderRows.Unreadable() }
        read[id] = message
        return message
    }
}

/// A replay handed to another thread to be let go of there.
private final class Spent: @unchecked Sendable {
    private var replay: JournalReplay?
    init(_ replay: JournalReplay?) { self.replay = replay }
    func release() { replay = nil }
}

/// `work` for each of `count` items, spread over the processors, in order.
func inParallel<T>(_ count: Int, _ work: (Int) -> T?) -> [T?] {
    var results = [T?](repeating: nil, count: count)
    guard count > 0 else { return results }
    results.withUnsafeMutableBufferPointer { out in
        let lanes = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount)), slots = Slots(out)
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            autoreleasepool {
                var at = lane
                while at < count { slots.out[at] = work(at); at += lanes }
            }
        }
    }
    return results
}

/// The results' storage, shared by `inParallel`'s lanes. Each lane writes
/// only the slots its own indices name, and the storage outlives them all.
private struct Slots<T>: @unchecked Sendable {
    let out: UnsafeMutableBufferPointer<T?>
    init(_ out: UnsafeMutableBufferPointer<T?>) { self.out = out }
}

extension AgentSession {
    /// A row this chat did not load, from its record, as a replay leaves it.
    static func storedRow(_ span: JournalCheckpoint.Row, descriptor: Int32) -> ChatMessage? {
        guard let bytes = JournalCheckpoint.rowBytes(span, descriptor: descriptor), var message = journalRow(span, bytes: bytes) else { return nil }
        _ = endWithoutReceipt(&message)
        return message
    }

    /// Learns where the rows this chat did not load are (`olderIndex`), once.
    /// A replay that does not end in the rows this chat holds loads every row
    /// instead, as before.
    func loadOlderRows() throws {
        guard partialHistory, olderIndex == nil, journal != nil else { return }
        var spent: JournalReplay?
        if !(try indexOlderRows(&spent)) { try ensureFullHistory() }
        // The replay's rows are let go of on another thread, and their pages
        // returned to the system after them, while the reader has its page.
        let replay = Spent(spent); spent = nil
        DispatchQueue.global(qos: .utility).async { replay.release(); malloc_zone_pressure_relief(nil, 0) }
    }

    private func indexOlderRows(_ spent: inout JournalReplay?) throws -> Bool {
        guard let journal else { return false }
        spent = try Self.replay(journal, url: journal.url, id: id, binding: profile.binding, spendTracked: spendTracked, resume: false)
        guard let replayed = spent else { return false }
        let shown = replayed.visible.count - visible.count
        guard shown == olderRows, zip(replayed.visible[shown...], visible).allSatisfy({ $0.id == $1.id }) else { return false }
        let loaded = Set(history.map(\.id))
        let unloaded = replayed.history.filter { !loaded.contains($0.id) }
        guard replayed.history.count - unloaded.count == history.count, let file = try? FileHandle(forReadingFrom: journal.url) else { return false }
        defer { try? file.close() }
        var index = OlderRows()
        // Only a row with a kind is ever changed after its record is read
        // (a progress row a compaction adopted); the rest are their records.
        var checked: [(message: ChatMessage, span: JournalCheckpoint.Row)] = []
        func add(_ message: ChatMessage) {
            let span = replayed.rowSpans[message.id]
            if let span { if message.kind != nil { checked.append((message, span)) } } else { index.kept[message.id] = message }
            index.positions[message.id] = index.rows.count
            index.rows.append(.init(span: span ?? .init(id: message.id, kind: .message, offset: 0, length: 0), user: message.role == "user"))
        }
        for message in replayed.visible[..<shown] { add(message) }
        index.shown = shown
        for message in unloaded where index.positions[message.id] == nil { add(message) }
        let descriptor = file.fileDescriptor
        let same = inParallel(checked.count) { Self.storedRow(checked[$0].span, descriptor: descriptor) == checked[$0].message }
        for (row, same) in zip(checked, same) where same != true { index.kept[row.message.id] = row.message }
        let tools = ToolHistoryIndex(replayed.history)
        for message in unloaded where message.role == "assistant" {
            guard let pairs = tools.results[message.id] else { continue }
            index.results[message.id] = pairs.mapValues { replayed.history[$0].id }
        }
        index.historyRows = unloaded.count
        olderIndex = index
        // What loading every row brings with it, as `ensureFullHistory` does.
        pendingRequestLinks = replayed.pendingRequestLinks
        recentTaskPresentations = mergedTasks(replayed.recentTaskPresentations, shown: Set(replayed.visible.map(\.id)))
        return true
    }

    /// Runs a read over the shown rows. A row not where the replay found it
    /// loads every row instead, and the read runs again over them.
    func withShownRows<T>(_ body: (inout ShownRows) throws -> T) throws -> T {
        if let older = olderIndex, let journal {
            let file = try? FileHandle(forReadingFrom: journal.url)
            defer { try? file?.close() }
            var shown = ShownRows(older: older, base: 0, visible: visible, history: history, descriptor: file?.fileDescriptor)
            do { return try body(&shown) }
            catch is OlderRows.Unreadable { olderIndex = nil; try ensureFullHistory() }
        }
        var shown = ShownRows(older: nil, base: olderRows, visible: visible, history: history, descriptor: nil)
        return try body(&shown)
    }

    /// A row of the whole history, loaded or not.
    func retainedMessage(_ id: String) throws -> ChatMessage? {
        if let message = history.first(where: { $0.id == id }) { return message }
        guard partialHistory else { return nil }
        try loadOlderRows()
        return try withShownRows { try $0.message(id) }
    }

    /// A shown row as the transcript draws it. A row this chat did not load
    /// pairs its tool calls with their results as a chat holding every row
    /// pairs them.
    func displayShown(_ message: ChatMessage, _ shown: inout ShownRows) throws -> JSON {
        guard let older = shown.older, shown.isOlder(message.id) else { return displayMessage(message) }
        var results: [String: ChatMessage] = [:]
        for (call, id) in older.results[message.id] ?? [:] { results[call] = try shown.message(id) }
        return displayMessage(message, results: results)
    }
}
