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

    func testSideConversationKeepsTheReleasedSplitWhenBothMinimaCannotFit() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        for size in WorkspaceSplitFixture.sizes {
            fixture.window.setContentSize(size)
            for sidebar: CGFloat in [300, WindowChrome.maximumSidebarWidth] {
                fixture.view.sidebarHandle.ended?(sidebar - fixture.view.sidebar.frame.width)
                for mainBusy in [false, true] {
                    fixture.session.state = mainBusy ? "running" : "idle"
                    for sideBusy in [false, true] {
                        side.state = sideBusy ? "running" : "idle"
                        await fixture.settle()
                        try reference.assertSplit(fixture, fits: false,
                            scene: "\(Int(size.width))×\(Int(size.height)), sidebar \(sidebar), main busy \(mainBusy), side busy \(sideBusy)")
                    }
                }
            }
        }
    }

    func testSideConversationPreservesProportionalFramesWhenBothMinimaAlreadyFit() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        for width: CGFloat in [4000, 4600] {
            fixture.window.setContentSize(NSSize(width: width, height: 800))
            for fraction in [0.3, 0.5, 0.7] {
                UserDefaults.standard.set(fraction, forKey: "sidePaneFraction")
                fixture.view.refresh()
                for mainBusy in [false, true] {
                    fixture.session.state = mainBusy ? "running" : "idle"
                    for sideBusy in [false, true] {
                        side.state = sideBusy ? "running" : "idle"
                        await fixture.settle()
                        try reference.assertSplit(fixture, fits: true, proportional: true,
                            scene: "unchanged at \(width), fraction \(fraction), main busy \(mainBusy), side busy \(sideBusy)")
                    }
                }
            }
        }
    }

    func testSideConversationClampsTheProportionalSplitToBothMinima() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        for (width, fraction) in [(CGFloat(1240), 0.5), (1800, 0.3), (1800, 0.5), (1800, 0.7)] {
            fixture.window.setContentSize(NSSize(width: width, height: 800))
            UserDefaults.standard.set(fraction, forKey: "sidePaneFraction")
            fixture.view.refresh()
            for mainBusy in [false, true] {
                fixture.session.state = mainBusy ? "running" : "idle"
                for sideBusy in [false, true] {
                    side.state = sideBusy ? "running" : "idle"
                    await fixture.settle()
                    try reference.assertSplit(fixture, fits: true, scene: "fraction \(fraction), main busy \(mainBusy), side busy \(sideBusy)")
                    XCTAssertEqual(fixture.view.sideFraction, fraction)
                }
            }
        }
    }

    func testSideSplitDragKeepsTheWholeRegionFraction() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        for width: CGFloat in [1800, 2400] {
            UserDefaults.standard.set(0.5, forKey: "sidePaneFraction")
            fixture.view.refresh()
            side.state = "idle"
            fixture.window.setContentSize(NSSize(width: width, height: 800))
            await fixture.settle()
            let pane = try XCTUnwrap(fixture.view.conversation)
            let chats = try XCTUnwrap(pane.superview as? WorkspaceChatsLayer)
            let before = pane.bounds.width
            let expectedFraction = 0.5 + 12 / Double(chats.bounds.width)
            fixture.view.splitHandle.changed?(12)
            await fixture.settle()
            let dragged = pane.bounds.width
            XCTAssertEqual(fixture.view.sideFraction, expectedFraction, accuracy: 0.000001, "A drag is a fraction of the whole region")
            XCTAssertEqual(UserDefaults.standard.double(forKey: "sidePaneFraction"), 0.5, "The preference changes only at mouse-up")
            XCTAssertEqual(dragged, before + 12, accuracy: 1)
            fixture.view.splitHandle.ended?(12)
            await fixture.settle()
            XCTAssertEqual(pane.bounds.width, dragged, accuracy: 1, "Ending the drag keeps the divider in place, even if a control form changed")
            XCTAssertEqual(fixture.view.sideFraction, expectedFraction, accuracy: 0.000001)
            try reference.assertSplit(fixture, fits: true, proportional: true, scene: "side drag at \(width)")
            let idleWidth = pane.bounds.width
            side.state = "running"
            await fixture.settle()
            XCTAssertEqual(pane.bounds.width, idleWidth, "Changing a minimum that still fits must not move the divider")
            try reference.assertSplit(fixture, fits: true, proportional: true, scene: "only the side becomes busy at \(width)")
        }
    }

    func testSideSplitDragStartsAtEitherVisibleClampBoundary() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        _ = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        fixture.session.state = "running"
        for (width, fraction, movement) in [(CGFloat(1800), 0.3, CGFloat(12)), (1340, 0.7, -12)] {
            fixture.window.setContentSize(NSSize(width: width, height: 800))
            UserDefaults.standard.set(fraction, forKey: "sidePaneFraction")
            fixture.view.refresh()
            await fixture.settle()
            try reference.assertSplit(fixture, fits: true, scene: "clamp at fraction \(fraction)")
            let pane = try XCTUnwrap(fixture.view.conversation)
            let chats = try XCTUnwrap(pane.superview as? WorkspaceChatsLayer)
            let side = try XCTUnwrap(fixture.view.rightPane?.subviews.compactMap { $0 as? SidePaneView }.first)
            let before = pane.bounds.width
            let boundary = movement > 0 ? ceil(pane.minimumWidth) : chats.bounds.width - SplitPane.dividerWidth - ceil(side.minimumWidth)
            XCTAssertEqual(before, boundary, "This fixture must hit the requested clamp boundary")
            let visibleFraction = Double(before / (chats.bounds.width - SplitPane.dividerWidth))
            let expectedFraction = visibleFraction + Double(movement / chats.bounds.width)
            fixture.view.splitHandle.changed?(movement)
            await fixture.settle()
            XCTAssertEqual(fixture.view.sideFraction, expectedFraction, accuracy: 0.000001)
            XCTAssertEqual(pane.bounds.width, before + movement, accuracy: 1, "Move from the actual divider without a dead zone")
            let dragged = pane.bounds.width
            fixture.view.splitHandle.ended?(movement)
            await fixture.settle()
            XCTAssertEqual(fixture.view.sideFraction, expectedFraction, accuracy: 0.000001)
            XCTAssertEqual(pane.bounds.width, dragged, accuracy: 0.01)
        }
    }

    func testSideMinimumChangesRecheckTheClampAndProportionalFallback() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        fixture.window.setContentSize(NSSize(width: 1340, height: 800))
        fixture.session.state = "running"
        UserDefaults.standard.set(0.7, forKey: "sidePaneFraction")
        fixture.view.refresh()
        for busy in [false, true, false] {
            side.state = busy ? "running" : "idle"
            await fixture.settle()
            try reference.assertSplit(fixture, fits: !busy, scene: "clamp changes to fallback, side busy \(busy)")
            XCTAssertEqual(fixture.view.sideFraction, 0.7, "Changing control minima does not rewrite the saved fraction")
        }
    }

    func testCoveredSideKeepsItsMinimumUntilRemovedFromTheFilePane() async throws {
        let fixture = try WorkspaceSplitFixture(test: self)
        fixture.window.setContentSize(WorkspaceRootView.minimumWindowSize)
        fixture.showFile(true)
        await fixture.settle()
        try fixture.assertFits("file only before the side opens")
        _ = try fixture.showSide()
        await fixture.settle()
        let pane = try XCTUnwrap(fixture.view.conversation)
        let chats = try XCTUnwrap(pane.superview as? WorkspaceChatsLayer)
        XCTAssertEqual(pane.bounds.width, SplitPane.mainWidth(total: chats.bounds.width, fraction: fixture.view.sideFraction), "A file covering a side still reserves both composers")
        fixture.model.sides[fixture.session.id] = nil
        await fixture.settle()
        try fixture.assertFits("file only after the side closes")
    }
}

