import XCTest
@testable import PiAgentCore

/// Every record and reply carries its time as a new `ISO8601DateFormatter`
/// wrote it; the one `isoNow` keeps writes the same text, a time within half
/// a millisecond of the next second rounded up as before.
final class IsoTimeTests: XCTestCase {
    func testTheTimeReadsAsTheFormatterWroteIt() {
        let formatter = ISO8601DateFormatter()
        for seconds in [0.0, 1_790_000_000, 1_790_000_000.999, 1_790_000_000.9994, 1_790_000_000.9996, 1_790_000_059.5, 4_102_444_799, 951_782_400] {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(isoString(date), formatter.string(from: date), "\(seconds)")
        }
        XCTAssertEqual(isoNow().count, 20)
        XCTAssertEqual(isoString(Date(timeIntervalSince1970: 1_790_000_000.9996)), "2026-09-21T14:13:21Z", "rounded up, as the formatter always did")
    }
}
