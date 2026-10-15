import AppKit
import XCTest
@testable import PiApp

final class SubagentTranscriptTests: XCTestCase {
    @MainActor func testHistoricalForkCardHasNoSourceNavigationOrControls() throws {
        var tool = Self.tool; tool.nativeSubagent = Self.metadata; tool.state = "running"
        var environment = TranscriptRowEnvironment(); environment.sessionID = "fork"
        var called = false
        let actions = TranscriptActions(openSubagent:{ _ in called = true },inspectSubagent:{ _ in called = true },stopSubagent:{ _ in called = true })
        let row = TranscriptNativeActionRow()
        row.update(tool:tool,open:true,fetched:nil,environment:environment,toggle:{},openFile:nil,actions:actions)
        let buttons = ConversationPaneTests.views(PiKit.Button.self,in:row)
        for id in ["open-subagent","inspect-subagent","stop-subagent"] {
            let button = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == id })
            XCTAssertTrue(button.isHidden || !button.isEnabled)
            button.onPress?()
        }
        XCTAssertFalse(called,"Even a retained action must not navigate into the source's live child")
        XCTAssertEqual(buttons.first { $0.accessibilityIdentifier() == "open-subagent" }?.title,"History")
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self,in:row).contains { $0.string.contains("Historical sub-agent") })
    }
    static let link = SubagentLink(delegationID: "delegation", childSessionID: "chat-child", budgetOwnerSessionID: "chat-parent",
                                  call: .init(parentSessionID: "chat-parent", assistantMessageID: "reply", toolCallID: "call"),
                                  parentTurnID: "turn", parentExecutionID: "execution")
    static let metadata = try! JSONDecoder().decode(WireValue.self, from: Data("""
    {"version":1,"delegationId":"delegation","sessionId":"chat-child","budgetOwnerSessionId":"chat-parent",
     "parentAssistantMessageId":"reply","toolCallId":"call","status":"completed",
     "resultRef":{"messageIds":["answer"]},"effects":"known","accountingRevision":1}
    """.utf8))
    static var tool: ToolView {
        ToolView(id: "call", name: "subagent", state: "completed", input: "{\"task\":\"Check the parser\"}",
                 output: "{\"status\":\"completed\",\"text\":\"Parser checked\",\"truncated\":false}", durationMs: 800, truncated: false)
    }

    @MainActor func testRunningCardUsesSharedMoneyFormattingWithoutRepeatingItsHeader() throws {
        var tool = Self.tool
        tool.subagent = SubagentSummary(link: Self.link, description: "Review", model: "fixture", status: .running, revision: 1,
            tools: ["read"], progress: .init(phase: "streaming", elapsedMs: 1000, requests: 2, tools: 1, preview: "Checking the parser",
                usd: 0.04, reported: 2, unreported: 1, inputTokens: 100, outputTokens: 20))
        let row = TranscriptNativeActionRow()
        row.update(tool: tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptPlainTextView.self, in: row.card!).first).string
        XCTAssertEqual(body, "Model: fixture\nTools: read\n2 requests · 1 tools completed · 1s\nReported $0.04 · 2 reported · 1 cost unknown\nTokens: 100 input · 20 output\nChecking the parser")
        XCTAssertEqual(SessionCostReading(limit: .usd(1), spentUSD: 0.04).figure, "$0.04 of $1.00")
        XCTAssertEqual(InspectorSubagentGroup(summary: tool.subagent!, requests: 2, cost: 0.04, costSamples: 2).detail, "Running · 2 requests · $0.04")
        var totals = GatewayTotals(); totals.requests = 2; totals.costSamples = 2; totals.costUSD = 0.04
        XCTAssertEqual(ChatRowStats(totals: totals).costLabel, "$0.04")
    }

    func testOfflineAndFastProjectionKeepDurableChildNavigation() throws {
        let record = try XCTUnwrap(ToolResultRecord.of([
            "role":.string("toolResult"), "toolCallId":.string("call"), "content":.string(Self.tool.output), "nativeSubagent":Self.metadata
        ]))
        var tool = Self.tool; tool.state = "recorded"
        let rows = TranscriptMessage.resolvingToolResults([
            TranscriptMessage(id: "reply", role: "assistant", text: "", tools: [tool]),
            TranscriptMessage(id: "result", role: "tool", text: tool.output, toolCallID: "call")
        ], results: ["result":record.record])
        let value = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(rows))
        XCTAssertEqual(value.array?.first?.object?["tools"]?.array?.first?.object?["nativeSubagent"], Self.metadata)
        var fields = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(Self.tool)).object ?? [:]
        fields["nativeSubagent"] = Self.metadata
        let live: WireValue = .array([.object(["id":.string("reply"), "role":.string("assistant"), "text":.string(""), "tools":.array([.object(fields)])])])
        let projected = try TranscriptMessage.projected(live)
        let saved = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(projected))
        XCTAssertEqual(saved.array?.first?.object?["tools"]?.array?.first?.object?["nativeSubagent"], Self.metadata)
    }

    @MainActor func testSubagentUsesItsNativeCardAndKeepsManualDisclosure() {
        let row = TranscriptNativeActionRow()
        row.update(tool: Self.tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        XCTAssertEqual(row.card?.accessibilityIdentifier(), "subagent-card")
        row.update(tool: Self.tool, open: false, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        XCTAssertNil(row.card)
    }

    @MainActor func testManagedChildCannotForkOrOpenASide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-transcript-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        bench.model.chats[1].delegation = Self.link; bench.model.chats[1].parentSessionID = "chat-parent"
        XCTAssertFalse(bench.model.canForkFromReply("chat-child"))
        XCTAssertFalse(bench.model.canOpenSide("chat-child"))
    }
    @MainActor func testCardActionsUseSavedIdentityAndCopiedCardsCannotStopTheOriginal() throws {
        var tool = Self.tool; tool.nativeSubagent = Self.metadata
        var environment = TranscriptRowEnvironment(); environment.sessionID = "chat-parent"
        var calls: [String] = []
        let relay = TranscriptActionRelay()
        relay.current = TranscriptActions(openSubagent: { calls.append("open:" + $0.sessionID) },
                                          inspectSubagent: { calls.append("inspect:" + $0.delegationID) },
                                          stopSubagent: { calls.append("stop:" + $0.ownerID) })
        let row = TranscriptNativeActionRow()
        row.update(tool: tool, open: true, fetched: nil, environment: environment, toggle: {}, openFile: nil, actions: .forwarding { relay.forwarded })
        for id in ["open-subagent", "inspect-subagent"] {
            let button = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == id })
            button.onPress?()
        }
        XCTAssertEqual(calls, ["open:chat-child", "inspect:delegation"])
        // A copied card is saved history and has no Stop affordance.
        tool.output = "{\"status\":\"running\",\"text\":\"\",\"truncated\":false}"; tool.state = "running"
        environment.sessionID = "fork"
        row.update(tool: tool, open: true, fetched: nil, environment: environment, toggle: {}, openFile: nil, actions: relay.forwarded)
        XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "stop-subagent" }).isHidden)
        environment.sessionID = "chat-parent"
        row.update(tool: tool, open: true, fetched: nil, environment: environment, toggle: {}, openFile: nil, actions: relay.forwarded)
        let stop = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "stop-subagent" })
        XCTAssertFalse(stop.isHidden); stop.onPress?()
        XCTAssertEqual(calls.last, "stop:chat-parent")
    }

    func testDiscoveryChecksManagedHeaderReciprocalIdentityAndDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-header-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var link = Self.link; link.childSessionID = UUID().uuidString
        let target = SubagentTarget(link), path = root.appendingPathComponent(link.childSessionID + ".jsonl")
        let header = SubagentHeader(link: link, description: "Parser", model: .init(model: "model"), readOnly: true)
        let origin = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(header))
        let records: [WireValue] = [
            .object(["type":.string("session"), "version":.number(3), "id":.string(link.childSessionID)]),
            .object(["type":.string("custom"), "id":.string("marker"), "customType":.string("pi-app.native.v2"), "data":.object(["version":.number(2)])]),
            .object(["type":.string("custom"), "parentId":.string("marker"), "customType":.string("pi-app.subagent-origin.v1"), "data":origin])
        ]
        var bytes = Data(); for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        try bytes.write(to: path)
        let reader = HistoryReader()
        let found = try await reader.subagentHeader(path: path, directory: root, expected: target)
        XCTAssertEqual(found.link, link)
        var wrong = target; wrong.ownerID = "foreign"
        do { _ = try await reader.subagentHeader(path: path, directory: root, expected: wrong); XCTFail("Foreign ownership accepted") } catch { }
        do { _ = try await reader.subagentHeader(path: path, directory: root.appendingPathComponent("other"), expected: target); XCTFail("Foreign project accepted") } catch { }
        let old = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "pi-app.native.v2", with: "pi-app.native.v1")
        try Data(old.utf8).write(to: path)
        do { _ = try await reader.subagentHeader(path: path, directory: root, expected: target); XCTFail("Ordinary journal accepted as a managed child") } catch { }
    }

    @MainActor func testChildrenHaveNoDraftOrIndependentCostChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-input-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["parent", "child"])
        defer { bench.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        bench.model.chats[0].costLimit = .usd(8)
        bench.model.chats[1].delegation = Self.link; bench.model.chats[1].parentSessionID = "chat-parent"
        let view = SessionDisplay(id: "chat-child"); view.selectionMetadataLoaded = true
        view.draft = "Not an input session"; bench.model.displays[view.id] = view
        let store = try XCTUnwrap(bench.model.store)
        for chat in bench.model.chats { try await store.put(chat, kind: "chat", id: chat.id) }
        try await bench.model.flushDrafts()
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertNil(draft)
        XCTAssertEqual(bench.model.costLimit(for: view.id), .usd(8))
        do { try await bench.model.setCostLimit(.usd(100), for: view.id); XCTFail("Managed child changed its own limit") } catch { }
        XCTAssertNil(bench.model.record(view.id)?.costLimit)
    }

    func testGenericCutOffToolResultsAreNeverShownAsQueued() {
        for (state, expected) in [("unknown", SubagentStatus.interrupted), ("cancelled", .cancelled), ("completed", .completed), ("failed", .failed)] {
            var tool = Self.tool; tool.state = state; tool.output = "Saved result from the older helper"
            XCTAssertEqual(SubagentToolView(tool).status, expected, state)
        }
    }

}
