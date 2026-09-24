import XCTest
import SwiftUI
@testable import PiApp

/// A reply as the helper streams it today. Every live reply carries a response
/// timeline, so its words reach the page as a text part row that holds them
/// twice — in the row's message and in its timeline segment, beside that
/// segment's revision. A token must still take the page's two fast paths:
/// extend the reply's own native surface while the reader watches it arrive,
/// and stand the row at an estimate of its growth while the reader is reading
/// somewhere else. Neither may rebuild the row's SwiftUI tree, and nothing may
/// build a tree for a row nobody can see.
final class TimelineStreamingFastPathTests: XCTestCase {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    /// The reply, as the helper builds it: reasoning that finished first, then
    /// its words arriving as "append" events on one text part of its timeline,
    /// with the message's own text the same words.
    struct LiveReply {
        private(set) var message: TranscriptMessage
        private var ordinal = 0
        init(id: String, turn: String) {
            message = TranscriptMessage(id: id, role: "assistant", text: "", state: "streaming", turn: turn)
            message.responseTimeline = ResponseTimeline()
            consume(kind: "reasoningText", update: "replace", text: "Where does the retry live?", output: 0)
        }
        mutating func append(_ token: String) {
            message.text += token
            consume(kind: "text", update: "append", text: token, output: 1)
        }
        private mutating func consume(kind: String, update: String, text: String, output: Int) {
            message.responseTimeline?.consume(ResponsePartEvent(attemptID: "attempt-" + message.id, ordinal: ordinal,
                                                                itemID: "\(message.id)-item-\(output)", outputIndex: output,
                                                                partIndex: 0, kind: kind, update: update, text: text,
                                                                callID: nil, name: nil))
            ordinal += 1
        }
    }

    /// Plain prose, so what the row shows can be read back word for word.
    static let prose = (0..<10).map { paragraph in
        (0..<4).map { sentence in
            "The retry loop waits \(paragraph * 4 + sentence) seconds before attempt number \(sentence + 1), and it logs why the last one failed."
        }.joined(separator: " ")
    }.joined(separator: "\n\n")

    // MARK: The rule itself

    /// The reply's text part row, as the planner builds it for one state of the reply.
    private func textRow(_ message: TranscriptMessage) -> TranscriptBlock? {
        for case .block(let block) in TaskTranscriptPlan.rows([message], lifecycle: nil) where block.part?.part.kind == "text" {
            return block
        }
        return nil
    }

    func testATokenOnATimelinePartIsAnAppendAndNothingElseIs() throws {
        var reply = LiveReply(id: "a1", turn: "u1")
        reply.append("The loop retries")
        let before = try XCTUnwrap(textRow(reply.message))
        reply.append(" three times.")
        let after = try XCTUnwrap(textRow(reply.message))
        XCTAssertNotEqual(before.part?.revision, after.part?.revision, "the fixture is the helper's: a token moves the segment's revision")
        // The row holds the words in its message and in its segment, and the
        // segment's revision moved: none of that is anything but the token.
        let append = try XCTUnwrap(TranscriptStreamingTail.append(from: .block(before), to: .block(after)),
                                   "a token on a timeline reply must be answered by extending the reply's surface")
        XCTAssertEqual(append.messageID, "a1")
        XCTAssertEqual(append.text, "The loop retries three times.")
        XCTAssertTrue(TranscriptStreamingTail.textGrew(from: .block(before), to: .block(after)))

        // Anything else that changes with it is not a token.
        func changed(_ change: (inout TranscriptBlock) -> Void) -> TranscriptItem {
            var block = after; change(&block); return .block(block)
        }
        XCTAssertNil(TranscriptStreamingTail.append(from: .block(before), to: changed { $0.part?.state = "continued" }),
                     "a part that stopped streaming is not a token")
        XCTAssertNil(TranscriptStreamingTail.append(from: .block(before), to: changed { $0.part?.text = "Something else entirely, and longer." }),
                     "a segment that did not grow by appending is not a token")
        XCTAssertNil(TranscriptStreamingTail.append(from: .block(before), to: changed { $0.part?.truncated = true }),
                     "a segment whose other fields changed is not a token")
        XCTAssertNil(TranscriptStreamingTail.append(from: .block(before), to: changed { $0.live = false }),
                     "a row that changed otherwise is not a token")

        // A message that carries its whole timeline beside its text grows by
        // a token too, as long as the timeline only grew by that token.
        func segment(_ id: String, _ text: String, revision: Int) -> ResponseTimeline.Segment {
            ResponseTimeline.Segment(id: id, part: ResponsePartEvent(attemptID: "x", ordinal: 0, itemID: id, outputIndex: 0, partIndex: 0,
                                                                     kind: "text", update: "append", text: "", callID: nil, name: nil),
                                     text: text, revision: revision)
        }
        var legacy = TranscriptMessage(id: "b1", role: "assistant", text: "Hello", state: "streaming", turn: "u1")
        var timeline = ResponseTimeline()
        timeline.segments = [segment("x", "Hello", revision: 1), segment("y", "", revision: 0)]
        legacy.responseTimeline = timeline
        var grown = legacy
        grown.text = "Hello there"
        grown.responseTimeline?.segments[0].text = "Hello there"
        grown.responseTimeline?.segments[0].revision = 2
        XCTAssertNotNil(TranscriptStreamingTail.append(from: .message(legacy), to: .message(grown)),
                        "a message whose timeline only grew by the same token is a token")
        grown.responseTimeline?.segments[1].state = "completed"
        XCTAssertNil(TranscriptStreamingTail.append(from: .message(legacy), to: .message(grown)),
                     "a message whose timeline changed otherwise is not a token")
    }

