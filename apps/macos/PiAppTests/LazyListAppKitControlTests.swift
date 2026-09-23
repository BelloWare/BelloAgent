import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// 0.1.89 froze for good while a chat compacted. The main thread never left
/// one SwiftUI update: `GraphHost.flushTransactions` ran transaction after
/// transaction, each one updating the sidebar's lazy list — its items' phases
/// (`LazyLayoutViewCache.updateItemPhases`) — and the AppKit pop-up buttons
/// SwiftUI `Menu`s are made of (`AppKitPopUpAdaptor.updateNSView`: font,
/// items, images, accessibility text).
///
/// An AppKit control that SwiftUI hosts invalidates its own size whenever
/// SwiftUI updates it; its host turns that into another transaction, and in a
/// lazy list that transaction lays the list out and updates its items again,
/// the controls with them. On macOS 26 that never settles. So the lazy list
/// may hold no AppKit control that sizes itself — no pop-up button, no
/// progress indicator — and no live `Menu` is kept anywhere in the window:
/// menus are built when they open (`PiMenu.swift`).
final class LazyListAppKitControlTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    /// The AppKit views under `view` that change their own size when SwiftUI
    /// updates them. A menu or popover press target never does: its size is
    /// the face's, and it keeps its title, font and image.
    @MainActor static func selfSizingControls(in view: NSView) -> [String] {
        func walk(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + walk($0) } }
        return walk(view).filter { view in
            if view is PiPopoverTriggerButton { return false }
            return view is NSControl || view is NSProgressIndicator
        }.map { String(describing: type(of: $0)) }
    }

    /// Three projects, topics, a chat compacting in the background and the
    /// selected chat with its composer: every place a menu or a spinner was.
    @MainActor static func crowdedWindow(_ root: URL) throws -> (model: WorkspaceModel, window: NSWindow, hosted: NSView) {
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["Selected chat"])
        let model = bench.model
        var projects = [bench.workspace]
        for name in ["design", "billing"] {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            projects.append(WorkspaceRecord(id: "project-" + name, path: path.path, trusted: true))
        }
        model.workspaces = projects
        model.topics = [TopicRecord(id: "topic-a", workspaceID: bench.workspace.id, title: "Payments"),
                        TopicRecord(id: "topic-b", workspaceID: projects[1].id, title: "Research")]
        var chats = bench.chats
        for (index, project) in projects.enumerated() {
            for number in 0..<3 {
                var chat = ChatRecord(id: "chat-\(index)-\(number)", workspaceID: project.id, title: "Chat \(number) in \(project.id)",
                                      path: nil, profileID: bench.profile.id)
                if number == 1 { chat.topicID = index == 0 ? "topic-a" : index == 1 ? "topic-b" : nil }
                chats.append(chat)
            }
        }
        model.chats = chats
        let selected = bench.chats[0]
        let session = SessionDisplay(id: selected.id)
        model.displays[selected.id] = session; model.selectedID = selected.id; model.selected = session; model.focusedSessionID = selected.id
        // A chat compacting in the background: its row shows that it is working.
        let compacting = SessionDisplay(id: "chat-0-0")
        compacting.state = "compacting"; compacting.runStatus = "compacting"
        model.displays["chat-0-0"] = compacting
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        return (model, window, hosted)
    }

    @MainActor static func settle(_ hosted: NSView, _ window: NSWindow) async {
        for _ in 0..<10 {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield(); try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The sidebar's lazy list holds no AppKit control that sizes itself: the
    /// project and topic menus, and a working chat's spinner, are SwiftUI.
    @MainActor func testTheSidebarListHostsNoControlThatResizesItselfOnUpdate() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("lazy-list-controls-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, window, hosted) = try Self.crowdedWindow(root)
        defer { model.shutdown(); window.contentView = nil; window.close() }
        await Self.settle(hosted, window)
        // The sidebar's list is the scroll view in the sidebar column: it
        // starts at the window's leading edge, and no wider than the column.
        let lists = descendants(hosted).compactMap { $0 as? NSScrollView }.filter {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.minX < 20 && frame.width <= WindowChrome.maximumSidebarWidth + 1
        }
        let list = try XCTUnwrap(lists.max { $0.bounds.height < $1.bounds.height }, "The sidebar's list is on screen")
        // The list's own content, not the scroll view's scrollers.
        let content = try XCTUnwrap(list.documentView, "The sidebar's list has content")
        XCTAssertGreaterThan(descendants(content).count, 0, "The sidebar's list has content")
        let controls = Self.selfSizingControls(in: content)
        XCTAssertEqual(controls, [], "The sidebar's lazy list hosts AppKit controls that resize themselves on every update: \(controls)")
        // The compacting chat still says it is working: its ring turns on
        // its own layer, at no cost to the main thread.
        let spinners = descendants(content).compactMap { $0 as? PiSpinnerView }
        XCTAssertEqual(spinners.count, 1, "The compacting chat's row shows one spinner")
        XCTAssertTrue(spinners.allSatisfy(\.isAnimating), "The spinner turns")
    }

    /// No live `Menu` anywhere in the window: the sidebar's headers, the
    /// composer bar's chat actions and a side pane's header build their menus
    /// when they open.
    @MainActor func testTheWindowKeepsNoLiveMenu() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("lazy-list-menus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, window, hosted) = try Self.crowdedWindow(root)
        defer { model.shutdown(); window.contentView = nil; window.close() }
        await Self.settle(hosted, window)
        let popUps = descendants(hosted).filter { $0 is NSPopUpButton }.map { String(describing: type(of: $0)) }
        XCTAssertEqual(popUps, [], "Live pop-up menus in the window, each rebuilt on every update of the view that holds it: \(popUps)")
        let triggers = descendants(hosted).compactMap { $0 as? PiPopoverTriggerButton }.compactMap { $0.accessibilityIdentifier() }
        for identifier in ["projectActions-pane-project", "projectActions-project-design", "topicActions-topic-a", "conversationActions"] {
            XCTAssertTrue(triggers.contains(identifier), "\(identifier) is a menu control in the window: \(triggers)")
        }
    }

    /// The menu bar panel refreshes every second while it is shown, and the
    /// Changes panel lists every branch and stash: their menus are built when
    /// they open, like the window's.
    @MainActor func testTheMenuBarPanelAndTheChangesPanelKeepNoLiveMenu() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("lazy-list-panels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent(".state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let monitor = MenuBarMetricsController(load: { _, _, _ in throw CaptureFailure.unavailable }, period: .fifteenMinutes)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 576), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let popup = NSHostingView(rootView: MenuBarMetricsView(load: { _, _, _ in throw CaptureFailure.unavailable }, live: model.liveActivity,
                                                               monitorController: monitor, openApp: {}, openReport: {})
            .environment(\.menuBarHeight, 576))
        panel.contentView = popup; panel.orderFront(nil)
        defer { monitor.setVisible(false); panel.contentView = nil; panel.close() }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "First"]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = repository; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }
        let changes = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        changes.isReleasedWhenClosed = false
        let panelView = NSHostingView(rootView: GitPanelView(model: model, roots: [repository.path]))
        changes.contentView = panelView; changes.orderFront(nil)
        defer { changes.contentView = nil; changes.close() }
        for _ in 0..<40 {
            popup.layoutSubtreeIfNeeded(); panelView.layoutSubtreeIfNeeded(); panel.displayIfNeeded(); changes.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        for (name, view) in [("menu bar panel", popup as NSView), ("Changes panel", panelView as NSView)] {
            let popUps = descendants(view).filter { $0 is NSPopUpButton }.map { String(describing: type(of: $0)) }
            XCTAssertEqual(popUps, [], "Live pop-up menus in the \(name): \(popUps)")
        }
        let triggers = (descendants(popup) + descendants(panelView)).compactMap { $0 as? PiPopoverTriggerButton }.compactMap { $0.accessibilityIdentifier() }
        for identifier in ["monitorOptions", "git-branch-menu", "git-stash-menu"] {
            XCTAssertTrue(triggers.contains(identifier), "\(identifier) is a menu control: \(triggers)")
        }
    }
}
