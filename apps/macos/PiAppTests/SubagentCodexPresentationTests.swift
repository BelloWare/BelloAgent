import AppKit
import XCTest
@testable import PiApp

final class SubagentCodexPresentationTests: XCTestCase {
    static func tool(_ name: String, target: String = "audit", output: String = "") -> ToolView {
        var tool = ToolView(id: "call", name: name, state: "completed",
            input: WireValue.object(["task_name": .string(target), "target": .string(target),
                "message": .string("Audit the journal."), "fork_turns": .string("all")]).pretty,
            output: output, truncated: false)
        tool.codexAgents = true
        if ["spawn_agent", "followup_task"].contains(name) {
            var fields = SubagentTranscriptTests.metadata.object!
            fields["version"] = .number(2); fields["turn"] = .number(name == "spawn_agent" ? 1 : 2)
            fields["route"] = .string(name == "spawn_agent" ? "start" : "follow_up")
            fields["taskName"] = .string("/root/" + target); fields["forkTurns"] = .string("all")
            tool.nativeSubagent = .object(fields)
        }
        return tool
    }
    static func delivery(_ type: String, sender: String, recipient: String, text: String = "**The writer lock is held.**") -> TranscriptMessage {
        var fields: [String: WireValue] = ["event_id": .string("event"), "family_sequence": .number(2),
            "type": .string(type), "sender": .string(sender), "recipient": .string(recipient),
            "turn": .number(1), "text": .string(text)]
        if sender != "/root" { fields["sender_child_id"] = .string((SubagentLabel.task(sender) ?? sender) + "-child") }
        if recipient != "/root" { fields["recipient_child_id"] = .string((SubagentLabel.task(recipient) ?? recipient) + "-child") }
        let event = WireValue.object(fields)
        var row = TranscriptMessage(id: "delivery", role: "user", text: "Untrusted frame text", kind: "agent_message",
            nativeAgentDelivery: .object(["version": .number(2), "eventIds": .array([.string("event")]), "events": .array([event])]))
        row.codexAgents = true
        return row
    }
    func testNamesUseCanonicalTaskNameAndKeepLegacyFallback() {
        var summary = SubagentSteeringPresentationTests.tool.subagent!
        summary.taskName = "/root/audit"
        XCTAssertEqual(InspectorSubagentGroup(summary: summary).title, "audit")
        var tool = Self.tool("spawn_agent"); tool.subagent = summary
        XCTAssertEqual(SubagentToolView(tool).name, "audit")
        XCTAssertEqual(SubagentToolView(tool).description, "Check the parser")
        summary.taskName = nil
        XCTAssertEqual(InspectorSubagentGroup(summary: summary, number: 2).title, "Sub-agent 2 · Check the parser")
    }
    func testEveryCodexCardHeadingAndWakeState() {
        let cases = [("spawn_agent", "Started audit"), ("send_message", "To audit"),
            ("followup_task", "New task for audit · turn 2"), ("wait_agent", "Waiting for agents"),
            ("interrupt_agent", "Interrupted audit"), ("list_agents", "Agents")]
        for (name, title) in cases {
            let tool = Self.tool(name)
            XCTAssertEqual(TranscriptToolRow.model(of: tool).title, title, name)
            if case .subagent = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) {} else { XCTFail(name) }
        }
        XCTAssertEqual(SubagentToolView(Self.tool("spawn_agent")).label, "with this chat's context")
        var fresh = Self.tool("spawn_agent"); fresh.nativeSubagent = nil
        fresh.input = "{\"task_name\":\"audit\",\"message\":\"Check\",\"fork_turns\":\"none\"}"
        XCTAssertEqual(SubagentToolView(fresh).label, "fresh")
        for wake in ["Wait completed: updates from /root/audit, /root/tests.", "Wait timed out.",
                     "Wait interrupted by new input.", "Wait interrupted by Stop.", "Wait interrupted by cost limit."] {
            XCTAssertEqual(SubagentToolView(Self.tool("wait_agent", output: wake)).label, wake)
        }
        var rejected = Self.tool("spawn_agent", output: "{\"version\":4,\"accepted\":false,\"error\":{\"code\":\"agent_name_taken\",\"message\":\"Name is taken.\"}}")
        rejected.state = "failed"
        XCTAssertEqual(SubagentToolView(rejected).label, "Not accepted")
        XCTAssertFalse(TranscriptToolRow.model(of: rejected).title.hasPrefix("Started"))
    }
    @MainActor func testCapabilityGatesCodexCardsButKeepsV3History() {
        let view = SessionDisplay(id: "parent"); view.historyState = .ready
        var raw = Self.tool("spawn_agent"); raw.codexAgents = false
        view.messages = [.init(id: "reply", role: "assistant", text: "", tools: [raw])]
        func card() -> TranscriptToolRow.Card {
            let tool = view.presentedMessages[0].tools![0]
            return TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false)
        }
        if case .subagent = card() { XCTFail("Unadvertised capability") }
        view.supportsCodexAgents = true
        if case .subagent = card() {} else { XCTFail("Advertised v4 capability") }
        view.supportsCodexAgents = false
        view.messages[0].tools = [SubagentSteeringPresentationTests.tool]
        if case .subagent = card() {} else { XCTFail("v3 history") }
    }
    func testUtilityCardsKeepTheirOwnStateAndShowCompactPagedLists() {
        var send = Self.tool("send_message", output: "Queued for /root/audit.")
        send.subagent = SubagentSteeringPresentationTests.tool.subagent
        send.subagent?.status = .running
        send.agentDeliveryState = "delivered"
        XCTAssertEqual(SubagentToolView(send).preview, "Audit the journal.")
        XCTAssertEqual(SubagentToolView(send).label, "Delivered")
        XCTAssertNotEqual(TranscriptToolRow.model(of: send).state, .running, "Sending must not spin for the target's entire turn")
        let list = Self.tool("list_agents", output: "{\"agents\":[{\"agent_name\":\"/root\",\"agent_status\":\"running\"},{\"agent_name\":\"/root/audit\",\"agent_status\":\"idle\",\"turn\":2}],\"next_cursor\":\"next\"}")
        XCTAssertEqual(SubagentToolView(list).result, "- main · Running\n- audit · Idle · turn 2\n\nMore agents available")
        XCTAssertTrue(SubagentToolView(list).task.isEmpty)
        XCTAssertEqual(SubagentToolView(Self.tool("wait_agent", output: "Wait timed out.")).result, "Wait timed out.")
        XCTAssertEqual(SubagentToolView(Self.tool("interrupt_agent", output: "{\"previous_status\":\"running\"}")).result, "Previous status: running")
        for name in ["spawn_agent", "interrupt_agent"] {
            var pending = Self.tool(name); pending.state = "running"
            XCTAssertTrue(SubagentToolView(pending).heading.hasPrefix(name == "spawn_agent" ? "Starting" : "Interrupting"))
            pending.state = "unknown"; pending.nativeSubagent = nil
            XCTAssertEqual(SubagentToolView(pending).label, "Outcome unknown")
            XCTAssertFalse(SubagentToolView(pending).heading.hasPrefix(name == "spawn_agent" ? "Started" : "Interrupted"))
        }
    }
    @MainActor func testSiblingAndFinalAnswerUseTypedPayloadAndBoundedMarkdown() throws {
        let sibling = Self.delivery("MESSAGE", sender: "/root/audit", recipient: "/root/tests")
        let event = try XCTUnwrap(AgentMessagePresentation(sibling).events.first)
        XCTAssertEqual(event.title, "audit → tests · Message")
        XCTAssertEqual(event.text, "**The writer lock is held.**")
        let text = String(repeating: "## Finding\n\nRecovery is **sound**.\n\n", count: 400) + "Unique final conclusion"
        let final = Self.delivery("FINAL_ANSWER", sender: "/root/audit", recipient: "/root", text: text)
        XCTAssertEqual(AgentMessagePresentation(final).events.first?.title, "audit · Final answer")
        XCTAssertEqual(AgentMessagePresentation(final).events.first?.text, text)
        let item = TranscriptItem.message(final)
        let row = TranscriptNativeAgentRow(inputs: .init(item: item, fresh: false, actions: .init(), width: 500, environment: .init()))
        XCTAssertFalse(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: row).isEmpty)
        let task = Self.delivery("NEW_TASK", sender: "/root", recipient: "/root/audit")
        XCTAssertEqual(AgentMessagePresentation(task).events.first?.title, "main · New task")
        var followup = task
        var metadata = followup.nativeAgentDelivery!.object!, eventFields = metadata["events"]!.array![0].object!
        eventFields["turn"] = .number(2); metadata["events"] = .array([.object(eventFields)])
        followup.nativeAgentDelivery = .object(metadata)
        XCTAssertEqual(AgentMessagePresentation(followup).events.first?.title, "main → audit · New task")
        var legacy = TranscriptMessage(id: "v1", role: "user", text: "", nativeAgentDelivery: SubagentSteeringPresentationTests.delivery)
        legacy.codexAgents = false
        XCTAssertEqual(AgentMessagePresentation(legacy).events.first?.label, "Question")
        var gated = sibling; gated.codexAgents = false
        XCTAssertTrue(AgentMessagePresentation(gated).events.isEmpty)
    }
    @MainActor func testSiblingSendKeepsItsLiveSenderAndCopiedHistoryOwnership() throws {
        let view = SessionDisplay(id: "audit-child"); view.historyState = .ready; view.supportsCodexAgents = true
        var summary = SubagentSteeringPresentationTests.tool.subagent!
        summary.taskName = "/root/tests"
        let recipient = summary.link.childSessionID
        view.childSummaries[recipient] = summary
        view.agentCoordination = ["mail": .init(id: "mail", childID: recipient, turn: 1, kind: "MESSAGE", author: "subagent", sourceSessionID: view.id,
            sourceMessageID: "reply", sourceToolCallID: "call", recipientID: recipient, disposition: "waiting_next_turn", sender: "/root/audit", recipient: "/root/tests", queueOnly: true)]
        view.messages = [.init(id: "reply", role: "assistant", text: "", tools: [Self.tool("send_message", target: "tests")])]
        let value = SubagentToolView(try XCTUnwrap(view.presentedMessages.first?.tools?.first))
        let target = try XCTUnwrap(value.target)
        XCTAssertFalse(target.isHistorical(in: view.id), "The issuing sibling is a live source, not copied history")
        XCTAssertTrue(target.isHistorical(in: "copied-chat"))
        XCTAssertEqual(value.label, "Waiting for its next turn")
        let card = TranscriptNativeSubagentCard()
        var environment = TranscriptRowEnvironment(); environment.sessionID = view.id
        var opened: [String] = []
        card.actions = TranscriptActions(openSubagent: { opened.append($0.sessionID) }, openAgentSource: { _ in opened.append("delivery") })
        for state in ["waiting_next_turn", "delivered"] {
            view.agentCoordination["mail"]?.disposition = state
            let current = SubagentToolView(try XCTUnwrap(view.presentedMessages.first?.tools?.first))
            card.update(.subagent(current), link: nil, environment: environment)
            let button = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: card).first { $0.accessibilityIdentifier() == "open-subagent" })
            XCTAssertTrue(button.isEnabled); button.onPress?()
        }
        XCTAssertEqual(opened, [recipient, "delivery"], "Pending mail opens the recipient; delivered mail opens its exact row")
    }
    @MainActor func testIdleQueueOnlyMailIsNotChangedToParentResume() throws {
        let view = SessionDisplay(id: "chat-parent"); view.historyState = .ready; view.supportsCodexAgents = true
        var tool = Self.tool("spawn_agent"), summary = SubagentSteeringPresentationTests.tool.subagent!
        summary.taskName = "/root/audit"; summary.status = .completed
        summary.deliveryState = "waiting_next_turn"; summary.pendingMessages = 1; summary.pendingQueueOnlyMessages = 1
        tool.subagent = summary; view.childSummaries[summary.link.childSessionID] = summary
        view.messages = [.init(id: "reply", role: "assistant", text: "", tools: [tool])]
        let shown = try XCTUnwrap(view.presentedMessages.first?.tools?.first?.subagent)
        XCTAssertEqual(shown.deliveryState, "waiting_next_turn")
        XCTAssertTrue(shown.presentationLabel.contains("Waiting for its next turn"))
        var send = Self.tool("send_message"); send.agentDeliveryState = "waiting_next_turn"
        XCTAssertEqual(SubagentToolView(send).label, "Waiting for its next turn")
    }
    @MainActor func testInheritedRowsKeepMarkersAndFoldWithoutBuildingProse() throws {
        let marker: WireValue = .object(["from": .string("parent"), "cutoffEntryId": .string("parent-end")])
        let wire: WireValue = .array([.object(["id": .string("inherited"), "role": .string("user"), "text": .string("Inherited question"), "nativeInherited": marker])])
        let live = try TranscriptMessage.projected(wire)[0]
        let saved = TranscriptMessage.project(id: "inherited", message: ["role": .string("user"), "content": .string("Inherited question"), "nativeInherited": marker])
        XCTAssertEqual(live.nativeInherited, marker); XCTAssertEqual(saved.nativeInherited, marker)
        let view = SessionDisplay(id: "tests-child"); view.historyState = .ready; view.isManagedSubagent = true; view.supportsCodexAgents = true
        view.messages = (0..<250).map { index in
            var row = TranscriptMessage(id: "seed-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", text: "Inherited prose")
            row.nativeInherited = marker; return row
        } + [Self.delivery("NEW_TASK", sender: "/root", recipient: "/root/tests")]
        let items = TaskTranscriptPlan.items(view.presentedMessages, lifecycle: nil)
        let folds = items.compactMap { item -> TurnFoldSpec? in if case .block(let block) = item { return block.foldSummary }; return nil }
        XCTAssertEqual(folds.map(\.label), ["Started with the main chat's context · 250 messages"])
        XCTAssertTrue(view.presentedMessages.filter { $0.nativeInherited != nil }.allSatisfy { $0.earlierVersion == true && $0.nativeAgentDelivery == nil })
        let pane = NativeTranscriptPane(frame: .init(x: 0, y: 0, width: 600, height: 400))
        pane.update(session: view, state: "idle", actions: .init(), environment: .init(), reduceMotion: true)
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(ConversationPaneTests.views(TranscriptNativeUserRow.self, in: pane).isEmpty, "Folded inherited rows build no user prose")
    }
}
