import XCTest
@testable import PiApp

/// Every way the app writes an amount of money or a report's token count,
/// pinned value by value. A change to how any of them rounds, or to which
/// digits it keeps, shows up here cell by cell, and nowhere else first.
final class MoneyFormatGoldenTests: XCTestCase {
    /// One amount as each style writes it: `exact` is `gatewayUSD` (request
    /// pages, pills' details, the ledger, the menu bar, the report's help);
    /// `compact` is `compactGatewayUSD` (pills, turn cards, charts); `row`
    /// the report's cost column; `monitor` the live monitor and the report's
    /// tiles; `line` the transcript's per-request accounting line, nil where
    /// the line leaves an invalid cost out.
    private struct Money {
        let value: Double?
        let exact: String, compact: String, row: String, monitor: String
        let line: String?
    }

    private static let money: [Money] = [
        Money(value: nil, exact: "Cost unavailable", compact: "cost n/a", row: "—", monitor: "—", line: nil),
        Money(value: -1, exact: "Cost unavailable", compact: "cost n/a", row: "Cost unavailable", monitor: "—", line: nil),
        Money(value: .nan, exact: "Cost unavailable", compact: "cost n/a", row: "Cost unavailable", monitor: "—", line: nil),
        Money(value: .infinity, exact: "Cost unavailable", compact: "cost n/a", row: "Cost unavailable", monitor: "—", line: nil),
        Money(value: 0, exact: "$0 USD", compact: "$0", row: "$0", monitor: "$0", line: "$0 USD"),
        Money(value: 5e-13, exact: "$5.00e-13 USD", compact: "$5e-13", row: "$5.00e-13", monitor: "$5e-13", line: "$5.00e-13 USD"),
        Money(value: 1e-12, exact: "$1.00e-12 USD", compact: "$0.000000000001", row: "$1.00e-12", monitor: "$0.000000000001", line: "$1.00e-12 USD"),
        Money(value: 1e-10, exact: "$1.00e-10 USD", compact: "$0.0000000001", row: "$1.00e-10", monitor: "$0.0000000001", line: "$1.00e-10 USD"),
        Money(value: 1.23e-9, exact: "$1.23e-9 USD", compact: "$0.00000000123", row: "$1.23e-9", monitor: "$0.00000000123", line: "$1.23e-9 USD"),
        Money(value: 1.25e-9, exact: "$1.25e-9 USD", compact: "$0.00000000125", row: "$1.25e-9", monitor: "$0.00000000125", line: "$1.25e-9 USD"),
        Money(value: 2e-9, exact: "$2.00e-9 USD", compact: "$0.000000002", row: "$2.00e-9", monitor: "$0.000000002", line: "$2.00e-9 USD"),
        Money(value: 9.999e-9, exact: "$1.00e-8 USD", compact: "$0.000000009999", row: "$1.00e-8", monitor: "$0.000000009999", line: "$1.00e-8 USD"),
        Money(value: 1e-8, exact: "$0.00000001 USD", compact: "$0.00000001", row: "$0.00000001", monitor: "$0.00000001", line: "$0.00000001 USD"),
        Money(value: 1.5e-8, exact: "$0.00000002 USD", compact: "$0.000000015", row: "$0.00000002", monitor: "$0.000000015", line: "$0.00000002 USD"),
        Money(value: 1.25e-7, exact: "$0.00000013 USD", compact: "$0.000000125", row: "$0.00000013", monitor: "$0.000000125", line: "$0.00000013 USD"),
        Money(value: 1e-5, exact: "$0.00001 USD", compact: "$0.00001", row: "$0.00001", monitor: "$0.00001", line: "$0.00001 USD"),
        Money(value: 0.0004, exact: "$0.0004 USD", compact: "$0.0004", row: "$0.0004", monitor: "$0.0004", line: "$0.0004 USD"),
        Money(value: 0.000421875, exact: "$0.00042188 USD", compact: "$0.000421875", row: "$0.00042188", monitor: "$0.000421875", line: "$0.00042188 USD"),
        Money(value: 0.0012345, exact: "$0.0012345 USD", compact: "$0.0012345", row: "$0.0012345", monitor: "$0.0012345", line: "$0.0012345 USD"),
        Money(value: 0.0013875, exact: "$0.0013875 USD", compact: "$0.0013875", row: "$0.0013875", monitor: "$0.0013875", line: "$0.0013875 USD"),
        Money(value: 0.005, exact: "$0.005 USD", compact: "$0.005", row: "$0.005", monitor: "$0.005", line: "$0.005 USD"),
        Money(value: 0.025, exact: "$0.025 USD", compact: "$0.025", row: "$0.025", monitor: "$0.025", line: "$0.025 USD"),
        Money(value: 0.123456785, exact: "$0.12345679 USD", compact: "$0.123456785", row: "$0.12345679", monitor: "$0.123456785", line: "$0.12345679 USD"),
        Money(value: 0.5, exact: "$0.5 USD", compact: "$0.5", row: "$0.5", monitor: "$0.5", line: "$0.5 USD"),
        Money(value: 1, exact: "$1 USD", compact: "$1.00", row: "$1", monitor: "$1", line: "$1 USD"),
        Money(value: 1.5, exact: "$1.5 USD", compact: "$1.50", row: "$1.5", monitor: "$1.5", line: "$1.5 USD"),
        Money(value: 2.12345678, exact: "$2.12345678 USD", compact: "$2.12345678", row: "$2.12345678", monitor: "$2.12345678", line: "$2.12345678 USD"),
        Money(value: 12.345, exact: "$12.345 USD", compact: "$12.345", row: "$12.345", monitor: "$12.345", line: "$12.345 USD"),
        Money(value: 100, exact: "$100 USD", compact: "$100.00", row: "$100", monitor: "$100", line: "$100 USD"),
        Money(value: 1234.5678, exact: "$1234.5678 USD", compact: "$1234.5678", row: "$1234.5678", monitor: "$1234.5678", line: "$1234.5678 USD"),
    ]

