import XCTest
@testable import PiApp

/// How a sidebar row writes its cost and its token count, and a cost limit
/// its dollars, pinned value by value as `MoneyFormatGoldenTests` pins the
/// other styles. A change to how any of them rounds, or to which digits it
/// keeps, shows up here cell by cell.
final class SidebarFigureGoldenTests: XCTestCase {
    /// One amount as a sidebar row's cost (`ChatRowStats.costLabel`) and a
    /// cost limit (`CostLimit.dollars`) write it.
    private static let money: [(value: Double, row: String, limit: String)] = [
        (0, "$0", "$0.00"),
        (1e-12, "<$0.0001", "<$0.000001"),
        (1e-7, "<$0.0001", "<$0.000001"),
        (4.9e-7, "<$0.0001", "<$0.000001"),
        (5e-7, "<$0.0001", "$0.000001"),
        (0.000001, "<$0.0001", "$0.000001"),
        (0.0000015, "<$0.0001", "$0.000002"),
        (0.00004, "<$0.0001", "$0.00004"),
        (0.00005, "$0.0001", "$0.00005"),
        (0.00015, "$0.0002", "$0.00015"),
        (0.000421875, "$0.0004", "$0.000422"),
        (0.0005, "$0.0005", "$0.0005"),
        (0.001, "$0.0010", "$0.001"),
        (0.00125, "$0.0013", "$0.00125"),
        (0.005, "$0.0050", "$0.005"),
        (0.0099, "$0.0099", "$0.0099"),
        (0.0099949, "$0.01", "$0.009995"),
        (0.00995, "$0.01", "$0.00995"),
        (0.0099995, "$0.01", "$0.01"),
        (0.01, "$0.01", "$0.01"),
        (0.015, "$0.02", "$0.02"),
        (0.125, "$0.13", "$0.13"),
        (0.5, "$0.50", "$0.50"),
        (1, "$1.00", "$1.00"),
        (1.005, "$1.01", "$1.01"),
        (2.675, "$2.68", "$2.68"),
        (4.125, "$4.13", "$4.13"),
        (25, "$25.00", "$25.00"),
        (99.995, "$100.00", "$100.00"),
        (1234.5678, "$1234.57", "$1234.57"),
        (1_000_000, "$1000000.00", "$1000000.00"),
    ]

    @MainActor func testEverySidebarCostAndLimitIsWrittenAsPinned() {
        for row in Self.money {
            var totals = GatewayTotals(requests: 1); totals.costUSD = row.value; totals.costSamples = 1
            XCTAssertEqual(ChatRowStats(totals: totals).costLabel, row.row, "row \(row.value)")
            XCTAssertEqual(CostLimit.dollars(row.value), row.limit, "limit \(row.value)")
        }
        // A cost that is not a finite amount of zero or more is not written.
        for value in [-1, Double.nan, .infinity] {
            var totals = GatewayTotals(requests: 1); totals.costUSD = value; totals.costSamples = 1
            XCTAssertEqual(ChatRowStats(totals: totals).costLabel, "cost n/a", "row \(value)")
            XCTAssertEqual(CostLimit.dollars(value), "$0.00", "limit \(value)")
        }
        XCTAssertEqual(ChatRowStats(totals: GatewayTotals(requests: 1)).costLabel, "cost n/a")
        XCTAssertNil(ChatRowStats(totals: nil).costLabel)
    }

    /// A sidebar row's token count (`ChatRowStats.tokensLabel`).
    private static let tokens: [(value: Double, row: String)] = [
        (0, "0 tok"), (1, "1 tok"), (92, "92 tok"), (999, "999 tok"), (999.4, "999 tok"), (999.5, "1.0K tok"),
        (1_000, "1.0K tok"), (1_049, "1.0K tok"), (1_050, "1.1K tok"), (1_250, "1.3K tok"), (9_949, "9.9K tok"),
        (9_950, "10.0K tok"), (9_999, "10.0K tok"), (12_345, "12.3K tok"), (99_950, "100.0K tok"), (999_499, "999.5K tok"),
        (999_949, "999.9K tok"), (999_950, "1.0M tok"), (1_000_000, "1.0M tok"), (1_049_999, "1.0M tok"),
        (1_050_000, "1.1M tok"), (1_250_000, "1.3M tok"), (999_949_999, "999.9M tok"), (999_950_000, "1.0B tok"),
        (1e9, "1.0B tok"), (1.5e9, "1.5B tok"),
    ]

    @MainActor func testEverySidebarTokenCountIsWrittenAsPinned() {
        for row in Self.tokens {
            var totals = GatewayTotals(requests: 1)
            totals.tokens = GatewayTokenTotals(input: 0, output: row.value, total: row.value, inputSamples: 1, outputSamples: 1, samples: 1)
            XCTAssertEqual(ChatRowStats(totals: totals).tokensLabel, row.row, "tokens \(row.value)")
        }
        XCTAssertEqual(ChatRowStats(totals: GatewayTotals(requests: 1)).tokensLabel, "tok n/a")
        XCTAssertNil(ChatRowStats(totals: nil).tokensLabel)
    }
}
