import AppKit
import XCTest
@testable import PiApp

private actor CodexPageReads {
    private(set) var count = 0
    func record() { count += 1 }
}

final class SubagentCodexStorageTests: XCTestCase {
    @MainActor func testNamedRecordsPersistAcrossOlderWritesAndAppearInSearchAndPicker() async throws {
        let root = scratchRoot("codex-names"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let index = try XCTUnwrap(model.chats.firstIndex { $0.id == "chat-child" })
        var chat = model.chats[index]; chat.subagentTaskName = "audit"; chat.title = "Review cancellation"
        model.chats[index] = chat
        XCTAssertEqual(chat.displayTitle, "audit"); XCTAssertEqual(chat.subagentShortTitle, "audit")
        XCTAssertEqual(model.subagentSearchTitle(chat), "audit")
        let saved = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(saved.subagentTaskName, "audit")
        var old = chat; old.subagentTaskName = nil
        XCTAssertEqual(old.merged(over: saved).subagentTaskName, "audit")
        for query in ["audit", "cancellation"] {
            XCTAssertTrue(SubagentOrganizationTests.contents(model, filter: query).entries.map(\.id).contains("chat|chat-child"), query)
        }
        let picker = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: nil)
        let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: picker)
        XCTAssertTrue(rows.contains { $0.accessibilityLabel()?.contains("Open audit") == true })
        XCTAssertTrue(rows.contains { $0.accessibilityLabel()?.contains("Review cancellation") == true })
        let sidebar = WorkspaceSidebarView(model: model)
        sidebar.setFilter("audit"); sidebar.frame = .init(x: 0, y: 0, width: 280, height: 600); sidebar.layoutSubtreeIfNeeded()
        let named = try XCTUnwrap(ConversationPaneTests.views(ChatRowBodyView.self, in: sidebar).first { $0.content?.title == "audit" })
        var content = try XCTUnwrap(named.content)
        content.stats.requests = 1; content.stats.costUSD = 0.42
        named.update(content)
        XCTAssertTrue(ConversationPaneTests.views(PiKit.TextLine.self, in: named).contains { !$0.isHidden && $0.line.text.contains("Review cancellation") })
    }
    @MainActor func testHandshakeAdvertisesCodexCapabilityAndClearsItOnDisconnect() async throws {
        let root = scratchRoot("codex-capability")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for enabled in [false, true] {
            let host = HostSupervisor(commandSender: { _ in }); defer { host.shutdown() }
            try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
            let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
            let capabilities = ["responses", "mcp", "steering", "transport-capture"] + (enabled ? ["subagents-codex-v4"] : [])
            host.receive(.frame(["v": .number(1), "kind": .string("ready"), "major": .number(1), "engine": .string("swift"), "engineVersion": .string("1.0.0"), "hostEpoch": .string(epoch), "capabilities": .array(capabilities.map(WireValue.string))]), connectionID: connection)
            XCTAssertEqual(host.supportsCodexAgents, enabled)
            try await host.shutdownAndWait(); XCTAssertFalse(host.supportsCodexAgents)
        }
    }
    func testInheritedPageCountsTheWholeSeedWithoutDecodingIt() async throws {
        let root = scratchRoot("codex-inherited-page")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("child.jsonl")
        var rows: [[String: WireValue]] = [["type": .string("session"), "version": .number(3), "id": .string("child")]]
        let marker: WireValue = .object(["from": .string("parent"), "cutoffEntryId": .string("seed-999")])
        for index in 0..<1000 {
            rows.append(["type": .string("message"), "id": .string("seed-\(index)"), "parentId": index == 0 ? .null : .string("seed-\(index - 1)"), "message": .object(["role": .string(index.isMultiple(of: 2) ? "user" : "assistant"), "content": .string("Inherited text \(index)"), "nativeInherited": marker])])
        }
        try Self.write(rows, to: path)
        let reader = HistoryReader()
        let page = try await reader.window(path: path.path, start: true, limits: .init(rows: 24, bytes: 262144, turnRows: 24, turnBytes: 262144))
        XCTAssertLessThanOrEqual(page.messages.count, 24)
        XCTAssertEqual(page.messages.first?.inheritedCount, 1000)
        let decoded = await reader.decodedRecords
        XCTAssertLessThan(decoded, 40, "Only the page bodies are decoded; the seed count comes from offsets")
        XCTAssertNotNil(page.newer)
    }
    @MainActor func testFoldedContextDefersOpeningFillAndReadsOnlyAfterExpand() async throws {
        let root = scratchRoot("codex-fold-paging"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat-child"); view.historyState = .ready; view.supportsCodexAgents = true
        let marker: WireValue = .object(["from": .string("chat-parent"), "cutoffEntryId": .string("seed-999")])
        var row = TranscriptMessage(id: "seed-999", role: "assistant", text: "Inherited tail"); row.nativeInherited = marker
        view.messages = [row]; view.presentation.identity = ("fixture", "root"); view.presentation.openingPage = true
        view.olderPage = .init(cursor: .init(incarnation: "fixture", lineage: "root", entry: row.id))
        model.displays[view.id] = view; model.selected = view; model.selectedID = view.id; model.focusedSessionID = view.id
        view.supportsCodexAgents = true
        let reads = CodexPageReads()
        model.historyWindowLoader = { _, _, _, _ in
            await reads.record()
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"), "older": .null, "newer": .null,
                "messages": .array([.object(["id": .string("seed-998"), "role": .string("user"), "text": .string("Inherited question"), "nativeInherited": marker])])]))
        }
        model.startOpeningFill(view.id)
        XCTAssertNil(view.presentation.openingFill, "A folded seed must not start the background full-page fill")
        await view.presentation.openingFill?.value
        _ = await model.loadHistoryPage(view.id, newer: false, automatic: true)
        let closedReads = await reads.count
        XCTAssertEqual(closedReads, 0, "A closed fold must not prefetch the hidden seed")
        view.disclosure.setOpen(true, .turnFold("inherited:chat-parent:seed-999"))
        _ = await model.loadHistoryPage(view.id, newer: false, automatic: true)
        let expandedReads = await reads.count
        XCTAssertEqual(expandedReads, 1, "Expanding uses the existing bounded history loader")
        XCTAssertTrue(view.presentedMessages.allSatisfy { $0.earlierVersion == true })
    }
    func testV2TurnNavigationUsesRecipientIdentityAndEventID() async throws {
        let path = scratchRoot("codex-turn.jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let task = SubagentCodexPresentationTests.delivery("NEW_TASK", sender: "/root/audit", recipient: "/root/tests")
        try Self.write([["type": .string("message"), "id": .string("row"), "message": .object(["role": .string("user"), "content": .string("frame"), "nativeAgentDelivery": task.nativeAgentDelivery!])]], to: path)
        let reader = HistoryReader()
        let found = try await reader.subagentTurnMessage(path: path, childID: "tests-child", turn: 1, messageID: "event")
        let foreign = try await reader.subagentTurnMessage(path: path, childID: "foreign", turn: 1, messageID: "event")
        XCTAssertEqual(found, "row"); XCTAssertNil(foreign)
    }
    @MainActor func testV4HeaderAndAdoptedV3SummarySupplyDurableNames() async throws {
        let root = scratchRoot("codex-discovery"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: nil, bodyRetention: 86_400, metricRetention: 86_400)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let parentPath = URL(fileURLWithPath: try XCTUnwrap(model.chats[0].path))
        var parentRows = try String(contentsOf: parentPath, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String: WireValue].self, from: Data($0.utf8)) }
        var plan = parentRows[1]["data"]!.object!, origin = plan["origin"]!.object!
        origin["taskName"] = .string("/root/audit"); origin["forkTurns"] = .string("all")
        plan["origin"] = .object(origin); parentRows[1]["data"] = .object(plan)
        var childRows = try String(contentsOf: family.path, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String: WireValue].self, from: Data($0.utf8)) }
        childRows[1]["customType"] = .string("pi-app.native.v4"); childRows[2]["data"] = .object(origin)
        try Self.write(parentRows, to: parentPath); try Self.write(childRows, to: family.path)
        try await model.store?.putChats(model.chats); await model.reconcileSubagents()
        XCTAssertEqual(model.record(family.child)?.displayTitle, "audit")
        XCTAssertEqual(model.subagentSummaries[family.child]?.forkTurns, "all")
        // Adoption supplies the canonical name in the helper summary even
        // when the saved v3 origin predates names.
        origin.removeValue(forKey: "taskName"); origin.removeValue(forKey: "forkTurns")
        childRows[1]["customType"] = .string("pi-app.native.v3"); childRows[2]["data"] = .object(origin)
        try Self.write(childRows, to: family.path)
        var summary = try XCTUnwrap(model.subagentSummaries[family.child]); summary.revision = 10
        try await model.registerListedSubagent(summary, parent: model.chats[0], task: "Audit")
        XCTAssertEqual(model.record(family.child)?.displayTitle, "audit")
    }
    @MainActor func testCoordinationProjectsSiblingAndFinalMailWithoutInventingAnInterruptResult() async throws {
        let root = scratchRoot("codex-coordination"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model), parent = model.chats[0]
        let path = URL(fileURLWithPath: try XCTUnwrap(parent.path))
        var rows = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String: WireValue].self, from: Data($0.utf8)) }
        var plan = rows[1]["data"]!.object!, origin = plan["origin"]!.object!
        origin["taskName"] = .string("/root/audit"); plan["origin"] = .object(origin); rows[1]["data"] = .object(plan)
        var siblingOrigin = origin, link = siblingOrigin["link"]!.object!
        link["childSessionID"] = .string("tests-child"); link["delegationID"] = .string("tests-delegation")
        siblingOrigin["link"] = .object(link); siblingOrigin["taskName"] = .string("/root/tests")
        rows.append(Self.custom("pi-app.subagent-call.v1", ["origin": .object(siblingOrigin)]))
        rows.append(Self.custom("pi-app.agent-operation.v1", ["key": .object(["parentSessionID": .string(family.child), "assistantMessageID": .string("source"), "toolCallID": .string("send")]), "message": .object(["id": .string("mail"), "childID": .string("tests-child"), "senderChildID": .string(family.child), "recipientChildID": .string("tests-child"), "turn": .number(1), "author": .string("subagent"), "type": .string("MESSAGE"), "sender": .string("/root/audit"), "recipient": .string("/root/tests"), "queueOnly": .bool(true)])]))
        rows.append(Self.custom("pi-app.subagent-turn-terminal.v1", ["childID": .string(family.child), "turn": .number(1), "status": .string("interrupted")]))
        rows.append(Self.custom("pi-app.agent-message.v1", ["id": .string("final"), "childID": .string(family.child), "senderChildID": .string(family.child), "turn": .number(2), "author": .string("subagent"), "type": .string("FINAL_ANSWER"), "sender": .string("/root/audit"), "recipient": .string("/root"), "disposition": .string("pending")]))
        try Self.write(rows, to: path)
        let state = try await model.history.agentCoordination(path: path, ownerID: parent.id)
        XCTAssertEqual(state.entries.map(\.id), ["mail", "final"])
        XCTAssertEqual(state.entries.first?.title, "audit → tests · Message")
        XCTAssertEqual(state.entries.first?.disposition, "waiting_next_turn")
        XCTAssertEqual(state.entries.last?.recipientID, parent.id)
        var delivery: [String: WireValue] = ["rowID": .string("delivered-row"), "recipientID": .string("tests-child"),
            "eventIDs": .array([.string("mail")]), "eventTurns": .object(["mail": .number(2)]), "committed": .bool(false)]
        rows.append(Self.custom("pi-app.agent-delivery.v1", delivery)); try Self.write(rows, to: path)
        let prepared = try await model.history.agentCoordination(path: path, ownerID: parent.id)
        XCTAssertEqual(prepared.entries.first?.turn, 1)
        XCTAssertEqual(prepared.entries.first?.disposition, "waiting_next_turn", "Preparation alone does not claim delivery")
        delivery["committed"] = .bool(true)
        rows.append(Self.custom("pi-app.agent-delivery.v1", delivery)); try Self.write(rows, to: path)
        let committed = try await model.history.agentCoordination(path: path, ownerID: parent.id)
        XCTAssertEqual(committed.entries.first?.turn, 2, "Queue-only mail navigates using its receiving turn")
        XCTAssertEqual(committed.entries.first?.recipientMessageID, "delivered-row")
        XCTAssertEqual(committed.entries.first?.disposition, "delivered")
    }
    static func custom(_ type: String, _ data: [String: WireValue]) -> [String: WireValue] {
        ["type": .string("custom"), "customType": .string(type), "data": .object(data)]
    }
    static func write(_ rows: [[String: WireValue]], to path: URL) throws {
        var bytes = Data(); for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }; try bytes.write(to: path)
    }
}
