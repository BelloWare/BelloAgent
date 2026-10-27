import AppKit
import Darwin
import XCTest
@testable import PiApp

/// Generated wire-contract scenes, without a helper, credentials or user data.
final class SubagentCodexGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testCodexAgentScenes() async throws {
        guard let path = testEnvironment("PI_APP_CODEX_AGENTS_GALLERY") else { throw XCTSkip("Set PI_APP_CODEX_AGENTS_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in
            fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        let previous = TranscriptDisplay.mode; TranscriptDisplay.use(.normal)
        defer { fixture.close(); TranscriptDisplay.use(previous) }
        let scenes = ["forked-start", "fresh-start", "sibling-send", "sibling-message", "final-answer", "follow-up", "interrupt", "idle-mail", "wait", "list", "inherited-fold", "inherited-expanded", "v3-history", "named-search"]
        var written: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 680), NSSize(width: 640, height: 820)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size); fixture.window.center()
                for scene in scenes {
                    fixture.showCodex(scene); await fixture.settle()
                    if let session = fixture.model.selected, let message = session.messages.last(where: { $0.tools?.isEmpty == false }), let tool = message.tools?.first {
                        let revealed = await fixture.model.revealInTranscript(sessionID: session.id, messageID: message.id, toolCallID: tool.id)
                        XCTAssertTrue(revealed, scene); await fixture.settle()
                    }
                    if fixture.model.selected?.isManagedSubagent == true { XCTAssertTrue(fixture.content.pane.composer.isHidden, scene) }
                    if scene.hasPrefix("inherited") {
                        let scroll = fixture.content.pane.transcript.scrollView
                        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                        await fixture.settle()
                        XCTAssertEqual(fixture.child.inheritedContextFolded, scene == "inherited-fold")
                    }
                    let name = "\(scene)-\(theme)-\(Int(size.width)).png"
                    try capture(fixture.window, to: folder.appendingPathComponent(name)); written.append(name)
                }
                fixture.showCodex("forked-start")
                let picker = AgentFamilyPopoverView(model: fixture.model, sessionID: fixture.parent.id, close: {}, ownerWindow: fixture.window, embedded: true)
                fixture.window.contentView = picker; picker.frame.size = size
                picker.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let name = "named-picker-\(theme)-\(Int(size.width)).png"
                try capture(fixture.window, to: folder.appendingPathComponent(name)); written.append(name)
                fixture.window.contentView = fixture.content
            }
        }
        _ = try await fixture.prepareSteeringInspector()
        fixture.showCodex("forked-start")
        for summary in fixture.model.subagentSummaries.values { try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project") }
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let inspector = SessionInspectorModel(scope: .init(sessionID: fixture.parent.id, workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model,
                usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                    try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                })
            let controller = SessionInspectorWindowController(inspector: inspector), window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: appearance); window.setContentSize(.init(width: 920, height: 680))
            controller.present(.subagent("delegation-0"))
            for _ in 0..<200 where !inspector.indexLoaded || inspector.page != .subagent("delegation-0") { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(inspector.groups.first?.title, "audit")
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(150))
            let name = "named-inspector-\(theme).png"
            try capture(window, to: folder.appendingPathComponent(name)); written.append(name); controller.close()
        }
        XCTAssertEqual(written.count, 62)
        try (written.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero, frame = window.frame
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        let captured = try XCTUnwrap(create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue())
        try XCTUnwrap(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:])).write(to: url)
    }
}

