import AppKit
import XCTest
@testable import PiApp

/// Standalone scenes, backed only by generated projects and an in-memory vault.
final class PendingChatProjectGalleryTests: XCTestCase {
    @MainActor func testProjectChipScenes() async throws {
        let folder = testEnvironment("PI_APP_PROJECT_GALLERY").map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let model = try await pendingProjectModel(), session = try await startPendingProjectChat(model)
        session.draft = "Review the onboarding copy and suggest a clearer first step."
        let content = WorkspaceRootView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1240, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600)] {
                window.setContentSize(size)
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    try await settle(window)
                    let composer = try XCTUnwrap(content.conversation?.composer)
                    let chip = composer.projectChip
                    XCTAssertFalse(chip.isHidden); XCTAssertTrue(chip.isEnabled)
                    XCTAssertLessThan(chip.frame.maxY, try XCTUnwrap(composer.field).convert(composer.field!.bounds, to: composer).minY)
                    let prefix = "\(flat ? "flat" : "topics")-\(Int(size.width))x\(Int(size.height))-\(name)"
                    if let folder { try capture(window, popup: nil, at: folder.appendingPathComponent(prefix + "-closed.png")) }
                    chip.performClick(nil)
                    try await eventually("project picker opened") { chip.presenter.isShown && chip.picker != nil }
                    try await settle(window)
                    let picker = try XCTUnwrap(chip.picker)
                    XCTAssertEqual(picker.visible.map(\.title), ["Orchard", "Harbor"])
                    XCTAssertEqual(picker.visible.filter(\.checked).map(\.title), ["Orchard"])
                    if let folder { try capture(window, popup: picker.window, at: folder.appendingPathComponent(prefix + "-open.png")) }
                    // Exercise the real menu command once, including the pane's
                    // replacement display/editor binding and retained draft.
                    if flat, size.width == 920, name == "dark" {
                        picker.move(1); picker.activate(picker.highlighted)
                        try await eventually("composer changed project") { model.record(session.id)?.workspaceID == "Harbor" && model.selected?.draftReady == true && content.conversation?.composer.session === model.selected }
                        XCTAssertEqual(model.selected?.draft, session.draft)
                        XCTAssertEqual(content.conversation?.composer.projectChip.accessibilityLabel(), "Project: Harbor, change")
                    }
                    chip.close()
                }
            }
        }
        // A narrow conversation pane with a long project name. It must not
        // grow the composer toolbar or clip the chip's chevron.
        let long = model.root.appendingPathComponent("A long project name for narrow composer panes")
        try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
        model.workspaces[1].path = long.path
        let narrow = ConversationPaneView(model: model)
        narrow.show(session: try XCTUnwrap(model.selected), chat: try XCTUnwrap(model.record(session.id)))
        window.contentView = narrow; window.setContentSize(NSSize(width: 420, height: 600))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance); try await settle(window)
            let chip = narrow.composer.projectChip
            XCTAssertLessThanOrEqual(chip.frame.maxX, narrow.composer.bounds.width - PiSpacing.lg)
            if let folder { try capture(window, popup: nil, at: folder.appendingPathComponent("narrow-420-\(name)-closed.png")) }
            chip.performClick(nil)
            try await eventually("narrow picker opened") { chip.presenter.isShown }
            try await settle(window)
            if let folder { try capture(window, popup: chip.picker?.window, at: folder.appendingPathComponent("narrow-420-\(name)-open.png")) }
            chip.close()
        }
        // Many projects expose search. Native command rows keep the current
        // check separate from keyboard navigation.
        for index in 1...9 {
            let path = model.root.appendingPathComponent("Project \(index)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            model.workspaces.append(WorkspaceRecord(id: "extra-\(index)", path: path.path, trusted: true))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance); try await settle(window)
            narrow.composer.projectChip.performClick(nil)
            try await eventually("searchable picker opened") { narrow.composer.projectChip.presenter.isShown }
            let picker = try XCTUnwrap(narrow.composer.projectChip.picker)
            XCTAssertFalse(picker.search.isHidden)
            picker.search.text = "Project 9"; picker.filter(picker.search.text)
            try await settle(window)
            if let folder { try capture(window, popup: picker.window, at: folder.appendingPathComponent("search-\(name).png")) }
            narrow.composer.projectChip.close()
        }
    }

    @MainActor private func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(360))
        window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.display(); window.display()
    }

    /// Capture only the two windows owned by this fixture, so another test
    /// process on this shared Mac cannot cover the evidence.
    @MainActor private func capture(_ window: NSWindow, popup: NSWindow?, at url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray"))
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let frame = popup.map { window.frame.union($0.frame) } ?? window.frame
        let screen = NSScreen.screens.first?.frame ?? .zero
        var ids = ([popup, window].compactMap { $0 }).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let rect = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let image = try XCTUnwrap(create(rect, array, CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
