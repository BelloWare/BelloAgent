import AppKit
import XCTest
@testable import PiApp

final class SubagentDisplayTests: XCTestCase {
    @MainActor func testEveryNewDisplaySeedsSavedNumbersIncludingSideAndCopiedPresentations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats[1].subagentNumber = 2
        for id in ["chat-parent", "side-viewer", "copied-viewer", "chat-child"] {
            let view = SessionDisplay(id: id)
            model.displays[id] = view
            XCTAssertEqual(view.subagentNumbers["chat-child"], 2)
        }
    }
    @MainActor func testNarrowSubagentActionsRemainInsideTheCard() throws {
        let card = TranscriptNativeSubagentCard()
        var environment = TranscriptRowEnvironment(); environment.sessionID = "chat-parent"
        card.update(.subagent(SubagentToolView(SubagentSteeringPresentationTests.tool)), link: nil, environment: environment)
        for width: CGFloat in [320, 376, 656] {
            card.frame = CGRect(x: 0, y: 0, width: width, height: card.height(width: width))
            card.layoutSubtreeIfNeeded()
            for button in ConversationPaneTests.views(PiKit.Button.self, in: card) where !button.isHidden {
                let frame = card.convert(button.bounds, from: button)
                XCTAssertGreaterThanOrEqual(frame.minX, card.panel.frame.minX)
                XCTAssertLessThanOrEqual(frame.maxX, card.panel.frame.maxX, "\(button.title) is clipped at \(width)")
                XCTAssertLessThanOrEqual(frame.maxY, card.panel.frame.maxY)
            }
        }
    }

    @MainActor func testChildFooterAndNarrowHeaderKeepTheNumberVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        var child = model.chats[1]; child.subagentNumber = 2
        let footer = PaneFooterView(frame: .zero), display = SessionDisplay(id: child.id)
        footer.update(.subagent(status: "Running", busy: true, parent: "A long parent title"), chat: child, session: display, model: model)
        let stop = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: footer).first)
        XCTAssertEqual(stop.title, "Stop Sub-agent 2")
        let header = SubagentHeaderView(frame: .zero)
        header.update(chat: child, parent: model.chats[0], back: {})
        XCTAssertTrue(ConversationPaneTests.views(PiKit.TextLine.self, in: header).contains { $0.line.text.hasPrefix("Sub-agent 2 ·") })
    }
    @MainActor func testNumberedCardsAndMixedAgentMessagesKeepWireTextAndProvenanceUntouched() throws {
        let display = SessionDisplay(id: "chat-parent"); display.historyState = .ready
        display.subagentNumbers = ["chat-child": 2, "sibling": 7]
        let control = TranscriptMessage(id: "control", role: "assistant", text: "", tools: [SubagentSteeringPresentationTests.tool])
        var delivery = SubagentSteeringPresentationTests.delivery.object!
        var first = delivery["events"]!.array![0].object!, second = first
        first["author"] = .string("parent"); second["child_id"] = .string("sibling")
        second["task"] = .string("Review cancellation")
        delivery["events"] = .array([.object(first), .object(second)])
        let message = TranscriptMessage(id: "batch", role: "user", text: "Original agent envelope", kind: "agent_message", nativeAgentDelivery: .object(delivery))
        display.messages = [control, message]
        let presented = display.presentedMessages
        let tool = try XCTUnwrap(presented.first?.tools?.first)
        XCTAssertEqual(tool.output, control.tools?.first?.output)
        XCTAssertEqual(tool.input, control.tools?.first?.input)
        XCTAssertEqual(tool.nativeSubagent, control.tools?.first?.nativeSubagent)
        XCTAssertNil(display.messages.first?.tools?.first?.subagentNumber)
        XCTAssertEqual(TranscriptToolRow.model(of: tool).title, "Sub-agent 2")
        XCTAssertTrue(TranscriptToolRow.model(of: tool).help.contains("Sub-agent 2"))
        let card = TranscriptNativeSubagentCard()
        card.configure(.subagent(SubagentToolView(tool)))
        XCTAssertTrue(card.accessibilityLabel()?.contains("Sub-agent 2") == true)
        let batch = try XCTUnwrap(presented.last)
        XCTAssertEqual(batch.text, message.text); XCTAssertEqual(batch.nativeAgentDelivery, message.nativeAgentDelivery)
        XCTAssertNil(display.messages.last?.agentNumbers)
        let events = AgentMessagePresentation(batch).events
        XCTAssertEqual(events.map(\.number), [2, 7])
        XCTAssertTrue(events[0].title.hasPrefix("Parent → Sub-agent 2 ·"))
        XCTAssertTrue(events[1].title.hasPrefix("Sub-agent 7 ·"))
        display.isManagedSubagent = true
        var report = SubagentSteeringPresentationTests.tool
        report.name = "subagent_report"; report.nativeSubagent = nil; report.subagent = nil; report.output = "{}"
        let child = SessionDisplay(id: "chat-child"); child.isManagedSubagent = true; child.subagentNumbers = display.subagentNumbers
        let shown = child.presentAgentState(.init(id: "report", role: "assistant", text: "", tools: [report]))
        XCTAssertEqual(shown.tools?.first?.subagentNumber, 2)
        // A copied card in a retained version keeps its original child's UI
        // identity. It does not become a child of the chat viewing the copy.
        display.messages = [.init(id: "edited", role: "user", text: "New version")]
        display.versionView = TranscriptVersionView(latestID: "edited", index: 1, count: 2, ids: ["old", "edited"], live: 2,
            rows: [.init(id: "old", role: "user", text: "Old task"), control], loading: false)
        let copied = display.presentedMessages.first { $0.id == "control" }?.tools?.first
        XCTAssertEqual(copied?.subagentNumber, 2)
        XCTAssertEqual(copied?.nativeSubagent, control.tools?.first?.nativeSubagent)
    }

    @MainActor func testNumberReachesSidebarHeaderInspectorAndSurvivesStaleMetadataMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        var child = model.chats[1]; child.subagentNumber = 2
        XCTAssertEqual(child.displayTitle, "Sub-agent 2 · " + child.title)
        var stale = child; stale.subagentNumber = nil
        XCTAssertEqual(stale.merged(over: child).subagentNumber, 2)
        let content = SidebarChatRowView.content(model: model, chat: child, state: SidebarChatRowState(), display: nil, retained: nil)
        XCTAssertEqual(content.title, "#2 · child — in parent")
        let header = SubagentHeaderView(frame: .zero)
        header.update(chat: child, parent: model.chats[0], back: {})
        let back = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: header).first { $0.accessibilityIdentifier() == "back-to-subagent-parent" })
        XCTAssertTrue(back.toolTip?.contains("Sub-agent 2") == true)
        XCTAssertTrue(back.accessibilityLabel()?.contains("Sub-agent 2") == true)
        let group = InspectorSubagentGroup(summary: SubagentSteeringPresentationTests.tool.subagent!, number: 2)
        XCTAssertTrue(group.title.hasPrefix("Sub-agent 2 ·"))
        header.update(chat: child, parent: nil, back: {})
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(back.accessibilityLabel()?.contains("Sub-agent 2") == true)
    }
    @MainActor func testNumbersFollowUniqueAcceptedStartsIncludingMissingChildrenAndLegacyPlans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        let parent = URL(fileURLWithPath: model.chats[0].path!)
        let original = try String(contentsOf: parent, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        let saved = try JSONDecoder().decode([String: WireValue].self, from: original[1])
        var plan = saved["data"]!.object!
        var origin = plan["origin"]!.object!, link = origin["link"]!.object!
        let missing = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        link["childSessionID"] = .string(missing); link["delegationID"] = .string("missing")
        origin["link"] = .object(link); plan["origin"] = .object(origin)
        let first: [String:WireValue] = ["customType":.string("pi-app.agent-operation.v1"), "data":.object(["plan":.object(plan)])]
        // Reverse lexical child order, no child file for the first start, and
        // a replayed copy of the second start. Neither changes the ordinal.
        var bytes = original[0]; bytes.append(10)
        for row in [first, saved, saved] { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
        try bytes.write(to: parent)
        let third = "00000000-0000-0000-0000-000000000003"
        link["childSessionID"] = .string(third); link["delegationID"] = .string("third")
        origin["link"] = .object(link); plan["origin"] = .object(origin)
        bytes.append(try JSONEncoder().encode(["customType":WireValue.string("pi-app.subagent-call.v1"), "data":.object(plan)])); bytes.append(10)
        try bytes.write(to: parent)
        let plans = try await model.history.subagentPlans(path: parent, ownerID: "chat-parent")
        XCTAssertEqual(plans.map(\.number), [1, 2, 3])
        let last = try await model.history.subagentPlans(path: parent, ownerID: "chat-parent", childID: third)
        XCTAssertEqual(last.first?.number, 3, "A filtered read still counts preceding accepted starts")
        let coordination = try await model.history.agentCoordination(path: parent, ownerID: "chat-parent")
        XCTAssertEqual(coordination.subagentNumbers, [missing: 1, family.child: 2, third: 3])
        try await model.store!.putChats(model.chats)
        await model.reconcileSubagents()
        var child = try XCTUnwrap(model.record(family.child))
        func number(_ chat: ChatRecord) throws -> Double? {
            try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(chat)).object?["subagentNumber"]?.number
        }
        XCTAssertEqual(try number(child), 2)
        child.lastActivityAt = .max; child.title = "Renamed task"
        try await model.store!.put(child, kind: "chat", id: child.id)
        model.chats = try await model.store!.loadChats()
        await model.reconcileSubagents()
        XCTAssertEqual(try number(XCTUnwrap(model.record(family.child))), 2)
        XCTAssertEqual(try Data(contentsOf: parent), bytes)
    }
    @MainActor func testDiscoveryCachesThePersistedStartNumberAndRebuildsItAfterMetadataLoss() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        try await model.store!.putChats(model.chats)
        let parentPath = URL(fileURLWithPath: model.chats[0].path!)
        let parentBytes = try Data(contentsOf: parentPath)
        let childBytes = try Data(contentsOf: family.path)
        for _ in 0..<2 {
            await model.reconcileSubagents()
            let child = try XCTUnwrap(model.record(family.child))
            let json = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(child))
            XCTAssertEqual(json.object?["subagentNumber"]?.number, 1)
            var legacy = json.object!; legacy.removeValue(forKey: "subagentNumber")
            try await model.store!.put(legacy, kind: "chat", id: child.id)
            model.chats = try await model.store!.loadChats()
        }
        XCTAssertEqual(try Data(contentsOf: parentPath), parentBytes)
        XCTAssertEqual(try Data(contentsOf: family.path), childBytes)
        XCTAssertTrue(model.hosts.isEmpty)
    }
}
