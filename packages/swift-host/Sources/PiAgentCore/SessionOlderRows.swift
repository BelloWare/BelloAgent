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

/// A value handed to another thread: whoever takes it out owns it, and the
/// box left behind holds nothing.
final class Handoff<Value>: @unchecked Sendable {
    private var value: Value?
    init(_ value: consuming Value) { self.value = value }
    func take() -> Value? { let taken = value; value = nil; return taken }
}

/// The journal file a replay reads, as the system and its checks know it:
/// a replay goes on only over the file it read.
struct JournalSource: Sendable, Equatable {
    let device: UInt64, inode: UInt64
    let header: JournalCheckpoint.Check, marker: JournalCheckpoint.Check?
    init?(_ journal: SessionJournal) {
        guard let identity = journal.fileIdentity, let header = journal.headerCheck else { return nil }
        device = identity.device; inode = identity.inode; self.header = header; marker = journal.markerCheck
    }
}

/// A replay of a journal's first `covered` bytes, for a load to take on to
/// the journal's end: it goes to the worker in a box it empties, so the
/// actor holds no reference to it after.
struct ReplayResume: Sendable {
    let replay: Handoff<JournalReplayConsumer>
    let source: JournalSource, covered: UInt64
    init(_ replay: consuming JournalReplayConsumer, source: JournalSource) {
        covered = replay.r.coveredBytes; self.replay = Handoff(replay); self.source = source
    }
    /// Whether it can be taken on to the end of `journal` as it is now.
    func reads(_ journal: SessionJournal) -> Bool { JournalSource(journal) == source && covered <= journal.size }
}

/// Anything large (a whole history, a replay of every row) handed to another
/// thread to be let go of there: letting go of every row takes a while, and
/// the actor has others waiting on it. The caller hands it over (`consume`),
/// holding no other reference, so the last one is let go of there.
final class Discarded: @unchecked Sendable {
    private var value: Any?
    private init(_ value: consuming Any) { self.value = value }
    static func release(_ value: consuming Any?) {
        guard let value else { return }
        let box = Discarded(value)
        DispatchQueue.global(qos: .utility).async { box.value = nil; malloc_zone_pressure_relief(nil, 0) }
    }
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
    /// Edits and versions need every retained row. Their requests share one
    /// load, including the fork's background replay or preparation when it
    /// is already running. Replay and row construction stay off the actor;
    /// a changed journal or live row requires a fresh snapshot before adoption.
    func loadFullHistory() async throws {
        try throwIfClosed()
        guard partialHistory else { return }
        if let pending = fullHistoryLoad { historyLoadJoins += 1; return try await closedWins(pending) }
        let load = Task { try await self.loadFullHistoryOnce() }
        fullHistoryLoad = load
        defer { fullHistoryLoad = nil; adoptHistoryFillIfIdle() }
        try await closedWins(load)
    }

    /// Waits for a load; a close or an unload meanwhile ends the wait with
    /// `session_closed`, whatever the load ended with.
    private func closedWins(_ load: Task<Void, Error>) async throws {
        do { try await load.value } catch { try throwIfClosed(); throw error }
        try throwIfClosed()
    }

