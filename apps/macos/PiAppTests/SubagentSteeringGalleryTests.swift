import AppKit
import XCTest
@testable import PiApp

extension UIScreenshotTests {
    @MainActor func testRenderSubagentSteeringGallery() async throws {
        guard let path = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else { throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT for the steering gallery") }
        let folder = URL(fileURLWithPath: path).appendingPathComponent("steering")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent(UUID().uuidString))
        addTeardownBlock { @MainActor in
            fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        let previous = TranscriptDisplay.mode; TranscriptDisplay.use(.normal)
        defer { fixture.close(); TranscriptDisplay.use(previous) }
        let captures = try await fixture.prepareSteeringInspector()
        let scenes = ["background-folded", "background-expanded", "final-wait", "pending-result", "delivered-result", "message-delivered-card", "pending-question", "pending-blocker",
                      "delivered-question", "delivered-blocker", "parent-steering", "child-report", "follow-up-two", "follow-up-three", "follow-up-card",
                      "user-stopped-hold", "coordination-paused", "family-cost-limit", "resume-undelivered", "long-text-keyboard"]
        var written: [String] = []
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                for scene in scenes {
                    fixture.showSteering(scene); await fixture.settle()
                    if ["background-expanded", "user-stopped-hold", "pending-result", "delivered-result", "message-delivered-card"].contains(scene) {
                        let revealed = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
                        XCTAssertTrue(revealed); await fixture.settle()
                    }
                    if ["pending-question", "pending-blocker", "child-report", "follow-up-card"].contains(scene) {
                        let child = scene != "follow-up-card"
                        let revealed = await fixture.model.revealInTranscript(sessionID: child ? fixture.child.id : fixture.parent.id,
                            messageID: child ? "ask" : "follow-up", toolCallID: child ? "report-1" : "send-3")
                        XCTAssertTrue(revealed); await fixture.settle()
                        XCTAssertFalse(ConversationPaneTests.views(TranscriptNativeSubagentCard.self, in: fixture.content).isEmpty)
                    }
                    if ["final-wait", "coordination-paused", "family-cost-limit", "resume-undelivered"].contains(scene) {
                        let message = try XCTUnwrap(fixture.parent.presentedMessages.last?.id)
                        let revealed = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: message)
                        XCTAssertTrue(revealed); await fixture.settle()
                    }
                    if scene == "long-text-keyboard" {
                        fixture.window.makeFirstResponder(fixture.content.pane)
                        XCTAssertTrue(fixture.content.pane.canBackToSubagentParent)
                    }
                    if fixture.model.selected?.isManagedSubagent == true { XCTAssertTrue(fixture.content.pane.composer.isHidden) }
                    if ["delivered-question", "delivered-blocker", "parent-steering", "follow-up-two", "follow-up-three", "long-text-keyboard"].contains(scene) {
                        let rows = ConversationPaneTests.views(TranscriptNativeAgentRow.self, in: fixture.content)
                        XCTAssertFalse(rows.isEmpty, scene)
                        XCTAssertTrue(rows.allSatisfy { $0.accessibilityLabel()?.contains("turn") == true })
                    }
                    let file = "\(scene)-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(fixture.window, to: folder.appendingPathComponent(file)); written.append(file)
                }
                fixture.showSteering("follow-up-three")
                fixture.model.chats[0].path = captures.path
                for summary in fixture.model.subagentSummaries.values { try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project") }
                let inspector = SessionInspectorModel(scope: .init(sessionID: fixture.parent.id, workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model,
                    usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                        try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                    })
                let controller = SessionInspectorWindowController(inspector: inspector)
                controller.window?.appearance = NSAppearance(named: appearance); controller.window?.setContentSize(size)
                controller.present(.subagent("delegation-0"))
                for _ in 0..<200 where !inspector.indexLoaded || inspector.page != .subagent("delegation-0") { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(inspector.groups.count, 4)
                XCTAssertEqual(Set(inspector.index.requests.compactMap(\.childTurn)), [1, 2, 3])
                for scene in ["inspector-turns", "inspector-capture-missing", "inspector-outside-window"] {
                    if scene != "inspector-turns" {
                        if scene == "inspector-outside-window" { inspector.setFamilyFilter(.child("child-1")) }
                        inspector.focus(.request(scene == "inspector-capture-missing" ? captures.child : captures.old))
                        let wanted = scene == "inspector-capture-missing" ? captures.child : captures.old
                        for _ in 0..<200 where inspector.page != .request(wanted) || !inspector.request.metadataLoaded { try await Task.sleep(for: .milliseconds(20)) }
                        XCTAssertEqual(inspector.page, .request(wanted))
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    let file = "\(scene)-\(name)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(try XCTUnwrap(controller.window), to: folder.appendingPathComponent(file)); written.append(file)
                }
                controller.close(); fixture.window.makeKeyAndOrderFront(nil)
            }
        }
        XCTAssertEqual(written.count, 92)
        try (written.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
}

extension SubagentGalleryFixture {
    func agentRow(_ id: String, author: String, kind: String, turn: Int, text: String, replyTo: String? = nil) -> TranscriptMessage {
        let event: WireValue = .object(["event_id":.string(id),"author":.string(author),"child_id":.string(child.id),"turn":.number(Double(turn)),
            "kind":.string(kind),"text":.string(text),"task":.string("Check token boundaries"),"reply_to":replyTo.map(WireValue.string) ?? .null])
        var row = TranscriptMessage(id: id, role: "user", text: text, kind: "agent_message")
        row.nativeAgentDelivery = .object(["version":.number(1),"author":.string(author),"childId":.string(child.id),"turn":.number(Double(turn)),
            "task":.string("Check token boundaries"),"eventIds":.array([.string(id)]),"events":.array([event])])
        return row
    }
    func steeringTool(_ name: String, turn: Int, route: String, message: String, id: String, source: String, kind: String? = nil) -> ToolView {
        var tool = SubagentTranscriptTests.tool
        tool.name = name; tool.id = id
        tool.input = WireValue.object([name == "subagent_start" ? "task" : "message":.string(message),"kind":kind.map(WireValue.string) ?? .null]).pretty
        tool.output = WireValue.object(["version":.number(3),"accepted":.bool(true),"child_id":.string(child.id),"turn":.number(Double(turn)),"route":.string(route),"message_id":.string(id)]).pretty
        tool.nativeSubagent = .object(["version":.number(2),"sessionId":.string(child.id),"delegationId":.string("delegation-0"),
            "budgetOwnerSessionId":.string(parent.id),"parentAssistantMessageId":.string(source),"toolCallId":.string(id),"turn":.number(Double(turn)),"route":.string(route)])
        if name == "subagent_report" { tool.nativeSubagent = nil }
        tool.subagent = name == "subagent_report" ? nil : model.subagentSummaries[child.id]
        return tool
    }
    func showSteering(_ scene: String) {
        for session in [parent, child] {
            session.reveal = nil; session.revealRead = nil; session.revealFailure = nil; session.scrollAnchor = nil
        }
        show(scene == "background-folded" ? "running-collapsed" : "running-expanded")
        parent.familyWaiting = false; parent.agentInboxPending = 0; parent.heldAgentChildren = []; parent.agentCoordination = [:]
        parent.childSummaries = [:]; parent.failureMessage = nil; parent.draft = ""
        child.familyWaiting = false; child.agentInboxPending = 0; child.heldAgentChildren = []; child.agentCoordination = [:]
        child.subagentTurn = 1; child.subagentStatus = .running; child.runState = .running; child.queuePaused = false
        child.footer.cost = SessionCostReading(limit: .usd(1), spentUSD: 0.04, reportedRequests: 2, unreportedRequests: 0)
        child.footer.gateway.requests = 2; child.footer.gateway.costUSD = 0.04; child.footer.gateway.costSamples = 1
        for id in model.subagentSummaries.keys {
            model.subagentSummaries[id]?.turn = 1; model.subagentSummaries[id]?.deliveryState = "pending"
            model.subagentSummaries[id]?.pendingMessages = 0
        }
        let turn = ["follow-up-three", "follow-up-card"].contains(scene) ? 3 : scene == "follow-up-two" ? 2 : 1
        model.subagentSummaries[child.id]?.turn = turn; child.subagentTurn = turn
        let task = "Review token boundaries and preserve the diagnostic span before recovery advances the parser."
        let start = steeringTool("subagent_start", turn: 1, route: "start", message: task, id: "call-0", source: "reply")
        parent.messages = [.init(id: "turn", role: "user", text: "Check the parser before the release."),
            .init(id: "reply", role: "assistant", text: "I’ll check the release notes while the parser review runs.", tools: [start], turn: "turn")]
        child.messages = [agentRow("input-1", author: "parent", kind: "task", turn: 1, text: task),
            .init(id: "child-work", role: "assistant", text: "UTF-8 boundaries look correct. I’m checking recovery of malformed escapes.")]
        var showChild = false
        switch scene {
        case "final-wait":
            parent.familyWaiting = true
            parent.messages.append(.init(id: "answer", role: "assistant", text: "The release notes are ready. I’m waiting for the parser findings before the final summary."))
        case "pending-result", "delivered-result":
            model.subagentSummaries[child.id]?.status = .completed
            child.subagentStatus = .completed; child.runState = .idle
            model.subagentSummaries[child.id]?.deliveryState = scene == "pending-result" ? "pending" : "delivered"
            if scene == "delivered-result" { parent.messages.append(agentRow("result-1", author: "subagent", kind: "result", turn: 1, text: "Preserve the diagnostic span before advancing the recovery cursor. The focused regression now passes.")) }
        case "message-delivered-card":
            let send = steeringTool("subagent_send", turn: 1, route: "steer", message: "Preserve the original span and add a malformed-escape fixture.", id: "call-0", source: "reply")
            parent.messages[1].tools = [send]
            parent.agentCoordination["call-0"] = AgentCoordinationEntry(id: "call-0", childID: child.id, turn: 1, kind: "steer", author: "parent",
                sourceSessionID: parent.id, sourceMessageID: "reply", sourceToolCallID: "call-0", recipientID: child.id, recipientMessageID: "steer-1", disposition: "delivered")
        case "pending-question", "pending-blocker", "child-report":
            showChild = true
            let kind = scene == "pending-blocker" ? "blocker" : scene == "child-report" ? "note" : "question"
            let text = kind == "blocker" ? "The legacy fixture is missing its expected diagnostic span. Please confirm the intended location." : kind == "note" ? "The recovery path advances one token too early. I have a minimal reproduction." : "Should the legacy parser retain its original diagnostic span?"
            let report = steeringTool("subagent_report", turn: 1, route: "report", message: text, id: "report-1", source: "ask", kind: kind)
            child.messages.append(.init(id: "ask", role: "assistant", text: "I’m sending this to the parent while I continue checking the other paths.", tools: [report]))
            child.disclosure.setOpen(true, .tool(ToolOccurrence.key("ask", "report-1"))); child.disclosure.setOpen(true, .work("ask"))
            model.subagentSummaries[child.id]?.pendingMessages = 1; parent.agentInboxPending = 1
        case "delivered-question", "delivered-blocker":
            let kind = scene == "delivered-question" ? "question" : "blocker"
            parent.messages.append(agentRow("report-1", author: "subagent", kind: kind, turn: 1,
                text: kind == "question" ? "Should the legacy parser retain its original diagnostic span?" : "The legacy fixture has no expected diagnostic span. I need the intended location before changing it."))
        case "parent-steering", "long-text-keyboard":
            showChild = true
            let text = scene == "long-text-keyboard" ? String(repeating: "Preserve the original span, including Unicode boundaries and malformed escapes. Keep the existing recovery behavior and add a focused fixture.\n\n", count: 12) : "Yes. Preserve the original diagnostic span, then add a fixture for a malformed escape."
            child.messages.append(agentRow("steer-1", author: "parent", kind: "steer", turn: 1, text: text, replyTo: "report-1"))
            PiKit.Motion.reducedOverride = scene == "long-text-keyboard"
        case "follow-up-two", "follow-up-three":
            showChild = true
            child.messages.append(.init(id: "answer-1", role: "assistant", text: "Turn 1: the error-recovery path needs to preserve the original span."))
            child.messages.append(agentRow("input-2", author: "parent", kind: "follow_up", turn: 2, text: "Add a focused regression for the malformed escape path."))
            child.messages.append(.init(id: "answer-2", role: "assistant", text: "Turn 2: the regression passes with the original span retained."))
            if turn == 3 { child.messages.append(agentRow("input-3", author: "parent", kind: "follow_up", turn: 3, text: "Check that the same regression also covers a multi-byte character before the escape.")) }
        case "follow-up-card":
            parent.messages.append(agentRow("result-1", author: "subagent", kind: "result", turn: 1, text: "The original diagnostic span must be preserved."))
            let send = steeringTool("subagent_send", turn: 3, route: "follow_up", message: "Check the new regression with a multi-byte character before the escape.", id: "send-3", source: "follow-up")
            parent.messages.append(.init(id: "follow-up", role: "assistant", text: "The same sub-agent is checking the follow-up with its previous context.", tools: [send]))
            parent.disclosure.setOpen(true, .work("follow-up")); parent.disclosure.setOpen(true, .tool(ToolOccurrence.key("follow-up", "send-3")))
        case "user-stopped-hold":
            model.subagentSummaries[child.id]?.status = .cancelled
            parent.heldAgentChildren = [child.id]; child.heldAgentChildren = [child.id]; child.subagentStatus = .cancelled; child.runState = .idle
        case "coordination-paused", "family-cost-limit", "resume-undelivered":
            parent.runState = .paused; parent.queuePaused = true; parent.agentInboxPending = 2
            for id in model.subagentSummaries.keys { model.subagentSummaries[id]?.status = .interrupted }
            child.subagentStatus = .interrupted; child.runState = .interrupted; child.queuePaused = true
            model.subagentSummaries[child.id]?.pendingMessages = 2
            model.subagentSummaries[child.id]?.deliveryState = "held"
            parent.messages.append(.init(id: "answer", role: "assistant", text: "The saved findings are pending. Resume the parent to continue from the retained conversation."))
            if scene == "coordination-paused" {
                parent.failureCode = "coordination_limit"; parent.failureMessage = "The family communication allowance was reached. Accepted messages remain saved for explicit Resume."
            } else if scene == "family-cost-limit" {
                parent.failureCode = SessionDisplay.costLimitCode; parent.failureMessage = "The parent chat’s $1.00 cost limit was reached. All sub-agents stopped."
                parent.footer.cost = SessionCostReading(limit: .usd(1), override: .usd(1), defaultLimit: .usd(25), spentUSD: 1.03, reportedRequests: 9, unreportedRequests: 0)
            }
        default: break
        }
        parent.childSummaries = model.subagentSummaries
        for row in child.messages where row.tools != nil { child.disclosure.setOpen(true, .work(row.id)) }
        let session = showChild ? child : parent
        model.selectedID = session.id; model.focusedSessionID = session.id; model.selected = session
        content.pane.show(session: session, chat: model.record(session.id)!)
        content.needsLayout = true
    }

    func prepareSteeringInspector() async throws -> (child: String, old: String, path: String) {
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        let path = root.appendingPathComponent("parent-steering.jsonl")
        var bytes = Data()
        func append(_ value: WireValue) throws { bytes.append(try JSONEncoder().encode(value)); bytes.append(10) }
        func record(_ name: String, _ value: [String:WireValue]) throws { try append(.object(["type":.string("custom"),"customType":.string(name),"data":.object(value)])) }
        try append(.object(["type":.string("session"),"version":.number(3),"id":.string(parent.id)]))
        let link = model.record(child.id)!.delegation!
        let origin = SubagentHeader(link: link, description: "Check token boundaries", model: .init(model: "fixture-model"), readOnly: true)
        let plan: WireValue = .object(["origin":try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(origin)),"task":.string("Check token boundaries")])
        var result = (child: "", old: "", path: path.path)
        for turn in 1...3 {
            let key: WireValue = .object(["parentSessionID":.string(parent.id),"assistantMessageID":.string("source-\(turn)"),"toolCallID":.string("send-\(turn)")])
            try record("pi-app.agent-operation.v1", ["key":key,"plan":turn == 1 ? plan : .null,
                "turn":.object(["childID":.string(child.id),"turn":.number(Double(turn)),"inputID":.string("input-\(turn)")])])
            for isChild in [false, true] {
                let attempt = UUID().uuidString, session = isChild ? child.id : parent.id
                let turnID = (isChild ? "child-turn-" : "parent-turn-") + String(turn)
                var scope = RequestScope(sourceSessionID: session, budgetOwnerSessionID: parent.id, turnID: turnID, executionID: "execution-\(turn)", purpose: "turn", ownerGeneration: 0, delegation: isChild ? link : nil)
                scope.childTurn = isChild ? turn : nil; scope.parentExecutionID = isChild ? "parent-run" : nil; scope.agentDeliveryIDs = isChild ? ["input-\(turn)"] : []
                let metadata: [String:WireValue] = ["attemptId":.string(attempt),"sessionId":.string(session),"turnId":.string(turnID),"purpose":.string("turn"),
                    "api":.string("openai-responses"),"requestedModel":.string("fixture-model"),"mode":.string("off"),"outcome":.string("completed"),
                    "wallTimestamp":.number(Date().timeIntervalSince1970 - (!isChild && turn == 1 ? 2000 : 20) + Double(turn)),"timingVersion":.number(2),"timings":.object(["dispatch":.number(100)]),
                    "requestScope":try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(scope)),
                    "messageIds":.array(isChild ? [.string("input-\(turn)")] : []),"outputMessageIds":.array([.string(isChild ? "answer-\(turn)" : "source-\(turn)")])]
                try await model.traces.begin(metadata, workspace: "pane-project"); try await model.traces.finish(metadata)
                if isChild && turn == 3 { result.child = attempt }
                if !isChild && turn == 1 { result.old = attempt }
            }
        }
        try bytes.write(to: path)
        // Exercise the existing 5,000-row navigator window, not a simulated
        // missing row. All filler belongs only to this generated archive.
        let archiveRoot = await model.traces.root
        let db = try CaptureDatabase(url: archiveRoot.appendingPathComponent("requests.sqlite"))
        try db.transaction {
            for index in 0..<5000 {
                try db.execute("INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,outcome,wall,updated,metadata) VALUES(?,'chat-parent','pane-project','older-turn','turn','openai-responses','fixture-model','completed',?,?,?)",
                    [.text(UUID().uuidString), .real(Date().timeIntervalSince1970 - 1000 + Double(index) / 10), .real(Date().timeIntervalSince1970), .blob(Data("{}".utf8))])
            }
        }
        return result
    }
}
