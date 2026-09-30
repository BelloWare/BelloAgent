import Foundation

// A fork that opens from its metadata file holds only its latest rows, so it
// is ready at once. It then loads the rest of its history in the background
// (`startHistoryFill`): its journal is replayed off the actor, the rows are
// made off the actor too, and the chat takes them in one step when it is
// idle. Sends, stops and everything else a chat does never wait for it; a
// load that is cancelled or fails leaves a chat that holds its latest rows,
// as any chat opened from its metadata file does.

extension AgentSession {
    /// The load under way, if any: its token, its replay's task, and once
    /// that is done, the replay.
    struct HistoryFill {
        let token: Int
        let task: Task<JournalReplayConsumer, Error>
        var replay: JournalReplayConsumer?
        /// The whole history being made from the replay, off the actor.
        var preparation: Task<Result<(FullHistory, JournalReplayConsumer), Error>, Never>?
    }

    /// Starts loading the rest of this chat's history in the background, if
    /// it holds only its latest rows.
    public func startHistoryFill() {
        guard partialHistory, !closed, historyFill == nil, let journal, !journal.writeOutcomeUncertain,
              let header = journal.headerCheck, let identity = journal.fileIdentity else { return }
        historyFillTokens &+= 1
        let token = historyFillTokens, url = journal.url, size = journal.size, id = self.id, marker = journal.markerCheck, hold = historyFillHold
        let task = Task.detached(priority: .utility) { () throws -> JournalReplayConsumer in
            if let hold { await hold("replay") }
            return try Self.replayPrefix(url: url, identity: identity, through: size, id: id, header: header, marker: marker)
        }
        historyFill = HistoryFill(token: token, task: task)
        // Detached, so what the load made and the chat does not take is let
        // go of here, not on the actor.
        Task.detached { [weak self] in
            let outcome = await task.result
            await self?.historyFillReplayed(token: token, outcome)
        }
    }

    /// Stops the load under way; what it made is not taken.
    public func cancelHistoryFill() {
        guard let fill = historyFill else { return }
        historyFill = nil
        fill.task.cancel(); fill.preparation?.cancel()
        Discarded.release(consume fill)
    }

    /// The journal's first `size` bytes replayed (from `start`'s end when
    /// given), from the file this chat writes, checked by its identity:
    /// records before `size` never change, whatever is written after it.
    static func replayPrefix(url: URL, identity: (device: UInt64, inode: UInt64), through size: UInt64, id: String,
                             header: JournalCheckpoint.Check, marker: JournalCheckpoint.Check?, from start: JournalReplayConsumer? = nil) throws -> JournalReplayConsumer {
        var consumer = start ?? JournalReplayConsumer(id: id, header: header, marker: marker, spendTracked: false)
        let reader = try start.map { try JournalRecordReader(url, startingAt: $0.r.coveredBytes) } ?? JournalRecordReader(url)
        guard reader.device == identity.device, reader.inode == identity.inode, reader.size >= size else {
            throw AgentError("session_damaged", "The journal changed while its history loaded")
        }
        if start == nil { _ = try reader.next(); consumer.starts(at: reader.completeBytes) }
        while reader.completeBytes < size {
            try Task.checkCancellation()
            let lineStart = reader.completeBytes
            guard let line = try reader.nextLine(), reader.completeBytes <= size else { throw AgentError("session_damaged", "The journal changed while its history loaded") }
            if line.isEmpty { continue }
            try consumer.consume(line, at: lineStart)
        }
        return consumer
    }

    func historyFillReplayed(token: Int, _ outcome: Result<JournalReplayConsumer, Error>) {
        guard var fill = historyFill, fill.token == token else { return }
        guard case .success(let replay) = outcome else { historyFill = nil; return }
        fill.replay = replay; historyFill = fill
        adoptHistoryFillIfIdle()
    }

    /// When the chat is idle, makes its whole history off the actor from the
    /// load's replay, taken on through the records written since, and takes
    /// it (`commitHistoryFill`). A run going defers it to the run's end.
    func adoptHistoryFillIfIdle() {
        guard var fill = historyFill, let replay = fill.replay, fill.preparation == nil, runTask == nil, partialHistory, !closed, let journal,
              let identity = journal.fileIdentity, let header = journal.headerCheck else { return }
        let token = fill.token, size = journal.size, generation = displayGeneration, url = journal.url
        let live = history, liveTasks = recentTaskPresentations, loaded = visible.map(\.id), older = olderRows, lineage = presentationTimeline
        let marker = journal.markerCheck, id = self.id, hold = historyFillHold
        let preparation = Task.detached(priority: .utility) { () -> Result<(FullHistory, JournalReplayConsumer), Error> in
                if let hold { await hold("prepare") }
                return Result {
                    let whole = try Self.replayPrefix(url: url, identity: identity, through: size, id: id, header: header, marker: marker, from: replay)
                    try Task.checkCancellation()
                    let replayed = try whole.finished()
                    try Task.checkCancellation()
                    // The rows the chat holds are the replay's last shown ones,
                    // after the rows it did not load, on the timeline it names.
                    let before = replayed.visible.count - loaded.count
                    guard before == older, zip(replayed.visible[before...], loaded).allSatisfy({ $0.id == $1 }),
                          (replayed.visible.last(where: { $0.kind == "branch" })?.id ?? "root") == lineage,
                          Set(replayed.history.map(\.id)).isSuperset(of: live.map(\.id)) else {
                        throw AgentError("history_changed", "The journal's history does not end in the rows the chat holds")
                    }
                    let full = Self.fullHistory(replayed, live: live, liveTasks: liveTasks)
                    try Task.checkCancellation()
                    return (full, whole)
                }
        }
        fill.preparation = preparation; fill.replay = nil; historyFill = fill
        Task.detached { [weak self] in
            let made = await preparation.value
            await self?.commitHistoryFill(token: token, generation: generation, size: size, made)
        }
    }

    /// Takes the whole history made for the load `token`, if the chat is as
    /// it was when it was made: no row changed, no record written, no run.
    /// Otherwise it is made again when the chat is next idle.
    func commitHistoryFill(token: Int, generation: UInt64, size: UInt64, _ made: Result<(FullHistory, JournalReplayConsumer), Error>) {
        // What is not taken here is let go of by the caller, off the actor.
        guard var fill = historyFill, fill.token == token else { return }
        fill.preparation = nil; historyFill = fill
        guard case .success(let (full, replay)) = made else { historyFill = nil; return }
        guard partialHistory, !closed, runTask == nil, let journal, journal.size == size, displayGeneration == generation else {
            // Made again from the replay, taken on, when the chat is next idle.
            fill.replay = replay; historyFill = fill
            adoptHistoryFillIfIdle()
            return
        }
        commitFullHistory(full, through: size)
        durable = replay
        event("history.loaded")
    }
}
