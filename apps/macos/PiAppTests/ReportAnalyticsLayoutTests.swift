import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The original routing stack measures its icon and caption together, so a
/// fractional icon slot cannot move the centred box or its following name.
@MainActor final class ReportAnalyticsLayoutTests: XCTestCase {
    func testRoutingAliasKeepsItsOriginalImageSlotAndCaptionSpacing() throws {
        let box = ModelRoutingMap.AliasBox(alias: "fixture-fast")
        box.frame = CGRect(x: 0, y: 0, width: 116, height: box.height(forWidth: 116))
        box.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(box.subviews.compactMap { $0 as? PiKit.SymbolView }.first)
        let caption = try XCTUnwrap(box.subviews.compactMap { $0 as? ShellSelectableText }.first)
        XCTAssertEqual(box.frame.height, 55, accuracy: 0.01, "The v0.1.119 alias box is 55 points tall")
        XCTAssertEqual(image.frame.height, 18, accuracy: 0.01)
        XCTAssertEqual(caption.frame.minY - image.frame.maxY, 5, accuracy: 0.01)
        XCTAssertEqual(box.frame.height - caption.frame.maxY, 9, accuracy: 0.01)
    }
}

@MainActor final class ReportAnalyticsParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    func testRoutingAliasMatchesTheOriginalStackInBothAppearances() async throws {
        for alias in ["fixture-fast", "ui-fixture"] {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let result = try await PiKitParity.compare("routing-alias-\(alias)-\(suffix)", appearance: appearance,
                    swiftUI: ReportRoutingAliasReference(alias: alias), appKit: ModelRoutingMap.AliasBox(alias: alias), canvas: .piSurface, width: 116)
                print("ROUTINGPARITY " + result.description)
                XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.25, result.description)
                XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * MonitorParityTests.allowedShare, result.description)
                let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: MonitorParityTests.strongChannel).0
                XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * MonitorParityTests.strongShare, "\(result.name): \(strong) strong pixels")
            }
        }
    }
}
