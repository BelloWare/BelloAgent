import AppKit
import XCTest
@testable import GitView
@testable import PiApp

/// Standalone: no chat fixture, gateway, installed app, preferences or vault.
final class GitHistoryGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testHistoryScenes() async throws {
        guard let path = testEnvironment("PI_APP_HISTORY_GALLERY") else { throw XCTSkip("Set PI_APP_HISTORY_GALLERY for the standalone History gallery") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try GitHistoryFixture(count: 8); defer { fixture.close() }
        let longRef = "feature/restore-committed-history-filters-with-exact-object-navigation-and-long-reference-names"
        try fixture.git(["branch", longRef]); try fixture.git(["tag", "v-fixture"])
        try await fixture.start(); fixture.controller.panel = .history
        let scene = GitHistoryGalleryScene(fixture)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scene; window.applyPiWindowChrome()
        defer { window.close() }
        var files: [String] = []
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600)] {
                window.setContentSize(size)
                for name in ["filtered", "empty", "loading", "long-ref"] {
                    fixture.controller.logFilter = .init(); fixture.options = .init()
                    var release: CheckedContinuation<Void, Never>?, held: Task<Bool, Never>?
                    fixture.state.didRead = nil
                    if name == "filtered" {
                        fixture.controller.logFilter = .init(text: "Change", author: "History Fixture", path: "notes.txt")
                        fixture.options.dates = .init(from: "2026-10-14", through: "2026-10-14")
                    } else if name == "empty" { fixture.controller.logFilter.text = "No matching commit" }
                    else if name == "long-ref" { fixture.options.reference = "refs/heads/" + longRef }
                    else if name == "loading" {
                        fixture.controller.logFilter.text = "Reading a new query"
                        fixture.state.didRead = { _ in await withCheckedContinuation { release = $0 } }
                    }
                    let query = GitHistoryQuery(filter: fixture.controller.logFilter, options: fixture.options)
                    if name == "loading" {
                        held = Task { await fixture.state.reload(in: fixture.historyRoot, query: query) }
                        try await fixture.wait { release != nil }
                    } else { _ = await fixture.state.reload(in: fixture.historyRoot, query: query) }
                    fixture.update()
                    fixture.controller.selectedCommit = fixture.state.reading.commits.first
                    try await fixture.wait { !fixture.controller.commitLoading }
                    scene.update(); scene.frame = CGRect(origin: .zero, size: size)
                    window.orderFrontRegardless()
                    for _ in 0..<4 { scene.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
                    let file = "\(name)-\(theme)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(window, to: folder.appendingPathComponent(file)); files.append(file)
                    release?.resume(); _ = await held?.value; fixture.state.didRead = nil
                }
            }
        }
        XCTAssertEqual(files.count, 16)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: Capture.self)
        let screen = NSScreen.screens.first?.frame ?? .zero, frame = window.frame
        let rect = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let image = try XCTUnwrap(create(rect, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                        CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

@MainActor private final class GitHistoryGalleryScene: PiKit.Box {
    private let fixture: GitHistoryFixture
    private let title = PiKit.TextLine(PiKit.Line("History", font: PiKit.Font.title(17), color: .piInk))
    private let context = PiKit.TextLine(PiKit.Line("History Fixture · main", font: PiKit.Font.caption, color: .piInkSecondary))
    private let rule = HairlineView(), divider = HairlineView()
    private let detail: GitPanelDetail
    init(_ fixture: GitHistoryFixture) {
        self.fixture = fixture; detail = GitPanelDetail(controller: fixture.controller, openFile: nil)
        super.init(fill: .piContent)
        for view in [title, context, rule, fixture.browser, divider, detail] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    func update() { fixture.update(); detail.apply(.init(fixture.controller)); needsLayout = true }
    override func layout() {
        super.layout()
        let inset = PiWindowBar.trafficLightInset
        title.frame = CGRect(x: inset, y: 12, width: 100, height: 26)
        context.frame = CGRect(x: inset + 110, y: 17, width: max(0, bounds.width - inset - 126), height: 18)
        rule.frame = CGRect(x: 0, y: 50, width: bounds.width, height: 1)
        let width: CGFloat = bounds.width >= 1000 ? 380 : 300
        fixture.browser.frame = CGRect(x: 0, y: 51, width: width, height: max(0, bounds.height - 51))
        divider.frame = CGRect(x: width, y: 51, width: 1, height: max(0, bounds.height - 51))
        detail.frame = CGRect(x: width + 1, y: 51, width: max(0, bounds.width - width - 1), height: max(0, bounds.height - 51))
    }
}
