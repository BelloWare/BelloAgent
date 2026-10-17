import AppKit
import XCTest
@testable import PiApp

@MainActor final class WorkspaceSplitTests: XCTestCase, SerialTestLane {
    func testFilePaneYieldsToTheChatMinimumAtNarrowWindowSizes() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        for size in WorkspaceSplitFixture.sizes {
            fixture.window.setContentSize(size)
            for sidebar: CGFloat in [300, WindowChrome.maximumSidebarWidth] {
                fixture.view.sidebarHandle.ended?(sidebar - fixture.view.sidebar.frame.width)
                for open in [false, true] {
                    fixture.showFile(open)
                    for busy in [false, true] {
                        fixture.session.state = busy ? "running" : "idle"
                        await fixture.settle()
                        try fixture.assertFits("\(Int(size.width))×\(Int(size.height)), sidebar \(sidebar), file \(open), busy \(busy)")
                        XCTAssertEqual(fixture.window.contentMinSize, WorkspaceRootView.minimumWindowSize)
                        XCTAssertEqual(fixture.view.bounds.size, size, "The window keeps its requested size")
                        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidePaneFraction"), SplitPane.defaultFraction)
                    }
                }
            }
        }
    }

    func testDraggingAndChangingComposerControlsPreserveThePreferredSplit() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        fixture.window.setContentSize(WorkspaceRootView.minimumWindowSize)
        fixture.showFile(true)
        await fixture.settle()
        let pane = try XCTUnwrap(fixture.view.conversation)
        let chats = try XCTUnwrap(pane.superview as? WorkspaceChatsLayer)
        fixture.view.splitHandle.changed?(-chats.bounds.width)
        await fixture.settle()
        try fixture.assertFits("dragged to the narrowest split")
        fixture.view.splitHandle.ended?(-chats.bounds.width)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidePaneFraction"), SplitPane.minimumFraction)
        let idleMinimum = pane.minimumWidth
        fixture.session.state = "running"
        await fixture.settle()
        XCTAssertGreaterThan(pane.minimumWidth, idleMinimum, "Steer and Stop increase the minimum without resizing the window")
        try fixture.assertFits("busy after the split settled")
        fixture.session.state = "idle"
        await fixture.settle()
        XCTAssertEqual(pane.bounds.width, ceil(pane.minimumWidth), accuracy: 0.5, "The file pane gets spare room back")
        fixture.window.setContentSize(NSSize(width: 2200, height: 800))
        await fixture.settle()
        try fixture.assertFits("widened again")
        XCTAssertEqual(pane.bounds.width, SplitPane.mainWidth(total: chats.bounds.width, fraction: SplitPane.minimumFraction),
                       "The preferred split returns once the controls fit")
        fixture.showFile(false)
        await fixture.settle()
        try fixture.assertFits("file closed after widening")
        XCTAssertEqual(pane.bounds.width, chats.bounds.width)
    }

    func testDraggingRightStartsAtTheVisibleMinimumBoundary() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        fixture.window.setContentSize(WorkspaceRootView.minimumWindowSize)
        fixture.showFile(true)
        await fixture.settle()
        let pane = try XCTUnwrap(fixture.view.conversation)
        let before = pane.bounds.width
        fixture.view.splitHandle.changed?(12)
        await fixture.settle()
        XCTAssertEqual(pane.bounds.width, before + 12, accuracy: 1, "A drag starts at the visible divider, even when the minimum overrode the saved fraction")
        XCTAssertEqual(UserDefaults.standard.double(forKey: "sidePaneFraction"), SplitPane.defaultFraction, "The preference changes only when the drag ends")
        fixture.view.splitHandle.ended?(12)
        await fixture.settle()
        XCTAssertEqual(pane.bounds.width, before + 12, accuracy: 1, "Ending a drag keeps its visible position")
        try fixture.assertFits("dragged right from the control minimum")
    }
}

