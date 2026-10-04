import XCTest
import SwiftUI
import AppKit
@testable import PiApp
@testable import GitView

/// A sheet closed with the pointer over it, the app in front, lets go of what
/// it showed before the test returns. XCTest keeps whatever AppKit
/// autoreleases until a test returns, and with the pointer over a hover
/// region (every Pi button has one) in a key window that includes the sheet's
/// hosting view: a sheet closed with its Done button kept its views
/// and its controller that long, and the checks that nothing keeps them failed
/// now and then. The app itself lets go of them as the closing turn ends.
/// Forcing it takes the app in front and the real pointer over the sheet,
/// which events sent to the view do not reproduce, so the test runs only when
/// asked (`PI_POINTER_TESTS=1`), in the serial lane, and puts the pointer back
/// where it found it.
final class SheetHoverReleaseTests: GitPanelTestCase, SerialTestLane {
    @MainActor final class Presenter: ObservableObject { @Published var showing = false }

    /// How many sheet contents are alive: each `Hovered` holds one as its state.
    @MainActor final class Marker: ObservableObject {
        static var live = 0
        init() { Marker.live += 1 }
        deinit { MainActor.assumeIsolated { Marker.live -= 1 } }
    }

    /// A sheet's content with hover regions, as every Pi button has.
    private struct Hovered: View {
        @StateObject private var marker = Marker()
        var body: some View {
            let _ = marker
            PiSheet("Hovered", width: 600, height: 400) {
                VStack(spacing: PiSpacing.lg) {
                    PiIconButton(symbol: "arrow.clockwise", label: "Refresh", size: 28) {}
                    Button("Done") {}
                }
            }
        }
    }

    private struct Host: View {
        @ObservedObject var presenter: Presenter
        var body: some View { Color.clear.piSheetWindow(isPresented: $presenter.showing) { Hovered() } }
    }

    /// A window presenting `view`, with the app in front, as it is when it is
    /// used (a hidden app shown again is), and the pointer put back where it
    /// was once the test is over; the screen's coordinates run down.
    @MainActor private func inFront<V: View>(_ view: V, size: NSSize) async throws -> (window: NSWindow, screen: NSScreen) {
        guard testEnvironment("PI_POINTER_TESTS") == "1" else {
            throw XCTSkip("Moves the pointer and brings the app to the front: set PI_POINTER_TESTS=1 to run")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let pointer = NSEvent.mouseLocation
        addTeardownBlock { CGWarpMouseCursorPosition(CGPoint(x: pointer.x, y: screen.frame.height - pointer.y)) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(500))
        NSApp.hide(nil); try await Task.sleep(for: .milliseconds(400))
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        guard NSApp.isActive else { throw XCTSkip("The test host could not come to the front") }
        return (window, screen)
    }

    @MainActor func testASheetClosedUnderThePointerLetsGoOfWhatItShowed() async throws {
        let presenter = Presenter(), before = Marker.live
        let (window, screen) = try await inFront(Host(presenter: presenter), size: NSSize(width: 1000, height: 700))
        addTeardownBlock { @MainActor in presenter.showing = false }

        for pass in 1...2 {
            presenter.showing = true
            try await eventually("the sheet") { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            CGWarpMouseCursorPosition(CGPoint(x: sheet.frame.midX, y: screen.frame.height - sheet.frame.midY))
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(sheet.isKeyWindow, "Pass \(pass): the sheet is key")
            XCTAssertTrue(sheet.frame.contains(NSEvent.mouseLocation), "Pass \(pass): the pointer is over it")
            XCTAssertEqual(Marker.live, before + 1)
            presenter.showing = false
            try await eventually("closed") { window.attachedSheet == nil }
            try await eventually("pass \(pass): its content let go of, the pointer still over where it was") { Marker.live == before }
        }
    }

    /// A Changes tab, closed as the reader closes it, the pointer over its
    /// panel: its controller goes, with everything it read.
    @MainActor func testAChangesTabClosedUnderThePointerLetsGoOfItsController() async throws {
        let folder = try repository("changes-under-pointer")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try start(folder)
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: folder); try git(["commit", "-q", "-m", "Seed"], in: folder)
        try "one!\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let host = TabHost(defaults: nil)
        host.showsWindows = false
        addTeardownBlock { @MainActor in host.tearDown() }
        let (window, screen) = try await inFront(TabWindowRootBridge(host: host, container: host.pane), size: NSSize(width: 1280, height: 860))
        var controllers: [() -> GitController?] = []
        for pass in 1...2 {
            weak var tab = autoreleasepool { host.open(kind: ChangesTab.kind, key: "under-pointer") { ChangesTab(projectID: "under-pointer", name: "project", roots: [folder.path]) } as? ChangesTab }
            try await eventually("the Changes tab") { tab?.hasController == true && tab?.controller.statusRead == true }
            weak var controller = tab?.controller
            controllers.append { [weak controller] in controller }
            CGWarpMouseCursorPosition(CGPoint(x: window.frame.midX, y: screen.frame.height - window.frame.midY))
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(window.frame.contains(NSEvent.mouseLocation), "Pass \(pass): the pointer is over the panel")
            autoreleasepool { if let tab { host.close(tab) } }
            try await eventually("pass \(pass): its controller let go of, the pointer still over where it was") { autoreleasepool { controller == nil } }
        }
        XCTAssertEqual(controllers.compactMap { $0() }.count, 0, "No closed Changes tab's controller is left")
    }
}
