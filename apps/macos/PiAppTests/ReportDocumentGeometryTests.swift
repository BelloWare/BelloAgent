import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Measure the original resolved rows without a window. A lazy table's
/// unconstrained estimate cannot stand in for the height of all its rows.
@MainActor final class ReportDocumentGeometryTests: XCTestCase {
    private let labels = ["Started", "Session", "Requested → final model", "Status", "Cost", "Tokens", "Duration", "Cache"]
    private func request(_ index: Int, reasoning: Bool = true, conflict: Bool = false) -> DashboardRequest {
        var row = DashboardRequest(id: "request-\(index)", sessionID: "session-\(index)", workspaceID: "project",
            wall: Date(timeIntervalSince1970: 1_790_000_000), purpose: "turn", api: "openai-responses", alias: "fixture-fast",
            effectiveModel: conflict ? nil : "fixture-fast-responses", identityStatus: conflict ? "conflict" : "reported",
            reportedModels: conflict ? ["provider/model-A", "model-B"] : [], outcome: "completed", ttft: 50, streaming: 500, http: 600)
        row.gateway.costUSD = 0.005; row.gateway.costStatus = "reported"
        row.gateway.inputTokens = 80; row.gateway.outputTokens = 170
        row.gateway.reasoningTokens = reasoning ? 31 : nil
        row.gateway.cacheReadTokens = 60; row.gateway.cacheStatus = "miss"
        return row
    }
    private func measure<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        // The original outer vertical ScrollView offers its column an ideal
        // height; a horizontal ScrollView must not consume the 10,000-point
        // measurement limit as if it were a viewport.
        NSHostingController(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).environment(\.piReduceMotion, true))
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }
    private func nativeRow(_ row: DashboardRequest, width: CGFloat, detailed: Bool, title: String? = "Retry loop", nested: Bool = false) -> ReportRequestRow {
        let view = ReportRequestRow(item: row, title: title, detailed: detailed, inspect: {}, message: {}, nested: nested)
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.intrinsicContentSize.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testHeaderAndRequestHeightsMatchTheFrozenRows() {
        for width: CGFloat in [1100, 1232] {
            let header = ReportGridRow(cells: labels)
            let oldHeader = measure(ReportGridRowReference(cells: labels, header: true), width: width)
            print("REPORTGEOMETRY header width=\(width) old=\(oldHeader) native=\(header.intrinsicContentSize.height)")
            XCTAssertEqual(header.intrinsicContentSize.height, oldHeader, accuracy: 0.25)
            for detailed in [false, true] {
                for (name, row, title, nested) in [
                    ("reported", request(0), Optional("Retry loop"), false),
                    ("no-reasoning", request(1, reasoning: false), Optional("Retry loop"), false),
                    ("untitled", request(2), nil, false),
                    ("nested", request(3), nil, true),
                    ("conflicting", request(4, conflict: true), Optional("Retry loop"), false),
                ] {
                    let old = measure(ReportRequestRowReference(item: row, title: title, detailed: detailed, inspect: {}, nested: nested), width: width)
                    let native = nativeRow(row, width: width, detailed: detailed, title: title, nested: nested)
                    print("REPORTGEOMETRY \(name) detailed=\(detailed) width=\(width) old=\(old) native=\(native.intrinsicContentSize.height)")
                    XCTAssertEqual(native.intrinsicContentSize.height, old, accuracy: 0.25, "\(name), detailed=\(detailed), width=\(width)")
                }
            }
        }
    }

    private func nativeTable(rows: [DashboardRequest], width: CGFloat, detailed: Bool) -> ReportGridScroll {
        var items: [ShellItem] = [.view(ReportGridRow(cells: labels), .fill), .view(FixedHeight(HairlineView(), height: 1, fills: true), .fill)]
        for row in rows {
            items.append(.view(nativeRow(row, width: width, detailed: detailed), .fill))
            items.append(.view(FixedHeight(HairlineView(), height: 1, fills: true), .fill))
        }
        let column = ShellStack(.vertical, spacing: 0, items)
        return ReportGridScroll(content: PiKit.inset(column), width: width)
    }

    func testResolvedTableHeightDoesNotAccumulateRowDrift() {
        let rows = (0..<9).map { request($0, reasoning: $0 % 3 != 0) }
        for detailed in [false, true] {
            for width: CGFloat in [1100, 1232] {
                let old = measure(ReportResolvedTableReference(rows: rows, labels: labels, detailed: detailed), width: width)
                let native = nativeTable(rows: rows, width: width, detailed: detailed)
                print("REPORTGEOMETRY table detailed=\(detailed) width=\(width) old=\(old) native=\(native.height(forWidth: width))")
                XCTAssertEqual(native.height(forWidth: width), old, accuracy: 0.25, "Every resolved row and separator contributes its actual height")
            }
        }
    }

    func testOuterScrollDocumentKeepsTheOriginalColumnHeightAtNarrowAndWideWidths() {
        let rows = (0..<9).map { request($0, reasoning: $0 % 3 != 0) }
        for width: CGFloat in [620, 1139, 1440] {
            // Identical resolved cards above the table, independent of live
            // values. The table and footer retain their real measured views.
            let above: CGFloat = 780
            let gridWidth = max(1100, min(1280, width) - 2 * PiSpacing.xl)
            let table = nativeTable(rows: rows, width: gridWidth, detailed: false)
            let footer = ReportDetailsToggle(action: {})
            let column = ShellStack(.vertical, spacing: PiSpacing.lg, [
                .view(FixedHeight(DashView(), height: above, fills: true), .fill), .view(table, .fill), .view(footer),
            ])
            let scroll = PageScrollView(column: column)
            scroll.scrollerStyle = .overlay
            scroll.maximumWidth = 1280
            scroll.insets = NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.xl, bottom: PiSpacing.lg, right: PiSpacing.xl)
            scroll.frame = CGRect(x: 0, y: 0, width: width, height: 840)
            scroll.layoutSubtreeIfNeeded(); scroll.fit()
            let old = measure(ReportResolvedColumnReference(rows: rows, labels: labels, above: above, gridWidth: gridWidth), width: width)
            let native = scroll.documentView?.frame.height ?? 0
            print("REPORTGEOMETRY document width=\(width) old=\(old) native=\(native) clip=\(scroll.contentSize)")
            XCTAssertEqual(native, old, accuracy: 0.25, "The outer document uses the original padded column height")
        }
    }
}
