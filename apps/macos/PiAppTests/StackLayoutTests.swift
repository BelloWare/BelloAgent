import AppKit
import XCTest
@testable import PiApp

/// The ported screens share their rows' width as `HStack` did. The figures
/// were measured from SwiftUI (macOS 14): `HStack(spacing: 8) { Text("A");
/// Spacer(); Text("B") }` is 42 points at its ideal, the same row with the
/// default spacing 26, and with `Spacer(minLength: 0)` 18.
@MainActor final class StackLayoutTests: XCTestCase {
    private func fixed(_ width: CGFloat) -> StackLayout.Item { StackLayout.Item(view: nil, sizing: .fixed(CGSize(width: width, height: 16))) }

    func testSpacersTakeTheirLeastLengthAndTheSpacingAroundThemOnlyWhenItIsGiven() {
        let a = fixed(9), b = fixed(9)
        XCTAssertEqual(StackLayout.width([a, .spacer(), b], spacing: 8, proposal: .infinity), 42)
        XCTAssertEqual(StackLayout.width([a, .spacer(0), b], spacing: 8, proposal: .infinity), 34)
        XCTAssertEqual(StackLayout.width([a, .spacer(), b], spacing: StackLayout.system, proposal: .infinity), 26)
        XCTAssertEqual(StackLayout.width([a, .spacer(0), b], spacing: StackLayout.system, proposal: .infinity), 18)
        XCTAssertEqual(StackLayout.width([a, b], spacing: StackLayout.system, proposal: .infinity), 26, "8 between views")
    }

    /// A spacer is given what the others leave: the views are offered their
    /// shares as if it were not there. Counted with them, a 223-point child
    /// beside a long label was offered 198 and fell back to its narrow form.
    func testASpacerIsOfferedWhatTheOthersLeave() {
        var offered: CGFloat = 0
        let picky = StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { proposal in offered = proposal; return proposal >= 223 ? 223 : 82 },
                                                                          height: { _ in 26 }))
        let label = StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { min(600, max(0, $0)) }, height: { _ in 14 }))
        let widths = StackLayout.widths([label, fixed(90), picky, fixed(97.5), fixed(145.5), .spacer()], spacing: 8, proposal: 968)
        XCTAssertEqual(widths[2], 223, "offered \(offered)")
        XCTAssertEqual(widths.reduce(0, +) + 5 * 8, 968, accuracy: 0.001, "the row filled")
    }

    func testTheLeastFlexibleChildIsOfferedItsShareFirst() {
        let flexible = StackLayout.Item(view: nil, sizing: StackLayout.Sizing(width: { min(500, max(0, $0)) }, height: { _ in 14 }))
        let widths = StackLayout.widths([flexible, fixed(100)], spacing: 0, proposal: 300)
        XCTAssertEqual(widths, [200, 100])
    }
}
