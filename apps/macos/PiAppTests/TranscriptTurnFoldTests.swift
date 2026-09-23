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

    // MARK: Display turns, steering and chats without turn ids

    /// The host stamps a steering input and every reply after it with the
    /// task root of the run it steers, so a steered task has two display
    /// turns under one root.
    private func rooted(_ message: TranscriptMessage, _ root: String?) -> TranscriptMessage {
        var copy = message; copy.taskRootID = root; return copy
    }
    private func controls(_ items: [TranscriptItem]) -> [TranscriptBlock] {
        items.compactMap { if case .block(let block) = $0, block.presentation == .turnFold { return block }; return nil }
    }
    /// u1 → a thought-out reply → a steer → a thought-out answer, all under root u1.
    private func steered() -> [TranscriptMessage] {
        [rooted(TranscriptMessage(id: "u1", role: "user", text: "Look at the retry loop.", at: 1_000, turn: "u1"), "u1"),
         rooted(reply(id: "a1", turn: "u1", at: 2_000, text: "It retries on every error.", thinking: "Where does it retry?"), "u1"),
         rooted(TranscriptMessage(id: "s1", role: "user", text: "Only the network errors, please.", at: 3_000, turn: "s1"), "u1"),
         rooted(reply(id: "a2", turn: "s1", at: 4_000, text: "Network errors retry three times.", thinking: "Which errors are transient?"), "u1")]
    }

    /// A steer mid-task split one task into two display turns that both
    /// folded as "fold:<root>": the page rejected every later projection as
    /// conflicting row identities, and both folds shared one open state.
    @MainActor func testASteeredTaskFoldsEachDisplayTurnUnderItsOwnKeyAndThePageKeepsRendering() throws {
        let items = withDisplay(.compact) { TaskTranscriptPlan.items(steered(), lifecycle: nil) }
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "Every row of a steered task has its own identity")
        XCTAssertEqual(controls(items).compactMap(\.foldControl), ["u1", "s1"],
                       "Each display turn folds on its own, keyed by the input that opened it")
        // And each keeps its own open state: opening one does not open the other.
        let store = TranscriptDisclosure()
        store.setOpen(true, .turnFold("u1"))
        for item in items {
            let group: String?
            switch item { case .message(let message): group = message.foldGroup; case .block(let block): group = block.foldGroup }
            guard let group else { continue }
            XCTAssertEqual(TranscriptRowDisclosure.of(item, in: store).foldedAway, group == "s1", "\(item.id) of \(group)")
        }

        // The scenario the finder saw: narration and a call, a steer, then the answer.
        var narrated = steered()
        narrated[1] = rooted(reply(id: "a1", turn: "u1", at: 2_000, text: "Reading the file first.", call: (id: "c1", name: "read")), "u1")
        narrated[3] = rooted(reply(id: "a2", turn: "s1", at: 4_000, text: "Network errors retry three times."), "u1")
        let other = withDisplay(.compact) { TaskTranscriptPlan.items(narrated, lifecycle: nil) }
        XCTAssertEqual(Set(other.map(\.id)).count, other.count)

        // And in a real window: the page publishes rather than freezing on
        // the last valid page.
        try withDisplay(.compact) {
            for rows in [steered(), narrated] {
                let fixture = Fixture(messages: rows); defer { fixture.close() }
                XCTAssertNil(fixture.page.projectionError, "A steered task never reads as conflicting row identities")
                let snapshot = try XCTUnwrap(fixture.page.snapshot)
                XCTAssertEqual(snapshot.messages.map(\.id), rows.map(\.id))
            }
        }
    }

    /// A plain answer — no reasoning, no tools — has nothing to fold. It used
    /// to get a "Thought for a while" line that hid only its own header.
    @MainActor func testAPlainAnswerHasNothingToFold() throws {
        let plain = [TranscriptMessage(id: "u1", role: "user", text: "Hi", at: 1_000, turn: "u1"),
                     reply(id: "a1", turn: "u1", at: 2_000, text: "Hello.")]
        XCTAssertTrue(controls(withDisplay(.compact) { TaskTranscriptPlan.items(plain, lifecycle: nil) }).isEmpty,
                      "An answer with no work under it reads as the answer alone")
        let thought = [plain[0], reply(id: "a1", turn: "u1", at: 2_000, text: "Hello.", thinking: "A greeting.")]
        let fold = try XCTUnwrap(controls(withDisplay(.compact) { TaskTranscriptPlan.items(thought, lifecycle: nil) }).first)
        XCTAssertEqual(fold.foldSummary?.label, "Thought for a while", "A turn that only thought still says so")
    }

    /// A turn that stopped or failed in the middle of its tool work did not
    /// answer: its narration is not an answer, and the stopped work stays on
    /// screen rather than behind a line.
    @MainActor func testATurnThatEndsInToolWorkNeverFoldsBehindItsNarration() throws {
        let u1 = TranscriptMessage(id: "u1", role: "user", text: "Fix it.", at: 1_000, turn: "u1")
        let narration = reply(id: "a1", turn: "u1", at: 2_000, text: "Reading the file first.", call: (id: "c1", name: "read"))
        let toolsOnly = reply(id: "a2", turn: "u1", at: 3_000, text: "", call: (id: "c2", name: "bash"))
        for rows in [[u1, narration, toolsOnly], [u1, narration]] {
            let items = withDisplay(.compact) { TaskTranscriptPlan.items(rows, lifecycle: nil) }
            XCTAssertTrue(controls(items).isEmpty, "\(rows.map(\.id)): a turn that ended in tool work has no answer to fold behind")
            XCTAssertEqual(groups(items).compactMap { $0 }, [], "Nothing of it is hidden")
        }
    }

    /// What ends a turn is a reply that said something and asked for nothing
    /// more, whatever follows its words inside it — and a legacy reply, whose
    /// part order is unknown, is read by the same rule.
    @MainActor func testTheAnswerIsTheLastReplyThatSpokeAndMadeNoCall() throws {
        let u1 = TranscriptMessage(id: "u1", role: "user", text: "Fix it.", at: 1_000, turn: "u1")
        let work = reply(id: "a1", turn: "u1", at: 2_000, text: "", thinking: "Where?", call: (id: "c1", name: "read"))
        // Words, then a thought the provider returned after them.
        var timeline = ResponseTimeline()
        for (index, part) in [("text", "Fixed."), ("reasoningText", "That should hold.")].enumerated() {
            timeline.consume(ResponsePartEvent(attemptID: "attempt-a2", ordinal: index, itemID: "a2-\(index)", outputIndex: index,
                                               partIndex: 0, kind: part.0, update: "replace", text: part.1))
        }
        timeline.finish("completed")
        var answer = TranscriptMessage(id: "a2", role: "assistant", text: "Fixed.", thinking: "That should hold.", state: "complete", at: 3_000, turn: "u1")
        answer.responseTimeline = timeline
        let items = withDisplay(.compact) { TaskTranscriptPlan.items([u1, work, answer], lifecycle: nil) }
        let fold = try XCTUnwrap(control(items))
        XCTAssertEqual(fold.foldSummary?.answerResponseID, "a2")
        for case .block(let block) in items where block.responseID == "a2" && block.part != nil {
            XCTAssertEqual(block.foldGroup != nil, block.part?.part.kind == "reasoningText",
                           "the answer's words stay; the thought after them folds with the work")
        }

        // Legacy replies: the one that ran a tool is work, the one that
        // answered without a call ends the turn.
        let legacyWork = TranscriptMessage(id: "l1", role: "assistant", text: "",
                                           tools: [ToolView(id: "t1", name: "read", state: "completed", input: "{}", output: "", truncated: false)],
                                           state: "complete", at: 2_000, turn: "u1")
        let legacyAnswer = TranscriptMessage(id: "l2", role: "assistant", text: "Fixed.", thinking: "Done.", state: "complete", at: 3_000, turn: "u1")
        let legacy = withDisplay(.compact) { TaskTranscriptPlan.items([u1, legacyWork, legacyAnswer], lifecycle: nil) }
        XCTAssertEqual(control(legacy)?.foldSummary?.label, "1 tool call")
        for case .block(let block) in legacy where block.presentation == .body {
            XCTAssertNil(block.foldGroup, "a legacy answer's words never fold")
        }
        var calling = legacyAnswer; calling.tools = legacyWork.tools
        XCTAssertNil(control(withDisplay(.compact) { TaskTranscriptPlan.items([u1, legacyWork, calling], lifecycle: nil) }),
                     "a legacy reply that made a call did not end its turn")
    }

    /// The resident window and a forward history read can end a page in the
    /// middle of a turn. What it holds of that turn is not the turn's answer.
    @MainActor func testAPageThatEndsMidTurnLeavesItsLastTurnOpen() throws {
        let full = [TranscriptMessage(id: "u1", role: "user", text: "Fix it.", at: 1_000, turn: "u1"),
                    reply(id: "a1", turn: "u1", at: 2_000, text: "Reading the file first.", call: (id: "c1", name: "read")),
                    reply(id: "a2", turn: "u1", at: 3_000, text: "Now the tests.", call: (id: "c2", name: "bash")),
                    reply(id: "a3", turn: "u1", at: 4_000, text: "Fixed.")]
        XCTAssertNotNil(control(withDisplay(.compact) { TaskTranscriptPlan.items(full, lifecycle: nil) }), "The whole turn folds")
        for cut in 2...3 {
            let page = Array(full.prefix(cut))
            XCTAssertNil(control(withDisplay(.compact) { TaskTranscriptPlan.items(page, lifecycle: nil) }),
                         "A page cut after \(page.last!.id) does not fold that turn behind its narration")
        }
        // A cut the rows cannot show: words that end a page need not be the
        // turn's last. A page that stops short of the newest row folds its
        // last turn only on the task's own receipt that it ended there.
        let spoken = [full[0], reply(id: "a1", turn: "u1", at: 2_000, text: "Found it.", thinking: "Where?")]
        XCTAssertNotNil(control(TaskTranscriptPlan.items(spoken, lifecycle: nil, display: .compact)))
        XCTAssertNil(control(TaskTranscriptPlan.items(spoken, lifecycle: nil, display: .compact, complete: false)),
                     "a page short of the newest row does not fold its last turn on words alone")
        var receipt = TaskPresentationRecord(rootID: "u1", executionID: "e1", startedAt: 1_000)
        receipt.outcome = "completed"; receipt.phase = "terminal"; receipt.endedAt = 5_000; receipt.lastSourceID = "a1"
        let ended = TaskPresentationProjection(sessionID: "s", epoch: "e", timeline: "root", sequence: 1,
                                               sourceRevision: "1", active: nil, recent: [receipt])
        let stamped = spoken.map { row -> TranscriptMessage in var copy = row; copy.taskRootID = "u1"; copy.taskExecutionID = "e1"; return copy }
        XCTAssertNotNil(control(TaskTranscriptPlan.items(stamped, lifecycle: ended, display: .compact, complete: false)),
                        "the task's receipt says the turn ended here")
        // An earlier turn is ended by the next question, however the page ends.
        let two = spoken + [TranscriptMessage(id: "u2", role: "user", text: "And then?", at: 6_000, turn: "u2"),
                            reply(id: "b1", turn: "u2", at: 7_000, text: "Then this.", thinking: "Next.")]
        XCTAssertEqual(controls(TaskTranscriptPlan.items(two, lifecycle: nil, display: .compact, complete: false)).compactMap(\.foldControl), ["u1"])
        XCTAssertEqual(controls(TaskTranscriptPlan.items(two, lifecycle: nil, display: .compact)).compactMap(\.foldControl), ["u1", "u2"])
    }

    /// Imported sessions and chats from before turn ids have no turn on any
    /// row. Their folds must open and stay open, and so must the fold of a
    /// steered turn whose root question is not on the page.
    @MainActor func testAFoldWithoutATurnIdOnThePageOpensAndStaysOpen() throws {
        func unmarked(_ message: TranscriptMessage) -> TranscriptMessage {
            var copy = message; copy.turn = nil; copy.taskRootID = nil; return copy
        }
        let imported = [unmarked(TranscriptMessage(id: "u1", role: "user", text: "Look at the retry loop.", at: 1_000)),
                        unmarked(reply(id: "a1", turn: "", at: 2_000, text: "", thinking: "Where does it retry?", call: (id: "c1", name: "read"))),
                        unmarked(reply(id: "a2", turn: "", at: 3_000, text: "It retries three times."))]
        // A page that begins at a steer: the root the replies carry is not here.
        let steeredPage = Array(steered().dropFirst(2))
        try withDisplay(.compact) {
            for rows in [imported, steeredPage] {
                let fixture = Fixture(messages: rows); defer { fixture.close() }
                let control = try XCTUnwrap(fixture.controlRow, "\(rows.map(\.id)) folds")
                guard case .block(let block) = control.item, let group = block.foldControl else { return XCTFail("a fold control") }
                XCTAssertTrue(fixture.memberRows.allSatisfy { $0.frame.height < 2 })
                control.toggleDisclosure(.turnFold(group))
                fixture.session.publishTranscript(); fixture.refresh()
                XCTAssertTrue(fixture.session.disclosure.isOpen(.turnFold(group)),
                              "\(rows.map(\.id)): the open fold survives the republish its own click asked for")
                XCTAssertFalse(fixture.memberRows.isEmpty)
                XCTAssertTrue(fixture.memberRows.allSatisfy { $0.frame.height > 2 },
                              "\(rows.map(\.id)): every row of the opened turn draws again")
            }
        }
    }

    /// The keyboard folds the same thing the chevron does: Unfold This Turn
    /// opens the finished turn's fold, Fold Every Turn closes it again.
    @MainActor func testTheFoldCommandsOpenAndCloseTheEndOfTurnFold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionDisplay(id: "keys")
        session.messages = steered()
        model.displays = [session.id: session]
        model.focusedSessionID = session.id
        withDisplay(.compact) {
            XCTAssertTrue(model.canFoldTurns)
            // Nobody has scrolled: the newest turn is the one the reader is on.
            model.setFocusedTurnFolded(false)
            XCTAssertTrue(session.disclosure.isOpen(.turnFold("s1")), "⌥⌘] opens the newest turn's fold")
            XCTAssertFalse(session.disclosure.isOpen(.turnFold("u1")), "and only that one")
            // A reader on the first question is on the first turn.
            session.scrollAnchor = TranscriptAnchor(id: "u1", offset: 0, followsBottom: false)
            model.setFocusedTurnFolded(false)
            XCTAssertTrue(session.disclosure.isOpen(.turnFold("u1")))
            model.setEveryTurnFolded(true)
            XCTAssertFalse(session.disclosure.isOpen(.turnFold("u1")), "⇧⌥⌘[ folds every finished turn")
            XCTAssertFalse(session.disclosure.isOpen(.turnFold("s1")))
            model.setEveryTurnFolded(false)
            XCTAssertTrue(session.disclosure.isOpen(.turnFold("u1")))
            XCTAssertTrue(session.disclosure.isOpen(.turnFold("s1")))
            model.setFocusedTurnFolded(true)
            XCTAssertFalse(session.disclosure.isOpen(.turnFold("u1")), "⌥⌘[ folds the turn the reader is on")
            XCTAssertTrue(session.disclosure.isOpen(.turnFold("s1")))
        }
    }

    /// Planning a page asked whether each reply said anything by trimming its
    /// whole text and reasoning — and the fold trimmed every text part twice
    /// more — so a page of long answers copied all of them on every plan.
    /// Whether text is blank is answered by its first visible character, and
    /// planning costs the same whatever length the replies are.
    @MainActor func testPlanningCostDoesNotGrowWithTheLengthOfWhatWasSaid() {
        func page(_ bytes: Int) -> [TranscriptMessage] {
            // Model output usually ends in a newline, which trimming had to cut.
            let words = String(repeating: "The retry loop backs off. ", count: max(1, bytes / 26)) + "\n"
            var rows = [TranscriptMessage(id: "u1", role: "user", text: "Explain.", at: 1_000, turn: "u1")]
            for index in 0..<40 {
                rows.append(reply(id: "a\(index)", turn: "u1", at: Double(2_000 + index), text: words, thinking: words,
                                  call: index < 39 ? (id: "c\(index)", name: "read") : nil))
            }
            return rows
        }
        // The two pages are planned in alternation, so both see the same load.
        func costs(_ first: [TranscriptMessage], _ second: [TranscriptMessage], runs: Int = 7) -> (Double, Double) {
            var best = (Double.infinity, Double.infinity)
            for _ in 0..<runs {
                for (index, rows) in [first, second].enumerated() {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = TaskTranscriptPlan.items(rows, lifecycle: nil, display: .compact)
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    if index == 0 { best.0 = min(best.0, ms) } else { best.1 = min(best.1, ms) }
                }
            }
            return best
        }
        let short = page(64), long = page(131_072)
        XCTAssertNotNil(control(TaskTranscriptPlan.items(long, lifecycle: nil, display: .compact)), "the measured page folds")
        let (shortMs, longMs) = costs(short, long)
        print(String(format: "PERF planner fortyReplies textBytes=64 ms=%.3f textBytes=131072 ms=%.3f ratio=%.2f", shortMs, longMs, longMs / max(shortMs, 0.001)))

        // One very long answer: a page always keeps a single row whole, however
        // large, so 4 MB of words and 4 MB of reasoning is one page.
        func answer(_ bytes: Int) -> [TranscriptMessage] {
            let words = String(repeating: "The retry loop backs off. ", count: max(1, bytes / 26)) + "\n"
            return [TranscriptMessage(id: "u1", role: "user", text: "Explain.", at: 1_000, turn: "u1"),
                    reply(id: "a1", turn: "u1", at: 2_000, text: "", thinking: "Where?", call: (id: "c1", name: "read")),
                    reply(id: "a2", turn: "u1", at: 3_000, text: words, thinking: words)]
        }
        let brief = answer(64), whole = answer(4_000_000)
        XCTAssertNotNil(control(TaskTranscriptPlan.items(whole, lifecycle: nil, display: .compact)))
        let (briefMs, wholeMs) = costs(brief, whole, runs: 25)
        print(String(format: "PERF planner oneAnswer textAndReasoningBytes=128 ms=%.3f textAndReasoningBytes=8000000 ms=%.3f", briefMs, wholeMs))
        XCTAssertLessThan(wholeMs, briefMs * 1.5 + 0.2, "an 8 MB answer plans as fast as a short one: nothing copies it")
    }

    /// SwiftUI evaluates the Conversation menu on every publish of the model,
    /// and the fold items asked whether they were enabled six times over, each
    /// by planning the whole page. The menu now reads the rows instead.
    @MainActor func testEvaluatingTheFoldMenuDoesNotPlanThePage() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionDisplay(id: "menu")
        var rows: [TranscriptMessage] = []
        for turn in 0..<50 {
            let user = "u\(turn)"
            rows.append(TranscriptMessage(id: user, role: "user", text: "Question \(turn)", at: Double(turn * 10_000), turn: user))
            for step in 0..<6 {
                rows.append(reply(id: "a\(turn)-\(step)", turn: user, at: Double(turn * 10_000 + step + 1), text: step == 5 ? "Answer \(turn)." : "",
                                  thinking: "Step \(step)", call: step < 5 ? (id: "c\(turn)-\(step)", name: "read") : nil))
            }
        }
        session.messages = rows
        model.displays = [session.id: session]
        model.focusedSessionID = session.id
        withDisplay(.compact) {
            let planned = TaskTranscriptPlan.planned
            var best = Double.infinity
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                // What one evaluation of the Conversation menu reads.
                let enabled = [model.canFoldTurns, model.canFoldTurns, model.canFoldTurns, model.canFoldTurns,
                               model.canFoldResponses, model.canFoldResponses]
                best = min(best, (ProcessInfo.processInfo.systemUptime - start) * 1000)
                XCTAssertEqual(enabled, Array(repeating: true, count: 6))
            }
            XCTAssertEqual(TaskTranscriptPlan.planned, planned, "evaluating the menu five times planned the page \(TaskTranscriptPlan.planned - planned) times")
            // A command plans the page once, when it runs.
            let start = ProcessInfo.processInfo.systemUptime
            let unfolded = model.setEveryTurnFolded(false)
            let commandMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertEqual(TaskTranscriptPlan.planned - planned, 1, "a command plans the page once")
            XCTAssertEqual(unfolded, WorkspaceModel.turnKeys(in: session.presentedMessages).count)
            model.setFocusedTurnFolded(true)
            XCTAssertEqual(TaskTranscriptPlan.planned - planned, 3, "one more for the count above, one for the command")
            XCTAssertEqual(WorkspaceModel.turnFolds(in: WorkspaceModel.commandItems(session)).count, 50)
            print(String(format: "PERF foldMenu rows=%d evaluationMs=%.3f commandMs=%.3f (before: every evaluation planned the page 6 times)",
                         rows.count, best, commandMs))
        }
        // An empty chat, and one with only the reader's question, offer nothing to fold.
        session.messages = [rows[0]]
        XCTAssertFalse(model.canFoldTurns); XCTAssertFalse(model.canFoldResponses)
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

    /// Folding a turn is one change to the page, made where the click is:
    /// every row of the turn takes its new geometry in the click's own pass
    /// and moves with the others. They used to take their folded content from
    /// SwiftUI's next update and their geometry a run-loop turn after that, so
    /// a frame showed the turn's rows empty in their old frames before the
    /// rows below moved up. Checked in a real pane, frame by frame, with the
    /// motion and with it snapped.
    @MainActor func testFoldingATurnMovesEveryRowOfItInTheClicksOwnPass() async throws {
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(.compact)
        defer { TranscriptDisplay.use(previous); TranscriptNativeDocument.reducesMotionOverride = nil }
        for snapped in [false, true] {
            TranscriptNativeDocument.reducesMotionOverride = snapped
            let session = SessionDisplay(id: "fold-one-pass-\(snapped)")
            session.messages = turn() + [TranscriptMessage(id: "u2", role: "user", text: "And the timeout?", at: 5_000, turn: "u2"),
                                         reply(id: "b1", turn: "u2", at: 6_000, text: "Thirty seconds, set where the client is built.")]
            let pane = TranscriptFrameBudgetTests.Pane(session, height: 900)
            defer { pane.close() }
            let appeared = await pane.waitForRow("u2", seconds: 60)
            XCTAssertTrue(appeared, "the chat never appeared")
            await pane.settle(turns: 10)
            let document = try XCTUnwrap(pane.document)
            func group(_ row: TranscriptRowContainer) -> String? {
                switch row.contentItem {
                case .block(let block): return block.foldGroup
                case .message(let message): return message.foldGroup
                }
            }
            func members() -> [TranscriptRowContainer] { document.retainedRows.filter { group($0) == "u1" } }
            let control = try XCTUnwrap(document.retainedRows.first { row in
                if case .block(let block) = row.contentItem { return block.presentation == .turnFold }
                return false
            })
            /// Frames as the app draws them, the main queue running between
            /// them. No row of the turn may stand taller than what it draws
            /// unless the document is moving it.
            func frames(_ what: String) async {
                for frame in 0..<30 {
                    pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
                    for row in members() where !row.isInDisclosureMotion {
                        XCTAssertLessThanOrEqual(row.frame.height, row.hostedFittingHeight + 2,
                                                 "\(what), frame \(frame): \(row.itemID) stands \(row.frame.height) pt tall and draws \(row.hostedFittingHeight) pt")
                    }
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(10))
                }
                document.finishDisclosureMotion()
            }
            XCTAssertTrue(members().allSatisfy { $0.frame.height <= 2 }, "a finished turn opens folded")

            control.toggleDisclosure(.turnFold("u1"))
            XCTAssertTrue(snapped ? members().contains { $0.frame.height > 20 } : members().filter(\.isInDisclosureMotion).count > 2,
                          "snapped \(snapped): opening the turn left its rows where they were until a later pass")
            await frames("opening, snapped \(snapped)")
            let open = members().map(\.frame.height)
            XCTAssertGreaterThan(open.filter { $0 > 20 }.count, 2, "the turn's rows are drawn again")

            control.toggleDisclosure(.turnFold("u1"))
            XCTAssertTrue(members().allSatisfy { $0.isInDisclosureMotion || $0.frame.height <= 2 },
                          "snapped \(snapped): folding the turn left its rows standing at \(members().map(\.frame.height)) until a later pass")
            await frames("folding, snapped \(snapped)")
            XCTAssertTrue(members().allSatisfy { $0.frame.height <= 2 }, "the turn folds back to its one line")
        }
    }

    /// A fold that spans a turn moves every row of it, and a change that
    /// retargets it part way — the pane narrowing, here — restarts every one
    /// of those rows from the height it is on screen at. Only the first used
    /// to; the others jumped to where they were going.
    @MainActor func testARetargetedTurnFoldKeepsEveryRowWhereItWas() throws {
        try withDisplay(.compact) {
            TranscriptNativeDocument.reducesMotionOverride = false
            defer { TranscriptNativeDocument.reducesMotionOverride = nil }
            let fixture = Fixture(messages: turn()); defer { fixture.close() }
            let control = try XCTUnwrap(fixture.controlRow)
            control.toggleDisclosure(.turnFold("u1"))
            let moving = fixture.memberRows.filter(\.isInDisclosureMotion)
            XCTAssertGreaterThan(moving.count, 2, "opening the turn must move several rows for this to mean anything")
            fixture.document.advanceDisclosureMotion(to: 0.5)
            let halfway = Dictionary(uniqueKeysWithValues: moving.map { ($0.itemID, $0.frame.height) })
            fixture.scroll.frame = CGRect(origin: .zero, size: CGSize(width: fixture.scroll.frame.width - 140, height: fixture.scroll.frame.height))
            fixture.document.layoutRows(width: fixture.scroll.contentSize.width)
            XCTAssertTrue(fixture.document.isMovingDisclosure, "the narrower pane retargets the motion rather than ending it")
            for row in fixture.memberRows where halfway[row.itemID] != nil {
                XCTAssertEqual(row.frame.height, halfway[row.itemID] ?? 0, accuracy: 1,
                               "\(row.itemID) jumped from \(halfway[row.itemID] ?? 0) to \(row.frame.height) pt when the motion was retargeted")
            }
            fixture.document.finishDisclosureMotion()
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

    /// A page that stops short of the conversation's newest row — a history
    /// window with newer rows after it, or the resident window's cut — may
    /// end in the middle of a turn. Its last turn does not fold on words alone.
    @MainActor func testAWindowShortOfTheNewestRowLeavesItsLastTurnOpen() throws {
        let rows = [TranscriptMessage(id: "u1", role: "user", text: "Fix it.", at: 1_000, turn: "u1"),
                    reply(id: "a1", turn: "u1", at: 2_000, text: "Found it.", thinking: "Where?")]
        try withDisplay(.compact) {
            let whole = Fixture(messages: rows); defer { whole.close() }
            XCTAssertNotNil(whole.controlRow, "a page that reaches the newest row folds its finished turn")
            let session = SessionDisplay(id: "browsing")
            session.newerPage = ConversationPageBoundary(cursor: ConversationCursor(incarnation: "file:1:1", lineage: "root", entry: "a1"))
            session.messages = rows
            let page = TranscriptPage(); page.state = "idle"; page.bind(session)
            let items = try XCTUnwrap(page.snapshot?.items)
            XCTAssertFalse(items.contains { if case .block(let b) = $0 { return b.presentation == .turnFold }; return false },
                           "a window with newer rows after it does not fold its last turn on words alone")
        }
    }
}
