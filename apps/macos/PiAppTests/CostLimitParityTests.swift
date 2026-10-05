import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The cost limit's meter, choices and editor drawn next to the SwiftUI
/// originals (`CostLimitParityReferences.swift`): the editor is in the stop
/// notice's popover, Session info and Settings, which the gallery shows only
/// in part.
///
/// Serial: the windows are on screen.
@MainActor final class CostLimitParityTests: XCTestCase, SerialTestLane {
    static let allowedShare = 0.012
    static let strongChannel = 64
    static let strongShare = 0.002
    private var results: [PiKitParity.Result] = []

    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("COSTLIMITPARITY " + result.description) }
    }

    private func check<V: View>(_ name: String, width: CGFloat, _ swiftUI: () -> V, _ appKit: () -> NSView,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance, swiftUI: swiftUI().frame(width: width),
                                                       appKit: appKit(), width: width)
            results.append(result)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * Self.allowedShare, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: Self.strongChannel).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * Self.strongShare, "\(result.name): \(strong) px differ past \(Self.strongChannel)", file: file, line: line)
        }
    }

    static let readings: [(String, SessionCostReading)] = [
        ("spent", SessionCostReading(limit: .usd(25), override: nil, defaultLimit: .usd(25), spentUSD: 4.12, reportedRequests: 9)),
        ("warning", SessionCostReading(limit: .usd(5), override: .usd(5), defaultLimit: .usd(25), spentUSD: 4.6, reportedRequests: 12, unreportedRequests: 2)),
        ("over", SessionCostReading(limit: .usd(5), override: .usd(5), defaultLimit: .usd(25), spentUSD: 5.12, reportedRequests: 12)),
        ("unlimited", SessionCostReading(limit: .unlimited, override: .unlimited, defaultLimit: .usd(25), spentUSD: nil)),
        ("custom", SessionCostReading(limit: .usd(7.5), override: .usd(7.5), defaultLimit: .usd(25), spentUSD: 0.003, reportedRequests: 1)),
    ]

    func testTheMeter() async throws {
        for (name, reading) in Self.readings {
            try await check("meter-\(name)", width: 320, { RefCostLimitMeter(reading: reading) }, { CostLimitMeter(reading: reading) })
        }
    }

    func testTheChoices() async throws {
        try await check("choices-default", width: 348, { RefCostLimitChoices(selection: nil, defaultLimit: .usd(25), choose: { _ in }) },
                        { CostLimitChoices(selection: nil, defaultLimit: .usd(25)) { _ in } })
        try await check("choices-custom", width: 348, { RefCostLimitChoices(selection: .usd(7.5), defaultLimit: .usd(25), choose: { _ in }) },
                        { CostLimitChoices(selection: .usd(7.5), defaultLimit: .usd(25)) { _ in } })
        // Settings: no default chip, a preset chosen.
        try await check("choices-settings", width: 420, { RefCostLimitChoices(selection: .usd(25), choose: { _ in }, identifier: "settings-cost-limit") },
                        { CostLimitChoices(selection: .usd(25), identifier: "settings-cost-limit") { _ in } })
    }

    func testTheEditor() async throws {
        for (name, reading) in Self.readings {
            try await check("editor-\(name)", width: 348, { RefCostLimitEditor(reading: reading, choose: { _ in }) },
                            { CostLimitEditor(reading: reading) { _ in } })
        }
        let reading = Self.readings[1].1
        try await check("editor-raise", width: 348, { RefCostLimitEditor(reading: reading, title: "Raise this chat's limit", choose: { _ in }) },
                        { CostLimitEditor(reading: reading, title: "Raise this chat's limit") { _ in } })
    }
}
