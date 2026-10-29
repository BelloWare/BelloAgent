import XCTest
@testable import PiAgentCore

/// A refreshed checkpoint must preserve the meaning of every settled prefix,
/// both from a cold journal and from the older context-boundary shortcut.
final class CheckpointRefreshParityTests: HelperTestCase {
    func testGeneratedSettledPrefixesMatchColdAndContextAnchoredReopens() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at:root) }
        let files = try await CheckpointParityCorpus.generate(in:root)
        var prefixes = 0, refreshed = 0, refused = 0, comparisons = 0
        var kinds = Set<String>()
        for file in files {
            let records = try Data(contentsOf:file).split(separator:10).map { Data($0) }
            let header = try JSON.parse(try XCTUnwrap(records.first)), id = try XCTUnwrap(header["id"].text)
            let copy = root.appendingPathComponent("prefix.jsonl")
            var bytes = Data()
            for (index,line) in records.enumerated() {
                bytes.append(line); bytes.append(10)
                let row = try JSON.parse(line)
                kinds.insert(row["customType"].text ?? row["type"].text ?? "")
                guard row["customType"].text == JournalRecordKind.state, row["data"]["active"].flag == false else { continue }
                prefixes += 1
                try bytes.write(to:copy); JournalCheckpoint.remove(for:copy)
                let cold = try reopen(copy, id:id), expected = try cold.finished()
                let old = try cold.capturedCheckpoint()
                let previous = try old.map { try reopen(copy, id:id, checkpoint:$0) }
                if let previous {
                    try assertSame(try previous.finished(), expected, id:id, name:"old / \(file.lastPathComponent):\(index)")
                    comparisons += 1
                }
                var fromCold = cold
                let direct = try fromCold.captureSettledCheckpoint(policy:CheckpointRefreshPolicy())
                var captures: [(String,JournalCheckpoint)] = []
                if let direct { captures.append(("cold refresh",direct)) }
                var snapshot = cold.settledCheckpointSnapshot(policy:CheckpointRefreshPolicy())
                let bounded = try snapshot?.captureSettledCheckpoint(policy:CheckpointRefreshPolicy())
                XCTAssertEqual(direct != nil, bounded != nil, "Freezing bounded rows cannot change eligibility")
                if let bounded { captures.append(("cold worker snapshot",bounded)) }
                if var fromOld = previous {
                    let advanced = try fromOld.captureSettledCheckpoint(policy:CheckpointRefreshPolicy())
                    XCTAssertEqual(direct != nil, advanced != nil, "Eligibility cannot depend on the starting checkpoint")
                    if let advanced { captures.append(("old refresh",advanced)) }
                    var snapshot = fromOld.settledCheckpointSnapshot(policy:CheckpointRefreshPolicy())
                    let bounded = try snapshot?.captureSettledCheckpoint(policy:CheckpointRefreshPolicy())
                    XCTAssertEqual(advanced != nil, bounded != nil)
                    if let bounded { captures.append(("old worker snapshot",bounded)) }
                }
                guard !captures.isEmpty else { refused += 1; continue }
                refreshed += 1
                for (label,checkpoint) in captures {
                    XCTAssertEqual(checkpoint.lineage, expected.visible.last(where:{ $0.kind == "branch" })?.id,
                                   "Lineage belongs to the whole visible timeline: \(label), \(index)")
                    let result = try reopen(copy, id:id, checkpoint:checkpoint).finished()
                    try assertSame(result, expected, id:id, name:"\(label) / \(file.lastPathComponent):\(index)")
                    comparisons += 1
                    if let previous {
                        try assertSame(result, try previous.finished(), id:id, name:"\(label) versus old checkpoint", complete:false)
                        comparisons += 1
                    }
                }
            }
        }
        let required = ["branch","compaction",JournalRecordKind.context,JournalRecordKind.taskTerminal,
            JournalRecordKind.agentCutPrepared,JournalRecordKind.agentCutCommitted,JournalRecordKind.agentOperation,
            JournalRecordKind.agentTerminal,JournalRecordKind.agentMessage,JournalRecordKind.agentDelivery,
            JournalRecordKind.sideOrigin,JournalRecordKind.forkOrigin,JournalRecordKind.rebind,
            JournalRecordKind.cutinMarker,JournalRecordKind.cost,JournalRecordKind.budgetAttempt]
        XCTAssertTrue(Set(required).isSubset(of:kinds), "Missing corpus kinds: \(Set(required).subtracting(kinds))")
        XCTAssertGreaterThan(refreshed, 40); XCTAssertGreaterThan(refused, 0)
        print("CHECKPOINT_PARITY generator=3 variants=4 journals=\(files.count) settledPrefixes=\(prefixes) refreshed=\(refreshed) unsafeRefused=\(refused) comparisons=\(comparisons)")
    }

    /// Open a real writer against the exact prefix, validate the cache, load
    /// its rows, then replay its suffix through the production opening path.
    private func reopen(_ url: URL, id: String, checkpoint: JournalCheckpoint? = nil) throws -> JournalReplayConsumer {
        if let checkpoint { try checkpoint.write(for:url) } else { JournalCheckpoint.remove(for:url) }
        let journal = try SessionJournal(url:url, id:id, cwd:url.deletingLastPathComponent(), binding:nil,
            create:false, checkpoint:checkpoint)
        if let checkpoint { XCTAssertEqual(journal.resumedFrom?.start, checkpoint.start, "Must use, not silently discard, the checkpoint") }
        return try AgentSession.replayConsumer(journal, url:url, id:id, binding:.null, spendTracked:false, resume:checkpoint != nil)
    }

    private func assertSame(_ value: JournalReplay, _ reference: JournalReplay, id: String, name: String,
                            complete: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        // Checkpoint rows are a lazy suffix. Check its exact offset and every
        // loaded row against the full timeline, not just its last message.
        if complete {
            XCTAssertEqual(value.olderRows + value.visible.count, reference.visible.count, name + ": rowsBefore", file:file,line:line)
            XCTAssertEqual(value.visible, Array(reference.visible.dropFirst(value.olderRows)), name + ": visible", file:file,line:line)
        } else {
            XCTAssertEqual(value.olderRows + value.visible.count, reference.olderRows + reference.visible.count, name + ": total rows", file:file,line:line)
            let start = max(value.olderRows, reference.olderRows)
            XCTAssertEqual(Array(value.visible.dropFirst(start-value.olderRows)), Array(reference.visible.dropFirst(start-reference.olderRows)), name + ": visible suffix", file:file,line:line)
        }
        XCTAssertEqual(value.context, reference.context, name + ": context", file:file,line:line)
        let next = ChatMessage(role:"user", content:[textBlock("Next generated request")])
        func request(_ replay: JournalReplay) throws -> Data {
            try ProviderClient.requestBody(profile:fixtureProfile(), messages:replay.context + [next], instructions:"Generated corpus",
                tools:[], sessionID:id).data()
        }
        XCTAssertEqual(try request(value), try request(reference), name + ": next request bytes", file:file,line:line)
        XCTAssertEqual(value.versions.ledger, reference.versions.ledger, name + ": versions", file:file,line:line)
        XCTAssertEqual(value.spend, reference.spend, name + ": spend", file:file,line:line)
        XCTAssertEqual(value.spendTracked, reference.spendTracked, name + ": spend coverage", file:file,line:line)
        XCTAssertEqual(value.accounting, reference.accounting, name + ": accounting", file:file,line:line)
        XCTAssertEqual(value.subagents, reference.subagents, name + ": family, mail, cuts", file:file,line:line)
        XCTAssertEqual(value.stateRecord, reference.stateRecord, name + ": run state and receipts", file:file,line:line)
        XCTAssertEqual(value.parentInfo, reference.parentInfo, name + ": origin", file:file,line:line)
        XCTAssertEqual(value.recentTaskPresentations, reference.recentTaskPresentations, name + ": tasks", file:file,line:line)
        XCTAssertEqual(value.assistantMessageCount, reference.assistantMessageCount, name + ": reply count", file:file,line:line)
        XCTAssertEqual(value.latestAssistantMessageID, reference.latestAssistantMessageID, name + ": latest reply", file:file,line:line)
        XCTAssertEqual(value.compactionState, reference.compactionState, name + ": compaction", file:file,line:line)
        XCTAssertEqual(value.contextRecovery, reference.contextRecovery, name + ": recovery", file:file,line:line)
        XCTAssertEqual(value.failedCompactionFingerprint, reference.failedCompactionFingerprint, name + ": failed compaction", file:file,line:line)
        XCTAssertEqual(value.presentationOrdinal, reference.presentationOrdinal, name + ": presentation ordinal", file:file,line:line)
        XCTAssertEqual(value.coveredBytes, reference.coveredBytes, name + ": prefix", file:file,line:line)
    }
}
