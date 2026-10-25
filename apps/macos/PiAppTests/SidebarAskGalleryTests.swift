import AppKit
import XCTest
@testable import PiApp

final class SidebarAskGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testAskBackgroundScenes() async throws {
        guard let path = testEnvironment("PI_APP_ASK_GALLERY") else { throw XCTSkip("Set PI_APP_ASK_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Tokenizer checklist", brief: "The tokenizer migration and retry checklist.")
        model.sidebarSearch.setScope(.ask); model.sidebarSearch.setQuery("Find the tokenizer checklist"); model.sidebarSearch.submit()
        await model.sidebarSearch.askChats.settle()
        model.openBackgroundRequests()
        let page = BackgroundRequestsPage(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1_000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = page; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await eventually("The Ask request is listed and counted") {
            model.backgroundRequests.rows.count == 1 && model.backgroundRequests.summary.cost == 0.004
        }
        for filter in [BackgroundRequestFilter.all, .asks] {
            model.backgroundRequests.filter = filter
            for width: CGFloat in [1_000, 640] {
                window.setContentSize(CGSize(width: width, height: 640))
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    page.needsLayout = true; page.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(120))
                    let image = try XCTUnwrap(page.bitmapImageRepForCachingDisplay(in: page.bounds))
                    page.cacheDisplay(in: page.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("background-\(filter.rawValue)-\(Int(width))-\(theme).png"))
                }
            }
        }
    }

    @MainActor func testAskScenes() async throws {
        guard let path = testEnvironment("PI_APP_ASK_GALLERY") else { throw XCTSkip("Set PI_APP_ASK_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await AskFixture.make(self, second: true, unavailable: true), model = fixture.model
        try await fixture.chat("a", title: "Welcome screen checklist", brief: "The tokenizer checklist and remaining launch checks.")
        try await fixture.chat("b", title: "Parser retry migration", brief: "Incremental parser input and retry handling, with the migration completed.")
        try await fixture.chat("c", title: "Research notes", brief: "Private research notes.", profile: "other")
        try await fixture.chat("p", title: "Personal notes", profile: "no-mini")
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.makeKeyAndOrderFront(nil)
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance; window.contentView = nil; window.close() }
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find the tokenizer checklist and parser retry")
        let ask = model.sidebarSearch.askChats
        func capture(_ scene: String, menu: Bool = false) async throws {
            for width: CGFloat in [300, 200] {
                window.setContentSize(CGSize(width: width, height: 640))
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance); window.appearance = NSAppearance(named: appearance)
                    sidebar.needsLayout = true; sidebar.settle(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(120))
                    XCTAssertTrue(sidebar.bounds.contains(sidebar.searchScope.frame), "Three search modes fit at \(width)")
                    XCTAssertFalse(sidebar.askConnection.isHidden); XCTAssertTrue(sidebar.bounds.contains(sidebar.askConnection.frame))
                    let target = folder.appendingPathComponent("ask-\(scene)-\(Int(width))-\(theme).png")
                    if menu {
                        var state: AskMenuCapture?
                        PiMenus.intercept = { built, anchor in
                            XCTAssertEqual(built.items.map(\.isEnabled), [true, true, false])
                            let capture = AskMenuCapture(menu: built) { try self.captureOwnWindows(to: target) }
                            state = capture
                            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { capture.take() } }
                            RunLoop.main.add(timer, forMode: .common)
                            built.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
                            timer.invalidate()
                        }
                        sidebar.askConnection.performClick(nil); PiMenus.intercept = nil
                        let captured = try XCTUnwrap(state)
                        XCTAssertTrue(captured.taken, "The real chooser was captured while open")
                        if let error = captured.error { throw error }
                    } else {
                        let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                        sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: target)
                    }
                }
            }
        }
        try await capture("chooser-closed")
        try await capture("chooser-open", menu: true)
        let snippets = AskCheckGate()
        addTeardownBlock { await snippets.release() }
        ask.beforeConfirmation = { _ in await snippets.wait() }
        fixture.gateway.hold(true); model.sidebarSearch.submit()
        try await eventually("The Ask mini model is waiting", timeout: .seconds(45)) { fixture.gateway.requests.count == 1 }
        try await capture("asking")
        fixture.gateway.hold(false); await ask.settleRanking(); sidebar.settle()
        XCTAssertEqual(ask.matches.map(\.id), ["b", "a"])
        XCTAssertTrue(ask.status.text.contains("in Studio · 2 checked"))
        XCTAssertEqual(ask.checkingIDs, ["a", "b"])
        try await capture("snippets-pending")
        await snippets.release(); await ask.settle(); sidebar.settle()
        XCTAssertEqual(ask.hits.count, 2); XCTAssertNotEqual(ask.hits["a"]?.excerpt, ask.hits["b"]?.excerpt)
        try await capture("results-filled")
        fixture.gateway.fail(true); model.sidebarSearch.submit(); await ask.settle(); sidebar.settle()
        XCTAssertTrue(ask.status.text.contains("Fixture Ask failure"))
        try await capture("error")
    }

    /// Include only this generated test host's windows, including its menu.
    @MainActor private func captureOwnWindows(to url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray"))
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0 }
        var bounds = CGRect.null, ids: [UnsafeRawPointer?] = []
        for window in owned {
            guard let number = window[kCGWindowNumber as String] as? UInt,
                  let raw = window[kCGWindowBounds as String] as? [String: CGFloat], let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            bounds = bounds.union(frame); ids.append(UnsafeRawPointer(bitPattern: number))
        }
        XCTAssertGreaterThan(ids.count, 1, "The chooser menu is an owned window above the sidebar")
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        let image = try XCTUnwrap(create(bounds, array, options)?.takeRetainedValue())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor private final class AskMenuCapture {
    let menu: NSMenu
    let action: () throws -> Void
    var taken = false
    var error: Error?
    init(menu: NSMenu, action: @escaping () throws -> Void) { self.menu = menu; self.action = action }
    func take() {
        taken = true
        do { try action() } catch { self.error = error }
        menu.cancelTracking()
    }
}