    private func loadFullHistoryOnce() async throws {
        // A try the chat overtook leaves its replay for the next one.
        var resume: ReplayResume?
        defer { Discarded.release(resume?.replay.take()) }
        for _ in 0..<8 {
            try throwIfClosed()
            guard partialHistory else { return }
            if let fill = historyFill, let preparation = fill.preparation, let snapshot = fill.preparationSnapshot {
                let made = await preparation.value
                guard !closed else { Discarded.release(consume made); try throwIfClosed(); return }
                guard partialHistory else { Discarded.release(consume made); return }
                guard journal?.size == snapshot.size, fill.reads(journal), displayGeneration == snapshot.generation else {
                    // Retire the preparation through its ordinary completion
                    // path; the replay remains available for the next snapshot.
                    if historyFill?.token == fill.token {
                        commitHistoryFill(token: fill.token, generation: snapshot.generation, size: snapshot.size, consume made)
                    } else { Discarded.release(consume made) }
                    continue
                }
                switch consume made {
                case .failure(let error): throw error
                case let .success((full, replay)):
                    commitFullHistory(full, through: snapshot.size); durable = replay
                    event("history.loaded")
                    return
                }
            }
            let start = try await resumedReplay(&resume), replay = start.replay, source = start.source
            guard !closed else { Discarded.release(replay.take()); try throwIfClosed(); return }
            guard partialHistory, let journal else { Discarded.release(replay.take()); return }
            // A replay of another file than the journal's now: a fresh one.
            guard start.reads(journal) else { Discarded.release(replay.take()); continue }
            let size = journal.size, generation = displayGeneration, url = journal.url, id = self.id
            let live = history, liveTasks = recentTaskPresentations, hold = historyFillHold, reads = historyReads
            let made = await Self.offActor(priority: .userInitiated) { () -> Result<(FullHistory, JournalReplayConsumer), Error> in
                if let hold { await hold("full") }
                return Result {
                    guard let start = replay.take() else { throw AgentError("history_changed", "The replay was already taken") }
                    let whole = try Self.replayPrefix(url: url, source: source, through: size, id: id, from: start, reads: reads)
                    try Task.checkCancellation()
                    let full = Self.fullHistory(try whole.finished(), live: live, liveTasks: liveTasks)
                    try Task.checkCancellation()
                    return (full, whole)
                }
            }
            guard !closed else { Discarded.release(consume made); try throwIfClosed(); return }
            guard partialHistory else { Discarded.release(consume made); return }
            let current = self.journal.map { $0.size == size && JournalSource($0) == source } == true && displayGeneration == generation
            switch consume made {
            case .failure(let error):
                if current { throw error }
            case let .success((full, replay)):
                if current {
                    commitFullHistory(full, through: size); durable = replay
                    event("history.loaded")
                    return
                }
                // The next try goes on from this replay.
                Discarded.release(consume full)
                resume = ReplayResume(replay, source: source)
            }
        }
        throw AgentError("history_changed", "The conversation kept changing while its history loaded. Try again.")
    }

    /// The replay a load's try starts from: the last try's, taken on from
    /// where it stopped, while the journal is still the file it read; else
    /// the whole journal's (`wholeJournalReplay`).
    func resumedReplay(_ resume: inout ReplayResume?) async throws -> ReplayResume {
        if let carried = resume.take() {
            if let journal, carried.reads(journal) { return carried }
            Discarded.release(carried.replay.take())
        }
        return try await wholeJournalReplay()
    }

    /// A row this chat did not load, from its record, as a replay leaves it.
    static func storedRow(_ span: JournalCheckpoint.Row, descriptor: Int32) -> ChatMessage? {
        guard let bytes = JournalCheckpoint.rowBytes(span, descriptor: descriptor), var message = journalRow(span, bytes: bytes) else { return nil }
        _ = endWithoutReceipt(&message)
        return message
    }

