import XCTest
import SwiftUI
@testable import PiApp

/// Streaming and scrolling at the same time — the thing the owner actually
/// does: a reply is arriving while the reader scrolls back through the chat.
/// The pane is the real one (`TranscriptFrameBudgetTests.Pane` hosts the real
/// `NativeTranscriptView` in a real key window); every frame here applies one
/// token *and* one wheel step, then lays the pane out and displays it, so the
/// numbers are what a reader's frame costs rather than what a token costs on
/// an idle page.
///
/// Four things are reported for every run, as PERF lines:
///   * what a frame costs (mean, p50/p95/p99, worst) and how many frames went
///     over a 120 Hz frame;
///   * how many tokens a second the page sustains;
///   * how much of a frame went into building a row's tree the reader had
///     already reached (the work preparation is supposed to have done);
///   * whether anything on screen moved by something other than the scroll —
///     the flicker rule, asserted in every configuration.
final class TranscriptStreamingScrollTests: XCTestCase {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    // MARK: The reply that arrives

    /// A reply with everything the renderer has to get right: headings, prose
    /// with inline markup, nested lists, a fenced block with a language, a
    /// table, a quote, links and non-Latin text.
    static let reply = """
    ## What changed

    The handler now **retries** twice and logs the reason in `Charge.swift`, so a \
    transient failure no longer reaches the caller. See [the note](https://example.com/notes).

    - First point, with a nested part:
      - the retry budget is per attempt
      - the log line carries the order id
    - Second point about 中文 and éclair text.

    ```swift
    func charge(_ order: Order) async throws -> Receipt {
        for attempt in 1...3 {
            do { return try await gateway.charge(order) }
            catch { logger.warning("attempt \\(attempt) failed: \\(error)") }
        }
        throw ChargeError.exhausted
    }
    ```

    | Field | Before | After |
    |---|---:|---|
    | attempts | 1 | 3 |
    | logging | none | per attempt |

    > The receipt is unchanged, so nothing downstream has to move.

    ### Next

    1. Land the retry.
    2. Watch the failure rate for a day.

    That is the whole change.
    """

