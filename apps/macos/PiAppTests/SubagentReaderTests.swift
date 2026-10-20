import AppKit
import XCTest
@testable import PiApp

private actor ChildHistoryGate {
    var text = "Saved child reply"
    var messageID = "saved-reply"
    var held = false
    private(set) var reads = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func set(_ text: String, held: Bool = false, messageID: String = "saved-reply") { self.text = text; self.held = held; self.messageID = messageID }
    func release() { held = false; waiting.forEach { $0.resume() }; waiting = [] }
    func page() async throws -> ConversationHistoryPage {
        reads += 1
        if held { await withCheckedContinuation { waiting.append($0) } }
        return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string(messageID), "role": .string("assistant"), "text": .string(text)])]),
            "older": .null, "newer": .null]))
    }
}

private actor ReaderLookupGate {
    private(set) var reads = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { reads += 1; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}

final class SubagentReaderTests: XCTestCase, SerialTestLane {
    @MainActor func testPendingReaderBaselineDefersAnchorAndKeepsParentTyping() async throws {
        let (model, _) = try fixture(), store = try XCTUnwrap(model.store)
        model.prewarmsHelpers = false
        let parent = try XCTUnwrap(model.selected), child = try XCTUnwrap(model.displays["chat-child"])
        _ = try await model.reconcileSubmissionDraft(try XCTUnwrap(model.record(parent.id)), view: parent, current: { true })
        try await store.put(TranscriptAnchor(id: "saved-reply", offset: 17, followsBottom: false), kind: "anchor", id: child.id)
        let gate = DraftBaselineGate(expectation(description: "Reader metadata held"))
        let blocker = Task { await store.holdDraftBaseline(gate) }
        await fulfillment(of: [gate.entered], timeout: 3)
        defer { gate.resume.signal() }
        let opening = Task { await model.openSubagentTab(child.id) }
        try await eventually("Pending draft fixture did not settle") { model.subagentTab(child.id)?.loading != nil }
        XCTAssertFalse(child.selectionMetadataLoaded)
        parent.draft = "Typing beside the reader"; model.draftChanged(parent)
        child.scrollAnchor = nil; model.anchorChanged(child)
        XCTAssertNil(child.anchorWrite, "No versioned anchor write before its baseline")
        gate.resume.signal(); await blocker.value; _ = await opening.value
        await parent.anchorWrite?.value; await child.anchorWrite?.value
        await model.draftWrites.tasks[parent.id]?.value
        XCTAssertTrue(child.selectionMetadataLoaded)
        let anchor = try await store.get(TranscriptAnchor.self, kind: "anchor", id: child.id)
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: parent.id)
        let childDraft = try await store.get(DraftRecord.self, kind: "draft", id: child.id)
        XCTAssertNil(anchor); XCTAssertNil(childDraft, "Managed readers never gain a composer")
        XCTAssertEqual(draft?.text, parent.draft)
        XCTAssertTrue(parent.draftConflicts.isEmpty)
    }

    @MainActor func testSupersededReloadCannotInheritANewerReveal() async throws {
        for hosted in [false, true] {
            for around in [nil, "obsolete-target"] as [String?] {
                let (model, gate) = try fixture()
                defer { Task { await gate.release() } }
                let id: String
                if hosted {
                    let tab = try await open("chat-child", in: model)
                    await tab.loading?.value; id = tab.key
                } else { id = "chat-parent" }
                let view = try XCTUnwrap(model.displays[id])
                view.messages = [.init(id: "held", role: "assistant", text: "The reader's destination")]
                view.historyState = .ready; view.draftReady = true
                await gate.set("Obsolete destination", held: true, messageID: around ?? "latest")
                model.historyWindowLoader = { _, _, _, target in
                    let page = try await gate.page()
                    if target == "held" {
                        return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                            "messages": .array([.object(["id": .string("held"), "role": .string("assistant"), "text": .string("The reader's destination")])]), "older": .null, "newer": .null]))
                    }
                    return page
                }
                let before = await gate.reads
                model.reloadHistory(id, around: around)
                let read = view.presentation.navigation
                try await eventually("Reload is held before the newer reveal") { await gate.reads > before }
                let revealed = hosted
                    ? await model.revealInTranscript(sessionID: id, messageID: "held")
                    : await model.revealMessage(sessionID: id, messageID: "held")
                XCTAssertTrue(revealed)
                let navigation = model.transcriptNavigation(id)
                await gate.release(); await read?.value
                try await eventually("The reader finishes recovery") {
                    view.historyState != .loading && view.historyState != .dormant && view.presentation.navigation == nil && model.subagentTab(id)?.loading == nil
                }
                XCTAssertEqual(view.messages.map(\.id), ["held"], "A superseded reload cannot replace the newer destination (hosted=\(hosted), around=\(around ?? "Latest"))")
                XCTAssertEqual(view.scrollAnchor?.id, "held")
                XCTAssertTrue(navigation.isCurrent(in: model))
                XCTAssertNotEqual(view.historyState, .loading)
                XCTAssertNotEqual(view.historyState, .dormant)
                model.shutdown()
            }
        }
    }

    @MainActor func testRuntimeReplacementPreservesMountedChildSelection() async throws {
        let (model, _) = try fixture(), tab = try await open("chat-child", in: model)
        await tab.loading?.value
        let view = try XCTUnwrap(model.displays[tab.key])
        view.messages = [.init(id: "saved-reply", role: "assistant", text: "Saved child reply", thinking: "Retained reasoning")]
        view.historyState = .ready; view.browsingHistory = true; view.snapshotEpoch = "first-runtime"
        view.disclosure.setOpen(true, .reasoning("saved-reply"))
        let pane = tab.makeAppKitContent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let transcript = try XCTUnwrap(ConversationPaneTests.views(NativeTranscriptPane.self, in: pane).first)
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let editor = try XCTUnwrap(ConversationPaneTests.views(MarkdownTextView.self, in: transcript).first { $0.string.contains("Saved child reply") })
        let selection = (editor.string as NSString).range(of: "child reply")
        window.makeFirstResponder(editor); editor.setSelectedRange(selection)
        view.scrollAnchor = .init(id: "saved-reply", offset: 19, followsBottom: false)
        let generation = view.presentationGeneration, anchor = view.scrollAnchor
        XCTAssertTrue(view.adoptSnapshotEpoch("follow-up-runtime"))
        transcript.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let retained = ConversationPaneTests.views(MarkdownTextView.self, in: transcript).first { $0.string.contains("Saved child reply") }
        XCTAssertEqual(view.presentationGeneration, generation, "Retiring runtime reads must not replace the mounted presentation")
        XCTAssertTrue(retained === editor, "The selected native text view remains mounted")
        XCTAssertEqual(retained?.selectedRange(), selection)
        XCTAssertEqual(view.scrollAnchor?.id, anchor?.id); XCTAssertEqual(view.scrollAnchor?.offset, anchor?.offset)
        XCTAssertTrue(view.disclosure.isOpen(.reasoning("saved-reply")))
        XCTAssertEqual(view.historyState, .ready)
    }

    @MainActor private func fixture() throws -> (WorkspaceModel, ChildHistoryGate) {
        let root = scratchRoot("subagent-reader")
        let model = try SubagentOrganizationTests.fixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        let gate = ChildHistoryGate()
        model.historyWindowLoader = { _, _, _, _ in try await gate.page() }
        for chat in model.chats {
            let view = SessionDisplay(id: chat.id); view.historyState = .ready; view.draftReady = true
            model.displays[chat.id] = view
        }
        model.chats[1].subagentNumber = 2
        model.selectedID = "chat-parent"; model.selected = model.displays["chat-parent"]; model.focusedSessionID = "chat-parent"
        return (model, gate)
    }
    @MainActor private func open(_ id: String, in model: WorkspaceModel) async throws -> SubagentTab {
        let tab = await model.openSubagentTab(id); return try XCTUnwrap(tab)
    }
    @MainActor private func otherTab(_ model: WorkspaceModel) -> HostedTab {
        model.tabs.open(kind: HostedTab.kind, key: "other") { HostedTab(key: "other", title: "Other reader", symbol: "doc") }
    }
    @MainActor func testAnOwnedAgentKeepsItsAlreadySelectedForkInTheMainColumn() async throws {
        for kind in AgentForkKind.allCases {
            for remembered in [false, true] {
                let (model, _) = try fixture()
                var fork = model.chats[0]; fork.id = kind.id; fork.title = "Fork"; fork.parentSessionID = kind.parentID("chat-parent")
                model.chats.append(fork)
                model.chats[1].parentSessionID = fork.id
                model.chats[1].delegation?.budgetOwnerSessionID = fork.id
                model.chats[1].delegation?.call.parentSessionID = fork.id
                await model.select(fork.id)
                let view = try XCTUnwrap(model.selected)
                view.messages = [.init(id: "reading", role: "assistant", text: "Keep this fork here")]
                view.scrollAnchor = .init(id: "reading", offset: 17, followsBottom: false)
                if remembered {
                    model.sides["chat-parent"] = .init(id: fork.id, parentID: "chat-parent", workspaceID: fork.workspaceID,
                        profileID: fork.profileID, title: fork.title, kept: true)
                }
                let revision = model.selectionRevision, anchor = view.scrollAnchor
                let tab = try await open("chat-child", in: model)
                XCTAssertEqual(model.selectedID, fork.id, kind.rawValue)
                XCTAssertTrue(model.selected === view)
                XCTAssertEqual(model.selectionRevision, revision, "Opening cannot move an already-visible owner into its ancestor's side slot")
                XCTAssertEqual(view.scrollAnchor, anchor)
                XCTAssertTrue(model.subagentTabIsShown(tab.key))
                XCTAssertNil(model.sides[fork.id])
            }
        }
    }
    @MainActor func testSourceFromAChildWindowKeepsItsAlreadySelectedForkInTheMainColumn() async throws {
        for kind in AgentForkKind.allCases {
            for remembered in [false, true] {
                let (model, _) = try fixture()
                let tab = try await open("chat-child", in: model)
                model.tabs.showsWindows = false; let container = model.tabs.popOut(tab)
                var fork = model.chats[0]; fork.id = kind.id; fork.title = "Fork"; fork.parentSessionID = kind.parentID("chat-parent")
                model.chats.append(fork)
                model.chats[1].parentSessionID = fork.id
                model.chats[1].delegation?.budgetOwnerSessionID = fork.id
                model.chats[1].delegation?.call.parentSessionID = fork.id
                await model.select(fork.id)
                let view = try XCTUnwrap(model.selected), link = try XCTUnwrap(model.record(tab.key)?.delegation)
                view.messages = [.init(id: link.call.assistantMessageID, role: "assistant", text: "The fork's issuing call")]
                view.scrollAnchor = .init(id: "reading", offset: 17, followsBottom: false)
                if remembered {
                    model.sides["chat-parent"] = .init(id: fork.id, parentID: "chat-parent", workspaceID: fork.workspaceID,
                        profileID: fork.profileID, title: fork.title, kept: true)
                }
                let revision = model.selectionRevision
                let revealed = await model.openSubagentParent(link, origin: tab.renewNavigation())
                XCTAssertTrue(revealed, kind.rawValue)
                XCTAssertEqual(model.selectedID, fork.id, kind.rawValue)
                XCTAssertTrue(model.selected === view)
                XCTAssertEqual(model.selectionRevision, revision)
                XCTAssertEqual(view.scrollAnchor?.id, link.call.assistantMessageID)
                XCTAssertTrue(model.subagentTabIsShown(tab.key)); XCTAssertTrue(tab.container === container)
            }
        }
    }

    @MainActor func testEarlierChildTurnOpeningSurvivesMainFocusDuringEveryRead() async throws {
        for stage in ["presentation", "turn lookup", "reveal"] {
            let (model, _) = try fixture()
            model.chats.remove(at: 1)
            let family = try SubagentDiscoveryTests.family(model)
            await model.reconcileSubagents()
            let child = try XCTUnwrap(model.record(family.child))
            let delivery: WireValue = .object(["type": .string("message"), "id": .string("earlier-task"),
                "message": .object(["nativeAgentDelivery": .object(["childId": .string(child.id), "turn": .number(1)])])])
            let file = try FileHandle(forWritingTo: family.path)
            try file.seekToEnd(); try file.write(contentsOf: JSONEncoder().encode(delivery) + Data([10])); try file.close()
            let tab = try await open(child.id, in: model)
            model.tabs.showsWindows = false
            let container = model.tabs.popOut(tab)
            let mainWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            mainWindow.isReleasedWhenClosed = false
            defer { mainWindow.close() }
            let display = try XCTUnwrap(model.displays[child.id])
            display.historyRevision = nil
            display.scrollAnchor = nil
            let gate = ReaderLookupGate(), history = model.history
            model.historyWindowLoader = { _, _, _, around in
                if stage == "presentation" && around == nil || stage == "reveal" && around == "earlier-task" { await gate.wait() }
                return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                    "messages": .array([.object(["id": .string(around ?? "latest"), "role": .string("assistant"), "text": .string("Saved reply")])]),
                    "older": .null, "newer": .null]))
            }
            model.subagentTurnMessageLoader = { path, child, turn, message in
                if stage == "turn lookup" { await gate.wait() }
                return try await history.subagentTurnMessage(path: path, childID: child, turn: turn, messageID: message)
            }
            var target = SubagentTarget(try XCTUnwrap(child.delegation)); target.turn = 1
            let opening = Task { [target] in await model.openSubagent(target) }
            try await eventually("Earlier-turn open awaits \(stage)") { await gate.reads == 1 }
            let token = tab.navigation
            mainWindow.makeKeyAndOrderFront(nil)
            model.focusPane("chat-parent")
            let keyWindow = NSApp.keyWindow
            XCTAssertTrue(token.isCurrent, "Focus does not retire the independent reader")
            await gate.release()
            let opened = await opening.value
            XCTAssertTrue(opened, stage)
            XCTAssertEqual(display.scrollAnchor?.id, "earlier-task", stage)
            XCTAssertEqual(model.focusedSessionID, "chat-parent", "Publishing must not refocus the child: " + stage)
            XCTAssertTrue(NSApp.keyWindow === keyWindow, "Publishing must not change the key window: " + stage)
            XCTAssertTrue(tab.container === container)
            XCTAssertTrue(model.subagentTabIsShown(child.id))
        }
    }
    @MainActor func testChildSourceDestinationIgnoresFocusChangesDuringParentReads() async throws {
        for route in ["issuing call", "delivery", "initial delivery"] {
            let (model, _) = try fixture()
            let tab = try await open("chat-child", in: model)
            model.tabs.showsWindows = false; _ = model.tabs.popOut(tab)
            let parent = try XCTUnwrap(model.selected), link = try XCTUnwrap(model.record(tab.key)?.delegation)
            parent.messages = [.init(id: "reading", role: "assistant", text: "Keep reading")]
            parent.scrollAnchor = nil
            parent.historyRevision = nil
            if route != "delivery" { parent.historyState = .dormant }
            if route == "initial delivery" {
                var other = try XCTUnwrap(model.record(parent.id)); other.id = "other-main"
                model.chats.append(other)
                let otherView = SessionDisplay(id: other.id); otherView.historyState = .ready
                model.displays[other.id] = otherView; model.selectedID = other.id; model.selected = otherView
            }
            let gate = ReaderLookupGate()
            model.historyWindowLoader = { _, _, _, _ in
                await gate.wait()
                return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                    "messages": .array([.object(["id": .string(link.call.assistantMessageID), "role": .string("assistant"), "text": .string("Issuing call")])]),
                    "older": .null, "newer": .null]))
            }
            let origin = tab.renewNavigation()
            let reveal = Task {
                if route == "issuing call" { return await model.openSubagentParent(link, origin: origin) }
                return await model.revealMessage(sessionID: parent.id, messageID: link.call.assistantMessageID, origin: origin)
            }
            try await eventually("Source awaits its parent's \(route) history") { await gate.reads == 1 }
            tab.focus()
            XCTAssertTrue(origin.isCurrent)
            await gate.release()
            let revealed = await reveal.value
            XCTAssertTrue(revealed, route)
            XCTAssertEqual(parent.scrollAnchor?.id, link.call.assistantMessageID, route)
            XCTAssertEqual(model.focusedSessionID, tab.key, "A completed read never refocuses its destination")
        }
    }
    @MainActor func testVisibilityRecoveryDoesNotReplaceAnInMemoryPresentation() async throws {
        let (model, gate) = try fixture()
        let display = SessionDisplay(id: "chat-parent")
        display.messages = [.init(id: "in-memory", role: "assistant", text: "Already displayed")]
        display.draft = "Unsent draft"; display.draftReady = true
        model.displays[display.id] = display; model.selected = display
        let generation = display.presentationGeneration
        model.page = .report; model.page = .chats
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(display.presentationGeneration, generation, "A visibility update has no abandoned initialization to restart")
        let reads = await gate.reads
        XCTAssertEqual(reads, 0, "Visibility recovery resumes an abandoned load, not an unrelated in-memory presentation")
        XCTAssertEqual(display.messages.first?.id, "in-memory")
        XCTAssertEqual(display.draft, "Unsent draft")
    }
    @MainActor func testRetiredInitialMainAndSideLoadsResumeWhenChatsReturns() async throws {
        for side in [false, true] {
            for returnBeforeCompletion in [false, true] {
                let (model, gate) = try fixture()
                let id = side ? "chat-side" : "chat-parent"
                model.displays[id]?.historyState = .dormant
                await gate.set("Retired", held: true, messageID: "retired")
                let opening = Task { if side { await model.openFamilySide(id) } else { await model.select(id) } }
                try await eventually("Initial history is pending") { await gate.reads == 1 }
                model.page = .report
                let fresh = ChildHistoryGate(); await fresh.set("Fresh content", messageID: "fresh")
                model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
                if returnBeforeCompletion {
                    model.page = .chats
                    try await eventually("A retired uncooperative read cannot delay fresh hydration") { model.displays[id]?.messages.first?.id == "fresh" }
                }
                await gate.release(); await opening.value
                if !returnBeforeCompletion { model.page = .chats }
                try await eventually("Returning to Chats hydrates the still-selected reader") {
                    model.displays[id]?.messages.first?.id == "fresh"
                }
                XCTAssertTrue(model.displays[id]?.draftReady == true)
                XCTAssertNotEqual(model.displays[id]?.historyState, .dormant)
                XCTAssertEqual(model.selectedID, "chat-parent")
            }
        }
    }
    @MainActor func testSideHydrationSurvivesNoOpSelectionAndIndependentWindowActions() async throws {
        for action in ["Side", "window"] {
            let (model, gate) = try fixture()
            model.tabs.showsWindows = false
            let external = otherTab(model); let window = model.tabs.popOut(external)
            let other = model.tabs.open(kind: HostedTab.kind, key: "external-other", in: window) {
                HostedTab(key: "external-other", title: "Another", symbol: "doc")
            }
            await gate.set("Side content", held: true)
            let opening = Task { await model.openFamilySide("chat-side") }
            try await eventually("Side is reading") { await gate.reads == 1 }
            if action == "Side" { model.tabs.showSide() } else { model.tabs.activate(external); model.tabs.close(other) }
            await gate.release(); await opening.value
            XCTAssertEqual(model.displays["chat-side"]?.messages.first?.text, "Side content", action)
            XCTAssertNotEqual(model.displays["chat-side"]?.historyState, .dormant, action)
        }
    }
    @MainActor func testRetiredChildInitialLoadRestartsWhenItsReaderIsVisibleAgain() async throws {
        for popped in [false, true] {
            let (model, gate) = try fixture()
            model.tabs.showsWindows = false
            await gate.set("Retired", held: true, messageID: "retired")
            let opening = Task { await model.openSubagentTab("chat-child") }
            try await eventually("Child initial read is pending") { await gate.reads == 1 }
            let tab = try XCTUnwrap(model.subagentTab("chat-child"))
            if popped { model.tabs.popOut(tab) }
            let other = model.tabs.open(kind: HostedTab.kind, key: "replacement", in: tab.container) {
                HostedTab(key: "replacement", title: "Replacement", symbol: "doc")
            }
            let fresh = ChildHistoryGate(); await fresh.set("Fresh child", messageID: "fresh")
            model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
            model.tabs.activate(tab)
            let token = tab.navigation
            model.tabs.activate(tab)
            XCTAssertTrue(token.isCurrent, "Re-clicking a visible reader is a no-op")
            await gate.release(); _ = await opening.value
            try await eventually("Shown child hydrates under a fresh token") { model.displays[tab.key]?.messages.first?.id == "fresh" }
            XCTAssertFalse(model.displays[tab.key]?.historyState == .dormant)
            model.tabs.close(other)
        }
    }
    @MainActor func testNoOpVersionSelectionKeepsItsPendingPage() async throws {
        let (model, _) = try fixture(), tab = try await open("chat-child",in:model)
        let gate = ReaderLookupGate(), display = try XCTUnwrap(model.displays[tab.key])
        model.versionPageLoader = { _, _ in await gate.wait(); return ([.init(id:"old",role:"assistant",text:"Earlier")],[]) }
        model.showVersion(sessionID:tab.key,latestID:"latest",index:1,count:2,ids:["old","latest"])
        try await eventually("Version is reading") { await gate.reads == 1 }
        let token = tab.navigation
        model.showVersion(sessionID:tab.key,latestID:"latest",index:1,count:2,ids:["old","latest"])
        XCTAssertTrue(token.isCurrent)
        await gate.release(); await display.versionLoad?.value
        XCTAssertEqual(display.versionView?.rows.first?.text,"Earlier")
    }
    @MainActor func testExternalChildRevealsDoNotRetireMainHydration() async throws {
        let (model, _) = try fixture(), tab = try await open("chat-child",in:model)
        model.tabs.showsWindows = false; model.tabs.popOut(tab)
        let gate = ChildHistoryGate(); await gate.set("Fresh main",held:true)
        let childPage = ChildHistoryGate()
        model.historyWindowLoader = { id,_,_,_ in try await (id == "chat-parent" ? gate : childPage).page() }
        model.displays["chat-parent"]?.historyState = .dormant
        let opening = Task { await model.select("chat-parent") }
        try await eventually("Main read is pending") { await gate.reads == 1 }
        let revision = model.messageNavigationRevision
        _ = await model.revealMessage(sessionID:tab.key,messageID:"saved-reply")
        XCTAssertEqual(model.messageNavigationRevision,revision)
        await gate.release(); await opening.value
        XCTAssertEqual(model.selected?.messages.first?.text,"Fresh main")
    }
    @MainActor func testVisibleReadersRestartTheirRetiredFindQueryWithoutRevealingAnOldMatch() async throws {
        for child in [false,true] {
            let (model, _) = try fixture()
            let tab = child ? try await open("chat-child",in:model) : nil
            let display = try XCTUnwrap(child ? model.displays["chat-child"] : model.selected)
            let pane = NativeTranscriptPane(frame:.init(x:0,y:0,width:620,height:500))
            pane.showTranscript(model:model,session:display,state:"idle",canFork:false,canQuote:false,enabled:true)
            pane.showFind(); defer { pane.closeFind(focusing:false) }
            let gate = ReaderLookupGate(), history = model.history
            model.conversationSearchLoader = { _, query, start in
                if await gate.reads == 0 { await gate.wait() }
                return try await history.searchPresented([.init(id:"needle",role:"assistant",text:"Needle")],query:query,start:start)
            }
            pane.find.setQuery("Needle")
            try await eventually("Find is pending") { await gate.reads == 1 }
            if let tab { _ = otherTab(model); model.tabs.activate(tab) }
            else { model.page = .report; model.page = .chats }
            await gate.release()
            try await eventually("The retained query restarts under the visible reader's fresh intent") { !pane.find.searching && pane.find.matches.count == 1 }
            XCTAssertFalse(pane.find.failed)
            XCTAssertNotEqual(display.scrollAnchor?.id,"needle","Recovery must not replay an obsolete automatic reveal")
        }
    }
    @MainActor func testRecoveryDefersToANewerRevealThatStillOwnsTheReader() async throws {
        for route in ["transcript", "report", "conversation-search"] {
            let (model, old) = try fixture(), fresh = ChildHistoryGate(), display = try XCTUnwrap(model.selected)
            display.historyState = .dormant
            await old.set("Old initial",held:true); await fresh.set("Wanted match",held:true,messageID:"target")
            model.historyWindowLoader = { _,_,_,around in try await (around == "target" ? fresh : old).page() }
            let opening = Task { await model.select(display.id) }
            try await eventually("Initial read held") { await old.reads == 1 }
            let reveal = Task {
                switch route {
                case "report": return await model.revealMessage(sessionID:display.id,messageID:"target")
                case "conversation-search":
                    try? await model.revealConversationHit(display.id, hit:.init(id:"target",position:1,preview:"Wanted match"))
                    return display.scrollAnchor?.id == "target"
                default: return await model.revealInTranscript(sessionID:display.id,messageID:"target")
                }
            }
            try await eventually("New reveal held") { await fresh.reads == 1 }
            await old.release(); await opening.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            await fresh.release()
            let landed = await reveal.value
            XCTAssertTrue(landed,"Generic hydration cannot supersede a newer explicit destination: " + route)
            XCTAssertEqual(display.scrollAnchor?.id,"target",route)
            XCTAssertEqual(display.messages.first?.text,"Wanted match",route)
        }
    }
    @MainActor func testNewMainIntentRestartsInitializationWithoutWaitingForRetiredRead() async throws {
        let (model, old) = try fixture(), display = try XCTUnwrap(model.selected)
        display.historyState = .dormant
        display.messages = [.init(id: "target", role: "assistant", text: "Held rows")]
        await old.set("Retired", held: true)
        defer { Task { await old.release() } }
        let opening = Task { await model.select(display.id) }
        try await eventually("Initial read held") { await old.reads == 1 }
        let fresh = ChildHistoryGate(); await fresh.set("Fresh target", messageID: "target")
        model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
        _ = await model.revealInTranscript(sessionID: display.id, messageID: "target")
        try await eventually("Still-wanted initialization restarts while the old read remains suspended") {
            display.draftReady && display.messages.first?.text == "Fresh target"
        }
        await old.release(); await opening.value
        XCTAssertEqual(display.scrollAnchor?.id, "target")
        XCTAssertNotEqual(display.historyState, .dormant)
    }
    @MainActor func testFindKeepsPagingWhileItsAutomaticAndNextMatchesReadOtherPages() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let display = try XCTUnwrap(model.displays[tab.key])
        let pane = NativeTranscriptPane(frame: .init(x: 0, y: 0, width: 620, height: 500))
        pane.showTranscript(model: model, session: display, state: "idle", canFork: false, canQuote: false, enabled: true)
        defer { pane.closeFind(focusing: false) }
        let rows = (0..<251).map { TranscriptMessage(id: "match-\($0)", role: "assistant", text: "Needle \($0)") }
        let gate = ReaderLookupGate(), history = model.history
        model.conversationSearchLoader = { _, query, start in
            if start == 100 { await gate.wait() }
            return try await history.searchPresented(rows, query: query, start: start)
        }
        model.historyWindowLoader = { _, _, _, around in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                "messages": .array([.object(["id": .string(around ?? "match-0"), "role": .string("assistant"), "text": .string("Needle")])]),
                "older": .null, "newer": .null]))
        }
        pane.find.setQuery("Needle")
        try await eventually("The second 100-hit search page is awaiting its read") { await gate.reads == 1 }
        try await eventually("Find automatically reveals the first off-page match") { display.scrollAnchor?.id == "match-0" }
        XCTAssertEqual(pane.find.matches.count, 100)
        pane.find.step(1)
        try await eventually("Find Next reveals another page while search is pending") { display.scrollAnchor?.id == "match-1" }
        await gate.release()
        try await eventually("Find finishes all of its pages") { !pane.find.searching }
        XCTAssertFalse(pane.find.failed, "A query's own reveals cannot cancel its search pages")
        XCTAssertEqual(pane.find.matches.map(\.messageID), rows.map(\.id))
        XCTAssertEqual(pane.find.current, 1)
    }
    @MainActor func testEmbeddedBackRetiresAnAwaitingAgentSourceLookup() async throws {
        for goBack in [true, false] {
            let (model, _) = try fixture()
            let tab = try await open("chat-child", in: model)
            let parent = try XCTUnwrap(model.selected)
            parent.messages = [.init(id: "reply", role: "assistant", text: "Issuing call"),
                               .init(id: "reading", role: "assistant", text: "Reading here")]
            parent.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
            model.chats[0].path = model.workspaces[0].path + "/parent.jsonl"
            let gate = ReaderLookupGate()
            model.agentCoordinationLoader = { _, _ in
                await gate.wait()
                return AgentCoordination(entries: [.init(id: "delivery", childID: "chat-child", turn: 1, kind: "task", author: "parent",
                    sourceSessionID: "chat-parent", sourceMessageID: "reply", sourceToolCallID: "call", recipientID: "chat-child", disposition: "delivered")])
            }
            let lookup = Task { await model.openAgentSource(.init(childID: tab.key, turn: 1, eventID: "delivery"), from: tab.key) }
            try await eventually("Source is awaiting coordination history") { await gate.reads == 1 }
            let selection = model.selectionRevision
            if goBack { await model.backToSubagentParent(tab.key) }
            XCTAssertEqual(model.selectionRevision, selection)
            await gate.release(); await lookup.value
            XCTAssertEqual(parent.scrollAnchor?.id, goBack ? "reading" : "reply")
            if goBack { XCTAssertEqual(parent.scrollAnchor?.offset, 31); XCTAssertNil(parent.reveal) }
            XCTAssertTrue(model.subagentTabIsShown(tab.key))
        }
    }
    @MainActor func testEmbeddedBackRetiresEveryStageOfAParentSourceReveal() async throws {
        for stage in ["versions", "anchor", "version page", "message"] {
            for goBack in [true, false] {
                let (model, _) = try fixture()
                let tab = try await open("chat-child", in: model), parent = try XCTUnwrap(model.selected)
                parent.messages = [.init(id: "reading", role: "assistant", text: "Keep reading here")]
                parent.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
                model.chats[0].path = model.root.appendingPathComponent("parent.jsonl").path
                let gate = ReaderLookupGate()
                model.agentCoordinationLoader = { _, _ in
                    AgentCoordination(entries: [.init(id: "delivery", childID: "chat-child", turn: 1, kind: "task", author: "parent",
                        sourceSessionID: "chat-parent", sourceMessageID: "issuing", sourceToolCallID: "call", recipientID: "chat-child", disposition: "delivered")])
                }
                model.subagentVersionsLoader = { _, _ in
                    if stage == "versions" { await gate.wait() }
                    if stage == "message" { return [:] }
                    return ["versions": .array([.object(["messageId": .string("old-input")]), .object(["messageId": .string("anchor")])]),
                            "selected": .number(1), "anchor": .string("anchor"), "current": .number(2)]
                }
                model.historyWindowLoader = { _, _, _, around in
                    if stage == "anchor" || stage == "message" { await gate.wait() }
                    return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                        "messages": .array([.object(["id": .string(around ?? "anchor"), "role": .string("assistant"), "text": .string("Source")])]),
                        "older": .null, "newer": .null]))
                }
                model.versionPageLoader = { _, _ in
                    if stage == "version page" { await gate.wait() }
                    return ([.init(id: "issuing", role: "assistant", text: "Earlier issuing call")], [])
                }
                let lookup = Task { await model.openAgentSource(.init(childID: tab.key, turn: 1, eventID: "delivery"), from: tab.key) }
                try await eventually("Source awaits \(stage)") { await gate.reads == 1 }
                let before = parent.scrollAnchor, rows = parent.messages, versionRows = parent.versionView?.rows
                if goBack { await model.backToSubagentParent(tab.key) }
                await gate.release(); await lookup.value
                if goBack {
                    XCTAssertEqual(parent.scrollAnchor, before, stage)
                    XCTAssertEqual(parent.messages, rows, stage)
                    XCTAssertEqual(parent.versionView?.rows ?? [], versionRows ?? [], stage)
                    XCTAssertFalse(parent.versionView?.loading == true, stage)
                } else { XCTAssertEqual(parent.scrollAnchor?.id, "issuing", stage + " completes without Back") }
            }
        }
    }
    @MainActor func testParentSourceRetiresAnOlderParentReadBeforeAwaitingItsVersionLookup() async throws {
        let (model, history) = try fixture(), tab = try await open("chat-child", in: model)
        let parent = try XCTUnwrap(model.selected)
        parent.messages = [.init(id: "reading", role: "assistant", text: "Keep reading")]
        parent.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
        await history.set("Older destination", held: true, messageID: "older")
        let count = await history.reads
        let old = Task { await model.revealInTranscript(sessionID: parent.id, messageID: "older") }
        try await eventually("Older parent reveal is held") { await history.reads > count }
        let versions = ReaderLookupGate()
        model.subagentVersionsLoader = { _, _ in await versions.wait(); return [:] }
        let link = try XCTUnwrap(model.record(tab.key)?.delegation)
        let source = Task { await model.openSubagentParent(link, origin: tab.renewNavigation()) }
        try await eventually("New Source is looking up its version") { await versions.reads == 1 }
        await history.release()
        let landed = await old.value
        XCTAssertFalse(landed, "A new Source destination retires the old parent read immediately")
        XCTAssertEqual(parent.scrollAnchor?.id, "reading")
        await model.backToSubagentParent(tab.key); await versions.release(); _ = await source.value
    }
    @MainActor func testSidebarContentHitRevealsInPoppedOutChildOnEveryMainPage() async throws {
        let (model, _) = try fixture()
        let path = model.root.appendingPathComponent("search-child.jsonl")
        try FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        try "{\"type\":\"session\",\"version\":3,\"id\":\"chat-child\"}\n{\"type\":\"message\",\"id\":\"matching\",\"parentId\":null,\"message\":{\"role\":\"assistant\",\"content\":\"Distinctive search phrase\"}}\n".write(to: path, atomically: true, encoding: .utf8)
        model.chats[1].path = path.path
        await model.sidebarSearch.reconcileNow()
        model.sidebarSearch.setScope(.fullChats)
        model.sidebarSearch.setQuery("Distinctive search")
        try await eventually("The generated child journal is indexed") { model.sidebarSearchHit("chat-child") != nil }
        let tab = try await open("chat-child", in: model)
        model.tabs.showsWindows = false; model.tabs.popOut(tab)
        for page in [WorkspacePage.report, .background, .chats] {
            model.page = page
            let display = try XCTUnwrap(model.displays[tab.key]); display.scrollAnchor = .init(id: "saved-reply", offset: 19, followsBottom: false)
            await model.openFromSidebar(tab.key)
            XCTAssertEqual(display.scrollAnchor?.id, "matching", "Search reveals in the child window on \(page)")
            XCTAssertEqual(model.page, page)
        }
    }
    @MainActor func testMainHistoryOperationsRetireAcrossPageRoundTrips() async throws {
        for operation in ["reload", "edge", "version", "search hit"] {
            let (model, gate) = try fixture(), display = try XCTUnwrap(model.selected)
            display.messages = [.init(id: "reading", role: "assistant", text: "Keep this page")]
            display.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
            await gate.set("Obsolete read", held: true, messageID: "obsolete")
            let lookup = ReaderLookupGate()
            model.versionPageLoader = { _, _ in await lookup.wait(); return ([.init(id: "obsolete", role: "assistant", text: "Earlier version")], []) }
            let task = Task {
                switch operation {
                case "reload": model.reloadHistory(display.id); await display.presentation.navigation?.value
                case "edge":
                    display.olderPage.cursor = .init(incarnation: "fixture", lineage: "root", entry: "reading")
                    _ = await model.loadEarlierPage(sessionID: display.id)
                case "version":
                    model.showVersion(sessionID: display.id, latestID: "reading", index: 1, count: 2, ids: ["old", "reading"])
                    await display.versionLoad?.value
                default: try? await model.revealConversationHit(display.id, hit: .init(id: "obsolete", position: 1, preview: "Obsolete"))
                }
            }
            try await eventually("\(operation) is reading") { operation == "version" ? await lookup.reads == 1 : await gate.reads == 1 }
            model.page = .background
            let fresh = ChildHistoryGate(); await fresh.set("Keep this page", messageID:"reading")
            model.historyWindowLoader = { _,_,_,_ in try await fresh.page() }
            model.page = .chats
            await gate.release(); await lookup.release(); await task.value
            if operation == "reload" { try await eventually("Reload recovers its held page") { display.messages.first?.id == "reading" && display.historyState != .loading } }
            XCTAssertEqual(display.messages.map(\.id), ["reading"], operation)
            XCTAssertEqual(display.scrollAnchor?.id, "reading", operation)
            XCTAssertFalse(display.versionView?.rows.contains { $0.id == "obsolete" } == true, operation)
            XCTAssertFalse(display.versionView?.loading == true, "A retired version must not leave a permanent loading cover")
            XCTAssertFalse(display.historyState == .loading, "A retired reload can be reopened")
            XCTAssertFalse(display.olderPage.loading)
        }
    }
    @MainActor func testRetiredPositionReadDoesNotRestartItsQueuedDestination() async throws {
        let (model, gate) = try fixture(), display = try XCTUnwrap(model.selected)
        display.messages = [.init(id: "reading", role: "assistant", text: "Keep this page")]
        display.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
        await gate.set("Obsolete position", held: true, messageID: "obsolete")
        model.jumpToHistoryPosition(display.id, position: 0, offset: 24)
        try await eventually("The first position read is held") { await gate.reads == 1 }
        let first = display.jumpTask
        model.jumpToHistoryPosition(display.id, position: 10, offset: 24)
        model.page = .background; model.page = .chats
        await gate.release(); await first?.value; await display.jumpTask?.value
        let reads = await gate.reads
        XCTAssertEqual(reads, 1, "Retiring an intent also retires its coalesced destination")
        XCTAssertEqual(display.messages.map(\.id), ["reading"])
        XCTAssertEqual(display.scrollAnchor?.id, "reading")
        XCTAssertNil(display.jumpTask); XCTAssertNil(display.jumpRead)
    }
    @MainActor func testSourceCanTransferFromEmbeddedChildIntoItsOwningSavedSide() async throws {
        let (model, gate) = try fixture()
        model.chats[1].parentSessionID = "chat-side"; model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"; model.chats[1].delegation?.call.parentSessionID = "chat-side"
        model.chats[2].path = model.root.appendingPathComponent("side.jsonl").path
        let tab = try await open("chat-child", in: model)
        model.agentCoordinationLoader = { _, _ in
            AgentCoordination(entries: [.init(id: "delivery", childID: "chat-child", turn: 1, kind: "task", author: "parent",
                sourceSessionID: "chat-side", sourceMessageID: "issuing", sourceToolCallID: "call", recipientID: "chat-child", disposition: "delivered")])
        }
        await gate.set("Side's issuing call", messageID: "issuing")
        await model.openAgentSource(.init(childID: tab.key, turn: 1, eventID: "delivery"), from: tab.key)
        XCTAssertEqual(model.selectedID, "chat-parent"); XCTAssertEqual(model.focusedSessionID, "chat-side")
        XCTAssertEqual(model.displays["chat-side"]?.scrollAnchor?.id, "issuing")
        XCTAssertFalse(model.subagentTabIsShown(tab.key))
    }
    @MainActor func testReportDeliveryUncoversItsRecipientSideAndTransfersEmbeddedOwnership() async throws {
        for mounted in [true, false] {
            for popped in [false, true] {
                for loaded in [true, false] {
                    let (model, history) = try fixture()
                    model.chats[1].parentSessionID = "chat-side"
                    model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"
                    model.chats[1].delegation?.call.parentSessionID = "chat-side"
                    model.chats[2].path = model.root.appendingPathComponent("side.jsonl").path
                    if mounted { await model.openFamilySide("chat-side") }
                    let tab = try await open("chat-child", in: model)
                    model.tabs.showsWindows = false
                    if popped { _ = model.tabs.popOut(tab) }
                    let side = try XCTUnwrap(model.displays["chat-side"])
                    side.messages = [.init(id: loaded ? "delivered-report" : "latest", role: "assistant", text: "Side history")]
                    side.scrollAnchor = .init(id: "latest", offset: 18, followsBottom: false)
                    await history.set("Delivered report", messageID: "delivered-report")
                    model.agentCoordinationLoader = { _, _ in
                        AgentCoordination(entries: [.init(id: "report", childID: "chat-child", turn: 1, kind: "note", author: "subagent",
                            sourceSessionID: "chat-child", sourceMessageID: "report-call", sourceToolCallID: "report-tool", recipientID: "chat-side",
                            recipientMessageID: "delivered-report", disposition: "delivered")])
                    }
                    await model.openAgentSource(.init(childID: tab.key, turn: 1, eventID: "report", recipient: true), from: tab.key)
                    let label = "mounted=\(mounted), popped=\(popped), loaded=\(loaded)"
                    XCTAssertEqual(model.selectedID, "chat-parent", label)
                    XCTAssertEqual(model.focusedSessionID, "chat-side", label)
                    XCTAssertTrue(model.transcriptShows("chat-side"), label)
                    XCTAssertEqual(side.scrollAnchor?.id, "delivered-report", label)
                    XCTAssertEqual(model.subagentTabIsShown(tab.key), popped, label)
                }
            }
        }
    }
    @MainActor func testSideDeliveryFinishesLoadingWithoutOverwritingNewerMainFocus() async throws {
        for mounted in [false, true] {
            let (model, _) = try fixture()
            model.chats[1].parentSessionID = "chat-side"; model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"
            model.chats[1].delegation?.call.parentSessionID = "chat-side"
            model.chats[2].path = model.root.appendingPathComponent("side.jsonl").path
            if mounted { await model.openFamilySide("chat-side") }
            let tab = try await open("chat-child", in: model)
            let side = try XCTUnwrap(model.displays["chat-side"])
            side.historyState = .dormant
            let gate = ReaderLookupGate()
            model.historyWindowLoader = { _, _, _, _ in
                await gate.wait()
                return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                    "messages": .array([.object(["id": .string("delivered"), "role": .string("assistant"), "text": .string("Report")])]),
                    "older": .null, "newer": .null]))
            }
            let origin = tab.renewNavigation()
            let reveal = Task { await model.revealMessage(sessionID: side.id, messageID: "delivered", origin: origin) }
            try await eventually("Uncovered recipient side awaits its initial history") { await gate.reads == 1 }
            model.focusPane("chat-parent")
            await gate.release()
            let landed = await reveal.value
            XCTAssertTrue(landed)
            XCTAssertEqual(side.scrollAnchor?.id, "delivered")
            XCTAssertEqual(model.focusedSessionID, "chat-parent", "Late delivery loading preserves the reader's newer focus")
        }
    }
    @MainActor func testRetiredSideDeliveryCannotPublishAfterItsReaderHandoff() async throws {
        for popped in [false, true] {
            for action in ["file", "report", "new reveal"] {
                let (model, _) = try fixture()
                model.chats[1].parentSessionID = "chat-side"; model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"
                model.chats[1].delegation?.call.parentSessionID = "chat-side"
                model.chats[2].path = model.root.appendingPathComponent("side.jsonl").path
                await model.openFamilySide("chat-side")
                let tab = try await open("chat-child", in: model)
                model.tabs.showsWindows = false; if popped { _ = model.tabs.popOut(tab) }
                let side = try XCTUnwrap(model.displays["chat-side"])
                side.messages = [.init(id: "reading", role: "assistant", text: "Keep reading here")]
                side.scrollAnchor = .init(id: "reading", offset: 27, followsBottom: false)
                let gate = ReaderLookupGate()
                model.historyWindowLoader = { _, _, _, _ in
                    await gate.wait()
                    return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
                        "messages": .array([.object(["id": .string("delivered"), "role": .string("assistant"), "text": .string("Report")])]), "older": .null, "newer": .null]))
                }
                let origin = tab.renewNavigation()
                let reveal = Task { await model.revealMessage(sessionID: side.id, messageID: "delivered", origin: origin) }
                try await eventually("Delivery has uncovered its side and awaits history") { await gate.reads == 1 }
                XCTAssertTrue(model.transcriptShows(side.id))
                XCTAssertEqual(origin.isCurrent, popped, "Only embedded origins transfer ownership")
                if action == "file" { _ = otherTab(model) }
                else if action == "report" { model.page = .report }
                else { let opened = await model.revealMessage(sessionID: side.id, messageID: "reading"); XCTAssertTrue(opened) }
                await gate.release()
                let landed = await reveal.value
                XCTAssertFalse(landed, action)
                XCTAssertEqual(side.messages.first?.id, "reading")
                XCTAssertEqual(side.scrollAnchor?.id, "reading")
                XCTAssertNil(side.revealRead)
            }
        }
    }
    @MainActor func testSourceFromAPoppedChildRevealsItsAlreadyShownSide() async throws {
        let (model, _) = try fixture()
        model.chats[1].parentSessionID = "chat-side"; model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"; model.chats[1].delegation?.call.parentSessionID = "chat-side"
        model.chats[2].path = model.root.appendingPathComponent("side.jsonl").path
        let tab = try await open("chat-child", in: model)
        model.tabs.showsWindows = false; model.tabs.popOut(tab)
        await model.openFamilySide("chat-side")
        let side = try XCTUnwrap(model.displays["chat-side"])
        side.messages = [.init(id: "issuing", role: "assistant", text: "Side's issuing call")]
        side.scrollAnchor = .init(id: "reading", offset: 23, followsBottom: false)
        let paneRevision = model.tabs.navigationRevision
        model.agentCoordinationLoader = { _, _ in
            AgentCoordination(entries: [.init(id: "delivery", childID: "chat-child", turn: 1, kind: "task", author: "parent",
                sourceSessionID: "chat-side", sourceMessageID: "issuing", sourceToolCallID: "call", recipientID: "chat-child", disposition: "delivered")])
        }
        await model.openAgentSource(.init(childID: tab.key, turn: 1, eventID: "delivery"), from: tab.key)
        XCTAssertEqual(model.tabs.navigationRevision, paneRevision, "The side was already shown")
        XCTAssertEqual(side.scrollAnchor?.id, "issuing")
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
    }
    @MainActor func testInspectorParentSourceRetainsTheOriginatingReaderThroughItsVersionRead() async throws {
        let (model, _) = try fixture(), tab = try await open("chat-child", in: model)
        let parent = try XCTUnwrap(model.selected)
        parent.messages = [.init(id: "reading", role: "assistant", text: "Keep reading")]
        parent.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
        let gate = ReaderLookupGate()
        model.subagentVersionsLoader = { _, _ in await gate.wait(); return [:] }
        let inspector = SessionInspectorModel(scope: .init(sessionID: tab.key, workspaceID: "pane-project"), title: "Child", archive: model.traces,
            workspace: model, usageLoader: { _, _, _ in throw CancellationError() })
        inspector.showSubagentParent(try XCTUnwrap(model.record(tab.key)?.delegation))
        try await eventually("Inspector Source is reading versions") { await gate.reads == 1 }
        await model.backToSubagentParent(tab.key)
        await gate.release()
        // Drain both the version continuation and the generated history read.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(parent.scrollAnchor?.id, "reading")
        XCTAssertEqual(parent.messages.map(\.id), ["reading"])
    }
    @MainActor func testNewRevealInPoppedChildRetiresItsAwaitingBackToParent() async throws {
        let (model, _) = try fixture(), tab = try await open("chat-child", in: model)
        model.tabs.showsWindows = false; model.tabs.popOut(tab)
        let parent = try XCTUnwrap(model.selected)
        parent.messages = [.init(id: "reading", role: "assistant", text: "Keep reading")]
        parent.scrollAnchor = .init(id: "reading", offset: 31, followsBottom: false)
        let gate = ReaderLookupGate()
        model.subagentVersionsLoader = { _, _ in await gate.wait(); return [:] }
        let back = Task { await model.backToSubagentParent(tab.key) }
        try await eventually("Popped Back is reading the parent version") { await gate.reads == 1 }
        tab.focus()
        let shown = await model.revealInTranscript(sessionID: tab.key, messageID: "saved-reply")
        XCTAssertTrue(shown)
        await gate.release(); await back.value
        XCTAssertEqual(parent.scrollAnchor?.id, "reading"); XCTAssertEqual(parent.messages.map(\.id), ["reading"])
        XCTAssertEqual(model.focusedSessionID, tab.key)
    }
    @MainActor func testNewParentMessageNavigationRetiresAnAwaitingChildReveal() async throws {
        let (model, gate) = try fixture()
        model.selected?.messages = [.init(id: "parent-message", role: "assistant", text: "Main reply")]
        await gate.set("Child reply", held: true)
        let child = try XCTUnwrap(model.displays["chat-child"]); child.historyState = .dormant
        let opening = Task { await model.revealMessage(sessionID: child.id, messageID: "saved-reply") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let parentRevealed = await model.revealMessage(sessionID: "chat-parent", messageID: "parent-message")
        XCTAssertTrue(parentRevealed)
        await gate.release()
        let childRevealed = await opening.value
        XCTAssertFalse(childRevealed)
        XCTAssertNil(child.reveal, "The old child request cannot land after the newer parent request")
        XCTAssertEqual(model.selected?.scrollAnchor?.id, "parent-message")
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
    }
    @MainActor func testPoppedOutHistoryReadsSurviveUnrelatedMainNavigation() async throws {
        for operation in ["find", "home", "position"] {
            let (model, gate) = try fixture()
            let tab = try await open("chat-child", in: model)
            model.tabs.showsWindows = false; model.tabs.popOut(tab)
            let display = try XCTUnwrap(model.displays[tab.key])
            model.historyViewportReady(tab.key, generation: display.presentationGeneration)
            display.olderPage.cursor = .init(incarnation: "fixture", lineage: "root", entry: "saved-reply")
            let before = await gate.reads
            await gate.set("Earlier reply", held: true, messageID: "earlier")
            let reading = Task { @MainActor in
                if operation == "find" { return await model.revealInTranscript(sessionID: tab.key, messageID: "earlier", fromFind: true) }
                if operation == "home" { return await model.revealStartOfChat(sessionID: tab.key) }
                model.jumpToHistoryPosition(tab.key, position: 0, offset: 24)
                await display.jumpTask?.value
                return display.messages.first?.id == "earlier"
            }
            for _ in 0..<500 { if await gate.reads > before { break }; try await Task.sleep(for: .milliseconds(2)) }
            // A real selection uses an independent generated page; only the child read is held.
            let mainGate = ChildHistoryGate()
            model.historyWindowLoader = { id, _, _, _ in try await (id == tab.key ? gate : mainGate).page() }
            var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
            await model.select(other.id); model.page = .report
            XCTAssertTrue(model.subagentTabIsShown(tab.key))
            await gate.release()
            let loaded = await reading.value
            XCTAssertTrue(loaded, operation)
            XCTAssertEqual(display.messages.first?.id, "earlier", operation)
            XCTAssertEqual(display.scrollAnchor?.id, "earlier", operation)
            XCTAssertEqual(model.selectedID, other.id); XCTAssertEqual(model.page, .report)
        }
    }
    @MainActor func testBackRetiresAnAwaitingRevealInTheVisibleChild() async throws {
        let (model, gate) = try fixture()
        let tab = try await open("chat-child", in: model)
        let display = try XCTUnwrap(model.displays[tab.key])
        model.historyViewportReady(tab.key, generation: display.presentationGeneration)
        let before = await gate.reads
        await gate.set("Earlier reply", held: true, messageID: "earlier")
        let reading = Task { await model.revealInTranscript(sessionID: tab.key, messageID: "earlier", fromFind: true) }
        for _ in 0..<500 { if await gate.reads > before { break }; try await Task.sleep(for: .milliseconds(2)) }
        await model.backToSubagentParent(tab.key)
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
        await gate.release()
        let loaded = await reading.value
        XCTAssertFalse(loaded)
        XCTAssertEqual(display.messages.first?.id, "saved-reply")
        XCTAssertNil(display.reveal); XCTAssertNil(display.revealRead)
    }
    @MainActor func testPoppedOutConversationMenusUseTheKeyReaderEvenAfterMainFocusChanges() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of: container))
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeKey()
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let pane = try XCTUnwrap(tab.pane), display = try XCTUnwrap(model.displays[tab.key])
        XCTAssertTrue(window.makeFirstResponder(pane))
        model.page = .report; model.focusedSessionID = "chat-parent"
        // The machine is shared with other test hosts. Nominate this real
        // native window as key without making global activation a test input.
        model.conversationWindow = { window }
        XCTAssertTrue(model.hostedConversationReader(in: window) === tab)
        XCTAssertFalse(model.presentsSheet); XCTAssertFalse(model.quickOpen.isOpen)
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { nil }, revealWorkspace: {}, showSettings: {})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }; menus.install()
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Conversation" }?.submenu)
        func command(_ name: String) throws -> NSMenuItem { try XCTUnwrap(menu.items.first { $0.title == name }) }
        for name in ["Find…", "Find Next", "Stop", "Latest Messages", "Search and Copy Conversation…"] {
            XCTAssertTrue(menus.validateMenuItem(try command(name)), name)
        }
        let find = try command("Find…")
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(file.items.first { $0.title == "Delete Chat…" })))
        for name in ["Send / Queue Follow-up", "Open Side", "Compact Now"] { XCTAssertFalse(menus.validateMenuItem(try command(name)), name) }
        _ = menus.perform(find.action!, with: find)
        XCTAssertEqual(display.findCommand?.kind, .show); XCTAssertNil(model.selected?.findCommand)
        // The real Find bar establishes the menu's Previous availability.
        pane.transcript.showFind()
        XCTAssertTrue(menus.validateMenuItem(try command("Find Previous")))
        for (name, expected) in [("Find Next", TranscriptFindCommand.Kind.next), ("Find Previous", .previous)] {
            let item = try command(name); _ = menus.perform(item.action!, with: item)
            XCTAssertEqual(display.findCommand?.kind, expected)
        }
        let parent = try XCTUnwrap(model.selected); parent.runState = .running
        let stop = try command("Stop"); _ = menus.perform(stop.action!, with: stop)
        XCTAssertEqual(parent.runState, .running, "The child menu must never stop the selected main chat")
        display.scrollAnchor = .init(id: "earlier", offset: 10, followsBottom: false)
        let latest = try command("Latest Messages"); _ = menus.perform(latest.action!, with: latest)
        XCTAssertTrue(display.scrollAnchor?.followsBottom == true)
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; window.beginSheet(sheet, completionHandler: nil)
        XCTAssertFalse(menus.validateMenuItem(find))
        window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
        let search = try command("Search and Copy Conversation…"); _ = menus.perform(search.action!, with: search)
        XCTAssertEqual(model.contentSessionID, tab.key); XCTAssertTrue(model.showConversationContent)
        model.showConversationContent = false
    }
    @MainActor func testDeleteCommandCannotDeleteTheMainChatFromAFocusedManagedReader() async throws {
        let (model, _) = try fixture()
        _ = try await open("chat-child", in: model)
        let menus = ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { nil }, revealWorkspace: {}, showSettings: {})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        menus.install()
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        let delete = try XCTUnwrap(file.items.first { $0.title == "Delete Chat…" })
        XCTAssertFalse(menus.validateMenuItem(delete), "A managed reader has no independent Delete Chat command")
        var asked: [ChatQuestion] = []
        model.questions.answer = { asked.append($0); return false }
        model.deleteChat()
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(asked.isEmpty, "The focused child must never prepare its main chat's deletion")
        XCTAssertNotNil(model.record("chat-parent")); XCTAssertNotNil(model.record("chat-child"))
        model.focusPane("chat-parent")
        XCTAssertTrue(menus.validateMenuItem(delete))
        model.deleteChat()
        for _ in 0..<200 where asked.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(asked.count, 1, "Explicit parent focus still offers its ordinary confirmation")
    }
    @MainActor func testFamilyMenusRequireAUsablePickerButKeepIndependentChildWindows() async throws {
        let (model, _) = try fixture()
        model.conversationWindow = { nil }
        let menus = ApplicationMenus(model:model,updates:UpdateController(),workspaceWindow:{nil},revealWorkspace:{},showSettings:{})
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }; menus.install()
        let commands = try ["View", "Conversation"].map { title in
            let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == title }?.submenu)
            return try XCTUnwrap(menu.items.first { $0.title == "Sides and Agents…" })
        }
        var requests: [String] = []
        let subscription = model.agentFamilyRequests.sink { requests.append($0) }; defer { subscription.cancel() }
        for page in [WorkspacePage.chats, .report, .background, .chats] {
            model.page = page
            XCTAssertEqual(model.canShowAgentFamily, page == .chats)
            for command in commands { XCTAssertEqual(menus.validateMenuItem(command), page == .chats) }
            let before = requests.count
            model.showAgentFamily()
            XCTAssertEqual(requests.count - before, page == .chats ? 1 : 0, "Disabled requests must not reach a hidden picker")
        }
        let tab = try await open("chat-child",in:model)
        model.tabs.showsWindows = false
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of:container))
        model.conversationWindow = { window }
        for page in [WorkspacePage.chats, .report, .background] {
            model.page = page; model.focusedSessionID = "chat-parent"
            XCTAssertTrue(model.canShowAgentFamily)
            for command in commands {
                XCTAssertTrue(menus.validateMenuItem(command))
                let before = requests.count
                _ = menus.perform(command.action!,with:command)
                XCTAssertEqual(requests.count, before + 1)
                XCTAssertEqual(requests.last, "chat-parent")
            }
        }
        // Main-window activation must not reuse a previous child window's
        // remembered focus when the main picker is covered.
        model.conversationWindow = { nil }; model.focusedSessionID = tab.key
        for page in [WorkspacePage.report, .background] {
            model.page = page
            for command in commands { XCTAssertFalse(menus.validateMenuItem(command)) }
            let before = requests.count; model.showAgentFamily(); XCTAssertEqual(requests.count,before)
        }
    }
    @MainActor func testEmbeddedReaderFamilyMenuTargetsTheVisibleMainHeader() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; other.title = "Other main"
        model.chats.append(other)
        await model.select(other.id); tab.focus()
        XCTAssertFalse(model.canShowAgentFamily, "There is no picker anchor when the visible main chat has no family")
        var side = try XCTUnwrap(model.record("chat-side")); side.id = "other-side"; side.parentSessionID = other.id; model.chats.append(side)
        var owners: [String] = []
        let subscription = model.agentFamilyRequests.sink { owners.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(model.canShowAgentFamily)
        model.showAgentFamily()
        XCTAssertEqual(owners, [other.id], "Embedded commands use the main column's available picker")
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of:container))
        model.conversationWindow = { window }
        model.showAgentFamily()
        XCTAssertEqual(owners.last, "chat-parent", "A child window has its own family anchor")
    }
    @MainActor func testReopeningAHiddenChildRevalidatesSavedHistoryWithoutALiveHelper() async throws {
        let (model, gate) = try fixture()
        model.displays["chat-child"]?.historyState = .dormant
        let tab = try await open("chat-child", in: model)
        let display = try XCTUnwrap(model.displays[tab.key])
        model.historyViewportReady(display.id, generation: display.presentationGeneration)
        XCTAssertEqual(display.messages.first?.text, "Saved child reply")
        _ = otherTab(model)
        await gate.set("Finished while hidden")
        XCTAssertTrue(model.hosts.isEmpty)
        await model.openSubagentTab(tab.key)
        XCTAssertEqual(display.messages.first?.text, "Finished while hidden")
        XCTAssertTrue(model.sessionOpenings.isEmpty, "Reading saved history must not start a helper")
    }
    @MainActor func testBackDuringInitialLoadKeepsTheParentFocused() async throws {
        let (model, gate) = try fixture()
        await gate.set("Finished loading", held: true)
        model.displays["chat-child"]?.historyState = .dormant
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(model.subagentTab("chat-child"))
        await model.backToSubagentParent("chat-child")
        await gate.release(); _ = await opening.value
        XCTAssertEqual(model.focusedSessionID, "chat-parent", "Finishing a read is not a new focus request")
    }
    @MainActor func testBackSupersedesShowInChatWithoutMovingTheStillVisibleReader() async throws {
        let (model, gate) = try fixture()
        await gate.set("Finished loading", held: true)
        let display = try XCTUnwrap(model.displays["chat-child"])
        display.historyState = .dormant
        let revealing = Task { await model.revealMessage(sessionID: display.id, messageID: "saved-reply") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(model.subagentTab(display.id))
        await model.backToSubagentParent(display.id)
        XCTAssertTrue(model.subagentTabIsShown(display.id), "Back preserves the embedded reader's visibility")
        let serial = model.revealSerial
        await gate.release()
        let revealed = await revealing.value
        XCTAssertFalse(revealed, "A superseded opening cannot reveal its old message")
        XCTAssertNil(display.reveal)
        XCTAssertEqual(model.revealSerial, serial)
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        let current = await model.revealMessage(sessionID: display.id, messageID: "saved-reply")
        XCTAssertTrue(current, "An explicit new Show in Chat still reveals the message")
        XCTAssertEqual(display.reveal?.messageID, "saved-reply")
    }
    @MainActor func testAnotherTabChosenDuringLoadDoesNotFocusTheHiddenChild() async throws {
        let (model, gate) = try fixture()
        await gate.set("Finished loading", held: true)
        model.displays["chat-child"]?.historyState = .dormant
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let other = otherTab(model)
        await gate.release(); _ = await opening.value
        XCTAssertTrue(model.tabs.pane.activeTab === other)
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        XCTAssertFalse(model.subagentTabIsShown("chat-child"))
    }
    @MainActor func testSideSelectionWithoutAnAvailableSideStillShowsTheHostedReader() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        model.tabs.showSide()
        XCTAssertFalse(model.paneSideAvailable)
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === tab)
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
        let display = try XCTUnwrap(model.displays[tab.key]); display.historyState = .preparing
        model.historyViewportReady(tab.key, generation: display.presentationGeneration)
        XCTAssertEqual(display.historyState, .ready)
    }
    @MainActor func testClosingChildrenAppliesTheDisplayBudgetAndKeepsOpenAndRunningReaders() async throws {
        let (model, _) = try fixture()
        let original = try XCTUnwrap(model.record("chat-child"))
        let kept = try await open(original.id, in: model)
        let store = try XCTUnwrap(model.store)
        let conflict = SessionDisplay(id: "conflicted-chat"); conflict.used = .distantPast
        model.chats.append(ChatRecord(id: conflict.id, workspaceID: original.workspaceID, title: "Conflict", profileID: original.profileID))
        model.displays[conflict.id] = conflict
        conflict.draftVersion = try await store.draftVersion(id: conflict.id)
        try await store.put(DraftRecord(id: conflict.id, text: "Other instance's draft"), kind: "draft", id: conflict.id)
        conflict.draft = "Retained while child readers close"
        try? await store.put(conflict.savedDraft, kind: "draft", id: conflict.id, draftVersion: conflict.draftVersion)
        model.displays["chat-side"]?.runState = .running
        for index in 0..<14 {
            var child = original; child.id = "child-\(index)"; child.delegation?.childSessionID = child.id
            model.chats.append(child)
            let display = SessionDisplay(id: child.id); display.historyState = .ready
            display.messages = [.init(id: "reply", role: "assistant", text: String(repeating: "Retained transcript ", count: 100))]
            model.displays[child.id] = display
            let tab = try await open(child.id, in: model)
            model.tabs.close(tab)
        }
        XCTAssertLessThanOrEqual(model.displays.count, 8)
        XCTAssertTrue(model.displays[conflict.id] === conflict)
        let copies = try await store.draftConflicts(id: conflict.id)
        XCTAssertTrue(copies.contains(where: { $0.draft.text == conflict.draft }))
        XCTAssertNotNil(model.displays["chat-parent"]); XCTAssertNotNil(model.displays["chat-side"])
        XCTAssertNotNil(model.displays[kept.key]); XCTAssertTrue(model.subagentTab(kept.key) === kept)
    }
    @MainActor func testInactiveChildCannotOverwriteItsWindowsActiveTitle() async throws {
        let (model, _) = try fixture()
        var second = try XCTUnwrap(model.record("chat-child")); second.id = "second-child"; second.subagentNumber = 3
        second.delegation?.childSessionID = second.id; second.title = "Another task"
        model.chats.append(second)
        let first = try await open("chat-child", in: model)
        model.tabs.showsWindows = false
        let container = model.tabs.popOut(first)
        let secondTab = try await open(second.id, in: model)
        model.tabs.move(secondTab, to: container)
        let window = try XCTUnwrap(model.tabs.window(of: container))
        window.contentView?.layoutSubtreeIfNeeded()
        first.refresh()
        XCTAssertEqual(window.title, second.displayTitle + " — Bello Agent")
        model.tabs.activate(first); window.contentView?.layoutSubtreeIfNeeded(); secondTab.refresh()
        XCTAssertEqual(window.title, model.record(first.key)!.displayTitle + " — Bello Agent")
    }
    @MainActor func testPoppedOutReaderOwnsFindAndStopShortcutsButNotBehindASheet() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of: container))
        // Exercise the native transcript's shortcut path as well as the tab's,
        // independently of when the window server publishes the key window.
        model.conversationWindow = { window }
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeKey()
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let pane = try XCTUnwrap(tab.pane), display = try XCTUnwrap(model.displays[tab.key])
        XCTAssertTrue(window.makeFirstResponder(pane))
        model.page = .report
        XCTAssertTrue(model.subagentReaderCommandsEnabled(tab.key), "A popped-out reader keeps its commands while the main window shows another page")
        func key(_ text: String, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(TabHost.tabKey(try key("f"), in: window))
        XCTAssertEqual(display.findCommand?.kind, .show)
        XCTAssertNil(model.selected?.findCommand)
        try await eventually("The child Find bar opened") { display.findHost?.findIsOpen == true }
        XCTAssertTrue(TabHost.tabKey(try key("g", [.command, .shift]), in: window))
        XCTAssertEqual(display.findCommand?.kind, .previous)
        XCTAssertTrue(TabHost.tabKey(try key("g"), in: window))
        XCTAssertEqual(display.findCommand?.kind, .next)
        XCTAssertTrue(TabHost.tabKey(try key("."), in: window))
        for (text, flags, expected) in [("F", NSEvent.ModifierFlags.command, TranscriptFindCommand.Kind.show),
                                        ("G", [.command, .shift], .previous), ("G", .command, .next)] {
            XCTAssertTrue(window.makeFirstResponder(pane))
            let serial = model.revealSerial
            XCTAssertTrue(TabHost.tabKey(try key(text, flags.union(.capsLock)), in: window), "Caps Lock does not disable \(text)")
            XCTAssertEqual(display.findCommand?.kind, expected)
            XCTAssertGreaterThan(model.revealSerial, serial, "The child receives a fresh Find command")
        }
        XCTAssertTrue(TabHost.tabKey(try key(".", [.command, .capsLock]), in: window))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; window.beginSheet(sheet, completionHandler: nil)
        let serial = model.revealSerial
        XCTAssertFalse(TabHost.tabKey(try key("f"), in: window))
        XCTAssertFalse(TabHost.tabKey(try key("F", [.command, .capsLock]), in: window))
        XCTAssertFalse(TabHost.tabKey(try key("G", [.command, .shift, .capsLock]), in: window))
        XCTAssertEqual(model.revealSerial, serial, "A native sheet owns Find even with an open child Find bar")
        window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
        model.tabs.moveToPane(tab)
        XCTAssertFalse(model.subagentReaderCommandsEnabled(tab.key), "The Reports page still covers a reader embedded in the workspace")
    }
    @MainActor func testReopeningUnchangedHistoryCancelsPagingWithoutKeepingItsLoadingFlags() async throws {
        let (model, gate) = try fixture()
        let path = model.root.appendingPathComponent("paging.jsonl")
        var data = Data()
        func append(_ row: [String: WireValue]) throws { data.append(try JSONEncoder().encode(row)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string("chat-child")])
        for index in 0..<121 {
            try append(["type": .string("message"), "id": .string("m\(index)"), "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                        "message": .object(["role": .string(index % 2 == 0 ? "user" : "assistant"), "content": .string("Reply \(index)")])])
        }
        try FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        try data.write(to: path)
        model.chats[1].path = path.path; model.historyWindowLoader = nil
        let tab = try await open("chat-child", in: model), display = try XCTUnwrap(model.displays[tab.key])
        model.historyViewportReady(tab.key, generation: display.presentationGeneration)
        let cursor = try XCTUnwrap(display.olderPage.cursor)
        await gate.set("Older page", held: true)
        model.historyWindowLoader = { _, _, _, _ in try await gate.page() }
        let paging = Task { await model.loadEarlierPage(sessionID: tab.key) }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(display.olderPage.loading)
        _ = otherTab(model)
        await model.openSubagentTab(tab.key)
        XCTAssertFalse(display.olderPage.loading, "A new presentation owns fresh boundary flags, even when the journal is unchanged")
        XCTAssertEqual(display.olderPage.cursor, cursor)
        await gate.release(); _ = await paging.value
        XCTAssertFalse(display.olderPage.loading)
    }
    @MainActor func testShowingAnAvailableSideClearsTheHiddenChildFocus() async throws {
        let (model, _) = try fixture()
        model.openSide()
        let side = try XCTUnwrap(model.sides["chat-parent"])
        let tab = try await open("chat-child", in: model)
        XCTAssertEqual(model.focusedSessionID, tab.key)
        model.tabs.showSide()
        XCTAssertTrue(model.paneSideAvailable)
        XCTAssertFalse(model.subagentTabIsShown(tab.key))
        XCTAssertNotEqual(model.focusedSessionID, tab.key)
        XCTAssertTrue(["chat-parent", side.id].contains(model.focusedSessionID ?? ""))
    }
    @MainActor func testSavedSideLoadDoesNotHideATabChosenWhileItWasLoading() async throws {
        let (model, gate) = try fixture()
        await gate.set("Saved side", held: true)
        let opening = Task { await model.openFamilySide("chat-side") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let other = otherTab(model)
        await gate.release(); await opening.value
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === other)
        XCTAssertNotEqual(model.focusedSessionID, "chat-child")
    }
    @MainActor func testNativeResponderTransitionsRestoreChildCommandFocus() async throws {
        let (model, _) = try fixture()
        let tab = try await open("chat-child", in: model)
        let container = model.tabs.popOut(tab), window = try XCTUnwrap(model.tabs.window(of: container))
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(tab.pane)
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 30)); text.isEditable = false
        pane.addSubview(text)
        for responder in [pane, text] as [NSView] {
            window.makeFirstResponder(nil); model.focusedSessionID = "chat-parent"
            XCTAssertTrue(window.makeFirstResponder(responder))
            XCTAssertEqual(model.focusedSessionID, tab.key, "Native focus inside the child must route Inspector, folding and Stop to that child")
        }
    }

    @MainActor func testClosingAndReopeningDuringAReadCannotAdoptTheClosedReadersPage() async throws {
        let (model, gate) = try fixture()
        await gate.set("Closed reader", held: true)
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let old = try XCTUnwrap(model.subagentTab("chat-child"))
        model.tabs.close(old)
        let fresh = ChildHistoryGate(); await fresh.set("New reader")
        model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
        let reopened = try await open("chat-child", in: model), display = try XCTUnwrap(model.displays["chat-child"])
        let generation = display.presentationGeneration
        XCTAssertFalse(reopened === old)
        await gate.release(); _ = await opening.value
        old.contentVisibilityChanged(false); old.refresh()
        XCTAssertTrue(model.subagentTab("chat-child") === reopened)
        XCTAssertEqual(display.messages.first?.text, "New reader")
        XCTAssertEqual(display.presentationGeneration, generation)
        XCTAssertNil(display.presentation.navigation); XCTAssertNil(reopened.loading)
    }
    @MainActor func testOpeningForAnotherParentDoesNotOverrideANewerTabChoice() async throws {
        for kind in ["child", "side", "new side"] {
            let (model, gate) = try fixture()
            var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
            let view = SessionDisplay(id: other.id); view.historyState = .ready; model.displays[other.id] = view
            model.selectedID = other.id; model.selected = view; model.focusedSessionID = other.id
            model.displays["chat-parent"]?.historyState = .dormant
            await gate.set("Parent", held: true)
            let opening = Task {
                if kind == "child" { await model.openSubagentTab("chat-child") }
                else if kind == "side" { await model.openFamilySide("chat-side") }
                else { model.openNewFamilySide("chat-parent") }
            }
            for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
            let selected = otherTab(model)
            await gate.release(); await opening.value; await model.navigationTask?.value
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === selected, kind)
            XCTAssertNil(model.subagentTab("chat-child"), kind)
            XCTAssertNil(model.sides["chat-parent"], kind)
        }
    }
    @MainActor func testMovingALoadingChildAcrossContainersKeepsItsLoadAndLaterFocusChoice() async throws {
        let (model, gate) = try fixture()
        await gate.set("Moved reader", held: true)
        let opening = Task { await model.openSubagentTab("chat-child") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let tab = try XCTUnwrap(model.subagentTab("chat-child"))
        let loading = try XCTUnwrap(tab.loading)
        let intent = tab.navigation
        model.tabs.popOut(tab)
        model.tabs.move(tab, to: model.tabs.pane)
        XCTAssertTrue(intent.isCurrent, "Moving the same reader keeps its pending read")
        await model.backToSubagentParent(tab.key)
        await gate.release(); await loading.value; _ = await opening.value
        // Back retires the opening. Its still-visible reader independently
        // revalidates history under the new intent without taking focus.
        tab.refresh(); await tab.loading?.value
        XCTAssertTrue(model.subagentTab(tab.key) === tab)
        XCTAssertEqual(model.displays[tab.key]?.messages.first?.text, "Moved reader")
        XCTAssertEqual(model.focusedSessionID, "chat-parent")
        XCTAssertNil(tab.loading)
    }
    @MainActor func testSavedSideOwnedAgentOpensBesideTheMainAndBackShowsItsActualOwner() async throws {
        let (model, _) = try fixture()
        model.chats[1].parentSessionID = "chat-side"
        model.chats[1].delegation?.budgetOwnerSessionID = "chat-side"
        let tab = try await open("chat-child", in: model)
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertTrue(model.subagentTabIsShown(tab.key))
        await model.backToSubagentParent(tab.key)
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertEqual(model.sides["chat-parent"]?.id, "chat-side")
        XCTAssertEqual(model.focusedSessionID, "chat-side")
        XCTAssertTrue(model.tabs.pane.sideShown)
    }
    @MainActor func testSidePresentationRestartsResetBothBoundaryFlagsAndRetainCursors() async throws {
        let (model, gate) = try fixture()
        let display = try XCTUnwrap(model.displays["chat-side"]), chat = try XCTUnwrap(model.record("chat-side"))
        let cursor = ConversationCursor(incarnation: "fixture", lineage: "root", entry: "boundary")
        func markPendingPages() {
            display.olderPage = .init(cursor: cursor, loading: true, error: "Old failure")
            display.newerPage = .init(cursor: cursor, loading: true, error: "Old failure")
        }
        func checkBoundaries() {
            XCTAssertEqual(display.olderPage, .init(cursor: cursor))
            XCTAssertEqual(display.newerPage, .init(cursor: cursor))
        }
        markPendingPages(); _ = model.mountSide(chat, beside: "chat-parent"); checkBoundaries()
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
        await model.select(other.id)
        markPendingPages(); await gate.set("Restored side", held: true)
        let selection = Task { await model.select("chat-parent") }
        for _ in 0..<500 { if model.selectedID == "chat-parent" { break }; try await Task.sleep(for: .milliseconds(2)) }
        checkBoundaries(); await gate.release(); await selection.value; await display.presentation.navigation?.value
        XCTAssertNil(display.presentation.navigation)
    }
    @MainActor func testPickerArrowsReturnAndRefreshPreserveTheChosenRow() async throws {
        let (model, _) = try fixture()
        let window = TabWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let picker = AgentFamilyPopoverView(model: model, sessionID: "chat-parent", close: {}, ownerWindow: window)
        window.contentView = picker; window.makeKeyAndOrderFront(nil); window.layoutIfNeeded()
        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        let first = try XCTUnwrap(ConversationPaneTests.views(FamilyPickerRow.self, in: picker).first)
        window.makeFirstResponder(first)
        first.keyDown(with: try key(125))
        XCTAssertEqual((window.firstResponder as? FamilyPickerRow)?.title, "New Side")
        (window.firstResponder as? FamilyPickerRow)?.keyDown(with: try key(125))
        XCTAssertEqual((window.firstResponder as? FamilyPickerRow)?.accessibilityIdentifier(), "open-agent-chat-child")
        let child = try XCTUnwrap(model.record("chat-child"))
        model.subagentSummaries[child.id] = .init(link: child.delegation!, description: child.title, model: "fixture", status: .running, revision: 2)
        picker.refresh()
        let focused = try XCTUnwrap(window.firstResponder as? FamilyPickerRow)
        XCTAssertEqual(focused.accessibilityIdentifier(), "open-agent-chat-child")
        var opened = false; focused.onPress = { opened = true }
        focused.keyDown(with: try key(36)); XCTAssertTrue(opened)
        let stop = try XCTUnwrap(focused.stop); picker.layoutSubtreeIfNeeded()
        XCTAssertTrue(focused.hitTest(stop.convert(.init(x: 12, y: 12), to: focused.superview)) === stop)
        XCTAssertTrue(focused.accessibilityChildren()?.contains { ($0 as? NSView) === stop } == true)
    }

    @MainActor func testNewSideRequestRetiresBeforeItsDeferredSelectionIfAnotherTabWasChosen() async throws {
        let (model, _) = try fixture()
        var other = try XCTUnwrap(model.record("chat-parent")); other.id = "other-main"; model.chats.append(other)
        model.openNewFamilySide(other.id)
        let file = otherTab(model)
        for _ in 0..<30 { await Task.yield() }
        await model.navigationTask?.value
        XCTAssertEqual(model.selectedID, "chat-parent")
        XCTAssertTrue(model.tabs.pane.shownTab(sideAvailable: model.paneSideAvailable) === file)
        XCTAssertNil(model.sides[other.id])
    }
    @MainActor func testReopeningASideWhoseReadWasCanceledStartsANewPresentation() async throws {
        let (model, gate) = try fixture()
        await gate.set("Canceled side read", held: true)
        let opening = Task { await model.openFamilySide("chat-side") }
        for _ in 0..<500 { if await gate.reads > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let display = try XCTUnwrap(model.displays["chat-side"])
        display.presentation.navigation?.cancel()
        let fresh = ChildHistoryGate(); await fresh.set("Reopened saved side")
        model.historyWindowLoader = { _, _, _, _ in try await fresh.page() }
        await gate.release(); await opening.value
        try await eventually("A canceled visible side resumes without reselecting") { display.messages.first?.text == "Reopened saved side" }
        XCTAssertFalse(display.historyState == .dormant)
    }

}

extension SubagentReaderTests {
    /// BUG-009 (review 2026-10-16): a side mounted beside its parent is not
    /// in view while a File or Changes tab covers it. A run that fails there,
    /// before any reply, keeps its unread-failure mark and sidebar dot; the
    /// same failure on the side in view does not.
    @MainActor func testASideCoveredByATabKeepsItsFailureMark() async throws {
        let (model, _) = try fixture()
        model.applicationIsActiveOverride = true
        model.readStatesRestored = true
        await model.openFamilySide("chat-side")
        XCTAssertTrue(model.transcriptShows("chat-side"))
        model.markRunFailed(sessionID: "chat-side")
        XCTAssertFalse(model.unreadFailure(sessionID: "chat-side"), "The reader saw the failure where it happened")

        _ = otherTab(model)
        XCTAssertNotNil(model.sides["chat-parent"], "The side stays mounted under the tab")
        XCTAssertFalse(model.transcriptShows("chat-side"))
        model.markRunFailed(sessionID: "chat-side")
        XCTAssertTrue(model.unreadFailure(sessionID: "chat-side"), "A covered side's failure is unread: the sidebar row's failure dot")
        XCTAssertEqual(model.unreadOutputCount(sessionID: "chat-side"), 0, "It failed before any reply")
    }
}