    // MARK: The page

    struct Run {
        var frames: [Double] = []
        /// A frame's parts: the session taking the token (the page reads it
        /// synchronously), the pane's layout (where the row takes the token
        /// and the page places itself), and the window's display pass.
        var models: [Double] = [], layouts: [Double] = [], displays: [Double] = []
        var appends = 0, estimates = 0, rebuilds = 0, hostBuilds = 0, rootUpdates = 0, sizingPasses = 0, measuredRows = 0
        /// Times the page or the document hashed every row's id: a token keeps them all.
        var identityWalks = 0
        /// Inside the pane's layout, in seconds over the run: the document
        /// taking the snapshot (the reply's row taking its token among it),
        /// placing its rows, the reply's own surface reading and measuring the
        /// block a token changed, and rows rebuilt, sized and measured again.
        var documentUpdate = 0.0, documentLayout = 0.0, surface = 0.0, rebuilding = 0.0
        /// Frames after which the watched row held a SwiftUI tree.
        var watchedRowHosted = 0
        var mean: Double { frames.isEmpty ? 0 : frames.reduce(0, +) / Double(frames.count) }
        static func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
        var line: String {
            let n = Double(max(1, frames.count))
            return String(format: "%d tokens — mean %.2f ms, median %.2f ms a frame (medians: the model %.2f, the pane's layout %.2f, display %.2f ms; per token inside the layout: the document taking the snapshot %.2f ms, placing rows %.2f ms, the reply's surface %.2f ms, rebuilding and measuring rows %.2f ms); %d extended the reply's surface, %d stood it at an estimate, %d rebuilt the row; %d row trees built, %d root rebuilds, %d SwiftUI sizing passes, %d rows measured",
                          frames.count, mean * 1000, Self.median(frames) * 1000, Self.median(models) * 1000, Self.median(layouts) * 1000,
                          Self.median(displays) * 1000, documentUpdate * 1000 / n, documentLayout * 1000 / n, surface * 1000 / n, rebuilding * 1000 / n,
                          appends, estimates, rebuilds, hostBuilds, rootUpdates, sizingPasses, measuredRows)
        }
    }

