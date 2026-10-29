import AppKit
import XCTest
@testable import PiApp

private actor OriginalReaderBackGate {
    private(set) var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}

final class InheritedSubagentReaderTests: XCTestCase, SerialTestLane {
    @MainActor func testOriginalReaderLoadsAnchorBaselineBeforeSavingPendingPosition() async throws {
        let root = scratchRoot("original-anchor-baseline"), model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.prewarmsHelpers = false; model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        try await model.store?.putChats(model.chats); await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child)), store = try XCTUnwrap(model.store)
        var fork = model.chats[0]; fork.id = "fork"; fork.path = nil; model.chats.append(fork)
        await model.select(fork.id)
        let parent = try XCTUnwrap(model.selected)
        try await store.put(TranscriptAnchor(id: "terminal", offset: 17, followsBottom: false), kind: "anchor", id: child.id)
        let gate = DraftBaselineGate(expectation(description: "Original reader history held"))
        let blocker = Task { await model.history.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        let request = model.beginSubagentOpening(child.id); request.reader.originalForkID = fork.id
        defer { model.finishSubagentOpening(request) }
        let loading = Task { await model.openSubagentTab(child.id, opening: request) }
        try await eventually("Pending draft fixture did not settle") { model.displays[child.id] != nil }
        let view = try XCTUnwrap(model.displays[child.id])
        XCTAssertFalse(view.selectionMetadataLoaded)
        parent.draft = "Typing beside an original reader"; model.draftChanged(parent)
        view.scrollAnchor = nil; model.anchorChanged(view)
        XCTAssertNil(view.anchorWrite)
        gate.resume.signal(); await blocker.value; _ = await loading.value
        await view.anchorWrite?.value; await model.draftWrites.tasks[parent.id]?.value
        XCTAssertTrue(view.selectionMetadataLoaded)
        let saved = try await store.get(TranscriptAnchor.self, kind: "anchor", id: child.id)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: parent.id)
        XCTAssertNil(saved); XCTAssertEqual(draft?.text, parent.draft); XCTAssertTrue(parent.draftConflicts.isEmpty)
    }

    @MainActor func testColdOriginalReaderRefreshesCostWithoutReopeningOwnerOrChargingFork() async throws {
        for kind in AgentForkKind.allCases {
            let root = scratchRoot("original-cost-" + kind.rawValue), model = try SubagentOrganizationTests.fixture(root)
            registerWorkspaceFixtureTeardown(model,root:root)
            model.chats.remove(at:1)
            let family = try SubagentDiscoveryTests.family(model)
            try await model.store?.putChats(model.chats); await model.reconcileSubagents()
            let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0], link = try XCTUnwrap(child.delegation)
            model.observeCost(["cost":.object(["spentUSD":.number(0.25),"reportedRequests":.number(1),"accountingRevision":.number(1)])],sessionID:child.id)
            model.helperSessionDidUnload(child.id)
            let file = try FileHandle(forWritingTo:family.path); try file.seekToEnd()
            for (revision,amount) in [(1,0.25),(2,0.35)] {
                let data: WireValue = .object(["attemptId":.string("attempt-\(revision)"),"sourceSessionId":.string(child.id),"budgetOwnerSessionId":.string(parent.id),"delegationId":.string(link.delegationID),"usd":.number(amount),"reported":.number(1),"accountingRevision":.number(Double(revision))])
                let row: WireValue = .object(["type":.string("custom"),"customType":.string("pi-app.cost.v1"),"id":.string("cost-\(revision)"),"parentId":.string(revision == 1 ? "terminal" : "cost-1"),"data":data])
                try file.write(contentsOf:JSONEncoder().encode(row)); try file.write(contentsOf:Data([10]))
            }
            try file.close()
            var fork = parent; fork.id = "fork"; fork.path = nil; fork.parentSessionID = kind.parentID(parent.id)
            model.chats.append(fork)
            model.historyWindowLoader = { _,_,_,_ in
                try ConversationHistoryPage(.object(["version":.number(2),"incarnation":.string("fixture"),"lineage":.string("root"),"messages":.array([]),"older":.null,"newer":.null]))
            }
            await model.select(fork.id)
            let opened = await model.openOriginalSubagent(SubagentTarget(link),from:fork.id)
            XCTAssertTrue(opened)
            try await eventually("Original reader retained stale spending") { model.displays[child.id]?.footer.cost.spentUSD == 0.60 }
            XCTAssertEqual(model.costReading(for:child.id).reportedRequests,2)
            XCTAssertEqual(model.costReading(for:child.id).budgetOwnerID,parent.id)
            XCTAssertNil(model.costReading(for:fork.id).spentUSD)
            XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        }
    }

    @MainActor func testOrdinaryParentInspectorReopenClearsForkProvenance() async throws {
        for kind in AgentForkKind.allCases {
            let root = scratchRoot("inspector-original-context-" + kind.rawValue)
            let model = try SubagentOrganizationTests.fixture(root)
            registerWorkspaceFixtureTeardown(model, root: root)
            SessionInspectorWindows.shared.closeAll()
            defer { SessionInspectorWindows.shared.closeAll() }
            let parent = model.chats[0]
            var fork = parent; fork.id = kind.id; fork.title = "Fork"; fork.parentSessionID = kind.parentID(parent.id)
            model.chats.append(fork)
            model.historyWindowLoader = { _, _, _, around in
                try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                    "messages": .array([.object(["id": .string(around ?? "newer-reply"), "role": .string("assistant"), "text": .string("Original's newer response")])]),
                    "older": .null, "newer": .null]))
            }
            await model.select(fork.id)
            let controller = SessionInspectorWindows.shared.show(model: model, sessionID: parent.id, workspaceID: parent.workspaceID,
                title: parent.title, focus: .overview, originalForkID: fork.id)
            let inspector = controller.inspector
            XCTAssertEqual(inspector.originalForkID, fork.id)
            let request = inspector.request
            request.open(InspectorRequestRow(id: "new-request", wall: 1, turn: "newer-reply", purpose: "turn", api: "openai-responses",
                model: "fixture", outcome: "completed", source: .record), predecessor: nil, previousLabel: nil)
            let requestPage = InspectorRequestPage(inspector: inspector, request: request, compact: false)
            XCTAssertTrue(ConversationPaneTests.views(InspectorForkFromHere.self, in: requestPage).isEmpty)
            model.openInspector(session: parent.id, focus: .overview)
            XCTAssertTrue(SessionInspectorWindows.shared.controller(sessionID: parent.id) === controller)
            XCTAssertNil(inspector.originalForkID, "Ordinary reopening owns the original session again: " + kind.rawValue)
            requestPage.refresh()
            XCTAssertEqual(ConversationPaneTests.views(InspectorForkFromHere.self, in: requestPage).count, 1)
            inspector.select(.turn("newer-reply")); inspector.showInChat()
            try? await eventually("Ordinary Show in Chat reveals the original's newer request", timeout: .seconds(2)) {
                model.selectedID == parent.id && model.displays[parent.id]?.scrollAnchor?.id == "newer-reply"
            }
            XCTAssertTrue(model.hosts.isEmpty)
        }
    }

    @MainActor func testOriginalSourceKeepsAnAlreadySelectedForkInTheMainPane() async throws {
        for kind in AgentForkKind.allCases {
            for rememberedSide in [false, true] {
                let root = scratchRoot("original-source-" + kind.rawValue), model = try SubagentOrganizationTests.fixture(root)
                registerWorkspaceFixtureTeardown(model, root: root)
                model.chats.remove(at: 1)
                let family = try SubagentDiscoveryTests.family(model)
                try await model.store?.putChats(model.chats); await model.reconcileSubagents()
                let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0]
                var fork = parent; fork.id = "fork"; fork.path = nil; fork.parentSessionID = kind.parentID(parent.id)
                model.chats.append(fork)
                let link = try XCTUnwrap(child.delegation)
                model.historyWindowLoader = { _, _, _, around in
                    try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                        "messages": .array([.object(["id": .string(around ?? "latest"), "role": .string("assistant"), "text": .string("Saved reply")])]),
                        "older": .null, "newer": .null]))
                }
                await model.select(fork.id)
                let display = try XCTUnwrap(model.displays[fork.id])
                display.messages = [.init(id: link.call.assistantMessageID, role: "assistant", text: "Copied call")]
                display.historyState = .ready
                if rememberedSide && kind == .fromReply {
                    model.sides[parent.id] = .init(id: fork.id, parentID: parent.id, workspaceID: fork.workspaceID,
                                                  profileID: fork.profileID, title: fork.title, kept: true)
                }
                let opened = await model.openOriginalSubagent(SubagentTarget(link), from: fork.id)
                XCTAssertTrue(opened)
                let tab = try XCTUnwrap(model.subagentTab(child.id))
                let returned = await model.openSubagentParent(link, origin: tab.renewNavigation())
                XCTAssertTrue(returned, kind.rawValue)
                XCTAssertEqual(model.selectedID, fork.id, kind.rawValue)
                XCTAssertEqual(display.scrollAnchor?.id, link.call.assistantMessageID)
                XCTAssertTrue(model.subagentTabIsShown(child.id), "Source keeps the embedded reader beside the visible fork")
            }
        }
    }
    @MainActor func testOriginalTargetLookupKeepsReaderOwnershipAcrossBackHideAndMainFocus() async throws {
        for kind in AgentForkKind.allCases {
            for action in ["back", "hide", "main focus", "popped report"] {
                let root = scratchRoot("original-lookup-" + kind.rawValue), model = try SubagentOrganizationTests.fixture(root)
                registerWorkspaceFixtureTeardown(model, root: root)
                model.chats.remove(at: 1)
                let family = try SubagentDiscoveryTests.family(model)
                try await model.store?.putChats(model.chats); await model.reconcileSubagents()
                let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0]
                var fork = parent; fork.id = "fork"; fork.path = nil; fork.parentSessionID = kind.parentID(parent.id)
                model.chats.append(fork)
                model.historyWindowLoader = { _, _, _, around in
                    try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                        "messages": .array([.object(["id": .string(around ?? "latest"), "role": .string("assistant"), "text": .string("Saved reply")])]),
                        "older": .null, "newer": .null]))
                }
                await model.select(fork.id)
                var target = SubagentTarget(try XCTUnwrap(child.delegation))
                let initial = await model.openOriginalSubagent(target, from: fork.id)
                XCTAssertTrue(initial)
                let tab = try XCTUnwrap(model.subagentTab(child.id))
                model.tabs.showsWindows = false
                if action == "popped report" { _ = model.tabs.popOut(tab) }
                let gate = OriginalReaderBackGate()
                model.subagentTurnMessageLoader = { _, _, _, _ in await gate.wait(); return "follow-up" }
                target.turn = 2
                let opening = Task { [target] in await model.openOriginalSubagent(target, from: fork.id) }
                try await eventually("Original target lookup awaits its saved turn") { await gate.entered }
                let view = try XCTUnwrap(model.displays[child.id]), anchor = view.scrollAnchor, token = tab.navigation
                if action == "back" { await model.backToSubagentParent(child.id) }
                else if action == "hide" { _ = model.tabs.open(kind: HostedTab.kind, key: "file") { HostedTab(key: "file", title: "File", symbol: "doc") } }
                else if action == "main focus" { model.focusPane(fork.id) }
                else { model.page = .report; model.focusPane(fork.id) }
                await gate.release()
                let opened = await opening.value
                let retired = action == "back" || action == "hide"
                XCTAssertEqual(opened, !retired, kind.rawValue + "/" + action)
                XCTAssertEqual(token.isCurrent, !retired)
                if retired { XCTAssertEqual(view.scrollAnchor, anchor) }
                else { XCTAssertEqual(view.scrollAnchor?.id, "follow-up"); XCTAssertEqual(model.focusedSessionID, fork.id) }
                if action == "popped report" { XCTAssertEqual(model.page, .report) }
            }
        }
    }
    @MainActor func testCopiedFollowUpAndSteeringTargetsOpenTheOriginalAtTheirSavedDestination() async throws {
        for kind in AgentForkKind.allCases {
            for route in ["turn", "event", "message", "explicit"] {
                let root = scratchRoot("original-target-" + kind.rawValue)
                let model = try SubagentOrganizationTests.fixture(root)
                registerWorkspaceFixtureTeardown(model, root: root)
                model.chats.remove(at: 1)
                let family = try SubagentDiscoveryTests.family(model)
                try await model.store?.putChats(model.chats); await model.reconcileSubagents()
                let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0]
                let source = URL(fileURLWithPath: parent.path!), forkPath = source.deletingLastPathComponent().appendingPathComponent("fork.jsonl")
                try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "\"id\":\"chat-parent\"", with: "\"id\":\"fork\"").write(to: forkPath, atomically: true, encoding: .utf8)
                var fork = parent; fork.id = "fork"; fork.path = forkPath.path; fork.parentSessionID = kind.parentID(parent.id)
                model.chats.append(fork)
                let file = try FileHandle(forWritingTo: family.path); try file.seekToEnd()
                for (id, turn, event) in [("first-task", 1, "first"), ("follow-up", 2, "follow"), ("steering", 2, "steer-event")] {
                    let row: WireValue = .object(["type": .string("message"), "id": .string(id), "message": .object([
                        "nativeAgentDelivery": .object(["childId": .string(child.id), "turn": .number(Double(turn)), "eventIds": .array([.string(event)])])])])
                    try file.write(contentsOf: JSONEncoder().encode(row) + Data([10]))
                }
                try file.close()
                let before = try [Data(contentsOf: source), Data(contentsOf: family.path)]
                model.historyWindowLoader = { _, _, _, around in
                    try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                        "messages": .array([.object(["id": .string(around ?? "latest"), "role": .string("assistant"), "text": .string("Saved reply")])]),
                        "older": .null, "newer": .null]))
                }
                await model.select(fork.id)
                var target = SubagentTarget(try XCTUnwrap(child.delegation)); target.turn = 2
                if route != "turn" { target.messageID = route == "message" ? "steering" : "steer-event" }
                let expected = route == "turn" ? "follow-up" : route == "explicit" ? "answer" : "steering"
                let opened = await model.openOriginalSubagent(target, from: fork.id, sourceMessage: route == "explicit" ? "answer" : nil)
                XCTAssertTrue(opened, kind.rawValue + "/" + route)
                XCTAssertEqual(model.displays[child.id]?.scrollAnchor?.id, expected, kind.rawValue + "/" + route)
                XCTAssertTrue(model.isOriginalSubagentReader(child.id)); XCTAssertTrue(model.hosts.isEmpty)
                XCTAssertEqual(try [Data(contentsOf: source), Data(contentsOf: family.path)], before)
            }
        }
    }
    @MainActor func testOriginalWindowBackRestoresChatsForTheAlreadySelectedFork() async throws {
        for kind in AgentForkKind.allCases { try await checkOriginalWindowBackRestoresChatsForTheAlreadySelectedFork(kind) }
    }
    @MainActor private func checkOriginalWindowBackRestoresChatsForTheAlreadySelectedFork(_ kind: AgentForkKind) async throws {
        let root = scratchRoot("original-reader-back-page")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        var fork = model.chats[0]; fork.id = "fork"; fork.title = "Independent fork"; fork.parentSessionID = kind.parentID(model.chats[0].id)
        model.chats.append(fork)
        let display = SessionDisplay(id: fork.id); display.historyState = .ready; display.draftReady = true
        display.messages = [.init(id: "reading", role: "assistant", text: "The fork's response")]
        display.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
        model.displays[fork.id] = display; model.selectedID = fork.id; model.selected = display
        model.tabs.showsWindows = false
        let tab = model.tabs.open(kind: SubagentTab.kind, key: "chat-child") {
            let reader = SubagentTab(childID: "chat-child"); reader.originalForkID = fork.id; return reader
        } as! SubagentTab
        let container = model.tabs.popOut(tab)
        for reports in [true, false] {
            model.page = reports ? .report : .background
            tab.focus()
            let old = tab.navigation, anchor = display.scrollAnchor, generation = display.presentationGeneration
            await model.backToSubagentParent(tab.key)
            XCTAssertEqual(model.page, .chats)
            XCTAssertEqual(model.selectedID, fork.id)
            XCTAssertEqual(model.focusedSessionID, fork.id)
            XCTAssertFalse(old.isCurrent)
            XCTAssertEqual(display.scrollAnchor, anchor, "Back preserves the fork's reading position")
            XCTAssertEqual(display.presentationGeneration, generation, "A visible ready fork needs no reload")
            XCTAssertTrue(tab.container === container)
            XCTAssertTrue(model.subagentTabIsShown(tab.key))
        }
    }
    @MainActor func testForkCardAndPickerOpenOriginalReadOnlyWithoutWritingSource() async throws {
        for kind in AgentForkKind.allCases { try await checkForkCardAndPickerOpenOriginalReadOnlyWithoutWritingSource(kind) }
    }
    @MainActor private func checkForkCardAndPickerOpenOriginalReadOnlyWithoutWritingSource(_ kind: AgentForkKind) async throws {
        let root = scratchRoot("fork-original-reader")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.chats.remove(at: 1)
        let family = try SubagentDiscoveryTests.family(model)
        try await model.store?.putChats(model.chats)
        await model.reconcileSubagents()
        let child = try XCTUnwrap(model.record(family.child)), parent = model.chats[0]
        let source = URL(fileURLWithPath: parent.path!)
        let before = try [Data(contentsOf: source), Data(contentsOf: family.path)]
        let path = source.deletingLastPathComponent().appendingPathComponent("fork.jsonl")
        try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "\"id\":\"chat-parent\"", with: "\"id\":\"fork\"").write(to: path, atomically: true, encoding: .utf8)
        var fork = parent; fork.id = "fork"; fork.title = "Independent fork"; fork.path = path.path; fork.parentSessionID = kind.parentID(parent.id)
        model.chats.append(fork)
        var tool = SubagentTranscriptTests.tool
        var fields = SubagentTranscriptTests.metadata.object!; fields["sessionId"] = .string(child.id); tool.nativeSubagent = .object(fields)
        let savedTool = tool
        model.historyWindowLoader = { id, _, _, _ in
            var page = try ConversationHistoryPage(.object(["version":.number(2), "incarnation":.string(id), "lineage":.string("root"), "messages":.array([]), "older":.null, "newer":.null]))
            page.messages = id == "fork" ? [.init(id:"reply", role:"assistant", text:"Copied review", tools:[savedTool])] : [.init(id:"answer", role:"assistant", text:"Original saved reply")]
            return page
        }
        await model.select(fork.id)
        let display = try XCTUnwrap(model.displays[fork.id]); display.disclosure.setOpen(true, .work("legacy:reply"))
        display.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply",tool.id)))
        let pane = NativeTranscriptPane(frame:.init(x:0,y:0,width:700,height:500))
        pane.page.presentationInterval = 0
        pane.showTranscript(model:model, session:display, state:"idle", canFork:true, canQuote:true, enabled:true)
        pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
        model.historyViewportReady(fork.id, generation: display.presentationGeneration)
        await display.presentation.inheritedPlanRead?.value
        pane.showTranscript(model:model, session:display, state:"idle", canFork:true, canQuote:true, enabled:true)
        pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:pane).first)
        let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:card).first { $0.accessibilityIdentifier() == "open-subagent" })
        XCTAssertEqual(model.inheritedSubagents[fork.id]?.count,1)
        XCTAssertTrue(model.conversationFamily(fork.id).canAddSide, "A fork's own family picker retains New Side")
        XCTAssertNil(model.originalAvailability(SubagentTarget(child.delegation!)).reason)
        XCTAssertNotNil(display.originalSubagentAvailability[child.id])
        XCTAssertEqual(open.title,"Open"); XCTAssertTrue(open.isEnabled, open.toolTip ?? "no tooltip")
        guard open.isEnabled else { return }
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self,in:card).contains { $0.string.contains("From the original chat") })
        open.onPress?()
        try await eventually("Fork card opens the original reader") { model.subagentTab(child.id) != nil }
        let tab = try XCTUnwrap(model.subagentTab(child.id)); await tab.loading?.value
        XCTAssertEqual(model.selectedID,fork.id)
        XCTAssertTrue(tab.title.contains("From the original chat · " + parent.title))
        XCTAssertTrue(tab.stripTitle.contains("From the original chat"))
        let backButton = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:tab.contentView).first { $0.accessibilityIdentifier() == "back-to-subagent-parent" })
        XCTAssertEqual(backButton.title, "Back to " + fork.title)
        XCTAssertTrue(backButton.toolTip?.contains(fork.title) == true)
        XCTAssertTrue(backButton.accessibilityLabel()?.contains(fork.title) == true)
        let forkIndex = try XCTUnwrap(model.chats.firstIndex { $0.id == fork.id })
        model.chats[forkIndex].title = "Renamed fork"
        tab.pane?.refresh()
        XCTAssertEqual(backButton.title, "Back to Renamed fork", "Destination labels follow renames without reloading the child")
        model.chats[forkIndex].title = fork.title; tab.pane?.refresh()

        XCTAssertEqual(model.displays[child.id]?.messages.first?.text,"Original saved reply")
        let inspect = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:card).first { $0.accessibilityIdentifier() == "inspect-subagent" })
        inspect.onPress?(); XCTAssertEqual(model.lastInspectorFocus,.subagent(child.delegation!.delegationID))
        XCTAssertTrue(model.isOriginalSubagentReader(child.id))
        XCTAssertFalse(model.canStopConversation)
        do { _ = try await model.open(child); XCTFail("A reference reader cannot attach a writable helper") } catch { }
        model.displays[child.id]?.draft = "Cannot send"
        model.send(sessionID: child.id); model.send(steer:true,sessionID:child.id); model.stop(sessionID:child.id)
        model.action("turn.stop",sessionID:child.id); model.action("queue.resume",sessionID:child.id)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertFalse(model.displays[child.id]?.loading == true)
        let restored = try XCTUnwrap(SubagentTab.restore(key:child.id,state:tab.savedState()) as? SubagentTab)
        XCTAssertEqual(restored.originalForkID,fork.id)
        model.tabs.showsWindows = false
        let external = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of:external))
        _ = tab.contentView; tab.focus()
        model.conversationWindow = { window }
        let menus = ApplicationMenus(model:model,updates:UpdateController(),workspaceWindow:{nil},revealWorkspace:{},showSettings:{})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }; menus.install()
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Conversation" }?.submenu)
        for title in ["Stop", "Send / Queue Follow-up", "Send / Steer Current Run", "Resume", "Resume Follow-ups", "Compact Now"] {
            XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(menu.items.first { $0.title == title })),title)
        }
        for title in ["Find…", "Search and Copy Conversation…"] {
            XCTAssertTrue(menus.validateMenuItem(try XCTUnwrap(menu.items.first { $0.title == title })),title)
        }
        XCTAssertTrue(tab.pane?.composer.isHidden == true)
        XCTAssertFalse(ConversationPaneTests.views(PiKit.Button.self,in:tab.contentView).contains { $0.title == "Stop" && !$0.isHidden && $0.isEnabled })
        // Back is still a reader-owned navigation when the fork needs loading.
        await model.select(parent.id, focusesComposer: false)
        display.historyState = .dormant; display.presentation.identity = nil
        let gate = OriginalReaderBackGate(), originalLoader = try XCTUnwrap(model.historyWindowLoader), forkID = fork.id
        model.historyWindowLoader = { id, cursor, newer, around in
            if id == forkID { await gate.wait() }
            return try await originalLoader(id, cursor, newer, around)
        }
        let back = Task { await model.backToSubagentParent(child.id) }
        try await eventually("Original-reader Back is loading its fork") { await gate.entered }
        await model.select(parent.id, focusesComposer: false)
        await gate.release(); await back.value
        XCTAssertEqual(model.focusedSessionID, parent.id, "Retired Back cannot refocus the fork after a newer selection")
        model.historyWindowLoader = originalLoader
        await model.select(fork.id, focusesComposer: false)
        model.tabs.close(tab)
        _ = model.tabs.open(kind:SubagentTab.kind,key:child.id) { restored }
        await restored.loading?.value
        XCTAssertTrue(model.isOriginalSubagentReader(child.id)); XCTAssertTrue(model.hosts.isEmpty)
        model.tabs.close(restored)
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID:parent.id)?.inspector)
        XCTAssertEqual(inspector.originalForkID,fork.id)
        inspector.reveal(model,child.id,nil)
        try await eventually("Inspector retains original-read-only provenance after the tab closes") { model.isOriginalSubagentReader(child.id) }
        await model.subagentTab(child.id)?.loading?.value
        if let shown = model.subagentTab(child.id) { model.tabs.close(shown) }
        let picker = AgentFamilyPopoverView(model:model,sessionID:fork.id,close:{},ownerWindow:nil)
        let rows = ConversationPaneTests.views(FamilyPickerRow.self,in:picker)
        let row = try XCTUnwrap(rows.first { $0.primary.contains("Parser review") })
        row.onPress?()
        try await eventually("Fork picker opens original") { model.subagentTab(child.id) != nil }
        await model.subagentTab(child.id)?.loading?.value
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        XCTAssertFalse(ConversationPaneTests.views(PiKit.IconButton.self,in:picker).contains { $0.accessibilityIdentifier().hasPrefix("stop-agent-") })
        display.disclosure.setOpen(true, .work("reply"))
        display.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", tool.id)))
        // Missing and untrusted originals remain labelled, with inert actions.
        for missing in ["project", "folder", "trust", "parent", "child", "file"] {
            let records = model.chats, projects = model.workspaces
            if missing == "project" { model.workspaces = [] }
            if missing == "folder" { model.workspaces[0].path += "/unavailable-original-project" }
            if missing == "trust" { model.workspaces[0].trusted = false }
            if missing == "parent" { model.chats.removeAll { $0.id == parent.id } }
            if missing == "child" { model.chats.removeAll { $0.id == child.id } }
            if missing == "file" { try FileManager.default.removeItem(at:family.path); model.refreshOriginalAvailability() }
            XCTAssertNotNil(model.originalAvailability(SubagentTarget(child.delegation!)).reason,missing)
            pane.showTranscript(model:model,session:display,state:"idle",canFork:true,canQuote:true,enabled:true)
            pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded()
            let missingCard = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:pane).first)
            let unavailableOpen = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:missingCard).first { $0.accessibilityIdentifier() == "open-subagent" })
            XCTAssertFalse(unavailableOpen.isEnabled,missing)
            XCTAssertTrue(unavailableOpen.toolTip?.contains("unavailable") == true || unavailableOpen.toolTip?.contains("trusted") == true,missing)
            let unavailable = AgentFamilyPopoverView(model:model,sessionID:fork.id,close:{},ownerWindow:nil)
            let missingRow = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self,in:unavailable).first { $0.accessibilityIdentifier().hasPrefix("open-original-") })
            XCTAssertFalse(missingRow.isEnabled,missing); XCTAssertNotNil(missingRow.secondary)
            let opened = await model.openOriginalSubagent(SubagentTarget(child.delegation!),from:fork.id)
            XCTAssertFalse(opened,missing)
            if missing == "file" { try before[1].write(to:family.path) }
            model.chats = records; model.workspaces = projects
        }
        XCTAssertEqual(try [Data(contentsOf:source),Data(contentsOf:family.path)],before)
    }
}