@MainActor final class WorkspaceSplitGalleryTests: XCTestCase, SerialTestLane {
    func testSideConversationSplitGallery() async throws {
        guard let path = testEnvironment("PI_WORKSPACE_SPLIT_SIDE_GALLERY") else { throw XCTSkip("Set PI_WORKSPACE_SPLIT_SIDE_GALLERY to capture") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try WorkspaceSplitFixture(test: self)
        let side = try fixture.showSide()
        let reference = try WorkspaceSideSplitReference(test: self, fixture: fixture)
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for (size, sidebar) in [(WorkspaceRootView.minimumWindowSize, CGFloat(300)),
                                    (WorkspaceRootView.minimumWindowSize, CGFloat(420)),
                                    (NSSize(width: 1800, height: 800), CGFloat(300))] {
                fixture.window.setContentSize(size)
                fixture.view.sidebarHandle.ended?(sidebar - fixture.view.sidebar.frame.width)
                for busy in [false, true] {
                    fixture.session.state = busy ? "running" : "idle"
                    side.state = busy ? "running" : "idle"
                    await fixture.settle()
                    let scene = "side-\(name)-\(Int(size.width))x\(Int(size.height))-sidebar\(Int(sidebar))-\(busy ? "busy" : "idle")"
                    try reference.assertSplit(fixture, fits: size.width > 920, scene: scene)
                    fixture.window.displayIfNeeded()
                    let bitmap = try XCTUnwrap(fixture.view.bitmapImageRepForCachingDisplay(in: fixture.view.bounds))
                    fixture.view.cacheDisplay(in: fixture.view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(scene + ".png"))
                }
            }
        }
    }

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

