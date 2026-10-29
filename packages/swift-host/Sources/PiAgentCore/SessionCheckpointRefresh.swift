import Foundation

struct CheckpointRefreshPolicy: Sendable {
    var bytes: UInt64 = 8 << 20
    var seconds: Double = 60
    var replayBytes: UInt64 = 64 << 20
    var batchBytes: UInt64 = 32 << 20
    var metadataBytes = 8 << 20
    var rows = 32_768
}

extension AgentSession {
    /// Called after the settled run-state write has flushed. Scheduling is
    /// constant work; replay, metadata construction and staging run apart
    /// from the session actor. Only one snapshot is in flight per runtime.
    func scheduleCheckpointRefresh() {
        guard !closed, !ephemeral, runTask == nil, partialID == nil, !partialReplyUnsaved,
              !journaledCommandsUncertain, requestPermits.isEmpty,
              let journal, !journal.writeOutcomeUncertain, let source = JournalSource(journal), let durable else { return }
        let through = journal.size, now = checkpointRefreshClock()
        let previous = max(checkpointPublishedThrough, checkpointRefreshAttemptedThrough)
        guard through > previous,
              through - previous >= checkpointRefreshPolicy.bytes || now - checkpointRefreshAttemptedAt >= checkpointRefreshPolicy.seconds,
              checkpointRefreshTask == nil else { return }
        let token = UUID(), policy = checkpointRefreshPolicy, url = journal.url
        checkpointRefreshToken = token; checkpointRefreshAttemptedThrough = through; checkpointRefreshAttemptedAt = now
        checkpointRefreshTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let made = try await Self.prepareCheckpointRefresh(durable, source: source, url: url, through: through, policy: policy)
                await self?.publishCheckpointRefresh(token: token, source: source, through: through, replay: made.replay,
                    checkpoint: made.checkpoint, temporary: made.temporary)
                if let temporary = made.temporary { try? FileManager.default.removeItem(at: temporary) }
            } catch { /* A cache failure cannot fail the durable turn. */ }
            await self?.checkpointRefreshFinished(token: token)
        }
    }

    private static func prepareCheckpointRefresh(_ start: JournalReplayConsumer, source: JournalSource, url: URL,
                                                through: UInt64, policy: CheckpointRefreshPolicy) async throws
        -> (replay: JournalReplayConsumer, checkpoint: JournalCheckpoint?, temporary: URL?) {
        var replay = start
        let reader = try JournalRecordReader(url, startingAt: replay.r.coveredBytes)
        guard reader.device == source.device, reader.inode == source.inode, reader.size >= through else {
            throw AgentError("history_changed", "The checkpoint's journal changed")
        }
        var yieldedAt = reader.completeBytes
        while reader.completeBytes < through {
            try Task.checkCancellation()
            let offset = reader.completeBytes
            guard let line = try reader.nextLine(), reader.completeBytes <= through else {
                throw AgentError("history_changed", "The checkpoint's durable prefix changed")
            }
            if !line.isEmpty { try replay.consume(line, at: offset) }
            if reader.completeBytes - yieldedAt >= policy.batchBytes {
                yieldedAt = reader.completeBytes; await Task.yield()
            }
        }
        try Task.checkCancellation()
        replay.retarget(marker: source.marker)
        // An unsafe or oversized prefix is still useful as a kept replay,
        // but must not replace the previous on-disk checkpoint.
        let checkpoint = try? replay.captureSettledCheckpoint(policy: policy)
        guard let checkpoint else { return (replay, nil, nil) }
        try Task.checkCancellation()
        let temporary = try checkpoint.stage(for: url, maximumBytes: policy.metadataBytes)
        return (replay, checkpoint, temporary)
    }

    private func publishCheckpointRefresh(token: UUID, source: JournalSource, through: UInt64,
                                          replay: JournalReplayConsumer, checkpoint: JournalCheckpoint?, temporary: URL?) {
        guard checkpointRefreshToken == token, !Task.isCancelled, !closed, let journal, !journal.writeOutcomeUncertain,
              JournalSource(journal) == source, journal.size >= through else { return }
        if (durable?.r.coveredBytes ?? 0) <= replay.r.coveredBytes {
            let old = durable; durable = replay; Discarded.release(consume old)
        }
        guard let checkpoint, let temporary, checkpoint.start > checkpointPublishedThrough else { return }
        do {
            try beforeCheckpointReplacement?()
            try JournalCheckpoint.publish(staged: temporary, for: journal.url)
            checkpointPublishedThrough = checkpoint.start
        } catch { /* Atomic replacement leaves the previous cache intact. */ }
    }

    private func checkpointRefreshFinished(token: UUID) {
        guard checkpointRefreshToken == token else { return }
        checkpointRefreshTask = nil
        // A turn that settled during this work is coalesced into the next
        // bounded prefix. Active runs wait for their own durable settlement.
        scheduleCheckpointRefresh()
    }

    func stopCheckpointRefresh() async {
        guard let task = checkpointRefreshTask else { return }
        checkpointRefreshToken = UUID()
        task.cancel(); await task.value
        checkpointRefreshTask = nil
    }
}
