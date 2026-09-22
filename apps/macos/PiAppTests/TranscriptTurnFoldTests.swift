import XCTest
import SwiftUI
@testable import PiApp

/// What a finished turn reads as, and what every work row reads as.
///
/// The fold is the end of a turn, not a state a reader watches happen: it
/// fires when the turn has stopped and has actually said something, it never
/// fires on a page that begins in the middle of a turn, and it hides nothing
/// the reader cannot get back with one click. The rows behind it keep their
/// identities and everything opened inside them.
final class TranscriptTurnFoldTests: XCTestCase {
    /// The planner's mode is app-wide, so every case that depends on it says
    /// which transcript it means and puts the process back as it found it.
    @MainActor private func withDisplay<T>(_ mode: TranscriptDisplayMode, _ body: () throws -> T) rethrows -> T {
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(mode)
        defer { TranscriptDisplay.use(previous) }
        return try body()
    }

    // MARK: A turn to fold

    /// A reply that thought, called a tool, and then answered.
    private func reply(id: String, turn: String, at: Double, text: String, thinking: String? = nil,
                       call: (id: String, name: String)? = nil, streaming: Bool = false) -> TranscriptMessage {
        var timeline = ResponseTimeline()
        var ordinal = 0
        func consume(_ kind: String, _ body: String, call: String? = nil, name: String? = nil) {
            timeline.consume(ResponsePartEvent(attemptID: "attempt-" + id, ordinal: ordinal, itemID: "\(id)-item-\(ordinal)",
                                               outputIndex: ordinal, partIndex: 0, kind: kind, update: "replace",
                                               text: body, callID: call, name: name))
            ordinal += 1
        }
        if let thinking { consume("reasoningText", thinking) }
        if let call { consume("toolArguments", "{\"path\":\"README.md\"}", call: call.id, name: call.name) }
        if !text.isEmpty { consume("text", text) }
        if !streaming { timeline.finish("completed") }
        var message = TranscriptMessage(id: id, role: "assistant", text: text, thinking: thinking,
                                        tools: call.map { [ToolView(id: $0.id, name: $0.name, state: "completed",
                                                                    input: "{\"path\":\"README.md\"}", output: "ok",
                                                                    durationMs: 120, truncated: false)] },
                                        state: streaming ? "streaming" : "complete", at: at, turn: turn)
        message.modelMs = 900
        message.responseTimeline = timeline
        return message
    }
    /// One turn: two tool-running replies and a final answer.
    private func turn(streaming: Bool = false) -> [TranscriptMessage] {
        [TranscriptMessage(id: "u1", role: "user", text: "Look at the retry loop.", at: 1_000, turn: "u1"),
         reply(id: "a1", turn: "u1", at: 2_000, text: "Reading the file first.", thinking: "Where does the retry live?",
               call: (id: "c1", name: "read")),
         reply(id: "a2", turn: "u1", at: 3_000, text: "", call: (id: "c2", name: "bash")),
         reply(id: "a3", turn: "u1", at: 4_000, text: "The loop retries three times.", streaming: streaming)]
    }
    private func control(_ items: [TranscriptItem]) -> TranscriptBlock? {
        for case .block(let block) in items where block.presentation == .turnFold { return block }
        return nil
    }
    private func groups(_ items: [TranscriptItem]) -> [String?] {
        items.map { item in
            switch item {
            case .message(let message): return message.foldGroup
            case .block(let block): return block.foldGroup
            }
        }
    }

    // MARK: The fold fires at the end of a turn, and only then

