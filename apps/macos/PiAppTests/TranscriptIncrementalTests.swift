import XCTest
@testable import PiApp

final class TranscriptIncrementalTests: XCTestCase {
    @MainActor func testEnteringEstimatedHistoryPlacesNewlyMeasuredRows() throws {
        let session = SessionDisplay(id: "viewport-estimates")
        session.messages = TranscriptStressTestCase.history(turns: 500)
        let stage = TranscriptStressTestCase.Stage(session); defer { stage.close() }
        let row = stage.rows[stage.rows.count / 2]
        XCTAssertTrue(stage.document.isApproximate(row.itemID))
        stage.readerScroll(to: row.frame.minY)
        XCTAssertGreaterThan(stage.document.approximateRowCount, 100)
        XCTAssertFalse(stage.document.isApproximate(row.itemID))
        let exact = row.measure(width: row.frame.width).height
        XCTAssertEqual(row.frame.height, exact, accuracy: 0.5, "A reached row still has its estimated frame")
        if let following = stage.rows.dropFirst(row.layoutIndex + 1).first {
            XCTAssertEqual(following.frame.minY, row.frame.maxY, accuracy: 0.5)
        }
    }

    @MainActor func testAPartialPlacementKeepsUnresolvedHistorySliced() throws {
        let session = SessionDisplay(id: "partial-unresolved")
        var rows = TranscriptStressTestCase.history(turns: 500)
        let index = 31
        rows[index].state = "streaming"
        session.messages = rows
        let stage = TranscriptStressTestCase.Stage(session); defer { stage.close() }
        stage.page.presentationInterval = 0
        let estimated = stage.document.estimatedRowCount
        XCTAssertGreaterThan(estimated, 500)
        TranscriptLayoutClock.recording = true; TranscriptLayoutClock.reset()
        defer { TranscriptLayoutClock.recording = false }
        var live = rows[index]; live.text += " one more token"
        session.replaceMessage(at: index, with: live)
        stage.refresh()
        XCTAssertLessThan(TranscriptLayoutClock.measuredRows, 50, "A local change measured unresolved history below it")
        XCTAssertGreaterThan(stage.document.estimatedRowCount, estimated / 2, "Unseen history must retain its estimates")
    }

    func testNestedMessageEditsLeaveTheSourceSnapshotUntouched() {
        let source = TranscriptMessage(id: "source", role: "assistant", text: "Original",
                                       tools: [.init(id: "call", name: "read", state: "preparing", input: "{", output: "", truncated: false)],
                                       agentNumbers: ["child": 1], responseTimeline: ResponseTimeline())
        var next = source
        next.id = "next"; next.text = "Edited"; next.tools?[0].input = "{}"
        next.agentNumbers?["child"] = 2; next.responseTimeline?.coverage = "changed"
        XCTAssertEqual(source.id, "source"); XCTAssertEqual(source.text, "Original")
        XCTAssertEqual(source.tools?.first?.input, "{")
        XCTAssertEqual(source.agentNumbers?["child"], 1)
        XCTAssertNotEqual(source.responseTimeline?.coverage, "changed")
    }

