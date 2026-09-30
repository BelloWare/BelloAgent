import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Tabs beside the chats and in windows of their own (`TabHost`): one tab a
/// kind and key wherever it is, opened after the tab shown, closed to its
/// right-hand neighbour, else its left, else the side; moved and popped out
/// without closing; and brought back after a relaunch, windows where they
/// were, kinds unknown left out.
final class TabHostTests: XCTestCase {
    /// A kind of tab for the tests: counts what the host tells it.
    @MainActor final class Probe: HostedTab {
        override class var kind: String { "probe" }
        var shows = 0, hides = 0, closes = 0, keys = 0
        /// What takes the keys in its content, if the test gives it one.
        var focusable: NSView?
        override var focusView: NSView? { focusable }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keys += 1; return true }
        init(_ key: String) { super.init(key: key, title: key, symbol: "doc") }
        override func didShow() { shows += 1 }
        override func didHide() { hides += 1 }
        override func willClose() { closes += 1 }
    }
    @MainActor private func host(_ defaults: UserDefaults? = nil) -> TabHost {
        let host = TabHost(defaults: defaults)
        host.showsWindows = false
        addTeardownBlock { @MainActor in for window in host.windows { host.window(of: window)?.close() } }
        return host
    }
    @MainActor private func open(_ host: TabHost, _ key: String, in container: TabContainer? = nil) -> Probe {
        host.open(kind: Probe.kind, key: key, in: container) { Probe(key) } as! Probe
    }
    @MainActor private func titles(_ container: TabContainer) -> [String] { container.tabs.map(\.title) }

    @MainActor func testOneTabAKeyOpenedAfterTheTabShown() {
        let host = host()
        let a = open(host, "a"), _ = open(host, "b")
        host.activate(a)
        _ = open(host, "c")
        XCTAssertEqual(titles(host.pane), ["a", "c", "b"], "after the tab shown")
        let window = host.popOut(a)
        XCTAssertEqual(titles(window), ["a"])
        let again = open(host, "a")
        XCTAssertTrue(again === a, "the tab already open, in its window")
        XCTAssertEqual(host.allTabs.count, 3)
    }

    @MainActor func testClosingShowsTheRightNeighbourThenTheLeftThenTheSide() {
        let host = host()
        let a = open(host, "a"), b = open(host, "b"), c = open(host, "c")
        XCTAssertEqual([a.shows, b.shows, c.shows], [1, 1, 1], "each shown as it opened")
        host.activate(b)
        let hides = b.hides
        host.close(b)
        XCTAssertEqual(b.hides, hides + 1, "the tab shown was hidden as it closed")
        XCTAssertTrue(host.pane.shownTab(sideAvailable: true) === c, "the right-hand neighbour")
        host.close(c)
        XCTAssertTrue(host.pane.shownTab(sideAvailable: true) === a, "else the left")
        host.close(a)
        XCTAssertNil(host.pane.shownTab(sideAvailable: true), "else the side")
        XCTAssertEqual([a.closes, b.closes, c.closes], [1, 1, 1])
    }

    @MainActor func testTheSideIsShownInPlaceOfTheTabsOnlyWhereThereIsOne() {
        let host = host()
        let a = open(host, "a")
        host.showSide()
        XCTAssertNil(host.pane.shownTab(sideAvailable: true), "the side, in a chat that has one")
        XCTAssertTrue(host.pane.shownTab(sideAvailable: false) === a, "the tab, in a chat without")
        XCTAssertFalse(host.closeShownTab(in: host.pane, sideAvailable: true), "⌘W does not close the side")
        XCTAssertTrue(host.closeShownTab(in: host.pane, sideAvailable: false))
        XCTAssertTrue(host.pane.tabs.isEmpty)
    }

    @MainActor func testMovingKeepsATabOpenAndAWindowClosesWithItsLastTab() {
        let host = host()
        let a = open(host, "a"), b = open(host, "b")
        let window = host.popOut(a)
        XCTAssertEqual(titles(host.pane), ["b"]); XCTAssertEqual(host.windows.count, 1)
        _ = open(host, "c", in: window)
        XCTAssertEqual(titles(window), ["a", "c"])
        host.move(a, to: window, at: 2)
        XCTAssertEqual(titles(window), ["c", "a"], "moved along its own strip")
        host.move(a, to: host.pane, at: 0)
        XCTAssertEqual(titles(host.pane), ["a", "b"])
        XCTAssertTrue(host.pane.shownTab(sideAvailable: true) === a, "shown where it went")
        XCTAssertEqual(a.closes, 0, "moving never closes")
        let c = window.tabs[0]
        host.moveToPane(c)
        XCTAssertTrue(host.windows.isEmpty, "the window closed with its last tab gone")
        XCTAssertEqual(host.allTabs.count, 3)
        // The only tab of a window, popped out again, moves the window instead.
        let alone = host.popOut(b)
        XCTAssertTrue(host.popOut(b) === alone)
        XCTAssertEqual(host.windows.count, 1)
    }

    /// Where a tab's content is shown is its pane's or window's to say: a
    /// view for another, kept by SwiftUI a moment longer, never takes it.
    @MainActor func testOnlyTheTabsOwnPaneOrWindowTakesItsContent() {
        let host = host()
        let tab = open(host, "a")
        let window = host.popOut(tab)
        let inWindow = TabContentContainer(), inPane = TabContentContainer()
        inWindow.show(tab, for: window)
        XCTAssertTrue(tab.contentView.superview === inWindow)
        inPane.show(tab, for: host.pane)
        XCTAssertTrue(tab.contentView.superview === inWindow, "the pane's view does not take a window's tab")
        host.moveToPane(tab)
        inPane.show(tab, for: host.pane)
        XCTAssertTrue(tab.contentView.superview === inPane)
        inWindow.show(tab, for: window)
        XCTAssertTrue(tab.contentView.superview === inPane, "nor the window's view a tab gone to the pane")
    }

    /// A tab with focus in its content is told so as it moves, before its
    /// content leaves its window.
    @MainActor func testATabMovingWithFocusIsToldSo() throws {
        let host = host()
        let tab = open(host, "a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let container = TabContentContainer(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container
        container.show(tab, for: host.pane)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        tab.contentView.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        host.popOut(tab)
        XCTAssertTrue(tab.takeFocusAfterMove(), "focus was in it")
        XCTAssertFalse(tab.takeFocusAfterMove(), "asked once")
    }

    /// Focus carried with a moving tab does not go into content covered
    /// where it lands.
    @MainActor func testFocusCarriedWithATabDoesNotGoIntoCoveredContent() async throws {
        let host = host()
        let tab = open(host, "a")
        func window() -> (NSWindow, TabContentContainer) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = TabContentContainer(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            window.contentView = container
            addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
            return (window, container)
        }
        let (first, inFirst) = window(), (second, inSecond) = window(), (third, inThird) = window()
        // Takes the keys as a file's text does (a text field gives focus up
        // by itself when hidden, so would not tell).
        final class Keys: NSView { override var acceptsFirstResponder: Bool { true } }
        let keys = Keys(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        tab.contentView.addSubview(keys); tab.focusable = keys
        func focused(_ window: NSWindow) -> Bool { window.firstResponder === keys }
        inFirst.show(tab, for: host.pane)
        XCTAssertTrue(first.makeFirstResponder(keys))
        // Moved with focus to a window (a bare one: no window of the host's
        // takes the content first) whose content something covers.
        let elsewhere = TabContainer(isPane: false)
        host.move(tab, to: elsewhere)
        inSecond.isHidden = true
        inSecond.show(tab, for: elsewhere)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(tab.contentView.window === second)
        XCTAssertFalse(focused(second), "not into covered content")
        // Uncovered, a tab moved with focus takes it where it goes.
        inSecond.isHidden = false
        XCTAssertTrue(second.makeFirstResponder(keys))
        host.moveToPane(tab)
        inThird.show(tab, for: host.pane)
        try await eventually("focused where it went") { focused(third) }
    }

    /// A tab has the ⌘ keys pressed while focus is in its content, shown and
    /// not under a sheet; no other keys, and not from elsewhere.
    @MainActor func testATabHasItsKeysOnlyWhereItsShownContentHasFocus() async throws {
        final class Keys: NSView { override var acceptsFirstResponder: Bool { true } }
        let host = host()
        let tab = open(host, "a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let container = TabContentContainer(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        let elsewhere = Keys(frame: NSRect(x: 0, y: 160, width: 100, height: 20))
        root.addSubview(container); root.addSubview(elsewhere)
        window.contentView = root
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        container.show(tab, for: host.pane)
        let keys = Keys(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        tab.contentView.addSubview(keys)
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 3))
        }
        let commandF = try key("f", .command, in: window)
        XCTAssertTrue(window.makeFirstResponder(elsewhere))
        XCTAssertFalse(TabHost.tabKey(commandF, in: window), "focus elsewhere")
        XCTAssertTrue(window.makeFirstResponder(keys))
        XCTAssertTrue(TabHost.tabKey(commandF, in: window), "focus in its content")
        XCTAssertEqual(tab.keys, 1)
        XCTAssertFalse(TabHost.tabKey(try key("f", [], in: window), in: window), "not a ⌘ key")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in other.close() }
        XCTAssertFalse(TabHost.tabKey(try key("f", .command, in: other), in: window), "another window's key")
        container.isHidden = true
        XCTAssertTrue(window.makeFirstResponder(keys))
        XCTAssertFalse(TabHost.tabKey(commandF, in: window), "covered")
        container.isHidden = false
        XCTAssertTrue(window.makeFirstResponder(keys))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        try await eventually("the sheet up") { window.attachedSheet === sheet }
        XCTAssertFalse(TabHost.tabKey(commandF, in: window), "under a sheet")
        window.endSheet(sheet)
        try await eventually("the sheet down") { window.attachedSheet == nil }
        XCTAssertEqual(tab.keys, 1)
    }

    @MainActor func testAWindowClosedByItsButtonClosesItsTabs() {
        let host = host()
        let a = open(host, "a")
        let window = host.popOut(a)
        host.window(of: window)?.performClose(nil)
        XCTAssertTrue(host.windows.isEmpty)
        XCTAssertEqual(a.closes, 1)
    }

    @MainActor func testCommandWInATabWindowClosesItsTabThenTheWindow() throws {
        let host = host()
        let a = open(host, "a")
        let container = host.popOut(a)
        _ = open(host, "b", in: container)
        let window = try XCTUnwrap(host.window(of: container) as? TabWindow)
        let commandW = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertTrue(window.performKeyEquivalent(with: commandW))
        XCTAssertEqual(titles(container), ["a"], "the tab shown closed")
        XCTAssertTrue(window.performKeyEquivalent(with: commandW))
        XCTAssertTrue(host.windows.isEmpty, "and with the last, the window")
    }

    @MainActor func testTabsComeBackWithTheirWindowsWhereTheyWere() throws {
        let suite = "tab-host-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let folder = scratchRoot("tab-host")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let files = (0..<4).map { folder.appendingPathComponent("file\($0).txt") }
        for file in files { try Data("text".utf8).write(to: file) }
        let first = host(defaults)
        first.restore()   // nothing saved yet: as the app, once the projects are known
        for file in files { first.open(kind: FileTab.kind, key: FileTab.key(for: file)) { FileTab(url: file, projectID: nil) } }
        let second = try XCTUnwrap(first.tab(kind: FileTab.kind, key: FileTab.key(for: files[1])))
        let window = first.popOut(try XCTUnwrap(first.tab(kind: FileTab.kind, key: FileTab.key(for: files[3]))))
        first.window(of: window)?.setFrame(NSRect(x: 120, y: 140, width: 700, height: 500), display: false)
        first.activate(second)
        first.showSide()
        first.flush()
        // A kind this app does not know is left out.
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: TabHost.savedKey))) as? [String: Any])
        var pane = try XCTUnwrap(saved["pane"] as? [String: Any])
        var tabs = try XCTUnwrap(pane["tabs"] as? [[String: Any]])
        tabs.append(["kind": "unknown", "key": "x"]); pane["tabs"] = tabs; saved["pane"] = pane
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: TabHost.savedKey)

        let again = host(defaults)
        again.restore()
        XCTAssertEqual(again.pane.tabs.map(\.key), files[0...2].map { FileTab.key(for: $0) }, "the pane's, in order, the unknown left out")
        XCTAssertEqual(again.pane.activeTab?.key, FileTab.key(for: files[1]))
        XCTAssertTrue(again.pane.sideShown)
        XCTAssertEqual(again.windows.count, 1)
        XCTAssertEqual(again.windows.first?.tabs.map(\.key), [FileTab.key(for: files[3])])
        let frame = try XCTUnwrap(again.windows.first.flatMap { again.window(of: $0) }?.frame)
        XCTAssertEqual(frame, TabWindowController.onScreen(NSRect(x: 120, y: 140, width: 700, height: 500)), "where it was")
        let hidden = again.allTabs.filter { tab in tab.container?.activeTab !== tab }
        XCTAssertEqual(hidden.count, 2)
        XCTAssertFalse(hidden.contains { $0.hasContent }, "nothing made of a tab not shown")
        XCTAssertFalse(hidden.contains { ($0 as? FileTab)?.hasDocument == true }, "nor its file opened")
        again.restore()
        XCTAssertEqual(again.allTabs.count, 4, "brought back once")
    }

    /// A quit before the saved tabs were brought back keeps what was saved;
    /// the workspace going empties every pane and window.
    @MainActor func testGoingBeforeTheTabsCameBackKeepsThemAndEmptiesEverything() throws {
        let suite = "tab-host-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let saved = Data(#"{"pane":{"tabs":[{"kind":"file","key":"/tmp/kept.txt"}],"sideShown":false},"windows":[]}"#.utf8)
        defaults.set(saved, forKey: TabHost.savedKey)
        let early = host(defaults)
        early.tearDown()
        XCTAssertEqual(defaults.data(forKey: TabHost.savedKey), saved, "not overwritten by a host never restored")
        let host = host()
        let a = open(host, "a"), b = open(host, "b")
        let window = host.popOut(b)
        host.tearDown()
        XCTAssertTrue(window.tabs.isEmpty && host.pane.tabs.isEmpty, "every pane and window emptied")
        XCTAssertNil(a.container); XCTAssertNil(b.container)
        XCTAssertEqual([a.closes, b.closes], [1, 1])
    }

    @MainActor func testAFrameOffEveryScreenComesBackOnOne() throws {
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let far = TabWindowController.onScreen(NSRect(x: screen.maxX + 5_000, y: screen.maxY + 5_000, width: 700, height: 500))
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(far) })
        let huge = TabWindowController.onScreen(NSRect(x: screen.minX, y: screen.minY, width: screen.width * 3, height: screen.height * 3))
        XCTAssertLessThanOrEqual(huge.width, screen.width); XCTAssertLessThanOrEqual(huge.height, screen.height)
    }
}
