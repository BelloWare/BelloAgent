import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A sheet the app presents in a window of its own (`piSheetWindow`), as the
/// Changes sheet now is: the same window as SwiftUI's sheet, sized the same,
/// closed by Escape and Done as before, taken down with the window it is on,
/// and given back what its presenter's environment says. What it lets go of
/// once closed is `ChangesSheetFrameTests.testAClosedSheetLetsGoOfWhatItRead`.
final class PiSheetWindowTests: XCTestCase {
    @MainActor final class Presenter: ObservableObject {
        @Published var showing = false
        @Published var reduceMotion = false
        @Published var disabled = false
    }

    /// What the sheet's content was handed, as it last drew.
    @MainActor final class Seen: ObservableObject {
        var reduceMotion: Bool?
        var enabled: Bool?
    }

    private struct Recorder: View {
        let seen: Seen
        @Environment(\.piReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let _ = { seen.reduceMotion = reduceMotion; seen.enabled = enabled }()
            PiSheet("Probe", symbol: "gearshape", width: 420, height: 260) { Text("A sheet of the app's own.") }
        }
    }

    private struct AppHost<Content: View>: View {
        @ObservedObject var presenter: Presenter
        @ViewBuilder let content: () -> Content
        var body: some View {
            Color.clear
                .piSheetWindow(isPresented: $presenter.showing, content: content)
                .environment(\.piReduceMotion, presenter.reduceMotion)
                .disabled(presenter.disabled)
        }
    }

    private struct SwiftUIHost<Content: View>: View {
        @ObservedObject var presenter: Presenter
        @ViewBuilder let content: () -> Content
        var body: some View { Color.clear.sheet(isPresented: $presenter.showing, content: content) }
    }

