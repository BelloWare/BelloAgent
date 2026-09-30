import Foundation

// The replay of a chat's journal as written (`durable`), kept apart from the
// live state a run keeps: rows streamed and not yet written, a task the open
// marked interrupted, a compaction's cleared failure. A fork's state and
// metadata file are made from it, as a replay of the fork's journal makes
// them.

extension AgentSession {
    /// The most a fork takes this chat's kept replay on by; past it, the fork
    /// starts from the chat's metadata file (`forkBase`).
    static let forkCatchUpLimit: UInt64 = 8 << 20

    /// The replay a fork of this chat starts from, at the journal's end: the
    /// kept one, taken on, when that is little to read. Otherwise the replay
    /// resumed from the chat's metadata file, as the chat's reopen would
    /// make it, taken on through the records after it: the fork then costs
    /// what a reopen does, whatever the journal's size. It is kept.
    func forkBase() throws -> JournalReplayConsumer? {
        guard let journal, !journal.writeOutcomeUncertain else { return nil }
        let behind = journal.size - min(journal.size, durable?.r.coveredBytes ?? 0)
        if behind <= Self.forkCatchUpLimit { return try durableReplay() }
        guard let stored = JournalCheckpoint.read(for: journal.url), stored.sessionID == id,
              stored.header == journal.headerCheck, stored.marker == journal.markerCheck, stored.start <= journal.size,
              let file = try? FileHandle(forReadingFrom: journal.url) else { return try durableReplay() }
        let last = JournalCheckpoint.verified(stored.last, in: file); try? file.close()
        guard let last, (try? JSON.parse(last))?["id"].text == stored.lastID, let loaded = Self.loadCheckpoint(stored, url: journal.url) else { return try durableReplay() }
        var consumer = JournalReplayConsumer(id: id, header: journal.headerCheck, marker: journal.markerCheck, spendTracked: spendTracked)
        consumer.resume(from: stored, loaded: loaded)
        let reader = try journal.recordReader(from: stored.start)
        while true {
            let start = reader.completeBytes
            guard let line = try reader.nextLine() else { break }
            if line.isEmpty { continue }
            // A checkpoint an edit or a context record follows does not hold, as for a reopen.
            if let fields = JournalLineScan.fields(line), fields.type == "branch" || fields.customType == JournalRecordKind.context { return try durableReplay() }
            try consumer.consume(line, at: start)
        }
        let old = durable
        durable = consumer
        Discarded.release(consume old)
        return consumer
    }

    /// The replay of this chat's journal as it is now: the open's replay, or
    /// the full one that loaded every row, taken on through the records
    /// written since. Nil when the journal's last write may not have happened
    /// as written, or there is none.
    func durableReplay() throws -> JournalReplayConsumer? {
        guard let journal, !journal.writeOutcomeUncertain else { return nil }
        var consumer: JournalReplayConsumer
        if let durable { consumer = durable }
        else { consumer = try Self.replayConsumer(journal, url: journal.url, id: id, binding: profile.binding, spendTracked: spendTracked, resume: false) }
        if consumer.r.coveredBytes < journal.size {
            let reader = try journal.recordReader(from: consumer.r.coveredBytes)
            while true {
                let start = reader.completeBytes
                guard let line = try reader.nextLine() else { break }
                if line.isEmpty { continue }
                try consumer.consume(line, at: start)
            }
        }
        durable = consumer
        return consumer
    }
}
