import XCTest
import SwiftUI
@testable import PiApp

/// The one line every piece of work reads as, and the cards it opens.
///
/// Each case is a state the reader can actually reach: a call running, a call
/// that failed, a call they stopped, a thought still being written, a diff too
/// long to draw whole, a read window, a command. What the row says in each of
/// them is asserted through the same pure functions the view draws from, and
/// the geometry — one 24 pt line, whatever the row says — in a window.
final class TranscriptWorkRowTests: XCTestCase {
    private func call(_ state: String, output: String = "ok", name: String = "read") -> ToolView {
        ToolView(id: "c1", name: name, state: state, input: "{\"path\":\"apps/macos/PiApp/Design/PiMotion.swift\"}",
                 output: output, durationMs: 940, truncated: false, path: "apps/macos/PiApp/Design/PiMotion.swift")
    }

    // MARK: Every state of a row

    func testARowSaysItsOutcomeInColourAndInOneHiddenWord() {
        XCTAssertEqual(ActionRowView.state(of: call("running")), .running)
        XCTAssertEqual(ActionRowView.state(of: call("preparing")), .running)
        XCTAssertEqual(ActionRowView.state(of: call("completed")), .ok)
        XCTAssertEqual(ActionRowView.state(of: call("failed")), .failed)
        XCTAssertEqual(ActionRowView.state(of: call("cancelled")), .stopped,
                       "A call the reader stopped did not fail: it is amber, not red")
        // Colour alone is never the message: assistive technology hears a word.
        XCTAssertNil(TranscriptRowState.ok.spokenStatus)
        XCTAssertEqual(TranscriptRowState.running.spokenStatus, "Running")
        XCTAssertEqual(TranscriptRowState.stopped.spokenStatus, "Stopped")
        XCTAssertEqual(TranscriptRowState.failed.spokenStatus, "Failed")
        XCTAssertEqual(TranscriptRowState.stopped.tint, TranscriptPalette.warning)
        XCTAssertEqual(TranscriptRowState.failed.tint, TranscriptPalette.danger)
    }

    func testAFailureReplacesTheSummaryRatherThanJoiningIt() {
        let ok = call("completed")
        XCTAssertEqual(ActionRowView.summary(of: ok), TranscriptActivity.describe(ok).object)
        let failed = call("failed", output: "ENOENT: no such file or directory\n  at readFile (fs.js:1)")
        XCTAssertEqual(ActionRowView.summary(of: failed), "ENOENT: no such file or directory",
                       "The failure's first line is what the row says, instead of the arguments")
        // A call the reader stopped keeps saying what it was doing.
        let stopped = call("cancelled", output: "")
        XCTAssertEqual(ActionRowView.summary(of: stopped), TranscriptActivity.describe(stopped).object)
    }

    func testAChangeCarriesItsTotalOnTheCollapsedRow() {
        var edit = call("completed", name: "edit")
        XCTAssertNil(ActionRowView.suffix(of: edit), "A call that changed nothing shows no total")
        edit.added = 130; edit.removed = 130
        XCTAssertEqual(ActionRowView.suffix(of: edit), "+130 −130",
                       "The change size reads without opening the card")
        edit.removed = nil
        XCTAssertEqual(ActionRowView.suffix(of: edit), "+130 −0")
    }

    // MARK: The Think row

    func testAThoughtReadsFromItsEndWhileItIsWrittenAndFromItsStartAfterwards() {
        let text = "**Plan**\nFirst I will read the file.\nThen I will check the retry budget."
        XCTAssertEqual(TimelinePartRow.thinkSummary(text, running: true), "Then I will check the retry budget.",
                       "A thought still arriving shows its newest line")
        XCTAssertEqual(TimelinePartRow.thinkSummary(text, running: false), "Plan",
                       "A settled thought shows its first line, without the emphasis markers")
        XCTAssertEqual(TimelinePartRow.thinkSummary("   ", running: true), "")
        XCTAssertEqual(TimelinePartRow.thinkSummary("One line only", running: true), "One line only")
        // Blank lines and indentation at either end are not the thought.
        XCTAssertEqual(TimelinePartRow.thinkSummary("\n\n  **First**  \nmiddle\n  last one \n\n  \n", running: true), "last one")
        XCTAssertEqual(TimelinePartRow.thinkSummary("\n\n  **First**  \nmiddle\n  last one \n\n  \n", running: false), "First")
        XCTAssertEqual(TimelinePartRow.thinkSummary("Windows line\r\nends here\r\n", running: true), "ends here")
        XCTAssertEqual(TimelinePartRow.thinkSummary("Windows line\r\nends here\r\n", running: false), "Windows line")
        XCTAssertEqual(TimelinePartRow.thinkSummary("naïve café 🧠\nnext", running: false), "naïve café 🧠")
    }

