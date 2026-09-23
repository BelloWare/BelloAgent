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

    /// After new attempts arrived, "Older Attempts" asked for the offset it
    /// recorded before they did; that page now began with rows already
    /// listed, and the list showed them twice.
    @MainActor func testOlderAttemptsNeverRepeatRowsAfterNewOnesArrive() {
        let loaded = (0..<256).map { attempt("a\($0)") }
        let polled = InspectorView.merging([attempt("n0"), attempt("n1")] + loaded.prefix(126), into: loaded)
        XCTAssertEqual(polled.count, 258)
        // The page at the recorded offset (256) now starts two rows earlier.
        let older = (254..<382).map { attempt("a\($0)") }
        let merged = InspectorView.appendingOlder(older, to: polled)
        XCTAssertEqual(Set(merged.compactMap { $0["attemptId"]?.string }).count, merged.count, "No attempt is listed twice")
        XCTAssertEqual(merged.count, 258 + 126)
        XCTAssertEqual(merged.last?["attemptId"]?.string, "a381")
    }

    /// "Next Results" used the query as edited in the field with the cursor
    /// of the results on screen, which belong to the query that was searched.
    func testNextResultsPagesTheQueryThatProducedTheResults() {
        let result = ContentSearch(hits: [], total: 40, next: 25, revision: "r")
        let next = ConversationSearchPaging.next(after: result, searched: "cache", current: "cache miss")
        XCTAssertEqual(next?.query, "cache")
        XCTAssertEqual(next?.start, 25)
        XCTAssertNil(ConversationSearchPaging.next(after: ContentSearch(hits: [], total: 3, next: nil, revision: "r"), searched: "cache", current: "cache"))
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
