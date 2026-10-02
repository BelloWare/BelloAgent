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
        /// The journal file its replay reads.
        let source: JournalSource
        var replay: JournalReplayConsumer?
        /// The whole history being made from the replay, off the actor.
        var preparation: Task<Result<(FullHistory, JournalReplayConsumer), Error>, Never>?
        var preparationSnapshot: (generation: UInt64, size: UInt64)?
        /// Whether its replay is of `journal`'s file.
        func reads(_ journal: SessionJournal?) -> Bool { journal.flatMap(JournalSource.init) == source }
    }

    /// Starts loading the rest of this chat's history in the background, if
    /// it holds only its latest rows.
    public func startHistoryFill() {
        guard partialHistory, !closed, historyFill == nil, let journal, !journal.writeOutcomeUncertain,
              let source = JournalSource(journal) else { return }
        historyFillTokens &+= 1
        let token = historyFillTokens, url = journal.url, size = journal.size, id = self.id, hold = historyFillHold, reads = historyReads
        let task = Task.detached(priority: .utility) { () throws -> JournalReplayConsumer in
            if let hold { await hold("replay") }
            return try Self.replayPrefix(url: url, source: source, through: size, id: id, reads: reads)
        }
        historyFill = HistoryFill(token: token, task: task, source: source)
        // Detached, so what the load made and the chat does not take is let
        // go of here, not on the actor.
        Task.detached { [weak self] in
            let outcome = await task.result
            await self?.historyFillReplayed(token: token, outcome)
        }
    }

    /// The replay of the whole journal, or of as much of it as a load under
    /// way read, made off the actor: the background load's when there is
    /// one, else one made now. The caller takes it on to the journal's end.
    func wholeJournalReplay() async throws -> ReplayResume {
        try throwIfClosed()
        if let fill = historyFill {
            if fill.reads(journal) {
                if let replay = fill.replay { return ReplayResume(replay, source: fill.source) }
                let replay = try? await fill.task.value
                try throwIfClosed()
                if let replay, historyFill?.token == fill.token, fill.reads(journal) { return ReplayResume(replay, source: fill.source) }
            }
            // A load of another file than the journal's now goes; a fresh
            // replay reads the journal as it is.
            if let current = historyFill, current.token == fill.token, !current.reads(journal) { cancelHistoryFill() }
        }
        guard let journal, let source = JournalSource(journal) else {
            throw AgentError("session_unavailable", "The conversation is not open")
        }
        let url = journal.url, size = journal.size, id = self.id, hold = historyFillHold, reads = historyReads
        let made = await Self.offActor(priority: .userInitiated) { () -> Result<JournalReplayConsumer, Error> in
            if let hold { await hold("replay") }
            return Result { try Self.replayPrefix(url: url, source: source, through: size, id: id, reads: reads) }
        }
        guard !closed else { Discarded.release(consume made); throw AgentError.sessionClosed }
        return ReplayResume(try made.get(), source: source)
    }

    /// `work` on a task of its own, off the actor, stopped when the caller
    /// is: a load that a close or an unload stops stops its worker too.
    static func offActor<T: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func throwIfClosed() throws {
        if closed { throw AgentError.sessionClosed }
    }

    /// Stops every load of this chat's rows under way: the background one,
    /// a load of its older rows, and a load of every row. A command waiting
    /// on one gets `session_closed`. For a close and an unload.
    func cancelHistoryLoads() {
        cancelHistoryFill()
        olderRowsLoad?.cancel(); fullHistoryLoad?.cancel()
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
    static func replayPrefix(url: URL, source: JournalSource, through size: UInt64, id: String, from start: JournalReplayConsumer? = nil,
                             reads: ((UInt64) -> Void)? = nil) throws -> JournalReplayConsumer {
        try Task.checkCancellation()
        let identity = (device: source.device, inode: source.inode), header = source.header, marker = source.marker
        var consumer = start ?? JournalReplayConsumer(id: id, header: header, marker: marker, spendTracked: false)
        let from = start?.r.coveredBytes ?? 0
        let reader = try JournalRecordReader(url, startingAt: from)
        reads?(from)
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
        guard fullHistoryLoad == nil, var fill = historyFill, let replay = fill.replay, fill.preparation == nil, runTask == nil, partialHistory, !closed, let journal else { return }
        // A replay of another file than the journal's now is not taken on.
        guard fill.reads(journal) else { cancelHistoryFill(); return }
        let source = fill.source, reads = historyReads
        let token = fill.token, size = journal.size, generation = displayGeneration, url = journal.url
        let live = history, liveTasks = recentTaskPresentations, loaded = visible.map(\.id), older = olderRows, lineage = presentationTimeline
        let id = self.id, hold = historyFillHold
        let preparation = Task.detached(priority: .utility) { () -> Result<(FullHistory, JournalReplayConsumer), Error> in
                if let hold { await hold("prepare") }
                return Result {
                    let whole = try Self.replayPrefix(url: url, source: source, through: size, id: id, from: replay, reads: reads)
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
        fill.preparation = preparation; fill.preparationSnapshot = (generation, size); fill.replay = nil; historyFill = fill
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
        fill.preparation = nil; fill.preparationSnapshot = nil; historyFill = fill
        guard case .success(let (full, replay)) = made else { historyFill = nil; return }
        guard partialHistory, !closed, runTask == nil, let journal, journal.size == size, fill.reads(journal), displayGeneration == generation else {
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

extension AgentError {
    /// A command on a chat closed or unloaded while it waited.
    static var sessionClosed: AgentError { AgentError("session_closed", "The conversation is closed") }
}