    @MainActor private func parent<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return window
    }

    @MainActor private func eventually(_ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Never \(what)", file: file, line: line)
    }

    private func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53))
    }

    /// The window is the one SwiftUI made for its sheets: document modal,
    /// sized to the content and held at that size, not opaque, on the window
    /// background, with the content first in line for the keyboard. It is the app's own,
    /// so `DismissedSheets` leaves it alone.
    @MainActor func testTheSheetIsTheWindowSwiftUIWouldHaveMade() async throws {
        let theirs = Presenter(), ours = Presenter()
        let swiftUIParent = parent(SwiftUIHost(presenter: theirs) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        let appParent = parent(AppHost(presenter: ours) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        theirs.showing = true
        try await eventually("SwiftUI's sheet") { swiftUIParent.attachedSheet != nil }
        let reference = try XCTUnwrap(swiftUIParent.attachedSheet)
        try await Task.sleep(for: .milliseconds(600))
        ours.showing = true
        try await eventually("the app's sheet") { appParent.attachedSheet != nil }
        let sheet = try XCTUnwrap(appParent.attachedSheet)
        XCTAssertTrue(sheet === PiSheetWindow.newest)
        XCTAssertFalse(DismissedSheets.presentedBySwiftUI(sheet), "Not one of SwiftUI's sheet windows")
        XCTAssertEqual(sheet.styleMask, reference.styleMask)
        XCTAssertEqual(sheet.frame.size, reference.frame.size)
        XCTAssertEqual(sheet.frame.size, CGSize(width: 420, height: 260))
        XCTAssertEqual(sheet.contentMinSize, reference.contentMinSize)
        XCTAssertEqual(sheet.contentMaxSize, reference.contentMaxSize)
        XCTAssertEqual(sheet.isOpaque, reference.isOpaque)
        XCTAssertEqual(sheet.backgroundColor, reference.backgroundColor)
        XCTAssertEqual(sheet.hasShadow, reference.hasShadow)
        XCTAssertTrue(sheet.initialFirstResponder === sheet.contentView, "The content takes the keyboard, as in SwiftUI's sheet")
        theirs.showing = false; ours.showing = false
        try await eventually("both closed") { swiftUIParent.attachedSheet == nil && appParent.attachedSheet == nil }
    }

    /// Escape closes it, as it closed SwiftUI's sheet, and what presented it
    /// is told.
    @MainActor func testEscapeClosesIt() async throws {
        let presenter = Presenter()
        let window = parent(AppHost(presenter: presenter) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        presenter.showing = true
        try await eventually("the sheet") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        weak var content = sheet.contentView
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(try XCTUnwrap(sheet.contentView).performKeyEquivalent(with: try escape()), "Escape leaves the sheet")
        try await eventually("closed by Escape") { !presenter.showing && window.attachedSheet == nil }
        try await eventually("its content let go of") { content == nil }
    }

    /// The Changes panel itself closes from its window: Escape, which PiSheet
    /// carries, and Done both call the close action the window hands down in
    /// place of `dismiss`, which has no SwiftUI sheet to end there. (SwiftUI
    /// builds no accessibility tree for a test to press Done through.)
    @MainActor func testTheChangesPanelClosesFromItsWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-changes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let presenter = Presenter()
        let window = parent(AppHost(presenter: presenter) { GitPanelView(roots: [folder.path]) })
        window.setContentSize(NSSize(width: 1280, height: 860))
        presenter.showing = true
        try await eventually("the Changes sheet") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(sheet.frame.size, CGSize(width: 1180, height: 780), "The panel's own size, as SwiftUI's sheet had it")
        weak var content = sheet.contentView
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(try XCTUnwrap(sheet.contentView).performKeyEquivalent(with: try escape()), "Escape leaves the Changes sheet")
        try await eventually("closed") { !presenter.showing && window.attachedSheet == nil }
        try await eventually("its content let go of") { content == nil }
    }

    /// A window that closes takes its sheet down with it, and what presented
    /// the sheet is told, as a SwiftUI sheet's binding would be.
    @MainActor func testTheWindowItIsOnClosingTakesItDown() async throws {
        let presenter = Presenter()
        let window = parent(AppHost(presenter: presenter) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        presenter.showing = true
        try await eventually("the sheet") { window.attachedSheet != nil }
        weak var sheet = window.attachedSheet, content = window.attachedSheet?.contentView
        try await Task.sleep(for: .milliseconds(400))
        window.close()
        try await eventually("the binding told") { !presenter.showing }
        try await eventually("the sheet down and let go of") { sheet?.isVisible != true && content == nil }
    }

    /// The view that presented it going away takes it down at once, and
    /// nothing of it is left behind waiting on an animation.
    @MainActor func testThePresenterGoingTakesItDown() async throws {
        let presenter = Presenter()
        let window = parent(AppHost(presenter: presenter) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        presenter.showing = true
        try await eventually("the sheet") { window.attachedSheet != nil }
        weak var sheet = window.attachedSheet, content = window.attachedSheet?.contentView
        try await Task.sleep(for: .milliseconds(400))
        window.contentView = NSView()
        try await eventually("the sheet down") { window.attachedSheet == nil && sheet?.isVisible != true }
        try await eventually("its content let go of") { content == nil }
    }

    /// Asked for again while it is sliding away, it comes back.
    @MainActor func testAskedForAgainWhileItClosesItComesBack() async throws {
        let presenter = Presenter()
        let window = parent(AppHost(presenter: presenter) { PiSheet("Probe", width: 420, height: 260) { Text("Probe") } })
        presenter.showing = true
        try await eventually("the sheet") { window.attachedSheet != nil }
        weak var first = window.attachedSheet
        try await Task.sleep(for: .milliseconds(400))
        presenter.showing = false
        try await Task.sleep(for: .milliseconds(40))
        presenter.showing = true
        try await eventually("a sheet again") { window.attachedSheet != nil && window.attachedSheet !== first }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(presenter.showing, "Still asked for")
        XCTAssertNotNil(window.attachedSheet, "and still up")
        presenter.showing = false
        try await eventually("closed") { window.attachedSheet == nil }
    }

    /// What the view that presents it sets, the sheet inherits, as SwiftUI's
    /// sheet did: Reduce Motion, and a window made unavailable while an update
    /// installs. A change to either while it is up reaches it.
    @MainActor func testTheSheetInheritsWhatItsPresenterSets() async throws {
        let presenter = Presenter(), seen = Seen()
        presenter.reduceMotion = true; presenter.disabled = true
        let window = parent(AppHost(presenter: presenter) { Recorder(seen: seen) })
        presenter.showing = true
        try await eventually("the sheet") { window.attachedSheet != nil && seen.enabled != nil }
        XCTAssertEqual(seen.reduceMotion, true)
        XCTAssertEqual(seen.enabled, false)
        presenter.reduceMotion = false; presenter.disabled = false
        try await eventually("the change reaching the sheet") { seen.reduceMotion == false && seen.enabled == true }
        presenter.showing = false
        try await eventually("closed") { window.attachedSheet == nil }
    }
}
