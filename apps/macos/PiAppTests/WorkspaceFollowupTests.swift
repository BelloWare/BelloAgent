import XCTest
import SwiftUI
@testable import PiApp

private final class ConnectionTestReadGate: @unchecked Sendable {
    let entered: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() { entered.fulfill(); resume.wait() }
}
private extension MetadataStore {
    func holdConnectionTestReads(_ gate: ConnectionTestReadGate) { gate.hold() }
}

final class WorkspaceFollowupTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("workspace-followup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    /// The suite's one wait (`eventually`). A hundred polls of 20 ms, about
    /// two seconds, ran out in the parallel lane's load while the scratch
    /// chat's composer mounted (the 0.1.115 gate); the time is now read from
    /// a clock, with the suite's allowance.
    @MainActor private func waitFor(_ message: String = "Conversation view did not settle", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await eventually(message, file: file, line: line, condition)
    }

    @MainActor func testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject() async throws {
        let root = try scratch()
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "preview-only"
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-preview-key")]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        let chat = try await model.createConnectionTestChat(profileID: profile.id)
        let display = try XCTUnwrap(model.displays[chat.id]); display.draft = "Connection follow-up"
        let hosted = NSHostingView(rootView: ConversationPane(model: model, session: display, chat: chat, paneWidth: 900))
        window.contentView = hosted; window.orderFront(nil)
        try await waitFor("The scratch chat must mount its native composer") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).count == 1
        }
        XCTAssertEqual(descendants(ComposerTextView.self, in: hosted).first?.string, display.draft)
        XCTAssertTrue(model.workspaces.isEmpty); XCTAssertNil(model.selectedWorkspaceID)

        let preview = try await model.preparedContext(chat.id)
        let revision = try XCTUnwrap(preview["revision"]?.string)
        let tools = try await model.readPreparedContext(chat.id, revision: revision, section: "tools")
        let body = try JSONDecoder().decode(WireValue.self, from: Data(try XCTUnwrap(tools["text"]?.string).utf8))
        XCTAssertEqual(body, .array([]), "The scratch host must not advertise filesystem or MCP tools")
        XCTAssertEqual(preview["dispatched"]?.bool, false)
        let attempts = try await model.traces.list(sessionID: chat.id); XCTAssertTrue(attempts.isEmpty)

        var unavailable = chat; unavailable.workspaceID = "removed-project"
        hosted.rootView = ConversationPane(model: model, session: display, chat: unavailable, paneWidth: 900)
        try await waitFor("An unavailable project must remove the native composer") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).isEmpty
        }
        XCTAssertEqual(display.draft, "Connection follow-up", "Unavailable projects remain history-only without losing the draft")
        hosted.rootView = ConversationPane(model: model, session: display, chat: chat, paneWidth: 900)
        try await waitFor("Returning to the scratch chat must restore its native composer and draft") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).first?.string == "Connection follow-up"
        }
        try await model.hosts[WorkspaceRecord.scratchID]?.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testConnectionTestSideActionsPreserveDraftAndCreateNoChild() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let test = ChatRecord(id: "test", workspaceID: "project", title: "Connection test", path: nil, profileID: "p", toolMode: "read-only", connectionTest: true)
        let scratch = ChatRecord(id: "scratch-child", workspaceID: WorkspaceRecord.scratchID, title: "Retained scratch chat", path: nil, profileID: "p", toolMode: "read-only")
        let regular = ChatRecord(id: "regular", workspaceID: "project", title: "Regular", path: nil, profileID: "p")
        model.chats = [test, scratch, regular]
        XCTAssertTrue(model.canOpenSide(regular.id))
        for chat in [test, scratch] {
            let display = SessionDisplay(id: chat.id); display.draft = "/side keep this question"; display.directCommand = true
            model.displays[chat.id] = display
            XCTAssertFalse(model.canOpenSide(chat.id))
            model.openSide(parentID: chat.id)
            XCTAssertNotNil(model.error); XCTAssertTrue(model.sides.isEmpty)
            XCTAssertTrue(model.resolveLeadingCommand(display, steer: false))
            XCTAssertEqual(display.draft, "/side keep this question")
            XCTAssertTrue(display.directCommand); XCTAssertFalse(display.loading)
            model.enableEditing(chat.id)
            XCTAssertEqual(model.record(chat.id)?.toolMode, "read-only")
        }
        let intents = try await model.store?.list(SideKeepIntent.self, kind: "side-keep") ?? []
        XCTAssertTrue(intents.isEmpty); XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testConnectionTestSubmissionKeepsItsTargetAfterSelectionChanges() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.id = "synthetic-profile"; profile.api = LiteLLMConfiguration.supportedAPI
        model.profiles = [profile]
        let test = try await model.createConnectionTestChat(profileID: profile.id)
        let testDisplay = try XCTUnwrap(model.displays[test.id])
        let other = ChatRecord(id: "other", workspaceID: "project", title: "Other chat", path: nil, profileID: profile.id)
        let otherDisplay = SessionDisplay(id: other.id); otherDisplay.draft = "Keep this unrelated draft"
        model.chats.append(other); model.displays[other.id] = otherDisplay
        model.selectedID = other.id; model.focusedSessionID = other.id; model.selected = otherDisplay
        // A missing synthetic profile ends the submission before a helper or
        // network request, while exercising the actual target capture in send.
        model.profiles = []
        model.submitConnectionTestChat(test.id)
        XCTAssertTrue(testDisplay.loading); XCTAssertFalse(otherDisplay.loading)
        XCTAssertEqual(testDisplay.draft, "Reply with OK to confirm this API connection.")
        XCTAssertEqual(otherDisplay.draft, "Keep this unrelated draft")
        XCTAssertEqual(model.selectedID, other.id); XCTAssertEqual(model.focusedSessionID, other.id)
        try await waitFor { !testDisplay.loading }
        XCTAssertTrue(model.hosts.isEmpty)
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: test.id)
        XCTAssertEqual(saved?.text, testDisplay.draft)
        XCTAssertNotNil(testDisplay.sendFailure)
        XCTAssertFalse(testDisplay.uncertain, "A locally rejected send never reached the helper")
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(test.id)") ?? []
        XCTAssertTrue(pending.isEmpty)
        let unrelated = try await model.store?.get(DraftRecord.self, kind: "draft", id: other.id)
        XCTAssertNil(unrelated)
        await model.store?.close()
    }

    @MainActor func testConfirmedConnectionTestSurvivesCancelledSelection() async throws { try await cancelledConnectionTest(fails: false) }
    @MainActor func testConfirmedConnectionTestHydratesAfterSelectionMetadataWasCancelled() async throws { try await cancelledConnectionTest(fails: false, beforeMetadata: true) }
    @MainActor func testConfirmedConnectionTestReportsReconciliationFailure() async throws { try await cancelledConnectionTest(fails: true) }
    @MainActor private func cancelledConnectionTest(fails: Bool, beforeMetadata: Bool = false) async throws {
        let root = try scratch(), vault = ConfigurationVault(storage: MemoryVaultStorage())
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [.init(profile: savedProfile, apiKey: "fixture")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host")); model.hosts[WorkspaceRecord.scratchID] = host
        var release: CheckedContinuation<Void, Never>?, reads = 0
        model.commandAcceptanceRead = { path, _, _ in
            guard let chat = model.chats.first(where: { $0.connectionTest == true }), path.hasSuffix("/\(chat.id).jsonl") else { return [] }
            reads += 1
            if reads == 1 && !beforeMetadata { await withCheckedContinuation { release = $0 } }
            if fails { throw StoreError.unreadableRecord }
            return []
        }
        defer { release?.resume(); model.commandAcceptanceRead = nil }
        var gate: ConnectionTestReadGate?, blocker: Task<Void, Never>?, creation: Task<Void, Never>?
        defer { gate?.resume.signal() }
        if beforeMetadata {
            // The saved-chat handoff from createConnectionTestChat, held before
            // selection can read any metadata, not merely before acceptance.
            let chat = ChatRecord(id: "test", workspaceID: WorkspaceRecord.scratchID, title: "Connection test", profileID: profile.id, toolMode: ChatRecord.readOnlyTools, connectionTest: true)
            let store = try XCTUnwrap(model.store)
            try await store.put(chat, kind: "chat", id: chat.id); model.chats.append(chat)
            let entered = expectation(description: "metadata held"), held = ConnectionTestReadGate(entered); gate = held
            blocker = Task { await store.holdConnectionTestReads(held) }
            await fulfillment(of: [entered], timeout: 2)
            creation = Task { await model.select(chat.id); model.submitConnectionTestChat(chat.id) }
            try await eventually("connection test selected") { model.selectedID == chat.id }
        } else {
            model.testConnection(profileID: profile.id, confirmed: true)
            try await eventually("connection test reconciliation held") { release != nil }
        }
        let chat = try XCTUnwrap(model.chats.first(where: { $0.connectionTest == true })), view = try XCTUnwrap(model.displays[chat.id])
        view.snapshotInFlight = true; model.opened.insert(chat.id)
        XCTAssertFalse(view.draftReady)
        if beforeMetadata { XCTAssertFalse(view.selectionMetadataLoaded) }
        let other = ChatRecord(id: "other", workspaceID: "w", title: "Other", profileID: profile.id), otherView = SessionDisplay(id: "other")
        otherView.draft = "Keep this unrelated draft"; model.chats.append(other); model.displays[other.id] = otherView
        let navigation = Task { await model.select(other.id) }
        try await eventually("reader switched chats") { model.selectedID == other.id }
        gate?.resume.signal(); gate = nil; release?.resume(); release = nil
        await blocker?.value; await navigation.value; await creation?.value
        let prompt = "Reply with OK to confirm this API connection."
        try await eventually("confirmed test submitted or reported its failure") {
            frames.contains { $0["method"]?.string == "turn.submit" } || model.error != nil || (!view.loading && view.draft == prompt)
        }
        let submissions = frames.filter { $0["method"]?.string == "turn.submit" }
        if fails {
            XCTAssertTrue(submissions.isEmpty); XCTAssertNotNil(model.error, "A confirmed request must not disappear when reconciliation fails")
            XCTAssertFalse(view.draftReady)
        } else {
            XCTAssertEqual(submissions.count, 1, "Switching chats must not drop or duplicate the confirmed request")
            XCTAssertTrue(view.draftReady); XCTAssertTrue(view.selectionMetadataLoaded); XCTAssertGreaterThanOrEqual(reads, beforeMetadata ? 1 : 2)
            if let frame = submissions.first {
                XCTAssertEqual(frame["sessionId"]?.string, chat.id); XCTAssertEqual(frame["params"]?.object?["text"]?.string, prompt)
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                                     "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]),
                             connectionID: try XCTUnwrap(host.connectionID))
                try await eventually("test submit settled") { !view.loading }
            }
        }
        XCTAssertEqual(otherView.draft, "Keep this unrelated draft"); XCTAssertEqual(model.selectedID, other.id); XCTAssertEqual(model.focusedSessionID, other.id)
    }

    @MainActor func testMissingConnectionPreservesTheEditedMessageAndDisplacedDraft() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let chat = ChatRecord(id: "edit", workspaceID: "project", title: "Retained chat", path: nil, profileID: "missing")
        let display = SessionDisplay(id: chat.id)
        display.draft = "Edited question"; display.editingMessageID = "earlier-user-message"
        display.draftBeforeEdit = DraftRecord(id: chat.id, text: "Unsent original draft")
        model.chats = [chat]; model.displays[chat.id] = display

        model.sendEdit(sessionID: chat.id)
        try await waitFor { !display.loading }
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(saved?.text, "Edited question")
        XCTAssertEqual(saved?.edit?.messageID, "earlier-user-message")
        XCTAssertEqual(saved?.edit?.originalText, "Unsent original draft")
        XCTAssertTrue(display.notice.contains("connection is unavailable"))
        XCTAssertFalse(display.uncertain); XCTAssertTrue(model.hosts.isEmpty)
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(chat.id)") ?? []
        XCTAssertTrue(pending.isEmpty)
        await model.store?.close()
    }

    @MainActor func testCancellingArchivedOpenSideDeletionKeepsPaneRecordDraftAndJournal() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let directory = try model.subagentDirectory("w")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path = directory.appendingPathComponent("side_child.jsonl")
        let bytes = Data((#"{"type":"session","version":3,"id":"child"}"# + "\n").utf8)
        try bytes.write(to: path)
        let parent = ChatRecord(id: "parent", workspaceID: "w", title: "Parent", path: nil, profileID: "p")
        var child = ChatRecord(id: "child", workspaceID: "w", title: "Side", path: path.path, profileID: "p", toolMode: "read-only", parentSessionID: parent.id)
        child.archivedAt = Date()
        let display = SessionDisplay(id: child.id); display.draft = "Unsent child draft"
        model.chats = [parent, child]; model.displays[child.id] = display
        model.sides[parent.id] = SideRecord(id: child.id, parentID: parent.id, workspaceID: "w", profileID: "p", title: child.title, kept: true)
        model.selectedID = parent.id; model.focusedSessionID = child.id
        try await model.store?.put(child, kind: "chat", id: child.id)
        var question: ChatQuestion?
        model.questions.answer = { question = $0; return false }
        model.deleteChat(child.id)
        try await eventually("The idle archived side reaches its deletion confirmation") { question != nil || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(question?.title,"Delete the archived chat “Side”?")
        XCTAssertEqual(model.sides[parent.id]?.id, child.id); XCTAssertTrue(model.displays[child.id] === display)
        XCTAssertEqual(model.record(child.id), child); XCTAssertEqual(display.draft, "Unsent child draft")
        XCTAssertEqual(model.selectedID, parent.id); XCTAssertEqual(model.focusedSessionID, child.id)
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: child.id)
        XCTAssertEqual(stored, child); XCTAssertEqual(try Data(contentsOf: path), bytes)
        await model.store?.close()
    }

    /// A compaction is one summary request: its progress names the phase,
    /// never a chunk or an invented percent.
    @MainActor func testCompactionProgressNamesThePhaseWithoutChunksOrInventedPercent() {
        let display=SessionDisplay(id:"progress")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("planning")])])
        XCTAssertEqual(display.compactionProgress,"Preparing complete tool history")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("summarizing"),"chunk":.number(2)])])
        XCTAssertEqual(display.compactionProgress,"Summarizing earlier work","An older helper's chunk is not shown")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("retrying")])])
        XCTAssertEqual(display.compactionProgress,"Retrying summary request")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("merging")])])
        XCTAssertNil(display.compactionProgress,"No helper merges summaries now")
        display.observeCompaction(["runStatus":.string("failed"),"compaction":.object(["phase":.string("failed")])])
        XCTAssertNil(display.compactionProgress)
    }
}
