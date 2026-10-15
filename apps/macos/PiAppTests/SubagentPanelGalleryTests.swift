import AppKit
import Darwin
import XCTest
@testable import PiApp

final class SubagentPanelGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testMainColumnFamilyAndChildTabGallery() async throws {
        guard let path = testEnvironment("PI_APP_SUB_PANEL_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_PANEL_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        let model = fixture.model, window = fixture.window
        let root = WorkspaceRootView(model: model); window.contentView = root
        let previousMotion = PiKit.Motion.reducedOverride; PiKit.Motion.reducedOverride = true
        defer { PiKit.Motion.reducedOverride = previousMotion; fixture.close() }
        addTeardownBlock { @MainActor in model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        var files: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                window.setContentSize(size)
                for done in [false, true] {
                    for tab in model.tabs.allTabs { model.tabs.close(tab) }
                    fixture.show(done ? "completed" : "parallel-queued")
                    fixture.child.subagentStatus = done ? .completed : .running
                    fixture.child.runState = done ? .idle : .running
                    fixture.child.runStatus = done ? "idle" : "streaming"
                    root.refresh(); await settle(window)
                    let main = try XCTUnwrap(root.conversation)
                    XCTAssertFalse(main.agentFamilyHeader.isHidden)
                    XCTAssertEqual(main.agentFamilyHeader.button.title.hasPrefix("Agents 4"), true)
                    let base = "\(done ? "done" : "running")-\(theme)-\(Int(size.width))x\(Int(size.height))"
                    try capture([window], to: folder.appendingPathComponent(base + "-closed.png")); files.append(base + "-closed.png")
                    main.agentFamilyHeader.open(); await settle(window)
                    let popup = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                    try capture([popup, window], to: folder.appendingPathComponent(base + "-open.png")); files.append(base + "-open.png")
                    let content = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view)
                    let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: content).first { $0.accessibilityIdentifier() == "open-agent-child-0" })
                    XCTAssertTrue(open.accessibilityLabel()?.contains("Sub-agent 1") == true)
                    let list = try XCTUnwrap(ConversationPaneTests.views(AgentFamilyPopoverView.self, in: content).first)
                    let tabKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: popup.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                    list.keyDown(with: tabKey)
                    XCTAssertTrue(popup.firstResponder === open)
                    if !done {
                        let stop = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: content).first { $0.title == "Stop All…" })
                        var reviewed = false
                        model.questions.presentSheet = { sheet, owner, answer in
                            XCTAssertTrue(owner === window)
                            XCTAssertTrue(sheet is AgentStopAllSheet)
                            reviewed = true; answer(false)
                        }
                        stop.onPress?(); XCTAssertTrue(reviewed)
                        model.questions.presentSheet = nil
                    }
                    main.agentFamilyHeader.popover.close()
                    await model.openSubagentTab("child-0")
                    root.refresh(); await settle(window)
                    let tab = try XCTUnwrap(model.subagentTab("child-0")), pane = try XCTUnwrap(model.subagentTab("child-0")?.pane)
                    XCTAssertTrue(pane.composer.isHidden); XCTAssertTrue(pane.agentFamilyHeader.isHidden)
                    XCTAssertEqual(model.selectedID, fixture.parent.id)
                    let mainBounds = main.convert(main.bounds, to: root)
                    let pill = main.agentFamilyHeader.button.convert(main.agentFamilyHeader.button.bounds, to: root)
                    let childBounds = pane.convert(pane.bounds, to: root)
                    XCTAssertLessThanOrEqual(pill.maxX, mainBounds.maxX)
                    XCTAssertLessThanOrEqual(mainBounds.maxX, childBounds.minX)
                    XCTAssertGreaterThanOrEqual(main.transcript.frame.minY, main.agentFamilyHeader.frame.maxY)
                    try capture([window], to: folder.appendingPathComponent(base + "-side.png")); files.append(base + "-side.png")
                    await model.openSubagentTab("child-0"); XCTAssertTrue(model.subagentTab("child-0") === tab)
                    XCTAssertTrue(window.firstResponder === pane)
                    await model.backToSubagentParent("child-0")
                    XCTAssertEqual(model.focusedSessionID, fixture.parent.id)
                    if done {
                        model.tabs.popOut(tab); await settle(window)
                        let popped = try XCTUnwrap(tab.container.flatMap { model.tabs.window(of: $0) })
                        popped.appearance = window.appearance; await settle(popped)
                        XCTAssertFalse(pane.agentFamilyHeader.isHidden)
                        XCTAssertTrue(popped.title.contains("Sub-agent 1"))
                        pane.agentFamilyHeader.open(); await settle(popped)
                        let siblingPopup = try XCTUnwrap(pane.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                        try capture([siblingPopup, popped], to: folder.appendingPathComponent(base + "-window.png")); files.append(base + "-window.png")
                        pane.agentFamilyHeader.popover.close()
                        model.tabs.moveToPane(tab); await settle(window)
                    }
                }
            }
        }
        XCTAssertEqual(files.count, 28)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor private func settle(_ window: NSWindow) async {
        for _ in 0..<4 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(75)) }
    }
    /// Only this fixture's windows, including its own popup. Never the desktop.
    @MainActor private func capture(_ windows: [NSWindow], to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let union = windows.reduce(CGRect.null) { $0.union($1.frame) }
        let screen = NSScreen.screens.first?.frame ?? .zero
        let scale = windows.first?.backingScaleFactor ?? 1
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        for window in windows.reversed() {
            let frame = window.frame
            let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
            let image = try XCTUnwrap(create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
            context.draw(image, in: CGRect(x: frame.minX - union.minX, y: frame.minY - union.minY, width: frame.width, height: frame.height))
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
