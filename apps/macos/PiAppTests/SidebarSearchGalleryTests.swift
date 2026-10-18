import AppKit
import XCTest
@testable import PiApp

final class SidebarSearchGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testSearchScopeScenes() async throws {
        guard let path = testEnvironment("PI_APP_SEARCH_SCOPE_GALLERY") else { throw XCTSkip("Set PI_APP_SEARCH_SCOPE_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = scratchRoot("search-scope-gallery"), model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        registerWorkspaceFixtureTeardown(model, root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model.workspaces = [WorkspaceRecord(id: "orchard", path: root.appendingPathComponent("Orchard").path, trusted: true)]
        model.topics = [TopicRecord(id: "launch", workspaceID: "orchard", title: "Product launch")]
        var profile = ProfileRecord(); profile.id = "studio"; profile.name = "Studio"; profile.modelId = "design-model"
        model.profiles = [profile]
        for (id, title, text, archived) in [("notes", "Lantern release notes", "Polish the launch checklist.", false),
                                           ("copy", "Welcome screen copy", "The lantern illustration needs a warmer glow.", false),
                                           ("old", "Earlier design review", "Keep the lantern beside the welcome message.", true)] {
            let journal = try SearchJournal(root.appendingPathComponent(id + ".jsonl"), id: id)
            try journal.message("message-" + id, role: "user", text)
            var chat = ChatRecord(id: id, workspaceID: "orchard", title: title, path: journal.url.path, profileID: profile.id)
            chat.topicID = "launch"; if archived { chat.archivedAt = Date() }
            model.chats.append(chat)
        }
        model.setArchivedChatsShown(true)
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await model.sidebarSearch.reconcileNow()
        sidebar.setFilter("lantern")
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for scope in SidebarSearch.Scope.allCases {
                sidebar.searchScope.tab(scope)?.performClick(nil)
                await model.sidebarSearch.settleQuery(); sidebar.settle()
                for width: CGFloat in [300, 200] {
                    window.setContentSize(NSSize(width: width, height: 640))
                    for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        window.appearance = NSAppearance(named: appearance)
                        sidebar.needsLayout = true; sidebar.settle(); window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        XCTAssertTrue(sidebar.bounds.contains(sidebar.searchScope.frame))
                        for mode in SidebarSearch.Scope.allCases {
                            let tab = try XCTUnwrap(sidebar.searchScope.tab(mode))
                            XCTAssertGreaterThanOrEqual(tab.bounds.width, tab.intrinsicContentSize.width)
                        }
                        let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                        sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                        let name = "\(flat ? "flat" : "topics")-\(scope == .fullChats ? "full" : "details")-\(Int(width))-\(theme).png"
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
                    }
                }
            }
        }
    }
}

final class SidebarSearchKeyboardTests: XCTestCase, SerialTestLane {
    @MainActor func testFocusVisibilityKeyboardAndVoiceOverSelectionWithoutRowMovement() async throws {
        let root = scratchRoot("search-scope-keyboard"), model = makeWorkspaceModel(stateRoot: root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "search-scope-" + UUID().uuidString
        let group = PiKit.Box.ClipView(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
        sidebar.frame = group.bounds; group.addSubview(sidebar); window.contentView = group
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(nil); sidebar.settle()
        XCTAssertTrue(sidebar.searchScope.isHidden)
        let origin = sidebar.scroll.frame.minY
        XCTAssertTrue(window.makeFirstResponder(sidebar.filterField.field))
        let editor = try XCTUnwrap(sidebar.filterField.field.currentEditor() as? NSTextView)
        sidebar.settle()
        try await eventually("The focused search shows its scope") { !sidebar.searchScope.isHidden }
        XCTAssertFalse(sidebar.searchScope.isHidden, "Focus alone starts searching")
        let delegate = try XCTUnwrap(sidebar.filterField.field.delegate as? SidebarFilterDelegate)
        XCTAssertTrue(delegate.control(sidebar.filterField.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(window.firstResponder === sidebar.searchScope.tab(.titlesAndDetails))
        await Task.yield(); sidebar.settle()
        XCTAssertFalse(sidebar.searchScope.isHidden, "Tab can reach the pill with an empty query")
        XCTAssertTrue(try XCTUnwrap(sidebar.searchScope.tab(.fullChats)).acceptsFirstResponder)
        XCTAssertTrue(try XCTUnwrap(sidebar.searchScope.tab(.fullChats)).canBecomeKeyView)
        XCTAssertTrue(sidebar.searchScope.tab(.titlesAndDetails)?.nextValidKeyView === sidebar.searchScope.tab(.fullChats))
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === sidebar.searchScope.tab(.fullChats), "Tab reaches the second scope")
        window.selectNextKeyView(nil)
        let chain = [sidebar.filterField.field, sidebar.searchScope.tab(.titlesAndDetails)!, sidebar.searchScope.tab(.fullChats)!, sidebar.clearFilter, sidebar.scroll].map {
            "\($0.accessibilityLabel() ?? String(describing: type(of: $0)))) key=\($0.canBecomeKeyView) next=\($0.nextKeyView?.accessibilityLabel() ?? String(describing: $0.nextKeyView)) valid=\($0.nextValidKeyView?.accessibilityLabel() ?? String(describing: $0.nextValidKeyView))"
        }.joined(separator: "\n")
        XCTAssertFalse((window.firstResponder as? NSView)?.isDescendant(of: sidebar.searchScope) == true, "Tab also leaves the pill: \(String(describing: window.firstResponder))\n" + chain)
        let ax = try await AXClient.find(in: window) { $0.label == "Search scope" }
        XCTAssertEqual(ax.role, "AXGroup")
        XCTAssertEqual(ax.children.map(\.label), ["Titles & details", "Full chats"])
        XCTAssertEqual(ax.children.map(\.selected), [true, false])
        sidebar.searchScope.tab(.fullChats)?.performClick(nil)
        _ = try await AXClient.find(in: window) { $0.label == "Search scope" && $0.children.map(\.selected) == [false, true] }
        for query in ["l", "lantern", ""] {
            sidebar.setFilter(query); sidebar.settle()
            XCTAssertEqual(sidebar.scroll.frame.minY, origin)
        }
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        sidebar.settle()
        XCTAssertTrue(sidebar.searchScope.isHidden)
        XCTAssertEqual(sidebar.scroll.frame.minY, origin)
        sidebar.setFilter("lantern"); sidebar.settle()
        XCTAssertFalse(sidebar.searchScope.isHidden, "A query keeps the pill visible without focus")
    }
}