    @MainActor func testAFinishedTurnFoldsItsWorkBehindOneLineAboveItsAnswer() throws {
        let items = withDisplay(.compact) { TaskTranscriptPlan.items(turn(), lifecycle: nil) }
        let fold = try XCTUnwrap(control(items), "A finished turn with an answer has a fold")
        XCTAssertEqual(fold.foldSummary?.label, "2 tool calls · 1 message",
                       "The line counts the calls and the replies that spoke before the answer")
        XCTAssertEqual(fold.foldSummary?.answerResponseID, "a3")
        XCTAssertNil(fold.foldGroup, "The control is never hidden by the fold it controls")

        // The control stands where the turn's work starts, the answer's own
        // words stay visible, and the reader's message is never a member.
        let position = try XCTUnwrap(items.firstIndex { if case .block(let b) = $0 { return b.presentation == .turnFold }; return false })
        XCTAssertEqual(groups(items)[..<position].compactMap { $0 }, [], "Nothing before the control is folded")
        let answerProse = items.filter { item in
            if case .block(let block) = item, block.responseID == "a3", block.part?.part.kind == "text" { return true }
            return false
        }
        XCTAssertEqual(answerProse.count, 1)
        for item in answerProse { if case .block(let block) = item { XCTAssertNil(block.foldGroup, "The answer's words never fold") } }
        for case .message(let message) in items where message.role == "user" {
            XCTAssertNil(message.foldGroup, "The reader's own message never folds")
        }
        // Every card and every thought before the answer is a member.
        let folded = items.filter { item in
            if case .block(let block) = item { return block.foldGroup != nil }
            if case .message(let message) = item { return message.foldGroup != nil }
            return false
        }
        XCTAssertGreaterThanOrEqual(folded.count, 5, "The turn's work is behind the line")
    }

    @MainActor func testATurnStillRunningKeepsEveryRowItHas() throws {
        let streaming = withDisplay(.compact) { TaskTranscriptPlan.items(turn(streaming: true), lifecycle: nil) }
        XCTAssertNil(control(streaming), "Nothing folds while the answer is still arriving")
        XCTAssertEqual(groups(streaming).compactMap { $0 }, [])

        // And between two model requests of one turn every row is settled,
        // which is exactly when a fold would be wrong. The running task says so.
        var record = TaskPresentationRecord(rootID: "u1", executionID: "e1", startedAt: 1_000)
        record.phase = "tools"
        let projection = TaskPresentationProjection(sessionID: "s", epoch: "e", timeline: "root", sequence: 1,
                                                    sourceRevision: "e:1", active: record, recent: [])
        let midTurn = withDisplay(.compact) { TaskTranscriptPlan.items(turn(), lifecycle: projection) }
        XCTAssertNil(control(midTurn), "The task the host is running is the test, not whether a row is settled")
    }

    @MainActor func testATurnWithNoAnswerAndAPageThatStartsMidTurnNeverFold() throws {
        // A turn that only ran tools has nothing to fold behind.
        let toolsOnly = [turn()[0], turn()[2]]
        XCTAssertNil(control(withDisplay(.compact) { TaskTranscriptPlan.items(toolsOnly, lifecycle: nil) }),
                     "A turn that never answered keeps its work on screen")
        // A window that begins after the reader's message cannot know what it
        // would be hiding, so it hides nothing.
        let midPage = Array(turn().dropFirst())
        XCTAssertNil(control(withDisplay(.compact) { TaskTranscriptPlan.items(midPage, lifecycle: nil) }),
                     "An incomplete history never folds")
    }

    @MainActor func testTheNormalTranscriptLeavesEveryRowWhereItWas() throws {
        let normal = withDisplay(.normal) { TaskTranscriptPlan.items(turn(), lifecycle: nil) }
        let compact = withDisplay(.compact) { TaskTranscriptPlan.items(turn(), lifecycle: nil) }
        XCTAssertNil(control(normal))
        XCTAssertEqual(groups(normal).compactMap { $0 }, [])
        XCTAssertEqual(normal.count + 1, compact.count, "Compact adds exactly one row: the line")
        XCTAssertEqual(normal.map(\.id), compact.filter { $0.id != control(compact)?.key }.map(\.id),
                       "Folding changes what is drawn, never which rows exist")
    }