@MainActor final class WorkspaceSplitGalleryTests: XCTestCase, SerialTestLane {
    func testNarrowWorkspaceSplitGallery() async throws {
        guard let path = testEnvironment("PI_WORKSPACE_SPLIT_GALLERY") else { throw XCTSkip("Set PI_WORKSPACE_SPLIT_GALLERY to capture") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try WorkspaceSplitFixture(test: self)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in WorkspaceSplitFixture.sizes {
                fixture.window.setContentSize(size)
                for open in [false, true] {
                    fixture.showFile(open)
                    for busy in [false, true] {
                        fixture.session.state = busy ? "running" : "idle"
                        await fixture.settle()
                        if let tab = fixture.tab {
                            try await eventually("file visible in split gallery") { tab.focusView?.window === fixture.window }
                        }
                        let scene = "split-\(name)-\(Int(size.width))x\(Int(size.height))-\(open ? "file" : "chat")-\(busy ? "busy" : "idle")"
                        try fixture.assertFits(scene)
                        fixture.window.displayIfNeeded()
                        let bitmap = try XCTUnwrap(fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds))
                        fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(scene + ".png"))
                    }
                }
            }
        }
    }
}

@MainActor private final class WorkspaceSplitFixture {
    static let sizes = [NSSize(width: 920, height: 800), WorkspaceRootView.minimumWindowSize]
    let model: WorkspaceModel
    let session: SessionDisplay
    let view: WorkspaceRootView
    let window: NSWindow
    let file: URL
    var tab: FileTab?

    init(test: XCTestCase) throws {
        for (key, value) in [("sidebarWidth", 300.0), ("sidePaneFraction", SplitPane.defaultFraction)] {
            let saved = UserDefaults.standard.object(forKey: key)
            test.addTeardownBlock { @MainActor in
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.set(value, forKey: key)
        }
        let root = scratchRoot("workspace-split")
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["Split layout"])
        model = bench.model
        test.registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        var alternate = bench.profile
        alternate.id = "alternate"; alternate.name = "Alternate connection"
        model.profiles.append(alternate)
        session = SessionDisplay(id: bench.chats[0].id)
        session.messages = [TranscriptMessage(id: "question", role: "user", text: "Check the composer while the file pane is open."),
                            TranscriptMessage(id: "reply", role: "assistant", text: "The chat keeps enough room for its controls. The file pane uses the remaining space.")]
        session.draft = "Keep this draft visible while resizing."
        model.displays[session.id] = session; model.selectedID = session.id; model.selected = session
        model.focusedSessionID = session.id
        file = root.appendingPathComponent("layout.txt")
        try Data("Generated split-layout fixture\n\nThe file pane yields space to the chat controls.\n".utf8).write(to: file)
        view = WorkspaceRootView(model: model)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.sizes[0]), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.makeKeyAndOrderFront(nil)
        test.addTeardownBlock { @MainActor [window, model] in
            for tab in model.tabs.pane.tabs { model.tabs.close(tab) }
            window.contentView = nil; window.close()
        }
    }

    func showFile(_ open: Bool) {
        if open, tab == nil { tab = model.openFile(file) }
        if !open, let tab { model.tabs.close(tab); self.tab = nil }
    }

    func settle() async {
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        view.layoutSubtreeIfNeeded()
    }

    func assertFits(_ scene: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let pane = try XCTUnwrap(view.conversation, file: file, line: line)
        let composer = pane.composer
        XCTAssertFalse(composer.isHiddenOrHasHiddenAncestor, scene, file: file, line: line)
        XCTAssertGreaterThanOrEqual(pane.bounds.width, pane.minimumWidth, scene, file: file, line: line)
        let controls = PiKit.controls(in: composer).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
        XCTAssertGreaterThan(controls.count, 6, "The fixture must expose the real composer controls", file: file, line: line)
        for control in controls {
            let frame = composer.convert(control.bounds, from: control)
            XCTAssertTrue(composer.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(scene): \(control.accessibilityLabel() ?? String(describing: type(of: control))) at \(frame) outside \(composer.bounds)", file: file, line: line)
            XCTAssertTrue(pane.bounds.insetBy(dx: -0.5, dy: -0.5).contains(pane.convert(control.bounds, from: control)), scene, file: file, line: line)
        }
        let chats = try XCTUnwrap(pane.superview as? WorkspaceChatsLayer, file: file, line: line)
        if let side = view.rightPane {
            XCTAssertEqual(side.frame.minX, pane.frame.maxX + SplitPane.dividerWidth, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(side.frame.maxX, chats.bounds.maxX, accuracy: 0.01, file: file, line: line)
            XCTAssertGreaterThan(side.bounds.width, 0, "The file remains open", file: file, line: line)
        } else { XCTAssertEqual(pane.frame.width, chats.bounds.width, file: file, line: line) }
        print("SPLIT \(scene): chat=\(pane.bounds.width), minimum=\(pane.minimumWidth), file=\(view.rightPane?.bounds.width ?? 0)")
    }
}
