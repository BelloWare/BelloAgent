import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The composer footer against its pre-port appearance at wide, narrow and
/// side-pane widths. Windows are captured alone on the machine.
@MainActor final class MetricsFooterParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func check(_ name: String, width: CGFloat, running: Bool = false, compact: Bool = false,
                       notice: String = "", preparing: Bool = false, captureAvailable: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let root = scratchRoot("footer-parity")
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            func session() -> SessionDisplay {
                let session = SessionDisplay(id: "footer")
                session.footer.gateway = SessionStatsFixture.gateway(SessionStatsFixture.session())
                session.footer.turnTiming = ["sessionModelMs": .number(61_000), "sessionToolMs": .number(23_500),
                                             "startedAt": .number(1_000), "endedAt": .number(13_000), "elapsedMs": .number(12_000)]
                session.context = preparing ? [:] : ["tokens": .number(45_000), "contextWindow": .number(200_000)]
                session.footer.preparingContext = preparing
                session.captureMode = "memory"; session.captureAvailable = captureAvailable
                session.state = running ? "running" : "idle"
                session.activity = ["phase": .string("model")]
                session.notice = notice
                return session
            }
            let reference = MetricsFooterReference(model: model, session: session(), compact: compact, inspect: {})
            let native = MetricsFooter(model: model, session: session(), compact: compact, inspect: {})
            let result = try await PiKitParity.compare("footer-\(name)-\(Int(width))-\(suffix)", appearance: appearance,
                                                       swiftUI: reference.frame(width: width), appKit: native, width: width)
            print("FOOTERPARITY " + result.description)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, result.description, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * 0.012, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: 64).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * 0.002, "\(result.name): \(strong) strong differences", file: file, line: line)
        }
    }

    func testIdleAndRunningFootersMatchAtWideAndNarrowWidths() async throws {
        for width: CGFloat in [1_600, 1_200, 900, 520, 300] {
            try await check("idle", width: width)
            try await check("running", width: width, running: true)
        }
    }

    func testNoticesPreparationCaptureAndSideFootersMatch() async throws {
        for width: CGFloat in [1_600, 900, 520, 300] {
            try await check("notice", width: width, notice: "Run cancelled. Pending messages are paused; resume below")
            try await check("preparing", width: width, preparing: true, captureAvailable: false)
            try await check("side", width: width, compact: true, notice: "Pending messages are paused; resume below")
        }
    }
}

@MainActor final class MetricsFooterControlTests: XCTestCase, SerialTestLane {
    private func model() -> WorkspaceModel {
        let root = scratchRoot("footer-controls")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        return model
    }

    func testNarrowCaptureBadgeUsesOnlyItsGlyphAndKeepsItsAccessibleName() throws {
        let model = model(), session = SessionDisplay(id: "narrow")
        session.context = ["tokens": .number(45_000), "contextWindow": .number(200_000)]
        session.captureMode = "memory"; session.captureAvailable = true
        let footer = MetricsFooter(model: model, session: session, inspect: {})
        func layout(_ width: CGFloat) {
            footer.frame = CGRect(x: 0, y: 0, width: width, height: footer.height(forWidth: width))
            footer.layoutSubtreeIfNeeded()
        }
        layout(220)
        XCTAssertFalse(footer.fullForm)
        let badge = try XCTUnwrap(ConversationPaneTests.views(PiKit.Badge.self, in: footer).first)
        XCTAssertEqual(badge.text, "", "The narrow form shows the capture symbol alone")
        let target = try XCTUnwrap(ConversationPaneTests.views(CaptureBadge.Target.self, in: footer).first)
        XCTAssertEqual(target.accessibilityLabel(), "Capture: Session memory. Open the Session Inspector")
        layout(900)
        XCTAssertTrue(footer.fullForm)
        XCTAssertEqual(badge.text, "Session memory", "Resizing restores the full caption")
    }

