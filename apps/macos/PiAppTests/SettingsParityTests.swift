import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The AppKit settings rows look as the SwiftUI `PiRow` did, pixel for
/// pixel: a long label offered half the row, as `HStack` offered it, the
/// control at the trailing edge of a frame up to 380 points wide.
@MainActor final class SettingsParityTests: XCTestCase {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func check<V: View>(_ name: String, width: CGFloat, _ swiftUI: V, _ appKit: NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await PiKitParity.compare(name, appearance: .aqua, swiftUI: swiftUI.frame(width: width), appKit: appKit, canvas: .piSurface, width: width)
        XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height.rounded(.up), accuracy: 1.01, "\(name) height", file: file, line: line)
        // Symbols and switches' edges aside, the same picture.
        XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * 0.03, result.description, file: file, line: line)
    }

    func testALongLabelIsOfferedHalfTheRow() async throws {
        let detail = "A finished turn folds its work behind one line above the answer."
        try await check("row-dropdown", width: 590,
                        PiRow(label: "Finished turns", detail: detail, last: true) {
                            PiDropdown(selection: .constant("compact"), items: [("normal", "Normal"), ("compact", "Compact")], compact: true)
                        },
                        SettingsRow(label: "Finished turns", detail: detail, last: true,
                                    control: PiKit.Dropdown(selection: "compact", items: [("normal", "Normal"), ("compact", "Compact")], compact: true)))
    }

    func testAFieldTakesTheRestUpTo380() async throws {
        try await check("row-field", width: 590,
                        PiRow(label: "Name", detail: "Rename freely: the connection keeps its id, key, chats and model cache.") {
                            PiTextField(placeholder: "Team router", text: .constant("Team router · Responses"))
                        },
                        SettingsRow(label: "Name", detail: "Rename freely: the connection keeps its id, key, chats and model cache.",
                                    control: PiKit.TextField(placeholder: "Team router", text: "Team router · Responses")))
    }

    func testAShortLabelAndASwitch() async throws {
        try await check("row-switch", width: 590,
                        PiRow(label: "Allow fallback models", last: true) { Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.piSwitch) },
                        SettingsRow(label: "Allow fallback models", last: true, control: PiKit.Switch(isOn: true)))
    }
}
