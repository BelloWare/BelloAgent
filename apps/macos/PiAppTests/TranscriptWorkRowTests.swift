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