    /// Learns where the rows this chat did not load are (`olderIndex`), once,
    /// without holding the actor: the whole journal's replay is the
    /// background load's when there is one (`startHistoryFill`), else one
    /// made now off the actor; the index is made off the actor from what the
    /// chat holds, and taken only if the chat is still as it was (else made
    /// again). A replay that does not end in the rows this chat holds loads
    /// every row instead, as before, also off the actor.
    func loadOlderRows() async throws {
        try throwIfClosed()
        // One load at a time: reads that come meanwhile wait for it.
        if let pending = olderRowsLoad { historyLoadJoins += 1; return try await closedWins(pending) }
        let load = Task { try await self.loadOlderRowsOnce() }
        olderRowsLoad = load
        defer { olderRowsLoad = nil }
        try await closedWins(load)
    }
    private func loadOlderRowsOnce() async throws {
        // A try the chat overtook leaves its replay for the next one.
        var resume: ReplayResume?
        defer { Discarded.release(resume?.replay.take()) }
        for _ in 0..<8 {
            try throwIfClosed()
            guard partialHistory, olderIndex == nil, journal != nil else { return }
            let start = try await resumedReplay(&resume), replay = start.replay, source = start.source
            guard !closed else { Discarded.release(replay.take()); try throwIfClosed(); return }
            guard partialHistory, olderIndex == nil, let journal else { Discarded.release(replay.take()); return }
            // A replay of another file than the journal's now: a fresh one.
            guard start.reads(journal) else { Discarded.release(replay.take()); continue }
            let size = journal.size, generation = displayGeneration, url = journal.url, id = self.id
            let loadedVisible = visible.map(\.id), loadedHistory = Set(history.map(\.id)), historyCount = history.count, older = olderRows
            let live = history, liveTasks = recentTaskPresentations, hold = historyFillHold, reads = historyReads
            let made = await Self.offActor(priority: .userInitiated) { () -> Result<OlderRowsMade, Error> in
                if let hold { await hold("index") }
                return Result {
                    guard let start = replay.take() else { throw AgentError("history_changed", "The replay was already taken") }
                    let whole = try Self.replayPrefix(url: url, source: source, through: size, id: id, from: start, reads: reads)
                    try Task.checkCancellation()
                    let replayed = try whole.finished()
                    try Task.checkCancellation()
                    if let index = try Self.olderRows(replayed, url: url, loadedVisible: loadedVisible, loadedHistory: loadedHistory, historyCount: historyCount, older: older) {
                        return .index(index, replayed.pendingRequestLinks, replayed.recentTaskPresentations, Set(replayed.visible.map(\.id)), whole)
                    }
                    try Task.checkCancellation()
                    return .whole(Self.fullHistory(replayed, live: live, liveTasks: liveTasks), whole)
                }
            }
            guard !closed else { Discarded.release(consume made); try throwIfClosed(); return }
            guard partialHistory, olderIndex == nil else { Discarded.release(consume made); return }
            let current = self.journal.map { $0.size == size && JournalSource($0) == source } == true
            switch consume made {
            case .failure(let error):
                if current { throw error }
            case let .success(.index(index, links, tasks, shown, whole)):
                // The index names where the rows before the ones held are:
                // it holds while those rows and the journal are as they were,
                // whatever is streamed meanwhile.
                if current, visible.count == loadedVisible.count, history.count == historyCount,
                   visible.first?.id == loadedVisible.first, visible.last?.id == loadedVisible.last {
                    olderIndex = index
                    // What loading every row brings with it, as a full load does.
                    pendingRequestLinks = links
                    recentTaskPresentations = mergedTasks(tasks, shown: shown)
                    Discarded.release(consume shown); Discarded.release(consume whole)
                    return
                }
                Discarded.release(consume index); Discarded.release(consume links); Discarded.release(consume shown)
                resume = ReplayResume(whole, source: source)
            case let .success(.whole(full, replay)):
                // Every row, with the live versions of those held: only if none changed.
                if current, displayGeneration == generation {
                    commitFullHistory(full, through: size); durable = replay
                    return
                }
                Discarded.release(consume full)
                resume = ReplayResume(replay, source: source)
            }
        }
        throw AgentError("history_changed", "The conversation kept changing while its older rows loaded. Try again.")
    }
    /// What `loadOlderRows` makes off the actor, with the replay it took to
    /// the journal's end, for a next try if the chat overtook this one.
    enum OlderRowsMade: Sendable {
        case index(OlderRows, [String: [String]], [TaskPresentationRecord], Set<String>, JournalReplayConsumer)
        case whole(FullHistory, JournalReplayConsumer)
    }

    /// Where the rows a chat holding `loadedVisible` and `loadedHistory` did
    /// not load are, from a replay of its whole journal; nil when the replay
    /// does not end in those rows.
    static func olderRows(_ replayed: JournalReplay, url: URL, loadedVisible: [String], loadedHistory: Set<String>, historyCount: Int, older: Int) throws -> OlderRows? {
        let shown = replayed.visible.count - loadedVisible.count
        guard shown == older, zip(replayed.visible[shown...], loadedVisible).allSatisfy({ $0.id == $1 }) else { return nil }
        let unloaded = replayed.history.filter { !loadedHistory.contains($0.id) }
        guard replayed.history.count - unloaded.count == historyCount, let file = try? FileHandle(forReadingFrom: url) else { return nil }
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
        try Task.checkCancellation()
        let same = inParallel(checked.count) { storedRow(checked[$0].span, descriptor: descriptor) == checked[$0].message }
        try Task.checkCancellation()
        for (row, same) in zip(checked, same) where same != true { index.kept[row.message.id] = row.message }
        let tools = ToolHistoryIndex(replayed.history)
        for message in unloaded where message.role == "assistant" {
            guard let pairs = tools.results[message.id] else { continue }
            index.results[message.id] = pairs.mapValues { replayed.history[$0].id }
        }
        index.historyRows = unloaded.count
        return index
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
    func retainedMessage(_ id: String) async throws -> ChatMessage? {
        if let message = history.first(where: { $0.id == id }) { return message }
        guard partialHistory else { return nil }
        try await loadOlderRows()
        if let message = history.first(where: { $0.id == id }) { return message }
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