    /// Streams `tokens` into the reply, one presented frame per token. The
    /// pane's SwiftUI update can hand a token to the document a run-loop turn
    /// after the frame it arrived in, so what the last one leaves behind is
    /// collected too, from one more frame with no token in it.
    @MainActor private func stream(_ tokens: [String], into reply: inout LiveReply, pane: Pane,
                                   watching row: TranscriptRowContainer? = nil) async -> Run {
        let session = pane.session
        guard let index = session.messages.lastIndex(where: { $0.id == reply.message.id }) else { return Run() }
        var run = Run()
        TranscriptLayoutClock.recording = true
        defer { TranscriptLayoutClock.recording = false }
        func collect() {
            run.appends += TranscriptLayoutClock.streamingAppends
            run.estimates += TranscriptLayoutClock.streamingEstimates
            run.rebuilds += TranscriptLayoutClock.streamingRebuilds
            run.hostBuilds += TranscriptLayoutClock.hostBuilds
            run.rootUpdates += TranscriptLayoutClock.rootUpdates
            run.sizingPasses += TranscriptLayoutClock.rowSizingPasses
            run.measuredRows += TranscriptLayoutClock.measuredRows
            run.identityWalks += TranscriptLayoutClock.identityWalks
            run.documentUpdate += TranscriptLayoutClock.updateSeconds
            run.documentLayout += TranscriptLayoutClock.layoutSeconds
            run.surface += TranscriptLayoutClock.markdownUpdateSeconds + TranscriptLayoutClock.markdownLayoutSeconds
            // A host built to measure a row is inside its measurement.
            run.rebuilding += TranscriptLayoutClock.rootUpdateSeconds + TranscriptLayoutClock.measureSeconds
        }
        for (count, token) in tokens.enumerated() {
            TranscriptLayoutClock.reset()
            let start = ProcessInfo.processInfo.systemUptime
            reply.append(token)
            session.messages[index] = reply.message
            let modelled = ProcessInfo.processInfo.systemUptime
            pane.hosted.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime
            pane.window.displayIfNeeded()
            let shown = ProcessInfo.processInfo.systemUptime
            run.frames.append(shown - start)
            run.models.append(modelled - start); run.layouts.append(laidOut - modelled); run.displays.append(shown - laidOut)
            collect()
            if row?.isHosted == true { run.watchedRowHosted += 1 }
            await Task.yield()
            if count % 8 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        TranscriptLayoutClock.reset()
        pane.hosted.layoutSubtreeIfNeeded()
        pane.window.displayIfNeeded()
        collect()
        return run
    }

    /// A gesture, the way AppKit reports one.
    @MainActor private func readerMoves(_ pane: Pane, to y: CGFloat) async throws {
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView)
        let clip = scroll.contentView
        scroll.readerWillNavigate(upward: y < clip.bounds.minY)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pane.settle(turns: 6)
    }

