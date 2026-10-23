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
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Welcome screen checklist", brief: "The marmalade tokenizer checklist and remaining launch checks.")
        try await fixture.chat("b", title: "Parser retry migration", brief: "Incremental parser input and retry handling, with the migration completed.")
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Where did we discuss parser retries?")
        let ask = model.sidebarSearch.askChats
        fixture.gateway.hold(true); model.sidebarSearch.submit()
        try await eventually("The Ask mini model is waiting", timeout: .seconds(45)) { fixture.gateway.requests.count == 1 }
        func capture(_ scene: String) async throws {
            for width: CGFloat in [300, 200] {
                window.setContentSize(CGSize(width: width, height: 640))
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    sidebar.needsLayout = true; sidebar.settle(); window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(120))
                    XCTAssertTrue(sidebar.bounds.contains(sidebar.searchScope.frame), "Three search modes fit at \(width)")
                    let image = try XCTUnwrap(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
                    sidebar.cacheDisplay(in: sidebar.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("ask-\(scene)-\(Int(width))-\(theme).png"))
                }
            }
        }
        try await capture("asking")
        fixture.gateway.hold(false); await ask.settle(); sidebar.settle()
        XCTAssertEqual(ask.matches.map(\.id), ["b", "a"])
        try await capture("results")
        fixture.gateway.fail(true); model.sidebarSearch.submit(); await ask.settle(); sidebar.settle()
        XCTAssertTrue(ask.status.text.contains("Fixture Ask failure"))
        try await capture("error")
    }
}
