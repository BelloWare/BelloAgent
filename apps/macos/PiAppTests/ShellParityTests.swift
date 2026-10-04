import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The workspace shell's AppKit views drawn next to the SwiftUI views they
/// replaced (`ShellParityReferences.swift`), light and dark, compared pixel
/// for pixel as `PiKitParityTests` compares the Pi components.
///
/// Serial: the windows are on screen.
@MainActor final class ShellParityTests: XCTestCase, SerialTestLane {
    private var results: [PiKitParity.Result] = []
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("PARITY " + result.description) }
    }

    private func check<V: View>(_ name: String, canvas: NSColor = .piContent, width: CGFloat? = nil,
                                share: Double = PiKitParityTests.symbolShare,
                                _ swiftUI: @autoclosure () -> V, _ appKit: () -> NSView,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance,
                                                       swiftUI: swiftUI().frame(width: width), appKit: appKit(), canvas: canvas, width: width)
            results.append(result)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height.rounded(.up), accuracy: 1.01, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
        }
    }

    static func detail(context: SkillDetail.Context = .composer, arguments: String = "focus on notarization", revision: SkillRevision = .current) -> SkillDetail {
        SkillDetail(context: context, id: "release-checklist", name: "release-checklist", description: "Walk through the release preflight before tagging",
                    arguments: arguments, path: "/tmp/project/.agents/skills/release-checklist/SKILL.md",
                    place: SkillPlace(kind: .project, root: "/tmp/project/.agents/skills"), policy: "explicitOnly",
                    contentHash: "0123456789abcdef", revision: revision)
    }

    func testSkillPillFace() async throws {
        for (name, args, hovered, open) in [("plain", "", false, false), ("arguments", "focus on notarization and stapling", false, false),
                                            ("hovered", "", true, false), ("open", "x", false, true)] {
            try await check("skillpill-\(name)", SkillPillFace(name: "release-checklist", arguments: args, hovered: hovered, open: open)) {
                let face = SkillPillFaceView(name: "release-checklist", arguments: args)
                face.hovered = hovered; face.open = open
                return face
            }
        }
    }

    func testSkillHoverCard() async throws {
        try await check("skillcard", canvas: .piSurface, width: SkillPopovers.cardWidth, RefSkillHoverCard(detail: Self.detail())) {
            SkillHoverCardView(detail: Self.detail())
        }
        let changed = Self.detail(arguments: "", revision: .changed(now: "fedcba98"))
        try await check("skillcard-changed", canvas: .piSurface, width: SkillPopovers.cardWidth, RefSkillHoverCard(detail: changed)) {
            SkillHoverCardView(detail: changed)
        }
    }

    func testSkillPopover() async throws {
        let actions = SkillPopoverActions(open: {}, reveal: {}, editArguments: {}, remove: {})
        try await check("skillpopover", canvas: .piSurface, width: SkillPopovers.popoverWidth, RefSkillPopoverView(detail: Self.detail(), actions: actions)) {
            SkillPopoverContentView(session: nil) { (Self.detail(), actions) }
        }
        let sent = Self.detail(context: .sent, arguments: "", revision: .changed(now: "fedcba98"))
        let plain = SkillPopoverActions(open: nil, reveal: nil)
        try await check("skillpopover-sent", canvas: .piSurface, width: SkillPopovers.popoverWidth, RefSkillPopoverView(detail: sent, actions: plain)) {
            SkillPopoverContentView(session: nil) { (sent, plain) }
        }
    }

    func testComposerPills() async throws {
        for (name, text, active, compact, width) in [("named", "Team router · Responses", false, false, CGFloat(150)), ("active", "ui-fixture", true, false, 170),
                                                     ("compact", "Effort", false, true, 176), ("compact-active", "Effort", true, true, 176),
                                                     ("cut", "a-very-long-model-alias-that-is-cut-in-the-middle", false, false, 110)] {
            // Symbols sit a fraction of a pixel apart (DesignKit's allowance),
            // which in a pill this small is a larger share; a label cut in the
            // middle is cut by Core Text, not SwiftUI.
            try await check("pill-\(name)", share: name == "cut" ? 0.05 : 0.04, RefPillLabel(icon: "cpu", text: text, active: active, loading: false, maxWidth: width, compact: compact).fixedSize()) {
                ComposerPillButton(icon: "cpu", text: text, active: active, maxTextWidth: width, compact: compact)
            }
        }
    }

    func testComposerEditBanners() async throws {
        let session = SessionDisplay(id: "banner")
        session.editNotice = "Editing message 3 of this chat. Send replaces it and everything after it."
        try await check("editbanner", width: 600, RefEditingBanner(session: session, cancel: {})) {
            let banner = ComposerEditBanner(title: "Editing an earlier message", accessibilityName: "Editing an earlier message", cancel: {})
            banner.update(detail: session.editNotice, cancelEnabled: true)
            return banner
        }
        try await check("queuebanner", width: 600, RefQueueEditBanner(steering: false, cancel: {})) {
            let banner = ComposerEditBanner(title: "Editing a queued message", accessibilityName: "Editing a queued message", cancel: {})
            banner.update(detail: "This message and the others waiting are paused while you edit. Return saves it in its place in the queue.", maximumLines: 3, cancelEnabled: true)
            return banner
        }
    }

    /// The queue panel over the composer, in the states a reader meets it:
    /// a run with steering and follow-ups, paused and folded, a message in
    /// the composer, and one held by an edit a restart left.
    func testQueuePanel() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("queue-parity-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        func session(_ name: String, _ configure: (SessionDisplay) -> Void) -> SessionDisplay {
            let session = SessionDisplay(id: "queue-" + name)
            session.queue = [["turnId": .string("s"), "kind": .string("steering"), "text": .string("[Steering] Look at the failing test first")],
                             ["turnId": .string("a"), "kind": .string("follow-up"), "text": .string("Then summarise what changed in the release notes")],
                             ["turnId": .string("b"), "kind": .string("follow-up"), "text": .string("Run the gallery again")],
                             ["turnId": .string("c"), "kind": .string("follow-up"), "text": .string("")]]
            configure(session)
            return session
        }
        let scenes: [(String, SessionDisplay)] = [
            ("running", session("running") { $0.state = "running" }),
            ("paused-folded", session("folded") { $0.state = "paused"; $0.queuePaused = true; $0.queueCollapsed = true }),
            ("editing", session("editing") { $0.state = "running"; $0.queueEditingID = "a"; $0.adoptQueueEditHold(QueueEditHold(["editId": .string("e"), "turnId": .string("a")]), revision: 1) }),
            ("held", session("held") { $0.state = "idle"; $0.adoptQueueEditHold(QueueEditHold(["editId": .string("e"), "turnId": .string("b")]), revision: 1) }),
        ]
        // The detail of one message, its choices with a long model name.
        let detail = session("detail") {
            $0.queue[1]["model"] = .string("a-very-long-provider-prefix/with-a-model-name-that-goes-on-and-on-2026-09")
            $0.queue[1]["thinkingLevel"] = .string("high"); $0.queue[1]["contextWindow"] = .number(200_000)
        }
        try await check("queue-detail", canvas: .piSurface, width: QueuedMessageDetailView.width, RefQueuedMessageDetail(model: model, session: detail, turnID: "a")
                                .fixedSize(horizontal: false, vertical: true)) {
            // At its ideal height, as its popover sizes it (a probe of the
            // SwiftUI popover measured the same).
            QueuedMessageDetailView(model: model, session: detail, turnID: "a")
        }
        for (name, session) in scenes {
            try await check("queue-\(name)", width: 640, RefQueuePanel(model: model, session: session).padding(.horizontal, PiSpacing.lg).padding(.bottom, PiSpacing.sm)) {
                QueuePanelView(model: model, session: session)
            }
        }
    }

    /// The terminal panel: tabs, title, folder and buttons, wide and in a
    /// narrow pane, with the shown shell's state.
    func testTerminalPanel() async throws {
        let registry = TerminalRegistry.shared
        registry.shutdown()
        let folder = URL(fileURLWithPath: scratchBase()).appendingPathComponent("terminal-parity-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { registry.shutdown(); model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        let project = WorkspaceRecord(id: "parity-terminals", path: folder.path, trusted: true)
        let one = registry.create(for: project), two = registry.create(for: project)
        registry.rename(two.id, in: project.id, to: "Dev server")
        // Still shells with nothing on screen: the same picture both times.
        for session in [one, two] { session.process.terminate(); session.emulator.feed(Data("\u{1b}[2J\u{1b}[H".utf8)) }
        two.shellTitle = "zsh — ~/projects/app"
        two.exited = true
        // The shell's own view moves between the two panels; the first time
        // SwiftUI's host has not drawn it yet, so one picture is thrown away.
        _ = try await PiKitParity.compare("terminal-warmup", swiftUI: RefTerminalPanel(model: model, workspace: project).frame(width: 600, height: 200),
                                          appKit: TerminalParityHolder(TerminalPanelView(model: model, workspace: project)), width: 600)
        // (At 460 points SwiftUI's header overflowed, centred and cut at both
        // ends; the AppKit header fits, its tabs scrolling past their room.)
        for width in [CGFloat(920), 600] {
            try await check("terminal-\(Int(width))", canvas: .piWindow, width: width, RefTerminalPanel(model: model, workspace: project).frame(height: 200)) {
                let panel = TerminalPanelView(model: model, workspace: project)
                panel.frame.size.height = 200
                return TerminalParityHolder(panel)
            }
        }
    }

    /// The strip of tabs: the side and three tabs in the pane, one chosen;
    /// the same tabs in a window, after its buttons.
    func testTabStrip() async throws {
        let host = TabHost(defaults: nil)
        host.showsWindows = false
        defer { host.tearDown() }
        for (key, title) in [("a", "README.md"), ("b", "Changes in bello-agent"), ("c", "a-rather-long-file-name-that-is-cut-in-the-middle-of-it.swift")] {
            host.open(kind: TabHostTests.Probe.kind, key: key) { let tab = TabHostTests.Probe(key); tab.title = title; return tab }
        }
        if let second = host.pane.tabs.dropFirst().first { host.activate(second) }
        let side = SideTabItem(title: "Side conversation", help: "The side conversation")
        try await check("tabstrip-pane", canvas: .piContent, width: 760, RefTabStrip(host: host, container: host.pane, side: side)) {
            TabStripView(host: host, container: host.pane, side: side)
        }
        try await check("tabstrip-window", canvas: .piContent, width: 760, RefTabStrip(host: host, container: host.pane, side: nil, leadingInset: 78)) {
            TabStripView(host: host, container: host.pane, side: nil, leadingInset: 78)
        }
    }

    /// The workspace's own sheets: a new topic, renaming a chat, and the
    /// webhook preview with the webhook off.
    func testWorkspaceSheets() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sheet-parity-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.workspaces = [WorkspaceRecord(id: "p", path: root.path, trusted: true)]
        model.chats = [ChatRecord(id: "c", workspaceID: "p", title: "Retry budget for the payment worker", path: nil, profileID: "none")]
        let target = TopicEditorTarget(projectID: "p")
        try await check("sheet-topic", canvas: .piWindow, width: TopicSheetView.size.width,
                        RefTopicSheet(model: model, target: target).frame(width: TopicSheetView.size.width, height: TopicSheetView.size.height)) {
            TopicSheetView(model: model, target: target, dismiss: {})
        }
        try await check("sheet-rename", canvas: .piWindow, width: RenameChatSheetView.size.width,
                        RefRenameChatSheet(model: model, chatID: "c").frame(width: RenameChatSheetView.size.width, height: RenameChatSheetView.size.height)) {
            RenameChatSheetView(model: model, chatID: "c", dismiss: {})
        }
        let side = SessionDisplay(id: "side-parity")
        side.messages = [TranscriptMessage(id: "a1", role: "assistant", text: "The retry budget resets after each successful charge; the worker keeps at most three attempts.")]
        try await check("sheet-handoff", canvas: .piWindow, width: SideHandoffView.size.width,
                        RefSideHandoff(model: model, session: side).frame(width: SideHandoffView.size.width, height: SideHandoffView.size.height)) {
            SideHandoffView(model: model, session: side, dismiss: {})
        }
        try await check("sheet-webhook", canvas: .piWindow, width: WebhookPreviewSheetView.size.width,
                        RefWebhookPreviewSheet(model: model, chatID: "c").frame(width: WebhookPreviewSheetView.size.width, height: WebhookPreviewSheetView.size.height)) {
            WebhookPreviewSheetView(model: model, chatID: "c", dismiss: {})
        }
    }
}
