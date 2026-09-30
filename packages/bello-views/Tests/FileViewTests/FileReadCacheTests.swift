import XCTest
@testable import FileView

/// What is kept of a file's text (`FileReadCache`): the screen's pins and
/// each hold keep their entries whatever the budget, each independently of
/// the others; letting go is idempotent; everything else goes, longest
/// unused first, but for the entry just put.
final class FileReadCacheTests: XCTestCase {
    private func put(_ cache: inout FileReadCache, _ page: Int, cost: Int = 10) {
        cache.put(.page(page), .page(firstLine: page, lines: []), cost: cost, asked: cache.tick())
    }

    func testTheLongestUnusedGoesFirstButNotTheOneJustPut() {
        var cache = FileReadCache(budget: 30)
        for page in 0..<3 { put(&cache, page) }
        _ = cache.payload(.page(0), use: true)
        put(&cache, 3)
        XCTAssertFalse(cache.contains(.page(1)), "the longest unused")
        XCTAssertTrue(cache.contains(.page(0)), "used since")
        XCTAssertTrue(cache.contains(.page(3)), "just put")
        put(&cache, 4, cost: 100)
        XCTAssertTrue(cache.contains(.page(4)), "just put, however much it costs")
        XCTAssertEqual(cache.pageCount, 1)
    }

    func testTheScreenAndEachHoldKeepTheirOwnWhateverTheBudget() {
        var cache = FileReadCache(budget: 10)
        cache.pin(screen: [.page(0)])
        let a = cache.hold([.page(1), .page(2)]), b = cache.hold([.page(2), .page(3)])
        for page in 0..<9 { put(&cache, page) }
        for page in 0..<4 { XCTAssertTrue(cache.contains(.page(page)), "kept past the budget: page \(page)") }
        XCTAssertFalse(cache.contains(.page(5)), "kept by nothing")
        XCTAssertTrue(cache.contains(.page(8)), "just put")
        cache.release(a)
        XCTAssertTrue(cache.contains(.page(2)), "still held by the other hold")
        XCTAssertFalse(cache.contains(.page(1)), "let go of")
        cache.release(a)
        XCTAssertTrue(cache.contains(.page(2)), "letting go again is nothing")
        cache.release(b)
        XCTAssertFalse(cache.contains(.page(2)))
        XCTAssertTrue(cache.contains(.page(0)), "the screen's")
        cache.pin(screen: [.page(9)])
        put(&cache, 9)
        XCTAssertFalse(cache.contains(.page(0)), "kept only until another screen")
    }

    func testHoldsFromBeforeEverythingWentAreNothing() {
        var cache = FileReadCache(budget: 10)
        put(&cache, 0)
        let old = cache.hold([.page(0)])
        cache.removeAll()
        put(&cache, 1)
        let new = cache.hold([.page(1)])
        XCTAssertNotEqual(old, new, "a hold's number is never given again")
        cache.release(old)
        XCTAssertEqual(cache.holdCount, 1, "the old hold's letting go leaves the new one")
    }
}