    /// The transcript's per-request line for one reported request costing
    /// `value`: the figure it ends with, or nil when the line has no cost.
    private func lineCost(_ value: Double) -> String? {
        var a = GatewayTotals()
        a.requests = 1; a.costSamples = 1; a.costUSD = value
        a.tokens = GatewayTokenTotals(input: 38, output: 423, total: 461, inputSamples: 1, outputSamples: 1, samples: 1)
        let summary = TranscriptActivity.accountingPresentation(a).summary
        guard summary.contains("USD") else { return nil }
        return summary.components(separatedBy: " · ").last
    }

    @MainActor func testEveryMoneyStyleWritesEachAmountAsPinned() {
        for row in Self.money {
            let label = row.value.map { "\($0)" } ?? "nil"
            XCTAssertEqual(gatewayUSD(row.value), row.exact, "exact \(label)")
            XCTAssertEqual(compactGatewayUSD(row.value), row.compact, "compact \(label)")
            XCTAssertEqual(reportUSD(row.value), row.row, "row \(label)")
            XCTAssertEqual(monitorCost(row.value), row.monitor, "monitor \(label)")
            if let value = row.value {
                XCTAssertEqual(lineCost(value), row.line, "line \(label)")
                // The request line and every other exact figure are one style.
                if let line = row.line { XCTAssertEqual(line, row.exact, "the request line and the exact figure \(label)") }
                // The figures a turn card and the charts write are the compact style.
                if value.isFinite && value >= 0 {
                    XCTAssertEqual(TranscriptActivity.formatTurnCost(value), row.compact, "turn card \(label)")
                    XCTAssertEqual(SessionStatsFormat.cost(value), row.compact, "chart \(label)")
                }
            }
        }
    }

    /// A report's token count, and the pills' count of the same tokens.
    private static let tokens: [(value: Double?, report: String, pill: String?)] = [
        (nil, "—", nil), (0, "0", "0"), (1, "1", "1"), (999, "999", "999"), (999.4, "999", "999"), (999.5, "1.0k", "1K"),
        (1_000, "1.0k", "1K"), (1_049, "1.0k", "1K"), (1_050, "1.1k", "1.1K"), (9_949, "9.9k", "9.9K"), (9_950, "10k", "10K"),
        (9_960, "10k", "10K"), (9_999, "10k", "10K"), (10_000, "10k", "10K"), (10_499, "10k", "10.5K"), (10_500, "11k", "10.5K"),
        (999_499, "999k", "999K"), (999_500, "1.0M", "1M"), (999_950, "1.0M", "1M"), (1_000_000, "1.0M", "1M"),
        (1_049_999, "1.0M", "1M"), (1_050_000, "1.1M", "1.1M"), (999_949_999, "999.9M", "1B"), (1e9, "1.0B", "1B"),
        (1.5e9, "1.5B", "1.5B"),
    ]

    @MainActor func testEveryTokenCountIsWrittenAsPinned() {
        for row in Self.tokens {
            let label = row.value.map { "\($0)" } ?? "nil"
            XCTAssertEqual(reportTokens(row.value), row.report, "report \(label)")
            if let value = row.value, let pill = row.pill { XCTAssertEqual(MetricFormat.tokens(value), pill, "pill \(label)") }
        }
    }
}
