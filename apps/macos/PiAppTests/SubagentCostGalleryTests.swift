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
        fixture.model.configuration.chatCostLimit = .usd(5)
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
        let sideScope = RequestScope(sourceSessionID: "cost-side", budgetOwnerSessionID: "cost-side", turnID: "turn", executionID: "side-execution", purpose: "turn", ownerGeneration: 0, delegation: nil, sideParents: ["chat-parent"])
        let sideMetadata: [String: WireValue] = ["attemptId":.string(UUID().uuidString),"sessionId":.string("cost-side"),"turnId":.string("turn"),
            "purpose":.string("turn"),"api":.string("openai-responses"),"requestedModel":.string("fixture-model"),"mode":.string("off"),
            "outcome":.string("completed"),"wallTimestamp":.number(Date().timeIntervalSince1970),"timingVersion":.number(2),"timings":.object(["dispatch":.number(100)]),
            "requestScope":try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(sideScope)),
            "usage":.object(["inputIncludingCache":.number(800),"output":.number(200)]),
            "gateway":.object(["version":.number(1),"cost":.object(["status":.string("reported"),"usd":.number(0.40)])])]
        try await fixture.model.traces.begin(sideMetadata,workspace:"pane-project"); try await fixture.model.traces.finish(sideMetadata)
        let sideView = SessionDisplay(id: "cost-side")
        sideView.historyState = .ready; sideView.draftReady = true; sideView.runStateKnown = true; sideView.runState = .idle
        sideView.messages = [TranscriptMessage(id: "side-question", role: "user", text: "Compare the parser alternatives."),
                             TranscriptMessage(id: "side-answer", role: "assistant", text: "Keep the existing scanner and preserve the original diagnostic span before advancing the cursor.")]
        fixture.model.displays[sideView.id] = sideView
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                for scene in ["completed", "child", "side"] {
                    fixture.show(scene == "side" ? "completed" : scene); settleFixtureValues(fixture)
                    for summary in fixture.model.subagentSummaries.values { try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project") }
                    for session in [fixture.parent, fixture.child, sideView] {
                        await fixture.model.refreshAccounting(session, workspaceID: "pane-project", includeMessages: false)
                    }
                    setParentCost(fixture)
                    if scene == "side" {
                        fixture.model.observeCost(["cost":.object(["spentUSD":.number(0.40),"reportedRequests":.number(1),"limitUSD":.null])], view: sideView)
                        fixture.model.selectedID = sideView.id; fixture.model.focusedSessionID = sideView.id; fixture.model.selected = sideView
                        fixture.content.pane.show(session: sideView, chat: try XCTUnwrap(fixture.model.record(sideView.id)))
                    }
                    await fixture.settle()
                    try await eventually("settled cost pill", timeout: .seconds(10)) {
                        fixture.content.layoutSubtreeIfNeeded()
                        let pills = ConversationPaneTests.views(SessionStatsPills.self, in: fixture.content)
                        let expected = scene == "child" ? "$0.15" : scene == "side" ? "$0.40" : "$1.63"
                        return pills.contains { $0.usage.label.contains(expected) && !$0.usage.isRolling
                            && (scene != "side" || $0.usage.toolTip?.contains("Counts toward Review the parser") == true) }
                    }
                    try save(try XCTUnwrap(fixture.window.contentView), to: folder.appendingPathComponent("\(scene)-\(name)-\(Int(size.width)).png"))
                }
                fixture.show("completed"); settleFixtureValues(fixture)
                await fixture.model.refreshAccounting(fixture.parent, workspaceID: "pane-project", includeMessages: false)
                setParentCost(fixture)
                let inspector = SessionInspectorModel(scope: .init(sessionID: "chat-parent", workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model, usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                    try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                })
                let controller = SessionInspectorWindowController(inspector: inspector)
                controller.window?.appearance = NSAppearance(named: appearance); controller.window?.setContentSize(size); controller.present(.overview)
                try await eventually("Inspector cost breakdown", timeout: .seconds(15)) { inspector.indexLoaded && !inspector.isReading && inspector.groups.count == 4 && inspector.inputs.gateway.requests == 5 && inspector.sideGroups.count == 1 && inspector.tokenCharts.hero.contains { $0.id == "cost" } }
                let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
                try await eventually("rendered child cost controls", timeout: .seconds(10)) {
                    content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let controls = ConversationPaneTests.views(PiKit.ButtonBase.self, in: content)
                    return controls.filter { $0.accessibilityIdentifier().hasPrefix("subagent-cost-") }.count == 4
                        && controls.contains { $0.accessibilityIdentifier() == "side-cost-cost-side" }
                        && !ConversationPaneTests.views(ShellText.self, in: content).contains { $0.text == "Reading requests…" }
                        && ConversationPaneTests.views(ShellSelectableText.self, in: content).contains { $0.text.hasPrefix("1 turn · 5 requests") }
                }
                let buttons = ConversationPaneTests.views(PiKit.ButtonBase.self, in: content).filter { $0.accessibilityIdentifier().hasPrefix("subagent-cost-") }
                XCTAssertEqual(buttons.count, 4)
                XCTAssertTrue(buttons.first?.accessibilityLabel()?.contains("counts toward this chat") == true)
                XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(buttons.first)), "Cost details are reachable by keyboard")
                try save(content, to: folder.appendingPathComponent("inspector-\(name)-\(Int(size.width)).png"))
                let breakdown = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: content).first { $0.accessibilityIdentifier() == "inspector-subagent-costs" })
                breakdown.scrollToVisible(breakdown.bounds)
                try save(content, to: folder.appendingPathComponent("breakdown-\(name)-\(Int(size.width)).png"))
                let sideCard = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: content).first { $0.accessibilityIdentifier() == "inspector-side-costs" })
                let sideButton = try XCTUnwrap(ConversationPaneTests.views(PiKit.ButtonBase.self, in: sideCard).first)
                XCTAssertTrue(sideButton.accessibilityLabel()?.contains("counts toward this chat") == true)
                XCTAssertLessThanOrEqual(sideButton.convert(sideButton.bounds, to: sideCard).maxX, sideCard.bounds.width)
                XCTAssertTrue(window.makeFirstResponder(sideButton), "Side statistics are reachable by keyboard")
                sideCard.scrollToVisible(sideCard.bounds)
                try save(content, to: folder.appendingPathComponent("sides-breakdown-\(name)-\(Int(size.width)).png"))
                let limitCard = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: content).first { $0.accessibilityIdentifier() == "inspector-cost-limit" })
                limitCard.scrollToVisible(limitCard.bounds)
                try save(content, to: folder.appendingPathComponent("cost-limit-\(name)-\(Int(size.width)).png"))
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
                    let sideDetail = try XCTUnwrap(ConversationPaneTests.views(NSView.self, in: narrow).first { $0.accessibilityIdentifier() == "inspector-side-costs" })
                    sideDetail.scrollToVisible(sideDetail.bounds)
                    try save(narrow, to: folder.appendingPathComponent("sides-breakdown-narrow-\(name).png"))
                    narrowWindow.contentView = nil; narrowWindow.close()
                }
                controller.close()
            }
        }
    }
    @MainActor private func setParentCost(_ fixture: SubagentGalleryFixture) {
        // Use production limit resolution rather than mixing a synthetic $5
        // effective limit with SessionCostReading's default $25 default.
        var reading = fixture.model.costReading(for: fixture.parent.id)
        reading.spentUSD = 1.63; reading.reportedRequests = 5; reading.unreportedRequests = 0
        fixture.parent.footer.cost = reading
        XCTAssertEqual(reading.limit, .usd(5)); XCTAssertEqual(reading.defaultLimit, reading.limit)
        XCTAssertEqual(reading.source, "Default · $5.00")
    }
    @MainActor private func settleFixtureValues(_ fixture: SubagentGalleryFixture) {
        if fixture.model.record("cost-side") == nil {
            let title = String(String(repeating: "Explore Unicode edge cases and compare parser alternatives ", count: 3).prefix(120))
            fixture.model.chats.append(ChatRecord(id:"cost-side",workspaceID:"pane-project",title:title,path:"/fixture/side_cost-side.jsonl",profileID:fixture.model.record("chat-parent")!.profileID,parentSessionID:"chat-parent"))
        }
        PiKit.Motion.reducedOverride = true
        fixture.parent.runState = .idle; fixture.parent.runStatus = "completed"
        // The shared gallery fixture has illustrative progress. Match this
        // scene's actual capture so the card, child and parent agree.
        guard var summary = fixture.model.subagentSummaries["child-0"] else { return }
        summary.description = String(String(repeating: "Review Unicode token boundaries, cancellation and diagnostic spans ", count: 2).prefix(120))
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
