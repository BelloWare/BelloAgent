import XCTest
import AppKit
import FileFinder
@testable import PiApp

// Window-backed pointer and scroll checks run alone.
final class FileFolderTests: XCTestCase, SerialTestLane {
    @MainActor override func setUp() async throws { installStandaloneFileResolver(self) }

    @MainActor func testFixtureOwnsInheritedHooks() async throws {
        try await checkStandaloneFileResolverSetup(self) { try await self.setUp() }
    }

    @MainActor func testFileHeaderOffersFolderToggleAndClickableAncestors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: url)
        let tab = FileTab(url: url, projectID: nil)
        defer { tab.willClose() }
        let header = FileTabHeader(tab: tab)
        header.refresh(); header.frame = NSRect(x: 0, y: 0, width: 600, height: 32); header.layoutSubtreeIfNeeded()
        let buttons = descendants(NSButton.self, in: header)
        XCTAssertNotNil(buttons.first { $0.accessibilityIdentifier() == "file-folder-toggle" })
        XCTAssertTrue(buttons.contains { $0.accessibilityLabel()?.contains("file.txt") == true && $0.accessibilityIdentifier().hasPrefix("file-crumb-") == true })
    }
    @MainActor func testCrumbMenuListsFoldersLazilyAndOpensSiblingThroughChatPath() async throws {
        let (model, root) = try await fixture()
        let first = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let crumb = try XCTUnwrap(FileBreadcrumb.path(to: first.url, project: ("Project", root)).dropLast().last)
        let menu = FileFolderMenu(crumb: crumb, projectRoot: root, open: { first.openNearbyFile?($0) }, showTree: { _ in })
        defer { menu.browser.stop() }
        let folder = first.url.deletingLastPathComponent()
        try await until { menu.browser.snapshot(folder) != nil }
        XCTAssertNil(menu.browser.snapshot(folder.appendingPathComponent("nested")))
        let names = menu.entries.compactMap { entry -> String? in
            switch entry { case .submenu(let title, _, _, _, _): return title
            case .item(let item) where item.identifier?.hasPrefix("/") == true: return item.title
            default: return nil }
        }
        XCTAssertEqual(names, ["nested", "a.txt", "b.txt"])
        XCTAssertTrue(PiMenus.perform(root.appendingPathComponent("Sources/b.txt").path, in: PiMenus.menu(menu.entries)))
        let opened = try XCTUnwrap(model.tabs.pane.activeTab as? FileTab)
        XCTAssertEqual(opened.url.path, root.appendingPathComponent("Sources/b.txt").path)
        XCTAssertTrue(opened === model.openFile(fromChat: "unused", path: opened.url.path, lines: nil))
        menu.enter(folder.appendingPathComponent("nested"))
        try await until { menu.browser.snapshot(folder.appendingPathComponent("nested")) != nil }
        menu.back(); XCTAssertEqual(menu.browser.root?.path, folder.path)
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testTreeRevealsSelectsAndOpensSiblingWithReturn() async throws {
        let (model, root) = try await fixture()
        let first = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let content = first.contentView
        first.folders.setShown(true)
        try await until { first.folders.browser.rows.contains { $0.url == first.url } }
        let browser = first.folders.browser, tree = first.folders.panel.tree
        XCTAssertEqual(browser.selectedURL, first.url)
        XCTAssertEqual(browser.rows[tree.table.selectedRow].url, first.url)
        let sibling = root.appendingPathComponent("Sources/b.txt")
        browser.select(sibling)
        XCTAssertTrue(tree.navigate(keyCode: 36))
        XCTAssertEqual((model.tabs.pane.activeTab as? FileTab)?.url.path, sibling.path)
        XCTAssertTrue(model.tabs.pane.fileFolders.shown)
        XCTAssertNotNil(content.content as? FileTabContent)
    }

    @MainActor func testTreeKeyboardCollapsesExpandsAndSelectsParent() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        tab.folders.setShown(true)
        let browser = tab.folders.browser, tree = tab.folders.panel.tree
        try await until { browser.rows.contains { $0.url == tab.url } }
        XCTAssertTrue(tree.navigate(keyCode: 123))
        XCTAssertEqual(browser.selectedURL?.path, root.appendingPathComponent("Sources").path)
        XCTAssertTrue(tree.navigate(keyCode: 123))
        XCTAssertFalse(browser.expanded.contains(FileBreadcrumb.normalized(root.appendingPathComponent("Sources"))))
        XCTAssertTrue(tree.navigate(keyCode: 123))
        XCTAssertEqual(browser.selectedURL?.path, root.appendingPathComponent("Sources").path, "Left must keep the top-level row selected")
        XCTAssertTrue(tree.navigate(keyCode: 124))
        XCTAssertTrue(browser.expanded.contains(FileBreadcrumb.normalized(root.appendingPathComponent("Sources"))))
    }

    @MainActor func testUntrustedFilesCanBrowseWithoutReadingContentOrStartingHelper() async throws {
        let (model, root) = try await fixture(trusted: false)
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        tab.folders.setShown(true)
        try await until { tab.folders.browser.rows.contains { $0.url == tab.url } }
        XCTAssertNil(tab.folders.projectRoot)
        XCTAssertEqual(tab.folders.browser.root?.path, tab.url.deletingLastPathComponent().path)
        XCTAssertFalse(tab.readable); XCTAssertNil(tab.document); XCTAssertFalse(tab.hasDocument)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(model.workspaces.first!.trusted)
        let sibling = try XCTUnwrap(tab.folders.browser.rows.first { $0.url.lastPathComponent == "b.txt" }?.entry)
        tab.folders.browser.activate(sibling)
        XCTAssertFalse((model.tabs.pane.activeTab as? FileTab)?.readable ?? true)
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testNoProjectFileStartsAtParentAndCanGoUp() async throws {
        let (model, _) = try await fixture()
        let root = try directory()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        XCTAssertNil(tab.projectID); XCTAssertTrue(tab.readable)
        XCTAssertTrue(model.hosts.isEmpty)
        tab.folders.setShown(true)
        try await until { tab.folders.browser.rows.contains { $0.url == tab.url } }
        XCTAssertEqual(tab.folders.browser.root?.path, root.appendingPathComponent("Sources").path)
        XCTAssertTrue(tab.folders.browser.canGoUp)
        tab.folders.browser.goUp()
        try await until { tab.folders.browser.snapshot(root) != nil }
        XCTAssertEqual(tab.folders.browser.root?.path, root.path)
        XCTAssertEqual(tab.folders.browser.selectedURL, tab.url)
    }

    @MainActor func testFolderSettingsPersistPerPaneAndOldSavedStateRestores() async throws {
        let root = try directory(), suite = "file-folders-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = TabHost(defaults: defaults); host.showsWindows = false; host.restore()
        defer { host.tearDown() }
        let tab = host.open(kind: FileTab.kind, key: root.appendingPathComponent("Sources/a.txt").path) { FileTab(url: root.appendingPathComponent("Sources/a.txt"), projectID: nil) } as! FileTab
        XCTAssertFalse(host.pane.fileFolders.shown)
        tab.folders.setShown(true); tab.folders.setWidth(246); host.flush()
        let saved = try XCTUnwrap(defaults.data(forKey: TabHost.savedKey))
        let restored = TabHost(defaults: defaults); restored.showsWindows = false; restored.restore()
        XCTAssertEqual(restored.pane.fileFolders, FileFolderSettings(shown: true, width: 246))
        let restoredFile = try XCTUnwrap(restored.pane.activeTab as? FileTab)
        let restoredWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        restoredWindow.isReleasedWhenClosed = false; restoredWindow.contentView = restoredFile.contentView
        XCTAssertTrue(restoredFile.readable, "The standalone fixture must not inherit another workspace's resolver")
        XCTAssertTrue(restoredFile.isShownNow)
        XCTAssertNotNil(restoredFile.folders.browser.root, "A restored visible file must load the remembered tree without switching tabs")
        restoredWindow.contentView = nil; restoredWindow.close()
        restored.tearDown()
        let popped = host.popOut(tab)
        XCTAssertFalse(popped.fileFolders.shown)
        XCTAssertEqual(popped.fileFolders.width, 200)
        host.move(tab, to: host.pane)
        XCTAssertTrue(tab.folders.settings.shown)
        XCTAssertEqual(tab.folders.settings.width, 246)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var pane = try XCTUnwrap(json["pane"] as? [String: Any]); pane.removeValue(forKey: "fileFolders"); json["pane"] = pane
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: TabHost.savedKey)
        let legacy = TabHost(defaults: defaults); legacy.restore()
        XCTAssertEqual(legacy.pane.tabs.count, 1); XCTAssertFalse(legacy.pane.fileFolders.shown)
        legacy.tearDown()
    }

    @MainActor func testFallbackFileSuspendsWhenSideReturnsAndRefreshesOnRemount() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let pane = RightPaneView(model: model, host: model.tabs, pane: model.tabs.pane)
        pane.makeSideView = { _, _, _ in NSView() }
        let side = (info: SideRecord(id: "side", parentID: "main", workspaceID: "project", profileID: "fixture", title: "Side"), session: SessionDisplay(id: "side"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane
        defer { window.contentView = nil; window.close() }
        pane.update(side: side, width: 600)
        tab.folders.setShown(true)
        try await until { tab.folders.browser.rows.contains { $0.url == tab.url } }
        model.tabs.showSide(); pane.update(side: side, width: 600)
        XCTAssertFalse(tab.isShownNow)
        pane.update(side: nil, width: 600)
        XCTAssertTrue(tab.isShownNow, "A missing side mounts and resumes the fallback file")
        try await until { tab.folders.browser.rows.contains { $0.url == tab.url } }
        // Leave real reads pending in this main-actor turn, then remove the
        // fallback without any TabHost selection to exercise mount lifetime.
        tab.folders.browser.expand(root)
        XCTAssertTrue(tab.folders.browser.isLoading(root))
        pane.update(side: side, width: 600)
        XCTAssertFalse(tab.isShownNow, "Returning to a side must hide the fallback file")
        XCTAssertFalse(tab.isWatching)
        XCTAssertFalse(tab.folders.browser.isLoading(root))
        let added = root.appendingPathComponent("Sources/new.txt")
        try Data("new sibling".utf8).write(to: added)
        pane.update(side: nil, width: 600)
        XCTAssertTrue(tab.isShownNow)
        try await until { tab.folders.browser.rows.contains { $0.url.path == added.path } }
        XCTAssertEqual(tab.folders.browser.selectedURL, tab.url)
    }

    @MainActor func testNarrowLayoutKeepsContentAndCrumbButtonsWithinPane() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let content = tab.contentView.content
        tab.folders.setShown(true); tab.folders.setWidth(300)
        for width in [240.0, 380, 700] {
            content.frame = NSRect(x: 0, y: 0, width: width, height: 480); content.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(tab.folders.panel.frame.maxX, width * 0.46)
            let header = try XCTUnwrap(descendants(FileTabHeader.self, in: content).first)
            let buttons = descendants(NSButton.self, in: header).filter { $0.accessibilityIdentifier().hasPrefix("file-crumb-") }
            XCTAssertFalse(buttons.isEmpty)
            for button in buttons { XCTAssertGreaterThan(button.frame.width, 0); XCTAssertLessThanOrEqual(header.convert(button.bounds, from: button).maxX, width) }
        }
        XCTAssertEqual(tab.folders.settings.width, 300, "Narrow layout must not overwrite the remembered preference")
    }

    @MainActor func testShowInFolderTreeRevealsTheChosenMenuFolder() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let folder = root.appendingPathComponent("Sources/nested")
        tab.folders.showInTree(folder)
        try await until { tab.folders.browser.snapshot(root) != nil }
        XCTAssertEqual(tab.folders.browser.selectedURL?.path, folder.path)
        XCTAssertTrue(tab.folders.browser.expanded.contains(FileBreadcrumb.normalized(folder)))
    }

    @MainActor func testSingleClickOnTreeSiblingOpensIt() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tab.contentView
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        tab.folders.setShown(true)
        try await until { tab.folders.browser.rows.contains { $0.url.lastPathComponent == "b.txt" } }
        window.contentView?.layoutSubtreeIfNeeded()
        let table = tab.folders.panel.tree.table
        let row = try XCTUnwrap(tab.folders.browser.rows.firstIndex { $0.url.lastPathComponent == "b.txt" })
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        XCTAssertGreaterThan(table.bounds.width, 0)
        XCTAssertTrue(table.visibleRect.contains(NSPoint(x: rect.midX, y: rect.midY)), "table \(table.frame), visible \(table.visibleRect), row \(rect)")
        XCTAssertEqual(table.row(at: table.convert(point, from: nil)), row)
        table.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(table.selectedRow, row, "table \(table.frame), visible \(table.visibleRect), row \(rect), point \(point)")
        XCTAssertEqual((model.tabs.pane.activeTab as? FileTab)?.url.lastPathComponent, "b.txt")
    }

    @MainActor func testFolderOpenFromPoppedOutTabStaysInThatContainer() async throws {
        let (model, root) = try await fixture()
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        let container = model.tabs.popOut(tab)
        tab.openNearbyFile?(root.appendingPathComponent("Sources/b.txt"))
        let sibling = try XCTUnwrap(container.activeTab as? FileTab)
        XCTAssertEqual(sibling.url.lastPathComponent, "b.txt")
        XCTAssertTrue(sibling.container === container)
        XCTAssertTrue(model.tabs.pane.tabs.isEmpty)
    }

    @MainActor func testSecondaryTrustedRootAnchorsItsFileTree() async throws {
        let root = try directory(), secondary = try directory()
        var config = VaultConfiguration()
        config.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true, paths: [secondary.path])]
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let tab = model.openFile(secondary.appendingPathComponent("Sources/a.txt"))
        tab.folders.setShown(true)
        XCTAssertEqual(tab.folders.projectRoot?.path, secondary.path)
        XCTAssertEqual(tab.folders.browser.root?.path, secondary.path)
        XCTAssertFalse(tab.folders.browser.canGoUp)
    }

    @MainActor func testShowInTreeCanRevealSiblingOfUnanchoredRoot() async throws {
        let (model, _) = try await fixture()
        let root = try directory()
        let folder = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tab = model.openFile(root.appendingPathComponent("Sources/a.txt"))
        XCTAssertNil(tab.projectID)
        tab.folders.showInTree(folder)
        XCTAssertEqual(tab.folders.browser.root?.path, root.path)
        XCTAssertEqual(tab.folders.browser.selectedURL?.path, folder.path)
        XCTAssertTrue(tab.folders.browser.expanded.contains(FileBreadcrumb.normalized(folder)))
    }

    @MainActor func testShowMorePreservesTreeScrollPosition() async throws {
        let root = try directory()
        let entries = (0..<60).map { FolderEntry(url: root.appendingPathComponent(String(format: "%03d.txt", $0)), isDirectory: false) }
        let browser = FolderBrowser(pageSize: 20, reader: { _, _ in FolderDirectory(entries: entries) })
        let tree = FolderTreeView(browser: browser)
        browser.changed = { [weak tree] in tree?.reload() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tree
        defer { browser.stop(); window.contentView = nil; window.close() }
        browser.show(file: entries[0].url, projectRoot: root)
        try await until { browser.snapshot(root) != nil }
        tree.layoutSubtreeIfNeeded()
        tree.table.scrollRowToVisible(20)
        let before = tree.table.visibleRect.minY
        XCTAssertGreaterThan(before, 0)
        browser.showMore(in: root)
        tree.layoutSubtreeIfNeeded()
        XCTAssertEqual(tree.table.visibleRect.minY, before, accuracy: 1)
    }

    @MainActor func testMenuRightArrowEntersOnlySubmenus() async throws {
        let root = try directory(), folder = root.appendingPathComponent("Sources")
        let crumb = try XCTUnwrap(FileBreadcrumb.path(to: folder.appendingPathComponent("a.txt"), project: ("Project", root)).dropLast().last)
        var opened = 0
        let menu = FileFolderMenu(crumb: crumb, projectRoot: root, open: { _ in opened += 1 }, showTree: { _ in opened += 1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = menu
        defer { menu.browser.stop(); window.contentView = nil; window.close() }
        try await until { menu.browser.snapshot(folder) != nil }
        let button = try XCTUnwrap(descendants(NSButton.self, in: menu).first { $0.accessibilityIdentifier() == folder.appendingPathComponent("a.txt").path })
        XCTAssertTrue(window.makeFirstResponder(button))
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
        button.keyDown(with: right)
        XCTAssertEqual(opened, 0)
    }

    @MainActor func testMenuKeepsKeyboardFocusWhenLazySubmenuFinishes() async throws {
        let root = try directory(), nested = FileBreadcrumb.normalized(root.appendingPathComponent("Sources/nested"))
        let gate = FolderMenuReadGate()
        let browser = FolderBrowser(reader: { url, _ in
            if url == nested { await gate.wait() }
            return FolderDirectory(entries: [])
        })
        let crumb = try XCTUnwrap(FileBreadcrumb.path(to: root.appendingPathComponent("a.txt"), project: ("Project", root)).first)
        let menu = FileFolderMenu(crumb: crumb, projectRoot: root, open: { _ in }, showTree: { _ in }, browser: browser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = menu
        defer { browser.stop(); window.contentView = nil; window.close() }
        menu.enter(nested)
        let back = try XCTUnwrap(descendants(NSButton.self, in: menu).first { $0.accessibilityIdentifier() == "folder-menu-back" })
        XCTAssertTrue(window.makeFirstResponder(back))
        await gate.release()
        try await until { browser.snapshot(nested) != nil }
        let freshBack = try XCTUnwrap(descendants(NSButton.self, in: menu).first { $0.accessibilityIdentifier() == "folder-menu-back" })
        XCTAssertTrue(window.firstResponder === freshBack)
    }

    @MainActor func testReturnKeepsMenuFocusOnShowMoreWhileMorePagesRemain() async throws {
        let root = try directory()
        let entries = (0..<7).map { FolderEntry(url: root.appendingPathComponent("file-\($0)"), isDirectory: false) }
        let browser = FolderBrowser(pageSize: 2, reader: { _, _ in FolderDirectory(entries: entries) })
        let crumb = try XCTUnwrap(FileBreadcrumb.path(to: root.appendingPathComponent("a.txt"), project: ("Project", root)).first)
        var otherAction = 0
        let menu = FileFolderMenu(crumb: crumb, projectRoot: root, open: { _ in otherAction += 1 }, showTree: { _ in otherAction += 1 }, browser: browser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = menu
        defer { browser.stop(); window.contentView = nil; window.close() }
        try await until { browser.snapshot(root) != nil }
        let more = try XCTUnwrap(descendants(NSButton.self, in: menu).first { $0.accessibilityIdentifier() == "folder-menu-more" })
        XCTAssertTrue(window.makeFirstResponder(more))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        more.keyDown(with: enter)
        XCTAssertEqual((window.firstResponder as? NSButton)?.accessibilityIdentifier(), "folder-menu-more")
        window.firstResponder?.keyDown(with: enter)
        XCTAssertEqual(browser.visibleEntries(in: root).count, 6)
        XCTAssertEqual(otherAction, 0)
    }

    @MainActor func testInformationalTreeRowsHaveNoAccessibilityPressAction() async throws {
        let root = try directory()
        let browser = FolderBrowser(reader: { _, _ in FolderDirectory(entries: []) })
        let tree = FolderTreeView(browser: browser)
        browser.changed = { [weak tree] in tree?.reload() }
        browser.show(file: root.appendingPathComponent("file.txt"), projectRoot: root)
        defer { browser.stop() }
        try await until { browser.snapshot(root) != nil }
        let cell = try XCTUnwrap(tree.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityRole(), .staticText)
        XCTAssertEqual(cell.accessibilityLabel(), "Empty folder")
        XCTAssertFalse(cell.accessibilityPerformPress())
        XCTAssertFalse(cell.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")))
    }

    @MainActor private func fixture(trusted: Bool = true) async throws -> (WorkspaceModel, URL) {
        let root = try directory()
        var config = VaultConfiguration(); config.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: trusted)]
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false; try await model.reloadConfiguration()
        return (model, root)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-folder-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/nested"), withIntermediateDirectories: true)
        for file in ["Sources/a.txt", "Sources/b.txt", "Sources/nested/c.txt"] { try Data("fixture".utf8).write(to: root.appendingPathComponent(file)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Folder UI did not finish"); throw CancellationError()
    }
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
}

private actor FolderMenuReadGate {
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { waiting = $0 } } }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