extension SubagentGalleryFixture {
    func showCodex(_ scene: String) {
        showSteering(scene == "v3-history" ? "delivered-result" : "background-expanded")
        for session in [parent, child] { session.supportsCodexAgents = scene != "v3-history"; session.subagentNames = [:] }
        guard scene != "v3-history" else { return }
        parent.runState = .idle; parent.runStatus = "completed"
        child.runState = .idle; child.runStatus = "completed"; child.subagentStatus = .completed
        let names = ["audit", "tests", "recovery", "coverage"]
        for index in 1..<model.chats.count {
            let id = model.chats[index].id, name = names[index - 1]
            model.chats[index].subagentTaskName = name
            model.subagentSummaries[id]?.taskName = "/root/" + name
            model.subagentSummaries[id]?.forkTurns = "all"
            model.subagentSummaries[id]?.deliveryState = nil
            model.subagentSummaries[id]?.revision += 100
            for session in [parent, child] { session.subagentNames[id] = name }
        }
        if scene == "idle-mail" {
            model.subagentSummaries["child-1"]?.status = .completed
            model.subagentSummaries["child-1"]?.deliveryState = "waiting_next_turn"
            model.subagentSummaries["child-1"]?.pendingMessages = 1
            model.subagentSummaries["child-1"]?.pendingQueueOnlyMessages = 1
        }
        if ["sibling-send", "sibling-message", "idle-mail", "inherited-fold", "inherited-expanded", "final-answer", "list"].contains(scene) {
            model.subagentSummaries[child.id]?.status = .completed
        }
        if scene == "interrupt" { model.subagentSummaries["child-1"]?.status = .interrupted }
        parent.childSummaries = model.subagentSummaries; child.childSummaries = model.subagentSummaries
        func tool(_ name: String, target: String = "audit", text: String = "Review the parser and report concrete issues with file and line references.", output: String = "") -> ToolView {
            var value = SubagentCodexPresentationTests.tool(name, target: target, output: output)
            value.id = "call-0"
            value.input = WireValue.object([name == "spawn_agent" ? "task_name" : "target": .string(target), "message": .string(text), "fork_turns": .string(scene == "fresh-start" ? "none" : "all")]).pretty
            if var fields = value.nativeSubagent?.object {
                fields["sessionId"] = .string(child.id); fields["delegationId"] = .string("delegation-0")
                fields["budgetOwnerSessionId"] = .string(parent.id); fields["parentAssistantMessageId"] = .string("reply"); fields["toolCallId"] = .string(value.id)
                fields["forkTurns"] = .string(scene == "fresh-start" ? "none" : "all"); value.nativeSubagent = .object(fields)
                value.subagent = model.subagentSummaries[child.id]
            }
            return value
        }
        func delivery(_ type: String, sender: String, recipient: String, text: String) -> TranscriptMessage {
            var row = SubagentCodexPresentationTests.delivery(type, sender: sender, recipient: recipient, text: text)
            var metadata = row.nativeAgentDelivery!.object!, event = metadata["events"]!.array![0].object!
            func id(_ name: String) -> String? { names.firstIndex(of: SubagentLabel.task(name) ?? "").map { "child-\($0)" } }
            event["sender_child_id"] = id(sender).map(WireValue.string); event["recipient_child_id"] = id(recipient).map(WireValue.string)
            metadata["events"] = .array([.object(event)]); row.nativeAgentDelivery = .object(metadata); return row
        }
        var value = tool("spawn_agent"), session = parent
        switch scene {
        case "sibling-send", "idle-mail":
            session = child
            value = tool("send_message", target: "tests", text: "The writer lock is held. Check that the recovery test waits for it before reading.", output: "Queued for /root/tests.")
            child.agentCoordination = ["mail": .init(id: "mail", childID: "child-1", turn: 1, kind: "MESSAGE", author: "subagent", sourceSessionID: child.id, sourceMessageID: "reply", sourceToolCallID: "call-0", recipientID: "child-1", disposition: scene == "idle-mail" ? "waiting_next_turn" : "delivered", sender: "/root/audit", recipient: "/root/tests", queueOnly: true)]
        case "follow-up": value = tool("followup_task", text: "Check recovery with a multi-byte character before the malformed escape."); value.subagent?.turn = 2
        case "interrupt": value = tool("interrupt_agent", target: "tests", output: "{\"previous_status\":\"running\"}")
        case "wait": value = tool("wait_agent", output: "Wait completed: updates from /root/audit, /root/tests.")
        case "list": value = tool("list_agents", output: "{\"agents\":[{\"agent_name\":\"/root\",\"agent_status\":\"running\"},{\"agent_name\":\"/root/audit\",\"agent_status\":\"idle\",\"turn\":2},{\"agent_name\":\"/root/tests\",\"agent_status\":\"running\",\"turn\":1}],\"next_cursor\":null}")
        default: break
        }
        session.messages = [.init(id: "reply", role: "assistant", text: "", tools: [value])]
        session.disclosure.setOpen(true, .work("reply")); session.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", "call-0")))
        if scene == "sibling-message" {
            session = child
            session.messages = [delivery("MESSAGE", sender: "/root/tests", recipient: "/root/audit", text: "The recovery regression passes.\n\nPlease preserve the **original diagnostic span** before advancing the cursor.")]
        } else if scene == "final-answer" {
            parent.messages = [delivery("FINAL_ANSWER", sender: "/root/audit", recipient: "/root", text: SubagentMarkdownTests.rich + "\n\n" + String(repeating: "The focused regression preserves the **original span**.\n\n", count: 30))]
        } else if scene.hasPrefix("inherited") {
            session = child
            let marker: WireValue = .object(["from": .string(parent.id), "cutoffEntryId": .string("seed-5")])
            child.messages = (0..<6).map { index in
                var row = TranscriptMessage(id: "seed-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant", text: index.isMultiple(of: 2) ? "Review the release and its parser regression tests." : "The release notes describe token boundaries and recovery.")
                row.nativeInherited = marker; return row
            } + [delivery("NEW_TASK", sender: "/root", recipient: "/root/audit", text: "You are now `/root/audit`, a sub-agent in this team. The conversation above is inherited context from `/root`.\n\nAudit the parser and report concrete findings.")]
            child.disclosure.setOpen(scene == "inherited-expanded", .turnFold("inherited:" + parent.id + ":seed-5"))
        }
        model.selectedID = session.id; model.focusedSessionID = session.id; model.selected = session
        content.pane.show(session: session, chat: model.record(session.id)!)
        content.sidebar.setFilter(scene == "named-search" ? "audit" : ""); content.needsLayout = true
    }
}
