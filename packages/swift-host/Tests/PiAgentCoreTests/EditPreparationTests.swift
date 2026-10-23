import XCTest
@testable import PiAgentCore

final class EditPreparationTests: HelperTestCase {
    private func fullReplay(_ session: AgentSession, path: URL) async throws -> JournalReplay {
        let source = await session.editPreparationIndex?.source, size = await session.journalSizeForTesting
        return try AgentSession.replayPrefix(url: path, source: XCTUnwrap(source), through: XCTUnwrap(size), id: "edit-index").finished()
    }
    private func assertContext(_ actual: [ChatMessage], _ expected: [ChatMessage], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.role, b.role, file: file, line: line)
            XCTAssertEqual(a.content, b.content, file: file, line: line)
            XCTAssertEqual(a.providerItems, b.providerItems, file: file, line: line)
            XCTAssertEqual(a.providerIdentity ?? .null, b.providerIdentity ?? .null, file: file, line: line)
            XCTAssertEqual(a.providerBinding ?? .null, b.providerBinding ?? .null, file: file, line: line)
            XCTAssertEqual(a.compaction ?? .null, b.compaction ?? .null, file: file, line: line)
            XCTAssertEqual(a.contextNote, b.contextNote, file: file, line: line)
            XCTAssertEqual(a.userInput, b.userInput, file: file, line: line)
        }
    }
    private func generated(_ seed: Int) throws -> [JSON] {
        var records: [JSON] = [], replay = try ConversationReplay()
        func append(_ value: JSON, _ id: String) throws {
            var record = value; record["id"] = JSON(id)
            try replay.consume(record); records.append(record)
        }
        for round in 0..<3 {
            for turn in 0..<7 {
                let id = "s\(seed)-r\(round)-t\(turn)"
                try append(["type":"message", "message":["role":"user", "content":JSON("expanded \(id)"),
                    "nativeDisplayText":JSON("question \(id) 漢字🌍"), "nativeUserInput":["version":1,"attachments":[["path":"missing-fixture-image","sha256":"fixture"]],"skills":[["name":"fixture","arguments":"kept"]]]]], id)
                if (turn + seed) % 3 == 0 {
                    try append(["type":"message", "message":["role":"assistant", "content":[["type":"toolCall","id":"reused","name":"fixture","arguments":[:]]]]], id + "-call")
                    try append(["type":"message", "message":["role":"toolResult","toolCallId":"reused","content":"fixture result"]], id + "-result")
                }
                try append(["type":"message", "message":["role":"assistant", "content":JSON("reply \(id)")]], id + "-answer")
                if turn == 0 {
                    let progress = "progress-\(round)"
                    try append(["type":"message","message":["role":"system","nativeKind":"requestLedger","nativeReplayEligible":false,"content":"Working"]], progress)
                    try append(["type":"custom","customType":JSON(JournalRecordKind.presentationUpdate),"data":["id":JSON(progress)],
                        "message":["role":"system","nativeKind":"requestLedger","nativeReplayEligible":false,"content":"Completed request presentation"]], progress + "-update")
                }
            }
            if (round + seed) % 2 == 0 {
                let target = replay.visible.filter { $0.role == "user" }.dropLast(2).last!.id
                let plan = try AgentSession.planEdit(target, history: replay.history, visible: replay.visible, context: replay.context)
                let branch = HistoricalBranch(fromMessageId: target, keptIds: plan.replay, selectedTimelinePrefix: plan.displayPrefix, sourceTimelineDigest: plan.sourceTimeline)
                var record = try JSON.parse(JSONEncoder().encode(branch)); record["type"] = "branch"
                try append(record, "branch-\(round)")
                try append(["type":"message", "message":["role":"user", "content":"replacement"]], "replacement-\(round)")
                try append(["type":"message", "message":["role":"assistant", "content":"replacement reply"]], "replacement-answer-\(round)")
            }
            let active = replay.context.filter(\.replayEligible), start = active.lastIndex { $0.role == "user" }!
            let source = active.map(\.id), kept = Array(source[start...]), summarized = Array(source[..<start])
            try append(["type":"compaction", "summary":"Generated summary", "nativeKeptIDs":.array(kept.map { JSON($0) }), "nativeCompactionVersion":2,
                "nativeCompaction":["version":2,"sourceIDs":.array(source.map { JSON($0) }),"protectedIDs":[],"keptIDs":.array(kept.map { JSON($0) }),
                    "dependencyIDs":.array(summarized.map { JSON($0) }),"summarySourceIDs":.array(summarized.map { JSON($0) })]], "summary-\(round)")
        }
        // A fork/import selects its complete boundary and leaves a later
        // physical user record retained but outside the selected timeline.
        let boundary = replay.context.map(\.id)
        try append(["type":"message", "message":["role":"user","content":"physical tail"]], "unselected")
        let selected = EditReplayPlan.forkTimeline(visible: replay.visible.map(\.id), boundary: boundary)
        try append(["type":"custom","customType":JSON(JournalRecordKind.context),"data":["ids":.array(boundary.map { JSON($0) }),"visibleIDs":.array(selected.map { JSON($0) })]], "fork-boundary")
        return records
    }

    func testGeneratedBranchedCompactedAndImportedJournalsMatchFullReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<5 { repo.deleteLastPathComponent() }
        var cases = try (0..<6).map(generated)
        // Saved/imported context can carry a compaction as an ordinary
        // message, rather than its original compaction record.
        var imported = cases.last!
        let prior = try ConversationReplay(imported), sources = prior.context.map(\.id)
        imported.append(["type":"message","id":"carried-summary","message":["role":"system","content":"Inherited summary",
            "nativeKind":"compaction","nativeCompaction":["version":2,"sourceIDs":.array(sources.map { JSON($0) }),"protectedIDs":[],"keptIDs":[],
                "dependencyIDs":.array(sources.map { JSON($0) }),"summarySourceIDs":.array(sources.map { JSON($0) })]]])
        imported.append(["type":"custom","id":"imported-context","customType":JSON(JournalRecordKind.context),
            "data":["ids":["carried-summary"],"visibleIDs":.array((prior.visible.map(\.id) + ["carried-summary"]).map { JSON($0) })]])
        imported.append(["type":"message","id":"imported-user","message":["role":"user","content":[["type":"text","text":"Expanded legacy input"],["type":"image"]],"nativeDisplayText":"Imported display input"]])
        cases.append(imported)
        for suffix in ["before", "after"] {
            let bytes = try Data(contentsOf: repo.appendingPathComponent("fixtures/native/historical-edit-\(suffix).jsonl"))
            cases.append(try bytes.split(separator: 10).map { try JSON.parse(Data($0)) }.filter { $0["type"].text != "session" && !JournalRecordKind.isMarker($0["customType"].text) })
        }
        for (number, records) in cases.enumerated() {
            let path = root.appendingPathComponent("case-\(number).jsonl")
            do {
                let journal = try SessionJournal(url: path, id: "edit-index", cwd: root, binding: fixtureProfile().binding, create: true)
                for record in records { try journal.append(record.removing(["id", "parentId"]), id: identity(record["id"])) }
            }
            let whole = try open(root, path: path), history = await whole.history, visible = await whole.visible, context = await whole.context
            await whole.close()
            let cold = try open(root, path: path)
            let partial = await cold.partialHistory
            XCTAssertTrue(partial, "case \(number) exercises a metadata-file open")
            for message in history where message.role == "user" {
                let plan: HistoricalEditPlan
                do { plan = try AgentSession.planEdit(message.id, history: history, visible: visible, context: context) }
                catch {
                    do { _ = try await cold.prepareEdit(message.id); XCTFail("case \(number) accepted abandoned target \(message.id)") }
                    catch let error as AgentError { XCTAssertEqual(error.code, "edit_target") }
                    continue
                }
                let prepared = try await cold.prepareEdit(message.id)
                let indexed = await cold.editPreparationIndex
                let metadata = try XCTUnwrap(indexed)
                let fastPlan = try AgentSession.planEdit(message.id, history: metadata.replay.history, visible: metadata.replay.visible, context: metadata.replay.context)
                XCTAssertEqual(fastPlan, plan, "case \(number): the complete replay plan must match, not only its digests")
                let text = message.displayText ?? message.text
                XCTAssertEqual(prepared["sourceTimeline"].text, plan.sourceTimeline, "case \(number): \(message.id)")
                XCTAssertEqual(prepared["sourcePrefix"].text, plan.sourcePrefix)
                XCTAssertEqual(prepared["sourceTextDigest"].text, sha256(Data(text.utf8)))
                var loaded = prepared["text"].text ?? "", next = prepared["next"].int
                while let offset = next {
                    let page = try await cold.prepareEdit(message.id, offset: offset, expectedTimeline: prepared["sourceTimeline"].text, expectedTextDigest: prepared["sourceTextDigest"].text)
                    loaded += try XCTUnwrap(page["text"].text); next = page["next"].int
                }
                XCTAssertEqual(loaded, text)
                XCTAssertEqual(prepared["input"], message.userInput ?? .null)
                XCTAssertEqual(prepared["legacyInputs"].flag, message.userInput == nil && (message.displayText != nil && message.displayText != message.text || message.content.contains { $0["type"].text == "image" }))
            }
            await cold.close()
        }
    }

    func testColdRollbackLoadsRawInputsOrASafeSummaryAsTheFullReplayRequires() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let records = try generated(0), original = try ConversationReplay(records)
        let users = original.visible.filter { $0.role == "user" }
        for (number, target) in [users[1], users.last!].enumerated() {
            let path = root.appendingPathComponent("rollback-\(number).jsonl")
            do {
                let journal = try SessionJournal(url: path, id: "edit-index", cwd: root, binding: fixtureProfile().binding, create: true)
                for record in records { try journal.append(record.removing(["id", "parentId"]), id: identity(record["id"])) }
            }
            let whole = try open(root, path: path); await whole.close()
            let cold = try open(root, path: path, client: ScriptClient([answer("replacement reply")]))
            let input = try await cold.prepareEdit(target.id)
            _ = try await cold.edit(fromMessageID: target.id, input: Submission(commandID: "edit", turnID: "new-input", text: "replacement"),
                expectedTextDigest: input["sourceTextDigest"].text, expectedPrefix: input["sourcePrefix"].text)
            try await eventually { !(await cold.isRunning) }
            let full = try await fullReplay(cold, path: path)
            let context = await cold.context, partial = await cold.partialHistory
            let total = try await cold.historyWindow(["version":2])["total"].int
            assertContext(context, full.context)
            XCTAssertEqual(total, full.visible.count)
            XCTAssertTrue(partial)
            if number == 0 {
                let progress = await cold.visible.first { $0.id == "progress-0" }
                XCTAssertEqual(progress?.text, full.visible.first { $0.id == "progress-0" }?.text)
            }
            let version = try await cold.versionPage(["messageId":JSON(target.id)])
            XCTAssertEqual(version["messages"].list.first?["text"].text, target.displayText ?? target.text)
            await cold.close()
        }
    }

    func testColdForkRejectsReplacementIDsInUnloadedHistoryLikeFullReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("edit-index.jsonl")
        do {
            let journal = try SessionJournal(url: path, id: "edit-index", cwd: root, binding: fixtureProfile().binding, create: true)
            for record in try generated(0) { try journal.append(record.removing(["id", "parentId"]), id: identity(record["id"])) }
        }
        let whole = try open(root, path: path); await whole.close()
        let parent = try open(root, path: path)
        // A summarized user and reply, a replaced turn, and a retained row
        // outside the fork's selected timeline must all reserve their IDs.
        for (number, collision) in ["s0-r0-t0", "s0-r0-t0-answer", "s0-r0-t6", "unselected"].enumerated() {
            let id = "collision-fork-\(number)", fork = try await parent.fork(to: id)
            let forkPath = URL(fileURLWithPath: try XCTUnwrap(fork["path"].text))
            let input = Submission(commandID: "edit", turnID: collision, text: "replacement")
            let oracle = try open(root, path: forkPath, id: id)
            try await oracle.loadFullHistory()
            do { _ = try await oracle.edit(fromMessageID: "replacement-2", input: input); XCTFail("Full history accepted \(collision)") }
            catch let error as AgentError { XCTAssertEqual(error.code, "duplicate_turn") }
            await oracle.close()

            let cold = try open(root, path: forkPath, id: id)
            let held = await cold.history.map(\.id), receipts = await cold.commands, partial = await cold.partialHistory
            XCTAssertTrue(partial)
            XCTAssertTrue(receipts.isEmpty, "Forks do not inherit accepted-turn receipts")
            XCTAssertFalse(held.contains(collision), "The ID must be outside the checkpoint's resident rows")
            // Exercise both a direct Send and Send after cached preparation.
            if number % 2 == 0 { _ = try await cold.prepareEdit("replacement-2") }
            let before = try Data(contentsOf: forkPath), head = await cold.journal?.head
            do { _ = try await cold.edit(fromMessageID: "replacement-2", input: input); XCTFail("Cold history accepted \(collision)") }
            catch let error as AgentError { XCTAssertEqual(error.code, "duplicate_turn") }
            try await eventually { !(await cold.isRunning) }
            let afterHead = await cold.journal?.head, after = await cold.history.map(\.id), stillPartial = await cold.partialHistory
            let queued = await cold.queue.count, afterReceipts = await cold.commands, indexed = await cold.editPreparationIndex?.replay.history.map(\.id)
            XCTAssertTrue(try XCTUnwrap(indexed).contains(collision))
            XCTAssertEqual(try Data(contentsOf: forkPath), before, "A refused edit must write no branch or replacement")
            XCTAssertEqual(afterHead, head)
            XCTAssertEqual(after, held)
            XCTAssertEqual(afterReceipts, receipts)
            XCTAssertEqual(queued, 0)
            XCTAssertTrue(stillPartial, "Checking all IDs must not load full history")
            await cold.close()
        }
        await parent.close()
    }

    func testDamagedEarlierCheckpointsAreRefusedLikeFullReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for (number, needle) in [#""nativeBranchVersion":2"#, #""nativeCompactionVersion":2"#, #""sourceTimelineDigest":""#, #""arguments":"kept""#].enumerated() {
            let path = root.appendingPathComponent("damaged-\(number).jsonl")
            do {
                let journal = try SessionJournal(url: path, id: "edit-index", cwd: root, binding: fixtureProfile().binding, create: true)
                for record in try generated(0) { try journal.append(record.removing(["id", "parentId"]), id: identity(record["id"])) }
            }
            let whole = try open(root, path: path); await whole.close()
            var bytes = try Data(contentsOf: path)
            let range = try XCTUnwrap(bytes.range(of: Data(needle.utf8)))
            if number == 3 { bytes.replaceSubrange(range, with: Data(#""arguments":1e999 "#.utf8)) }
            else {
                let at = number == 2 ? range.upperBound : range.upperBound - 1
                bytes[at] = bytes[at] == 57 ? 56 : 57
            }
            try bytes.write(to: path)
            let cold = try open(root, path: path), partial = await cold.partialHistory
            XCTAssertTrue(partial, "The later intact checkpoint alone cannot validate earlier edit sources")
            var fullCode: String?
            do { try await cold.loadFullHistory(); XCTFail("Damaged full replay accepted") }
            catch let error as AgentError { fullCode = error.code }
            do { _ = try await cold.prepareEdit("replacement-2"); XCTFail("Damaged metadata replay accepted") }
            catch let error as AgentError { XCTAssertEqual(error.code, fullCode) }
            await cold.close()
        }
    }

    private func open(_ root: URL, path: URL, id: String = "edit-index", client: ScriptClient = ScriptClient([])) throws -> AgentSession {
        try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                         readOnly: true, resources: Resources(cwd: root, home: root), client: client,
                         tools: RecordingTools(), traces: TraceStore(), resumePath: path.path, autoCompaction: false)
    }

    /// A generated journal over 100 MiB, with large replies before a compacted
    /// boundary. A cold helper holds only its checkpoint's rows. Preparing an
    /// edit must leave it that way, and return the full replay's exact checks.
    func testLargeColdPreparationDoesNotLoadReplyBodiesAndMatchesFullReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("edit-index.jsonl"), profile = try fixtureProfile()
        do {
            let journal = try SessionJournal(url: path, id: "edit-index", cwd: root, binding: profile.binding, create: true)
            try journal.append(["type":"message","message":["role":"system","nativeKind":"requestLedger","nativeReplayEligible":false,"content":"Working"]], id: "presentation")
            try journal.append(["type":"custom","customType":JSON(JournalRecordKind.presentationUpdate),"data":["id":"presentation"],
                "message":["role":"system","nativeKind":"requestLedger","nativeReplayEligible":false,"content":JSON(String(repeating: "Provider presentation ", count: 12_000))]], id: "presentation-update")
            let reply = String(repeating: "generated reply ", count: 70_000)
            var ids: [String] = []
            for turn in 0..<105 {
                let user = "u\(turn)", assistant = "a\(turn)"
                try journal.append(["type":"message", "message":["role":"user", "content":JSON("question \(turn)")]], id: user)
                try journal.append(["type":"message", "message":["role":"assistant", "content":JSON(reply)]], id: assistant)
                ids += [user, assistant]
            }
            try journal.append(["type":"compaction", "summary":"Generated summary", "nativeKeptIDs":[], "nativeCompactionVersion":2,
                                "nativeCompaction":["version":2, "sourceIDs":.array(ids.map { JSON($0) }), "protectedIDs":[], "keptIDs":[],
                                                    "dependencyIDs":.array(ids.map { JSON($0) }), "summarySourceIDs":.array(ids.map { JSON($0) })]], id: "summary")
            try journal.append(["type":"message", "message":["role":"user", "content":"expanded skill input",
                "nativeDisplayText":"edited question 🌍", "nativeUserInput":["version":1,"attachments":[],"skills":[]]]], id: "target")
            try journal.append(["type":"message", "message":["role":"assistant", "content":"answer"]], id: "answer")
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber
        XCTAssertGreaterThan(try XCTUnwrap(bytes).intValue, 100 * 1024 * 1024)
        // The first open writes the rebuildable checkpoint and supplies the
        // independent oracle; the measured open below starts from that file.
        let whole = try open(root, path: path)
        let plan = try await AgentSession.planEdit("target", history: whole.history, visible: whole.visible, context: whole.context)
        await whole.close()
        let cold = try open(root, path: path, client: ScriptClient([answer("edited reply")]))
        let partial = await cold.partialHistory, held = await cold.history.map(\.id)
        XCTAssertTrue(partial)
        let clock = ContinuousClock(), start = clock.now
        let prepared = try await cold.prepareEdit("target")
        print("EDIT-PREPARE generated \(try XCTUnwrap(bytes).intValue) bytes: \(start.duration(to: clock.now))")
        XCTAssertEqual(prepared["sourceTimeline"].text, plan.sourceTimeline)
        XCTAssertEqual(prepared["sourcePrefix"].text, plan.sourcePrefix)
        XCTAssertEqual(prepared["sourceTextDigest"].text, sha256(Data("edited question 🌍".utf8)))
        XCTAssertEqual(prepared["text"].text, "edited question 🌍")
        XCTAssertEqual(prepared["input"]["version"].int, 1)
        let index = await cold.editPreparationIndex
        XCTAssertEqual(index?.replay.history.first { $0.id == "presentation" }?.text, "", "An edit index must not retain an old provider presentation body")
        let stillPartial = await cold.partialHistory, after = await cold.history.map(\.id)
        XCTAssertTrue(stillPartial, "Preparation must not replay and hydrate every old reply")
        XCTAssertEqual(after, held, "The read must leave the helper's retained rows alone")
        let sending = clock.now
        let accepted = try await cold.edit(fromMessageID: "target", input: Submission(commandID: "edit", turnID: "replacement", text: "replacement"),
            expectedTimeline: prepared["sourceTimeline"].text, expectedTextDigest: prepared["sourceTextDigest"].text, expectedPrefix: prepared["sourcePrefix"].text)
        print("EDIT-SEND generated \(try XCTUnwrap(bytes).intValue) bytes: \(sending.duration(to: clock.now))")
        XCTAssertEqual(accepted["accepted"].flag, true)
        try await eventually { !(await cold.isRunning) }
        let sparse = await cold.partialHistory, retained = await cold.history
        XCTAssertTrue(sparse, "Send must load the planned replay inputs, leaving older display rows lazy")
        XCTAssertFalse(retained.contains { $0.id == "a0" }, "A safe summary replaces these old replies in the model context")
        let oracle = try await fullReplay(cold, path: path)
        let actual = await cold.context
        assertContext(actual, oracle.context)
        let total = try await cold.historyWindow(["version":2])["total"].int
        XCTAssertEqual(total, oracle.visible.count)
        let fork = try await cold.fork(to: "edit-child")
        let child = try open(root, path: URL(fileURLWithPath: XCTUnwrap(fork["path"].text)), id: "edit-child")
        let childContext = await child.context
        assertContext(childContext, actual)
        await child.close()
        let stillSparse = await cold.partialHistory
        XCTAssertTrue(stillSparse, "A fork from the new checkpoint must not force the source's older display rows into memory")
        await cold.close()
        let reopened = try open(root, path: path)
        let reopenedContext = await reopened.context
        assertContext(reopenedContext, actual)
        let versions = try await reopened.messageVersions(["messageId":"replacement"])
        XCTAssertEqual(versions["count"].int, 2, "A subsequent full version read restores the original hidden input")
        await reopened.close()
    }
}
