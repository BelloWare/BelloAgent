import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Escape leaves a sheet. Every sheet used to need its own cancel button for
/// that and most never had one; `PiSheet` carries the cancel action itself.
/// A presented sheet's key press cannot be driven from a test process, so the
/// wiring is asserted where AppKit resolves it: the hosted view's own key
/// equivalent handling.
final class PiSheetCancelTests: XCTestCase {
    @MainActor private func host(_ sheet: some View) throws -> (window: NSWindow, hosted: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: sheet.transaction { $0.animation = nil; $0.disablesAnimations = true })
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        hosted.needsLayout = true
        hosted.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, hosted)
    }

    private func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53))
    }

    /// Nothing in the sheet has to declare a cancel button for Escape to work.
    @MainActor func testASheetWithNoCancelButtonOfItsOwnStillTakesEscape() throws {
        let sheet = PiSheet("Inspector", symbol: "ladybug", width: 420, height: 260) {
            Text("Nothing here declares a cancel action.")
        }
        let (window, hosted) = try host(sheet)
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(hosted.performKeyEquivalent(with: try escape()),
                      "A sheet has to answer Escape without each one wiring its own cancel button")
    }

    /// A sheet in the middle of a write it must not be closed under holds
    /// Escape back until the write finishes.
    @MainActor func testASheetMidWriteHoldsEscapeBackUntilTheWriteFinishes() throws {
        let busy = PiSheet("Rename chat", symbol: "pencil", width: 420, height: 260, cancelDisabled: true) {
            Text("Renaming…")
        }
        let (window, hosted) = try host(busy)
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(hosted.performKeyEquivalent(with: try escape()),
                       "A rename being written must not be closed under by Escape")
    }

    /// The same chrome used as a window keeps the system's own behaviour: a
    /// Settings window is not a sheet and does not close on Escape.
    @MainActor func testTheSameChromeInAWindowDoesNotClaimEscape() throws {
        let asWindow = PiSheet("Settings", symbol: "gearshape", width: 420, height: 260, windowChrome: true) {
            Text("A window, not a sheet.")
        }
        let (window, hosted) = try host(asWindow)
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(hosted.performKeyEquivalent(with: try escape()),
                       "A window keeps ⌘W, not Escape")
    }
}
