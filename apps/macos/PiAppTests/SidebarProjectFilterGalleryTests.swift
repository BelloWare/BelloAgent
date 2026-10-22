import AppKit
import XCTest
@testable import PiApp

/// Flat's project filter, drawn on its own (0.1.131, SIDEBAR-1): every
/// project, one project chosen by its chip, one chosen from the "+N" menu at
/// the minimum width, and a search across every project, at the normal and
/// minimum sidebar widths in both appearances. Drawn offscreen: no window is
/// shown or focused. The open "+N" menu is `UIScreenshotTests` 14i.
final class SidebarProjectFilterGalleryTests: XCTestCase {
    @MainActor func testProjectFilterScenes() async throws {
        guard let path = testEnvironment("PI_APP_PROJECT_FILTER_GALLERY") else { throw XCTSkip("Set PI_APP_PROJECT_FILTER_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = scratchRoot("project-filter-gallery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        registerWorkspaceFixtureTeardown(model, root: root)
        let projects = [("app", "pi-app"), ("box", "BelloBox"), ("site", "belloware-site"), ("views", "bello-views")]
        model.workspaces = projects.map { WorkspaceRecord(id: $0.0, path: root.appendingPathComponent($0.1).path, trusted: true) }
        model.topics = [TopicRecord(id: "transcript", workspaceID: "app", title: "transcript"),
                        TopicRecord(id: "sidebar", workspaceID: "app", title: "sidebar"),
                        TopicRecord(id: "capture", workspaceID: "box", title: "capture")]
        var profile = ProfileRecord(); profile.id = "studio"; profile.name = "Studio"; profile.modelId = "design-model"
        model.profiles = [profile]
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000), minute: Int64 = 60_000_000
        func chat(_ id: String, _ title: String, in project: String, minutesAgo: Int64, topic: String? = nil, pinned: Bool = false) -> ChatRecord {
            var value = ChatRecord(id: id, workspaceID: project, title: title, path: nil, profileID: profile.id, sidebarOrder: now - minutesAgo * minute)
            value.topicID = topic
            if pinned { value.pinnedAt = Date() }
            return value
        }
        model.chats = [chat("checklist", "Release checklist", in: "app", minutesAgo: 2_000, pinned: true),
                       chat("scroll", "Fix scrolling", in: "app", minutesAgo: 2, topic: "transcript"),
                       chat("release", "Release 0.1.130", in: "app", minutesAgo: 60),
                       chat("save", "Save dialog fix", in: "box", minutesAgo: 180, topic: "capture"),
                       chat("filter", "Sidebar project filter", in: "app", minutesAgo: 240, topic: "sidebar"),
                       chat("landing", "Landing page copy", in: "site", minutesAgo: 600),
                       chat("overlay", "Capture overlay notes", in: "box", minutesAgo: 900),
                       chat("git", "Git view polish", in: "views", minutesAgo: 1_400),
                       chat("probe", "Connection test", in: WorkspaceRecord.scratchID, minutesAgo: 1_600)]
        model.unreadStates["scroll"] = SessionReadState(id: "scroll", observedAssistantCount: 2, latestAssistantID: "m", unreadOutputs: 1)
        model.runHolds["release"] = RunHoldRecord(id: "release", state: "paused")
        model.selectedID = "save"
        model.setSidebarFlat(true)
        model.setSidebarShownRoots(SidebarSessionPresentation.combinedFlatGroupID, to: 100, in: "")

        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar
        defer { window.contentView = nil; window.close() }
        func draw(_ scene: String, widths: [CGFloat] = [WindowChrome.sidebarWidth, WindowChrome.minimumSidebarWidth]) async throws {
            for width in widths {
                window.setContentSize(NSSize(width: width, height: 700))
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    sidebar.needsLayout = true; sidebar.settle(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let bar = sidebar.projectFilter
                    if !bar.isHidden {
                        var placed: [NSView] = [bar.all]
                        if !bar.more.isHidden { placed.append(bar.more) }
                        placed += bar.placement.shown.compactMap { bar.buttons[bar.laidOut[$0].projectID] }
                        for view in placed { XCTAssertLessThanOrEqual(view.frame.maxX, bar.bounds.width + 0.5, "\(scene) \(Int(width))") }
                    }
                    let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                    sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                    let name = "project-filter-\(scene)-\(Int(width))-\(theme).png"
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
                }
            }
        }
        try await draw("all")
        window.setContentSize(NSSize(width: WindowChrome.sidebarWidth, height: 700)); sidebar.settle()
        XCTAssertFalse(try XCTUnwrap(sidebar.projectFilter.buttons["box"]).isHidden)
        sidebar.projectFilter.buttons["box"]?.performClick(nil)
        XCTAssertEqual(model.sidebarFlatProject, "box")
        try await draw("project")
        sidebar.projectFilter.all.performClick(nil)
        // At the minimum width a project from the "+N" menu takes the chips' last place.
        window.setContentSize(NSSize(width: WindowChrome.minimumSidebarWidth, height: 700)); sidebar.settle()
        var menu: NSMenu?
        PiMenus.intercept = { built, _ in menu = built }
        defer { PiMenus.intercept = nil }
        sidebar.projectFilter.more.performClick(nil)
        XCTAssertTrue(PiMenus.perform("sidebarProjectFilterMenu-site", in: try XCTUnwrap(menu)))
        XCTAssertEqual(model.sidebarFlatProject, "site")
        try await draw("from-menu", widths: [WindowChrome.minimumSidebarWidth])
        sidebar.projectFilter.all.performClick(nil)
        sidebar.setFilter("fix")
        try await draw("search")
        sidebar.setFilter("")
    }
}