    func testTheLineCountsCallsRepliesAndSubagents() {
        XCTAssertEqual(TurnFoldSpec(group: "t", answerResponseID: "a", toolCalls: 3, messages: 1).label, "3 tool calls · 1 message")
        XCTAssertEqual(TurnFoldSpec(group: "t", answerResponseID: "a", subagents: 2).label, "2 subagents")
        XCTAssertEqual(TurnFoldSpec(group: "t", answerResponseID: "a", toolCalls: 1).label, "1 tool call")
        XCTAssertEqual(TurnFoldSpec(group: "t", answerResponseID: "a").label, "Thought for a while",
                       "A turn that only thought says so rather than counting nothing")
        XCTAssertTrue(TurnFoldSpec.isSubagent("subagent"))
        XCTAssertTrue(TurnFoldSpec.isSubagent("subagent_review"))
        XCTAssertFalse(TurnFoldSpec.isSubagent("send_message"))
    }

    @MainActor func testADelegatingTurnCountsItsSubagentsSeparately() throws {
        var rows = turn()
        rows[1].tools?[0].name = "subagent_review"
        let renamed = (rows[1].responseTimeline?.segments ?? []).map { segment -> ResponseTimeline.Segment in
            var copy = segment
            if copy.part.callID == "c1" { copy.part.name = "subagent_review" }
            return copy
        }
        rows[1].responseTimeline?.segments = renamed
        let fold = try XCTUnwrap(control(withDisplay(.compact) { TaskTranscriptPlan.items(rows, lifecycle: nil) }))
        XCTAssertEqual(fold.foldSummary?.label, "1 tool call · 1 message · 1 subagent")
    }

    // MARK: What the reader does with it

    @MainActor func testTheFoldIsClosedByDefaultAndSurvivesStreamingAndAChatSwitch() throws {
        let items = withDisplay(.compact) { TaskTranscriptPlan.items(turn(), lifecycle: nil) }
        let fold = try XCTUnwrap(control(items))
        let member = try XCTUnwrap(items.first { if case .block(let b) = $0 { return b.foldGroup != nil }; return false })
        let store = TranscriptDisclosure()
        // Closed is the default, and a page nobody has touched still draws it.
        XCTAssertEqual(store.changedCount, 0)
        XCTAssertTrue(TranscriptRowDisclosure.of(member, in: store).foldedAway)
        XCTAssertFalse(TranscriptRowDisclosure.of(.block(fold), in: store).turnFoldOpen)
        XCTAssertFalse(TranscriptRowDisclosure.of(.block(fold), in: store).foldedAway)

        var spanning = 0
        store.spanningChange = { spanning += 1 }
        store.toggle(.turnFold("u1"))
        XCTAssertEqual(spanning, 1, "Opening a turn republishes: every row of it reaches its height in one pass")
        XCTAssertFalse(TranscriptRowDisclosure.of(member, in: store).foldedAway)
        XCTAssertTrue(TranscriptRowDisclosure.of(.block(fold), in: store).turnFoldOpen)

        // Replanning the same conversation — a streamed delta, a chat switch
        // and back — keeps the reader's choice: it is keyed by the turn, not
        // by anything a republish rebuilds.
        let again = withDisplay(.compact) { TaskTranscriptPlan.items(turn(), lifecycle: nil) }
        let laterMember = try XCTUnwrap(again.first { if case .block(let b) = $0 { return b.foldGroup != nil }; return false })
        XCTAssertFalse(TranscriptRowDisclosure.of(laterMember, in: store).foldedAway, "The open turn stays open")
        XCTAssertTrue(store.isOpen(.turnFold("u1")))
        store.forget(["u1"])
        XCTAssertTrue(TranscriptRowDisclosure.of(laterMember, in: store).foldedAway, "A turn that leaves takes its entry with it")
    }

