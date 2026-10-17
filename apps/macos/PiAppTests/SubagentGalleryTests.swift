import AppKit
import XCTest
@testable import PiApp

extension UIScreenshotTests {
    /// All §13.5 scenes use generated metadata, in-memory credentials and
    /// native Pi views. No helper or provider is needed to render these states.
    @MainActor func testRenderSubagentGallery() async throws {
        guard let path = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else { throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT for the sub-agent gallery") }
        let folder = URL(fileURLWithPath: path).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent(UUID().uuidString))
        // Preserve this generated fixture alongside its gallery. Search closes
        // asynchronously; removing its directory first invalidates SQLite fds.
        addTeardownBlock { @MainActor in
            fixture.model.shutdown()
            try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        defer { fixture.close() }
        try await fixture.model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        for index in -1..<2 {
            let id = index < 0 ? "chat-parent" : "child-\(index)"
            var metadata: [String: WireValue] = ["attemptId":.string(UUID().uuidString), "sessionId":.string(id), "turnId":.string(index < 0 ? "turn" : "child-turn"), "purpose":.string("turn"), "api":.string("openai-responses"), "requestedModel":.string("fixture-model"), "timingVersion":.number(2), "timings":.object(["dispatch":.number(100)]), "mode":.string("off"), "outcome":.string("completed"), "wallTimestamp":.number(Date().timeIntervalSince1970)]
            if index >= 0 {
                let scope = RequestScope(sourceSessionID: id, budgetOwnerSessionID: "chat-parent", turnID: "child-turn", executionID: "child-execution", purpose: "turn", ownerGeneration: 0, delegation: fixture.model.record(id)!.delegation)
                metadata["requestScope"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(scope))
            }
            try await fixture.model.traces.begin(metadata, workspace: "pane-project"); try await fixture.model.traces.finish(metadata)
        }
        let scenes = ["running-collapsed", "running-expanded", "parallel-queued", "completed", "failed", "cancelled",
                      "interrupted", "output-limited", "truncated", "child", "relaunch-paused", "family-cost-limit",
                      "family-cost-limit-raised", "child-cost-paused",
                      "topics-folded", "topics-expanded", "flat-folded", "flat-expanded", "parent-unread-draft",
                      "search-child", "missing-parent", "recovery-error", "long-label-keyboard-reduced-motion"]
        var written: [String] = []
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance)
                fixture.window.setContentSize(size)
                for scene in scenes {
                    fixture.show(scene)
                    await fixture.settle()
                    if !scene.contains("collapsed") && !scene.contains("folded") && scene != "parallel-queued" && fixture.model.selectedID == fixture.parent.id {
                        let revealed = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
                        XCTAssertTrue(revealed); await fixture.settle()
                        XCTAssertFalse(ConversationPaneTests.views(TranscriptNativeSubagentCard.self, in: fixture.content).isEmpty)
                    }
                    if scene == "long-label-keyboard-reduced-motion" {
                        fixture.window.makeFirstResponder(fixture.content.pane)
                        XCTAssertTrue(fixture.content.pane.canBackToSubagentParent)
                    }
                    let file = "\(scene)-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(fixture.window, to: folder.appendingPathComponent(file)); written.append(file)
                    XCTAssertGreaterThan(fixture.content.pane.transcript.frame.height, 100)
                    if fixture.model.selected?.isManagedSubagent == true { XCTAssertTrue(fixture.content.pane.composer.isHidden) }
                }
                fixture.show("parallel-queued")
                for summary in fixture.model.subagentSummaries.values { try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project") }
                let inspector = SessionInspectorModel(scope: .init(sessionID: "chat-parent", workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model, usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                    try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                })
                let controller = SessionInspectorWindowController(inspector: inspector)
                controller.window?.appearance = NSAppearance(named: appearance)
                controller.window?.setContentSize(size); controller.present(.overview)
                for _ in 0..<100 where !inspector.indexLoaded || inspector.usage.snapshot?.gateway.requests != 3 { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(inspector.groups.count, 4)
                XCTAssertEqual(inspector.usage.snapshot?.gateway.requests, 3)
                XCTAssertEqual(inspector.inputs.gateway.requests, 3)
                try await Task.sleep(for: .milliseconds(150))
                let file = "family-inspector-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                try capture(try XCTUnwrap(controller.window), to: folder.appendingPathComponent(file)); written.append(file)
                inspector.setFamilyFilter(.child("child-0"))
                for _ in 0..<100 where inspector.usage.loading || inspector.usage.snapshot?.gateway.requests != 1 { try await Task.sleep(for: .milliseconds(20)) }
                try await Task.sleep(for: .milliseconds(250))
                let childFile = "family-inspector-child-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                try capture(try XCTUnwrap(controller.window), to: folder.appendingPathComponent(childFile)); written.append(childFile)
                XCTAssertEqual(inspector.index.requests.count, 1)
                XCTAssertEqual(inspector.inputs.gateway.requests, 1)
                XCTAssertTrue(inspector.index.requests.allSatisfy { $0.sessionID == "child-0" })
                controller.close(); fixture.window.makeKeyAndOrderFront(nil)
            }
        }
        XCTAssertEqual(written.count, 100)
        try (written.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
}

/// Reusable native content for the gallery and streaming measurements. Fixed
/// fixture geometry avoids reading or changing the real window preferences.
@MainActor final class SubagentGalleryContent: NSView {
    let sidebar: WorkspaceSidebarView, pane: ConversationPaneView
    init(model: WorkspaceModel) {
        sidebar = WorkspaceSidebarView(model: model, width: 264); pane = ConversationPaneView(model: model)
        super.init(frame: .zero); wantsLayer = true; addSubview(sidebar); addSubview(pane)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); layer?.backgroundColor = NSColor.piSurface.cgColor
        sidebar.frame = CGRect(x: 0, y: 0, width: 264, height: bounds.height)
        pane.frame = CGRect(x: 264, y: 0, width: max(1, bounds.width - 264), height: bounds.height)
    }
}

@MainActor final class SubagentGalleryFixture {
    let root: URL, model: WorkspaceModel, window: NSWindow, content: SubagentGalleryContent
    let parent: SessionDisplay, child: SessionDisplay
    let records: [ChatRecord]
    let previousMotion = PiKit.Motion.reducedOverride
    init(root: URL) throws {
        self.root = root
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent"])
        model = bench.model
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.chats[0].title = "Review the parser"
        for index in 0..<4 {
            var link = SubagentTranscriptTests.link; link.childSessionID = "child-\(index)"; link.delegationID = "delegation-\(index)"; link.call.toolCallID = "call-\(index)"
            model.chats.append(ChatRecord(id: link.childSessionID, workspaceID: "pane-project", title: ["Check token boundaries", "Audit cancellation", "Review error recovery", "Compare fixture coverage"][index], profileID: bench.profile.id, parentSessionID: "chat-parent", delegation: link, subagentNumber: index + 1))
        }
        records = model.chats
        parent = SessionDisplay(id: "chat-parent"); child = SessionDisplay(id: "child-0")
        for session in [parent, child] {
            session.historyState = .ready; session.draftReady = true; session.runStateKnown = true
            session.subagentNumbers = Dictionary(model.chats.compactMap { chat in chat.subagentNumber.map { (chat.id, $0) } }, uniquingKeysWith: { first, _ in first })
            model.displays[session.id] = session
        }
        content = SubagentGalleryContent(model: model)
        window = ConversationWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "Sub-agent gallery — generated fixture"; window.isReleasedWhenClosed = false
        window.contentView = content; window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        show("running-collapsed")
    }
    func show(_ scene: String) {
        model.chats = records; model.subagentSummaries = [:]; model.unreadStates = [:]; model.draftChatIDs = []
        model.topics = [TopicRecord(id: "review-topic", workspaceID: "pane-project", title: "Release review", revision: 1)]
        for index in model.chats.indices { model.chats[index].topicID = "review-topic" }
        model.projectSidebarStates = ["pane-project":ProjectSidebarState(id: "pane-project", flatTopics: scene.hasPrefix("flat"), expandedSubagents: scene.contains("expanded") || scene == "parallel-queued" || scene == "parent-unread-draft" ? [parent.id] : nil)]
        parent.runState = .running; parent.runStatus = "waiting_tool"; parent.failureCode = nil; parent.failureMessage = nil
        parent.queuePaused = false; parent.continuable = true; parent.notice = ""; parent.draft = ""; parent.costPaused = false; parent.resuming = false
        parent.applyCostReading(SessionCostReading(limit: .usd(1), override: .usd(1), defaultLimit: .usd(25), spentUSD: 0.18, reportedRequests: 5, unreportedRequests: 1))
        child.isManagedSubagent = true; child.runState = .idle; child.notice = ""; child.subagentStatus = .completed; child.costPaused = false
        // 0.1.129: the shared limit pauses the family; Resume after a raise.
        let costPaused = ["family-cost-limit", "family-cost-limit-raised", "child-cost-paused"].contains(scene)
        var status: SubagentStatus = .running
        switch scene {
        case "completed", "truncated", "child", "missing-parent", "long-label-keyboard-reduced-motion": status = .completed
        case "failed", "recovery-error": status = .failed
        case "cancelled": status = .cancelled
        case "interrupted", "relaunch-paused": status = .interrupted
        case "family-cost-limit", "family-cost-limit-raised", "child-cost-paused": status = .queued
        case "output-limited": status = .outputLimited
        default: break
        }
        let long = scene == "long-label-keyboard-reduced-motion"
        if long { model.chats[1].title = String(String(repeating: "Review Unicode token boundaries and diagnostic spans ", count: 3).prefix(120)) }
        let task = long ? String(repeating: "Review Unicode token boundaries, cancellation and diagnostic spans. ", count: 18) : "Review the parser’s token boundaries and report concrete issues with file and line references."
        var tools: [ToolView] = []
        for index in 0..<4 {
            let record = model.chats[index + 1], link = record.delegation!
            let state = scene == "parallel-queued" && index > 1 ? SubagentStatus.queued : status
            var summary = SubagentSummary(link: link, description: record.title, model: "fixture-model", status: state, revision: 1, tools: ["read", "grep", "find"])
            if costPaused { summary.costPaused = true; summary.turn = 1 }
            summary.progress = SubagentProgress(phase: "model", elapsedMs: 8400, requests: 2, tools: 3, preview: "Checked the tokenizer; examining escape sequences.", usd: 0.04, reported: 1, unreported: 1, inputTokens: 1800, outputTokens: 420)
            model.subagentSummaries[record.id] = summary
            var tool = SubagentTranscriptTests.tool; tool.id = link.call.toolCallID; tool.state = state.terminal ? "completed" : "running"
            tool.input = WireValue.object(["task":.string(task), "description":.string(record.title)]).pretty
            tool.output = WireValue.object(["status":.string(state.rawValue), "text":.string(state.terminal ? "Token ranges are stable. One recovery path loses the original diagnostic span; preserve it before advancing the cursor." : ""), "truncated":.bool(scene == "truncated"), "error":state == .failed ? .object(["message":.string("The child journal could not be read. The saved task was not replayed.")]) : .null]).pretty
            tool.subagent = summary; tools.append(tool)
        }
        let expanded = !scene.contains("collapsed") && !scene.contains("folded") && scene != "parallel-queued"
        for tool in tools { parent.disclosure.setOpen(expanded, .tool(ToolOccurrence.key("reply", tool.id))) }
        parent.disclosure.setOpen(true, .work("reply"))
        parent.messages = [TranscriptMessage(id: "turn", role: "user", text: "Check the parser before the release."),
                           TranscriptMessage(id: "reply", role: "assistant", text: "I’m delegating focused checks, then I’ll combine the findings.", tools: scene == "parallel-queued" ? tools : [tools[0]], turn: "turn")]
        let parts: [(kind: String, text: String, callID: String?, name: String?)] = [("text", parent.messages[1].text, nil, nil)] + (parent.messages[1].tools ?? []).map { ("toolArguments", $0.input, $0.id, $0.name) }
        parent.messages[1].responseTimeline = .canonical(parts, sourceID: "reply")
        child.messages = [TranscriptMessage(id: "task", role: "user", text: task), TranscriptMessage(id: "answer", role: "assistant", text: "The tokenizer handles UTF-8 boundaries correctly.\n\nOne error-recovery path advances the cursor before preserving its original diagnostic span. Save that span before advancing, and add a malformed-escape fixture.")]
        if scene == "relaunch-paused" { parent.runState = .interrupted; parent.queuePaused = true }
        if costPaused {
            parent.runState = .paused; parent.runStatus = "cancelled"; parent.queuePaused = true; parent.costPaused = true
            let raised = scene == "family-cost-limit-raised"
            parent.applyCostReading(SessionCostReading(limit: .usd(raised ? 5 : 1), override: .usd(raised ? 5 : 1), defaultLimit: .usd(25), spentUSD: 1.03, reportedRequests: 9, unreportedRequests: 1))
            if scene == "child-cost-paused" {
                child.runState = .paused; child.costPaused = true; child.subagentStatus = .queued
                child.applyCostReading(SessionCostReading(limit: .usd(1), spentUSD: 0.15, reportedRequests: 2))
                var shared = child.footer.cost; shared.budgetOwnerID = parent.id; shared.budgetSpentUSD = 1.03; child.applyCostReading(shared)
            }
        }
        if scene == "parent-unread-draft" {
            model.readStatesRestored = true; parent.draft = "Follow up on the diagnostic span."; model.draftChatIDs = [parent.id]
            model.unreadStates[parent.id] = SessionReadState(id: parent.id, observedAssistantCount: 1, latestAssistantID: "final", unreadOutputs: 1)
        }
        let showChild = ["child", "child-cost-paused", "missing-parent", "recovery-error", "long-label-keyboard-reduced-motion"].contains(scene)
        if scene == "missing-parent" { model.chats.removeAll { $0.id == parent.id }; child.notice = "The parent chat is unavailable. This saved sub-agent is view-only." }
        if scene == "recovery-error" { child.notice = "The saved origin does not match the parent’s delegation. This transcript is view-only." }
        let session = showChild ? child : parent
        model.selectedID = session.id; model.focusedSessionID = session.id; model.selected = session
        content.pane.show(session: session, chat: model.record(session.id)!)
        PiKit.Motion.reducedOverride = long
        content.sidebar.setFilter(scene == "search-child" ? "boundaries" : "")
        content.needsLayout = true
    }
    func settle() async {
        for _ in 0..<18 { content.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
    }
    func close() { PiKit.Motion.reducedOverride = previousMotion; model.shutdown(); window.contentView = nil; window.close() }
}
