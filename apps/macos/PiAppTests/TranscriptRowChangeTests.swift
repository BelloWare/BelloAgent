import XCTest
import SwiftUI
@testable import PiApp

/// What an update does to a row, decided from the row as it stands and what
/// it is handed, before anything about the row changes.
final class TranscriptRowChangeTests: XCTestCase {
    private typealias Row = TranscriptRowContainer
    private let closed = TranscriptRowContainer.Look(disclosure: .default, environment: TranscriptRowEnvironment(), fresh: false)

    /// A reply still arriving, whose timeline holds prose, reasoning and a
    /// call's card, in that order.
    private func reply(answer: String = "Answer", reasoning: String = "Thinking", arguments: String = "{\"command\":",
                       callState: String = "preparing") -> TranscriptMessage {
        var timeline = ResponseTimeline()
        timeline.consume(ResponsePartEvent(attemptID: "attempt", ordinal: 0, itemID: "0", kind: "text", update: "append", text: answer))
        timeline.consume(ResponsePartEvent(attemptID: "attempt", ordinal: 1, itemID: "1", kind: "reasoningSummary", update: "append", text: reasoning))
        timeline.consume(ResponsePartEvent(attemptID: "attempt", ordinal: 2, itemID: "2", kind: "toolArguments", update: "append",
                                           text: arguments, callID: "call-1", name: "bash"))
        var message = TranscriptMessage(id: "reply", role: "assistant", text: answer, state: "streaming")
        message.responseTimeline = timeline
        message.tools = [ToolView(id: "call-1", name: "bash", state: callState, input: arguments, output: "", durationMs: nil, truncated: false)]
        return message
    }
    /// The row of a reply's plan that draws the part of this kind.
    private func part(_ kind: String, of message: TranscriptMessage) throws -> TranscriptItem {
        try XCTUnwrap(TaskTranscriptPlan.items([message], lifecycle: nil).first { item in
            if case .block(let block) = item { return block.part?.part.kind == kind }
            return false
        }, "No \(kind) row")
    }
    /// A reply without a timeline: its calls are one aggregate work list.
    private func workList(output: String) throws -> TranscriptItem {
        let tool = ToolView(id: "call-1", name: "bash", state: "done", input: "{}", output: output, durationMs: 40, truncated: false)
        let message = TranscriptMessage(id: "legacy", role: "assistant", text: "", tools: [tool])
        return try XCTUnwrap(TaskTranscriptPlan.items([message], lifecycle: nil).first { item in
            if case .block(let block) = item { return block.presentation == .work && block.part == nil }
            return false
        }, "No work list")
    }

    /// A reply without a timeline, still arriving: one body row of prose.
    private func body(_ text: String) throws -> TranscriptItem {
        let message = TranscriptMessage(id: "body", role: "assistant", text: text, state: "streaming")
        return try XCTUnwrap(TaskTranscriptPlan.items([message], lifecycle: nil).first { item in
            if case .block(let block) = item { return block.presentation == .body }
            return false
        }, "No body")
    }