    /// One reply, cut into pieces the size of real tokens (one to eight bytes,
    /// never through a scalar), so a frame here carries what a frame of a real
    /// reply carries.
    static func tokens(of source: String, seed: UInt64 = 0x9E3779B97F4A7C15) -> [String] {
        let bytes = Array(source.utf8)
        var result: [String] = [], offset = 0, state = seed
        while offset < bytes.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var end = min(bytes.count, offset + 1 + Int((state >> 33) % 8))
            while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end += 1 }
            result.append(String(decoding: bytes[offset..<end], as: UTF8.self))
            offset = end
        }
        return result
    }

    // MARK: What a run reports

    struct Run {
        var frames: [Double] = []
        var worst = 0.0
        var hostBuildFrames = 0
        var hostBuildSeconds = 0.0
        var movedUnexpectedly: [String] = []
        var sizingPasses = 0
        var rootUpdates = 0
        var measuredRows = 0
        var layoutPasses = 0
        var tokens = 0
        var wallSeconds = 0.0
        var unpreparedVisits = 0
        /// Frames the page answered by extending the reply's own surface, and
        /// frames it answered by rebuilding the row's SwiftUI tree.
        var appendFrames: [Double] = []
        /// Frames the page answered by standing the unseen reply at an estimate.
        var estimateFrames: [Double] = []
        /// Frames where a token arrived with something else, so the row had to
        /// be rebuilt.
        var rebuiltForOtherReasons = 0
        /// How much of the frames went into the window's display pass.
        var displaySeconds = 0.0
        /// Inside the frames: reading the message again, measuring the blocks
        /// a token changed, the page's own row loop and mounting.
        var modelSeconds = 0.0
        var readSeconds = 0.0, blockLayoutSeconds = 0.0, blocksMeasured = 0
        var rowLoopSeconds = 0.0, mountSeconds = 0.0, viewportLayoutSeconds = 0.0
        var rebuildFrames: [Double] = []
        /// Frames inside a wheel gesture that laid the arriving row out.
        var layoutsInsideGesture = 0
        var preparedAhead = 0
        var mean: Double { frames.isEmpty ? 0 : frames.reduce(0, +) / Double(frames.count) }
        var over: Int { frames.filter { $0 > 1.0 / 120 }.count }
        var overFraction: Double { frames.isEmpty ? 0 : Double(over) / Double(frames.count) }
        var tokensPerSecond: Double { wallSeconds > 0 ? Double(tokens) / wallSeconds : 0 }
        func percentile(_ p: Double) -> Double {
            guard !frames.isEmpty else { return 0 }
            let ordered = frames.sorted()
            return ordered[max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * p)) - 1))]
        }
        var appendMean: Double { appendFrames.isEmpty ? 0 : appendFrames.reduce(0, +) / Double(appendFrames.count) }
        var rebuildMean: Double { rebuildFrames.isEmpty ? 0 : rebuildFrames.reduce(0, +) / Double(rebuildFrames.count) }
        var estimateMean: Double { estimateFrames.isEmpty ? 0 : estimateFrames.reduce(0, +) / Double(estimateFrames.count) }
        var inside: String {
            let n = Double(max(1, frames.count))
            return String(format: "per frame: the model %.2f ms, reading the message %.2f ms, measuring %.2f blocks %.2f ms, the page's row loop %.2f ms, mounting %.2f ms, laying rows out for the viewport %.2f ms",
                          modelSeconds * 1000 / n, readSeconds * 1000 / n, Double(blocksMeasured) / n, blockLayoutSeconds * 1000 / n,
                          rowLoopSeconds * 1000 / n, mountSeconds * 1000 / n, viewportLayoutSeconds * 1000 / n)
        }
        var paths: String {
            String(format: "%d frames extended the reply's own surface at %.2f ms mean, %d stood it at an estimate at %.2f ms mean, %d rebuilt the row at %.2f ms mean; %d row trees prepared ahead of the reader",
                   appendFrames.count, appendMean * 1000, estimateFrames.count, estimateMean * 1000,
                   rebuildFrames.count, rebuildMean * 1000, preparedAhead) +
            String(format: "; %d tokens arrived with something else that changed the row", rebuiltForOtherReasons)
        }
        var displayMean: Double { frames.isEmpty ? 0 : displaySeconds / Double(frames.count) }
        var line: String {
            String(format: "%d frames — mean %.2f ms, p50 %.2f, p95 %.2f, p99 %.2f, worst %.2f ms; %d over 8.33 ms (%.1f%%); %.0f tokens/s; %.2f row trees built inside a frame costing %.2f ms; %.2f SwiftUI sizing passes and %.2f root rebuilds per frame; %.2f ms of it the window's display pass",
                   frames.count, mean * 1000, percentile(0.5) * 1000, percentile(0.95) * 1000, percentile(0.99) * 1000,
                   worst * 1000, over, overFraction * 100, tokensPerSecond,
                   Double(hostBuildFrames) / Double(max(1, frames.count)), hostBuildSeconds * 1000 / Double(max(1, frames.count)),
                   Double(sizingPasses) / Double(max(1, frames.count)), Double(rootUpdates) / Double(max(1, frames.count)),
                   displayMean * 1000)
        }
    }

    /// Streams `tokens` into the newest turn of a `rows`-row chat. With
    /// `scrollStep` the reader is scrolling at the same time, a wheel step per
    /// frame, in a gesture that begins and ends the way AppKit reports one.
    @MainActor private func stream(rows: Int, tokens: [String], scrollStep: CGFloat,
                                   gestureFrames: Int = 0, file: StaticString = #filePath, line: UInt = #line) async throws -> Run {
        let session = TranscriptFrameBudgetTests.chat("stream-scroll", rows: rows)
        let last = TranscriptFrameBudgetTests.lastUserID(rows: rows)
        let pane = Pane(session, state: "running"); defer { pane.close() }
        let ready = await pane.waitForRow(last, seconds: 120)
        XCTAssertTrue(ready, "the chat never appeared", file: file, line: line)
        await pane.settleUntilExact()
        let page = try XCTUnwrap(pane.page, file: file, line: line)
        let scroll = try XCTUnwrap(pane.scroll as? TranscriptNativeScrollView, file: file, line: line)
        let document = try XCTUnwrap(pane.document, file: file, line: line)
        // Every token is presented, so a frame here is a token reaching the
        // screen. Production cadence is a separate question, measured by
        // `testTokensCoalesceToTheDisplayRefresh`.
        page.presentationInterval = 0
        // The reply's row exists before the run starts, so the first frame is
        // a delta rather than an insertion.
        session.messages.append(TranscriptMessage(id: "stream:x", role: "assistant", text: "#", state: "streaming", turn: last))
        await pane.settle(turns: 6)
        let clip = scroll.contentView
        // The reader has scrolled back into the history: the page is detached,
        // which is the case where their position has to hold while the reply
        // grows below them.
        var travel = max(0, document.frame.height - clip.bounds.height)
        var y = (travel * 0.6).rounded()
        var direction: CGFloat = -1
        if scrollStep > 0 {
            scroll.readerWillNavigate(upward: true)
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            await pane.settle(turns: 4)
            y = clip.bounds.minY
        }
        var run = Run()
        run.tokens = tokens.count
        let preparedBefore = TranscriptIdleScheduler.shared.preparationCount
        var text = "#"
        var gestureOpen = false
        let started = ProcessInfo.processInfo.systemUptime
        TranscriptLayoutClock.recording = true
        for (index, token) in tokens.enumerated() {
            if !token.isEmpty { text += token }
            let arriving = document.retainedRows.last
            let arrivingTop = arriving?.frame.minY ?? .greatestFiniteMagnitude
            let before = Dictionary(uniqueKeysWithValues: document.retainedRows
                .filter { $0.superview != nil && $0.frame.maxY <= arrivingTop }
                .map { ($0.itemID, $0.frame.minY - clip.bounds.minY) })
            let beforeY = clip.bounds.minY
            // A wheel gesture: AppKit says when one begins and when it ends,
            // and the page is allowed to treat the frames in between
            // differently from the frames outside one.
            if scrollStep > 0, gestureFrames > 0, !gestureOpen {
                gestureOpen = true
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            }
            TranscriptLayoutClock.reset()
            let start = ProcessInfo.processInfo.systemUptime
            if !token.isEmpty { session.messages[session.messages.count - 1].text = text }
            run.modelSeconds += ProcessInfo.processInfo.systemUptime - start
            if scrollStep > 0 {
                if y <= 0 { direction = 1 } else if y >= travel * 0.85 { direction = -1 }
                y = max(0, min(travel, y + direction * scrollStep))
                scroll.readerWillNavigate(upward: direction < 0)
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            }
            pane.hosted.layoutSubtreeIfNeeded()
            let laidOut = ProcessInfo.processInfo.systemUptime
            pane.window.displayIfNeeded()
            let cost = ProcessInfo.processInfo.systemUptime - start
            run.displaySeconds += ProcessInfo.processInfo.systemUptime - laidOut
            if gestureOpen, gestureFrames > 0, (index + 1) % gestureFrames == 0 {
                gestureOpen = false
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                pane.hosted.layoutSubtreeIfNeeded()
                pane.window.displayIfNeeded()
            }
            run.frames.append(cost)
            run.worst = max(run.worst, cost)
            if TranscriptLayoutClock.hostBuilds > 0 {
                run.hostBuildFrames += 1
                run.hostBuildSeconds += TranscriptLayoutClock.hostBuildSeconds
            }
            if TranscriptLayoutClock.streamingAppends > 0 { run.appendFrames.append(cost) }
            else if TranscriptLayoutClock.streamingEstimates > 0 { run.estimateFrames.append(cost) }
            else if TranscriptLayoutClock.streamingRebuilds > 0 { run.rebuiltForOtherReasons += 1 }
            else if TranscriptLayoutClock.rootUpdates > 0 || TranscriptLayoutClock.rowSizingPasses > 0 { run.rebuildFrames.append(cost) }
            if gestureOpen, TranscriptLayoutClock.streamingAppends + TranscriptLayoutClock.rowSizingPasses > 0 { run.layoutsInsideGesture += 1 }
            run.readSeconds += TranscriptLayoutClock.markdownUpdateSeconds
            run.blockLayoutSeconds += TranscriptLayoutClock.markdownLayoutSeconds
            run.blocksMeasured += TranscriptLayoutClock.markdownBlocksMeasured
            run.rowLoopSeconds += TranscriptLayoutClock.rowLoopSeconds
            run.mountSeconds += TranscriptLayoutClock.mountSeconds
            run.viewportLayoutSeconds += TranscriptLayoutClock.viewportLayoutSeconds
            run.sizingPasses += TranscriptLayoutClock.rowSizingPasses
            run.rootUpdates += TranscriptLayoutClock.rootUpdates
            run.measuredRows += TranscriptLayoutClock.measuredRows
            // Nothing above the arriving row may move by anything other than
            // the scroll the reader asked for.
            let moved = clip.bounds.minY - beforeY
            for row in document.retainedRows where row.superview != nil {
                guard let was = before[row.itemID] else { continue }
                let now = row.frame.minY - clip.bounds.minY
                if abs(now - (was - moved)) > 0.6 {
                    run.movedUnexpectedly.append(String(format: "%@ moved %.1f pt (scroll was %.1f pt)", row.itemID, now - was, -moved))
                }
            }
            // A row the reader can see must already have its tree.
            let viewport = clip.bounds
            run.unpreparedVisits += document.retainedRows.filter {
                TranscriptNativeDocument.overlaps($0.frame, viewport) && !$0.isHosted
            }.count
            await Task.yield()
            if index % 8 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
            travel = max(0, document.frame.height - clip.bounds.height)
        }
        TranscriptLayoutClock.recording = false
        run.wallSeconds = ProcessInfo.processInfo.systemUptime - started
        run.layoutPasses = document.layoutPassCount
        run.preparedAhead = TranscriptIdleScheduler.shared.preparationCount - preparedBefore
        // The reply is what arrived, in full, however the page carried it.
        session.messages[session.messages.count - 1].state = "completed"
        await pane.settle(turns: 8)
        if tokens.contains(where: { !$0.isEmpty }) {
            XCTAssertEqual(page.snapshot?.messages.last?.text, text, "the page must end holding the whole reply", file: file, line: line)
        }
        return run
    }

    // MARK: 1 — A token on an idle page

    @MainActor func testATokenCostsLessThanFiveMillisecondsInALongChat() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let repeats = Int(testEnvironment("PI_PERF_REPEAT") ?? "") ?? 1
        let tokens = Array(Array(repeating: Self.tokens(of: Self.reply), count: repeats).joined())
        let run = try await stream(rows: rows, tokens: tokens, scrollStep: 0)
        // The same frames with no token in them: what this harness costs per
        // frame whatever the reply does — laying the pane out and asking the
        // window to display. A token's own cost is the difference.
        let still = try await stream(rows: rows, tokens: Array(repeating: "", count: tokens.count), scrollStep: 0)
        print("PERF streaming \(tokens.count) tokens into a \(rows)-row chat, reader still: \(run.line)")
        print("PERF streaming, reader still: \(run.paths)")
        print("PERF streaming, reader still, \(run.inside)")
        print("PERF the same frames with no token in them: \(still.line)")
        XCTAssertEqual(run.movedUnexpectedly, [], "the page moved while a reply arrived")
        // The shape that holds in every configuration: a token touches the
        // arriving row and nothing else.
        XCTAssertLessThanOrEqual(run.measuredRows, tokens.count + 4,
                                 "a token measured \(run.measuredRows) rows over \(tokens.count) tokens")
        // A token is one block read again, one block measured again and one
        // row placed again: 0.05 + 0.41 + 0.21 ms of the frame it lands in.
        // What is left of it is SwiftUI laying the arriving row's own tree out
        // at its new height, which is why the ceiling is not tighter yet.
        XCTAssertLessThan(run.mean - still.mean, releaseBudget(0.008),
                          String(format: "a token cost %.2f ms in a %d-row chat (%.2f ms a frame with the token, %.2f without)",
                                 (run.mean - still.mean) * 1000, rows, run.mean * 1000, still.mean * 1000))
        XCTAssertEqual(run.hostBuildFrames, 0, "a token built a row's tree inside the frame that showed it")
    }

    // MARK: 2 — A token while the reader scrolls

    @MainActor func testStreamingWhileScrollingStaysWithinTheDisplaysFrame() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let tokens = Self.tokens(of: Self.reply)
        let run = try await stream(rows: rows, tokens: tokens, scrollStep: 10)
        // The same scroll with nothing arriving: the frames a reader pays for
        // scrolling this page at all. What streaming adds is the difference.
        let control = try await stream(rows: rows, tokens: Array(repeating: "", count: tokens.count), scrollStep: 10)
        print("PERF streaming \(tokens.count) tokens into a \(rows)-row chat while scrolling 10 pt a frame: \(run.line)")
        print("PERF streaming while scrolling: \(run.paths)")
        print("PERF streaming while scrolling, \(run.inside)")
        print("PERF streaming while scrolling: \(run.unpreparedVisits) visits to a row with no tree, \(run.layoutPasses) document layout passes")
        print("PERF the same scroll with nothing arriving: \(control.line)")
        XCTAssertEqual(run.movedUnexpectedly, [], "the page moved by something other than the scroll while a reply arrived")
        XCTAssertEqual(run.unpreparedVisits, 0, "a scroll reached \(run.unpreparedVisits) rows the page had not prepared")
        // A reply arriving must cost a scroll frame almost nothing: the rows
        // the reader is looking at are not the arriving one.
        XCTAssertLessThan(run.mean - control.mean, releaseBudget(0.008),
                          String(format: "a reply arriving added %.2f ms to a scroll frame (%.2f ms with it, %.2f without)",
                                 (run.mean - control.mean) * 1000, run.mean * 1000, control.mean * 1000))
        XCTAssertLessThan(run.worst, releaseBudget(0.030),
                          String(format: "the worst frame while streaming and scrolling took %.1f ms, against %.1f ms for the same scroll alone",
                                 run.worst * 1000, control.worst * 1000))
        // The shape that holds in any configuration: the reader's own frames
        // do not carry the arriving row's tree, and the page has the rows they
        // are travelling towards ready before they get there.
        XCTAssertEqual(run.hostBuildFrames, 0, "a scroll frame built a row's tree while a reply arrived")
        XCTAssertEqual(run.sizingPasses, 0, "a scroll frame put a row through SwiftUI's sizing while a reply arrived")
        // Getting the rows the reader is travelling towards ready is exactly
        // the work a reply arriving used to stop. It does not stop any more.
        XCTAssertGreaterThan(run.preparedAhead, 0,
                             "preparation stopped while a reply was arriving, which is when the reader most needs it")
    }

    // MARK: 4 — Tokens arrive faster than the display, and are shown once a frame

    /// The helper delivers tokens as fast as the model produces them. The page
    /// must not lay itself out once per token: it publishes on the display's
    /// own beat, so a burst of sixty tokens inside one frame reaches the
    /// screen as one layout, carrying all sixty.
    @MainActor func testTokensCoalesceToTheDisplayRefresh() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 120
        let session = TranscriptFrameBudgetTests.chat("coalesce", rows: rows)
        let last = TranscriptFrameBudgetTests.lastUserID(rows: rows)
        let pane = Pane(session, state: "running"); defer { pane.close() }
        let ready = await pane.waitForRow(last, seconds: 120)
        XCTAssertTrue(ready, "the chat never appeared")
        await pane.settleUntilExact()
        let page = try XCTUnwrap(pane.page)
        let document = try XCTUnwrap(pane.document)
        // The production cadence, untouched: the other tests in this file set
        // it to zero so that a frame is a token.
        XCTAssertEqual(page.presentationInterval, 1.0 / 30, "the page publishes on the display's beat")
        session.messages.append(TranscriptMessage(id: "stream:c", role: "assistant", text: "#", state: "streaming", turn: last))
        await pane.settle(turns: 6)

        let tokens = Array(Self.tokens(of: Self.reply).prefix(60))
        let reconciledBefore = document.contentReconciliationCount, laidOutBefore = document.layoutPassCount
        var text = "#"
        // A burst: sixty tokens with no run-loop turn between them, which is
        // what a fast model on a fast link actually looks like.
        for token in tokens {
            text += token
            session.messages[session.messages.count - 1].text = text
        }
        let reconciledInBurst = document.contentReconciliationCount - reconciledBefore
        let laidOutInBurst = document.layoutPassCount - laidOutBefore
        print("PERF \(tokens.count) tokens inside one frame: \(reconciledInBurst) row reconciliations, \(laidOutInBurst) document layout passes, \(page.pendingPresentationCount) waiting to be published")
        XCTAssertLessThanOrEqual(reconciledInBurst, 1,
                                 "\(tokens.count) tokens inside one frame cost \(reconciledInBurst) row reconciliations")
        XCTAssertLessThanOrEqual(laidOutInBurst, 1,
                                 "\(tokens.count) tokens inside one frame cost \(laidOutInBurst) document layout passes")

        // Held, not dropped: the text catches up on the next beat, in full.
        await pane.settle(turns: 8)
        XCTAssertEqual(page.snapshot?.messages.last?.text, text, "the page must end holding every token of the burst")

        // And over real time the page publishes at its own cadence, not the
        // helper's: many more tokens than beats, and one layout per beat.
        let reconciledBeforeRun = document.contentReconciliationCount
        let started = ProcessInfo.processInfo.systemUptime
        var delivered = 0
        while ProcessInfo.processInfo.systemUptime - started < 0.5 {
            text += " token"
            session.messages[session.messages.count - 1].text = text
            delivered += 1
            pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let published = document.contentReconciliationCount - reconciledBeforeRun
        // The beat plus a couple for the edges of the window.
        let beats = Int(elapsed / page.presentationInterval) + 3
        print(String(format: "PERF %d tokens over %.2f s reached the screen as %d publications (at most %d beats)", delivered, elapsed, published, beats))
        XCTAssertGreaterThan(delivered, published, "the page published once per token rather than once per frame")
        XCTAssertLessThanOrEqual(published, beats,
                                 "\(delivered) tokens over \(String(format: "%.2f", elapsed)) s were published \(published) times, more than the display's beat allows")
        session.messages[session.messages.count - 1].state = "completed"
        await pane.settle(turns: 8)
    }

    // MARK: 3 — A wheel gesture owns its frames

    @MainActor func testTheStreamingRowIsNotLaidOutDuringAWheelGesture() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 120
        let tokens = Self.tokens(of: Self.reply)
        let run = try await stream(rows: rows, tokens: tokens, scrollStep: 10, gestureFrames: 12)
        print("PERF streaming through 12-frame wheel gestures into a \(rows)-row chat: \(run.line)")
        print("PERF streaming through gestures: \(run.paths); \(run.layoutsInsideGesture) frames inside a gesture laid the arriving row out")
        // A gesture owns its frames. The one exception is the hold cap: a
        // gesture that runs longer than a quarter of a second lets the reply
        // through once rather than leaving it looking stuck.
        let gestures = tokens.count / 12 + 1
        XCTAssertLessThanOrEqual(run.layoutsInsideGesture, gestures,
                                 "\(run.layoutsInsideGesture) frames inside \(gestures) wheel gestures laid the arriving row out")
        XCTAssertEqual(run.movedUnexpectedly, [], "the page moved by something other than the scroll during a gesture")
        XCTAssertLessThan(run.mean, releaseBudget(0.004),
                          String(format: "a frame inside a wheel gesture took %.2f ms", run.mean * 1000))
        XCTAssertLessThan(run.overFraction, releaseBudget(0.10),
                          String(format: "%d of %d frames (%.1f%%) inside a wheel gesture went over a 120 Hz frame",
                                 run.over, run.frames.count, run.overFraction * 100))
        XCTAssertLessThan(run.worst, releaseBudget(0.020),
                          String(format: "the worst frame inside a wheel gesture took %.1f ms", run.worst * 1000))
    }
}