    /// A streaming thought redraws its row on every delta, and the row shows
    /// its newest line. That line is all a delta may cost: the summary used to
    /// trim and split the entire thought on every render, so a long thought
    /// grew slower to stream with every line it gained.
    func testAStreamingThoughtCostsItsNewestLineNotTheWholeThought() {
        let line = "Then I will check the retry budget and the backoff before the next request."
        let small = String(repeating: line + "\n", count: 25) + "Newest line"
        let large = String(repeating: line + "\n", count: 25_000) + "Newest line"
        func perCall(_ text: String, _ repeats: Int) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<repeats { XCTAssertEqual(TimelinePartRow.thinkSummary(text, running: true), "Newest line") }
            return (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(repeats)
        }
        _ = perCall(small, 20)
        let smallMs = perCall(small, 400), largeMs = perCall(large, 20)
        print(String(format: "PERF thinkSummary running smallBytes=%d largeBytes=%d smallMs=%.4f largeMs=%.4f ratio=%.1f",
                     small.utf8.count, large.utf8.count, smallMs, largeMs, largeMs / max(smallMs, 1e-6)))
        XCTAssertLessThan(largeMs, max(smallMs, 0.001) * 40,
                          "A thought 1,000 times longer must not make each delta's summary much slower")
        XCTAssertLessThan(largeMs / 1_000, releaseBudget(0.000_5), "Half a millisecond per delta, however long the thought")
    }

