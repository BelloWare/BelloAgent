import AppKit
import XCTest
@testable import PiApp

final class SubagentTranscriptTests: XCTestCase {
    @MainActor func testHistoricalForkCardSurvivesAppearanceChangesWithoutASessionUpdate() throws {
        var tool = Self.tool; tool.nativeSubagent = Self.metadata
        let session = SessionDisplay(id:"fork")
        session.messages = [TranscriptMessage(id:"question",role:"user",text:"Review the parser"),
                            TranscriptMessage(id:"reply",role:"assistant",text:"Delegating the review",tools:[tool])]
        session.disclosure.setOpen(true,.work("reply"))
        session.disclosure.setOpen(true,.tool(ToolOccurrence.key("reply",tool.id)))
        let pane = NativeTranscriptPane(frame:NSRect(x:0,y:0,width:700,height:500))
        let window = NSWindow(contentRect:pane.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:.aqua); window.contentView = pane
        defer { window.contentView = nil }
        var environment = TranscriptRowEnvironment(view:pane); environment.sessionID = session.id
        var called = false
        let actions = TranscriptActions(openSubagent:{ _ in called = true },inspectSubagent:{ _ in called = true },stopSubagent:{ _ in called = true })
        pane.update(session:session,state:"idle",actions:actions,environment:environment,reduceMotion:true)
        func checkHistory(_ color: TranscriptColorScheme) throws {
            pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
            XCTAssertEqual(pane.environment.colorScheme,color)
            XCTAssertEqual(pane.environment.sessionID,session.id)
            let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:pane).first)
            let buttons = ConversationPaneTests.views(PiKit.Button.self,in:card)
            let open = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "open-subagent" })
            XCTAssertEqual(open.title,"Open")
            XCTAssertEqual(open.accessibilityLabel(),SubagentToolView.historicalNotice)
            for id in ["open-subagent", "inspect-subagent", "stop-subagent"] {
                let button = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == id })
                XCTAssertTrue(button.isHidden || !button.isEnabled)
                button.onPress?()
            }
            XCTAssertFalse(called)
            // Historical navigation stays disabled; copying saved Markdown is
            // still a local reading action, including after appearance changes.
            let copies = buttons.filter { $0.accessibilityLabel()?.hasSuffix("as Markdown") == true }
            XCTAssertEqual(copies.count, 2)
            XCTAssertTrue(copies.allSatisfy(\.isEnabled))
            XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self,in:card).contains { $0.string.contains("From the original chat") })
        }
        try checkHistory(.light)
        for (appearance,color) in [(NSAppearance.Name.darkAqua,TranscriptColorScheme.dark),(.aqua,.light)] {
            window.appearance = NSAppearance(named:appearance)
            // Deliver AppKit's notification explicitly for this offscreen
            // window. No session update may restore the missing context.
            pane.viewDidChangeEffectiveAppearance()
            try checkHistory(color)
        }
    }

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
        XCTAssertEqual(buttons.first { $0.accessibilityIdentifier() == "open-subagent" }?.title,"Open")
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self,in:row).contains { $0.string.contains("From the original chat") })
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
        tool.subagentEffort = "high"
        let row = TranscriptNativeActionRow()
        row.update(tool: tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: nil)
        let card = try XCTUnwrap(row.card)
        for (key, value) in [("Model", "fixture"), ("Effort", "high"), ("Tools", "read · 1 completed"),
                             ("Requests", "2"), ("Time", "1s"), ("Cost", "$0.04"), ("Tokens", "100 input · 20 output")] {
            let label = try XCTUnwrap(ConversationPaneTests.views(PiKit.TextLine.self, in: card).first { $0.line.text == key })
            XCTAssertEqual(label.line.font, PiKit.Font.caption)
            let field = try XCTUnwrap(ConversationPaneTests.views(PiKit.SelectableText.self, in: card).first { $0.stringValue == value })
            XCTAssertEqual(field.font, PiKit.Font.caption)
            XCTAssertEqual(field.accessibilityLabel(), key)
        }
        let note = try XCTUnwrap(ConversationPaneTests.views(PiKit.WrappedText.self, in: card).first { $0.text == "1 request's cost unknown" })
        XCTAssertEqual(note.color, .piInkSecondary)
        let copies = ConversationPaneTests.views(PiKit.Button.self, in: card).filter { $0.title == "Copy" }
        XCTAssertEqual(copies.count, 2, "Only Task and Result have Copy actions")
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self, in: card).allSatisfy { !$0.string.contains("Reported") && !$0.string.contains("Model:") })
        XCTAssertEqual(SessionCostReading(limit: .usd(1), spentUSD: 0.04).figure, "$0.04 of $1.00")
        XCTAssertEqual(InspectorSubagentGroup(summary: tool.subagent!, requests: 2, cost: 0.04, costSamples: 2).detail, "Running · 2 requests · $0.04")
        var totals = GatewayTotals(); totals.requests = 2; totals.costSamples = 2; totals.costUSD = 0.04
        XCTAssertEqual(ChatRowStats(totals: totals).costLabel, "$0.04")
    }

    @MainActor func testCardDetailsOmitKnownCostCaveatAndWrapInNarrowPanes() throws {
        for unknown in [0, 2] {
            var tool = Self.tool
            tool.subagent = .init(link: Self.link, description: "Review", model: "fixture-model-with-a-long-name", status: .completed, revision: 1,
                tools: ["read", "grep", "find"], progress: .init(phase: "done", elapsedMs: 8000, requests: 2, tools: 3, preview: "",
                    usd: 0.002, reported: 1, unreported: unknown, inputTokens: 1800, outputTokens: 420))
            let card = TranscriptNativeSubagentCard(); card.configure(.subagent(SubagentToolView(tool)))
            let details = try XCTUnwrap(card.subviews.first { $0.accessibilityIdentifier() == "subagent-details" })
            let notes = ConversationPaneTests.views(PiKit.WrappedText.self, in: details).map(\.text)
            XCTAssertEqual(notes, unknown == 0 ? [] : ["2 requests' cost unknown"])
            XCTAssertFalse(ConversationPaneTests.views(PiKit.TextLine.self, in: details).contains { $0.line.text == "Effort" })
            XCTAssertTrue(ConversationPaneTests.views(PiKit.SelectableText.self, in: details).contains { $0.stringValue == compactGatewayUSD(0.002) })
            for width in [272.0, 500.0, 850.0] {
                card.frame = .init(x: 0, y: 0, width: width, height: card.plan(width: width).height)
                card.needsLayout = true; card.layoutSubtreeIfNeeded()
                for text in ConversationPaneTests.views(PiKit.SelectableText.self, in: details) {
                    XCTAssertTrue(details.bounds.contains(text.convert(text.bounds, to: details)), "Every value fits the grid at \(width)")
                    XCTAssertGreaterThanOrEqual(text.frame.height, text.height(forWidth: text.frame.width))
                    let label = try XCTUnwrap(ConversationPaneTests.views(PiKit.TextLine.self, in: details).first { $0.line.text == text.accessibilityLabel() })
                    let keyBaseline = label.convert(.zero, to: details).y + label.line.baseline(scale: label.piScale)
                    let valueBaseline = text.convert(.zero, to: details).y + text.firstBaselineOffsetFromTop
                    XCTAssertEqual(keyBaseline, valueBaseline, accuracy: 0.5, "\(label.line.text) aligns with its value's first line")
                }
            }
        }
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
