import XCTest
@testable import PiApp

/// Search and Copy Conversation's paging. Kept from the request inspector's
/// list tests when that sheet went.
final class ConversationSearchPagingTests: XCTestCase {
    /// "Next Results" used the query as edited in the field with the cursor
    /// of the results on screen, which belong to the query that was searched.
    func testNextResultsPagesTheQueryThatProducedTheResults() {
        let result = ContentSearch(hits: [], total: 40, next: 25, revision: "r")
        let next = ConversationSearchPaging.next(after: result, searched: "cache", current: "cache miss")
        XCTAssertEqual(next?.query, "cache")
        XCTAssertEqual(next?.start, 25)
        XCTAssertNil(ConversationSearchPaging.next(after: ContentSearch(hits: [], total: 3, next: nil, revision: "r"), searched: "cache", current: "cache"))
    }
}