    /// A write streams its arguments into a closed card. From its first delta
    /// to its last the row reads "Writing Big.swift", and none of those
    /// renders may read the whole growing document again: each one used to
    /// decode it three times, 200 KB at a time.
    @MainActor func testAStreamingWriteDoesNotReparseItsGrowingArgumentsOnEveryRender() throws {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let chunk = String(repeating: #"let value = 42 // one line of the file being written\n"#, count: 19)
        var input = #"{"path":"Sources/Feature/Big.swift","content":""#
        let deltas = 200
        let decodedBefore = TranscriptActivity.argumentBytesDecoded
        let start = CFAbsoluteTimeGetCurrent()
        var tool = ToolView(id: "w", name: "write", state: "preparing", input: input, output: "", truncated: false)
        for _ in 0..<deltas {
            input += chunk
            tool.input = input
            host.rootView = AnyView(ActionRowView(tool: tool).frame(width: 640))
            host.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        let decoded = TranscriptActivity.argumentBytesDecoded - decodedBefore
        print(String(format: "PERF streamingWriteRow deltas=%d finalBytes=%d decodedBytes=%d totalMs=%.1f perDeltaMs=%.3f",
                     deltas, input.utf8.count, decoded, elapsed, elapsed / Double(deltas)))
        XCTAssertEqual(ActionRowView.title(of: tool), "Wrote")
        XCTAssertEqual(ActionRowView.summary(of: tool), "Feature/Big.swift", "The row names the file from the first delta that carries its path")
        XCTAssertLessThan(decoded, input.utf8.count,
                          "Drawing a closed card while its arguments stream must not decode the growing document on every delta")
        XCTAssertLessThan(elapsed / Double(deltas) / 1_000, releaseBudget(0.004), "A delta redraws one closed row within a quarter of a frame")
    }

    // MARK: The cards

    func testExpandingALongDiffCanReachTheLastChangedLine() throws {
        let before = (1...300).map { "before \($0)" }.joined(separator: "\n")
        let after = (1...300).map { "after \($0)" }.joined(separator: "\n")
        let data = try JSONSerialization.data(withJSONObject: ["path": "Long.swift", "oldText": before, "newText": after])
        let tool = ToolView(id: "long-edit", name: "edit", state: "completed",
                            input: String(decoding: data, as: UTF8.self), output: "ok", durationMs: 10, truncated: false)
        let diff = try XCTUnwrap(TranscriptActivity.editRequest(tool))
        XCTAssertFalse(diff.tooLarge)
        XCTAssertEqual(diff.rows.count, 600)
        XCTAssertEqual(diff.hiddenRows, 0, "Collapsing a card must not discard lines needed by Expand")
        XCTAssertEqual(diff.rows.last?.text, "after 300")
        XCTAssertEqual(diff.before, before)
        XCTAssertEqual(diff.after, after)
    }

    func testALongListShowsItsHeadAndItsTailAndSaysWhatIsBetweenThem() {
        let capped = TranscriptCardMetrics.headTail(total: 260, maxLines: 12, expanded: false)
        XCTAssertTrue(capped.capped)
        XCTAssertEqual(capped.hidden, 248)
        XCTAssertEqual(capped.head, 6); XCTAssertEqual(capped.tail, 6)
        XCTAssertEqual(capped.head + capped.tail, 12, "A capped list draws exactly the cap")
        // Expanding uncaps it; a short list was never capped.
        XCTAssertFalse(TranscriptCardMetrics.headTail(total: 260, maxLines: 12, expanded: true).capped)
        let short = TranscriptCardMetrics.headTail(total: 5, maxLines: 12, expanded: false)
        XCTAssertFalse(short.capped); XCTAssertEqual(short.hidden, -7)
        // An odd cap gives the head the extra line, as the reference does.
        XCTAssertEqual(TranscriptCardMetrics.headTail(total: 100, maxLines: 9, expanded: false).head, 5)
        XCTAssertEqual(TranscriptCardMetrics.headTail(total: 100, maxLines: 9, expanded: false).tail, 4)
    }

    func testAReadSaysHowMuchOfItsResultTheCardIsShowing() {
        XCTAssertEqual(TranscriptReadCard.window(shown: 12, total: 340), "Showing 12 of 340 lines")
        XCTAssertEqual(TranscriptReadCard.window(shown: 8, total: 8), "8 lines",
                       "A card showing everything does not say so on every read")
        XCTAssertEqual(TranscriptReadCard.window(shown: 1, total: 1), "1 line")
    }

    /// Hiding one line behind a line that says "1 more lines" hides nothing
    /// and says it badly: a list one line over its cap is drawn whole.
    func testAListOneLineOverItsCapIsDrawnWholeRatherThanSayingSo() {
        let one = TranscriptCardMetrics.headTail(total: 13, maxLines: 12, expanded: false)
        XCTAssertFalse(one.capped, "One hidden line costs the same height as the line that would say so")
        XCTAssertTrue(TranscriptCardMetrics.headTail(total: 14, maxLines: 12, expanded: false).capped)
        XCTAssertEqual(TranscriptCardMetrics.moreLines(2), "… 2 more lines")
        XCTAssertEqual(TranscriptCardMetrics.moreLines(1), "… 1 more line")
    }

    /// A read that started at line 40 numbers its window from 40, as the file
    /// numbers those lines, and the host's "[Truncated …]" trailer is a note
    /// under the window rather than one more numbered line of the file.
    @MainActor func testAReadNumbersItsWindowFromTheLineItStartedAt() async throws {
        XCTAssertEqual(TranscriptReadCard.firstLine(of: #"{"path":"Sources/App.swift","offset":40,"limit":3}"#), 40)
        XCTAssertEqual(TranscriptReadCard.firstLine(of: #"{"path":"Sources/App.swift"}"#), 1, "A read that named no offset starts at the top")
        XCTAssertEqual(TranscriptReadCard.firstLine(of: #"{"offset":true}"#), 1)
        XCTAssertEqual(TranscriptReadCard.firstLine(of: #"{"offset":0}"#), 1, "The host numbers lines from 1")
        let output = "alpha\nbeta\ngamma\n[Truncated. 400 total lines; read another range.]"
        let tool = ToolView(id: "r", name: "read", state: "completed", input: #"{"path":"Sources/App.swift","offset":40,"limit":3}"#,
                            output: output, durationMs: 12, truncated: false, path: "Sources/App.swift")
        let host = NSHostingView(rootView: ActionRowView(tool: tool, open: true).frame(width: 520).padding(12).background(TranscriptPalette.canvas))
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 544, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let rendered = try await SessionTimingTests.recognizedText(in: window)
        func shows(_ pattern: String) -> Bool { rendered.range(of: pattern, options: .regularExpression) != nil }
        XCTAssertTrue(shows(#"\b40\b"#) && shows(#"\b41\b"#) && shows(#"\b42\b"#), "The window is numbered from the offset it was read at. OCR: \(rendered)")
        XCTAssertFalse(shows(#"\b1\b"#) || shows(#"\b2\b"#), "Line 40 is not line 1. OCR: \(rendered)")
        XCTAssertFalse(shows(#"\b43\b"#), "The host's trailer is not line 43 of the file. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("400 total lines"), "The trailer is still said, as a note. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("3 lines"), "The window counts the file's lines only. OCR: \(rendered)")
    }

    func testEachSectionOfACardIsBoundedOnItsOwn() {
        XCTAssertEqual(TranscriptCardMetrics.sectionCap, 150,
                       "A long request must not bury a short result, so each section caps and scrolls alone")
        XCTAssertEqual(TranscriptCardMetrics.terminalCap, 224)
        XCTAssertGreaterThan(TranscriptCardMetrics.diffLines, 0)
        XCTAssertGreaterThan(TranscriptCardMetrics.readLines, 0)
    }

    // MARK: The line itself, in a window

    @MainActor private func height(_ view: some View, width: CGFloat = 640) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width).fixedSize(horizontal: false, vertical: true)))
        host.sizingOptions = [.intrinsicContentSize]
        return host.fittingSize.height
    }

    @MainActor func testEveryClosedWorkRowIsTheSameLineWhateverItSays() {
        let line = TranscriptRowChrome.height
        XCTAssertEqual(height(ActionRowView(tool: call("completed"))), line, accuracy: 0.5)
        XCTAssertEqual(height(ActionRowView(tool: call("running"))), line, accuracy: 0.5,
                       "A running row shimmers over itself; it does not grow")
        XCTAssertEqual(height(ActionRowView(tool: call("failed", output: String(repeating: "long failure text ", count: 40)))),
                       line, accuracy: 0.5, "A failure's first line is one line")
        var long = call("completed")
        long.path = String(repeating: "deep/directory/", count: 40) + "file.swift"
        XCTAssertEqual(height(ActionRowView(tool: long)), line, accuracy: 0.5)
        XCTAssertEqual(height(TranscriptWorkRow(icon: "brain", title: "Think",
                                               summary: String(repeating: "a thought that keeps going ", count: 20),
                                               content: { EmptyView() })), line, accuracy: 0.5)
    }

    @MainActor func testOpeningARowIsTheOnlyThingThatMakesItTaller() {
        let closed = height(ActionRowView(tool: call("completed")))
        let open = height(ActionRowView(tool: call("completed"), open: true))
        XCTAssertGreaterThan(open, closed + 20, "An open row holds its card")
        // A row with nothing to open stays a line even when it is told it is open.
        XCTAssertEqual(height(TranscriptWorkRow(icon: "circle", title: "Status", expandable: false, open: true,
                                                content: { Color.red.frame(height: 200) })),
                       TranscriptRowChrome.height, accuracy: 0.5)
    }

    @MainActor func testACappedDiffDrawsLessThanAnUncappedOneAndSaysHowMuchLess() {
        let rows = (0..<200).map { DiffRow(kind: $0 % 2 == 0 ? .added : .removed, text: "line \($0)") }
        let request = TranscriptActivity.EditRequest(before: "", after: "", mode: "edit", rows: rows,
                                                    hiddenRows: 0, complete: true, tooLarge: false, lines: rows.count)
        let capped = height(TranscriptDiffCard(request: request, path: "notes.md", added: 100, removed: 100))
        let whole = height(TranscriptDiffCard(request: TranscriptActivity.EditRequest(
            before: "", after: "", mode: "edit", rows: Array(rows.prefix(TranscriptCardMetrics.diffLines)),
            hiddenRows: 0, complete: true, tooLarge: false, lines: TranscriptCardMetrics.diffLines),
                                              path: "notes.md", added: 6, removed: 6))
        XCTAssertEqual(capped, whole, accuracy: 24,
                       "A 200-line diff and a 12-line diff draw the same height, because the middle collapses")
    }
}