    func showSide() throws -> SessionDisplay {
        let parent = try XCTUnwrap(model.chat)
        var child = ChatRecord(id: "split-side", workspaceID: parent.workspaceID, title: "Saved side", path: nil, profileID: parent.profileID)
        child.parentSessionID = parent.id
        model.chats.append(child)
        let side = SideRecord(id: child.id, parentID: parent.id, workspaceID: parent.workspaceID,
                              profileID: parent.profileID, title: child.title, kept: true)
        let display = SessionDisplay(id: side.id)
        display.messages = [TranscriptMessage(id: "side-reply", role: "assistant", text: "The saved side keeps its own composer and actions.")]
        display.draft = "Keep these side controls reachable."
        model.displays[side.id] = display; model.sides[parent.id] = side
        return display
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

/// Independent allocation of the released proportional split. It deliberately
/// bypasses WorkspaceChatsLayer, but mounts the same native side controls.
@MainActor private final class WorkspaceSideSplitReference {
    let root = NSView()
    let main: ConversationPaneView
    let right: RightPaneView
    let window: NSWindow

    init(test: XCTestCase, fixture: WorkspaceSplitFixture) throws {
        let model = fixture.model
        main = ConversationPaneView(model: model)
        main.show(session: fixture.session, chat: try XCTUnwrap(model.chat))
        right = RightPaneView(model: model, host: model.tabs, pane: TabContainer(isPane: true))
        right.makeSideView = { info, display, width in SidePaneView(model: model, session: display, info: info, paneWidth: width) }
        right.updateSideView = { view, info, _, width in (view as? SidePaneView)?.update(info: info, paneWidth: width) }
        right.update(side: try XCTUnwrap(fixture.view.shownSide), width: 309)
        root.addSubview(main); root.addSubview(right)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 619, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        test.addTeardownBlock { @MainActor [window] in window.contentView = nil; window.close() }
    }

    func assertSplit(_ fixture: WorkspaceSplitFixture, fits: Bool, proportional: Bool = false, scene: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actualMain = try XCTUnwrap(fixture.view.conversation, file: file, line: line)
        let chats = try XCTUnwrap(actualMain.superview as? WorkspaceChatsLayer, file: file, line: line)
        let actualRight = try XCTUnwrap(fixture.view.rightPane, file: file, line: line)
        let actualSide = try XCTUnwrap(actualRight.subviews.compactMap { $0 as? SidePaneView }.first, file: file, line: line)
        let side = try XCTUnwrap(right.subviews.compactMap { $0 as? SidePaneView }.first, file: file, line: line)
        let fraction = fixture.view.sideFraction
        let oldMain = SplitPane.mainWidth(total: chats.bounds.width, fraction: fraction)
        let oldSide = SplitPane.sideWidth(total: chats.bounds.width, fraction: fraction)
        window.setContentSize(chats.bounds.size)
        main.frame = CGRect(x: 0, y: 0, width: oldMain, height: chats.bounds.height)
        right.frame = CGRect(x: oldMain + SplitPane.dividerWidth, y: 0, width: oldSide, height: chats.bounds.height)
        root.layoutSubtreeIfNeeded()
        let mainMinimum = ceil(main.minimumWidth), sideMinimum = ceil(side.minimumWidth)
        let slack = chats.bounds.width - SplitPane.dividerWidth - mainMinimum - sideMinimum
        XCTAssertEqual(slack >= 0, fits, "\(scene): fixture must exercise the intended branch", file: file, line: line)
        if proportional {
            XCTAssertGreaterThanOrEqual(oldMain, mainMinimum, "The old proposal must already fit the main controls", file: file, line: line)
            XCTAssertGreaterThanOrEqual(oldSide, sideMinimum, "The old proposal must already fit the side controls", file: file, line: line)
            XCTAssertEqual(actualMain.frame, main.frame, "\(scene): unchanged proportional main frame", file: file, line: line)
            XCTAssertEqual(actualRight.frame, right.frame, "\(scene): unchanged proportional side frame", file: file, line: line)
        }
        let expected = fits ? min(max(oldMain, mainMinimum), chats.bounds.width - SplitPane.dividerWidth - sideMinimum) : oldMain
        XCTAssertEqual(actualMain.bounds.width, expected, accuracy: 0.01, scene, file: file, line: line)
        XCTAssertEqual(actualRight.bounds.width, chats.bounds.width - SplitPane.dividerWidth - expected, accuracy: 0.01, scene, file: file, line: line)
        if fits {
            try fixture.assertFits(scene, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actualRight.bounds.width, sideMinimum, scene, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actualRight.bounds.width, actualSide.minimumWidth, scene, file: file, line: line)
        }
        let actions = side.session.busy ? ["Queue Follow-up", "Stop response", "Close side"] : ["Send", "Close side"]
        for label in actions {
            let previous = try XCTUnwrap(PiKit.controls(in: side).first { $0.accessibilityLabel() == label }, "Missing reference \(label)", file: file, line: line)
            let control = try XCTUnwrap(PiKit.controls(in: actualSide).first { $0.accessibilityLabel() == label }, "Missing actual \(label)", file: file, line: line)
            let oldFrame = root.convert(previous.bounds, from: previous)
            let frame = chats.convert(control.bounds, from: control)
            let wasVisible = oldFrame.minX >= 0 && oldFrame.maxX <= root.bounds.width
            if fits || wasVisible {
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(scene): \(label)", file: file, line: line)
                XCTAssertLessThanOrEqual(frame.maxX, chats.bounds.width, "\(scene): \(label) must remain visible", file: file, line: line)
            }
            if !fits {
                XCTAssertEqual(frame.minX, oldFrame.minX, accuracy: 0.5, "\(scene): released \(label) position", file: file, line: line)
                XCTAssertEqual(frame.width, oldFrame.width, accuracy: 0.5, "\(scene): released \(label) width", file: file, line: line)
            }
            print("SIDE-ACTION \(scene): \(label) x=\(frame.minX)...\(frame.maxX), previous=\(oldFrame.minX)...\(oldFrame.maxX), edge=\(chats.bounds.width)")
        }
        print("SIDE-SPLIT \(scene): main=\(actualMain.bounds.width)/\(mainMinimum), side=\(actualRight.bounds.width)/\(sideMinimum), slack=\(slack), fraction=\(fraction), fallback=\(!fits)")
    }
}