    @MainActor private func shows(_ row: TranscriptRowContainer, _ word: String) -> Bool {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) } }
        return fields(row).contains { $0.stringValue.contains(word) }
    }

    @MainActor func testATimelineReplyTakesTheStreamingFastPaths() async throws {
        let rows = 80
        let session = TranscriptFrameBudgetTests.chat("timeline-stream", rows: rows)
        let last = TranscriptFrameBudgetTests.lastUserID(rows: rows)
        let pane = Pane(session, state: "running"); defer { pane.close() }
        let ready = await pane.waitForRow(last, seconds: 120)
        XCTAssertTrue(ready, "the chat never appeared")
        await pane.settleUntilExact()
        let page = try XCTUnwrap(pane.page)
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView)
        let document = try XCTUnwrap(pane.document)
        // Every token is presented, so a frame here is a token reaching the screen.
        page.presentationInterval = 0
        let tokens = TranscriptStreamingScrollTests.tokens(of: Self.prose)
        XCTAssertGreaterThan(tokens.count, 120)
        var reply = LiveReply(id: "live-reply", turn: last)
        reply.append(tokens[0])
        session.messages.append(reply.message)
        await pane.settle(turns: 6)
        // One token so the row is no longer new: its fresh accent clearing is
        // a change of its own, not a token's.
        _ = await stream([tokens[1]], into: &reply, pane: pane)
        await pane.settle(turns: 4)
        func replyRow() -> TranscriptRowContainer? {
            document.retainedRows.first { row in
                if case .block(let block) = row.item { return block.part?.part.kind == "text" && block.message?.id == "live-reply" }
                return false
            }
        }
        XCTAssertNotNil(replyRow(), "the reply's words are a text part row of its timeline")
        XCTAssertTrue(page.atBottom, "the reader is watching the reply arrive")
        func newestWord() -> String { reply.message.text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).last.map(String.init) ?? "" }

        // The reader watches the reply arrive: fewer tokens than the row's own
        // periodic re-measurement, so every one of them is a plain token.
        let row = try XCTUnwrap(replyRow())
        var appended = row.streamingAppendCount, measured = row.measurementCount
        let watched = Array(tokens[2..<50])
        let watching = await stream(watched, into: &reply, pane: pane)
        print("PERF a timeline reply arriving under a still reader, \(rows)-row chat: \(watching.line)")
        XCTAssertEqual(row.streamingAppendCount - appended, watched.count, "every token must extend the reply's own surface")
        XCTAssertEqual(row.measurementCount - measured, 0, "a token rebuilt and re-measured the reply's row")
        XCTAssertGreaterThan(watching.appends, 0)
        XCTAssertEqual(watching.rebuilds, 0, "a token rebuilt the reply's row")
        XCTAssertEqual(watching.hostBuilds, 0, "a token built a row's tree")
        XCTAssertEqual(watching.identityWalks, 0, "a token hashed every row's id again, though it keeps them all")
        XCTAssertTrue(page.atBottom, "the page followed the reply")
        await pane.settle(turns: 4)
        XCTAssertTrue(replyRow() === row, "the reply keeps its row")
        XCTAssertTrue(shows(row, newestWord()), "the reply's row must show its newest words (\(newestWord()))")

        // The reader goes back to the top of the chat, far from the reply.
        try await readerMoves(pane, to: 0)
        XCTAssertFalse(page.atBottom)
        XCTAssertFalse(row.isHosted, "the fixture must put the reply far enough away that its tree is released")
        let top = scroll.contentView.bounds.minY
        let screens = Int((row.frame.minY - top) / max(1, scroll.contentView.bounds.height))
        appended = row.streamingAppendCount; measured = row.measurementCount
        let away = Array(tokens[50..<98])
        let reading = await stream(away, into: &reply, pane: pane, watching: row)
        print("PERF a timeline reply arriving \(screens) screens below the reader: \(reading.line)")
        XCTAssertGreaterThan(reading.estimates, 0, "a reply nobody can see must stand at an estimate of its growth")
        XCTAssertEqual(reading.watchedRowHosted, 0, "a token built a tree for the reply nobody can see")
        // Per token, that is: between tokens the idle scheduler may measure a
        // row that stands at an estimate, which is what it is there for.
        XCTAssertEqual(reading.measuredRows, 0, "a token measured a row nobody can see")
        XCTAssertLessThan(row.measurementCount - measured, away.count / 4, "the reply was measured about once a token")
        XCTAssertEqual(reading.hostBuilds, 0, "a token built a row's tree")
        XCTAssertEqual(reading.identityWalks, 0, "a token hashed every row's id again, though it keeps them all")
        XCTAssertEqual(reading.rebuilds, 0, "a token rebuilt a row nobody can see")
        XCTAssertEqual(reading.sizingPasses, 0, "a token put a row through SwiftUI's sizing")
        XCTAssertEqual(scroll.contentView.bounds.minY, top, accuracy: 0.5, "the reply growing far below moved the reader")

        // Coming back, the reply is measured for real and shows every word.
        try await readerMoves(pane, to: max(0, document.frame.height - scroll.contentView.bounds.height))
        await pane.settleUntilExact()
        await pane.settle(turns: 4)
        let back = try XCTUnwrap(replyRow())
        XCTAssertTrue(back.isHosted, "the reader is back at the reply")
        XCTAssertTrue(shows(back, newestWord()), "the reply's row must show the words that arrived while the reader was away (\(newestWord()))")
        XCTAssertEqual(page.snapshot?.messages.last?.text, reply.message.text, "the page ends holding the whole reply")
    }
}