    func testMessageSnapshotsKeepValueSemanticsAndTheirFlatWireShape() async throws {
        var source = TranscriptMessage(id: "source", role: "assistant", text: "Original", thinking: "Reason",
                                       tools: [.init(id: "call", name: "read", state: "preparing", input: "{", output: "", truncated: false)],
                                       agentNumbers: ["child": 1], responseTimeline: ResponseTimeline())
        source.responseTimeline?.coverage = "prefix"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(source)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptMessage.self, from: bytes), source)
        let wire = try JSONDecoder().decode(WireValue.self, from: bytes)
        XCTAssertEqual(wire.object?["id"]?.string, source.id)
        XCTAssertEqual(wire.object?["text"]?.string, source.text)
        XCTAssertNil(wire.object?["storage"])
        XCTAssertNil(wire.object?["fields"])
        let original = source
        let forks = await withTaskGroup(of: TranscriptMessage.self, returning: [TranscriptMessage].self) { group in
            for index in 0..<20 {
                group.addTask {
                    var next = original
                    next.id = "fork-\(index)"; next.text += " \(index)"
                    next.tools?[0].input += "\(index)"
                    next.agentNumbers?["child"] = index + 2
                    next.responseTimeline?.coverage = "fork-\(index)"
                    return next
                }
            }
            var rows: [TranscriptMessage] = []
            for await next in group { rows.append(next) }
            return rows
        }
        XCTAssertEqual(Set(forks.map(\.id)).count, 20)
        XCTAssertTrue(forks.allSatisfy { $0.tools?.first?.input != "{" && $0.responseTimeline?.coverage != "prefix" })
        XCTAssertEqual(source, original)
        XCTAssertEqual(try encoder.encode(source), bytes)
        var array = [source]
        array[0].tools?[0].output = "Nested array edit"
        XCTAssertEqual(source.tools?.first?.output, "")
        XCTAssertEqual(source.agentNumbers?["child"], 1)
    }

    @MainActor func testARevisionOnlyTaskPresentationTouchesNoNativeRows() throws {
        let session = SessionDisplay(id: "revision-only")
        let task = TaskPresentationRecord(rootID: "q", executionID: "run", startedAt: 1)
        session.messages = TranscriptStressTestCase.history(turns: 1_500) + [.init(id: "q", role: "user", text: "Continue")]
        func lifecycle(_ revision: Int) -> TaskPresentationProjection {
            .init(sessionID: session.id, epoch: "e", timeline: "t", sequence: revision,
                  sourceRevision: "\(revision)", active: task, recent: [])
        }
        session.taskPresentation = lifecycle(1)
        let page = TranscriptPage(); page.presentationInterval = 0; page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        document.update(snapshot: page.snapshot, actions: .init(), environment: .init())
        let visits = document.rowReconciliationVisits
        session.taskPresentation = lifecycle(2)
        var next = page.snapshot
        if testEnvironment("PI_STREAM_MUTATION") == "empty" { next?.changes = nil }
        document.update(snapshot: next, actions: .init(), environment: .init())
        XCTAssertEqual(page.snapshot?.lifecycle?.sequence, 2)
        XCTAssertEqual(document.rowReconciliationVisits, visits, "An unchanged plan must not visit native history")
    }

    @MainActor func testNewPartsAndTaskReceiptsMatchTheWholePlannerInBothDisplayModes() throws {
        let display = TranscriptDisplay.mode; defer { TranscriptDisplay.use(display) }
        for mode in [TranscriptDisplayMode.normal, .compact] {
            TranscriptDisplay.use(mode)
            let session = SessionDisplay(id: "parts-\(mode.rawValue)")
            var task = TaskPresentationRecord(rootID: "q", executionID: "run", startedAt: 1)
            task.phase = "model"; task.replies = 1
            var live = TranscriptMessage(id: "live", role: "assistant", text: "", state: "streaming", taskRootID: "q", taskExecutionID: "run")
            var timeline = ResponseTimeline(); live.responseTimeline = timeline
            session.messages = TranscriptStressTestCase.history(turns: 20) + [.init(id: "q", role: "user", text: "Continue"), live]
            session.taskPresentation = TaskPresentationProjection(sessionID: session.id, epoch: "e", timeline: "t", sequence: 1,
                                                                  sourceRevision: "1", active: task, recent: [])
            let page = TranscriptPage(); page.presentationInterval = 0; page.bind(session)
            let document = TranscriptNativeDocument(page: page)
            document.update(snapshot: page.snapshot, actions: .init(), environment: .init(), disclosure: session.disclosure)
            let boundary = try XCTUnwrap(document.retainedRows.firstIndex { $0.itemID == "q" })
            let prefix = document.retainedRows.prefix(boundary).map(ObjectIdentifier.init)
            var sequence = 1
            func check(_ label: String, ended: Bool = false) throws {
                sequence += 1; live.responseTimeline = timeline
                let lifecycle = TaskPresentationProjection(sessionID: session.id, epoch: "e", timeline: "t", sequence: sequence,
                                                           sourceRevision: "\(sequence)", active: ended ? nil : task, recent: ended ? [task] : [])
                session.beginTranscriptBatch(); session.taskPresentation = lifecycle
                session.replaceMessage(at: session.messages.count - 1, with: live); session.endTranscriptBatch()
                XCTAssertEqual(page.snapshot?.items, TranscriptActivity.blocks(of: session.presentedMessages, lifecycle: lifecycle), "\(mode): \(label)")
                XCTAssertEqual(page.snapshot?.liveTurn, TaskTranscriptPlan.live(lifecycle, messages: session.presentedMessages), "\(mode): \(label)")
                document.update(snapshot: page.snapshot, actions: .init(), environment: .init(), disclosure: session.disclosure)
                XCTAssertEqual(document.retainedRows.prefix(boundary).map(ObjectIdentifier.init), prefix)
            }
            task.assistantID = live.id; task.lastSourceID = live.id
            timeline.consume(.init(attemptID: "attempt", ordinal: 0, itemID: "answer", kind: "text", update: "append", text: "Answer"))
            live.text = "Answer"; try check("first prose")
            timeline.consume(.init(attemptID: "attempt", ordinal: 1, itemID: "reason", kind: "reasoningText", update: "append", text: "Why"))
            live.thinking = "Why"; try check("a new reasoning part")
            timeline.consume(.init(attemptID: "attempt", ordinal: 2, itemID: "call", kind: "toolArguments", update: "append", text: "{", callID: "call", name: "read"))
            live.tools = [.init(id: "call", name: "read", state: "preparing", input: "{", output: "", truncated: false)]
            task.preparingCalls = 1; try check("a new call")
            timeline.consume(.init(attemptID: "attempt", ordinal: 2, itemID: "call", kind: "toolArguments", update: "append", text: "\"path\":\"file\"}", callID: "call", name: "read"))
            live.tools?[0].input = "{\"path\":\"file\"}"; try check("arguments")
            live.tools?[0].state = "running"; task.phase = "tools"; task.currentTool = "read"; task.preparingCalls = 0; task.issuedCalls = 1
            try check("the call starts")
            live.tools?[0].state = "completed"; live.tools?[0].output = "contents"; live.state = "complete"
            timeline.finish("completed"); task.outcome = "completed"; task.phase = "terminal"; task.endedAt = 10; task.currentTool = nil
            try check("the receipt and fold", ended: true)
        }
    }

    @MainActor func testTailRemovalKeepsDisclosuresOwnedByThePrefix() throws {
        let first = TranscriptMessage(id: "first", role: "assistant", text: "", tools: [.init(id: "shared", name: "read", state: "completed", input: "{}", output: "one", truncated: false)])
        var second = first; second.id = "second"
        let items = TaskTranscriptPlan.rows([first, second], lifecycle: nil)
        let boundary = try XCTUnwrap(items.firstIndex { $0.messageIDs.contains(second.id) })
        let disclosure = TranscriptDisclosure()
        let firstKey = ToolOccurrence.key(first.id, "shared"), secondKey = ToolOccurrence.key(second.id, "shared")
        for key in ["shared", firstKey, secondKey] { disclosure.setOpen(true, .tool(key)) }
        var changes = TranscriptChanges()
        var snapshot = TranscriptPage.Snapshot(sessionID: "pruning", messages: [first, second], items: items, fresh: [], sequence: 1, changes: changes)
        let document = TranscriptNativeDocument(page: TranscriptPage())
        document.update(snapshot: snapshot, actions: .init(), environment: .init(), disclosure: disclosure)
        changes.recordTail(from: boundary)
        snapshot.messages = [first]; snapshot.items = Array(items.prefix(boundary)); snapshot.sequence += 1; snapshot.changes = changes
        document.update(snapshot: snapshot, actions: .init(), environment: .init(), disclosure: disclosure)
        XCTAssertTrue(disclosure.isOpen(.tool("shared")))
        XCTAssertTrue(disclosure.isOpen(.tool(firstKey)))
        XCTAssertFalse(disclosure.changedIDs.contains(secondKey))
    }

    func testAFragmentKeepsAnAlreadyHeldWindowButDoesNotBypassANewBudgetCrossing() throws {
        let rows = (0..<21).map { TranscriptMessage(id: "m\($0)", role: "assistant", text: "Token", state: "streaming") }
        let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        let bytes = rows.reduce(0) { $0 + TranscriptPaging.size($1) }
        var live = rows[20]; live.text += " continues"
        let delta: WireValue = .object(["appends": .array([.object(["id": .string(live.id), "text": .string(" continues")])])])
        func prepare(rows cap: Int, bytes limit: Int, held: Set<String>) -> TranscriptStreamUpdate? {
            TranscriptStreamUpdate.prepare(delta: delta, projected: [live], displayed: rows, positions: positions, bytes: bytes,
                                           revision: UUID(), accounting: [:], accountingRevision: 0, caps: (cap, limit), held: held)
        }
        let kept = try XCTUnwrap(prepare(rows: 10, bytes: bytes, held: ["m0"]))
        XCTAssertEqual(kept.rows.count, rows.count)
        XCTAssertEqual(kept.rows.last?.text, live.text)
        XCTAssertEqual(kept.held, ["m0"])
        XCTAssertNil(prepare(rows: 10, bytes: bytes, held: []), "A released window goes through trimming")
        XCTAssertNil(prepare(rows: 21, bytes: bytes, held: ["m0"]), "Crossing a byte cap still decides which rows the selection needs")
    }

    @MainActor func testALiveTurnsFiguresAndSourceStayCurrentAcrossFragments() throws {
        let session = SessionDisplay(id: "live-summary")
        var task = TaskPresentationRecord(rootID: "q", executionID: "run", startedAt: 1)
        task.replies = 1
        session.taskPresentation = TaskPresentationProjection(sessionID: session.id, epoch: "e", timeline: "t", sequence: 1,
                                                              sourceRevision: "1", active: task, recent: [])
        session.messages = [TranscriptMessage(id: "q", role: "user", text: "Question"),
                            TranscriptMessage(id: "a", role: "assistant", text: "Answer", state: "streaming", taskRootID: "q", taskExecutionID: "run")]
        let page = TranscriptPage()
        page.presentationInterval = 0; page.bind(session)
        var row = session.messages[1]; row.text += " continues"
        session.replaceMessage(at: 1, with: row)
        XCTAssertEqual(page.snapshot?.liveTurn, TaskTranscriptPlan.live(session.taskPresentation, messages: session.presentedMessages))
        XCTAssertEqual(page.snapshot?.liveTurn?.requests.last?.text, row.text)
    }

    @MainActor func testASkippedPresentationUpdatesBothChangedRowsWithoutVisitingHistory() throws {
        let session = SessionDisplay(id: "skipped")
        session.messages = (0..<3_000).map { index in
            TranscriptMessage(id: "m\(index)", role: "assistant", text: "Row \(index)", state: "streaming")
        }
        let page = TranscriptPage()
        page.presentationInterval = 0; page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        document.update(snapshot: page.snapshot, actions: .init(), environment: .init())
        let visits = document.rowReconciliationVisits
        for index in [500, 2_500] {
            var row = session.messages[index]; row.text += " continued"
            session.replaceMessage(at: index, with: row)
        }
        document.update(snapshot: page.snapshot, actions: .init(), environment: .init())
        for index in [500, 2_500] {
            let row = try XCTUnwrap(document.row(drawing: "m\(index)"))
            XCTAssertTrue(row.contentItem.messageIDs.contains("m\(index)"))
            XCTAssertEqual(row.contentItem, page.snapshot?.items.first { $0.id == row.itemID })
        }
        XCTAssertLessThanOrEqual(document.rowReconciliationVisits - visits, 4)
    }

    @MainActor func testAProjectionStateChangeAndAFragmentKeepAllDecorations() throws {
        let session = SessionDisplay(id: "decorations")
        session.messages = [TranscriptMessage(id: "q", role: "user", text: "Question"),
                            TranscriptMessage(id: "a", role: "assistant", text: "Answer", state: "streaming")]
        session.retryNotice = "Retrying"
        session.failureMessage = "Failed"
        session.sendFailure = "Could not send"
        _ = session.presentedMessages
        var row = session.messages[1]; row.text += " continues"
        session.replaceMessage(at: 1, with: row)
        XCTAssertEqual(session.presentedMessages.map(\.id), ["q", "a", "notice:retry:decorations", "failure:run:decorations"])
        XCTAssertEqual(session.presentedMessages[1].text, row.text)
        session.failureMessage = nil
        XCTAssertEqual(session.presentedMessages.last?.id, "failure:send:decorations")
        session.historyState = .loading
        XCTAssertTrue(session.presentedMessages.isEmpty)
        session.refreshingCachedRows = true
        XCTAssertEqual(session.presentedMessages[1].text, row.text)
    }

    func testAnExpiredOrDifferentRowOrderFallsBackToReconciliation() {
        var changes = TranscriptChanges()
        let original = changes
        for index in 0..<65 { changes.record([index]) }
        XCTAssertNil(changes.indices(since: original))
        XCTAssertNil(changes.indices(since: TranscriptChanges()))
        let recent = changes
        changes.record([3]); changes.record([7, 3])
        XCTAssertEqual(changes.indices(since: recent), [3, 7])
    }
}
