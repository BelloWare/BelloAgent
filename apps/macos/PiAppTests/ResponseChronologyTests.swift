import XCTest
import SwiftUI
@testable import PiApp

/// What the reader sees of one reply: its parts in the order they actually
/// arrived — prose, the card of the call it made, the reasoning it returned,
/// more prose — and the one control that folds all of it.
///
/// The order is asserted against the order in the response's own record, while
/// it streams and after it settles, and the geometry is asserted in a real
/// window: rows stacked, each level of the fold measured in the same pass as
/// the click that asked for it.
final class ResponseChronologyTests: XCTestCase {
    // MARK: A response whose parts did not arrive in the flattened order

    /// text → tool call → reasoning → text, as the provider delivered it.
    private func interleaved(streaming: Bool = false, arguments: String = "{\"command\":\"npm test\"}") -> TranscriptMessage {
        var timeline = ResponseTimeline()
        let parts: [(kind: String, text: String, call: String?, name: String?)] = [
            ("text", "First, here is what I found.", nil, nil),
            ("toolArguments", arguments, "call-1", "bash"),
            ("reasoningText", "The suite passed, so the change is safe.", nil, nil),
            ("text", "And here is the conclusion.", nil, nil),
        ]
        for (index, part) in parts.enumerated() {
            timeline.consume(ResponsePartEvent(attemptID: "attempt", ordinal: index, itemID: "item-\(index)",
                                               outputIndex: index, partIndex: 0, kind: part.kind,
                                               update: streaming && index == parts.count - 1 ? "append" : "replace",
                                               text: part.text, callID: part.call, name: part.name))
        }
        if !streaming { timeline.finish("completed") }
        var reply = TranscriptMessage(id: "reply", role: "assistant",
                                      text: "First, here is what I found.And here is the conclusion.",
                                      thinking: "The suite passed, so the change is safe.",
                                      tools: [ToolView(id: "call-1", name: "bash", state: streaming ? "running" : "completed",
                                                       input: arguments, output: "12 tests passed", durationMs: 940, truncated: false)],
                                      state: streaming ? "streaming" : "complete", at: 2_000, turn: "u1")
        reply.modelMs = 4_200
        reply.responseTimeline = timeline
        return reply
    }
    private func conversation(streaming: Bool = false) -> [TranscriptMessage] {
        var result = TranscriptMessage(id: "result", role: "tool", text: "12 tests passed", at: 2_500, turn: "u1")
        result.kind = "toolResult"; result.detail = "Tool result · bash"; result.toolCallID = "call-1"
        return [TranscriptMessage(id: "u1", role: "user", text: "Run the tests and explain.", at: 1_000, turn: "u1"),
                interleaved(streaming: streaming), result]
    }
    /// The kinds of the response's rows, in the order the page holds them.
    private func rowKinds(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case .message(let message): return "message:" + (message.kind ?? message.role)
            case .block(let block):
                if block.presentation == .response { return "response" }
                if let part = block.part { return (block.message?.tools?.isEmpty == false ? "card:" : "part:") + part.part.kind }
                return "block:\(block.presentation)"
            }
        }
    }

    func testPartsAreShownInTheOrderTheyArrived() {
        let settled = TaskTranscriptPlan.items(conversation(), lifecycle: nil)
        XCTAssertEqual(rowKinds(settled),
                       ["message:user", "response", "part:text", "card:toolArguments", "part:reasoningText", "part:text", "message:requestInfo"],
                       "The reply reads text, the call it made, the reasoning it returned, then text")
        // The same order, from the same record, while the reply is arriving
        // and before its call has a result.
        XCTAssertEqual(rowKinds(TaskTranscriptPlan.items(Array(conversation(streaming: true).prefix(2)), lifecycle: nil)),
                       rowKinds(settled), "Streaming and settled hold the same order")
        // And it is the order of the record itself, not a re-sorted one.
        let record = interleaved().responseTimeline?.segments.map(\.part.kind)
        XCTAssertEqual(record, ["text", "toolArguments", "reasoningText", "text"])
        let shown = settled.compactMap { item -> String? in
            if case .block(let block) = item, let part = block.part { return part.part.kind }
            return nil
        }
        XCTAssertEqual(shown, record)
    }

    func testTheCallIsOneCardAtThePositionItWasMade() throws {
        let items = TaskTranscriptPlan.items(conversation(), lifecycle: nil)
        let card = try XCTUnwrap(items.compactMap { item -> TranscriptBlock? in
            if case .block(let block) = item, block.part?.part.kind == "toolArguments" { return block }
            return nil
        }.first)
        let tool = try XCTUnwrap(card.message?.tools?.first)
        XCTAssertEqual(tool.id, "call-1")
        XCTAssertEqual(tool.output, "12 tests passed", "The card carries the call's own result")
        XCTAssertEqual(tool.durationMs, 940)
        // Only the call made here travels with the row, so another card's
        // output can never re-measure it.
        XCTAssertEqual(card.message?.tools?.count, 1)
        // The result is the same result: it is not also shown as its own row.
        XCTAssertFalse(items.contains { if case .message(let message) = $0 { return message.kind == "toolResult" }; return false },
                       "A result whose call is shown as a card is not repeated underneath")
        // A result whose call is not on this page keeps its own row.
        var orphan = TranscriptMessage(id: "other", role: "tool", text: "output", at: 3_000, turn: "u1")
        orphan.kind = "toolResult"; orphan.toolCallID = "call-9"
        XCTAssertTrue(TaskTranscriptPlan.items(conversation() + [orphan], lifecycle: nil)
            .contains { if case .message(let message) = $0 { return message.id == "other" }; return false })
    }

    /// The call appears where it was made, and the result lands in that same
    /// card without anything else moving: while the reply streams, once it has
    /// settled, and read back from the journal.
    func testTheResultLandsInTheCallsOwnCardWithoutMovingAnything() throws {
        // While the call is still being written, there is no result yet.
        var streaming = conversation(streaming: true)
        streaming[1].tools = [ToolView(id: "call-1", name: "bash", state: "preparing", input: "{\"command\":\"npm te",
                                       output: "", durationMs: nil, truncated: false)]
        let before = TaskTranscriptPlan.items(Array(streaming.prefix(2)), lifecycle: nil)
        XCTAssertEqual(rowKinds(before),
                       ["message:user", "response", "part:text", "card:toolArguments", "part:reasoningText", "part:text", "message:requestInfo"])
        let preparing = try XCTUnwrap(before.compactMap { item -> ToolView? in
            if case .block(let block) = item, block.part?.part.kind == "toolArguments" { return block.message?.tools?.first }
            return nil
        }.first)
        XCTAssertEqual(preparing.state, "preparing"); XCTAssertEqual(preparing.output, "")
        // The result lands. The rows are the same rows, in the same order; the
        // card it belongs to now carries it.
        let after = TaskTranscriptPlan.items(conversation(), lifecycle: nil)
        XCTAssertEqual(after.map(\.id), before.map(\.id), "A result cannot move, add or remove a row")
        let landed = try XCTUnwrap(after.compactMap { item -> ToolView? in
            if case .block(let block) = item, block.part?.part.kind == "toolArguments" { return block.message?.tools?.first }
            return nil
        }.first)
        XCTAssertEqual(landed.state, "completed"); XCTAssertEqual(landed.output, "12 tests passed")
        // The local record that the call started is what the card's status
        // says, so it is not a row of its own either.
        var started = TranscriptMessage(id: "exec", role: "system", text: "", at: 2_100, turn: "u1")
        started.kind = "execution"; started.detail = "Tool started · bash"
        var evidence = ResponseTimeline()
        evidence.consume(ResponsePartEvent(attemptID: "exec", ordinal: 0, itemID: "exec", kind: "status", update: "begin",
                                           text: "Invocation started: bash", callID: "call-1", name: "bash", evidence: "local"))
        started.responseTimeline = evidence
        let withStart = TaskTranscriptPlan.items([conversation()[0], conversation()[1], started, conversation()[2]], lifecycle: nil)
        XCTAssertEqual(withStart.map(\.id), after.map(\.id), "The call, its start and its result are one card")
        // A start record for another operation keeps its row.
        var compaction = started; compaction.id = "op"; compaction.responseTimeline = ResponseTimeline()
        XCTAssertTrue(TaskTranscriptPlan.items([conversation()[0], conversation()[1], compaction], lifecycle: nil)
            .contains { if case .message(let message) = $0 { return message.id == "op" }; return false })
        // A page read from a journal holds the request in its card and not the
        // result, so that result keeps its own row rather than disappearing.
        var journal = conversation()
        journal[1].tools = [ToolView(id: "call-1", name: "bash", state: "recorded", input: "{\"command\":\"npm test\"}",
                                     output: "", durationMs: nil, truncated: false)]
        XCTAssertTrue(TaskTranscriptPlan.items(journal, lifecycle: nil)
            .contains { if case .message(let message) = $0 { return message.kind == "toolResult" }; return false },
                      "A result a card cannot show is still shown")
    }

    /// A chat read back from its journal shows the same card as a live one:
    /// the call, its outcome, its clock and its output in one place, and no
    /// separate result row underneath.
    func testAChatReadFromItsJournalShowsTheSameCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.jsonl")
        let arguments: WireValue = .object(["command": .string("npm test")])
        let reply: WireValue = .object(["role": .string("assistant"), "timestamp": .number(2_000), "nativeTurn": .string("u1"),
            "content": .array([.object(["type": .string("text"), "text": .string("Running the suite.")]),
                               .object(["type": .string("toolCall"), "id": .string("call-1"), "name": .string("bash"), "arguments": arguments])])])
        let result: WireValue = .object(["role": .string("toolResult"), "timestamp": .number(2_500), "nativeTurn": .string("u1"),
            "toolCallId": .string("call-1"), "toolName": .string("bash"), "isError": .bool(false),
            "content": .array([.object(["type": .string("text"), "text": .string("12 tests passed")])]),
            "nativeToolStats": .object(["durationMs": .number(940), "outcome": .string("completed")])])
        let records: [WireValue] = [
            .object(["type": .string("session"), "version": .number(3), "id": .string("s")]),
            .object(["type": .string("message"), "id": .string("u1"), "message": .object(["role": .string("user"), "content": .string("Run the tests")])]),
            .object(["type": .string("message"), "id": .string("a1"), "parentId": .string("u1"), "message": reply]),
            .object(["type": .string("message"), "id": .string("r1"), "parentId": .string("a1"), "message": result])]
        var bytes = Data()
        for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        try bytes.write(to: file)

        let page = try await HistoryReader().read(path: file.path)
        let card = try XCTUnwrap(page.messages.first { $0.role == "assistant" }?.tools?.first)
        XCTAssertEqual(card.id, "call-1")
        XCTAssertEqual(card.state, "completed", "The recorded result decides the card's outcome")
        XCTAssertEqual(card.output, "12 tests passed")
        XCTAssertEqual(card.durationMs, 940)
        let items = TaskTranscriptPlan.items(page.messages, lifecycle: nil)
        XCTAssertFalse(items.contains { if case .message(let message) = $0 { return message.kind == "toolResult" }; return false },
                       "The result is in its call's card, so it is not a row as well")
        XCTAssertEqual(rowKinds(items).filter { $0.hasPrefix("card:") }, ["card:toolArguments"])
        // A call whose result is not in the window keeps the card it was
        // projected with, and nothing claims an outcome it never saw.
        let unresolved = TranscriptMessage.resolvingToolResults(page.messages, results: [:])
        XCTAssertEqual(unresolved.first { $0.role == "assistant" }?.tools?.first?.state, "completed",
                       "A card already filled in stays filled in")
        let fresh = TranscriptMessage.project(id: "a1", message: reply.object ?? [:])
        XCTAssertEqual(TranscriptMessage.resolvingToolResults([fresh], results: [:]).first?.tools?.first?.state, "recorded")

        // A provider may reuse a call id on a later turn. Each card shows
        // the result of its own call, whichever direction the page was read
        // in, and each result is shown exactly once.
        func call(_ turn: String, _ at: Double) -> WireValue {
            .object(["role": .string("assistant"), "timestamp": .number(at), "nativeTurn": .string(turn),
                     "content": .array([.object(["type": .string("toolCall"), "id": .string("call-1"), "name": .string("bash"), "arguments": arguments])])])
        }
        func output(_ turn: String, _ at: Double, _ text: String) -> WireValue {
            .object(["role": .string("toolResult"), "timestamp": .number(at), "nativeTurn": .string(turn),
                     "toolCallId": .string("call-1"), "toolName": .string("bash"), "isError": .bool(false),
                     "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
        }
        let reused = root.appendingPathComponent("reused.jsonl")
        let turns: [(String, String?, WireValue)] = [
            ("u1", nil, .object(["role": .string("user"), "content": .string("First run")])),
            ("a1", "u1", call("u1", 2_000)), ("r1", "a1", output("u1", 2_500, "first")),
            ("u2", "r1", .object(["role": .string("user"), "content": .string("Second run")])),
            ("a2", "u2", call("u2", 4_000)), ("r2", "a2", output("u2", 4_500, "second"))]
        var journal = Data()
        journal.append(try JSONEncoder().encode(WireValue.object(["type": .string("session"), "version": .number(3), "id": .string("s")]))); journal.append(10)
        for (id, parent, message) in turns {
            var record: [String: WireValue] = ["type": .string("message"), "id": .string(id), "message": message]
            if let parent { record["parentId"] = .string(parent) }
            journal.append(try JSONEncoder().encode(WireValue.object(record))); journal.append(10)
        }
        try journal.write(to: reused)
        let reader = HistoryReader()
        let backward = try await reader.read(path: reused.path)
        let forward = try await reader.read(path: reused.path, around: "u1")
        let window = try await reader.window(path: reused.path)
        for (name, page) in [("backward", backward), ("forward", forward), ("window", window)] {
            XCTAssertEqual(page.messages.map(\.id), ["u1", "a1", "r1", "u2", "a2", "r2"], name)
            let cards = page.messages.filter { $0.role == "assistant" }.map { $0.tools?.first?.output }
            XCTAssertEqual(cards, ["first", "second"], "\(name): each card shows its own call's result")
            let items = TaskTranscriptPlan.items(page.messages, lifecycle: nil, display: .normal)
            let shown = items.flatMap { item -> [String] in
                switch item {
                case .message(let message): return message.kind == "toolResult" ? [message.text] : []
                case .block(let block): return block.presentation == .work ? (block.message?.tools ?? []).map(\.output) : []
                }
            }
            XCTAssertEqual(shown, ["first", "second"], "\(name): every result is on the page exactly once")
        }
    }

    /// Two responses may reuse a provider call id. Opening one card must not
    /// open the other, and asking for a call's full arguments must still name
    /// the reply that made it.
    @MainActor func testTwoResponsesReusingACallIdKeepTheirOwnCards() throws {
        var first = interleaved(), second = interleaved()
        second.id = "second"
        // The second card is one whose arguments the host had to cut, so
        // opening it asks for the rest. A whole card asks nothing.
        second.tools?[0].inputTruncated = true; second.tools?[0].inputBytes = 90_000
        second.responseTimeline = ResponseTimeline()
        var timeline = ResponseTimeline()
        timeline.consume(ResponsePartEvent(attemptID: "attempt-2", ordinal: 0, itemID: "item-0", outputIndex: 0, partIndex: 0,
                                           kind: "toolArguments", update: "replace", text: "{}", callID: "call-1", name: "bash"))
        timeline.finish("completed")
        second.responseTimeline = timeline
        let rows = [TranscriptMessage(id: "u1", role: "user", text: "Twice", at: 1_000, turn: "u1"), first, second]
        let items = TaskTranscriptPlan.items(rows, lifecycle: nil)
        let cards = items.compactMap { item -> TranscriptBlock? in
            if case .block(let block) = item, block.message?.tools?.isEmpty == false { return block }
            return nil
        }
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.map { $0.message?.id }, ["reply", "second"], "Each card belongs to the reply that made the call")
        let store = TranscriptDisclosure()
        store.setOpen(true, .tool(ToolOccurrence.key("reply", "call-1")))
        XCTAssertEqual(TranscriptRowDisclosure.of(.block(cards[0]), in: store).openTools, [ToolOccurrence.key("reply", "call-1")])
        XCTAssertTrue(TranscriptRowDisclosure.of(.block(cards[1]), in: store).openTools.isEmpty,
                      "The other response's card stays closed")
        // The row asks for that call's arguments with the reply's id and the
        // real call id, which is what the host answers for.
        let row = TranscriptRowContainer(item: .block(cards[1]), fresh: false, actions: TranscriptActions(), disclosure: store)
        var asked: [(String, String)] = []
        row.onToolInputNeeded = { asked.append(($0, $1)) }
        row.toggleDisclosure(.tool(ToolOccurrence.key("second", "call-1")))
        XCTAssertEqual(asked.map(\.0), ["second"]); XCTAssertEqual(asked.map(\.1), ["call-1"])
        XCTAssertTrue(store.isOpen(.tool(ToolOccurrence.key("second", "call-1"))))
        XCTAssertTrue(store.isOpen(.tool(ToolOccurrence.key("reply", "call-1"))), "The first card is still open")
    }

    func testLegacyRepliesKeepTheirOwnGroupAndSayWhy() {
        let rows = [TranscriptMessage(id: "u", role: "user", text: "Ask"),
                    TranscriptMessage(id: "a", role: "assistant", text: "Answer", thinking: "Reasoning",
                                      tools: [ToolView(id: "t", name: "read", state: "completed", input: "{}", output: "", truncated: false)])]
        let items = TaskTranscriptPlan.items(rows, lifecycle: nil)
        XCTAssertTrue(items.contains { if case .block(let block) = $0 { return block.key.hasPrefix("legacy:") }; return false },
                      "A reply with no recorded order keeps one honest group")
        XCTAssertFalse(items.contains { if case .block(let block) = $0 { return block.presentation == .response }; return false },
                       "Nothing offers to fold a response whose order was never recorded")
    }

    // MARK: The fold

    @MainActor func testFoldStateRoundTripsAndRestoresWhatWasOpenInside() {
        let store = TranscriptDisclosure()
        let items = TaskTranscriptPlan.items(conversation(), lifecycle: nil)
        let reasoning = items.first { if case .block(let block) = $0 { return block.part?.part.kind == "reasoningText" }; return false }!
        let card = items.first { if case .block(let block) = $0 { return block.part?.part.kind == "toolArguments" }; return false }!
        guard case .block(let reasoningBlock) = reasoning else { return XCTFail("reasoning row") }
        // The reader opens the reasoning and the card.
        store.setOpen(true, .work(reasoningBlock.key))
        let cardKey = ToolOccurrence.key("reply", "call-1")
        store.setOpen(true, .tool(cardKey))
        XCTAssertTrue(TranscriptRowDisclosure.of(reasoning, in: store).work)
        XCTAssertTrue(TranscriptRowDisclosure.of(card, in: store).openTools.contains(cardKey))
        // Then folds the whole response: both draw closed, and neither entry
        // is forgotten.
        store.setOpen(true, .response("reply"))
        XCTAssertTrue(TranscriptRowDisclosure.of(reasoning, in: store).responseFolded)
        XCTAssertTrue(store.isOpen(.work(reasoningBlock.key)), "What was open inside is remembered")
        XCTAssertTrue(store.isOpen(.tool(cardKey)))
        // The second level implies the first.
        store.setOpen(true, .responseLine("reply"))
        let collapsed = TranscriptRowDisclosure.of(reasoning, in: store)
        XCTAssertTrue(collapsed.responseLine); XCTAssertTrue(collapsed.responseFolded)
        // Opening the response again restores exactly the response that was folded.
        store.setOpen(false, .responseLine("reply")); store.setOpen(false, .response("reply"))
        XCTAssertEqual(TranscriptRowDisclosure.of(reasoning, in: store), TranscriptRowDisclosure(work: true))
        XCTAssertEqual(TranscriptRowDisclosure.of(card, in: store).openTools, [cardKey])
    }

    @MainActor func testAResponseFoldAsksTheConversationToReconcileEveryRow() {
        let store = TranscriptDisclosure()
        var spanning = 0
        store.spanningChange = { spanning += 1 }
        store.setOpen(true, .work("part:one"))
        store.setOpen(true, .tool("call-1"))
        XCTAssertEqual(spanning, 0, "A fold inside one row is that row's own business")
        store.setOpen(true, .response("reply"))
        store.setOpen(true, .responseLine("reply"))
        XCTAssertEqual(spanning, 2, "A fold that spans rows republishes the page")
        store.setOpen(true, .response("reply"))
        XCTAssertEqual(spanning, 2, "Setting the same state again changes nothing")
    }

    // MARK: Geometry, in a window

    @MainActor private final class Fixture {
        let session: SessionDisplay
        let page: TranscriptPage
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow
        init(messages: [TranscriptMessage], width: CGFloat = 780, height: CGFloat = 560) {
            session = SessionDisplay(id: "chronology")
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
        func row(_ predicate: (TranscriptBlock) -> Bool) -> TranscriptRowContainer? {
            rows.first { if case .block(let block) = $0.item { return predicate(block) }; return false }
        }
        var header: TranscriptRowContainer? { row { $0.presentation == .response } }
        var reasoning: TranscriptRowContainer? { row { $0.part?.part.kind == "reasoningText" } }
        var card: TranscriptRowContainer? { row { $0.part?.part.kind == "toolArguments" } }
        var prose: [TranscriptRowContainer] { rows.filter { if case .block(let block) = $0.item { return block.part?.part.kind == "text" }; return false } }
        /// What a republish does: the document reconciles and every row reads
        /// what the reader has folded.
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

    @MainActor private func assertStacked(_ fixture: Fixture, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var expected: CGFloat?
        for row in fixture.rows {
            if let expected {
                XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5,
                               "\(what): row \(row.itemID) starts at \(row.frame.minY), the row above ends at \(expected)",
                               file: file, line: line)
            }
            expected = row.frame.maxY
        }
    }

    @MainActor func testEachLevelOfTheFoldIsMeasuredInThePassOfTheClick() throws {
        let fixture = Fixture(messages: conversation())
        defer { fixture.close() }
        let header = try XCTUnwrap(fixture.header), reasoning = try XCTUnwrap(fixture.reasoning), card = try XCTUnwrap(fixture.card)
        // Open the reasoning and the card, so folding has something to hide.
        reasoning.toggleDisclosure(.work("part:" + (try XCTUnwrap(reasoningPart(reasoning)))))
        card.toggleDisclosure(.tool(ToolOccurrence.key("reply", "call-1")))
        fixture.refresh()
        let open = (header: header.frame.height, reasoning: reasoning.frame.height, card: card.frame.height,
                    prose: fixture.prose.map(\.frame.height), document: fixture.document.frame.height)
        XCTAssertGreaterThan(open.reasoning, 30, "Open reasoning shows its text")
        assertStacked(fixture, "open")

        // Level one: everything inside the response folds. The click is the
        // real path — the control calls this on the header row.
        header.toggleDisclosure(.response("reply"))
        fixture.refresh()
        XCTAssertLessThan(reasoning.frame.height, open.reasoning, "Folded reasoning is its header line")
        XCTAssertLessThan(card.frame.height, open.card, "The card folds with the response")
        XCTAssertEqual(fixture.prose.map(\.frame.height), open.prose, "The reply's own words stay")
        XCTAssertLessThan(fixture.document.frame.height, open.document)
        assertStacked(fixture, "contents folded")
        let folded = fixture.document.frame.height

        // Level two: the response reads as one line.
        header.toggleDisclosure(.responseLine("reply"))
        fixture.refresh()
        XCTAssertLessThan(fixture.document.frame.height, folded, "One line is shorter than the folded response")
        for row in fixture.prose + [reasoning, card] {
            XCTAssertLessThan(row.frame.height, 4, "A row of a response folded to one line draws nothing")
        }
        XCTAssertGreaterThan(header.frame.height, 10, "The one line is the header line")
        assertStacked(fixture, "one line")

        // And opening it again restores the response exactly.
        header.toggleDisclosure(.responseLine("reply"))
        header.toggleDisclosure(.response("reply"))
        fixture.refresh()
        XCTAssertEqual(reasoning.frame.height, open.reasoning, accuracy: 0.5, "The reasoning the reader had open is open again")
        XCTAssertEqual(card.frame.height, open.card, accuracy: 0.5)
        XCTAssertEqual(fixture.document.frame.height, open.document, accuracy: 0.5)
        assertStacked(fixture, "restored")
    }
    @MainActor private func reasoningPart(_ row: TranscriptRowContainer) -> String? {
        guard case .block(let block) = row.item, let part = block.part else { return nil }
        return part.id
    }

    @MainActor func testReasoningUpdatesWhileOpenAndWhileCollapsed() throws {
        let fixture = Fixture(messages: conversation(streaming: true))
        defer { fixture.close() }
        fixture.page.presentationInterval = 0
        let row = try XCTUnwrap(fixture.reasoning)
        row.toggleDisclosure(.work("part:" + (try XCTUnwrap(reasoningPart(row)))))
        fixture.refresh()
        let initialHeight = row.frame.height
        var next = conversation(streaming: true)
        next[1].responseTimeline?.segments[2].text += String(repeating: "\n\nChecking the next case in detail.", count: 12)
        next[1].responseTimeline?.segments[2].revision += 1
        fixture.session.messages = next
        fixture.refresh()
        XCTAssertGreaterThan(row.frame.height, initialHeight, "Expanded reasoning must lay out the text that arrived")

        row.toggleDisclosure(.work("part:" + (try XCTUnwrap(reasoningPart(row)))))
        fixture.refresh()
        let closedHeight = row.frame.height
        var block = try XCTUnwrap({ if case .block(let value) = row.item { return value }; return nil }())
        block.part?.text += "\nChecking the final case."
        block.part?.revision += 1
        TranscriptLayoutClock.recording = true
        defer { TranscriptLayoutClock.recording = false }
        let roots = TranscriptLayoutClock.rootUpdates
        XCTAssertFalse(row.update(item: .block(block), fresh: false, actions: TranscriptActions()),
                       "The collapsed summary retains its height")
        XCTAssertGreaterThan(TranscriptLayoutClock.rootUpdates, roots, "Its latest-line summary must still update")
        XCTAssertEqual(row.frame.height, closedHeight)
    }

    @MainActor func testOpenToolCardReflowsAsItsOutputGrows() throws {
        let fixture = Fixture(messages: conversation(streaming: true))
        defer { fixture.close() }
        fixture.page.presentationInterval = 0
        let row = try XCTUnwrap(fixture.card)
        row.toggleDisclosure(.tool(ToolOccurrence.key("reply", "call-1")))
        fixture.refresh()
        let initialHeight = row.frame.height
        var next = conversation(streaming: true)
        next[1].tools?[0].output += String(repeating: "\nAnother test case passed.", count: 6)
        fixture.session.messages = next
        fixture.refresh()
        XCTAssertGreaterThan(row.frame.height, initialHeight, "An open card must adopt new output even when the call's state did not change")
    }

    @MainActor func testTheFoldSurvivesStreamingAndAChatSwitch() throws {
        let fixture = Fixture(messages: conversation(streaming: true))
        defer { fixture.close() }
        let header = try XCTUnwrap(fixture.header)
        header.toggleDisclosure(.response("reply"))
        fixture.refresh()
        let folded = try XCTUnwrap(fixture.reasoning).frame.height
        // More of the reply arrives, and the row it arrives in grows.
        var next = conversation(streaming: true)
        next[1].responseTimeline?.segments[3].text += " Then a little more."
        next[1].responseTimeline?.segments[3].revision += 1
        next[1].text += " Then a little more."
        fixture.session.messages = next
        fixture.refresh()
        XCTAssertEqual(try XCTUnwrap(fixture.reasoning).frame.height, folded, accuracy: 0.5,
                       "A token cannot unfold what the reader folded")
        XCTAssertTrue(fixture.session.disclosure.isOpen(.response("reply")))
        // The reply settles under the same id.
        fixture.session.messages = conversation()
        fixture.refresh()
        XCTAssertTrue(fixture.session.disclosure.isOpen(.response("reply")), "Settling is not a reason to unfold")
        XCTAssertEqual(try XCTUnwrap(fixture.reasoning).frame.height, folded, accuracy: 0.5)
        // The reader leaves for another chat and comes back: the fold belongs
        // to the conversation, so it is still there.
        let other = SessionDisplay(id: "other")
        other.messages = [TranscriptMessage(id: "x", role: "user", text: "Elsewhere")]
        fixture.page.bind(other)
        fixture.document.update(snapshot: fixture.page.snapshot, actions: TranscriptActions(),
                                environment: TranscriptRowEnvironment(), disclosure: other.disclosure)
        fixture.page.bind(fixture.session)
        fixture.refresh()
        XCTAssertTrue(fixture.session.disclosure.isOpen(.response("reply")))
        XCTAssertEqual(try XCTUnwrap(fixture.reasoning).frame.height, folded, accuracy: 0.5)
    }

    @MainActor func testFoldingOneReasoningSegmentMovesTheRowsBelowInStep() throws {
        let fixture = Fixture(messages: conversation())
        defer { fixture.close() }
        let reasoning = try XCTUnwrap(fixture.reasoning)
        let part = try XCTUnwrap(reasoningPart(reasoning))
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let before = fixture.rows.map(\.frame.minY)
        reasoning.toggleDisclosure(.work("part:" + part))
        XCTAssertTrue(fixture.document.isMovingDisclosure, "Opening a part inside a response moves the page")
        var heights: [CGFloat] = []
        for tick in 1...5 {
            fixture.document.advanceDisclosureMotion(to: Double(tick) / 5)
            heights.append(reasoning.frame.height)
            assertStacked(fixture, "tick \(tick)")
        }
        XCTAssertEqual(heights, heights.sorted(), "The row grows towards its measured height, never past it")
        fixture.document.finishDisclosureMotion()
        fixture.refresh()
        XCTAssertGreaterThan(reasoning.frame.height, 30)
        XCTAssertNotEqual(fixture.rows.map(\.frame.minY), before, "The rows below moved with it")
        assertStacked(fixture, "settled")
    }

    // MARK: The keyboard

    @MainActor func testTheFoldCommandsDriveTheSameParts() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SessionDisplay(id: "keys")
        session.messages = conversation()
        model.displays = [session.id: session]
        model.focusedSessionID = session.id
        XCTAssertTrue(model.canFoldResponses)
        XCTAssertEqual(WorkspaceModel.responseIDs(in: session.presentedMessages), ["reply"])
        XCTAssertEqual(WorkspaceModel.focusedResponse(holding: nil, in: session.presentedMessages), "reply")
        model.setFocusedTurnFolded(true)
        XCTAssertTrue(session.disclosure.isOpen(.response("reply")), "⌥⌘[ folds the focused response")
        model.setFocusedTurnFolded(false)
        XCTAssertFalse(session.disclosure.isOpen(.response("reply")))
        model.setEveryTurnFolded(true)
        XCTAssertTrue(session.disclosure.isOpen(.response("reply")), "⇧⌥⌘[ folds every response")
        model.setFocusedResponseCollapsed(true)
        XCTAssertTrue(session.disclosure.isOpen(.responseLine("reply")))
        model.setFocusedResponseCollapsed(false)
        XCTAssertFalse(session.disclosure.isOpen(.responseLine("reply")))
        XCTAssertFalse(session.disclosure.isOpen(.response("reply")), "Showing a response again leaves nothing folded")
    }
}
