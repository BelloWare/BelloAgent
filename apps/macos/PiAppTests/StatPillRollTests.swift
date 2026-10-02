import XCTest
import SwiftUI
@testable import PiApp

/// A stat pill's figure that changes rolls to its new value; the figures of
/// another chat replace the old ones at once (`PiStatPillFace.scope`). Rolled,
/// a whole pill was drawn again on the CPU for some twenty frames on every
/// chat switch, the main thread's largest drawing cost there. The pill's
/// press target is the same view throughout, and says and opens what the
/// pill now shows.
final class StatPillRollTests: XCTestCase, SerialTestLane {
    @MainActor private final class Shown: ObservableObject {
        @Published var label = "7.3K tok · 80 uncached · 40 cached · 7.2K out · Cache hit 33.33% · $0.005"
        @Published var scope = 1
        var pressed: [Int] = []
    }
    private struct Pill: View {
        @ObservedObject var shown: Shown
        var body: some View {
            PiStatButton(symbol: "cylinder.split.1x2", label: shown.label, scope: shown.scope, accessibility: "Usage of \(shown.scope)",
                         identifier: "usage") { [shown, scope = shown.scope] in shown.pressed.append(scope) }
                .padding(20)
        }
    }

    @MainActor private func host(_ shown: Shown) -> (NSWindow, NSHostingView<Pill>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: Pill(shown: shown))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        return (window, hosted)
    }

    /// How many times SwiftUI draws the pill on the CPU while `change` takes
    /// effect and any animation it starts runs out.
    @MainActor private func draws(_ hosted: NSView, _ window: NSWindow, _ change: () -> Void) async throws -> Int {
        SoakDrawLedger.begin(window)
        defer { SoakDrawLedger.end() }
        change()
        // Longer than the roll (`PiMotion.base`), drawing every frame.
        let end = ProcessInfo.processInfo.systemUptime + 0.8
        while ProcessInfo.processInfo.systemUptime < end {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
        }
        return SoakDrawLedger.entries.values.reduce(0) { $0 + $1.count }
    }

    @MainActor private func settle(_ hosted: NSView, _ window: NSWindow) async throws {
        _ = try await draws(hosted, window) {}
    }

    @MainActor private func trigger(_ hosted: NSView) throws -> PiPopoverTriggerButton {
        try XCTUnwrap(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: hosted).first)
    }

    @MainActor func testAnotherChatsFiguresReplaceTheOldOnesWithoutRolling() async throws {
        let shown = Shown()
        let (window, hosted) = host(shown)
        defer { window.contentView = nil; window.close() }
        try await settle(hosted, window)
        let button = try trigger(hosted)

        // The same chat's figure changes: it rolls, drawn frame by frame.
        let rolled = try await draws(hosted, window) { shown.label = "7.4K tok · 81 uncached · 40 cached · 7.3K out · Cache hit 33.10% · $0.006" }
        XCTAssertGreaterThan(rolled, 5, "A figure of the same chat rolls to its new value")

        // Another chat's figures: replaced at once.
        let replaced = try await draws(hosted, window) {
            shown.scope = 2; shown.label = "12.9K tok · 400 uncached · 1.2K cached · 11.1K out · Cache hit 75.00% · $0.0213"
        }
        XCTAssertLessThanOrEqual(replaced, 3, "Another chat's figures do not roll from the old chat's")

        // A switch in the middle of a roll: the roll stops there.
        SoakDrawLedger.begin(window)
        shown.label = "13.0K tok · 401 uncached · 1.2K cached · 11.2K out · Cache hit 74.90% · $0.0214"
        try await eventually("the roll drawing its frames", timeout: .seconds(5), poll: .milliseconds(8)) {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return SoakDrawLedger.entries.values.reduce(0) { $0 + $1.count } >= 2
        }
        SoakDrawLedger.end()
        let midRoll = try await draws(hosted, window) {
            shown.scope = 1; shown.label = "7.4K tok · 81 uncached · 40 cached · 7.3K out · Cache hit 33.10% · $0.006"
        }
        XCTAssertLessThanOrEqual(midRoll, 3, "A switch during a roll does not go on rolling")
        // And back at once.
        let back = try await draws(hosted, window) {
            shown.scope = 2; shown.label = "13.0K tok · 401 uncached · 1.2K cached · 11.2K out · Cache hit 74.90% · $0.0214"
        }
        XCTAssertLessThanOrEqual(back, 3)

        // The press target is the same view, saying and opening the new chat's.
        let after = try trigger(hosted)
        XCTAssertTrue(after === button, "The pill's press target was not made again")
        XCTAssertEqual(after.accessibilityLabel(), "Usage of 2")
        after.performClick(nil)
        XCTAssertEqual(shown.pressed, [2])
    }
}