    func testWhatAnUpdateDoesToARow() throws {
        func change(_ old: TranscriptItem, _ was: Row.Look, _ new: TranscriptItem, _ now: Row.Look,
                    tree: Bool = true, moving: Bool = false) -> Row.Change {
            Row.change(from: old, was, to: new, now, sameItem: old == new, hasTree: tree, inMotion: moving)
        }
        let old = try body("Hello"), new = try body("Hello there")
        XCTAssertEqual(change(old, closed, old, closed), .none)
        var dark = closed; dark.environment.colorScheme = .dark
        XCTAssertEqual(change(old, closed, old, dark), .repaint, "A colour is paint: every height stays")
        var larger = closed; larger.environment.dynamicTypeSize = .xxLarge
        XCTAssertEqual(change(old, closed, old, larger), .settled(.remeasure), "A type size is geometry")
        XCTAssertEqual(change(old, closed, new, closed), .streamed(TranscriptStreamingTail.Append(messageID: "body", text: "Hello there")),
                       "A token goes to the reply's own surface")
        XCTAssertEqual(change(old, closed, new, closed, tree: false), .unseenGrowth, "A row with no tree stands at an estimate")
        XCTAssertEqual(change(old, closed, new, closed, moving: true), .settled(.remeasure), "A row being moved takes no token through its surface")
        var fresh = closed; fresh.fresh = true
        XCTAssertEqual(change(old, closed, new, fresh), .settled(.remeasure), "A token with anything else is measured again")
        let reasoning = try part("reasoningSummary", of: reply()), more = try part("reasoningSummary", of: reply(reasoning: "Thinking further"))
        XCTAssertEqual(change(reasoning, closed, more, closed), .settled(.closedPart), "Reasoning arrives in its closed line, not the reply's surface")
        let work = try workList(output: "one"), moreWork = try workList(output: "one\ntwo")
        XCTAssertEqual(change(work, closed, moreWork, closed), .settled(.closedWork))
    }

    func testAClosedPartKeepsItsHeightWhileItsTextArrives() throws {
        let old = try part("reasoningSummary", of: reply())
        let new = try part("reasoningSummary", of: reply(reasoning: "Thinking further"))
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(Row.closedPartKeepsHeight(from: old, closed, to: new, closed))
        var open = closed; open.disclosure.work = true
        XCTAssertFalse(Row.closedPartKeepsHeight(from: old, open, to: new, open), "An open part grows with its text")
        var cardOpen = closed; cardOpen.disclosure.openTools = ["call-1"]
        XCTAssertFalse(Row.closedPartKeepsHeight(from: old, cardOpen, to: new, cardOpen), "Nothing may be open in the row")
        var fresh = closed; fresh.fresh = true
        XCTAssertFalse(Row.closedPartKeepsHeight(from: old, closed, to: new, fresh), "Anything else about the row changing measures it again")
        var larger = closed; larger.environment.dynamicTypeSize = .xxLarge
        XCTAssertFalse(Row.closedPartKeepsHeight(from: old, closed, to: new, larger))
        let prose = try part("text", of: reply()), longer = try part("text", of: reply(answer: "Answer and more"))
        XCTAssertFalse(Row.closedPartKeepsHeight(from: prose, closed, to: longer, closed), "Prose is never one line")
    }

    func testAClosedCardKeepsItsHeightWhileItsArgumentsArrive() throws {
        let old = try part("toolArguments", of: reply())
        guard case .block(let block) = old else { return XCTFail("Not a block") }
        XCTAssertEqual(block.presentation, .work, "A call with a card is a work row in the response's order")
        let more = try part("toolArguments", of: reply(arguments: "{\"command\":\"ls"))
        XCTAssertTrue(Row.closedPartKeepsHeight(from: old, closed, to: more, closed))
        let running = try part("toolArguments", of: reply(arguments: "{\"command\":\"ls", callState: "running"))
        XCTAssertFalse(Row.closedPartKeepsHeight(from: old, closed, to: running, closed), "A call in another state says something else on its line")
    }

    func testAClosedWorkListKeepsItsHeightWhileItsCallsChange() throws {
        let old = try workList(output: "one"), new = try workList(output: "one\ntwo")
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(Row.closedWorkKeepsHeight(from: old, closed, to: new, closed))
        var open = closed; open.disclosure.work = true
        XCTAssertFalse(Row.closedWorkKeepsHeight(from: old, open, to: new, open), "An open work list grows with its calls")
        var fresh = closed; fresh.fresh = true
        XCTAssertFalse(Row.closedWorkKeepsHeight(from: old, closed, to: new, fresh))
        let card = try part("toolArguments", of: reply()), moreCard = try part("toolArguments", of: reply(arguments: "{\"command\":\"ls"))
        XCTAssertFalse(Row.closedWorkKeepsHeight(from: card, closed, to: moreCard, closed), "A timeline's card is not an aggregate work list")
    }
}