    func testResizeMeasuresTheChosenUsageFaceWithoutRollingBetweenForms() {
        let session = SessionDisplay(id: "resize")
        session.footer.gateway = SessionStatsFixture.gateway(SessionStatsFixture.session())
        let context: [String: WireValue] = ["tokens": .number(45_000), "contextWindow": .number(200_000)]
        let pills = SessionStatsPills(session: session, selectedContextWindow: nil, compact: false, open: { _ in })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 2_000, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pills
        defer { window.contentView = nil; window.close() }
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = nil }
        pills.update(context: context)
        let stats = SessionStatsPresentation(gateway: session.footer.gateway, work: nil, cost: session.footer.cost)
        for width: CGFloat in [2_000, 420, 2_000, 420] {
            let measured = pills.height(forWidth: width)
            pills.frame = CGRect(x: 0, y: 0, width: width, height: measured)
            pills.layoutSubtreeIfNeeded()
            let bottom = pills.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max() ?? 0
            XCTAssertEqual(bottom, measured, accuracy: 0.5, "The measured footer leaves no extra row after resizing to \(width)")
            XCTAssertEqual(pills.usage.label, width > 1_000 ? stats.usageFace.label : stats.compactUsageFace.label)
            XCTAssertNil(pills.usage.rollingChange, "Changing layout replaces the face immediately")
        }
    }

    func testDisablingAPaneKeepsItsFooterAndReservedCaptureWidth() throws {
        let root = scratchRoot("footer-enabled")
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["footer"])
        registerWorkspaceFixtureTeardown(bench.model, root: root)
        let chat = bench.chats[0], session = SessionDisplay(id: chat.id)
        session.captureMode = "memory"; session.captureAvailable = true
        let pane = ConversationPaneView(model: bench.model)
        pane.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        pane.show(session: session, chat: chat)
        let footer = try XCTUnwrap(ConversationPaneTests.views(MetricsFooter.self, in: pane).first)
        let badge = try XCTUnwrap(ConversationPaneTests.views(CaptureBadge.self, in: footer).first)
        let reserved = badge.slotWidth(full: true)
        session.captureAvailable = false
        footer.refresh()
        for enabled in [false, true] {
            pane.inheritedEnabled = enabled
            let shown = try XCTUnwrap(ConversationPaneTests.views(MetricsFooter.self, in: pane).first)
            XCTAssertTrue(shown === footer, "The same chat keeps its footer when its pane is disabled or enabled")
            let shownBadge = try XCTUnwrap(ConversationPaneTests.views(CaptureBadge.self, in: shown).first)
            XCTAssertEqual(shownBadge.slotWidth(full: true), reserved)
            XCTAssertEqual(shownBadge.isEnabled, enabled)
        }
    }

    func testVisibleFooterRecountsWhenTheConfigurationRevisionChanges() async throws {
        let model = model(), session = SessionDisplay(id: "configuration")
        var profile = ProfileRecord(); profile.id = "footer-profile"; profile.modelId = "fixture-model"
        profile.baseUrl = "http://127.0.0.1:9/v1"; profile.api = LiteLLMConfiguration.supportedAPI
        let workspace = WorkspaceRecord(id: "footer-project", path: model.root.path, trusted: true)
        model.workspaces = [workspace]; model.profiles = [profile]
        model.chats = [ChatRecord(id: session.id, workspaceID: workspace.id, title: "Footer", path: nil, profileID: profile.id)]
        model.displays[session.id] = session
        model.selectedID = session.id; model.focusedSessionID = session.id
        session.loading = false; session.contextSelectionReady = true
        var counts = 0
        model.automaticContextOperation = { _, _ in
            counts += 1
            return ["tokens": .number(Double(counts * 100)), "contextWindow": .number(1_000)]
        }
        let footer = MetricsFooter(model: model, session: session, inspect: {})
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = footer
        defer { window.contentView = nil; window.close() }
        window.orderFrontRegardless()
        try await eventually("the visible footer's initial count", timeout: .seconds(5)) { counts == 1 && model.automaticContextTask == nil }
        model.configuration.revision += 1
        try await eventually("the footer recounting after configuration changes", timeout: .seconds(5)) { counts == 2 && model.automaticContextTask == nil }
    }
}
