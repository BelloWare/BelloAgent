import XCTest
@testable import PiApp

/// The Inspector's parsed documents: least recently used out first, bounded by
/// count and by cost, with the delta's digests kept apart.
final class InspectorDocumentCacheTests: XCTestCase {
    private func document(_ text: String) throws -> RequestDocument {
        try RequestDocument.parse(try JSONSerialization.data(withJSONObject: ["input": [["role": "user", "content": text]]]))
    }
    private func key(_ attempt: String, _ kind: String = "request", _ revision: String = "r1") -> InspectorDocumentCache.Key {
        InspectorDocumentCache.Key(attempt: attempt, kind: kind, revision: revision)
    }

    func testTheLeastRecentlyUsedDocumentLeavesFirst() async throws {
        let cache = InspectorDocumentCache(capacity: 2, costLimit: 1_000_000)
        await cache.store(.request(try document("a")), for: key("a"), cost: 10)
        await cache.store(.request(try document("b")), for: key("b"), cost: 10)
        let touched = await cache.value(key("a"))
        XCTAssertNotNil(touched, "Reading a document makes it recent")
        await cache.store(.request(try document("c")), for: key("c"), cost: 10)
        let evicted = await cache.value(key("b"))
        let kept = await cache.value(key("a"))
        let newest = await cache.value(key("c"))
        XCTAssertNil(evicted); XCTAssertNotNil(kept); XCTAssertNotNil(newest)
        let count = await cache.count
        XCTAssertEqual(count, 2)
    }

    func testCostBoundsTheCacheAndAnOversizedDocumentIsNeverKept() async throws {
        let cache = InspectorDocumentCache(capacity: 10, costLimit: 100)
        await cache.store(.request(try document("a")), for: key("a"), cost: 60)
        await cache.store(.request(try document("b")), for: key("b"), cost: 60)
        let first = await cache.value(key("a"))
        XCTAssertNil(first, "Storing past the cost limit lets the oldest go")
        let cost = await cache.cost
        XCTAssertEqual(cost, 60)
        await cache.store(.request(try document("huge")), for: key("huge"), cost: 101)
        let huge = await cache.value(key("huge"))
        XCTAssertNil(huge, "A document dearer than the whole cache is not kept")
        let second = await cache.value(key("b"))
        XCTAssertNotNil(second, "and does not push the others out")
    }

    func testARevisionIsAnotherDocumentAndDigestsAreKeptApart() async throws {
        let cache = InspectorDocumentCache(capacity: 1, costLimit: 1_000, digestCapacity: 2)
        await cache.store(.request(try document("a")), for: key("a", "request", "r1"), cost: 1)
        let otherRevision = await cache.value(key("a", "request", "r2"))
        XCTAssertNil(otherRevision, "A body that grew is read again")
        let otherKind = await cache.value(key("a", "response", "r1"))
        XCTAssertNil(otherKind)
        let digests = RequestDigests(items: ["x"], characters: [1])
        await cache.storeDigests(digests, for: key("a"))
        await cache.storeDigests(digests, for: key("b"))
        await cache.storeDigests(digests, for: key("c"))
        let oldest = await cache.digests(key("a"))
        let latest = await cache.digests(key("c"))
        XCTAssertNil(oldest); XCTAssertEqual(latest, digests)
        let digestCount = await cache.digestCount
        XCTAssertEqual(digestCount, 2)
        let documents = await cache.count
        XCTAssertEqual(documents, 1, "Digests never push a document out")
        await cache.removeAll()
        let empty = await cache.count, emptyDigests = await cache.digestCount
        XCTAssertEqual(empty, 0); XCTAssertEqual(emptyDigests, 0)
    }
}
