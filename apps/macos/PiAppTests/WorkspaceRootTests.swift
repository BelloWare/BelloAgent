import AppKit
import XCTest
@testable import PiApp

/// The workspace window's AppKit root: the sidebar's handle, the pages over
/// the chats, the error strip's easing, and the install cover.
final class WorkspaceRootTests: XCTestCase {
    @MainActor private func root(_ name: String) throws -> (WorkspaceModel, WorkspaceRootView, NSWindow) {
        let folder = URL(fileURLWithPath: scratchBase()).appendingPathComponent("root-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: folder.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: folder)
        let view = WorkspaceRootView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        return (model, view, window)
    }

    /// Dragging the sidebar's handle moves the boundary as it goes and keeps
    /// where it lands; the handle stays centred on the hairline.
    @MainActor func testTheSidebarHandleDragsAndKeepsTheWidth() throws {
        let stored = UserDefaults.standard.object(forKey: "sidebarWidth")
        defer { if let stored { UserDefaults.standard.set(stored, forKey: "sidebarWidth") } else { UserDefaults.standard.removeObject(forKey: "sidebarWidth") } }
        UserDefaults.standard.set(300.0, forKey: "sidebarWidth")
        let (_, view, _) = try root("handle")
        view.refresh(); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.sidebar.frame.width, 300)
        view.sidebarHandle.changed?(40)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.sidebar.frame.width, 340, "the boundary follows the drag")
        XCTAssertEqual(view.chrome.frame.width, 340, "and the chrome above the sidebar with it")
        XCTAssertEqual(view.sidebarHandle.frame.midX, 340.5, accuracy: 0.01, "the handle stays on the hairline")
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidebarWidth"), 300, "nothing is kept mid-drag")
        view.sidebarHandle.ended?(60)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.sidebar.frame.width, 360)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidebarWidth"), 360, "where it lands is kept")
        view.sidebarHandle.ended?(1_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.sidebar.frame.width, WindowChrome.maximumSidebarWidth, "within its bounds")
    }

    /// A page lies over the chats, which stay mounted but neither show, take
    /// clicks, nor read to VoiceOver; back on the chats, they are as they were.
    @MainActor func testAPageCoversTheChats() async throws {
        let (model, view, window) = try root("page")
        let chats = try XCTUnwrap(view.subviewsOfType(WorkspaceChatsLayer.self).first)
        let welcome = try XCTUnwrap(view.subviewsOfType(WorkspaceWelcomeView.self).first)
        let point = welcome.convert(NSPoint(x: welcome.bounds.midX, y: welcome.bounds.midY), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point)?.isDescendant(of: chats) == true, "the chats take clicks")
        model.page = .background
        try await eventually("the page covers the chats") { view.layoutSubtreeIfNeeded(); return chats.alphaValue == 0 }
        XCTAssertTrue(welcome.isDescendant(of: chats), "the chats stay mounted")
        XCTAssertFalse(window.contentView?.hitTest(point)?.isDescendant(of: chats) == true, "covered, they take no clicks")
        let local = try XCTUnwrap(chats.superview).convert(point, from: nil)
        XCTAssertNil(chats.hitTest(local), "not even where nothing lies over them")
        XCTAssertTrue(chats.isAccessibilityHidden(), "nor read to VoiceOver")
        model.page = .chats
        try await eventually("back on the chats") { view.layoutSubtreeIfNeeded(); return chats.alphaValue == 1 }
        XCTAssertTrue(window.contentView?.hitTest(point)?.isDescendant(of: chats) == true)
        XCTAssertFalse(chats.isAccessibilityHidden())
    }

    /// The error strip takes its room in one step, so the conversation's
    /// edge never drags the reader's line; the banner itself comes down and
    /// fades in, and fades out over the conversation as it goes. Dismiss
    /// clears the error.
    @MainActor func testTheErrorStripTakesItsRoomAtOnceAndItsBannerMoves() async throws {
        let (model, view, _) = try root("strip")
        let strip = view.errorStrip
        XCTAssertEqual(strip.frame.height, 0)
        model.error = "The gateway rejected the request: the key has expired."
        try await eventually("the strip comes") { view.layoutSubtreeIfNeeded(); return strip.banner != nil }
        view.layoutSubtreeIfNeeded()
        let banner = try XCTUnwrap(strip.banner)
        let full = 12 + banner.height(forWidth: min(640, strip.bounds.width - 48)) + 8
        XCTAssertEqual(strip.frame.height, full, accuracy: 0.5, "all of its room at once")
        if !PiKit.Motion.reduced { XCTAssertNotNil(banner.layer?.animation(forKey: "arrive"), "the banner comes down and in") }
        banner.dismissButton.performClick(nil)
        XCTAssertNil(model.error)
        try await eventually("the room is given back at once") { view.layoutSubtreeIfNeeded(); return strip.frame.height == 0 }
        if !PiKit.Motion.reduced { XCTAssertNotNil(banner.superview, "the banner fades out over the conversation") }
        try await eventually("then the banner is gone") { banner.superview == nil }
    }

    /// While an update installs, a cover says so and nothing takes input.
    @MainActor func testInstallingCoversTheWindow() async throws {
        let (model, view, _) = try root("install")
        model.installPreparing = true
        try await eventually("the cover is up") { view.subviewsOfType(WorkspaceInstallCover.self).count == 1 }
        XCTAssertFalse(view.sidebar.inheritedEnabled, "the sidebar takes no input")
        let welcome = try XCTUnwrap(view.subviewsOfType(WorkspaceWelcomeView.self).first)
        XCTAssertFalse(welcome.projects.isEnabled, "nor do the welcome's buttons")
        model.installPreparing = false
        try await eventually("the cover goes") { view.subviewsOfType(WorkspaceInstallCover.self).isEmpty }
        XCTAssertTrue(view.sidebar.inheritedEnabled)
        XCTAssertTrue(welcome.projects.isEnabled)
    }

    /// A side's row reads its title and what it shows under it, and goes
    /// quiet with the window.
    @MainActor func testASideRowReadsWhatItShows() throws {
        let (model, _, _) = try root("sides")
        var parent = ChatRecord(id: "P", workspaceID: "p", title: "Parent", path: nil, profileID: "none"); parent.sidebarOrder = 1
        var side = ChatRecord(id: "S", workspaceID: "p", title: "Idempotency keys for refunds", path: nil, profileID: "none")
        side.parentSessionID = "P"; side.sidebarOrder = 2
        model.workspaces = [WorkspaceRecord(id: "p", path: "/tmp/p", trusted: true)]
        model.chats = [parent, side]
        let panel = SidesPanelView(model: model, parentID: "P", pinned: true)
        panel.frame = NSRect(x: 0, y: 0, width: SidesPanelMetrics.width, height: 400)
        panel.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(panel.subviewsOfType(SidesPanelRowView.self).first)
        XCTAssertEqual(row.row.accessibilityLabel(), "Idempotency keys for refunds, Saved")
        panel.inheritedEnabled = false
        XCTAssertFalse(row.row.isEnabled); XCTAssertFalse(panel.pin.isEnabled); XCTAssertFalse(panel.newSide.isEnabled)
    }

    /// A sheet asked for follows the root out of its window and back: it goes
    /// with the window and comes again when the root is in a window again.
    @MainActor func testASheetFollowsTheRootBetweenWindows() async throws {
        let (model, view, window) = try root("sheet")
        model.showWorkspaceManager = true
        try await eventually("the sheet is up") { window.attachedSheet != nil }
        window.contentView = nil
        try await eventually("it goes with the window") { window.attachedSheet == nil }
        XCTAssertTrue(model.showWorkspaceManager, "the model still asks for it")
        window.contentView = view
        try await eventually("and it comes back") { window.attachedSheet != nil }
        model.showWorkspaceManager = false
        try await eventually("closed when no longer asked for") { window.attachedSheet == nil }
    }
}
