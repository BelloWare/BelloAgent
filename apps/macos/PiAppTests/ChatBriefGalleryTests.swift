import AppKit
import XCTest
@testable import PiApp

/// Chat briefs (FIND-1) on screen: a row's hover card in Flat and Topics at
/// two widths, a search that finds a chat by a keyword, Settings' Chat briefs
/// card on and off, and the Background requests page's Chat briefs filter.
/// Light and dark. Generated chats only. Set PI_APP_CHAT_BRIEF_GALLERY to a
/// folder to write them.
final class ChatBriefGalleryTests: XCTestCase, SerialTestLane {
    private static let themes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    @MainActor private func folder() throws -> URL {
        guard let path = testEnvironment("PI_APP_CHAT_BRIEF_GALLERY") else { throw XCTSkip("Set PI_APP_CHAT_BRIEF_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two projects' chats, most of them with a brief, as a week of use leaves them.
    @MainActor private func model() throws -> WorkspaceModel {
        let root = scratchRoot("brief-gallery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "orchard", path: root.appendingPathComponent("Orchard").path, trusted: true),
                            WorkspaceRecord(id: "lantern", path: root.appendingPathComponent("Lantern").path, trusted: true)]
        model.topics = [TopicRecord(id: "parser", workspaceID: "lantern", title: "Parser")]
        var profile = ProfileRecord(); profile.id = "studio"; profile.name = "Studio"; profile.modelId = "design-model"
        model.profiles = [profile]
        let now = Date()
        let chats: [(String, String, String, String?, [String], TimeInterval)] = [
            ("tokenizer", "lantern", "Streaming tokenizer", "Moving the lantern parser to streaming input. The tokenizer now reads in chunks; error recovery for unterminated strings is next.",
             ["tokenizer", "streaming", "PR 812", "Parser.swift"], 25 * 60),
            ("recovery", "lantern", "Error recovery pass", "Unterminated strings now resume at the next quote; two snapshot tests still fail on CRLF input.",
             ["error recovery", "CRLF", "snapshots"], 3 * 3_600),
            ("launch", "orchard", "Launch checklist", "Drafting the 2.4 launch checklist: notarization and the release notes are done, the press kit waits on screenshots.",
             ["launch", "notarization", "press kit"], 26 * 3_600),
            ("welcome", "orchard", "Welcome screen copy", nil, [], 50 * 3_600),
            ("pricing", "orchard", "Pricing page review", "Comparing three pricing layouts; the team prefers the two-column one with a yearly toggle.",
             ["pricing", "layout", "yearly"], 4 * 86_400),
        ]
        for (index, chat) in chats.enumerated() {
            var record = ChatRecord(id: chat.0, workspaceID: chat.1, title: chat.2, path: root.appendingPathComponent(chat.0 + ".jsonl").path, profileID: profile.id)
            record.lastActivityAt = Int64((now.timeIntervalSince1970 - chat.5) * 1_000_000); record.sidebarOrder = record.lastActivityAt
            if chat.1 == "lantern" { record.topicID = "parser" }
            if let text = chat.3 {
                record.brief = ChatBrief(text: text, keywords: chat.4, through: "m\(index)", at: now.addingTimeInterval(-chat.5 + 90), activity: record.lastActivityAt)
            }
            model.chats.append(record)
        }
        model.configuration.briefSettings.enabled = true
        return model
    }

    /// The hover card over its row, in Flat and Topics, wide and narrow.
    @MainActor func testHoverCardScenes() async throws {
        let folder = try folder(), model = try model()
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.orderFront(nil)
        SidebarBriefCard.presenter.delay = .milliseconds(10); SidebarBriefCard.presenter.reducesMotion = true
        defer { SidebarBriefCard.presenter.hide(); SidebarBriefCard.presenter.delay = PiHoverCardPresenter.delay; window.contentView = nil; window.close() }
        for (layout, flat) in [("flat", true), ("topics", false)] {
            model.setSidebarFlat(flat)
            for width: CGFloat in [300, 220] {
                window.setContentSize(NSSize(width: width, height: 560))
                for (theme, appearance) in Self.themes {
                    window.appearance = NSAppearance(named: appearance)
                    SidebarBriefCard.presenter.hide()
                    sidebar.needsLayout = true; sidebar.settle(); window.displayIfNeeded()
                    let row = try XCTUnwrap(rowView("tokenizer", in: sidebar), "The briefed chat is listed")
                    row.body.setHovering(true)
                    try await eventually("the card comes up", timeout: .seconds(5)) { SidebarBriefCard.presenter.isShown }
                    try await shown(window)
                    try capture(window, to: folder.appendingPathComponent("hover-\(layout)-\(Int(width))-\(theme).png"))
                    row.body.setHovering(false)
                }
            }
        }
    }

    /// A keyword the chat's title does not hold finds it in Titles & details.
    @MainActor func testSearchScenes() async throws {
        let folder = try folder(), model = try model()
        model.setSidebarFlat(true)
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        sidebar.setFilter("crlf"); sidebar.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["recovery"])
        for (theme, appearance) in Self.themes {
            window.appearance = NSAppearance(named: appearance)
            sidebar.needsLayout = true; sidebar.settle()
            try await shown(window)
            try capture(window, to: folder.appendingPathComponent("search-keyword-\(theme).png"))
        }
    }

    /// Settings → Chats & notifications, its Chat briefs card on and off.
    @MainActor func testSettingsScenes() async throws {
        let folder = try folder()
        let root = scratchRoot("brief-settings-gallery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        model.settingsSection = .chats
        let view = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let window = NSWindow(contentRect: NSRect(x: 200, y: 120, width: 880, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for (state, enabled) in [("off", false), ("on", true)] {
            controller.preferences.briefSettings.enabled = enabled
            for (theme, appearance) in Self.themes {
                window.appearance = NSAppearance(named: appearance)
                for _ in 0..<5 { view.refresh(); view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
                try await shown(window)
                try capture(window, to: folder.appendingPathComponent("settings-chats-\(state)-\(theme).png"))
            }
        }
    }

    /// The Background requests page with brief requests, and its Chat briefs filter.
    @MainActor func testBackgroundRequestsScenes() async throws {
        let folder = try folder(), model = try model()
        let now = Date()
        func request(_ id: String, _ kind: String, source: String, minutes: Double, result: String?, outcome: String? = "completed") -> ChatRecord {
            var value = ChatRecord(id: id, workspaceID: WorkspaceRecord.scratchID, title: kind == "chat-brief" ? "Chat brief" : "Request", path: nil,
                                   profileID: "studio", toolMode: "read-only", connectionTest: true, model: "mini-fixture", thinkingLevel: "default",
                                   contextWindow: 16_000, maxOutputTokens: 512)
            value.backgroundTask = kind; value.sourceSessionID = source
            value.backgroundTaskStartedAt = now.addingTimeInterval(-minutes * 60); value.backgroundTaskOutcome = outcome
            value.backgroundTaskResult = result
            if outcome != nil { value.backgroundTaskEndedAt = value.backgroundTaskStartedAt?.addingTimeInterval(2.4) }
            return value
        }
        model.chats += [
            request("brief-1", "chat-brief", source: "tokenizer", minutes: 24, result: "Moving the lantern parser to streaming input.\ntokenizer, streaming, PR 812"),
            request("brief-2", "chat-brief", source: "recovery", minutes: 170, result: "Unterminated strings now resume at the next quote.\nerror recovery, CRLF"),
            request("title-1", "session-title", source: "welcome", minutes: 3_000, result: "Welcome screen copy"),
            request("brief-3", "chat-brief", source: "launch", minutes: 1_500, result: "Drafting the 2.4 launch checklist.\nlaunch, notarization"),
        ]
        let page = BackgroundRequestsPage(model: model)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = page; window.orderFront(nil)
        defer { model.backgroundRequests.suspend(); window.contentView = nil; window.close() }
        for filter in [BackgroundRequestFilter.all, .briefs] {
            model.backgroundRequests.filter = filter
            for width: CGFloat in [1000, 700] {
                window.setContentSize(NSSize(width: width, height: 560))
                for (theme, appearance) in Self.themes {
                    window.appearance = NSAppearance(named: appearance)
                    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); page.layoutSubtreeIfNeeded() }
                    try await shown(window)
                    try capture(window, to: folder.appendingPathComponent("background-\(filter.rawValue)-\(Int(width))-\(theme).png"))
                }
            }
        }
        XCTAssertEqual(model.backgroundRequests.counts[.briefs], 3)
    }

    /// Drawn, and on its way to the window server: what a capture reads is
    /// what is on screen, in the appearance just chosen.
    @MainActor private func shown(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            window.contentView?.needsDisplay = true; window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    @MainActor private func rowView(_ id: String, in view: NSView) -> SidebarChatRowView? {
        if let row = view as? SidebarChatRowView, row.chat.id == id { return row }
        return view.subviews.lazy.compactMap { self.rowView(id, in: $0) }.first
    }

    /// The window and the brief's card over it, as the window server shows
    /// them (this process's own windows; no screen-recording consent).
    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        let cards = NSApp.windows.filter { $0.isVisible && $0 is PiHoverCardPanel }
        var frame = window.frame
        for card in cards { frame = frame.union(card.frame) }
        var ids = (cards + [window]).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let image = create(bounds, array, options)?.takeRetainedValue() else { throw XCTSkip("Window capture returned no image") }
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
