import XCTest
@testable import PiApp

/// The request inspector refreshes itself once a second while it is open.
/// That refresh used to replace the whole list with the first page, so
/// "Older Attempts" grew the list and then lost it a second later, leaving a
/// selected attempt with no row and an empty Headers pane.
final class InspectorAttemptListTests: XCTestCase {
    private func attempt(_ id: String) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string("session")]
    }

    @MainActor func testABackgroundRefreshKeepsThePagesTheReaderAskedFor() {
        let firstPage = (0..<128).map { attempt("a\($0)") }
        let olderPage = (128..<200).map { attempt("a\($0)") }
        let paged = firstPage + olderPage

        // Nothing new: the refresh must leave the reader's list exactly as it was.
        XCTAssertEqual(InspectorView.merging(firstPage, into: paged), paged)

        // A new attempt arrives at the top: it appears, the newest page shifts
        // by one, and every older page the reader loaded is still there.
        let refreshed = [attempt("new")] + firstPage.dropLast()
        let merged = InspectorView.merging(refreshed, into: paged)
        XCTAssertEqual(merged.first?["attemptId"]?.string, "new")
        XCTAssertEqual(merged.count, paged.count + 1)
        XCTAssertEqual(merged.last?["attemptId"]?.string, "a199", "the oldest loaded attempt must not disappear")
        XCTAssertEqual(Set(merged.compactMap { $0["attemptId"]?.string }).count, merged.count, "an attempt must not be listed twice")
        XCTAssertTrue(merged.contains { $0["attemptId"]?.string == "a127" }, "the attempt pushed off the first page is still loaded")
    }

    @MainActor func testAReaderWhoNeverPagedJustSeesTheNewestPage() {
        let existing = (0..<10).map { attempt("a\($0)") }
        let refreshed = [attempt("new")] + existing.prefix(9)
        XCTAssertEqual(InspectorView.merging(refreshed, into: existing), refreshed)
        XCTAssertEqual(InspectorView.merging([], into: []), [])
        // A shorter refresh (attempts expired) replaces the list rather than
        // resurrecting rows the archive no longer has.
        XCTAssertEqual(InspectorView.merging(Array(existing.prefix(3)), into: Array(existing.prefix(3))), Array(existing.prefix(3)))
    }
}