    func testEnterAndSpaceActivateAFocusedRowAndNothingElseDoes() {
        XCTAssertTrue(TranscriptRowChrome.activates(.return))
        XCTAssertTrue(TranscriptRowChrome.activates(.space))
        for key in [KeyEquivalent.tab, .escape, .downArrow, .leftArrow, "a"] {
            XCTAssertFalse(TranscriptRowChrome.activates(key), "\(key) belongs to the conversation, not to the row")
        }
    }

    // MARK: The setting

    @MainActor func testTheSavedChoiceDefaultsToCompactAndRejectsAnythingElse() throws {
        let old = try JSONEncoder().encode(VaultConfiguration())
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("transcriptView"),
                       "An untouched vault writes no field")
        XCTAssertEqual(try ConfigurationVault.decode(old).transcriptDisplay, .compact,
                       "A vault that predates the setting reads as compact")
        var configuration = VaultConfiguration()
        configuration.transcriptDisplay = .normal
        XCTAssertEqual(configuration.transcriptView, "normal")
        XCTAssertEqual(try JSONDecoder().decode(VaultConfiguration.self, from: JSONEncoder().encode(configuration)).transcriptDisplay, .normal)
        try configuration.validate(persisted: false)
        configuration.transcriptView = "tiny"
        XCTAssertThrowsError(try configuration.validate(persisted: false), "An unknown mode is not a mode")
        // A sheet that never touched the setting must not undo another writer's change.
        let baseline = VaultConfiguration()
        var concurrent = baseline; concurrent.transcriptDisplay = .normal
        XCTAssertEqual(ConnectionSettingsController.merging(baseline, from: baseline, onto: concurrent).transcriptDisplay, .normal)
        var edits = baseline; edits.transcriptDisplay = .normal
        XCTAssertEqual(ConnectionSettingsController.merging(edits, from: baseline, onto: baseline).transcriptDisplay, .normal)
    }

    // MARK: Geometry, in a window

    @MainActor private final class Fixture {
        let session: SessionDisplay
        let page: TranscriptPage
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow
        init(messages: [TranscriptMessage], width: CGFloat = 780, height: CGFloat = 560) {
            session = SessionDisplay(id: "fold")
            session.messages = messages
            page = TranscriptPage()
            page.state = "idle"
            page.bind(session)
            scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            document = TranscriptNativeDocument(page: page)
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            refresh()
        }
        var rows: [TranscriptRowContainer] { document.retainedRows }
        var controlRow: TranscriptRowContainer? {
            rows.first { if case .block(let block) = $0.item { return block.presentation == .turnFold }; return false }
        }
        var memberRows: [TranscriptRowContainer] {
            rows.filter { row in
                switch row.item {
                case .block(let block): return block.foldGroup != nil
                case .message(let message): return message.foldGroup != nil
                }
            }
        }
        func refresh() {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(),
                            environment: TranscriptRowEnvironment(), disclosure: session.disclosure)
            document.layoutRows(width: scroll.contentSize.width)
            document.finishDisclosureMotion()
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func close() { window.contentView = nil; window.close() }
    }

    @MainActor func testAFoldedTurnDrawsOneLineAndOpensIntoItsWholeSelf() throws {
        try withDisplay(.compact) {
            let fixture = Fixture(messages: turn()); defer { fixture.close() }
            let control = try XCTUnwrap(fixture.controlRow)
            let members = fixture.memberRows
            XCTAssertFalse(members.isEmpty)
            XCTAssertGreaterThan(control.frame.height, 20, "The line is a line")
            // A folded row draws nothing and takes up nothing — a message row
            // included, whose host drops the paragraph spacing it reserves
            // around every message rather than leaving fourteen points of
            // blank where the fold swallowed the row.
            for row in members {
                XCTAssertLessThan(row.frame.height, 2,
                                  "A folded row draws nothing: \(row.itemID) is \(row.frame.height)")
            }
            let foldedDocument = fixture.document.frame.height

            control.toggleDisclosure(.turnFold("u1"))
            fixture.session.publishTranscript()
            fixture.refresh()
            let openMembers = fixture.memberRows
            XCTAssertEqual(openMembers.count, members.count, "Opening a turn adds no rows and removes none")
            XCTAssertTrue(openMembers.allSatisfy { $0.frame.height > 0 }, "Every row of the turn is back")
            XCTAssertGreaterThan(openMembers.filter { $0.frame.height > 20 }.count, 2,
                                 "Its thoughts and its cards are drawn again")
            XCTAssertGreaterThan(fixture.document.frame.height, foldedDocument)

            control.toggleDisclosure(.turnFold("u1"))
            fixture.session.publishTranscript()
            fixture.refresh()
            XCTAssertEqual(fixture.document.frame.height, foldedDocument, accuracy: 1,
                           "Closing it again lands on the geometry it was folded at")
        }
    }

    /// A row's own fold is a motion the document drives; a turn's fold spans
    /// rows, so it republishes and lands in one pass. Both are checked here:
    /// the motion sampled at five ticks on the quicker tempo, and the spanning
    /// fold arriving at its geometry without a frame in between.
    @MainActor func testAFoldMovesOnTheQuickerTempoAndASpanningFoldLandsInOnePass() throws {
        XCTAssertEqual(TranscriptNativeDocument.disclosureMotionDuration, 0.16, accuracy: 0.001,
                       "A disclosure answers a click in 160 ms, not in 220")
        XCTAssertEqual(TranscriptRowChrome.chevronSeconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(TranscriptRowChrome.foldSeconds, 0.16, accuracy: 0.001)
        XCTAssertTrue(TranscriptDisclosure.Part.turnFold("u1").spansRows,
                      "A turn's fold moves every row of the turn, so the conversation republishes for it")
        XCTAssertFalse(TranscriptDisclosure.Part.tool("c1").spansRows)

        try withDisplay(.compact) {
            let fixture = Fixture(messages: turn()); defer { fixture.close() }
            let control = try XCTUnwrap(fixture.controlRow)
            let folded = fixture.document.frame.height
            control.toggleDisclosure(.turnFold("u1"))
            fixture.session.publishTranscript(); fixture.refresh()
            let open = fixture.document.frame.height
            XCTAssertGreaterThan(open, folded)
            XCTAssertFalse(fixture.document.isMovingDisclosure,
                           "A spanning fold is a republish, not a motion on one row")

            // One row inside the turn — a thought — folds as a motion the
            // document drives. Five ticks: the rows stay stacked, the row only
            // grows, and it lands on the height the click measured.
            let thought = try XCTUnwrap(fixture.rows.first { row in
                if case .block(let block) = row.item { return block.part?.part.kind == "reasoningText" }
                return false
            })
            guard case .block(let block) = thought.item else { return XCTFail("a thought row") }
            let closed = thought.frame.height
            thought.toggleDisclosure(.work(block.key))
            XCTAssertTrue(fixture.document.isMovingDisclosure, "a click starts the motion rather than snapping")
            var heights: [CGFloat] = []
            for point in [0.0, 0.25, 0.5, 0.75, 1.0] {
                fixture.document.advanceDisclosureMotion(to: point)
                fixture.window.displayIfNeeded()
                heights.append(thought.frame.height)
                var expected: CGFloat?
                for row in fixture.rows {
                    if let expected {
                        XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5,
                                       "at \(point): \(row.itemID) starts at \(row.frame.minY), the row above ends at \(expected)")
                    }
                    expected = row.frame.maxY
                }
            }
            for (index, height) in heights.dropFirst().enumerated() {
                XCTAssertGreaterThanOrEqual(height, heights[index] - 0.5, "the row only grows as it opens: \(heights)")
            }
            XCTAssertGreaterThan(heights.last ?? closed, closed, "the thought ended open")
            XCTAssertFalse(fixture.document.isMovingDisclosure, "the motion ends on the geometry the click measured")
        }
    }
}
