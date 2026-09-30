import Foundation

// The replay of a chat's journal as written (`durable`), kept apart from the
// live state a run keeps: rows streamed and not yet written, a task the open
// marked interrupted, a compaction's cleared failure. A fork's state and
// metadata file are made from it, as a replay of the fork's journal makes
// them.

extension AgentSession {
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
