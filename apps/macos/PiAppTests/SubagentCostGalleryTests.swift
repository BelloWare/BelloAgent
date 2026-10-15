import AppKit
import XCTest
@testable import PiApp

/// Standalone, generated native scenes; no provider, real preferences or app.
final class SubagentCostGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testCostAttributionScenes() async throws {
        guard let path = testEnvironment("PI_APP_SUB_COST_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_COST_GALLERY for native cost scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in
            fixture.close(); try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        try await fixture.model.traces.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        for index in -1..<3 {
            let id = index < 0 ? "chat-parent" : "child-\(index)"
            var metadata: [String: WireValue] = ["attemptId":.string(UUID().uuidString), "sessionId":.string(id), "turnId":.string("turn"),
                "purpose":.string("turn"), "api":.string("openai-responses"), "requestedModel":.string("fixture-model"),
                "timingVersion":.number(2), "timings":.object(["dispatch":.number(100), "firstContent":.number(300), "lastContent":.number(800)]),
                "mode":.string("off"), "outcome":.string("completed"), "wallTimestamp":.number(Date().timeIntervalSince1970),
                "usage":.object(["inputIncludingCache":.number(1500), "output":.number(250), "cacheRead":.number(500)]),
                "gateway":.object(["version":.number(1), "cost":.object(["status":.string("reported"), "usd":.number(index < 0 ? 0.78 : 0.15)])])]
            if index >= 0 {
                let scope = RequestScope(sourceSessionID: id, budgetOwnerSessionID: "chat-parent", turnID: "turn", executionID: "execution", purpose: "turn", ownerGeneration: 0, delegation: fixture.model.record(id)!.delegation)
                metadata["requestScope"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(scope))
            }
            try await fixture.model.traces.begin(metadata, workspace: "pane-project"); try await fixture.model.traces.finish(metadata)
        }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                for scene in ["completed", "child"] {
                    fixture.show(scene); settleFixtureValues(fixture)
                    for summary in fixture.model.subagentSummaries.values { try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project") }
                    for session in [fixture.parent, fixture.child] {
                        await fixture.model.refreshAccounting(session, workspaceID: "pane-project", includeMessages: false)
                    }
                    fixture.parent.footer.cost = SessionCostReading(limit: .usd(5), spentUSD: 1.23, reportedRequests: 4)
                    await fixture.settle()
                    try await eventually("settled cost pill", timeout: .seconds(10)) {
                        fixture.content.layoutSubtreeIfNeeded()
                        let pills = ConversationPaneTests.views(SessionStatsPills.self, in: fixture.content)
                        let expected = scene == "child" ? "$0.15" : "$1.23"
                        return pills.contains { $0.usage.label.contains(expected) && !$0.usage.isRolling }
                    }
                    try save(try XCTUnwrap(fixture.window.contentView), to: folder.appendingPathComponent("\(scene)-\(name)-\(Int(size.width)).png"))
                }
                fixture.show("completed"); settleFixtureValues(fixture)
                await fixture.model.refreshAccounting(fixture.parent, workspaceID: "pane-project", includeMessages: false)
                fixture.parent.footer.cost = SessionCostReading(limit: .usd(5), spentUSD: 1.23, reportedRequests: 4)
                let inspector = SessionInspectorModel(scope: .init(sessionID: "chat-parent", workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model, usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                    try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                })
                let controller = SessionInspectorWindowController(inspector: inspector)
                controller.window?.appearance = NSAppearance(named: appearance); controller.window?.setContentSize(size); controller.present(.overview)
                try await eventually("Inspector cost breakdown", timeout: .seconds(15)) { inspector.groups.count == 4 && inspector.inputs.gateway.requests == 4 && inspector.tokenCharts.hero.contains { $0.id == "cost" } }
                let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
                try await eventually("rendered child cost controls", timeout: .seconds(10)) {
                    content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    return ConversationPaneTests.views(PiKit.Button.self, in: content).filter { $0.accessibilityIdentifier().hasPrefix("subagent-cost-") }.count == 4
                }
                let buttons = ConversationPaneTests.views(PiKit.Button.self, in: content).filter { $0.accessibilityIdentifier().hasPrefix("subagent-cost-") }
                XCTAssertEqual(buttons.count, 4)
                XCTAssertTrue(buttons.first?.accessibilityLabel()?.contains("counts toward this chat") == true)
                XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(buttons.first)), "Cost details are reachable by keyboard")
                try save(content, to: folder.appendingPathComponent("inspector-\(name)-\(Int(size.width)).png"))
                let breakdown = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: content).first { $0.accessibilityIdentifier() == "inspector-subagent-costs" })
                breakdown.scrollToVisible(breakdown.bounds)
                try save(content, to: folder.appendingPathComponent("breakdown-\(name)-\(Int(size.width)).png"))
                buttons.first?.performClick(nil)
                XCTAssertEqual(inspector.page, .subagent("delegation-0"))
                if size.width == 920 {
                    let narrow = InspectorOverviewPage(inspector: inspector, compact: true)
                    let narrowWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                    narrowWindow.isReleasedWhenClosed = false; narrowWindow.appearance = NSAppearance(named: appearance)
                    narrowWindow.contentView = narrow; narrowWindow.orderFront(nil)
                    narrow.wantsLayer = true
                    narrow.effectiveAppearance.performAsCurrentDrawingAppearance { narrow.layer?.backgroundColor = NSColor.piContent.cgColor }
                    try save(narrow, to: folder.appendingPathComponent("inspector-narrow-\(name).png"))
                    let detail = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: narrow).first { $0.accessibilityIdentifier() == "inspector-subagent-costs" })
                    detail.scrollToVisible(detail.bounds)
                    try save(narrow, to: folder.appendingPathComponent("breakdown-narrow-\(name).png"))
                    narrowWindow.contentView = nil; narrowWindow.close()
                }
                controller.close()
            }
        }
    }
    @MainActor private func settleFixtureValues(_ fixture: SubagentGalleryFixture) {
        PiKit.Motion.reducedOverride = true
        fixture.parent.runState = .idle; fixture.parent.runStatus = "completed"
        // The shared gallery fixture has illustrative progress. Match this
        // scene's actual capture so the card, child and parent agree.
        guard var summary = fixture.model.subagentSummaries["child-0"] else { return }
        summary.progress?.usd = 0.15; summary.progress?.reported = 1; summary.progress?.unreported = 0
        summary.progress?.requests = 1; summary.progress?.inputTokens = 1500; summary.progress?.outputTokens = 250
        fixture.model.subagentSummaries["child-0"] = summary
        var messages = fixture.parent.messages
        if messages.count > 1, var tools = messages[1].tools, !tools.isEmpty {
            tools[0].subagent = summary; messages[1].tools = tools; fixture.parent.messages = messages
        }
    }
    @MainActor private func save(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
